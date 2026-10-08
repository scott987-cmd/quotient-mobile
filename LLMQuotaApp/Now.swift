import SwiftUI

func shouldShowAllQuiet(bleedingCount: Int, askCount: Int,
                        pendingProjectCount: Int, reviewCount: Int = 0,
                        plannedCount: Int = 0) -> Bool {
    bleedingCount == 0 && askCount == 0 && pendingProjectCount == 0
        && reviewCount == 0 && plannedCount == 0
}

/// 首页：**要你干什么，以及在浪费什么**。
///
/// ## 为什么重做
///
/// 原来五个标签页（办公室 / 额度 / 任务 / 问题 / 派活）是按**系统结构**切的，
/// 不是按**人的需要**切的。人在手机上真正要做的只有三件：
/// 回答挡住 agent 的问题、放行或否决高危改动、看有没有额度在白白过期。
/// 这三件散在三个页里，前两件甚至没有统一入口。
///
/// 而办公室 —— 最漂亮、信息密度最低的那个 —— 是首页。
/// 它回答「系统在干什么」，而人打开手机时想知道的是「要我干什么」。
///
/// ## 为什么排序键不是倒计时
///
/// **紧迫 ≠ 重要。** 一个 20 分钟后清零但已经用了 96% 的窗口，
/// 和一个两天后清零、已经连续空了 19 个的窗口，后者才是真在流血。
/// 按 resetsAt 排会让前者一直霸占头条。
///
/// ## 为什么排序键也不是「还会浪费多少」
///
/// 那个数需要上限，而**实测 13 个额度窗口里只有 3 个有上限**，
/// 其余全是 unconfigured，而且填不得（GLM 公布积分口径对不上、
/// Kimi 和 Claude 不公布）。照那个做，主轴上会只剩三条，
/// 其余全掉进「算不出来」的折叠区 —— 一个几乎空着的主界面。
///
/// 所以用**空窗**：一个完整过去的窗口，期间一次调用都没有。
/// 这跟天花板是多少完全无关，而它照样是明确的损失。
struct NowView: View {
    /// 等过目的项目方案。放在「挡住了」里 ——
    /// 没批的项目一条活都不会被取用，它挡住的是整条自动化。
    private var pendingProjects: [PlaybookProject] {
        store.actionInbox.projects
    }

    private var plannedCount: Int {
        store.actionInbox.plannedCount
    }

    @EnvironmentObject var store: Store
    @EnvironmentObject var push: PushRegistrar
    @State private var composing: PlatformReport?
    @State private var answering: Ask?
    @State private var showOffice = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    FreshnessBar(dashboard: store.dashboard)

                    // **服务端下发了就用下发的。**
                    //
                    // 这一页的判断最多（什么算在漏、怎么排、写什么提示语），
                    // 而这些正是变得最快的东西 —— 一天之内改过三次
                    // 「什么算待验收」。搬到 Mac 端之后，改它们不用重新上架。
                    //
                    // 没下发时退回内置画法：演示模式、或者 Mac 端还没升级，
                    // 都得能用。
                    //
                    // ── 为什么改成「追加」而不是「顶替」
                    //
                    // 原来是「有下发就整页交给通用渲染器」。而下发那版只组装了
                    // 「在漏的」和「等你验收」两块 —— 于是在跑的任务、员工那一行、
                    // 挡住了、冷却说明全部消失，页面还变丑了。
                    //「为啥手机端看不到现在进行中的任务」这个问题被重新做了一遍。
                    //
                    // 顶替的前提是**下发装得下这一页原来显示的全部东西**。
                    // 五种区块表达不了那张「正在干」的大卡和头像行，所以装不下。
                    //
                    // 追加就没有这个前提：服务端仍然可以不发版往这页加东西，
                    // 但它**拿不走已经在的**。少发一个文件最多是少一块，
                    // 不会把一整页换成更差的一页。
                    if store.dashboard == nil {
                        if store.taskDigest.published || store.actionInbox.count > 0 {
                            Text("额度数据暂未同步，任务和待办仍可查看")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            NoDataCard(store: store)
                        }
                    }
                    Group {
                        // 「现在在干什么」排在最上面 —— 这是打开 App 第一眼要的答案。
                        //
                        // 在这之前，这一屏上关于「正在干嘛」的唯一线索是办公室里
                        // 那些小人的动作，而那是按**用量活跃度推**出来的，
                        // 不是真的任务记录。用户的原话：「为啥手机端看不到
                        // 现在进行中的任务」——因为这份数据以前根本没发过来。
                        RunningNow(digest: store.taskDigest, name: { self.name(for: $0) })
                        if store.taskDigest.published {
                            DeliveryStatusCard(digest: store.taskDigest)
                        }
                        DeskStrip(reports: workers, onOpen: { showOffice = true })
                        LeakBoard(reports: reports)

                        // 演示横幅：跟着内容走，**不做全局浮层**。
                        //
                        // 浮层试过三个位置全部失败，而且都失败在同一件事上：
                        // 挡住交互。顶部 safeAreaInset 和子页面的大标题重叠；
                        // 底部 overlay（padding 或 offset 都试过）整层吃触摸，
                        // 标签栏点不动 —— 人被锁在演示里出不去，这是最糟的。
                        // 加在 TabView 上的 safeAreaInset 在 iOS 26 的浮动
                        // 标签栏下会直接压在标签栏上。
                        //
                        // 放进内容流里零风险。人是自己点进演示的，切到别的页
                        // 也不会误解 —— 那里的数据到处写着「演示 · Mac mini」
                        //「示例游戏」。
                        if store.isDemo {
                            HStack(spacing: 8) {
                                Image(systemName: "eye").font(.footnote)
                                Text("演示数据 · 不是你的真实额度")
                                    .font(.footnote.weight(.medium))
                                Spacer()
                                Button("退出") { store.exitDemo() }
                                    .font(.footnote.weight(.semibold))
                                    .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Color.orange.opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: 12))
                        }

                        // **软询问：真有事要通知你的时候才问。**
                        //
                        // iOS 的权限框只有一次机会 —— 被拒之后再调
                        // requestAuthorization 不会再弹，人得自己去设置里翻。
                        // 所以不能在启动时白白花掉它：那时候人还什么都没看到，
                        // 本能就是点「不允许」。
                        // 等到屏幕上真的摆着「有事等你拍板」，这个请求才讲得通。
                        if !push.asked, store.actionInbox.count > 0 {
                            NotifyAskCard(push: push)
                        }

                        if store.actionInbox.count > 0 {
                            SectionTitle("待我处理", note: "先看风险和证据，再决定下一步")
                            ForEach(store.actionInbox.questions) { a in
                                Button {
                                    answering = a
                                } label: {
                                    AskCard(ask: a, name: name(for: a.platform))
                                }
                                .buttonStyle(.plain)
                            }
                            // 未批的方案也是「挡住了」：批之前这个项目
                            // 一条活都不会被取用，空窗照样过期。
                            ForEach(pendingProjects) { p in
                                NavigationLink { PlaybookView() } label: {
                                    PendingProjectCard(project: p)
                                }
                                .buttonStyle(.plain)
                            }
                            if plannedCount > 0 {
                                NavigationLink { PlanView() } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "list.number")
                                            .font(.title3).foregroundStyle(.orange)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("\(plannedCount) 个计划等你放行")
                                                .font(.headline)
                                            Text("确认后才会进入任务队列")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption).foregroundStyle(.tertiary)
                                    }
                                    .padding(12)
                                    .background(Color.orange.opacity(0.1),
                                                in: RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                            }
                            if !store.actionableReviews.isEmpty {
                                NavigationLink { ReviewView() } label: {
                                    ReviewQueueCard(reviews: store.actionableReviews, actionable: true)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if !store.unavailableReviews.isEmpty {
                            SectionTitle("成果进展", note: "查看检查结果与处理进展")
                            NavigationLink { ReviewView() } label: {
                                ReviewQueueCard(reviews: store.unavailableReviews, actionable: false)
                            }
                            .buttonStyle(.plain)
                        }

                        // **「没有要你做的事」不能和上面的「挡住了」同时出现。**
                        //
                        // 第一版就这么撞上了：上面写着「Claude Code 在等你」，
                        // 下面一张绿卡说「没有要你做的事」。
                        // 同一屏两句互相打脸的话，比其中任何一句单独错更糟 ——
                        // 它让人不知道该信哪个，于是两个都不信。
                        if shouldShowAllQuiet(bleedingCount: bleeding.count,
                                             askCount: store.asks.count,
                                             pendingProjectCount: pendingProjects.count,
                                             reviewCount: store.actionableReviews.count,
                                             plannedCount: plannedCount) {
                            SectionTitle("在漏的", note: bleedNote)
                            AllQuietCard(reports: reports, asks: 0,
                                         digest: store.taskDigest,
                                         hasUnavailableReviews: !store.unavailableReviews.isEmpty)
                        } else if bleeding.isEmpty {
                            // 有问题挡着、但没有平台在空窗：只说后半句，别宣布「无事」。
                            SectionTitle("在漏的", note: bleedNote)
                            Text("没有平台正连续空窗 —— 但上面还有事项等你处理。")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(11)
                                .background(Color.secondary.opacity(0.07),
                                            in: RoundedRectangle(cornerRadius: 10))
                        } else {
                            SectionTitle("在漏的", note: bleedNote)
                            ForEach(bleeding, id: \.report.id) { row in
                                LeakRow(report: row.report, window: row.window)
                                    .onTapGesture { composing = row.report }
                            }
                        }

                        if !cooling.isEmpty {
                            CoolingNote(reports: cooling)
                        }
                        if !unmeasurable.isEmpty {
                            UnmeasurableNote(reports: unmeasurable)
                        }

                        // 服务端想在这页加东西，就写 views/now-extra.json。
                        // 名字带 -extra 是故意的：它只能补充，不参与顶替，
                        // 看名字就知道边界在哪。
                        if let extra = store.feeds["now-extra"], !store.isDemo {
                            FeedView(sections: extra.sections) { action, note in
                                await store.invoke(action, note: note)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 28)
            }
            .navigationTitle("现在")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh() }
            .navigationDestination(item: $answering) { ask in
                AnswerView(ask: ask)
            }
            .sheet(item: $composing) { r in NavigationStack { SubmitView(assignTo: r) } }
            .fullScreenCover(isPresented: $showOffice) {
                NavigationStack { OfficeView().toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("关掉") { showOffice = false }
                    }
                } }
            }
        }
    }

    // MARK: - 数据

    private var reports: [PlatformReport] {
        (store.dashboard?.reports ?? []).filter { ($0.enabled ?? true) }
    }
    private var workers: [PlatformReport] {
        reports.filter { $0.detected || $0.installed }
    }
    private func name(for p: String?) -> String {
        guard let p else { return "某个 agent" }
        return reports.first { $0.platform == p }?.displayName
            ?? PlatformNames.map[p] ?? p
    }

    /// 正在漏的：按「连续空了几个窗口」降序。
    ///
    /// 用连续空窗而不是总体空窗率，因为它们回答的是不同问题：
    /// 空窗率说「长期用得够不够」，连续空窗说「**现在**是不是正闲着」——
    /// 而首页只该回答后者。长期趋势属于账本页。
    private var bleeding: [(report: PlatformReport, window: IdleWindow)] {
        reports.compactMap { r -> (PlatformReport, IdleWindow)? in
            // **被限流的不算在漏。**
            //
            // Kimi 连续空 19 个窗口，看起来是「没在用」，
            // 真相是额度用尽 —— 试过、被拒了、退避了。那是订阅被用满，
            // 正好是浪费的反面。列进「在漏的」会让人去给一个
            // 进不去的平台塞更多活。
            guard !r.isCooling else { return nil }
            guard let w = r.idleWindows
                .filter({ $0.measurable && $0.currentStreak > 0 })
                .max(by: { $0.currentStreak < $1.currentStreak })
            else { return nil }
            return (r, w)
        }
        .sorted { $0.1.currentStreak > $1.1.currentStreak }
    }

    /// 测不了的：没有本地用量日志的平台。**要列出来，不能装作没有** ——
    /// 空窗率 0 和「测不了」长得一样，而后者意味着这个平台的浪费完全没人看着。
    /// 正在冷却的。单列 —— 它们不是在漏，是暂时进不去，
    /// 而「什么时候能再用」是个真实有用的信息。
    private var cooling: [PlatformReport] { reports.filter(\.isCooling) }

    private var unmeasurable: [PlatformReport] {
        reports.filter { r in
            (r.detected || r.installed) && !r.idleWindows.isEmpty
                && r.idleWindows.allSatisfy { !$0.measurable }
        }
    }

    private var bleedNote: String {
        let n = bleeding.count
        return n == 0 ? "按「已经连续空了几个窗口」排" : "\(n) 个平台正闲着，按连续空窗排"
    }
}

// MARK: - 顶栏：数据有多新

/// 数据新鲜度。
///
/// 这条必须在最上面而且永远存在：下面所有数字的可信度都取决于它。
/// Mac 端 15 分钟写一次，所以 35 分钟＝漏了两拍，值得说；
/// 3 小时＝这台机器多半没在跑，下面的东西不能当真。
private struct FreshnessBar: View {
    let dashboard: Dashboard?

    private var newest: Date? { dashboard?.machines.map(\.lastSeen).max() }
    private var age: TimeInterval { newest.map { -$0.timeIntervalSinceNow } ?? .infinity }
    private var level: Int { age > 3 * 3600 ? 2 : (age > 35 * 60 ? 1 : 0) }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(level == 0 ? Color.green : (level == 1 ? .orange : .red))
                .frame(width: 7, height: 7)
            Text(newest == nil ? "还没读到任何快照" : "快照 " + Fmt.relative(newest))
                .font(.caption)
            if let ms = dashboard?.machines, !ms.isEmpty {
                Text("· " + ms.map { $0.displayName + (
                    $0.isStale ? "(过期)" : "") }.joined(separator: " / "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            if level == 2 {
                Text("下面是 \(Fmt.duration(age)) 前的快照，别当真")
                    .font(.caption2).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(y: 12)
            }
        }
        .padding(.bottom, level == 2 ? 14 : 0)
    }
}

// MARK: - 现在在干什么

/// 顶上那条「正在干：<标题> · <平台> · 已 N 分钟」。
///
/// 五种处境要说五句不同的话，**一句都不能混**：
///
/// 1. 一份任务数据都没读到（Mac 上的 llmq 版本旧，或者板子全读不动）
///    → 说「不知道」。这一条最要紧：说成「没有任务在跑」是假话，
///    而且是完全查不出来的假话 —— 屏幕上没有任何东西提示你它其实不知道。
/// 2. 有这份数据，此刻确实没有活的任务 → **什么都不显示**。
///    首页寸土寸金，「当前无事」不值得占一张卡片。
/// 3. 有在跑/排队/卡住的 → 头条一句话，剩下的收起来，点开看全。
/// 4. 某台机器的板子冷了（超过两轮采集没更新）→ 它上面挂着的活
///    单独一块，每条都写着「N 分钟前的状态」，**不进「正在干」**。
/// 5. 某台机器的板子读不到 → 点名说是哪台读不到，
///    跟「那台没有活」区分开。
private struct RunningNow: View {
    let digest: TaskDigest
    /// platform → 员工名。从看板里查，手机端不另存一份映射 ——
    /// 两份映射迟早会漂移，而漂移了最难查。
    let name: (String?) -> String

    @State private var expanded = false
    @State private var coldExpanded = false

    /// 头条优先展示跑得最久的；没有在跑时，直接展示卡住或排队的第一件。
    ///
    /// **这里不能用 `digest.running.last`。** 合并多机之后排序的第一键
    /// 是机器名，最后一条只是「机器名排最后那台里最早开跑的那件」，
    /// 跟「跑得最久」没关系了。要哪一条就明说哪一条。
    private var headline: TaskBrief? {
        digest.running.min {
            ($0.startedAt ?? .distantFuture) < ($1.startedAt ?? .distantFuture)
        } ?? digest.blocked.first ?? digest.queued.first
    }
    private var rest: [TaskBrief] {
        digest.live.filter { $0.id != headline?.id } + digest.unrecognized
    }

    var body: some View {
        if !digest.published {
            unknownRow
        } else if !digest.hasAnythingToSay {
            // 没有在跑的、也没有冷板子和读不到的，就别占地方。
            EmptyView()
        } else {
            card
        }
    }

    // 1. 不知道
    //
    // 「没读到」有两种来路，下一步动作完全不同：
    // 板子在但读不动 → 等 iCloud 同步；压根没有这份数据 → 升级 Mac 上的 llmq。
    private var unknownRow: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("看不到在跑的任务").font(.caption.weight(.medium))
                if digest.unreadableBoards.isEmpty {
                    // **必须是一整条字符串字面量。** 用 + 拼出来的话，
                    // Text 走的是 String 那个重载，markdown 不再解析 ——
                    // 屏幕上会原样出现两个星号。这一版就这么错过一次。
                    Text("""
                         这台 Mac 发来的看板里没有任务数据 —— 是**不知道**，\
                         不是「没有任务」。把 Mac 上的 llmq 升级一下这里就有了。
                         """)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Text("""
                         这几台机器的任务板一块都读不出来 —— 是**不知道**，\
                         不是「没有任务」。多半是 iCloud 还没把文件同步下来。
                         """)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    unreadableList
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    /// 读不到的板子，**逐台点名**。
    ///
    /// 「有 2 台读不到」这句话没法让人去哪台机器上查；
    /// 写出名字（读不到名字就写 machineID 前 8 位）才有下一步。
    private var unreadableList: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(digest.unreadableBoards) { b in
                Text("· \(b.displayName)：\(b.unreadable ?? "读不到")")
                    .font(.system(size: 9)).foregroundStyle(.orange)
            }
        }
    }

    // 3. 有活
    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let t = headline {
                HStack(alignment: .top, spacing: 8) {
                    headlineMark(t)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headlinePrefix(t) + display(t.title))
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                        if let progress = t.progressHeadline {
                            Text(progress)
                                .font(.caption)
                                .foregroundStyle(.tint)
                                .lineLimit(2)
                        }
                        if let next = t.progressNextStep, !next.isEmpty {
                            Text("下一步：" + next)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        // 每分钟自己走一格。不刷新的话，这个数会停在
                        // 你打开这一页的那一刻，而它偏偏长得像实时的。
                        TimelineView(.periodic(from: .now, by: 60)) { _ in
                            Text(meta(t)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle").foregroundStyle(.secondary)
                    // **有板子读不到的时候不能说「没有正在跑的」。**
                    // 读得到的那几台确实没在跑，读不到的那几台不知道 ——
                    // 合成一句「没有」就把不知道说成了没有。
                    Text(digest.unreadableBoards.isEmpty
                         ? "没有正在跑的"
                         : "读得到的机器上没有正在跑的")
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 0)
                }
            }

            if !rest.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(restSummary).font(.caption)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)

                if expanded {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(rest) { t in TaskLine(task: t, name: name) }
                    }
                    .padding(.top, 2)
                }
            }

            if !digest.cold.isEmpty { coldBlock }
            if !digest.unreadableBoards.isEmpty { unreadableBlock }

            // **砍过就得说。** 不说的话上面那句「另外 3 件」是错的，
            // 而且错得毫无线索 —— 人只会以为一共就这么多。
            if digest.truncated {
                Text("有机器的板子超了条数上限，Mac 端砍掉了一部分 —— 上面的件数只是发过来的那些。")
                    .font(.system(size: 9)).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(headlineBackground,
                    in: RoundedRectangle(cornerRadius: 10))
    }

    // 4. 冷板子上挂着的活
    //
    /// **这一块的全部意义是「别把它们当成正在跑」。**
    ///
    /// 一台机器超过两轮采集没更新（默认 15 分钟一轮，所以是 30 分钟），
    /// 它板子上那条 `running` 多半早就不在跑了 —— 机器睡了、关了、
    /// 或者 llmq 掉了，而板子是不会自己改口的。照原样混进「正在干」里，
    /// 屏幕上就会有一件永远跑不完的活，人还会以为它真卡了三个小时。
    private var coldBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { coldExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 10))
                    Text(coldSummary).font(.caption)
                    Image(systemName: coldExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)

            if coldExpanded {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(digest.cold) { t in TaskLine(task: t, name: name) }
                }
            }
            Text("这些是那几台机器**上次报告时**的状态，不是此刻 —— 它们的板子已经两轮没更新了。")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    private var coldSummary: String {
        let who = digest.coldBoards.map(\.displayName)
        let whoText = who.isEmpty ? "有机器" : who.joined(separator: "、")
        return "\(whoText)：\(digest.cold.count) 件活是旧状态"
    }

    // 5. 读不到的板子
    private var unreadableBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("还有机器的任务板读不到 —— 它们有没有活，这里**不知道**。")
                .font(.system(size: 10)).foregroundStyle(.orange)
            unreadableList
        }
        .padding(.top, 2)
    }

    /// 「正在干」那行后半截：**机器名打头**，然后平台 · 第几步 · 已跑多久。
    ///
    /// 机器名排在最前面是因为两台机器同时干活时它是唯一的区分 ——
    /// 排在末尾的话，标题一长就被挤到看不见的地方，
    /// 而屏幕上会同时出现两条长得几乎一样的「正在干」。
    private func meta(_ t: TaskBrief) -> String {
        var bits: [String] = []
        if !t.machineName.isEmpty {
            bits.append(machineLabelForDisplay(t.machineName, machineID: t.machineID))
        }
        if let p = t.platform { bits.append(name(p)) }
        if let s = t.stepText { bits.append(s) }
        if let e = t.elapsedText { bits.append(e) }
        if let r = t.repoAlias, !r.isEmpty { bits.append(r) }
        return bits.joined(separator: " · ")
    }

    private var restSummary: String {
        var bits: [String] = []
        let running = digest.running.count - (headline?.isRunning == true ? 1 : 0)
        let blocked = digest.blocked.count - (headline?.isBlocked == true ? 1 : 0)
        let queued = digest.queued.count - (headline?.isQueued == true ? 1 : 0)
        if running > 0 { bits.append("还有 \(running) 件在跑") }
        if blocked > 0 { bits.append("\(blocked) 件卡住") }
        if queued > 0 { bits.append("\(queued) 件排队") }
        // 状态字符串不认识的也要报出来，别让它们从计数里蒸发。
        if !digest.unrecognized.isEmpty {
            bits.append("\(digest.unrecognized.count) 件状态不明")
        }
        return bits.joined(separator: " · ")
    }

    @ViewBuilder
    private func headlineMark(_ task: TaskBrief) -> some View {
        if task.isRunning {
            RunningPip()
        } else {
            Image(systemName: task.isBlocked ? "exclamationmark.circle.fill" : "clock.fill")
                .font(.system(size: 10))
                .foregroundStyle(task.isBlocked ? .orange : .secondary)
                .padding(.top, 3)
        }
    }

    private func headlinePrefix(_ task: TaskBrief) -> String {
        if task.isRunning { return "正在干：" }
        if task.isBlocked { return task.stateLabel + "：" }
        return "排队中："
    }

    private var headlineBackground: Color {
        guard let headline else { return Color.secondary.opacity(0.08) }
        if headline.isRunning { return Color.green.opacity(0.09) }
        if headline.isBlocked { return Color.orange.opacity(0.10) }
        return Color.secondary.opacity(0.08)
    }

    private func display(_ title: String) -> String {
        title.isEmpty ? "（这条没有标题）" : title
    }
}

/// 在跑的那一下心跳。它是这一屏上唯一"动"的东西，
/// 而它动是因为**真有一件任务在跑**，不是为了好看。
private struct RunningPip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Color.green)
            .frame(width: 8, height: 8)
            .opacity(on ? 0.35 : 1)
            .padding(.top, 5)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }
}

/// 一件任务的一行。「现在」页展开后用它，办公室的岗位卡里也用它 ——
/// 同一件事在两个地方长得不一样的话，人会怀疑看到的是两份数据。
struct TaskLine: View {
    let task: TaskBrief
    let name: (String?) -> String

    private var tint: Color {
        // 板子冷了的时候**不能给绿色**。绿色在这一屏上的含义是「此刻在动」，
        // 而这条只是一块半小时没更新的板子上写着的东西。
        // 颜色比文字先被读到，颜色说的话必须和文字一致。
        if task.isFromColdBoard { return .secondary }
        switch task.known {
        case .running: return .green
        case .blocked: return .orange
        case .failed:  return .red
        case .queued:  return .secondary
        case .done:    return .secondary
        case nil:      return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Text(task.stateLabel)
                .font(.system(size: 9))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(tint.opacity(0.15), in: Capsule())
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title.isEmpty ? "（这条没有标题）" : task.title)
                    .font(.caption).lineLimit(2)
                if let progress = task.progressHeadline {
                    Text(progress).font(.system(size: 10)).foregroundStyle(.tint).lineLimit(2)
                }
                if let next = task.progressNextStep, !next.isEmpty {
                    Text("下一步：" + next)
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                }
                // 冷板子上的任务，「这是哪台机器什么时候的状态」排在最前 ——
                // 它决定了后面那些字该怎么读。
                if let cold = task.coldLabel {
                    Text(cold).font(.system(size: 9)).foregroundStyle(.orange)
                }
                Text(meta).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private var meta: String {
        var bits: [String] = []
        if let p = task.platform { bits.append(name(p)) }
        // **排队中还没派人要说出来。** 空着的话看起来像漏了一个字段，
        // 而「还没决定派给谁」本身就是这条任务此刻最重要的事实。
        else if task.isQueued { bits.append("还没派人") }
        if let s = task.stepText { bits.append(s) }
        if let e = task.elapsedText { bits.append(e) }
        if let p = task.progressAgeText { bits.append(p) }
        // 冷的那条机器名已经在 coldLabel 里说过了，别说第二遍。
        if !task.machineName.isEmpty, task.coldLabel == nil {
            bits.append(machineLabelForDisplay(task.machineName, machineID: task.machineID))
        }
        if let r = task.repoAlias, !r.isEmpty { bits.append(r) }
        return bits.joined(separator: " · ")
    }
}

// MARK: - 工位条

private struct DeskStrip: View {
    let reports: [PlatformReport]
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                ForEach(reports.prefix(8)) { r in
                    VStack(spacing: 2) {
                        Mascot(state: r.detected ? .working : .asleep,
                               hue: StaffHue.of(r.platform), size: 26, activity: 0.3)
                        Text(r.platformName).font(.system(size: 8))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 记分牌

/// 结构性白付：**订阅费花了，但这个平台根本没在产出。**
///
/// 这是全 App 最硬的一个数 —— 它不需要上限、不需要历史、不需要推算，
/// 装好当天就有值。而且它捕捉的是最大额的浪费：
/// 一整个订阅在空转，比某个窗口少用了 30% 严重一个数量级。
private struct LeakBoard: View {
    let reports: [PlatformReport]

    private struct Bucket { var label: String; var money: String; var who: [String] }

    private var buckets: [Bucket] {
        func sum(_ f: (PlatformReport) -> Bool) -> Bucket? {
            let hit = reports.filter { f($0) && ($0.monthlyCost ?? 0) > 0 }
            guard !hit.isEmpty else { return nil }
            // **按币种分开。** 这里有 USD 和 CNY 两种订阅，
            // 硬写 ¥ 会把 ChatGPT Plus 的 $20 说成 ¥20 —— 差七倍，
            // 而且是往少了说，正好让最该注意的浪费看起来最小。
            let money = Money.group(hit.map { ($0.monthlyCost ?? 0, $0.currency) })
                .map { Money.text($0.total, $0.currency) + "/月" }
                .joined(separator: " + ")
            return Bucket(label: "", money: money, who: hit.map(\.platformName))
        }
        var out: [Bucket] = []
        if var b = sum({ !$0.installed }) { b.label = "付了钱没装"; out.append(b) }
        if var b = sum({ $0.installed && !$0.detected }) {
            b.label = "装了但探测不到"; out.append(b)
        }
        // **链路断了**：装了、探测到了、也允许派活，但一周零请求。
        // 这条最值钱 —— 它抓的正是「进度条一切正常、其实整条链路死了」，
        // 而那种情况从任何单项指标上都看不出来。
        if var b = sum({
            $0.installed && $0.detected && $0.last7dRequests == 0
                // **别冤枉没有本地日志的平台。**
                //
                // MiniMax 的 last7dRequests 恒为 0 —— 它不产生会话日志，
                // 用量只有官方接口看得见（实测 4 小时窗 1%、周窗 5%）。
                // 不排除的话，一个正在被用的服务会被挂上「链路断了」，
                // 而这条提示的下一步动作是去退订它。
                //
                // 和空窗那条是同一类错：把「这条路子看不见」
                // 当成了「它没在动」。
                && !$0.hasOfficialUsage
        }) {
            b.label = "一周零请求，链路可能断了"; out.append(b)
        }
        return out
    }

    var body: some View {
        if buckets.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(buckets.indices, id: \.self) { i in
                    let b = buckets[i]
                    HStack {
                        Text(b.label).font(.caption)
                        Spacer()
                        Text(b.money).font(.caption.monospacedDigit().bold())
                            .foregroundStyle(.orange)
                        Text(b.who.joined(separator: "、"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                // 四项分行不求和：它们的可信度不一样。
                // 「没装」是硬事实，「探测不到」可能只是 CLI 掉了登录 ——
                // 加成一个数会让一条推测混进一个确定的金额里。
                Text("分开列，不合成一个数 —— 可信度不一样，币种也不换算")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - 行

private struct SectionTitle: View {
    let text: String
    let note: String
    init(_ t: String, note: String) { text = t; self.note = note }
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(text).font(.headline)
            Text(note).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }
}

private struct AskCard: View {
    let ask: Ask
    let name: String
    @EnvironmentObject var store: Store
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: ask.isApproval
                  ? "exclamationmark.shield.fill" : "questionmark.bubble.fill")
                .foregroundStyle(ask.isApproval ? .orange : .cyan)
            VStack(alignment: .leading, spacing: 3) {
                // 机器名必须在 —— 两台电脑都装了同一个 agent 时，
                // 「Qwen 在等你」根本分不清是谁。
                Text(name + (ask.isApproval ? " 有高危改动等你决定 · " : " 在等你 · ")
                     + machineDisplayName(ask.machineID, in: store.dashboard))
                    .font(.subheadline.weight(.medium))
                // 问题原文 —— 光看「有人在等你」推不出该回什么。
                Text(ask.questions.first?.text ?? ask.taskPrompt)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Text(Fmt.relative(ask.askedAt) + (ask.isApproval ? "拦下 · " : "问的 · ")
                     + ask.repoName)
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(11)
        .background((ask.isApproval ? Color.orange : Color.cyan).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ReviewQueueCard: View {
    let reviews: [ReviewDigest]
    let actionable: Bool

    private var detail: String {
        if !actionable {
            if reviews.count == 1 {
                return reviews[0].confirmationBlockReason ?? "已提交决定，等待电脑同步处理结果。"
            }
            return "等待检查、同步或处理结果，查看各项原因。"
        }
        return withEvidence == reviews.count
            ? "查看证据后决定合入或丢弃"
            : "其中 \(reviews.count - withEvidence) 份还没有可查看的证据"
    }

    private var withEvidence: Int {
        reviews.filter {
            if case .available = $0.evidenceAvailability { return true }
            return false
        }.count
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: actionable ? "checkmark.seal.fill" : "hourglass")
                .foregroundStyle(actionable ? Color.blue : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(actionable ? "\(reviews.count) 份成果等你验收" : "\(reviews.count) 份保留成果，无需你确认")
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(11)
        .background((actionable ? Color.blue : Color.secondary).opacity(0.09),
                    in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct LeakRow: View {
    let report: PlatformReport
    let window: IdleWindow

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(report.displayName).font(.subheadline.weight(.medium))
                Text(window.windowLabel + " · 30 天里 \(window.idle)/\(window.total) 个空窗")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("连续空 \(window.currentStreak)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.orange)
                Text("塞点活").font(.caption2).foregroundStyle(.tint)
            }
        }
        .padding(11)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 空状态（每一种都要自证）

/// 什么都不用做的时候，**给回执而不是空白**。
///
/// 一张白页让人分不清是「真没事」还是「没读到数据」——
/// 而这两者的下一步动作完全相反。所以要把「检查了什么」逐条列出来。
private struct AllQuietCard: View {
    let reports: [PlatformReport]
    let asks: Int
    /// 「什么都不用做」这句话下面必须交代任务 ——
    /// 一张说「全静了」的绿卡，配上一台其实正在跑三件活的 Mac，
    /// 是这一屏最容易骗到人的组合。
    let digest: TaskDigest
    var hasUnavailableReviews: Bool = false

    private var soonest: (String, Date)? {
        reports.flatMap { r in r.statuses.compactMap { s in s.resetsAt.map { (r.displayName, $0) } } }
            .filter { $0.1 > Date() }
            .min { $0.1 < $1.1 }
    }

    /// **「不知道」和「没有」在这里也必须分开。**
    ///
    /// 这张卡的标题是「没有要你做的事」—— 全 App 最容易骗到人的一句话。
    /// 所以但凡有一台机器的板子读不到、或者冷了，都得在这一行里说出来：
    /// 一句「没有任务在跑」配上一台其实正在跑三件活、只是没同步过来的 Mac，
    /// 比什么都不写更糟。
    private var taskLine: String {
        guard digest.published else {
            if !digest.unreadableBoards.isEmpty {
                return "任务板一块都读不出来（\(boardNames(digest.unreadableBoards))）"
                    + " —— 有没有活在跑，这里不知道"
            }
            return "任务数据这台 Mac 没发过来 —— 有没有活在跑，这里不知道"
        }
        var bits: [String] = []
        if !digest.running.isEmpty { bits.append("\(digest.running.count) 件在跑") }
        if !digest.blocked.isEmpty { bits.append("\(digest.blocked.count) 件卡住") }
        if !digest.queued.isEmpty { bits.append("\(digest.queued.count) 件排队") }
        if !digest.unrecognized.isEmpty {
            bits.append("\(digest.unrecognized.count) 件状态不明")
        }
        if bits.isEmpty { bits.append("没有任务在跑，也没有在排队") }
        // 下面两句是**附加的保留意见**，不是替代 —— 前半句说的是读得到的机器。
        if !digest.cold.isEmpty {
            bits.append("另有 \(digest.cold.count) 件是 "
                        + boardNames(digest.coldBoards) + " 的旧状态")
        }
        if !digest.unreadableBoards.isEmpty {
            bits.append(boardNames(digest.unreadableBoards) + " 的板子读不到，那边不知道")
        }
        return bits.joined(separator: " · ")
    }

    private func boardNames(_ list: [BoardStatus]) -> String {
        list.map(\.displayName).joined(separator: "、")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(hasUnavailableReviews ? "当前没有需要你在手机上确认的事项" : "没有要你做的事",
                  systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium)).foregroundStyle(.green)
            Text("· \(asks) 个问题等你回答")
            Text("· \(reports.count) 个平台在册，没有一个正连续空窗")
            Text("· " + taskLine)
            if let s = soonest {
                Text("· 最近一个窗口：\(s.0)，\(Fmt.duration(s.1.timeIntervalSinceNow))后清零")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// 正在冷却的平台。
///
/// 和「在漏的」严格分开：一个被限流的平台，它的空窗不是浪费，
/// 是订阅被用满了。两者混在一起会把「什么都别做」误导成「快去塞活」。
private struct CoolingNote: View {
    let reports: [PlatformReport]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("这些进不去，等它们恢复").font(.caption.weight(.medium))
            ForEach(reports) { r in
                HStack {
                    Text(r.displayName).font(.caption2)
                    Text(r.cooldownReason ?? "冷却中")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if let u = r.cooldownUntil {
                        Text(Fmt.duration(u.timeIntervalSinceNow) + "后")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            Text("它们的空窗不算浪费 —— 是订阅被用满了，不是没在用。")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 测不了的平台。**列出来而不是省略** ——
/// 「空窗率 0」和「根本没在测」在界面上长得一样，
/// 而后者意味着这个平台的浪费完全没人看着。
private struct UnmeasurableNote: View {
    let reports: [PlatformReport]
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("这些平台测不了空窗").font(.caption.weight(.medium))
            Text(reports.map(\.displayName).joined(separator: "、"))
                .font(.caption2)
            Text("它们不产生本地用量日志，只有平台直报的百分比。"
                 + "不是没在用 —— 是这条路子看不见它们。")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 连看板都没有时。**要说清楚是哪一步断了**，
/// 而不是一句「加载失败」——那句话把「没连文件夹」「Mac 没在跑」
/// 「解析出错」三种完全不同的处境说成同一件事。
private struct NoDataCard: View {
    @ObservedObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(store.isConnected ? "连上了文件夹，但没读到看板" : "还没连上你的 Mac",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.medium)).foregroundStyle(.orange)
            if let e = store.lastError {
                Text(e).font(.caption).foregroundStyle(.secondary)
            }
            Text(store.isConnected
                 ? "iCloud 目录在，但里面没有 dashboard.json —— Mac 端的采集可能没在跑。"
                 + "去那台机器上跑一次 llmq collect。"
                 : "去「设置」那一栏选 iCloud 云盘里的 LLMQuotaBar 文件夹。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}


/// 等你过目的项目方案。
private struct PendingProjectCard: View {
    let project: PlaybookProject

    /// 取第一段并抹掉 markdown 记号。
    static func plain(_ md: String) -> String {
        (md.split(separator: "\n").first.map(String.init) ?? "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name).font(.headline)
                Text("方案等你过目 —— 批了才会在空窗时自动跑")
                    .font(.caption).foregroundStyle(.secondary)
                // 摘要要**去掉 markdown 记号**。这一行是纯 Text，不解析
                // markdown，`**做什么**` 会原样显示成一串星号 —— 看着像坏了。
                Text(Self.plain(project.brief))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }
}


/// 软询问卡片：先用自己的话说清为什么要通知权限，人点了才去弹系统框。
private struct NotifyAskCard: View {
    @ObservedObject var push: PushRegistrar
    @State private var dismissed = false

    var body: some View {
        if !dismissed {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bell.badge")
                    .font(.title3).foregroundStyle(.blue).frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text("下次这种事，要不要直接通知你？")
                        .font(.subheadline.weight(.semibold))
                    // 说清楚会推什么、不会推什么 —— 人最怕的是开了之后被刷屏。
                    Text("只在需要你做决定时响：方案等过目、产出等验收、"
                         + "任务被拦下。同类两小时内不重复。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        Button("好，通知我") {
                            Task { _ = await push.requestAuthorization() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        Button("先不用") { dismissed = true }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

private struct DeliveryStatusCard: View {
    var digest: TaskDigest
    var body: some View {
        let status = digest.deliveryStatus
        VStack(alignment: .leading, spacing: 10) {
            Text("交付进展").font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { values(status) }
                VStack(alignment: .leading, spacing: 8) { values(status) }
            }
            Text(digest.truncated ? "当前已读任务与最近成果，部分记录未展示" : "当前任务与最近成果，不是累计交付数量")
                .font(.caption2).foregroundStyle(.secondary)
            if !digest.cold.isEmpty || !digest.unreadableBoards.isEmpty {
                Text("部分机器状态尚未更新，未计入当前运行和等待数量")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("delivery-progress")
    }
    @ViewBuilder private func values(_ status: TaskDigest.DeliveryStatus) -> some View {
        Text("运行 \(status.running)")
        Text("诊断 \(status.diagnosing)")
        Text("待复验 \(status.qualityWaiting)")
        Text("待合入 \(status.mergeWaiting)")
        Text("已合入 \(status.landed)")
    }
}
