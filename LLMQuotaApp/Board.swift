import SwiftUI

@MainActor
private enum BoardDateText {
    static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter
    }()
}

/// 看板：把「值得盯」的数字集中到一屏。
///
/// 选料的标准是**能触发行动**，不是数据全：
/// - 额度窗口按「快作废/快烧完」排 —— 这个 App 立项就是为了防浪费；
/// - 机器心跳 —— 板子多久没更新，一眼判断是谁掉线；
/// - 任务吞吐 —— 现在卡着几个、24 小时交付几个，失败堆没堆；
/// - 事件流统计 —— 今天办公室里到底发生了多少真事。
/// 全部由手机端从既有数据现算，Mac 端零改动。
struct BoardView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        NavigationStack {
            // 下发内容**追加在原生内容后面**，不顶替。
            //
            // 原来是「有下发就整页换成通用渲染器」，结果是机器心跳、
            // 吞吐、交付、事件流五块被两块通用区块换掉 —— 信息更少、
            // 还更丑。顶替的前提是下发装得下原来的全部，装不下就别顶。
            //
            // 追加保留了「服务端不发版也能往这页加东西」，同时保证
            // 它拿不走已经在的。
            List {
                overviewSection
                projectProgressSection
                collaborationSection
                quotaSection
                machineSection
                deliveredSection
                eventsSection
                if let extra = store.feeds["board-extra"], !store.isDemo {
                    Section {
                        FeedView(sections: extra.sections) { a, n in
                            await store.invoke(a, note: n)
                        }
                    }
                }
            }
            .navigationTitle("看板")
            .refreshable { await store.refresh() }
        }
    }

    @ViewBuilder
    private var projectProgressSection: some View {
        if store.feeds["roadmap"] != nil, !store.isDemo {
            Section("项目") {
                NavigationLink {
                    FeedPageView(page: "roadmap", title: "项目进度")
                } label: {
                    Label("项目进度", systemImage: "map")
                }
            }
        }
    }

    // MARK: 机器心跳

    private var machineSection: some View {
        Section("机器心跳") {
            let machines = store.orderedByMachine(
                store.dashboard?.machines ?? [], id: { $0.machineID })
            if machines.isEmpty {
                Text("还没读到机器列表").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(machines) { m in
                let age = Date().timeIntervalSince(m.lastSeen)
                let board = store.taskDigest.rawBoards
                    .first { $0.machineID == m.machineID }
                HStack(spacing: 10) {
                    Circle()
                        // 600s 低于 launchd 采集周期 900s:菜单栏没开时健康机器大半时间是橙的,
                        // 而「设备」页用 Mac 算的 isStale(3600)是绿的 —— 同一台机两页两个结论。
                        // 这里和 Mac 一个口径:一个采集周期内绿、一小时内橙、再久红。
                        .fill(age < 1800 ? .green : (age < 3600 ? .orange : .red))
                        .frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.displayName).font(.subheadline)
                        Text("采集 \(rel(m.lastSeen))"
                             + (board?.generatedAt.map { " · 任务板 \(rel($0))" } ?? " · 任务板未发"))
                            .font(.caption2).foregroundStyle(.secondary)
                        if m.maxConcurrentTasks > 0 {
                            let scope = m.automaticRepoAliases.isEmpty
                                ? "仅手动"
                                : "自动：" + m.automaticRepoAliases.joined(separator: "、")
                            Text("执行槽 \(m.runningTaskCount)/\(m.maxConcurrentTasks) · \(scope)"
                                 + (m.runningRepoAliases.isEmpty ? ""
                                    : " · 正在跑 " + m.runningRepoAliases.joined(separator: "、")))
                                .font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text("尚未上报跨机执行能力")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        Text(m.coordinatorStatusText)
                            .font(.caption2)
                            .foregroundStyle(m.coordinatorNeedsAttention()
                                ? Color.orange : Color.secondary)
                        if let updated = m.coordinatorUpdatedAt {
                            Text("调度状态 \(rel(updated))更新")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if age >= 3600 {
                        Text("掉线？").font(.caption2).foregroundStyle(.red)
                    }
                }
            }
        }
    }

    // MARK: 额度窗口

    /// 最该看的排最上面：先按「预计浪费」降序（快作废的钱），
    /// 再按「已用比例」降序（快顶到上限的）。
    private var watchedStatuses: [(report: PlatformReport, status: QuotaStatus)] {
        let reports = (store.dashboard?.reports ?? [])
            .filter { ($0.enabled ?? true) && ($0.detected || $0.installed) }
        return reports
            .flatMap { r in r.statuses.map { (r, $0) } }
            // **没配上限的窗口也要显示。**
            //
            // 老板 2026-08-22:「手机端看不到 kimi, codex 了」。原因就是这一句:
            // 它只留「算得出已用比例」的窗口,而 Kimi 和 GLM 官方**不公布绝对
            // 额度**(订阅页只给比例),上限一栏是空的 —— 于是他最常用的两个
            // 平台从看板上整个消失,尽管它们有 5576 次、29M token 的真实用量。
            //
            // 看板是防浪费用的:一个「用了多少、几天后清零」的窗口,就算不知道
            // 上限也该看得见 —— 看不见才是真浪费。没有比例的排在最后,
            // 不占「最该看」的位置就行。
            .filter { Self.worthWatching($0.1) }
            // 排序用**浪费比例**（1 - 投影用量），不用 projectedWaste 原始值 ——
            // 那个字段的单位是「原始计量单位」：百分比口径是百分点、次数口径
            // 是次数，跨平台直接比大小是拿百分点和次数比，没有意义。
            // 2026-08-20 实测踩过更痛的一脚：把它当 0–1 小数乘 100 显示，
            // 出来「预计浪费 9741%」。
            .sorted {
                let wa = $0.1.wasteFraction, wb = $1.1.wasteFraction
                if wa != wb { return wa > wb }
                return ($0.1.displayUsedFraction ?? 0) > ($1.1.displayUsedFraction ?? 0)
            }
    }

    /// 这个额度窗口值不值得放进看板。
    ///
    /// 老板 2026-08-22:「手机端看不到 kimi, codex 了」。原来的判据只留
    /// 「算得出已用比例」的,而 Kimi 和 GLM 官方**不公布绝对额度**
    /// (订阅页只给比例),上限一栏是空的 —— 于是他最常用的两个平台从看板上
    /// 整个消失,尽管它们有 5576 次、29M token 的真实用量。
    ///
    /// 看板是防浪费用的:一个「用了多少、几天后清零」的窗口,就算不知道上限
    /// 也该看得见 —— **看不见才是真浪费**。没有比例的排在最后就行。
    static func worthWatching(_ s: QuotaStatus) -> Bool {
        guard !s.advisory, s.isCurrent, s.hasUsageValue else { return false }
        if s.displayUsedFraction != nil { return true }
        if s.projectedWaste != nil { return true }
        if s.used > 0 { return true }
        return [.idle, .wasting, .atRisk, .exhausted].contains(s.health)
    }

    private var quotaSection: some View {
        let preview = Array(watchedStatuses.prefix(4))
        return Section("最需要关注的额度") {
            if watchedStatuses.isEmpty {
                Text("没有可监控的额度窗口").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(preview, id: \.status.id) { pair in
                QuotaRow(report: pair.report, status: pair.status)
            }
            if watchedStatuses.count > preview.count {
                NavigationLink {
                    QuotaView()
                } label: {
                    Text("查看全部 \(watchedStatuses.count) 个额度窗口")
                }
            }
        }
    }

    // MARK: 任务吞吐

    private struct Throughput {
        var running = 0, queued = 0, blocked = 0, failed = 0
        var done24h = 0, failed24h = 0
    }

    private var throughput: Throughput {
        var t = Throughput()
        for b in store.taskDigest.rawBoards {
            for task in b.tasks {
                switch task.state {
                case "running": t.running += 1
                case "queued":  t.queued += 1
                case "blocked": t.blocked += 1
                case "failed":  t.failed += 1
                default: break
                }
            }
        }
        let dayAgo = Date().addingTimeInterval(-86400)
        for r in store.results where r.updatedAt > dayAgo {
            if r.isDone { t.done24h += 1 }
            if r.isFailed { t.failed24h += 1 }
        }
        return t
    }

    private var overviewSection: some View {
        let t = throughput
        let urgent = watchedStatuses.filter {
            [.exhausted, .atRisk, .wasting].contains($0.status.effectiveHealth)
                || $0.status.wasteFraction > 0.05
        }.count
        return Section("现在") {
            HStack(spacing: 0) {
                stat("要关注", urgent, urgent > 0 ? .orange : .secondary)
                stat("在跑", t.running, .blue)
                stat("卡住/失败", t.blocked + t.failed,
                     t.blocked + t.failed > 0 ? .red : .secondary)
                stat("24h 交付", t.done24h, .green)
            }
            if t.queued > 0 || t.failed24h > 0 {
                Text([
                    t.queued > 0 ? "另有 \(t.queued) 件排队" : nil,
                    t.failed24h > 0 ? "24 小时内 \(t.failed24h) 件失败" : nil,
                ].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(t.failed24h > 0 ? .red : .secondary)
            }
        }
    }

    private func stat(_ label: String, _ n: Int, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(n)").font(.title3.monospacedDigit().bold())
                .foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 最近交付

    private var deliveredSection: some View {
        let recent = store.results
            .filter(\.isDone)
            .prefix(5)
        return Section("最近交付") {
            if recent.isEmpty {
                Text("最近没有交付").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(recent)) { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.prompt.split(separator: "\n").first.map(String.init) ?? r.taskID)
                        .font(.caption).lineLimit(2)
                    Text((r.platform.map { (PlatformNames.map[$0] ?? $0) + " · " } ?? "")
                         + rel(r.updatedAt)
                         + (r.changedFiles.map { " · 改 \($0) 个文件" } ?? ""))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: 事件 24h

    private var eventsSection: some View {
        let dayAgo = Date().addingTimeInterval(-86400)
        let recent = store.events.filter { $0.at > dayAgo }
        let counts = Dictionary(grouping: recent, by: \.kind).mapValues(\.count)
        let order: [(OfficeEvent.Kind, String)] = [
            (.dispatched, "派活"), (.finished, "交活"), (.handoff, "交接"),
            (.asked, "提问"), (.answered, "答复"), (.exhausted, "耗尽")]
        return Section("办公室 · 24 小时") {
            if recent.isEmpty {
                Text("最近 24 小时没有事件").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 0) {
                    ForEach(order.filter { counts[$0.0] != nil }, id: \.1) { kind, label in
                        stat(label, counts[kind] ?? 0,
                             kind == .exhausted ? .red : .primary)
                    }
                }
            }
        }
    }

    private func rel(_ d: Date) -> String {
        BoardDateText.relative.localizedString(for: d, relativeTo: Date())
    }
}

/// 一条额度窗口：进度条 + 重置时间 + 浪费预警。
private struct QuotaRow: View {
    let report: PlatformReport
    let status: QuotaStatus

    private var fraction: Double { min(1, max(0, status.displayUsedFraction ?? 0)) }

    private var barColor: Color {
        guard status.displayUsedFraction != nil else { return .secondary }
        if fraction > 0.9 { return .red }
        if fraction > 0.7 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(report.displayName).font(.subheadline)
                Text(status.label).font(.caption2).foregroundStyle(.secondary)
                if status.advisory { Text("独立额度").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                Text(status.displayUsedFraction.map { "已用 " + Fmt.percent($0) }
                     ?? (status.isFresh() ? "上限未知" : "数据已过期"))
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(barColor)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if status.displayUsedFraction != nil {
                        Capsule().fill(barColor)
                            .frame(width: max(3, g.size.width * fraction))
                    }
                    // 预计用到的位置：虚拟刻度，比说一句「预计 82%」直观
                    if let p = status.projectedUsedFraction, p > fraction, p <= 1 {
                        Rectangle().fill(barColor.opacity(0.35))
                            .frame(width: 2)
                            .offset(x: g.size.width * p)
                    }
                }
            }
            .frame(height: 7)
            HStack {
                if let left = status.remainingFraction {
                    Text("剩余 " + Fmt.percent(left))
                        .font(.caption2).foregroundStyle(.secondary)
                } else if let floor = status.observedFloor {
                    Text("历史单窗最高 " + Fmt.metricValue(floor, metric: status.metric))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let r = status.resetsAt {
                    Text("重置 " + relShort(r)).font(.caption2).foregroundStyle(.secondary)
                }
                if let badge = status.estimationBadge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Spacer()
                // 立项的初心就在这一行：这窗口到期时预计有多少白白作废。
                //
                // 比例从 projectedUsedFraction 现算（全链路 0–1，无歧义），
                // **不读 projectedWaste**：那个字段是「原始计量单位」——
                // 百分比口径下是百分点。之前这里把 97.4 个百分点当 0–1
                // 小数乘 100，显示成「预计浪费 9741%」。
                // projectedWaste 只留一个用途：非空 = 这窗口的浪费值得说
                //（生产端只在「会作废的周期窗口」才写它）。
                if status.projectedWaste != nil {
                    let w = status.wasteFraction
                    if w > 0.05 {
                        Text("预计浪费 " + Fmt.percent(w))
                            .font(.caption2.bold()).foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func relShort(_ d: Date) -> String {
        BoardDateText.relative.localizedString(for: d, relativeTo: Date())
    }
}
