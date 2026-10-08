import SwiftUI
import UniformTypeIdentifiers

@main
struct LLMQuotaApp: App {
    @StateObject private var store = Store()
    // SwiftUI 生命周期下拿 APNs device token 只有 app delegate 这一条路。
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(AppDelegate.push)
                .task {
                    AppDelegate.push.attachSharedRoot(store.rootURL)
                    AppDelegate.push.start()
                }
                .onChange(of: store.rootURL) { _, root in
                    // 首次启动常常先拿到 token、后选择文件夹；也可能运行中换目录。
                    // 每次连接变化都重新绑定并补写缓存的 token。
                    AppDelegate.push.attachSharedRoot(root)
                }
        }
    }
}

struct RootView: View {
    private enum Tab: Hashable { case now, office, board, more }

    @EnvironmentObject var store: Store
    @EnvironmentObject var push: PushRegistrar
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: Tab = .now
    /// 前台自动刷新。15 秒对齐 Mac 端节奏绰绰有余
    /// （镜像 30 秒推一轮，iCloud 传播还要几十秒）——
    /// 再密就只是空转电池。退后台时 SwiftUI 会停掉这个发布器，不用手动管。
    private let autoRefresh = Timer.publish(every: 15, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        Group {
            if store.isConnected || store.isDemo {
                // 三个标签页，不是五个。
                //
                // 原来五个是按**系统结构**切的（办公室/额度/任务/问题/派活），
                // 不是按**人的需要**切的：人真正要做的三件事
                //（回答挡住 agent 的问题、放行高危改动、看有没有额度在过期）
                // 散在三个页里，前两件甚至没有统一入口。
                //
                // 「现在」把它们收拢到一处，并且按**在漏什么**排序 ——
                // 而不是按平台罗列。额度/任务/派活退到「更多」里，
                // 它们是查阅用的，不是每天要看的。
                //
                // **办公室保留一等地位。** 评审按「能不能省额度」打分时
                // 把它排到了最后，但那套标准漏了一件事：
                // 用户会主动打开它 —— 而一个不被打开的 App 防浪费率是 0。
                TabView(selection: $selectedTab) {
                    NowView()
                        .tabItem { Label("现在", systemImage: "bolt.horizontal.circle") }
                        .badge(store.actionInbox.count)
                        .tag(Tab.now)
                    OfficeView()
                        .tabItem { Label("办公室", systemImage: "building.2") }
                        .tag(Tab.office)
                    BoardView()
                        .tabItem { Label("看板", systemImage: "gauge.with.dots.needle.67percent") }
                        .tag(Tab.board)
                    MoreView()
                        .tabItem { Label("更多", systemImage: "ellipsis.circle") }
                        .tag(Tab.more)
                }
            } else {
                ConnectView()
            }
        }
        // 演示横幅：**一眼看出这是假数据，一键退出。**
        //
        // 挂在最外层而不是 TabView 上 —— 挂在里面会和每个页面自己的
        // 大标题重叠（实测「演示数据」和「现在」两行字压在一起）。
        .task { await store.refresh() }
        // 「实时」的另一半：光会取最新版没用，还得有人**定期去取**。
        // 之前只有启动、下拉、手动按钮三个触发点 ——
        // 手机放在桌上看板永远停在打开那一刻。
        .onReceive(autoRefresh) { _ in store.reload() }
        // 从后台切回来立刻刷一次，别让人对着几小时前的数据等 15 秒。
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            store.reload()
            // 人可能刚去系统设置里开了通知 —— 回前台要重读，
            // 不然界面上还挂着「去开启」，而其实已经开好了。
            AppDelegate.push.refreshAuthorizationState()
        }
        .sheet(item: $push.destination) { target in
            NavigationStack {
                NotificationDetailView(target: target)
                    .id(target.id)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("关闭") { push.destination = nil }
                        }
                    }
            }
        }
    }
}

// MARK: - 首次连接

struct ConnectView: View {
    @EnvironmentObject var store: Store
    @State private var picking = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "externaldrive.badge.icloud")
                .font(.system(size: 54))
                .foregroundStyle(.tint)
            Text("连接到你的 Mac")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 10) {
                Text("选择 iCloud Drive 里的 **LLMQuotaBar** 文件夹。")
                // 明确指路。上一版只说「选 LLMQuotaBar」，
                // 而 iOS 的文件选择器默认可能停在「最近项目」或「我的 iPhone」，
                // 那里根本看不到 iCloud Drive —— 实际就卡在这一步。
                Text("点下面的按钮后：左上角「浏览」→「iCloud 云盘」→ LLMQuotaBar → 「打开」")
                    .foregroundStyle(.secondary)
                Text("如果列表里没有「iCloud 云盘」，去 设置 →〔你的名字〕→ iCloud → "
                    + "iCloud 云盘 打开它。")
                    .foregroundStyle(.secondary)
                Text("Mac 上的 llmq 把额度数据写在那里，任务也从那里取。只需要选一次。")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .frame(maxWidth: 340, alignment: .leading)

            Button {
                picking = true
            } label: {
                Label("选择文件夹", systemImage: "folder")
                    .frame(maxWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            // **还没连上也要能看到这个 App 在干什么。**
            //
            // 首屏要求选一个 iCloud 文件夹，而没装过 Mac 端的人
            //（包括 App Store 审核员）根本没有那个文件夹 —— 他们看到的
            // 是一个什么都点不动的空壳，于是「无法评估 App 功能」。
            Button("先看看效果（演示数据）") { store.enterDemo() }
                .font(.subheadline)
                .padding(.top, 2)

            if let e = store.lastError {
                Text(e).font(.footnote).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            Spacer()
        }
        .padding()
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { store.connect(to: url) }
        }
    }
}

// MARK: - 额度

struct QuotaView: View {
    @EnvironmentObject var store: Store

    private var active: [PlatformReport] {
        store.dashboard?.reports.filter(\.detected) ?? []
    }
    private var alerts: [QuotaStatus] {
        (store.dashboard?.reports.flatMap(\.statuses) ?? [])
            .filter { !$0.advisory && $0.isCurrent && $0.hasUsageValue
                && ($0.health == .wasting || $0.health == .atRisk || $0.health == .exhausted) }
            .sorted { $0.health.urgency > $1.health.urgency }
    }

    /// 按 30 天 token 用量从大到小 —— 「谁在吃大头」是这个总览要回答的问题。
    ///
    /// **不能只按 token/请求数筛。** MiniMax 走的是 API 不是 CLI，
    /// 本地没有会话日志可数，`last30dBillableTokens` 和 `last30dRequests`
    /// 恒为 0 —— 按用量筛会把它整个从额度明细里滤掉，而它恰恰是
    /// 空窗率最高、最该被看见的那个（周窗按当前速度会剩 85% 未用就清零）。
    /// 只要采到了额度窗口，就该出现在明细里。
    private var byUsage: [PlatformReport] {
        active.filter {
            $0.last30dBillableTokens > 0 || $0.last30dRequests > 0
                || !$0.statuses.isEmpty
        }
        .sorted { $0.last30dBillableTokens > $1.last30dBillableTokens }
    }
    private var totalTokens: Int { active.reduce(0) { $0 + $1.last30dBillableTokens } }
    private var totalRequests: Int { active.reduce(0) { $0 + $1.last30dRequests } }

    var body: some View {
        NavigationStack {
            List {
                // 连上了却什么都没读到 —— 给一个**显眼的**出口。
                //
                // 原来这种情况下整个列表是空的，而换文件夹的入口埋在右上角
                // 那个 ⋯ 菜单里。选错文件夹的人看到的是一片空白，
                // 想不到去菜单里找「断开文件夹」—— 实际就卡在这儿，
                // 反馈是「配置错误之后就找不到二次配置的地方了」。
                if store.dashboard == nil {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("没读到数据").font(.headline)
                            if let f = store.folderName {
                                Text("当前选的是「\(f)」").foregroundStyle(.secondary)
                            }
                            // 一整条字面量，别用 + 拼：拼出来的是 String，
                            // Text 就不解析 markdown 了，屏幕上会原样出现两个星号。
                            Text("""
                                 要选的是 iCloud 云盘根目录下的 **LLMQuotaBar**，\
                                 里面应该有 snapshots、config 这些文件夹。
                                 """)
                                .font(.callout).foregroundStyle(.secondary)
                            Button {
                                store.disconnect()
                            } label: {
                                Label("重新选择文件夹", systemImage: "folder.badge.gearshape")
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 2)
                        }
                        .padding(.vertical, 6)
                    }
                }

                if !alerts.isEmpty {
                    Section("需要注意") {
                        ForEach(alerts) { s in AlertRow(status: s) }
                    }
                }

                // 用量总览。
                //
                // 这个 App 最初的需求就是「统一看所有平台的用量」——
                // 而首页改版成漏损视角之后，token 数量只剩每张平台卡最底下
                // 一行三级灰字，用户的原话是「怎么没有了」。
                // 数据一直都在，是被藏没的。放回最显眼的位置。
                //
                // 只加总 token **数量**，不加总钱：各家币种和单价不同，
                // 跨币种相加是这个项目明确不做的事（Money 类型就是为此存在的）。
                if !active.isEmpty, totalTokens > 0 {
                    Section("用量 · 最近 30 天") {
                        HStack(alignment: .firstTextBaseline) {
                            Text(Fmt.compact(totalTokens))
                                .font(.title2.bold().monospacedDigit())
                            Text("token · \(totalRequests) 次调用")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                        ForEach(byUsage) { r in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(r.displayName).font(.subheadline)
                                    Spacer()
                                    // **「0 token」和「数不出来」是两回事。**
                                    //
                                    // MiniMax 走 API 不写会话日志，`mmx quota show`
                                    // 只报剩余百分比、不给 token 计数 —— 那个 0
                                    // 不是「没在用」，是这条路子根本数不出来。
                                    // 显示成 0 会让人以为它闲着，而它其实一直在生图。
                                    if r.last30dBillableTokens == 0
                                        && r.last30dRequests == 0 {
                                        Text("官方只报剩余额度")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    } else {
                                        Text(Fmt.compact(r.last30dBillableTokens) + " token")
                                            .font(.caption.monospacedDigit())
                                        Text("\(r.last30dRequests) 次")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                // 数不出 token 的平台，把它的额度窗口直接摆出来 ——
                                // 这才是它身上唯一有意义的数字。
                                if r.last30dBillableTokens == 0, r.last30dRequests == 0 {
                                    ForEach(r.statuses) { st in
                                        HStack {
                                            Text(st.label)
                                                .font(.caption2).foregroundStyle(.secondary)
                                            Spacer()
                                            if let f = st.displayUsedFraction {
                                                Text("已用 " + Fmt.percent(f))
                                                    .font(.caption2.monospacedDigit())
                                            } else {
                                                Text(st.isFresh() ? "额度未知" : "数据已过期")
                                                    .font(.caption2).foregroundStyle(.secondary)
                                            }
                                            if let rs = st.resetsAt, st.isFresh() {
                                                Text(Fmt.duration(rs.timeIntervalSinceNow)
                                                     + "后重置")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                                // 条形图：占全部用量的比例。谁在吃大头一眼可见。
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.secondary.opacity(0.15))
                                        Capsule().fill(Color.accentColor)
                                            .frame(width: max(2, geo.size.width
                                                * CGFloat(r.last30dBillableTokens)
                                                / CGFloat(max(1, totalTokens))))
                                    }
                                }
                                .frame(height: 4)
                            }
                            .padding(.vertical, 1)
                        }
                    }
                }

                if !active.isEmpty {
                    Section("平台") {
                        ForEach(active) { r in PlatformRow(report: r) }
                    }
                }

                if let d = store.dashboard {
                    Section("设备") {
                        ForEach(d.machines) { m in
                            HStack {
                                Circle()
                                    .fill(m.isStale ? Color.orange : Color.green)
                                    .frame(width: 8)
                                Text(m.displayName)
                                Spacer()
                                Text(Fmt.relative(m.lastSeen))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            Text("数据时间").foregroundStyle(.secondary)
                            Spacer()
                            Text(Fmt.relative(d.generatedAt))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if let e = store.lastError {
                    Section { Text(e).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("额度")
            .refreshable { await store.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("刷新") { store.reload() }
                        Button("断开文件夹", role: .destructive) { store.disconnect() }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
    }
}

struct AlertRow: View {
    let status: QuotaStatus

    private var tint: Color {
        switch status.health {
        case .wasting: return .orange
        case .atRisk, .exhausted: return .red
        default: return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.health == .wasting
                  ? "arrow.down.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(PlatformNames.map[status.platform] ?? status.platform) · \(status.label)")
                    .font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var detail: String {
        switch status.health {
        case .wasting:
            // 同一个概念一处实现：见 QuotaStatus.wasteFraction
            let left = status.projectedUsedFraction != nil
                ? Optional(status.wasteFraction) : nil
            return "按当前速度还会剩 \(Fmt.percent(left)) 用不完，"
                + "\(Fmt.duration(status.timeToReset))后清零"
        case .exhausted:
            return "已用尽，\(Fmt.duration(status.timeToReset))后重置"
        case .atRisk:
            // 说清这是**烧速外推**不是当前已超：27% 也可能被标预警。
            // 调度器逼近留白线会自动让位，这条是提醒人，不是要人干预。
            return "烧速预警：已用 \(Fmt.percent(status.usedFraction))，"
                + "按最近速度到重置时约 \(Fmt.percent(status.projectedUsedFraction))"
                + "（调度器碰到留白线会自动让位）"
        default:
            return status.sourceNote
        }
    }
}

struct PlatformRow: View {
    let report: PlatformReport

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(report.displayName).font(.headline)
                Text(report.planName).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text(Fmt.relative(report.lastActivity))
                    .font(.caption2).foregroundStyle(.secondary)
            }

            ForEach(report.statuses) { s in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(s.label).font(.caption).frame(width: 100, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.1))
                                if let f = s.displayUsedFraction {
                                    Capsule().fill(color(for: s))
                                        .frame(width: max(2, geo.size.width * min(1, max(0, f))))
                                }
                            }
                        }
                        .frame(height: 6)
                        Text(s.displayUsedFraction.map { Fmt.percent($0) }
                             ?? (s.isFresh() ? "上限未知" : "已过期"))
                            .font(.caption.monospacedDigit())
                            .frame(width: 64, alignment: .trailing)
                    }
                    HStack(spacing: 6) {
                        Text(s.usageText)
                        if !s.isFresh() { Text("数据已过期") }
                        if s.advisory { Text("独立额度") }
                        if s.isOfficial && s.hasUsageValue && s.sourceKind != "unknown" {
                            Text(s.isFresh() ? "平台直报" : "历史回报")
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.15),
                                            in: RoundedRectangle(cornerRadius: 3))
                        }
                        if let left = s.remainingValue {
                            Text("· 剩余 " + Fmt.metricValue(left, metric: s.metric))
                        } else if let left = s.remainingFraction {
                            Text("· 剩余 " + Fmt.percent(left))
                        }
                        Spacer()
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.leading, 108)

                    if let badge = s.estimationBadge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 4))
                            .padding(.leading, 108)
                    }

                    HStack(spacing: 6) {
                        if let projected = s.projectedRemainingFraction {
                            Text("按当前速度，重置时预计剩余 " + Fmt.percent(projected))
                        } else if let floor = s.observedFloor {
                            Text("历史单窗最高 " + Fmt.metricValue(floor, metric: s.metric)
                                 + " · 当前剩余未知")
                        } else if s.limit != nil {
                            Text("样本不足，暂不预测重置时余量")
                        } else {
                            Text("暂无可换算的额度上限")
                        }
                        Spacer()
                        if s.isFresh(), let t = s.timeToReset, t > 0 {
                            Text("\(Fmt.duration(t))后重置")
                        }
                    }
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.leading, 108)
                }
            }

            Text("30 天 \(report.last30dRequests) 次 · \(Fmt.compact(report.last30dBillableTokens)) token")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }

    private func color(for s: QuotaStatus) -> Color {
        switch s.effectiveHealth {
        case .wasting: return .orange
        case .atRisk, .exhausted: return .red
        case .idle, .unconfigured, .unknown: return .secondary
        case .healthy: return .green
        }
    }
}

// MARK: - 任务

struct TasksView: View {
    @EnvironmentObject var store: Store
    @State private var showOlder = false
    private let initialResultLimit = 30

    var body: some View {
        NavigationStack {
            List {
                if store.results.isEmpty {
                    ContentUnavailableView(
                        "还没有任务", systemImage: "tray",
                        description: Text("在「派活」里投一个，Mac 上的循环会捞走执行"))
                }
                ForEach(showOlder ? store.results : Array(store.results.prefix(initialResultLimit))) {
                    r in
                    NavigationLink { TaskResultDetail(result: r) } label: {
                        TaskRow(result: r)
                    }
                }
                if !showOlder && store.results.count > initialResultLimit {
                    Button("显示更早的 \(store.results.count - initialResultLimit) 条") {
                        showOlder = true
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("任务")
            .refreshable { await store.refresh() }
        }
    }
}

struct TaskRow: View {
    let result: TaskResult

    private var icon: (String, Color) {
        if result.isDone { return ("checkmark.circle.fill", .green) }
        if result.isFailed { return ("xmark.circle.fill", .red) }
        if result.isRunning { return ("circle.dotted", .orange) }
        return ("clock", .secondary)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon.0).foregroundStyle(icon.1)
            VStack(alignment: .leading, spacing: 4) {
                Text(result.prompt)
                    .font(.subheadline).lineLimit(3)
                HStack(spacing: 6) {
                    if let p = result.platform {
                        Text(PlatformNames.map[p] ?? p)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 3))
                    }
                    Text(Fmt.relative(result.updatedAt))
                    if let n = result.changedFiles, n > 0 { Text("改了 \(n) 个文件") }
                }
                .font(.caption2).foregroundStyle(.secondary)
                if !result.note.isEmpty {
                    Text(result.note).font(.caption2)
                        .foregroundStyle(result.isFailed ? .red : .secondary)
                        .lineLimit(3)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct TaskResultDetail: View {
    let result: TaskResult

    var body: some View {
        List {
            Section("状态") {
                LabeledContent("结果", value: stateName)
                LabeledContent("任务编号", value: result.taskID)
                LabeledContent("更新时间", value: Fmt.relative(result.updatedAt))
                if let platform = result.platform {
                    LabeledContent("Agent", value: PlatformNames.map[platform] ?? platform)
                }
                if let branch = result.branch, !branch.isEmpty {
                    LabeledContent("分支", value: branch)
                }
                if let changed = result.changedFiles {
                    LabeledContent("改动文件", value: "\(changed) 个")
                }
            }
            Section("任务") {
                Text(result.prompt).textSelection(.enabled)
            }
            Section("结果说明") {
                if result.note.isEmpty {
                    Text("Mac 没有附带结果说明").foregroundStyle(.secondary)
                } else {
                    Text(result.note).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("任务详情")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var stateName: String {
        switch result.state {
        case "done": return "已完成"
        case "failed": return "失败"
        case "running": return "执行中"
        case "queued": return "排队中"
        case "blocked": return "已卡住"
        default: return result.state
        }
    }
}

// MARK: - 派活

struct SubmitView: View {
    @EnvironmentObject var store: Store
    /// 从办公室点某张桌子进来时，指定的那个人。
    var assignTo: PlatformReport?
    @State private var text = ""
    @State private var repo: String?
    /// 多台机器都有这个仓库时，用户点名的那台（nil = 随便谁）。
    @State private var targetMachine: String?
    @FocusState private var focused: Bool

    private var selectedRepo: RepoItem? {
        store.repos.first { $0.alias == repo }
    }

    private var selectedMachineSelector: String? {
        if let selectedRepo, selectedRepo.machines.count == 1 {
            return selectedRepo.machines[0]
        }
        return targetMachine
    }

    /// 最终点名的机器：仓库唯一归属 > 用户手选。
    /// Repo 的键可能是 machineID/nodeName/历史机器名，必须先解析成稳定 ID；
    /// 只按名称取第一台会把同名 MacBook 的任务投错机器。
    private var resolvedMachine: (id: String?, name: String?) {
        guard let selector = selectedMachineSelector else { return (nil, nil) }
        guard let machine = MachineInfo.resolve(
            selector: selector, among: store.dashboard?.machines ?? [])
        else { return (nil, nil) }
        return (machine.machineID, machine.machineName)
    }

    private var machineSelectionError: String? {
        guard let selector = selectedMachineSelector else { return nil }
        let machines = store.dashboard?.machines ?? []
        guard MachineInfo.resolve(selector: selector, among: machines) == nil else { return nil }
        if MachineInfo.selectorIsAmbiguous(selector, among: machines) {
            return "旧配置里的「\(machineNameForDisplay(selector))」对应多台同名电脑，已阻止猜测投递。请等 Mac 用稳定机器 ID 刷新仓库配置后再选。"
        }
        return "目标机器尚未出现在最新集群状态中，已阻止无目标投递。"
    }

    private func displayMachine(_ raw: String) -> String {
        let machines = store.dashboard?.machines ?? []
        if let machine = MachineInfo.resolve(selector: raw, among: machines) {
            return machine.displayName
        }
        let suffix = MachineInfo.selectorIsAmbiguous(raw, among: machines)
            ? "（同名，待刷新）" : ""
        return machineNameForDisplay(raw) + suffix
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("任务描述") {
                    TextEditor(text: $text)
                        .frame(minHeight: 170)
                        .focused($focused)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("要 Mac 上的 agent 做什么？\n写清楚改哪个文件、做完的标准是什么。")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8).padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                if !store.repos.isEmpty {
                    Section("仓库") {
                        // 每个仓库标出它在哪几台机器上有目录 ——
                        // 不同电脑的目录不再混成一张不知谁是谁的平面清单。
                        Picker("仓库", selection: $repo) {
                            ForEach(store.repos) { r in
                                Text(r.alias
                                     + (r.isDefault ? "（默认）" : "")
                                     + (r.machines.isEmpty ? ""
                                        : " · " + r.machines.map(displayMachine)
                                            .joined(separator: "、")))
                                    .tag(Optional(r.alias))
                            }
                        }
                        .pickerStyle(.menu)
                        if let sel = selectedRepo {
                            if sel.machines.count == 1 {
                                Label("这个仓库只在「\(displayMachine(sel.machines[0]))」上有目录，任务会点名给它",
                                      systemImage: "desktopcomputer")
                                    .font(.caption2).foregroundStyle(.secondary)
                            } else if sel.machines.count > 1 {
                                Picker("哪台机器干", selection: $targetMachine) {
                                    Text("哪台有空哪台干").tag(String?.none)
                                    ForEach(sel.machines, id: \.self) { m in
                                        Text(displayMachine(m)).tag(Optional(m))
                                    }
                                }
                                .pickerStyle(.menu)
                            } else {
                                Text("旧版数据没带机器信息 —— 任务会被先抢到的机器执行")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            if let machineSelectionError {
                                Label(machineSelectionError, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }
                }

                if let who = assignTo {
                    Section("点名给") {
                        HStack {
                            Text(who.displayName)
                            if let r = who.role {
                                Text(r.title).font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.primary.opacity(0.08), in: Capsule())
                            }
                        }
                    }
                }

                Section {
                    Button {
                        focused = false
                        let m = resolvedMachine
                        Task {
                            if await store.submit(
                                prompt: text, repo: repo, platform: assignTo?.platform,
                                machineID: m.id, machineName: m.name) != nil {
                                text = ""
                            }
                        }
                    } label: {
                        Label("投进收件箱", systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).count < 8
                        || machineSelectionError != nil)
                } footer: {
                    Text("先写进共享收件箱；Mac 领取后再分诊和选择 Agent。下方回执会区分“已写入”和“已领取”。")
                }

                if let receipt = store.lastSubmissionReceipt {
                    SubmissionReceiptSection(receipt: receipt)
                }

                if let e = store.lastError {
                    Section { Text(e).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("派活")
            .onAppear {
                if repo == nil { repo = store.repos.first(where: \.isDefault)?.alias }
            }
            .onChange(of: repo) { _, _ in targetMachine = nil }
        }
    }
}

private struct SubmissionReceiptSection: View {
    @EnvironmentObject var store: Store
    let receipt: SubmissionReceipt

    private var result: TaskResult? { store.result(for: receipt) }

    private func displayMachine(_ raw: String) -> String {
        MachineInfo.resolve(selector: raw, among: store.dashboard?.machines ?? [])?.displayName
            ?? machineNameForDisplay(raw)
    }

    var body: some View {
        Section("最近一次投递") {
            LabeledContent("投递编号", value: receipt.shortID)
            LabeledContent("时间", value: Fmt.relative(receipt.submittedAt))
            if let repo = receipt.repo { LabeledContent("仓库", value: repo) }
            if let selector = receipt.machineID ?? receipt.machineName {
                LabeledContent("目标机器", value: displayMachine(selector))
            } else {
                LabeledContent("目标机器", value: "任一可用机器")
            }
            if let result {
                let style = statusStyle(result)
                Label(style.text, systemImage: style.icon)
                    .foregroundStyle(style.color)
                NavigationLink("查看任务详情") { TaskResultDetail(result: result) }
            } else if store.submissionIsWaiting(receipt) == true {
                Label("已写入共享收件箱，等待 Mac 领取", systemImage: "tray.and.arrow.down")
                    .foregroundStyle(.blue)
            } else if store.submissionIsWaiting(receipt) == false {
                Label("Mac 已领取，正在建立任务", systemImage: "desktopcomputer")
                    .foregroundStyle(.orange)
            } else {
                Label("连接已断开，暂时无法确认领取状态", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
            Button("刷新状态") { store.reload() }
        }
    }

    private func statusStyle(_ result: TaskResult) -> (text: String, icon: String, color: Color) {
        switch result.state {
        case "done": return ("任务已完成", "checkmark.circle.fill", .green)
        case "failed": return ("Mac 已领取，任务失败", "xmark.circle.fill", .red)
        case "queued": return ("Mac 已领取，任务已排队", "clock.fill", .blue)
        case "running": return ("Mac 已领取，任务执行中", "circle.dotted", .orange)
        case "blocked": return ("Mac 已领取，任务被卡住",
                                "exclamationmark.octagon.fill", .orange)
        default: return ("Mac 已领取，状态：\(result.state)", "questionmark.circle", .secondary)
        }
    }
}


/// 查阅用的东西收在这里 —— 它们每天不需要看，但需要的时候得找得到。
struct MoreView: View {
    @EnvironmentObject var store: Store

    private var reviewCount: Int { store.actionInbox.reviews.count }

    var body: some View {
        NavigationStack {
            List {
                Section("常用") {
                    NavigationLink {
                        ReviewView()
                    } label: {
                        Label("成果复核", systemImage: "checkmark.seal")
                    }
                    .badge(reviewCount)
                    NavigationLink { QuotaView() } label: {
                        Label("额度与用量", systemImage: "gauge.with.dots.needle.33percent")
                    }
                    NavigationLink { TasksView() } label: {
                        Label("任务记录", systemImage: "list.bullet.rectangle")
                    }
                    NavigationLink { SubmitView() } label: {
                        Label("派新任务", systemImage: "paperplane")
                    }
                }

                Section {
                    NavigationLink { SettingsView() } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                }

                // 服务端下发的入口。**加一个新功能不用发版**：
                // Mac 端加一个 views/xxx.json 再在菜单里指过去就行。
                if let menu = store.menu, !menu.entries.isEmpty, !store.isDemo {
                    // **同一件事只留一个入口。**
                    //
                    // 上面「查阅」里已经有原生的「等你验收」「项目清单」,而 Mac 的下发菜单
                    // 里也各有一条同名入口 —— 于是「更多」页里同一个名字出现两次,点哪个
                    // 都对、看到的东西还不完全一样(原生页有证据缩略图和合入/丢弃按钮,
                    // 下发页只有通用区块)。老板反复报的「点进去就没有了」里,有一部分
                    // 就是点到了另一个入口。原生页更全,下发的这两条隐掉。
                    //
                    // 哪天原生页不做了,把对应的 page 从这个集合里删掉,下发入口自动回来。
                    let nativePages: Set<String> = [
                        "review", "playbook", "blocked", "collaboration", "roadmap",
                    ]
                    ForEach(menu.groups(excluding: nativePages)) { group in
                        Section(group.title) {
                            ForEach(group.entries) { e in
                                NavigationLink {
                                    FeedPageView(page: e.page, title: e.title,
                                                 allowsActions: false)
                                } label: {
                                    Label(e.title, systemImage: e.icon ?? "square.grid.2x2")
                                        .badge(e.badge ?? 0)
                                }
                            }
                        }
                    }
                }

            }
            .navigationTitle("更多")
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var push: PushRegistrar
    @State private var confirmDisconnect = false

    var body: some View {
        List {
            Section {
                LabeledContent("文件夹", value: store.folderName ?? "没连")
                Button("重新选择文件夹", role: .destructive) {
                    confirmDisconnect = true
                }
            } header: {
                Text("连接")
            } footer: {
                Text("重新选择会断开当前目录，返回连接页重新授权。")
            }

            Section {
                if push.authorized {
                    LabeledContent("状态", value: "已开启")
                } else if push.asked {
                    LabeledContent("状态", value: "已关闭")
                    Button("去系统设置里开启") { push.openSystemSettings() }
                } else {
                    Button("开启通知") {
                        Task { _ = await push.requestAuthorization() }
                    }
                }
            } header: {
                Text("通知")
            } footer: {
                Text("只在需要你做决定时通知；同类两小时内不重复。")
            }

            Section {
                NavigationLink { ReserveView() } label: {
                    Label("Agent 可用额度", systemImage: "hand.raised")
                }
            } header: {
                Text("调度")
            } footer: {
                Text("设置每个平台要留给你自己使用的额度。")
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .alert("重新选择文件夹？", isPresented: $confirmDisconnect) {
            Button("取消", role: .cancel) { }
            Button("断开并重新选择", role: .destructive) { store.disconnect() }
        } message: {
            Text("当前连接会断开，但不会删除共享目录里的任何数据。")
        }
    }
}
