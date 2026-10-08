import SwiftUI
import CryptoKit

enum MobileActionRoute {
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func parse(_ id: String) -> (scope: String, actionID: String)? {
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "machine", NotificationDestination.validID(parts[1]),
              !parts[2].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !parts[2].hasPrefix("machine:") else { return nil }
        return (parts[1], parts[2])
    }

    static func scoped(_ id: String, scope: String) -> String? {
        guard NotificationDestination.validID(scope) else { return nil }
        if id.hasPrefix("machine:") { return parse(id)?.scope == scope ? id : nil }
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "machine:" + scope + ":" + id
    }

    static func receiptName(actionID: String, invocationID: String) -> String {
        digest(actionID + "\n" + invocationID) + ".json"
    }

    static func resourceKey(_ id: String) -> String {
        guard let route = parse(id) else { return id }
        let parts = route.actionID.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, ["review", "task", "playbook", "milestone"].contains(parts[0]) else { return id }
        return route.scope + ":" + parts[0] + ":" + parts[2]
    }

    static func reviewResourceKey(_ id: String) -> String? {
        guard let route = parse(id) else { return nil }
        let parts = route.actionID.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, ["review", "review-continuation"].contains(parts[0]) else { return nil }
        let bits = parts[2].split(separator: "|", omittingEmptySubsequences: false)
        guard bits.count >= 3 else { return nil }
        return route.scope + ":review:" + bits.prefix(3).joined(separator: "|")
    }
}

// MARK: - 与 Mac 端约定的结构
//
// 字段和 Mac 端 ViewFeed.swift 一一对应。
//
// **所有字段都是可选的，未知的一律忽略。** 这不是偷懒，是这套东西
// 能成立的前提：只有当老客户端遇到新服务端写的内容不会失败时，
// 服务端才能先发新功能。反过来客户端就把服务端锁死了 ——
// 而客户端要走审核，一次一周。

struct FeedPage: Codable {
    static let supportedSchema = 1

    var schema: Int
    var page: String
    var generatedAt: Date
    var sections: [FeedSection]

    /// 已升级机器各写一份；只有没有任何分机页面时才使用旧版共享页面。
    /// 不按数量或新旧任选一份，否则仍会把另一台机器的待办覆盖掉。
    static func resolving(_ page: String, in pages: [String: FeedPage], now: Date = Date()) -> FeedPage? {
        let actionPages = ["review", "blocked", "playbook"]
        let isScoped = actionPages.contains { page.hasPrefix($0 + "-") }
            && NotificationDestination.validPage(page)
        guard actionPages.contains(page) || isScoped else { return pages[page] }
        let sources = pages.values.filter {
            isScoped ? $0.page == page
                : ($0.page.hasPrefix(page + "-") && NotificationDestination.validPage($0.page))
        }.sorted { $0.page < $1.page }
        let inputs = sources.isEmpty ? pages[page].map { [$0] } ?? [] : sources
        guard !inputs.isEmpty else { return nil }
        let sections = inputs.flatMap { source -> [FeedSection] in
            let scope = actionPages.first(where: { source.page.hasPrefix($0 + "-") })
                .map { String(source.page.dropFirst($0.count + 1)) }
            func routed(_ actions: [FeedAction]?) -> [FeedAction]? {
                actions?.compactMap { action in
                    let id = scope.flatMap { MobileActionRoute.scoped(action.id, scope: $0) }
                        ?? (scope == nil && MobileActionRoute.parse(action.id) != nil ? action.id : nil)
                    guard let id else { return nil }
                    var copy = action; copy.id = id; return copy
                }
            }
            let stale = now.timeIntervalSince(source.generatedAt) > 30 * 60
                || source.generatedAt.timeIntervalSince(now) > 5 * 60
            if source.schema > supportedSchema {
                return [FeedSection(kind: "text", text: "一台机器的事项需要更新 App 后查看。")]
            }
            return source.sections.enumerated().map { index, section in
                var copy = section
                copy.localSourceID = source.page + "|" + String(index)
                copy.actions = routed(section.actions)
                let originalCount = (section.actions ?? []).count
                    + (section.cards ?? []).reduce(0) { $0 + ($1.actions ?? []).count }
                if stale {
                    copy.note = "此来源采样已过期，暂时只读。"
                    copy.actions = []
                }
                copy.cards = section.cards?.map { card in
                    var card = card; card.id = source.page + "|" + card.id
                    card.actions = stale ? [] : routed(card.actions)
                    return card
                }
                let routedCount = (copy.actions ?? []).count
                    + (copy.cards ?? []).reduce(0) { $0 + ($1.actions ?? []).count }
                if !stale, routedCount < originalCount {
                    copy.note = "操作来源无法确认，请更新来源 Mac 后刷新；内容仍可查看。"
                }
                return copy
            }
        }
        return FeedPage(schema: supportedSchema, page: page,
                        generatedAt: inputs.map(\.generatedAt).min() ?? now, sections: sections)
    }
}

enum FeedTone: String, Codable {
    case neutral, good, warn, danger

    /// Mac 以后加第 5 种语气,这边不认也不能让整页解不出来(kind 做到了,tone 漏了)。
    /// 对账实锤 2026-08-23:合成解码对「存在但不认识」的枚举值照样抛 → 整页「还没有内容」。
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FeedTone(rawValue: raw) ?? .neutral
    }

    /// 语气 → 颜色。**映射在客户端做**，因为它要跟着深浅色主题走。
    /// 服务端只说「这条该注意」，不说「这条是橙色的」——
    /// 下发颜色会让主题失效。
    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .good:    return .green
        case .warn:    return .orange
        case .danger:  return .red
        }
    }
}

struct FeedAction: Codable, Identifiable {
    var id: String
    var label: String
    var style: String?
    var needsNote: Bool?

    var isPrimary: Bool { style == "primary" }
    var isDestructive: Bool { style == "destructive" }
    var wantsNote: Bool { needsNote == true }
}

struct FeedMeter: Codable, Identifiable {
    var label: String
    var fraction: Double
    var tone: FeedTone?
    var right: String?
    var id: String { label }
    /// 服务端算错不该让界面炸掉 —— 夹紧到 0…1。
    var clamped: Double { min(max(fraction, 0), 1) }
}

struct FeedCard: Codable, Identifiable {
    var id: String
    var title: String
    var body: String?
    var detail: String?
    var tone: FeedTone?
    var icon: String?
    var trailing: String?
    var images: [String]?
    var actions: [FeedAction]?
    var eventKind: String?
    var replyTo: String?
    var taskID: String?

    var requiresReviewBeforeAction: Bool {
        detail != nil || !(images ?? []).isEmpty
    }
}

struct FeedFact: Codable, Identifiable {
    var key: String
    var value: String
    var tone: FeedTone?
    var id: String { key }
}

struct FeedSection: Codable, Identifiable {
    var kind: String
    var title: String?
    var note: String?
    var tone: FeedTone?
    var text: String?
    var meters: [FeedMeter]?
    var cards: [FeedCard]?
    var facts: [FeedFact]?
    var actions: [FeedAction]?
    /// 只用于汇总后的界面身份，不改变共享 JSON 协议。
    var localSourceID: String? = nil

    enum CodingKeys: String, CodingKey {
        case kind, title, note, tone, text, meters, cards, facts, actions
    }

    var id: String {
        StableID.make(namespace: "feed-section", parts: [
            localSourceID ?? "", kind, title ?? "", note ?? "", text ?? "",
            String(meters?.count ?? 0), String(cards?.count ?? 0),
            String(facts?.count ?? 0),
        ] + (cards ?? []).map(\.id) + (actions ?? []).map(\.id))
    }

    /// 这个客户端认识的区块类型。**不认识的一律跳过。**
    static let known: Set<String> = ["banner", "meters", "cards", "facts", "text"]
    var isRenderable: Bool { Self.known.contains(kind) }
}

extension FeedSection {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "unknown"
        title = try c.decodeIfPresent(String.self, forKey: .title)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        tone = try c.decodeIfPresent(FeedTone.self, forKey: .tone)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        meters = try c.decodeIfPresent([FeedMeter].self, forKey: .meters)
        cards = try c.decodeIfPresent([FeedCard].self, forKey: .cards)
        facts = try c.decodeIfPresent([FeedFact].self, forKey: .facts)
        actions = try c.decodeIfPresent([FeedAction].self, forKey: .actions)
    }
}

// MARK: - 渲染

/// 把服务端下发的区块画出来。
///
/// 这个视图**不做任何判断**：不排序、不算健康度、不拼文案。
/// 那些全在 Mac 端做完了 —— 改排序规则、改提示语、加一种新状态，
/// 都不需要重新上架。
struct FeedView: View {
    @EnvironmentObject private var store: Store
    let sections: [FeedSection]
    var allowsActions = true
    var expandAllOnAppear = false
    let onAction: (FeedAction, String?) async -> Bool

    @State private var expanded: Set<String> = []
    @State private var noting: FeedAction?
    @State private var note = ""
    @State private var pendingActions: Set<String> = []
    @State private var actionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !allowsActions, containsActions {
                Label("这页暂时只读；需要你处理的事项会集中出现在“现在”",
                      systemImage: "eye")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if sections.contains(where: { !$0.isRenderable }) {
                Label("有一部分内容需要更新 App 后才能显示", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            if let actionError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text(actionError).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("知道了") { self.actionError = nil }
                        .font(.caption).buttonStyle(.borderless)
                }
                .padding(10)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            // 未知 kind 在这里被滤掉。这一行就是「服务端能先发新东西」
            // 的全部代价 —— 老客户端看不到新区块，但不会崩、不会白屏。
            ForEach(sections.filter(\.isRenderable)) { s in
                section(s)
            }
        }
        .onAppear {
            if expandAllOnAppear { expanded = Set(sections.flatMap { $0.cards ?? [] }.map(\.id)) }
        }
        .alert(noting?.label ?? "", isPresented: Binding(
            get: { noting != nil }, set: { if !$0 { noting = nil } })
        ) {
            TextField("说一句（可留空）", text: $note)
            Button(noting?.label ?? "确定") {
                if let a = noting { submit(a, note: note.isEmpty ? nil : note) }
                noting = nil; note = ""
            }
            Button("取消", role: .cancel) { noting = nil; note = "" }
        }
    }

    @ViewBuilder
    private func section(_ s: FeedSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let t = s.title {
                Text(t).font(.headline)
            }
            if let n = s.note {
                Text(n).font(.caption).foregroundStyle(.secondary)
            }
            switch s.kind {
            case "banner": banner(s)
            case "meters": meters(s)
            case "cards":  ForEach(s.cards ?? []) { card($0) }
            case "facts":  facts(s)
            case "text":   Text(s.text ?? "").font(.callout).foregroundStyle(.secondary)
            default:       EmptyView()   // 到不了这里（上面已经滤过）
            }
        }
    }

    @ViewBuilder
    private func banner(_ s: FeedSection) -> some View {
        let tone = s.tone ?? .neutral
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(s.text ?? "").font(.subheadline)
                Spacer(minLength: 8)
                ForEach(s.actions ?? []) { a in actionButton(a) }
            }
            actionStatuses(s.actions ?? [])
        }
        .padding(13)
        .background(tone.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func meters(_ s: FeedSection) -> some View {
        VStack(spacing: 9) {
            ForEach(s.meters ?? []) { m in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(m.label).font(.subheadline)
                        Spacer()
                        if let r = m.right {
                            Text(r).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.15))
                            Capsule().fill((m.tone ?? .neutral).color)
                                .frame(width: max(3, geo.size.width * m.clamped))
                        }
                    }
                    .frame(height: 6)
                }
            }
        }
    }

    @ViewBuilder
    private func card(_ c: FeedCard) -> some View {
        let tone = c.tone ?? .neutral
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                if let icon = c.icon {
                    // 认不出的符号名会画成空 —— 给个兜底。
                    Image(systemName: icon).font(.title3).foregroundStyle(tone.color)
                        .frame(width: 24)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.title).font(.subheadline.weight(.medium))
                    if let b = c.body {
                        Text(b).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if let t = c.trailing {
                    Text(t).font(.caption2).foregroundStyle(.secondary)
                }
            }

            if expanded.contains(c.id) {
                if let d = c.detail {
                    Text(d).font(.caption).textSelection(.enabled)
                }
                if let imgs = c.images, !imgs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(imgs, id: \.self) { EvidenceThumb(file: $0) }
                        }
                    }
                }
            }

            // 每个按钮都要显式 buttonStyle —— List 行里的裸 Button
            // 会让整行触发所有按钮的 action。踩过。
            if !c.requiresReviewBeforeAction || expanded.contains(c.id) {
                actionStatuses(c.actions ?? [])
            }
            HStack(spacing: 14) {
                if c.detail != nil || !(c.images ?? []).isEmpty {
                    Button(expanded.contains(c.id) ? "收起" : "看详情") {
                        if expanded.contains(c.id) { expanded.remove(c.id) }
                        else { expanded.insert(c.id) }
                    }
                    .font(.subheadline).buttonStyle(.borderless)
                }
                Spacer()
                if !c.requiresReviewBeforeAction || expanded.contains(c.id) {
                    ForEach(c.actions ?? []) { a in actionButton(a) }
                }
            }
        }
        .padding(13)
        .background(Color.secondary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func facts(_ s: FeedSection) -> some View {
        VStack(spacing: 0) {
            ForEach(s.facts ?? []) { f in
                HStack {
                    Text(f.key).font(.subheadline)
                    Spacer()
                    Text(f.value).font(.subheadline.monospacedDigit())
                        .foregroundStyle((f.tone ?? .neutral).color)
                }
                .padding(.vertical, 9)
                Divider()
            }
        }
    }

    @ViewBuilder
    private func actionStatuses(_ actions: [FeedAction]) -> some View {
        if allowsActions {
            ForEach(uniqueSubmissions(actions), id: \.invocationID) { submission in
                MobileActionStatusView(submission: submission)
            }
        }
    }

    private func uniqueSubmissions(_ actions: [FeedAction]) -> [MobileActionSubmission] {
        var seen = Set<String>()
        return actions.compactMap { action in
            guard let submission = store.actionSubmission(for: action.id),
                  seen.insert(submission.invocationID).inserted else { return nil }
            return submission
        }
    }

    @ViewBuilder
    private func actionButton(_ a: FeedAction) -> some View {
        if allowsActions, store.actionSubmission(for: a.id)?.preventsResubmission != true {
            Button {
                if a.wantsNote { noting = a; note = "" } else { submit(a, note: nil) }
            } label: {
                if pendingActions.contains(a.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Text(a.label).font(.subheadline)
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(a.isDestructive ? Color.red : Color.accentColor)
            .fontWeight(a.isPrimary ? .semibold : .regular)
            .disabled(pendingActions.contains(a.id) || store.hasPendingReviewAction(a.id)
                      || awaitingContinuationRefresh(a.id))
        }
    }

    private func awaitingContinuationRefresh(_ id: String) -> Bool {
        guard let key = MobileActionRoute.reviewResourceKey(id) else { return false }
        let actions = sections.flatMap { ($0.actions ?? []) + ($0.cards ?? []).flatMap { $0.actions ?? [] } }
        return actions.contains {
            MobileActionRoute.parse($0.id)?.actionID.hasPrefix("review-continuation:request:") == true
                && MobileActionRoute.reviewResourceKey($0.id) == key
                && store.actionSubmission(for: $0.id)?.receipt?.state == "succeeded"
        }
    }

    private var containsActions: Bool {
        sections.contains { section in
            !(section.actions ?? []).isEmpty
                || (section.cards ?? []).contains { !(($0.actions ?? []).isEmpty) }
        }
    }

    private func submit(_ action: FeedAction, note: String?) {
        guard !pendingActions.contains(action.id),
              store.actionSubmission(for: action.id)?.preventsResubmission != true else {
            return
        }
        pendingActions.insert(action.id)
        Task {
            let sent = await onAction(action, note)
            pendingActions.remove(action.id)
            if !sent {
                actionError = store.lastError ?? "“\(action.label)”未能写入，请检查连接后重试。"
            }
        }
    }
}

struct MobileActionStatusView: View {
    @EnvironmentObject private var store: Store
    let submission: MobileActionSubmission
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(submission.statusText, systemImage: submission.receipt?.state == "succeeded"
                  ? "checkmark.circle.fill" : "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(submission.receipt?.state == "failed" ? Color.red : Color.secondary)
            if let message = submission.receipt?.message, submission.receipt?.state == "failed" {
                Text(message).font(.caption2).foregroundStyle(.red)
            }
            if submission.receipt?.isTerminal != true {
                Button("刷新处理状态") { Task { await store.refreshActionReceipts() } }
                    .font(.caption2).buttonStyle(.borderless)
            }
        }
    }
}

// MARK: - 动态入口

/// 「更多」页的入口列表，由服务端下发。
///
/// ## 为什么这个比迁页面更值钱
///
/// 迁一个已有页面，省下的是「改那一页要发版」。
/// 而下发入口列表省下的是**「加一个全新功能要发版」**：
/// Mac 端加一个 `views/新东西.json`，在菜单里加一项指过去，
/// 手机上就多了一页 —— 客户端一行都不用改。
struct FeedMenu: Codable {
    var schema: Int
    var generatedAt: Date
    var entries: [FeedMenuEntry]
}

struct FeedMenuEntry: Codable, Identifiable {
    var page: String
    var title: String
    var icon: String?
    /// 服务端算好的数字。以前是客户端自己数的 ——
    /// 两处各算一次，迟早对不上。
    var badge: Int?
    var group: String?
    var id: String { page }
}

struct FeedMenuGroup: Identifiable {
    let title: String
    var entries: [FeedMenuEntry]
    var id: String { title }
}

extension FeedMenu {
    /// 保留服务端给出的入口和分组顺序。字典分组再按中文标题排序会把
    /// 「要你拍板」之类的优先级意外改成字典序。
    func groups(excluding pages: Set<String>) -> [FeedMenuGroup] {
        var groups: [FeedMenuGroup] = []
        for entry in entries where !pages.contains(entry.page) {
            let title = entry.group ?? "更多"
            if let index = groups.firstIndex(where: { $0.title == title }) {
                groups[index].entries.append(entry)
            } else {
                groups.append(FeedMenuGroup(title: title, entries: [entry]))
            }
        }
        return groups
    }
}

/// 渲染任意一个下发的页面。
///
/// 这就是「加新功能不用发版」的全部实现：客户端不知道这一页是什么，
/// 只知道去 `feeds[page]` 拿内容画出来。
struct FeedPageView: View {
    @EnvironmentObject var store: Store
    let page: String
    let title: String
    var allowsActions = true
    private var feed: FeedPage? { FeedPage.resolving(page, in: store.feeds) }

    var body: some View {
        Group {
            if let feed, feed.schema <= FeedPage.supportedSchema {
                ScrollView {
                    FeedView(sections: feed.sections, allowsActions: allowsActions) { a, n in
                        await store.invoke(a, note: n)
                    }
                    .padding(16)
                }
            } else if let feed, feed.schema > FeedPage.supportedSchema {
                ContentUnavailableView(
                    "这一页需要更新 App",
                    systemImage: "arrow.down.app",
                    description: Text("电脑发来的内容版本比当前 App 新。其他页面仍可正常使用。"))
            } else {
                // 服务端还没下发这一页 —— 说清楚原因，别让人对着白屏猜。
                ContentUnavailableView(
                    "这一页还没有内容",
                    systemImage: "tray",
                    description: Text("电脑还没有同步这一页，稍后下拉刷新即可。"))
            }
        }
        .navigationTitle(title)
        // 从推送直达时 App 可能刚从后台唤醒，先催一次 iCloud 并刷新，
        // 避免拿着启动前的缓存把“有成果”画成空页。
        .task { await store.refresh() }
        .refreshable { await store.refresh() }
    }
}
