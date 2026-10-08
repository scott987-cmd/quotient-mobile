import SwiftUI

// MARK: - 与 Mac 端约定的结构
//
// 字段和 Mac 端 Playbook.swift 一一对应，只重复手机上要用的那些。

struct PlaybookProject: Codable, Identifiable {
    var id: String
    var name: String
    /// 方案：做什么、产出什么、怎么算合格。**这段就是要过目的东西。**
    var brief: String
    var repo: String?
    var recipes: [Recipe]
    var approvedAt: Date?
    var runs: Int
    var paused: Bool

    var isApproved: Bool { approvedAt != nil }

    struct Recipe: Codable, Identifiable {
        var title: String
        var prompt: String
        var tier: String
        var platform: String?
        /// 产出会对外可见（上架、发布、投稿）。这类活跑完会停下来等确认。
        var publishes: Bool

        var id: String { title }
    }
}

/// 手机批准。写进共享目录的 `approvals/<项目 id>.json`，
/// Mac 端下一轮读到就应用 —— 和回答 agent 提问是同一套路子。
struct PlaybookApproval: Codable {
    var projectID: String
    var approvedAt: Date
    var device: String?
    var note: String?
}

// MARK: - 页面

/// 项目方案审批。
///
/// ## 为什么这一页必须存在
///
/// 老板要「方案的确认还是经过我」，但确认入口原来只有 Mac 上的命令行。
/// 他人在手机上，看不到、批不了 —— 等于确认权名存实亡，
/// 而系统那边照样在自动跑。
struct PlaybookView: View {
    @EnvironmentObject var store: Store
    @State private var expanded: Set<String> = []
    @State private var noteFor: String?
    @State private var note = ""

    private var pending: [PlaybookProject] {
        store.projects.filter { !$0.isApproved }
    }
    private var live: [PlaybookProject] {
        store.projects.filter { $0.isApproved }
    }

    var body: some View {
        List {
            if store.projects.isEmpty {
                ContentUnavailableView(
                    "还没有项目清单",
                    systemImage: "list.bullet.rectangle",
                    description: Text("清单里是提前规划好、批过一次方案之后\n"
                                      + "就能在额度快浪费时自动执行的项目。"))
            }

            if !pending.isEmpty {
                Section {
                    ForEach(pending) { p in row(p, pendingApproval: true) }
                } header: {
                    Label("\(pending.count) 个方案等你过目", systemImage: "hand.raised")
                } footer: {
                    Text("批准之后，额度快过期时系统会自动从这个项目里取活。"
                         + "标了「对外发布」的产出仍然会停下来等你确认。")
                }
            }

            if !live.isEmpty {
                Section("已批准") {
                    ForEach(live) { p in row(p, pendingApproval: false) }
                }
            }
        }
        .navigationTitle("项目清单")
        .refreshable { await store.refresh() }
        // **alert 挂在 List 上，不是每行一个。**
        // ForEach 里每行挂一个 alert，多个会互相竞争，表现是点了没反应。
        .alert("批准这个方案", isPresented: Binding(
            get: { noteFor != nil },
            set: { if !$0 { noteFor = nil } })
        ) {
            TextField("附一句要求（可留空）", text: $note)
            Button("批准自动执行") {
                if let id = noteFor {
                    let approvalNote = note
                    Task { await store.approveProject(id, note: approvalNote) }
                }
                noteFor = nil; note = ""
            }
            Button("再想想", role: .cancel) { noteFor = nil; note = "" }
        } message: {
            Text("批准之后，额度快过期时会自动从这个项目里取活。"
                 + "标了「对外发布」的产出仍然会停下来等你确认。")
        }
    }

    @ViewBuilder
    private func row(_ p: PlaybookProject, pendingApproval: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(p.name).font(.headline)
                Spacer()
                if p.runs > 0 {
                    Text("跑过 \(p.runs) 次")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // 方案正文。默认收起 —— 一屏塞不下，而且列表里同时有好几个时
            // 全展开会让人根本不想读。要批的东西必须让人读得下去。
            if expanded.contains(p.id) {
                Text(p.brief)
                    .font(.callout)
                    .textSelection(.enabled)
                ForEach(p.recipes) { r in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "circle.fill").font(.system(size: 5))
                            .padding(.top, 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title).font(.subheadline)
                            HStack(spacing: 6) {
                                Text(r.tier).font(.caption2)
                                if let pl = r.platform {
                                    Text("点名 " + pl).font(.caption2)
                                }
                                if r.publishes {
                                    Text("对外发布 · 会等你确认")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text(p.brief.split(separator: "\n").first.map(String.init) ?? "")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            // 每个按钮都要显式 buttonStyle —— List 行里的裸 Button
            // 会让整行触发所有按钮的 action（点「看完整方案」同时弹出批准框）。
            HStack(spacing: 16) {
                Button(expanded.contains(p.id) ? "收起" : "查看并决定") {
                    if expanded.contains(p.id) { expanded.remove(p.id) }
                    else { expanded.insert(p.id) }
                }
                .font(.subheadline)
                .buttonStyle(.borderless)

                Spacer()

                if pendingApproval && expanded.contains(p.id) {
                    Button {
                        noteFor = p.id
                        note = ""
                    } label: {
                        Text("批准自动执行").font(.subheadline)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
