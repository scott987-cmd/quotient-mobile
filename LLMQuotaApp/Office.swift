import SwiftUI

// MARK: - 事件

/// 办公室里发生过的事。字段和 Mac 端 OfficeEvent 对应。
struct OfficeEvent: Codable, Identifiable {
    var id: String
    var at: Date
    var kind: Kind
    var taskID: String
    var platform: String?
    var toPlatform: String?
    var machineID: String
    var detail: String
    var taskTitle: String
    /// 派这件活时谁被规则挡掉了。**规则只有在拦人的那一刻才看得见。**
    var excluded: [Excluded]?

    struct Excluded: Codable, Identifiable {
        var platform: String
        var agentName: String
        var reason: String
        var id: String { platform }
    }

    /// **跨机器传的结构一律手写 decodeIfPresent。**(Mac 端 AGENTS.md「踩过五次」)
    /// 对账实锤(2026-08-23 契约评审):这里原来是合成解码器,一条缺键的事件会让
    /// 整份 office.json 解不出来,办公室永远停在最后一次成功的旧事件上循环。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? .distantPast
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .other
        taskID = try c.decodeIfPresent(String.self, forKey: .taskID) ?? ""
        platform = try c.decodeIfPresent(String.self, forKey: .platform)
        toPlatform = try c.decodeIfPresent(String.self, forKey: .toPlatform)
        machineID = try c.decodeIfPresent(String.self, forKey: .machineID) ?? ""
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        taskTitle = try c.decodeIfPresent(String.self, forKey: .taskTitle) ?? ""
        excluded = try c.decodeIfPresent([Excluded].self, forKey: .excluded)
        let rawID = try c.decodeIfPresent(String.self, forKey: .id)
        id = rawID?.isEmpty == false ? rawID! : StableID.make(
            namespace: "office-event",
            parts: [machineID, taskID, kind.rawValue, String(at.timeIntervalSince1970)])
    }

    enum Kind: String, Codable {
        case dispatched, handoff, asked, answered, finished, exhausted
        /// Mac 端 2026-08-22 加的:静默时说「为什么没人干活」。
        case idle
        /// 以后 Mac 再加新种类,手机这边不认也**不能让整份 office.json 解不出来**。
        /// 对账实锤(2026-08-23):一条 idle 事件让整个办公室事件流在手机上变空 ——
        /// Swift 合成解码遇到不认识的 rawValue 会让 `[OfficeEvent]` 整体失败。
        case other

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .other
        }
    }

    var verb: String {
        switch kind {
        case .dispatched: return "接到新活"
        case .handoff:    return "交接"
        case .asked:      return "提问"
        case .answered:   return "收到答复"
        case .finished:   return "结束"
        case .exhausted:  return "额度耗尽"
        case .idle:       return "闲着（说明原因）"
        case .other:      return "动态"
        }
    }
}

// MARK: - 办公室

/// 办公室只维护一套内容，按可用宽度换排法。
///
/// 不直接看设备型号：iPad 分屏时可能只有 iPhone 宽度，Mac 上的 iPhone App
/// 反过来也可能拿到很宽的窗口。真正决定信息能不能并排的是 size class + 宽度。
enum OfficePresentation: Equatable {
    case phone
    case tabletStacked
    case tabletSplit

    static func resolve(width: CGFloat, regularWidth: Bool) -> OfficePresentation {
        guard regularWidth else { return .phone }
        return width >= 960 ? .tabletSplit : .tabletStacked
    }

    static func deskColumnCount(width: CGFloat, staffCount: Int) -> Int {
        guard width >= 600 else { return 2 }
        let capacity = max(4, min(6, Int(width / 150)))
        // 每台机器各有一张独立网格。人数少时如果仍按“最大容量”建列，
        // 两个人只会占据六列中的前两列，iPad 右侧留下大片假空白。
        return max(1, min(capacity, staffCount))
    }

    var showsSummaryStrip: Bool { self == .tabletStacked }
    var showsControlRail: Bool { self == .tabletSplit }
}

/// 姿态只消费已同步的事实；休息动作是表现层，不产生任务或协作事件。
enum OfficeActivity: String, Equatable {
    case unknown, working, asking, celebrating, failed, blocked, queued, depleted
    case ready, sleeping, stretching, sipping

    var label: String {
        switch self {
        case .unknown: return "等状态同步"
        case .working: return "认真干活中"
        case .asking: return "有个问题想问你"
        case .celebrating: return "交活啦！"
        case .failed: return "这次没完成"
        case .blocked: return "这件活卡住了"
        case .queued: return "等着接下一棒"
        case .depleted: return "等额度恢复"
        case .ready: return "随时可以开工"
        case .sleeping: return "没活先躺一会儿"
        case .stretching: return "一起伸个懒腰"
        case .sipping: return "一起喝口水"
        }
    }

    var isIdle: Bool { self == .ready || self == .sleeping }

    static func completedTask(for event: OfficeEvent, in board: TaskBoardLoad) -> TaskBrief? {
        guard event.kind == .finished, board.machineID == event.machineID,
              !event.taskID.isEmpty, let platform = event.platform else { return nil }
        return board.tasks.first { $0.taskID == event.taskID && $0.platform == platform }
    }

    static func freshBoard(machine: MachineInfo?, tasks: TaskDigest, now: Date) -> TaskBoardLoad? {
        guard let machine, !machine.machineID.isEmpty, !machine.isStale,
              (-TaskDigest.futureTolerance...TaskDigest.staleAfter)
                .contains(now.timeIntervalSince(machine.lastSeen)),
              let board = tasks.rawBoards.first(where: { $0.machineID == machine.machineID }),
              board.unreadable == nil, !board.truncated, !board.isFallback,
              let generated = board.generatedAt,
              (-TaskDigest.futureTolerance...TaskDigest.staleAfter)
                .contains(now.timeIntervalSince(generated)) else { return nil }
        return board
    }

    static func resolve(report: PlatformReport, machine: MachineInfo?, tasks: TaskDigest,
                        asks: [Ask], events: [OfficeEvent], idleSince: Date?, now: Date) -> OfficeActivity {
        guard let machine else { return .unknown }
        guard let board = freshBoard(machine: machine, tasks: tasks, now: now), report.detected else {
            return .unknown
        }
        if asks.contains(where: { $0.machineID == machine.machineID && $0.platform == report.platform }) {
            return .asking
        }
        let mine = board.tasks.filter { $0.platform == report.platform && !$0.isTerminal }
        if mine.contains(where: \.isRunning) { return .working }
        if mine.contains(where: { $0.isBlocked || $0.known == nil }) { return .blocked }
        if mine.contains(where: \.isQueued) { return .queued }
        let latest = events.filter {
            $0.machineID == machine.machineID && ($0.platform == report.platform
                || ($0.kind == .handoff && $0.toPlatform == report.platform))
                && $0.kind != .idle && $0.at <= now
        }.max { $0.at < $1.at }
        if let latest, now.timeIntervalSince(latest.at) < 12 {
            if latest.kind == .finished {
                // Mac 的 finished 也用于失败收尾；只有同任务的真实 done 才庆祝。
                switch completedTask(for: latest, in: board)?.known {
                case .done: return .celebrating
                case .failed: return .failed
                default: return .unknown
                }
            }
            if latest.kind == .asked { return .asking }
        }
        if StaffState.classify(report) == .drained || (report.cooldownUntil ?? .distantPast) > now {
            return .depleted
        }
        // 没有平台归属的活也可能属于这位，不能把不确定演成睡觉。
        if board.tasks.contains(where: { !$0.isTerminal && ($0.platform ?? "").isEmpty }) { return .unknown }
        if let since = idleStart(report: report, machine: machine, events: events,
                                 observed: idleSince, now: now), now.timeIntervalSince(since) >= 20 * 60 {
            return .sleeping
        }
        return .ready
    }

    static func idleStart(report: PlatformReport, machine: MachineInfo, events: [OfficeEvent],
                          observed: Date?, now: Date) -> Date? {
        // 汇总报告的 lastActivity 不能冒充某一台机器的时间。
        let singleMachine = report.machineIDs == [machine.machineID]
        let activity = singleMachine ? report.lastActivity : nil
        let eventAt = events.filter {
            $0.machineID == machine.machineID && ($0.platform == report.platform || $0.toPlatform == report.platform)
                && $0.kind != .idle
        }.map(\.at).max()
        let known = [activity, eventAt].compactMap { $0 }.max()
        if let known {
            guard known <= now else { return nil }
            return max(known, observed ?? .distantPast)
        }
        return observed
    }

    static func sharedBreak(activities: [OfficeActivity], idleStarts: [Date?], board: TaskBoardLoad?,
                            hasQuestions: Bool, now: Date) -> OfficeActivity? {
        guard activities.count >= 2, activities.allSatisfy(\.isIdle), !hasQuestions,
              let board, !board.tasks.contains(where: { !$0.isTerminal }),
              idleStarts.count == activities.count,
              idleStarts.allSatisfy({ $0.map { now.timeIntervalSince($0) >= 120 } ?? false }) else { return nil }
        let phase = Int(now.timeIntervalSince1970) % 120
        if phase < 15 { return .stretching }
        if phase < 30 { return .sipping }
        return nil
    }
}

/// 数字员工的办公室。
///
/// 任务、提问与交活驱动角色姿态；额度牌仍使用员工页的同一判定。
/// 只有来源明确、新鲜且没有待办的工位才能小憩或参与本机休息动画。
/// 伸展、喝水是装饰，不写入真实事件流，不代表 Agent 执行了这些动作。
struct OfficeView: View {
    @EnvironmentObject var store: Store
    @State private var now = Date()
    /// 正在播放的事件身份。不能存 suffix(20) 里的下标：新事件进来时窗口左移，
    /// 同一个下标会突然指向下一条，动画和字幕无故跳变。
    @State private var currentEventID: String?
    /// 只有刚同步到的新事件会驱动场景动作；字幕仍显示最新一条。
    @State private var animatedEventID: String?
    @State private var selectedMachineID: String?
    @State private var picked: PlatformReport?
    /// 点了头顶带问号的那位 —— 直接跳去回答他。
    @State private var answering: Ask?
    /// 点名派活给某个人。
    @State private var assigning: PlatformReport?
    /// 工位和老板的实际坐标。
    @State private var anchors: [String: CGPoint] = [:]
    /// 0 = 在工位，1 = 到老板跟前。
    @State private var walkProgress: Double = 0
    /// 机器排序面板。
    @State private var ordering = false
    /// 谁正在去老板那儿的路上（离席中）。
    ///
    /// 人走了座位就得空着 —— 小人在路上走、座位上还坐着个大号分身，
    /// 等于同一个人画了两遍（用户原话：「应该离开座位的时候座位应该是空的」）。
    /// 带上 machineID：同一平台装在两台机器上时，只空走的那台的座位。
    struct Traveling: Equatable { let machineID: String; let platform: String }
    @State private var traveling: Traveling?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var staff: [PlatformReport] {
        (store.dashboard?.reports ?? [])
            .filter { ($0.enabled ?? true) && ($0.detected || $0.installed) }
            // 指挥**只在它当指挥的那台机器上**不坐工位(见 byMachine 里按机器判)。
            // 原来这里全局过滤掉它 —— Claude 在 MacBook 上是干活的,照样没桌子,
            // 它跑的活永远上不了桌(对账 2026-08-23)。
            .sorted { ($0.last30dRequests) > ($1.last30dRequests) }
    }

    /// 按机器分组的工位。
    ///
    /// **同一个平台可能装在两台机器上**，只按平台画一排的话，
    /// 你看到一个「Kimi」却不知道它是哪台机器上的那个 ——
    /// 而两台机器的额度、可用性、正在干的活都不一样。
    /// 分组之后每台机器一小节，各自的机器人还带不同色调，一眼分得开。
    private var byMachine: [(machine: MachineInfo, staff: [PlatformReport])] {
        // 顺序归用户管（右上角「排序」）：主力机想在上面就在上面。
        let ms = store.orderedByMachine(store.dashboard?.machines ?? [],
                                        id: { $0.machineID })
        return ms.compactMap { m in
            // 装在这台机器上、且不在这台上当指挥的,才在这台上有工位。
            let mine = staff.filter {
                $0.isReported(on: m)
                    && !($0.role?.isDispatcher(on: m) ?? false)
            }
            return mine.isEmpty ? nil : (m, mine)
        }
    }

    /// 一台机器都对不上的工位（快照里的机器名和 machines 列表对不上时）。
    /// **不能默默丢掉** —— 那会让一个真实存在的 agent 从界面上消失。
    private var unassigned: [PlatformReport] {
        let known = store.dashboard?.machines ?? []
        return staff.filter { report in
            !known.contains { report.isReported(on: $0) }
        }
    }

    /// 本集群的指挥。没有就是 nil —— 那时讲台上画一个「没有指挥」的空位，
    /// 而不是一个匿名吉祥物在那儿假装工作。
    private var boss: PlatformReport? {
        (store.dashboard?.reports ?? []).first { $0.role?.isDispatcher ?? false }
    }

    private var selectedGroup: (machine: MachineInfo, staff: [PlatformReport])? {
        guard let selectedMachineID else { return byMachine.first }
        return byMachine.first { $0.machine.machineID == selectedMachineID } ?? byMachine.first
    }

    private var visibleMachineGroups: [(machine: MachineInfo, staff: [PlatformReport])] {
        if horizontalSizeClass == .compact, let selectedGroup { return [selectedGroup] }
        return byMachine
    }

    private var visibleBoss: PlatformReport? {
        guard horizontalSizeClass == .compact,
              let machine = selectedGroup?.machine else { return boss }
        return (store.dashboard?.reports ?? []).first {
            $0.role?.isDispatcher(on: machine) ?? false
        } ?? boss
    }

    /// 平台 → agent 名。从看板里查，不在手机端另写一份映射 ——
    /// 两份映射迟早会漂移，而漂移了两边显示不同的名字最难查。
    private func agentName(_ platform: String?) -> String {
        guard let platform else { return "调度" }
        return store.dashboard?.reports.first { $0.platform == platform }?.displayName
            ?? (PlatformNames.map[platform] ?? platform)
    }

    /// 谁头上顶着待回答的问题。
    nonisolated static func asksByPlatform(_ asks: [Ask], machineID: String) -> [String: Ask] {
        guard !machineID.isEmpty else { return [:] }
        return Dictionary(asks.filter { $0.machineID == machineID }
            .compactMap { a in a.platform.map { ($0, a) } },
                   uniquingKeysWith: { a, _ in a })
    }

    /// 这件事要不要走一趟，以及谁去、手里有没有东西。
    ///
    /// 只有「领活」和「交活」才走 —— 提问和额度耗尽都是原地发生的事，
    /// 让他为此走一趟反而看不懂。
    private func trip(for e: OfficeEvent) -> (platform: String, carrying: Bool)? {
        guard let p = e.platform else { return nil }
        switch e.kind {
        case .dispatched: return (p, false)   // 空手去领
        case .finished:
            let machine = store.dashboard?.machines.first { $0.machineID == e.machineID }
            guard let board = OfficeActivity.freshBoard(machine: machine, tasks: store.taskDigest, now: Date()),
                  OfficeActivity.completedTask(for: e, in: board)?.known == .done else { return nil }
            return (p, true)
        default: return nil
        }
    }

    /// 只保留最近一小段供「最新动态」和详情使用，不循环播放历史。
    ///
    /// 原来直接在 store.events（200 条，最老的两天前）上循环：打开时定位到
    /// 最新一条，2.2 秒后 `(cursor+1) % 200` 绕回第 0 条 —— 于是屏幕上
    /// 立刻开始播两天前的事，走完一圈要七分半钟。用户的原话是
    ///「办公室不显示实时的任务进度，咋老显示两天前的」。
    ///
    /// 办公室要回答的是「**现在**谁在干什么」，不是「这两天发生过什么」——
    /// 后者是「任务」那一栏的事。所以这里只取最近 20 条作为轻量上下文。
    private var recentEvents: [OfficeEvent] {
        let events: [OfficeEvent]
        if horizontalSizeClass == .compact, let machineID = selectedGroup?.machine.machineID {
            events = store.events.filter { $0.machineID.isEmpty || $0.machineID == machineID }
        } else {
            events = store.events
        }
        return Array(events.suffix(20))
    }

    /// 当前正在演的那件事。没有事件就是 nil，办公室安安静静各干各的。
    private var current: OfficeEvent? {
        let list = recentEvents
        guard !list.isEmpty else { return nil }
        guard let currentEventID else { return list.last }
        return list.first { $0.id == currentEventID } ?? list.last
    }

    private var sceneEvent: OfficeEvent? {
        guard current?.id == animatedEventID else { return nil }
        return current
    }

    static func shouldAnimate(_ event: OfficeEvent, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(event.at)
        return age >= 0 && age <= 60
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let presentation = OfficePresentation.resolve(
                    width: geo.size.width,
                    regularWidth: horizontalSizeClass == .regular)
                let railWidth = min(390, max(330, geo.size.width * 0.34))
                let officeWidth = geo.size.width
                    - (presentation.showsControlRail ? railWidth : 0)
                ZStack(alignment: .top) {
                    Floor()

                    // **桌位内容必须能滚。** 按机器分节之后内容比一屏高：
                    // 两台机器 × (表头 + 桌位网格) + 老板排，最下面那排员工
                    // 被直接裁掉，而且整页没得滚 —— 用户的原话是
                    // 「没法上下滑动，最下面的数字员工被遮挡了」。
                    //
                    // Floor 和底部字幕留在屏幕固定层；小人（Courier）必须
                    // **和桌子一起滚**：它按 office 坐标空间的锚点走位，
                    // 空间跟着挪到滚动内容上，两者才始终对得上。
                    ScrollView(showsIndicators: false) {
                    ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                        BossRow(boss: visibleBoss,
                                machineName: horizontalSizeClass == .compact
                                    ? selectedGroup?.machine.displayName : nil,
                                dispatching: sceneEvent?.kind == .dispatched,
                                answering: sceneEvent?.kind == .answered)
                            .frame(height: 84)
                            .background(GeometryReader { g in
                                Color.clear.preference(
                                    key: DeskAnchors.self,
                                    value: ["__boss": CGPoint(
                                        x: g.frame(in: .named("office")).midX,
                                        y: g.frame(in: .named("office")).maxY - 10)])
                            })

                        if horizontalSizeClass == .compact, byMachine.count > 1 {
                            MachinePicker(groups: byMachine,
                                          selectedMachineID: Binding(
                                            get: { selectedGroup?.machine.machineID },
                                            set: { selectedMachineID = $0 }))
                                .padding(.bottom, 6)
                        }

                        if presentation.showsSummaryStrip {
                            OfficeSummaryStrip()
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                        }

                        // 一个员工都没有时，**说清楚为什么**。
                        //
                        // 原来这里直接渲染空网格：屏幕中间一片空地板，
                        // 没有工位、没有表情、也没有任何解释 ——
                        // 人无法判断是没连上、Mac 没在采集、还是 App 坏了。
                        // 今天这个毛病在三个地方各犯了一次
                        //（菜单栏空弹窗、额度页空列表、这里）。
                        if staff.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "person.2.slash")
                                    .font(.system(size: 34))
                                    .foregroundStyle(.secondary)
                                Text(store.isConnected ? "还没有员工上班" : "还没连上你的 Mac")
                                    .font(.headline)
                                Text(store.isConnected
                                     ? "Mac 上跑一次 llmq collect，采集到用量之后他们就会出现。"
                                     : "去「额度」那一栏选一次 iCloud 云盘里的 LLMQuotaBar 文件夹。")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 32)
                            }
                            .padding(.top, 40)
                        }

                        // **桌上看不到「在干什么」的时候，得说出来是为什么。**
                        //
                        // 小人照样在动 —— 那是按额度状态和事件流演的。
                        // 老 Mac 不发任务数据时，画面一切正常，但没有一张桌子
                        // 写得出他在干嘛。不解释的话，人得出的结论会是
                        //「这 App 就是不显示任务」，而不是「这台 Mac 版本旧」。
                        if !store.taskDigest.published && !staff.isEmpty {
                            Text(store.taskDigest.unreadableBoards.isEmpty
                                 ? "这台 Mac 没发来任务数据，桌上看不到「正在干什么」—— "
                                   + "不是没有任务。升级 Mac 上的 llmq 就有了。"
                                 // 板子在但一块都读不出来是另一回事：不用升级，
                                 // 等 iCloud 把文件同步下来就行。说错了会让人
                                 // 去折腾一台其实没问题的 Mac。
                                 : "所有机器的任务板都还读不出来，桌上看不到「正在干什么」—— "
                                   + "不是没有任务。等 iCloud 同步完再下拉刷新。")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.top, 6)
                        }

                        ForEach(visibleMachineGroups, id: \.machine.machineID) { group in
                            let asking = Self.asksByPlatform(store.asks, machineID: group.machine.machineID)
                            MachineHeader(
                                machine: group.machine,
                                board: store.taskDigest.board(
                                    machineID: group.machine.machineID,
                                    machineName: group.machine.machineName))
                            DeskGrid(staff: group.staff, machineID: group.machine.machineID,
                                     machineName: group.machine.machineName,
                                     tasks: store.taskDigest,
                                     event: sceneEvent, width: officeWidth,
                                     asking: asking, traveling: traveling, now: now,
                                     machine: group.machine, events: store.events, asks: store.asks,
                                     onTap: { r in
                                         // 有人举着手，点他就是去回答他 ——
                                         // 比让人自己去「问题」那栏里找快得多，
                                         // 而且画面上他头顶就顶着问号。
                                         if let a = asking[r.platform] { answering = a }
                                         else { picked = r }
                                     })
                        }
                        if !unassigned.isEmpty {
                            MachineHeader(machine: nil)
                            // 这一组的机器名对不上任何一台已知机器，
                            // 所以只能按平台去认领任务（machineName 传 nil）。
                            DeskGrid(staff: unassigned, machineID: "",
                                     machineName: nil,
                                     tasks: store.taskDigest,
                                     event: sceneEvent, width: officeWidth,
                                     asking: [:], traveling: traveling, now: now,
                                     machine: nil, events: [], asks: [],
                                     onTap: { r in picked = r })
                        }

                        Spacer(minLength: 0)
                    }
                    // 底部留白：最后一排桌子别贴着 tab 栏。
                    .padding(.bottom, 28)

                    // 走位：领活的从工位走到老板那儿，交活的走过去上交。
                    if let e = sceneEvent, let trip = trip(for: e),
                       let deskPt = anchors[DeskAnchors.key(e.machineID, trip.platform)],
                       let bossPt = anchors["__boss"] {
                        Courier(hue: StaffHue.of(trip.platform),
                                species: MascotSpecies.pick(
                                    machineID: e.machineID,
                                    platform: trip.platform),
                                from: deskPt, to: bossPt,
                                progress: walkProgress,
                                carrying: trip.carrying)
                    }
                    }
                    .coordinateSpace(name: "office")
                    .onPreferenceChange(DeskAnchors.self) { anchors = $0 }
                    }
                    // **字幕用 safeAreaInset，不用 ZStack 覆盖层。**
                    //
                    // 覆盖层是浮在内容之上的：滚到底时最后一排员工就藏在
                    // 它下面。老板报过两次同一件事 ——
                    // 第一次是「没法上下滑动，最下面的数字员工被遮挡了」
                    //（那次加了 ScrollView），第二次是「办公室下面的消息
                    // 显示遮挡员工」。加滚动只解决了「够不着」，
                    // 没解决「够着了也被压住」。
                    //
                    // safeAreaInset 让字幕**自己占位**：ScrollView 的可滚区域
                    // 自动缩掉字幕那么高，内容能完整滚到字幕上方。
                    // 比「量一下字幕高度再加 padding」好在两点：
                    // 不用手工量，而且字幕换行导致高度变化时布局也不会抖。
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if let e = current {
                            EventCaption(event: e, agentName: agentName,
                                         completion: store.taskDigest.rawBoards.first {
                                             $0.machineID == e.machineID
                                         }.flatMap { OfficeActivity.completedTask(for: e, in: $0)?.known })
                                // 字幕**不做转场**，原地换内容。
                                //
                                // 试过 .id + .transition(.opacity)：加 .id 让 SwiftUI
                                // 认成新 view 了，但交叉淡入期间新旧两条同时在场、
                                // 位置又完全重合，看起来就是重影。字幕是用来读的，
                                // 不是用来炫的。
                                .padding(.horizontal, 16)
                                .padding(.bottom, 12)
                        }
                    }

                    // iPad 大屏把桌面看板最有行动价值的部分放到右栏。
                    // 它只消费 Store 里的同一份服务端数据，不另算一套状态。
                    .safeAreaInset(edge: .trailing, spacing: 0) {
                        if presentation.showsControlRail {
                            OfficeDashboardRail()
                                .frame(width: railWidth)
                                .background(.regularMaterial)
                                .overlay(alignment: .leading) { Divider() }
                                .accessibilityIdentifier("office-ipad-dashboard")
                        }
                    }


                }
            }
            .navigationTitle("办公室")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("机器排序", systemImage: "arrow.up.arrow.down") {
                            ordering = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $ordering) {
                MachineOrderSheet()
                    .presentationDetents([.medium])
            }
            .refreshable { await store.refresh() }
            // 耗时文案只显示到「分钟」，没必要每秒让整间办公室重算一遍。
            .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { _ in
                now = Date()
            }
            // 新消息不能等下一次低频 tick：否则会错过短暂的交活窗口，
            // 或让刚接到任务的小人继续休息。只随数据更新重算，不提高整页帧率。
            .onReceive(store.$events) { _ in now = Date() }
            .onReceive(store.$taskDigest) { _ in now = Date() }
            .onReceive(store.$asks) { _ in now = Date() }
            .onReceive(store.$dashboard) { _ in now = Date() }
            // 走一趟：去 → 停一下交接 → 回来。
            //
            // 只为刚同步到的事件走一次：去 0.75 + 停 0.35 + 回 0.75 = 1.85 秒。
            .onChange(of: currentEventID) { _, _ in
                guard animatedEventID != nil, !reduceMotion,
                      let e = current, let t = trip(for: e) else {
                    walkProgress = 0; traveling = nil; return
                }
                walkProgress = 0
                // 人上路了，座位立刻空出来；走完一个来回（1.85 秒）再坐回去。
                let who = Traveling(machineID: e.machineID, platform: t.platform)
                withAnimation(.easeInOut(duration: 0.3)) { traveling = who }
                withAnimation(.easeInOut(duration: 0.75)) { walkProgress = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                    withAnimation(.easeInOut(duration: 0.75)) { walkProgress = 0 }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.85) {
                    if traveling == who {
                        withAnimation(.easeInOut(duration: 0.3)) { traveling = nil }
                    }
                }
            }
            .onAppear {
                now = Date()
                selectedMachineID = selectedGroup?.machine.machineID
                currentEventID = recentEvents.last?.id
            }
            .onChange(of: recentEvents.map(\.id)) { _, ids in
                guard !ids.isEmpty else { currentEventID = nil; return }
                guard currentEventID != ids.last else { return }
                currentEventID = ids.last
                animatedEventID = current.flatMap { Self.shouldAnimate($0) ? $0.id : nil }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if animatedEventID == ids.last { animatedEventID = nil }
                }
            }
            .onChange(of: selectedMachineID) { _, _ in
                animatedEventID = nil
                currentEventID = recentEvents.last?.id
            }
            .onChange(of: byMachine.map(\.machine.machineID)) { _, ids in
                if let selectedMachineID, ids.contains(selectedMachineID) { return }
                self.selectedMachineID = ids.first
            }
            .sheet(item: $picked) { r in
                NavigationStack {
                    RoleCard(report: r, events: store.events,
                             tasks: store.taskDigest,
                             onAssign: { picked = nil; assigning = r })
                        .navigationTitle(r.displayName)
                        .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $answering) { a in
                NavigationStack { AnswerView(ask: a) }
            }
            .sheet(item: $assigning) { r in
                NavigationStack { SubmitView(assignTo: r) }
            }
        }
    }
}

// MARK: - iPad 团队控制台

/// iPad 竖屏的摘要条。完整信息在横屏右栏，窄一点时只保留四个最该盯的数。
private struct OfficeSummaryStrip: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let digest = store.taskDigest
        HStack(spacing: 0) {
            metric("在跑", digest.running.count, .blue)
            metric("排队", digest.queued.count, .secondary)
            metric("卡住", digest.blocked.count, digest.blocked.isEmpty ? .secondary : .red)
            metric("待回答", store.asks.count, store.asks.isEmpty ? .secondary : .orange)
        }
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("office-ipad-summary")
    }

    private func metric(_ title: String, _ value: Int, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title3.monospacedDigit().bold()).foregroundStyle(tint)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 横屏 iPad 的右侧控制台：办公室负责“谁在动”，这里回答“为什么、接下来怎么办”。
private struct OfficeDashboardRail: View {
    @EnvironmentObject var store: Store

    private var activeReports: [PlatformReport] {
        (store.dashboard?.reports ?? []).filter {
            ($0.enabled ?? true) && ($0.detected || $0.installed)
        }
    }

    private var mood: StaffState {
        let states = activeReports.map(StaffState.classify)
        return StaffState.rank.first { states.contains($0) } ?? .asleep
    }

    private var watchedQuota: [(PlatformReport, QuotaStatus)] {
        activeReports.flatMap { report in report.statuses.map { (report, $0) } }
            .filter { statusPair in
                let status = statusPair.1
                return !status.advisory && status.isCurrent && status.hasUsageValue
                    && (status.health == .exhausted || status.health == .atRisk
                        || status.health == .wasting || status.wasteFraction > 0.05)
            }
            .sorted {
                if $0.1.health.urgency != $1.1.health.urgency {
                    return $0.1.health.urgency > $1.1.health.urgency
                }
                return $0.1.wasteFraction > $1.1.wasteFraction
            }
    }

    private var collaborationDigest: CollaborationDigest {
        CollaborationDigest(store.feeds["collaboration"])
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("团队控制台", systemImage: "gauge.with.dots.needle.67percent")
                        .font(.title3.bold())
                    Text(mood.teamMood)
                        .font(.caption)
                        .foregroundStyle(mood.tint)
                }

                taskSummary
                quotaSummary
                collaborationSummary
            }
            .padding(18)
        }
        .scrollIndicators(.hidden)
    }
    private var taskSummary: some View {
        let digest = store.taskDigest
        return VStack(alignment: .leading, spacing: 10) {
            Text("任务").font(.headline)
            HStack(spacing: 8) {
                dashboardMetric("在跑", digest.running.count, .blue)
                dashboardMetric("排队", digest.queued.count, .secondary)
                dashboardMetric("卡住", digest.blocked.count,
                                digest.blocked.isEmpty ? .secondary : .red)
            }
            if let current = digest.running.first {
                VStack(alignment: .leading, spacing: 3) {
                    Text(current.progressHeadline ?? current.title)
                        .font(.caption.weight(.semibold)).lineLimit(3)
                    if let next = current.progressNextStep, !next.isEmpty {
                        Text("下一步：" + next).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            } else if !digest.published {
                Text("还没收到任务板，当前是否有任务不知道。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var quotaSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("额度风险").font(.headline)
            if watchedQuota.isEmpty {
                Text("当前没有额度预警").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(watchedQuota.prefix(4)), id: \.1.id) { report, status in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(report.displayName).font(.caption.weight(.semibold))
                        Text(status.health.displayName)
                            .font(.caption2).foregroundStyle(statusColor(status.health))
                        Spacer()
                        if let used = status.usedFraction {
                            Text(Fmt.percent(used))
                                .font(.caption2.monospacedDigit())
                        }
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule().fill(statusColor(status.health))
                                .frame(width: max(3, geo.size.width
                                    * min(1, max(0, status.usedFraction ?? 0))))
                        }
                    }
                    .frame(height: 6)
                    HStack {
                        Text(status.label).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        if status.wasteFraction > 0.05, status.projectedWaste != nil {
                            Text("预计浪费 " + Fmt.percent(status.wasteFraction))
                                .font(.caption2.bold()).foregroundStyle(.orange)
                        }
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    /// iPad 控制台的协作摘要。
    ///
    /// 原来只是四行只读预览 —— 摘要说「有交流」，想看全文却要自己去
    /// 「更多」里翻。现在整块是一级入口，一键进完整时间线；
    /// 消费的和手机看板同一份 `store.feeds["collaboration"]`，
    /// 不存在第二套协作状态源。老服务端没发这一页时照样在、
    /// 照样能点，进去诚实说没有。
    @ViewBuilder
    private var collaborationSummary: some View {
        let digest = collaborationDigest
        NavigationLink {
            CollaborationTimelineView()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Agent 协作").font(.headline)
                    Spacer()
                    if digest.isReady, !digest.entries.isEmpty {
                        Text("最近 \(digest.entries.count)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if !digest.isReady {
                    Text(digest.entrySummary).font(.caption).foregroundStyle(.secondary)
                } else if digest.entries.isEmpty {
                    if let notice = digest.emptyNotice {
                        Text(notice.text ?? "还没有协作记录")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    } else {
                        Text("还没有协作记录").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(Array(digest.entries.prefix(3))) { entry in
                        collaborationRow(
                            title: entry.title,
                            detail: entry.direction
                                + (entry.pending ? " · 待回应" : ""),
                            icon: entry.icon ?? "arrow.triangle.branch",
                            tint: entry.tone.color)
                    }
                    if digest.entries.count > 3 {
                        Text("还有 \(digest.entries.count - 3) 条 · 点开看完整时间线")
                            .font(.caption2).foregroundStyle(.tint)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("rail-collaboration-link")
    }

    private func dashboardMetric(_ title: String, _ value: Int, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title3.monospacedDigit().bold()).foregroundStyle(tint)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private func collaborationRow(title: String, detail: String,
                                  icon: String, tint: Color = .accentColor) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold)).lineLimit(2)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func statusColor(_ health: Health) -> Color {
        switch health {
        case .exhausted, .atRisk: return .red
        case .wasting, .idle: return .orange
        default: return .green
        }
    }
}

/// 每个工位在办公室坐标系里的位置。
///
/// 为什么要采集真实坐标而不是按网格算：列宽随屏幕变、行高随内容变，
/// 算出来的位置在 iPad 和小屏 iPhone 上都会偏。而「走过去」这件事
/// 只要偏一点就很假 —— 人一眼就看出他没走到桌子那儿。
struct DeskAnchors: PreferenceKey {
    /// 工位坐标的键：**机器 + 平台**。
    ///
    /// 只用平台当键的话，同一个平台装在两台机器上时后者会覆盖前者，
    /// 信使就会走向错的那张桌子 —— 而且看起来完全正常，
    /// 只是「这个动画怎么老在另一台机器那边演」。
    static func key(_ machineID: String, _ platform: String) -> String {
        machineID + "|" + platform
    }
    static let defaultValue: [String: CGPoint] = [:]
    static func reduce(value: inout [String: CGPoint], nextValue: () -> [String: CGPoint]) {
        value.merge(nextValue()) { _, b in b }
    }
}

/// 一台机器的分节标题。
///
/// 加这个是因为**同一个平台可能装在两台机器上**，只按平台画一排的话，
/// 你看到一个「Kimi」却不知道它是哪台上的那个 ——
/// 而两台的额度、可用性、正在干的活都不一样。
private struct MachineHeader: View {
    /// nil = 那些对不上任何已知机器的工位。**不能默默丢掉它们** ——
    /// 那会让一个真实存在的 agent 从界面上消失，而消失是查不出来的。
    let machine: MachineInfo?
    /// 这台机器那块任务板怎么了。
    ///
    /// **这一节的桌子全空着时，光看画面分不出三件事**：他们真闲着、
    /// 板子冷了（上面的活是旧的，已经被挪出「正在干」）、还是板子读不到。
    /// 三件事的下一步完全不同，所以得在标题上说。
    var board: BoardStatus? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Circle()
                    .fill(machine.map { MachineHue.of($0.machineID) } ?? Color.secondary)
                    .frame(width: 8, height: 8)
                Text(machine?.displayName ?? "机器未知")
                    .font(.footnote.weight(.semibold))
                if let m = machine, m.isStale {
                    Text("离线").font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let note = boardNote {
                Text(note).font(.system(size: 9)).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private var boardNote: String? {
        guard let b = board else { return nil }
        if let why = b.unreadable {
            return "任务板读不到（\(why)）—— 这几张桌上有没有活，不知道"
        }
        guard b.isCold else { return nil }
        if let age = b.ageText {
            return "任务板 \(age)前更新过，之后就没动静 —— 桌上不画旧状态，"
                + "旧的那几件在「现在」页里"
        }
        return "任务板没说是什么时候的 —— 桌上不画来路不明的状态"
    }
}

/// 手机一次聚焦一台机器。十几个工位同时缩进三列虽然“都看见了”，
/// 但名字、任务和阻塞状态都读不清，实际等于什么也没看见。
private struct MachinePicker: View {
    let groups: [(machine: MachineInfo, staff: [PlatformReport])]
    @Binding var selectedMachineID: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(groups, id: \.machine.machineID) { group in
                    let selected = selectedMachineID == group.machine.machineID
                    Button {
                        selectedMachineID = group.machine.machineID
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(MachineHue.of(group.machine.machineID))
                                .frame(width: 7, height: 7)
                            Text(group.machine.displayName)
                                .lineLimit(1)
                            Text("\(group.staff.count)")
                                .foregroundStyle(selected ? .white.opacity(0.75) : .secondary)
                        }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .foregroundStyle(selected ? .white : .primary)
                        .background(selected ? Color.accentColor : Color.primary.opacity(0.07),
                                    in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
        }
    }
}

/// 每台机器一个稳定色调，让两台机器上的机器人一眼分得开。
///
/// 用 machineID 而不是机器名做种子：改个机器名不该让所有颜色都变，
/// 那会让人以为换了一批 agent。
enum MachineHue {
    static func of(_ machineID: String) -> Color {
        var h: UInt64 = 5381
        for b in machineID.utf8 { h = h &* 33 &+ UInt64(b) }
        // 避开红色区间：红在这个界面里表示出问题了，不能拿来当身份色。
        let hue = 0.12 + Double(h % 700) / 1000.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.85)
    }
}

/// 送件的机器人：从工位走到老板那儿，交接完再走回来。
///
/// 用户的原话是「领任务就走到分配那里领取，交任务成果的时候走过去上交」。
/// 静态的高亮/缩放表达不了「谁去了哪儿」，而这套界面的意义就是
/// 一眼看懂此刻谁在跟谁交接。
private struct Courier: View {
    let hue: Color
    var species: MascotSpecies = .robot
    let from: CGPoint
    let to: CGPoint
    /// 0 = 在工位，1 = 在老板那儿。
    let progress: Double
    let carrying: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var at: CGPoint {
        CGPoint(x: from.x + (to.x - from.x) * progress,
                y: from.y + (to.y - from.y) * progress)
    }

    var body: some View {
        ZStack {
            Mascot(state: .working, hue: hue, species: species, size: 34,
                   // 走路时手臂摆起来。静止的小人在移动，看着像在飘。
                   armSwing: reduceMotion ? 0 : (progress > 0.02 && progress < 0.98 ? 16 : 0))
            if carrying {
                Paper(tint: .green).offset(x: 15, y: -2)
            }
        }
        .position(at)
        .allowsHitTesting(false)
    }
}

// MARK: - 场景零件

/// 地板。用两层色带做出"地面往后延伸"的感觉，不画透视网格 ——
/// 网格线在小屏幕上很吵，而且和小人抢注意力。
private struct Floor: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [Color.primary.opacity(0.05), Color.primary.opacity(0.02)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 96)
            Rectangle().fill(Color.primary.opacity(0.03))
        }
        .ignoresSafeArea(edges: .bottom)
    }
}

/// 老板。派活时探身、答复时冒出对话框。
///
/// 「老板」在这套系统里不是拟人化的装饰 —— 它就是调度器：
/// 决定这个活派给谁的那段逻辑，以及你在手机上回答问题这件事。
private struct BossRow: View {
    /// 真实的指挥平台。**nil 时要说出来，别画个匿名的顶上** ——
    /// 一个没有身份的吉祥物在那儿，看的人分不清是「没配指挥」
    /// 还是「指挥闲着」。
    let boss: PlatformReport?
    let machineName: String?
    let dispatching: Bool
    let answering: Bool
    @State private var lean = false

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                Mascot(state: .working, hue: .accentColor, size: 44, activity: 0.8)
                    .rotationEffect(.degrees(dispatching && lean ? -7 : 0))
                    .animation(.easeInOut(duration: 0.35), value: lean)

                if answering {
                    Bubble(text: "回你了")
                        .offset(x: 34, y: -6)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            if let b = boss {
                Text(b.role?.title ?? "指挥").font(.caption2.weight(.medium))
                Text(b.agentName ?? b.platform)
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                if let machineName {
                    Text(machineName)
                        .font(.system(size: 8)).foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            } else {
                Text("没有指挥").font(.caption2).foregroundStyle(.secondary)
                Text("谁有额度谁上").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .onChange(of: dispatching) { _, v in
            guard v else { return }
            lean = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { lean = false }
        }
    }
}

/// 一排排的工位。
private struct DeskGrid: View {
    let staff: [PlatformReport]
    /// 这一格属于哪台机器。工位坐标要按「机器+平台」注册 ——
    /// 只按平台的话，同一个平台在两台机器上会互相覆盖，
    /// 信使就会走向错的那张桌子。
    let machineID: String
    /// 认领任务用的是**机器名**（任务里带的是名字，不是 ID）。
    /// nil = 这组桌子对不上任何已知机器，只能按平台认领。
    let machineName: String?
    let tasks: TaskDigest
    let event: OfficeEvent?
    let width: CGFloat
    let asking: [String: Ask]
    let traveling: OfficeView.Traveling?
    /// 每秒推进的当前时刻，透传给每张桌子算耗时。
    var now: Date = Date()
    let machine: MachineInfo?
    let events: [OfficeEvent]
    let asks: [Ask]
    let onTap: (PlatformReport) -> Void
    @State private var idleSince: [String: Date] = [:]

    private var activities: [OfficeActivity] {
        sortedStaff.map { report in
            OfficeActivity.resolve(report: report, machine: machine, tasks: tasks, asks: asks,
                                   events: events, idleSince: idleSince[report.platform], now: now)
        }
    }

    private var sharedBreak: OfficeActivity? {
        OfficeActivity.sharedBreak(activities: activities, idleStarts: sortedStaff.map { report in
            guard let machine else { return nil }
            return OfficeActivity.idleStart(report: report, machine: machine, events: events,
                                            observed: idleSince[report.platform], now: now)
        }, board: OfficeActivity.freshBoard(machine: machine, tasks: tasks, now: now),
        hasQuestions: asks.contains { $0.machineID == machineID }, now: now)
    }

    /// 这位是不是正在离席（去老板那儿的路上）。
    /// machineID 对得上才算：同一平台装在两台机器上时只空走的那台。
    /// 老事件缺机器来源时保留字幕，不猜测哪张桌子应该空出来。
    private func isAway(_ platform: String) -> Bool {
        guard let t = traveling, t.platform == platform else { return false }
        return !t.machineID.isEmpty && t.machineID == machineID
    }

    private var columns: [GridItem] {
        // 手机上两列，给名字和当前任务留出可读宽度；iPad 再铺开。
        //
        // **必须顶对齐。** 默认是居中，而自从桌上会写任务标题，
        // 同一排里有活的那格会高出两三行，居中会把旁边没活的人整个往下推 ——
        // 一排桌子高低错落，看着像渲染坏了。顶对齐之后桌面还在一条线上。
        let count = OfficePresentation.deskColumnCount(
            width: width, staffCount: staff.count)
        return Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
                     count: count)
    }

    private var sortedStaff: [PlatformReport] {
        staff.sorted { a, b in
            let aAsk = asking[a.platform] != nil
            let bAsk = asking[b.platform] != nil
            if aAsk != bAsk { return aAsk }
            let aTask = tasks.onDesk(
                platform: a.platform, machineID: machineID, machineName: machineName)
            let bTask = tasks.onDesk(
                platform: b.platform, machineID: machineID, machineName: machineName)
            if (aTask != nil) != (bTask != nil) { return aTask != nil }
            if let aTask, let bTask, aTask.isRunning != bTask.isRunning {
                return !aTask.isRunning
            }
            return a.last30dRequests > b.last30dRequests
        }
    }

    var body: some View {
        let moods = activities
        let pause = sharedBreak
        VStack(spacing: 8) {
        if let pause {
            Label("本机休息时间 · " + pause.label,
                  systemImage: pause == .stretching ? "figure.flexibility" : "cup.and.saucer")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
                .accessibilityIdentifier("office-shared-break-" + machineID)
        }
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(Array(sortedStaff.enumerated()), id: \.element.id) { index, r in
                let mood = moods[index].isIdle ? (pause ?? moods[index]) : moods[index]
                Button { onTap(r) } label: {
                    Desk(report: r, machineID: machineID, event: event,
                         activity: mood,
                         onDesk: tasks.onDesk(
                            platform: r.platform, machineID: machineID,
                            machineName: machineName),
                         queued: tasks.queuedCount(
                            platform: r.platform, machineID: machineID,
                            machineName: machineName),
                         hasPendingAsk: asking[r.platform] != nil,
                         away: isAway(r.platform),
                         roomy: width >= 800,
                         now: now)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("office-role-" + r.platform)
                .accessibilityLabel(r.displayName
                    + (asking[r.platform] == nil ? "，查看角色详情" : "，回答问题"))
                .accessibilityValue(mood.label)
            }
        }
        .padding(.horizontal, 8)
        }
        .onChange(of: Dictionary(uniqueKeysWithValues: zip(sortedStaff.map(\.platform), moods)), initial: true) { old, values in
            for report in sortedStaff {
                if values[report.platform]?.isIdle == true {
                    if let previous = old[report.platform], !previous.isIdle {
                        idleSince[report.platform] = now
                    } else if idleSince[report.platform] == nil, let machine {
                        idleSince[report.platform] = OfficeActivity.idleStart(
                            report: report, machine: machine, events: events, observed: nil, now: now) ?? now
                    }
                } else { idleSince[report.platform] = nil }
            }
        }
    }
}

/// 一个工位：桌子 + 坐在后面的人 + 桌上的活。
private struct Desk: View {
    /// 「3分12秒」这种给人看的耗时。超过一小时按小时说。
    static func elapsed(since: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(since)))
        if s < 60 { return "\(s)秒" }
        if s < 3600 { return "\(s / 60)分\(s % 60)秒" }
        return "\(s / 3600)时\((s % 3600) / 60)分"
    }

    let report: PlatformReport
    let machineID: String
    let event: OfficeEvent?
    let activity: OfficeActivity
    /// 他此刻手头这件活（在跑的，没有就是卡住的）。
    /// **桌上写出标题**正是这次要解决的事 —— 在这之前，
    /// 小人一直在动但看不出在干嘛，用户的原话是「看不到现在进行中的任务」。
    var onDesk: TaskBrief?
    /// 排在他后面还没开工的件数。
    var queued: Int = 0
    /// 他头上顶着一个还没被回答的问题。
    ///
    /// 和事件流里那个转瞬即逝的 `.asked` 不同：这个是**持续状态** ——
    /// 只要你没回答，他就一直举着手。这才是「有人在等你」该有的样子。
    var hasPendingAsk = false
    /// 正在去老板那儿的路上：座位空着，路上那个小人才是他。
    var away = false
    /// iPad 工位不能沿用手机字号，否则大屏只是把小组件隔得更远。
    var roomy = false
    /// 每秒推进的当前时刻，用来现算耗时（父视图统一驱动，
    /// 每张桌子各自开 timer 的话几十个一起跑，白费电）。
    var now: Date = Date()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var paperIn = false

    private var state: StaffState { StaffState.classify(report) }
    private var hue: Color { StaffHue.of(report.platform) }

    /// 当前这件事跟我有关系吗。
    private var role: Role {
        guard let e = event, !machineID.isEmpty, e.machineID == machineID else { return .none }
        let me = report.platform
        switch e.kind {
        case .dispatched where e.platform == me: return .receiving
        case .handoff where e.toPlatform == me:  return .receiving
        case .handoff where e.platform == me:    return .giving
        case .asked where e.platform == me:      return .asking
        case .finished where e.platform == me && activity == .celebrating: return .delivering
        case .exhausted where e.platform == me:  return .collapsing
        default: return .none
        }
    }

    enum Role { case none, receiving, giving, asking, delivering, collapsing }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // 人坐在桌子后面。离席（去老板那儿）时整个人隐掉 ——
                // 路上走的小人就是他，座位上再坐一个等于画了两遍。
                OfficeCharacter(activity: activity, quotaTint: state.tint, hue: hue,
                                species: MascotSpecies.pick(machineID: machineID, platform: report.platform),
                                size: roomy ? 58 : 46)
                    .offset(y: roomy ? 14 : 12)
                    .scaleEffect(role == .receiving ? 1.08 : 1, anchor: .bottom)
                    .animation(.spring(duration: 0.45), value: role)
                    .opacity(away ? 0 : 1)
                    .animation(.easeInOut(duration: 0.3), value: away)

                if role == .delivering {
                    Paper(tint: .green)
                        .offset(x: 24, y: paperIn ? -26 : -6)
                        .opacity(paperIn ? 0 : 1)
                        .animation(.easeOut(duration: 1.0), value: paperIn)
                }
            }
            .frame(height: roomy ? 86 : 72)
            .background(GeometryReader { g in
                Color.clear.preference(
                    key: DeskAnchors.self,
                    value: [DeskAnchors.key(machineID, report.platform):
                                CGPoint(x: g.frame(in: .named("office")).midX,
                                        y: g.frame(in: .named("office")).midY)])
            })

            // 桌面。**桌子带机器色，机器人保持平台身份色。**
            //
            // 不能反过来按机器给机器人上色 —— 那样同一台上的所有 agent
            // 会变成同一个颜色，「这是 Kimi 还是 Qwen」反而更分不清。
            // 身份归机器人，归属归桌子，两个维度各自可读。
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [hue.opacity(0.45), hue.opacity(0.28)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(height: 9)
                    .overlay(alignment: .bottom) {
                        // 桌沿那一条就是机器色。细，但两台机器并排时一眼分得开。
                        Rectangle()
                            .fill(machineID.isEmpty
                                  ? Color.secondary.opacity(0.4)
                                  : MachineHue.of(machineID))
                            .frame(height: 2.5)
                    }

                if role == .receiving || role == .giving {
                    // 位移限制在自己这一格里。原来收件时从 x:-30 起飞，
                    // 最左边那一列会被屏幕边缘裁掉半张纸。
                    Paper(tint: hue)
                        .offset(x: role == .receiving ? (paperIn ? 14 : 0) : (paperIn ? 30 : 14),
                                y: role == .receiving ? (paperIn ? -12 : -30) : -12)
                        .opacity(paperIn ? (role == .giving ? 0 : 1) : (role == .giving ? 1 : 0))
                        .animation(.easeInOut(duration: 0.9), value: paperIn)
                }
            }

            // 名字用 agent，不用模型 —— 干活的是 CLI。
            // 允许两行：「Claude Code · GLM」这种在三列布局里一行放不下。
            Text(report.displayName)
                .font(.system(size: roomy ? 14 : 12, weight: .semibold))
                .foregroundStyle(role == .none ? .secondary : .primary)
                .multilineTextAlignment(.center)
                .padding(.top, 3)
                .lineLimit(2)
                .minimumScaleFactor(0.85)

            // 岗位牌。桌子上最该有的就是这块牌子 ——
            // 「谁能接什么活」比「他现在忙不忙」更能解释调度为什么这么派。
            if let r = report.role {
                Text(r.title)
                    .font(.system(size: roomy ? 11 : 9, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(hue.opacity(0.18), in: Capsule())
                    .foregroundStyle(hue)
            }

            Text(state.pill)
                .font(.system(size: roomy ? 11 : 9))
                .foregroundStyle(state.tint)

            Text(activity.label)
                .font(.system(size: roomy ? 11 : 10, weight: .medium))
                .foregroundStyle(activity == .asking || activity == .blocked || activity == .failed ? .orange : .secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 2)

            // 手头这件活。
            //
            // 和上面那个额度 pill 不冲突：pill 说的是「他的额度状况」
            //（「产能闲置」= 这个窗口的额度快作废了），
            // 这里说的是「他此刻在干什么」。两件事都真，都得说。
            if let t = onDesk {
                HStack(spacing: 3) {
                    Circle().fill(taskTint(t)).frame(width: 4, height: 4)
                    // **秒表自己走，不等看板刷新。**
                    //
                    // 原来只显示状态词，而看板 30 秒才更新一次 ——
                    // 屏幕上那行字半分钟纹丝不动，看着就像卡死了
                    //（用户原话：「不显示实时的任务进度」）。
                    // 从 startedAt 现算耗时，每秒自增：哪怕数据没刷新，
                    // 也能一眼看出「他还在干，已经七分半了」。
                    if t.isRunning, let began = t.startedAt {
                        Text("在跑 " + Self.elapsed(since: began, now: now))
                            .font(.system(size: roomy ? 11 : 9, weight: .semibold)
                                .monospacedDigit())
                            .foregroundStyle(taskTint(t))
                    } else {
                        Text(t.stateLabel)
                            .font(.system(size: roomy ? 11 : 9, weight: .semibold))
                            .foregroundStyle(taskTint(t))
                    }
                }
                .padding(.top, 1)

                // 三列布局一格只有一百来点宽，标题封两行、允许略微缩放。
                // 标题在 Mac 端已经截到 80 字，这里再让它省略一次是防守。
                Text(t.title.isEmpty ? "（这条没有标题）" : t.title)
                    .font(.system(size: roomy ? 12 : 10))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 2)

                if let progress = t.progressHeadline {
                    Text(progress)
                        .font(.system(size: roomy ? 11 : 9, weight: .medium))
                        .foregroundStyle(.tint)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 2)
                }

                if let sub = taskSub(t) {
                    Text(sub).font(.system(size: roomy ? 10 : 8)).foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            if queued > 0 {
                Text("排队 \(queued)")
                    .font(.system(size: roomy ? 11 : 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .onChange(of: role) { _, v in
            guard v != .none, !reduceMotion else { return }
            paperIn = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { paperIn = true }
        }
        .onAppear { if hasPendingAsk, !reduceMotion { paperIn = true } }
    }

    /// 标题下面那一行：跑了多久 · 第几步。
    /// 一个都拿不到就整行不画，别留一条空行让人以为数据缺了。
    private func taskSub(_ t: TaskBrief) -> String? {
        let bits = [t.progressAgeText, t.elapsedText, t.stepText].compactMap { $0 }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    /// 卡住的用橙色 —— 它在桌上和「在跑」占同一个位置，
    /// 颜色一样的话，一眼扫过去会以为那件活正在动。
    private func taskTint(_ t: TaskBrief) -> Color {
        t.isRunning ? .green : .orange
    }
}

/// 动画时钟只重画小人；状态判断仍由办公室共用的低频时钟驱动。
private struct OfficeCharacter: View {
    let activity: OfficeActivity
    let quotaTint: Color
    let hue: Color
    let species: MascotSpecies
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false

    private var animated: Bool { visible && !reduceMotion && scenePhase == .active && activity != .unknown }
    private var expression: StaffState {
        switch activity {
        case .sleeping: return .dozing
        case .depleted: return .drained
        case .blocked, .failed: return .strained
        default: return .working
        }
    }
    private var pose: MascotPose {
        switch activity {
        case .asking, .celebrating: return .waving
        case .stretching: return .stretching
        case .sipping: return .sipping
        default: return .neutral
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !animated)) { context in
            let wave = animated ? sin(context.date.timeIntervalSince1970 * 2.5) : 0
            ZStack {
                if activity == .sleeping {
                    Capsule().fill(hue.opacity(0.15))
                        .frame(width: size * 1.35, height: 12)
                        .offset(y: size * 0.45)
                    RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.96))
                        .frame(width: 20, height: 12).rotationEffect(.degrees(-8))
                        .offset(x: -size * 0.42, y: size * 0.28)
                }
                Mascot(state: expression, hue: hue, species: species, size: size,
                       armSwing: activity == .working ? wave * 7 : 0,
                       pose: pose, gesture: wave, animates: animated, showsStatusAccessory: false,
                       statusTint: quotaTint)
                    .rotationEffect(.degrees(activity == .sleeping ? -78
                        : activity == .stretching ? wave * 5 : 0))
                    .offset(y: activity == .celebrating ? -abs(wave) * 4 : 0)
                    .opacity(activity == .unknown ? 0.55 : 1)
                if activity == .asking {
                    Text("?").font(.system(size: 19, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color(hex: 0x9B5900))
                        .frame(width: 26, height: 27)
                        .background(Color(hex: 0xFFF0C7), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .bottomLeading) {
                            Image(systemName: "arrowtriangle.down.fill").font(.system(size: 7))
                                .foregroundStyle(Color(hex: 0xFFF0C7)).offset(x: 5, y: 4)
                        }
                        .rotationEffect(.degrees(wave * 5))
                        .offset(x: size * 0.58, y: -size * 0.44 - wave * 2)
                }
                if activity == .celebrating {
                    Image(systemName: "star.fill").font(.system(size: 16))
                        .foregroundStyle(Color(hex: 0xE3A21A))
                        .rotationEffect(.degrees(wave * 12))
                        .offset(x: size * 0.62, y: -size * 0.4)
                }
                if activity == .sipping {
                    Image(systemName: "cup.and.saucer.fill").font(.system(size: 18))
                        .foregroundStyle(hue)
                        .offset(x: size * 0.48, y: size * 0.15 - wave)
                }
                if activity == .sleeping {
                    Text("z Z").font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .offset(x: size * 0.4, y: -size * 0.35 - wave * 2)
                }
                if activity == .blocked || activity == .failed || activity == .unknown || activity == .queued {
                    Image(systemName: activity == .failed ? "exclamationmark.bubble.fill"
                        : activity == .blocked ? "ellipsis.bubble.fill"
                        : activity == .unknown ? "icloud.slash" : "clock")
                        .font(.system(size: 13))
                        .foregroundStyle(activity == .blocked || activity == .failed ? .orange : .secondary)
                        .offset(x: size * 0.6, y: -size * 0.4)
                }
            }
        }
        .frame(width: size * 1.8, height: size * 1.1)
        .accessibilityHidden(true)
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }
}

/// 一张纸 —— 一件活。
private struct Paper: View {
    var tint: Color = .secondary
    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color(white: 0.98))
            .overlay(
                VStack(spacing: 1.5) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule().fill(tint.opacity(0.5)).frame(height: 1)
                    }
                }
                .padding(.horizontal, 2.5)
            )
            .overlay(RoundedRectangle(cornerRadius: 1.5)
                .stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
            .frame(width: 13, height: 16)
            .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
    }
}

private struct Bubble: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color(white: 0.98), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
            .foregroundStyle(.primary)
            .shadow(color: .black.opacity(0.1), radius: 1.5, y: 1)
    }
}

/// 底部那条字幕：最新发生的是哪件事。
///
/// 没有它的话，画面上纸飞来飞去但看不懂在干嘛 ——
/// 而这些事件全是真的，值得让人读到。
private struct EventCaption: View {
    let event: OfficeEvent
    let agentName: (String?) -> String
    let completion: TaskBrief.Known?

    private var icon: String {
        switch event.kind {
        case .dispatched: return "tray.and.arrow.down"
        case .handoff:    return "arrow.left.arrow.right"
        case .asked:      return "questionmark.bubble"
        case .answered:   return "checkmark.bubble"
        case .finished:
            return completion == .done ? "checkmark.seal"
                : completion == .failed ? "exclamationmark.circle" : "stop.circle"
        case .exhausted:  return "battery.0percent"
        case .idle:       return "zzz"
        case .other:      return "bell"
        }
    }
    private var tint: Color {
        switch event.kind {
        case .finished:  return completion == .done ? .green : completion == .failed ? .orange : .secondary
        case .exhausted: return .red
        case .asked:     return .orange
        default:         return .accentColor
        }
    }

    private var verb: String {
        guard event.kind == .finished else { return event.verb }
        return completion == .done ? "交活" : completion == .failed ? "本轮未完成" : "本轮结束"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).foregroundStyle(tint).font(.callout)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(who).font(.caption.weight(.semibold))
                    Text(verb).font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(tint.opacity(0.14), in: Capsule())
                        .foregroundStyle(tint)
                    Spacer()
                    Text(Fmt.relative(event.at)).font(.caption2).foregroundStyle(.secondary)
                }
                if !event.taskTitle.isEmpty {
                    Text(event.taskTitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(event.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(11)
        // 半透明：底下的办公室场景要能透出来。
        //
        // regularMaterial 太实，字幕像贴在画面上的一块板子，把工位挡住了 ——
        // 而这一块本来就是「浮在场景上的旁白」，不是独立的面板。
        // ultraThin + 一点点描边：既能读清字，又看得见下面谁在动。
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        .opacity(0.94)
    }

    private var who: String {
        let from = agentName(event.platform)
        if let t = event.toPlatform { return from + " → " + agentName(t) }
        return from
    }
}


// MARK: - 岗位说明书

/// 点开一张桌子看到的东西。
///
/// 重点不是「他现在忙不忙」（那个桌面上已经有了），
/// 而是**「调度凭什么把活派给他/不派给他」** —— 也就是这套岗位规则本身。
struct RoleCard: View {
    let report: PlatformReport
    var events: [OfficeEvent] = []
    /// 他手头的活。**跨机器全给** —— 这张卡是按平台开的，
    /// 只给点开的那台机器上的活，会漏掉他在另一台上正在跑的东西。
    /// 每行自己带机器名，不会混。
    var tasks: TaskDigest = .unpublished
    var onAssign: (() -> Void)?

    private var hue: Color { StaffHue.of(report.platform) }

    /// 他名下还没结束的活：在跑的、卡住的、排队的，外加状态不认识的。
    ///
    /// **冷板子上那些也算进来。** 漏掉的话，一台机器刚离线，
    /// 他手头三件活会在这张卡上变成「手头没活」—— 那三件并没有消失，
    /// 只是没人再报告它们了。`TaskLine` 会给每条标上「N 分钟前的状态」。
    private var live: [TaskBrief] {
        (tasks.live + tasks.unrecognized + tasks.cold)
            .filter { $0.platform == report.platform }
    }

    /// 他最近经手的事。用真实事件流，不编。
    private var mine: [OfficeEvent] {
        events.filter { $0.platform == report.platform || $0.toPlatform == report.platform }
            .suffix(6).reversed()
    }

    var body: some View {
        List {
            // 手头的活排在岗位说明前面：点开一个人，第一个问题永远是
            //「他现在在干嘛」，「他能接什么活」是第二个。
            if !tasks.published {
                Section {
                    Text("这台 Mac 没发来任务数据 —— 他手头有没有活，这里**不知道**。")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("手头的活") }
            } else if live.isEmpty, !tasks.unreadableBoards.isEmpty {
                // **有机器的板子读不到时，不能说「手头没活」。**
                //
                // 这张卡是跨机器的。乙机的板子只同步了半个文件读不出来，
                // 而他可能正在乙机上跑三件活 —— 这时候写「手头没活」是假话。
                // 正确答案是「读得到的机器上他没活，另外那台不知道」。
                //
                // 上面那段文档注释一字不差地描述了这个失败模式（冷板子那一半），
                // 而 RunningNow、AllQuietCard、MachineHeader、办公室横幅
                // 四处都加了这个保留意见 —— 只有这里漏了。
                // 「读不到」和「没有」说成同一句话，今天已经付过三次学费。
                Section {
                    Text("读得到的机器上他没活。另有 \(tasks.unreadableBoards.count) 台"
                        + "的任务板读不出来，那边有没有活**不知道**。")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("手头的活") }
            } else if live.isEmpty {
                Section {
                    Text("手头没活")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("手头的活") }
            } else {
                Section("手头的活") {
                    ForEach(live) { t in
                        TaskLine(task: t, name: { _ in report.displayName })
                    }
                }
            }

            if let role = report.role {
                Section("岗位") {
                    HStack {
                        Mascot(state: StaffState.classify(report), hue: hue, size: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(role.title).font(.title3.bold())
                            Text(report.displayName).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !role.note.isEmpty {
                        Text(role.note).font(.caption).foregroundStyle(.secondary)
                    }
                    NavigationLink {
                        RoleEditorView(report: report, role: role)
                    } label: {
                        Label("调整岗位规则", systemImage: "slider.horizontal.3")
                    }
                }

                Section {
                    RuleRow(icon: "exclamationmark.shield",
                            label: "最高能接",
                            value: role.riskLabel + "的活",
                            detail: riskExplain(role.maxRisk))
                    RuleRow(icon: "chart.bar",
                            label: "难度上限",
                            value: role.tierLabel ?? "交给学习器",
                            detail: role.maxTier == nil
                                ? "按它历史上成功完成过的最高档次自动判定"
                                : "人工设定，覆盖自动判定")
                    if !role.prefers.isEmpty {
                        RuleRow(icon: "hand.thumbsup",
                                label: "优先派给它",
                                value: role.prefersLabel + "的活",
                                detail: "只是加分，不是硬规定 —— 别人都忙时照样会派给它")
                    }
                    if !role.canEditFiles {
                        RuleRow(icon: "lock.doc", label: "改不了文件",
                                value: "只能文本进出",
                                detail: "所有需要改代码的任务都会跳过它")
                    }
                } header: {
                    Text("调度规则")
                } footer: {
                    Text("手机提交字段级修改，由 Mac 合并后在所有机器生效。指挥身份、机器静音和留白不会在这里改动。")
                }
            }

            if let onAssign {
                Section {
                    Button(action: onAssign) {
                        Label("点名让他干一件活", systemImage: "hand.point.right")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!(report.role?.canEditFiles ?? true))
                } footer: {
                    // 三目里的字符串会被推成 String，Text 就不解析 markdown 了 ——
                    // 那两个星号会原样上屏。拆成两个字面量各走各的。
                    if report.role?.canEditFiles ?? true {
                        Text("点名只是**优先**，不是命令：他要是过不了上面那些规则（比如这活太敏感），照样会换人，Mac 上会说明原因。")
                    } else {
                        // 原因也由 Mac 端给 —— 写死的话，等平台长出新能力，
                        // 这句话就变成谎话了（MiniMax 就这么骗了人好几周）。
                        Text(report.role?.cannotTakeWorkReason.isEmpty == false
                             ? report.role!.cannotTakeWorkReason
                             : "这个平台现在派不了活。")
                    }
                }
            }

            if !mine.isEmpty {
                Section("他最近经手的") {
                    ForEach(mine) { e in
                        HStack(alignment: .top, spacing: 8) {
                            Text(e.verb).font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(hue.opacity(0.14), in: Capsule())
                                .foregroundStyle(hue)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.taskTitle.isEmpty ? e.detail : e.taskTitle)
                                    .font(.caption).lineLimit(1)
                                Text(Fmt.relative(e.at)).font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("额度") {
                StaffRow(report: report, task: nil)
            }

            Section {
                LabeledContent("跑的可执行文件") { Text(report.agentBinary ?? "—").monospaced() }
                LabeledContent("额度算在") { Text(report.platformName) }
                LabeledContent("30 天用量") {
                    Text("\(report.last30dRequests) 次 · "
                         + Fmt.compact(report.last30dBillableTokens) + " token")
                }
            } footer: {
                if report.agentBinary == "claude" && report.platform != "claude" {
                    Text("它跑的是 Claude Code，但 ANTHROPIC_BASE_URL 指向别处 —— "
                         + "所以工具是同一个，烧的是另一份订阅。")
                }
            }
        }
    }

    private func riskExplain(_ r: String) -> String {
        switch r {
        case "safe": return "只动文档和测试"
        case "normal": return "可以动源码，但不碰构建配置"
        case "sensitive": return "构建配置、脚本、CI、依赖、权限位都能动"
        default: return ""
        }
    }
}

private struct RoleEditorView: View {
    @EnvironmentObject var store: Store

    let report: PlatformReport
    let role: AgentRole
    @State private var title: String
    @State private var maxRisk: String
    @State private var tierLimit: String
    @State private var prefers: Set<String>
    @State private var note: String
    @State private var submitting = false
    @State private var sent = false
    @State private var submitFailed = false

    private let tiers = ["trivial", "standard", "complex"]

    init(report: PlatformReport, role: AgentRole) {
        self.report = report
        self.role = role
        _title = State(initialValue: role.title)
        _maxRisk = State(initialValue: role.maxRisk)
        _tierLimit = State(initialValue: role.maxTier ?? "auto")
        _prefers = State(initialValue: Set(role.prefers))
        _note = State(initialValue: role.note)
    }

    private var changed: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines) != role.title
            || maxRisk != role.maxRisk
            || tierLimit != (role.maxTier ?? "auto")
            || prefers != Set(role.prefers)
            || note.trimmingCharacters(in: .whitespacesAndNewlines) != role.note
    }

    var body: some View {
        Form {
            Section("岗位") {
                TextField("岗位名", text: $title)
                    .accessibilityIdentifier("role-title-field")
                TextField("岗位说明（可选）", text: $note, axis: .vertical)
                    .lineLimit(2...4)
            }

            Section {
                Picker("最高风险", selection: $maxRisk) {
                    Text("低危").tag("safe")
                    Text("常规").tag("normal")
                    Text("高危").tag("sensitive")
                }
                Picker("难度上限", selection: $tierLimit) {
                    Text("自动学习").tag("auto")
                    ForEach(tiers, id: \.self) { tier in
                        Text(AgentRole.tierLabel(tier)).tag(tier)
                    }
                }
            } header: {
                Text("硬边界")
            } footer: {
                if maxRisk == "sensitive" {
                    Text("高危允许它修改构建配置、脚本、CI、依赖和权限位。")
                        .foregroundStyle(.orange)
                } else {
                    Text("超过这里的任务会换给有权限的角色，不会强行派发。")
                }
            }

            Section {
                ForEach(tiers, id: \.self) { tier in
                    Toggle(AgentRole.tierLabel(tier), isOn: preference(tier))
                }
            } header: {
                Text("优先接哪类任务")
            } footer: {
                Text("偏好只影响排序，不是硬限制；没有合适人选时仍可能接别的任务。")
            }

            Section {
                Button {
                    submit()
                } label: {
                    HStack {
                        Spacer()
                        if submitting { ProgressView() }
                        Text(sent ? "已送达 Mac" : "提交修改")
                        Spacer()
                    }
                }
                .disabled(!changed || submitting || sent)

                if sent {
                    Label("Mac 下一轮会合并到角色配置；刷新后可看到生效值。",
                          systemImage: "paperplane.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                } else if submitFailed, let error = store.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("这里只发送上面五项，不会覆写指挥身份、机器静音、留白或新版 Mac 增加的其他字段。")
            }
        }
        .navigationTitle(report.displayName + " · 岗位")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: title) { _, _ in sent = false }
        .onChange(of: maxRisk) { _, _ in sent = false }
        .onChange(of: tierLimit) { _, _ in sent = false }
        .onChange(of: note) { _, _ in sent = false }
    }

    private func preference(_ tier: String) -> Binding<Bool> {
        Binding(
            get: { prefers.contains(tier) },
            set: { enabled in
                if enabled { prefers.insert(tier) } else { prefers.remove(tier) }
                sent = false
            })
    }

    private func submit() {
        submitting = true
        submitFailed = false
        let ordered = tiers.filter(prefers.contains)
        Task {
            let ok = await store.updateRole(
                platform: report.platform, title: title, maxRisk: maxRisk,
                tierLimit: tierLimit, prefers: ordered, note: note)
            submitting = false
            sent = ok
            submitFailed = !ok
        }
    }
}

private struct RuleRow: View {
    let icon: String
    let label: String
    let value: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(label).font(.subheadline)
                    Spacer()
                    Text(value).font(.subheadline.weight(.medium))
                }
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 机器排序

/// 机器分节的显示顺序，拖一下就换。
///
/// 为什么让人排而不是程序猜：「主力」是人的判断 ——
/// 按名字排、按活跃度排、按加入先后排，都会有人觉得反了
///（用户原话：「我的 mac mini 是主力怎么放到了下面」）。
/// 顺序存本机（UserDefaults），办公室和计划清单共用。
struct MachineOrderSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    /// 编辑用的工作副本：已排的在前，没排过的机器按现状接在后面。
    @State private var ids: [String] = []

    private var names: [String: String] {
        Dictionary((store.dashboard?.machines ?? []).map {
            ($0.machineID, $0.displayName)
        }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(ids, id: \.self) { id in
                    HStack {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                        Text(names[id] ?? String(id.prefix(8)))
                        Spacer()
                        if ids.first == id {
                            Text("最上面").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .onMove { from, to in ids.move(fromOffsets: from, toOffset: to) }
                if ids.isEmpty {
                    Text("还没读到机器列表，先下拉刷新一次。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            // 常驻编辑模式：这张表**只是**用来拖的，还要先点「编辑」纯属绕路。
            .environment(\.editMode, .constant(.active))
            .navigationTitle("机器排序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("存") {
                        store.setMachineOrder(ids)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("算了") { dismiss() }
                }
            }
            .onAppear {
                ids = store.orderedByMachine(
                    (store.dashboard?.machines ?? []).map { $0.machineID },
                    id: { $0 })
            }
        }
    }
}
