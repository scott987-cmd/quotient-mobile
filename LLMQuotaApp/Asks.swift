import SwiftUI

// MARK: - 与 Mac 端约定的结构
//
// 字段和 Mac 端 Ask.swift 一一对应。只重复手机上真正要用的那些。

struct Ask: Codable, Identifiable, Hashable {
    var id: String
    var taskID: String
    var machineID: String
    var round: Int
    var askedAt: Date
    var platform: String?
    /// 任务原文。光看问题不知道在问什么，必须一起显示。
    var taskPrompt: String
    var repoName: String
    var questions: [Question]
    /// agent 提问前已经做到哪儿了。回答时能看到这个，判断会准得多。
    var progressNote: String?
    var wipCommit: String?
    /// question(提问,答完 agent 接着干)/ approval(审批,「放行」= 直接提交已做好的改动)。
    /// Mac 端 2026-08-23 起高危闸发的是 approval;老文件没这个键按 question 看。
    var kind: String?
    var isApproval: Bool { kind == "approval" }

    /// 手写解码:残留的旧格式问题文件缺 machineID/repoName 时,Mac 端能容,手机也得能,
    /// 否则整条在手机上静默消失(对账实锤 2026-08-23)。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try c.decodeIfPresent(String.self, forKey: .taskID) ?? ""
        machineID = try c.decodeIfPresent(String.self, forKey: .machineID) ?? ""
        round = try c.decodeIfPresent(Int.self, forKey: .round) ?? 1
        askedAt = try c.decodeIfPresent(Date.self, forKey: .askedAt) ?? .distantPast
        let rawID = try c.decodeIfPresent(String.self, forKey: .id)
        id = rawID?.isEmpty == false ? rawID! : StableID.make(
            namespace: "ask",
            parts: [machineID, taskID, String(round), String(askedAt.timeIntervalSince1970)])
        platform = try c.decodeIfPresent(String.self, forKey: .platform)
        taskPrompt = try c.decodeIfPresent(String.self, forKey: .taskPrompt) ?? ""
        repoName = try c.decodeIfPresent(String.self, forKey: .repoName) ?? ""
        questions = try c.decodeIfPresent([Question].self, forKey: .questions) ?? []
        progressNote = try c.decodeIfPresent(String.self, forKey: .progressNote)
        wipCommit = try c.decodeIfPresent(String.self, forKey: .wipCommit)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
    }

    struct Question: Codable, Identifiable, Hashable {
        var id: String
        var text: String
        /// 有选项就渲染成按钮，点一下就完事，不用在手机上打字。
        var options: [String]?
        /// agent 自己的倾向。不想细看就直接采纳。
        var suggestion: String?
    }

    var platformName: String { PlatformNames.map[platform ?? ""] ?? (platform ?? "") }

    /// 审批不是开放式问答。把明确决定映射回 Mac 端已经发布的选项，
    /// 既避免用户输入协议关键字，也兼容服务端以后调整按钮文案。
    func approvalReplies(approve: Bool) -> [String: String] {
        guard isApproval, let question = questions.first else { return [:] }
        let choice = question.options?.first(where: {
            approve ? $0.contains("放行") : ($0.contains("丢弃") || $0.contains("拒绝"))
        }) ?? (approve ? "放行并提交" : "丢弃这次改动")
        return [question.id: choice]
    }
}

struct AskAnswer: Codable {
    var askID: String
    var taskID: String
    var machineID: String
    var answeredAt: Date
    var answers: [String: String]
    /// 直接放弃这个任务。不给这个出口的话，一个想不清楚的任务会永远挂着。
    var abandon: Bool
}

// MARK: - 问题列表

/// machineID → 人认识的机器名。
///
/// # 为什么必须显示机器
///
/// `Ask` 里一直带着 `machineID`（答复就是按它写进 answers/<machineID>/ 的），
/// 但界面三处全都不显示 —— 两台电脑装了**同一个** agent 时（比如都装了 Qwen），
/// 你分不清是谁在问。用户的原话：「不显示来自哪个电脑，
/// 当两个电脑装了同面的 agent 无法识别」。
///
/// 答错机器的问题不是小事：答复文件落在错的 machineID 目录下，
/// 那台机器的 Mac 侧永远收不到，任务卡死在「等答复」。
///
/// 认不出的 machineID 显示前 8 位 —— **有区分度的乱码也比没有强**，
/// 两条问题至少能看出来自不同机器。
func machineDisplayName(_ machineID: String, in dashboard: Dashboard?) -> String {
    if let m = dashboard?.machines.first(where: { $0.machineID == machineID }) {
        return m.displayName
    }
    return machineID.isEmpty ? "未知机器" : String(machineID.prefix(8))
}

struct AsksView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        NavigationStack {
            Group {
                if store.asks.isEmpty {
                    ContentUnavailableView(
                        "没有待回答的问题", systemImage: "checkmark.bubble",
                        description: Text("agent 干活时遇到拿不准的地方会问你，问题会出现在这里"))
                } else {
                    List {
                        Section {
                            ForEach(store.asks) { ask in
                                NavigationLink { AnswerView(ask: ask) } label: { AskRow(ask: ask) }
                            }
                        } footer: {
                            Text("任务在等你回答的这段时间不占额度 —— "
                                 + "它已经从队列里让出来了，电脑会先去干别的活。")
                        }
                    }
                }
            }
            .navigationTitle("问题")
            .refreshable { await store.refresh() }
        }
    }
}

struct AskRow: View {
    let ask: Ask
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(ask.repoName)
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
                if !ask.platformName.isEmpty {
                    Text(ask.platformName).font(.caption2).foregroundStyle(.secondary)
                }
                // 审批和提问长得像、后果完全不同:「放行」是直接提交已做好的改动,
                // 不会重跑。标出来,别让人以为又是一个要回答的问题。
                if ask.isApproval {
                    Text("审批")
                        .font(.caption2).bold()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                }
                // 哪台电脑问的。两台都装了同一个 agent 时，没有这个就没法分。
                Text(machineDisplayName(ask.machineID, in: store.dashboard))
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.relative(ask.askedAt)).font(.caption2).foregroundStyle(.secondary)
            }
            Text(ask.taskPrompt).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(ask.questions.first?.text ?? "")
                .font(.subheadline.weight(.medium)).lineLimit(2)
            if ask.questions.count > 1 {
                Text("还有 \(ask.questions.count - 1) 个问题")
                    .font(.caption2).foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - 回答

struct AnswerView: View {
    let ask: Ask
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var replies: [String: String] = [:]
    @State private var sent = false
    @State private var confirmDestructiveAction = false

    /// 全部问题都有非空答复才让提交。
    ///
    /// 允许空答复的话，「你看着办」会换来 agent 又跑一整轮探索、
    /// 再问一次、再等你两天 —— 每一轮都实打实烧额度。
    private var canSubmit: Bool {
        ask.questions.allSatisfy {
            !(replies[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(get: { replies[id] ?? "" }, set: { replies[id] = $0 })
    }

    var body: some View {
        Form {
            Section("谁在问") {
                HStack {
                    Text(ask.platformName.isEmpty ? "agent" : ask.platformName)
                        .font(.callout.weight(.medium))
                    Text("在 " + machineDisplayName(ask.machineID, in: store.dashboard) + " 上")
                        .font(.callout).foregroundStyle(.secondary)
                }
                // 答复按 machineID 落盘 —— 答错机器的问题，那台永远收不到。
            }
            Section("它在做什么") {
                Text(ask.taskPrompt).font(.callout)
                if let n = ask.progressNote, !n.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("已经做到这儿").font(.caption2).foregroundStyle(.secondary)
                        Text(n).font(.caption)
                    }
                }
            }

            if ask.isApproval {
                Section("为什么被拦下") {
                    Label {
                        Text(ask.questions.first?.text ?? "这次改动触发了高危规则")
                    } icon: {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Button {
                        Task {
                            if await store.answer(ask: ask,
                                                  replies: ask.approvalReplies(approve: true),
                                                  abandon: false) {
                                sent = true
                            }
                        }
                    } label: {
                        Label("放行并提交", systemImage: "checkmark.shield.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(role: .destructive) {
                        confirmDestructiveAction = true
                    } label: {
                        Label("丢弃这次改动", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                } footer: {
                    Text("放行会提交当前已经完成的改动，不会让 agent 重跑；"
                         + "丢弃会结束这次任务，分支上的其他提交不受影响。")
                }
            } else {
                Section {
                    Text("这是执行问题，不是成果验收。请先阅读问题再答复；暂时无法处理时，可以保留进度稍后再答。")
                        .font(.callout)
                }
                ForEach(Array(ask.questions.enumerated()), id: \.element.id) { i, q in
                    Section("问题 \(i + 1)") {
                        QuestionBlock(question: q, reply: binding(for: q.id))
                    }
                }

                Section {
                    Button {
                        Task {
                            if await store.answer(ask: ask, replies: replies, abandon: false) {
                                sent = true
                            }
                        }
                    } label: {
                        Label("回复并继续", systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!canSubmit)

                    Button("稍后处理，保留进度") { dismiss() }

                    Button(role: .destructive) {
                        confirmDestructiveAction = true
                    } label: {
                        Label("放弃这个任务", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                } footer: {
                    Text("填写答复后才能继续。稍后处理只退出此页，任务仍等候答复；"
                         + "放弃会结束任务，不是拒绝某一份成果。")
                }
            }

            if let e = store.lastError {
                Section { Text(e).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle(ask.isApproval ? "改动放行" : "执行问题 · 第 \(ask.round) 轮")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // 预填它自己的倾向，多数时候直接提交就行。
            for q in ask.questions where replies[q.id] == nil {
                if let s = q.suggestion, !s.isEmpty { replies[q.id] = s }
            }
        }
        .alert(ask.isApproval ? "决定已送达" : "已回复", isPresented: $sent) {
            Button("好") { dismiss() }
        } message: {
            Text(ask.isApproval
                 ? "电脑最迟 30 秒内处理。放行后会提交现有改动，不会重新执行任务。"
                 : "电脑最迟 30 秒内会捞走，接着上一轮继续干。")
        }
        .confirmationDialog(ask.isApproval ? "丢弃这次改动？" : "放弃这个任务？",
                            isPresented: $confirmDestructiveAction,
                            titleVisibility: .visible) {
            Button(ask.isApproval ? "确认丢弃" : "放弃", role: .destructive) {
                Task {
                    let decision = ask.isApproval ? ask.approvalReplies(approve: false) : [:]
                    if await store.answer(ask: ask, replies: decision,
                                          abandon: !ask.isApproval) {
                        sent = true
                    }
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text(ask.isApproval
                 ? "当前未提交的高危改动会被清理，这个任务会结束。"
                 : "任务会标成失败，已经产生的改动还在分支上，不会丢。")
        }
    }
}


/// 单个问题的输入块。
///
/// 拆出来是因为编译器对着原来那一整块（ForEach 里嵌 ForEach、
/// 三元表达式、内联 Binding）会类型检查超时 —— SwiftUI 的
/// 「unable to type-check this expression in reasonable time」。
/// 拆开之后每块都很小，编译器一眼就能推出来。
struct QuestionBlock: View {
    let question: Ask.Question
    @Binding var reply: String

    private var hasOptions: Bool { !(question.options ?? []).isEmpty }
    private var placeholder: String { hasOptions ? "或者自己写" : "你的答复" }

    var body: some View {
        Text(question.text).font(.subheadline)

        if let opts = question.options, !opts.isEmpty {
            ForEach(opts, id: \.self) { opt in
                OptionRow(text: opt,
                          selected: reply == opt,
                          preferred: question.suggestion == opt) {
                    reply = opt
                }
            }
        }

        TextField(placeholder, text: $reply, axis: .vertical)
            .lineLimit(1...4)

        if let s = question.suggestion, !hasOptions, !s.isEmpty {
            Button("采纳它的建议：\(s)") { reply = s }.font(.caption)
        }
    }
}

struct OptionRow: View {
    let text: String
    let selected: Bool
    let preferred: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            HStack {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(text).foregroundStyle(.primary)
                Spacer()
                if preferred {
                    Text("它倾向这个").font(.caption2).foregroundStyle(.tint)
                }
            }
        }
    }
}
