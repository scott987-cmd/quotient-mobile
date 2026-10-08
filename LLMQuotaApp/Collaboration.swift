import SwiftUI

// MARK: - 协作时间线的数据

/// 「Agent 协作」时间线的现成结论。
///
/// **单一状态源**：`store.feeds["collaboration"]` —— 服务端
/// `ViewFeed.collaborationPage` 下发的显式事实。客户端不另存一份协作
/// 状态，不做任何推断，也不展示模型隐藏推理；服务端给什么就说什么，
/// 给不了就诚实说给不了（老服务端 / 空页面各有退路）。
///
/// 契约要点（以 Mac 端为准）：
/// - facts 区块给服务端算好的「待回应 / 最近记录」两个数；
/// - cards 按工作链排列，`body` 是工作链 + sender → recipient（或 · 项目广播），
///   pending 用 warn 语气、交付结果用 good 语气；
/// - 证据文件名放 `images`，分支/提交/材料拼在 `detail` 里。
struct CollaborationDigest {
    enum Availability: Equatable {
        /// 老服务端：从来没发过这一页。
        case unavailable
        /// 页面版本比当前 App 新。
        case needsUpdate
        /// 正常可渲染。内容可能为空 —— 空态文案由服务端写。
        case ready
    }

    struct Entry: Identifiable, Equatable {
        let id: String
        let title: String
        /// sender → recipient 或 · 项目广播，原样透传服务端的 body。
        let direction: String
        /// 项目名（卡片 trailing）。时间线按它可辨识、可筛选。
        let project: String?
        let pending: Bool
        /// 待回应 / 结果 / 动态。只从显式语气映射，不猜。
        let kindLabel: String
        let detail: String?
        /// 证据引用。**只在展开详情时才加载媒体**（见时间线行）。
        let images: [String]
        let tone: FeedTone
        let icon: String?
        let eventKind: String?
        let replyTo: String?
        let taskID: String?
    }

    let availability: Availability
    /// 服务端 facts 里算好的数。nil = 这一页没说 —— **不许编成 0**，
    /// 「没说」和「说没有」是两句话。
    let pendingCount: Int?
    let recentCount: Int?
    let claimCount: Int?
    let questionAnswerCount: String?
    let entries: [Entry]
    let rawSections: [FeedSection]

    /// 空页面时服务端写的说明（text 区块），原样展示。
    var emptyNotice: FeedSection? {
        rawSections.first { $0.kind == "text" && $0.text != nil }
    }

    /// 筛项目用的名单：去重、保持服务端最近在前的顺序。
    var projects: [String] {
        var seen = Set<String>()
        return entries.compactMap(\.project).filter { seen.insert($0).inserted }
    }

    init(_ page: FeedPage?) {
        guard let page, page.schema <= FeedPage.supportedSchema else {
            let state: Availability = page == nil ? .unavailable : .needsUpdate
            self.init(availability: state, pendingCount: nil, recentCount: nil,
                      claimCount: nil, questionAnswerCount: nil,
                      entries: [], rawSections: [])
            return
        }
        var pending: Int?
        var recent: Int?
        var claims: Int?
        var questionAnswers: String?
        var list: [Entry] = []
        for section in page.sections {
            for fact in section.facts ?? [] {
                switch fact.key {
                case "待回应": pending = Int(fact.value)
                case "最近记录": recent = Int(fact.value)
                case "主动认领": claims = Int(fact.value)
                case "问答": if questionAnswers == nil { questionAnswers = fact.value }
                case "Agent 互问": questionAnswers = fact.value
                default: break
                }
            }
            for card in section.cards ?? [] {
                // 注册表不是交流记录，时间也不是项目名。保留在独立名录中。
                guard card.eventKind != "agent" else { continue }
                let isPending = card.tone == .warn
                let explicitLabel: String?
                switch card.eventKind {
                case "claim": explicitLabel = "主动认领"
                case "started": explicitLabel = "开始执行"
                case "question": explicitLabel = "提问"
                case "answer": explicitLabel = "回复"
                case "decision": explicitLabel = "决定"
                case "finding": explicitLabel = "发现"
                case "checkpoint": explicitLabel = "检查点"
                case "result": explicitLabel = "结果"
                case "handoff": explicitLabel = "交接"
                case "ack": explicitLabel = "确认反馈"
                case "conversation": explicitLabel = "问答"
                case "chain": explicitLabel = "工作链"
                default: explicitLabel = nil
                }
                list.append(Entry(
                    id: card.id,
                    title: card.title,
                    direction: card.body ?? "",
                    project: card.trailing,
                    pending: isPending,
                    // 事件类型回答「发生了什么」，pending 只回答「是否还在等回应」。
                    // 两者不能互相覆盖，否则手机上会出现“回应待回应”这种失真的关系。
                    kindLabel: explicitLabel
                        ?? (isPending ? "待回应" : (card.tone == .good ? "结果" : "动态")),
                    detail: card.detail,
                    images: card.images ?? [],
                    tone: card.tone ?? .neutral,
                    icon: card.icon,
                    eventKind: card.eventKind,
                    replyTo: card.replyTo,
                    taskID: card.taskID))
            }
        }
        self.init(availability: .ready, pendingCount: pending, recentCount: recent,
                  claimCount: claims, questionAnswerCount: questionAnswers,
                  entries: list, rawSections: page.sections)
    }

    private init(availability: Availability, pendingCount: Int?, recentCount: Int?,
                 claimCount: Int?, questionAnswerCount: String?,
                 entries: [Entry], rawSections: [FeedSection]) {
        self.availability = availability
        self.pendingCount = pendingCount
        self.recentCount = recentCount
        self.claimCount = claimCount
        self.questionAnswerCount = questionAnswerCount
        self.entries = entries
        self.rawSections = rawSections
    }

    func filtered(by project: String?) -> [Entry] {
        guard let project else { return entries }
        return entries.filter { $0.project == project }
    }

    /// 把协议里的 replyTo 还原成人能读懂的上文。事件 ID 只用于关联，不能让
    /// 用户拿着一串哈希猜「到底回应了谁」。父事件超出最近 30 条时也诚实降级。
    func replyContext(for entry: Entry) -> String? {
        guard let replyTo = entry.replyTo else { return nil }
        guard let parent = entries.first(where: { $0.id == replyTo }) else {
            return "回应较早的协作事项"
        }
        return "回应\(parent.kindLabel)：\(parent.title)"
    }

    /// 看板一级入口的一句话摘要。
    var entrySummary: String {
        switch availability {
        case .unavailable: return "电脑还没有同步协作记录"
        case .needsUpdate: return "协作内容需要更新 App 才能看"
        case .ready:
            guard !entries.isEmpty else { return "暂无协作记录" }
            var text = "最近 \(entries.count) 条"
            if let n = pendingCount, n > 0 { text += " · \(n) 条待回应" }
            return text
        }
    }

    var isReady: Bool { availability == .ready }
}

// MARK: - 看板一级入口（手机 + iPad 同一份）

extension BoardView {
    /// 看板上的「Agent 协作」分节。
    ///
    /// 一级入口**永远在场**：老服务端不下发这一页时入口也在，
    /// 点进去诚实说没有 —— 藏起来等于这个功能对手机不存在。
    var collaborationSection: some View {
        Section("Agent 协作") {
            NavigationLink {
                CollaborationTimelineView()
            } label: {
                collaborationEntryLabel
            }
            .accessibilityIdentifier("board-collaboration-entry")
        }
    }

    private var collaborationDigest: CollaborationDigest {
        CollaborationDigest(store.feeds["collaboration"])
    }

    private var collaborationEntryLabel: some View {
        let digest = collaborationDigest
        let pending = digest.pendingCount ?? 0
        return HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(pending > 0 ? Color.orange : Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent 协作").font(.subheadline.weight(.medium))
                Text(digest.entrySummary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if pending > 0 {
                Text("\(pending)").font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.16), in: Capsule())
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - 时间线页

/// 完整的协作时间线。从看板一级入口和 iPad 控制台进来的是同一个视图、
/// 消费同一份 `store.feeds` —— 不存在第二套协作状态源。
struct CollaborationTimelineView: View {
    @EnvironmentObject var store: Store
    @State private var projectFilter: String?
    @State private var expanded: Set<String> = []

    private var digest: CollaborationDigest {
        CollaborationDigest(store.feeds["collaboration"])
    }

    var body: some View {
        Group {
            switch digest.availability {
            case .unavailable:
                ContentUnavailableView(
                    "Mac 端还没有发来 Agent 协作记录",
                    systemImage: "arrow.triangle.branch",
                    description: Text(
                        "升级电脑上的 llmq 后，跨 Agent 的交接、问题和结果会自动出现在这里。"))
            case .needsUpdate:
                ContentUnavailableView(
                    "这一页需要更新 App",
                    systemImage: "arrow.down.app",
                    description: Text("电脑发来的协作内容版本比当前 App 新。其他页面仍可正常使用。"))
            case .ready:
                timeline
            }
        }
        .navigationTitle("Agent 协作")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if digest.isReady, digest.projects.count > 1 {
                projectMenu
            }
        }
    }

    private var timeline: some View {
        List {
            if digest.pendingCount != nil || digest.recentCount != nil
                || digest.claimCount != nil || digest.questionAnswerCount != nil {
                Section("协作状态") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                              spacing: 12) {
                        fact("待回应", digest.pendingCount,
                             (digest.pendingCount ?? 0) > 0 ? Color.orange : .green)
                        fact("最近记录", digest.recentCount, .secondary)
                        fact("主动认领", digest.claimCount, .secondary)
                        textFact("Agent 提问 / 已答问题", digest.questionAnswerCount, .secondary)
                    }
                }
            }
            if digest.entries.isEmpty {
                // 服务端明确写了空态文案时原样展示，客户端不替它编内容。
                if let notice = digest.emptyNotice {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            if let t = notice.title {
                                Text(t).font(.headline)
                            }
                            Text(notice.text ?? "").font(.callout).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Section {
                        Text("还没有协作记录").font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else {
                entriesSection("问题与答复", kinds: ["conversation"])
                entriesSection("工作关系", kinds: ["chain"])
                let recent = digest.filtered(by: projectFilter).filter {
                    $0.eventKind != "conversation" && $0.eventKind != "chain"
                }
                if !recent.isEmpty {
                    Section("最近动作") { ForEach(recent) { row($0) } }
                }
            }
            let agents = digest.rawSections.flatMap { $0.cards ?? [] }.filter { $0.eventKind == "agent" }
            if !agents.isEmpty {
                Section {
                    DisclosureGroup("可用 Agent · \(agents.count)") {
                        ForEach(agents) { agent in
                            VStack(alignment: .leading) {
                                Text(agent.title).font(.subheadline)
                                Text(agent.body ?? "").font(.caption).foregroundStyle(.secondary)
                                if let detail = agent.detail { Text(detail).font(.caption2) }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func entriesSection(_ title: String, kinds: Set<String>) -> some View {
        let entries = digest.filtered(by: projectFilter).filter { kinds.contains($0.eventKind ?? "") }
        if !entries.isEmpty {
            Section(title) { ForEach(entries) { row($0) } }
        }
    }

    private func fact(_ label: String, _ value: Int?, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value.map(String.init) ?? "—")
                .font(.title3.monospacedDigit().bold())
                .foregroundStyle(value == nil ? Color.secondary : tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func textFact(_ label: String, _ value: String?, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value ?? "—")
                .font(.title3.monospacedDigit().bold())
                .foregroundStyle(value == nil ? Color.secondary : tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ e: CollaborationDigest.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: e.icon ?? "arrow.triangle.branch")
                    .foregroundStyle(e.tone.color)
                    .frame(width: 20)
                Text(e.title).font(.subheadline.weight(.medium)).lineLimit(3)
                Spacer(minLength: 6)
                Text(e.kindLabel)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(e.tone.color.opacity(0.14), in: Capsule())
                    .foregroundStyle(e.tone.color)
            }
            // 谁发给谁（或项目广播）—— 这一行就是这条记录的身份。
            Text(e.direction)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(e.eventKind == "conversation" || e.eventKind == "chain" ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let p = e.project {
                    Text(p).font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }
                if let taskID = e.taskID {
                    Text("任务 " + String(taskID.prefix(8))).font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.blue.opacity(0.09), in: Capsule())
                }
                Spacer()
            }
            if let reply = digest.replyContext(for: e) {
                Text("↳ " + reply)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if expanded.contains(e.id) {
                if let d = e.detail {
                    Text(d).font(.caption).textSelection(.enabled)
                }
                if !e.images.isEmpty {
                    // 媒体只在展开后才开始读（EvidenceThumb 自己按需取）——
                    // 时间线滚动不付任何图片下载的钱。
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(e.images, id: \.self) { EvidenceThumb(file: $0) }
                        }
                    }
                }
            }
            if e.detail != nil || !e.images.isEmpty {
                Button(expanded.contains(e.id) ? "收起" : (e.eventKind == "conversation" ? "看问答全文" : "看详情")) {
                    if expanded.contains(e.id) { expanded.remove(e.id) }
                    else { expanded.insert(e.id) }
                }
                .font(.caption).buttonStyle(.borderless)
                .accessibilityIdentifier("展开协作详情-\(e.id)")
            }
        }
        .padding(.vertical, 4)
    }

    private var projectMenu: some View {
        Menu {
            Picker("按项目筛选", selection: $projectFilter) {
                Text("全部项目").tag(String?.none)
                ForEach(digest.projects, id: \.self) { p in
                    Text(p).tag(Optional(p))
                }
            }
        } label: {
            Image(systemName: projectFilter == nil
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityIdentifier("collab-project-filter")
    }
}
