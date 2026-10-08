import SwiftUI
import AVKit

// MARK: - 与 Mac 端约定的结构

struct ReviewDigest: Codable, Identifiable {
    var sourceMachineID: String?
    var landingBlockReason: String?
    var head: String?
    var continuationActionID: String? = nil
    var continuationBlockReason: String? = nil
    var id: String {
        (sourceMachineID.map { $0 + "\u{1}" } ?? "") + repo + "|" + branch
    }
    var repo: String
    var repoName: String
    var branch: String
    var platform: String
    var subject: String
    var prompt: String?
    var files: [String]
    var insertions: Int
    var deletions: Int
    var mergesCleanly: Bool
    var overlapsWith: [String]
    var committedAt: Date?
    /// agent 交的证据截图（相对仓库根的路径）。
    var evidence: [String]
    /// Mac 端已经抽出来的图（文件名，在共享目录 evidence/<目录名>/ 下）。
    var evidenceFiles: [String]?

    /// 图放在共享目录的哪个子目录里。和 Mac 端的命名规则对齐。
    var evidenceFolder: String {
        (repo + "|" + branch).replacingOccurrences(of: "/", with: "_")
          .replacingOccurrences(of: "|", with: "-")
    }

    func actionID(_ action: String) -> String? {
        guard let sourceMachineID, !sourceMachineID.isEmpty else { return nil }
        if action == "continue" {
            guard let continuationActionID, let head,
                  continuationActionID.hasPrefix("review-continuation:request:" + repo + "|" + branch + "|" + head + "|") else { return nil }
            let parts = continuationActionID.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 5, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
            return MobileActionRoute.scoped(continuationActionID, scope: MobileActionRoute.digest(sourceMachineID))
        }
        let revision = head.flatMap { $0.isEmpty ? nil : "|" + $0 } ?? ""
        return MobileActionRoute.scoped("review:" + action + ":" + repo + "|" + branch + revision,
                                       scope: MobileActionRoute.digest(sourceMachineID))
    }

    /// 首页和详情共用可确认条件；有截图不等于已通过前置验收。
    var confirmationBlockReason: String? {
        if let landingBlockReason {
            return landingBlockReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "来源 Mac 暂未允许确认，请等待检查结果同步。" : landingBlockReason
        }
        guard let sourceMachineID, !sourceMachineID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "成果来源机器尚未确认，请更新 Mac 后刷新。"
        }
        guard let head, !head.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "成果版本尚未同步，请更新来源 Mac 后刷新。"
        }
        guard !repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "成果所属项目或分支尚未同步，请等待来源 Mac 更新。"
        }
        if !mergesCleanly { return "存在合入冲突，需要先在来源 Mac 处理。" }
        return nil
    }

    var evidenceAvailability: ReviewEvidenceAvailability {
        if let files = evidenceFiles, !files.isEmpty { return .available(files) }
        if !evidence.isEmpty { return .syncing(evidence.count) }
        return .missing
    }

    /// 只按手机**实际拿得到**的媒体计数，并把图片、视频分开。
    /// 原来的角标用 `evidence.count`（agent 声明的路径），详情却用
    /// `evidenceFiles`（成功同步的文件），于是会出现“17 张”但只看到
    /// 1 个视频和几张图。同一张卡只能有一个事实来源。
    var evidenceSummary: String? {
        guard let files = evidenceFiles, !files.isEmpty else { return nil }
        let videos = files.filter { name in
            let lower = name.lowercased()
            return lower.hasSuffix(".mp4") || lower.hasSuffix(".mov")
                || lower.hasSuffix(".m4v")
        }.count
        let images = files.count - videos
        if images > 0 && videos > 0 { return "\(images) 张图片 · \(videos) 个视频" }
        if images > 0 { return "\(images) 张图片" }
        return "\(videos) 个视频"
    }
}

extension ReviewDigest {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceMachineID = try c.decodeIfPresent(String.self, forKey: .sourceMachineID)
        landingBlockReason = try c.decodeIfPresent(String.self, forKey: .landingBlockReason)
        head = try c.decodeIfPresent(String.self, forKey: .head)
        continuationActionID = try c.decodeIfPresent(String.self, forKey: .continuationActionID)
        continuationBlockReason = try c.decodeIfPresent(String.self, forKey: .continuationBlockReason)
        repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? ""
        repoName = try c.decodeIfPresent(String.self, forKey: .repoName) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? ""
        subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? ""
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
        insertions = try c.decodeIfPresent(Int.self, forKey: .insertions) ?? 0
        deletions = try c.decodeIfPresent(Int.self, forKey: .deletions) ?? 0
        mergesCleanly = try c.decodeIfPresent(Bool.self, forKey: .mergesCleanly) ?? false
        overlapsWith = try c.decodeIfPresent([String].self, forKey: .overlapsWith) ?? []
        committedAt = try c.decodeIfPresent(Date.self, forKey: .committedAt)
        evidence = try c.decodeIfPresent([String].self, forKey: .evidence) ?? []
        evidenceFiles = try c.decodeIfPresent([String].self, forKey: .evidenceFiles)
    }
}

enum ReviewEvidenceAvailability: Equatable {
    case available([String])
    case syncing(Int)
    case missing
}

/// 手机上的验收结论。写进 `verdicts/`，Mac 端下一轮执行。
struct ReviewVerdict: Codable {
    var repo: String
    var branch: String
    /// merge / discard
    var action: String
    var reason: String?
    var decidedAt: Date
}

// MARK: - 页面

/// 待验收的产出。
///
/// ## 为什么这一页必须存在
///
/// 系统推了一条「10 份产出等你验收」，App 里却没有任何地方能看到它们 ——
/// 老板的原话是「显示有 94 个消息但是我也看不到」。
/// **一个数字指向不存在的地方，比不显示更糟**：它每天提醒你有事没做，
/// 又不告诉你事在哪儿，几次之后这个数就被彻底忽略了。
///
/// 而这恰恰是整套系统最大的浪费所在：产出跑完了没人来得及审，
/// 落地率只有 41%。消化端跟不上，生成端做得再快也只是把积压做大。
struct ReviewView: View {
    @EnvironmentObject var store: Store
    @State private var expanded: Set<String> = []
    /// 哪几条展开了「任务原文全文」(默认只给前几行,见展开区)。
    @State private var fullPrompt: Set<String> = []
    @State private var discarding: ReviewDigest?
    @State private var reason = ""

    private var byRepo: [(String, [ReviewDigest])] {
        Dictionary(grouping: store.reviews, by: \.repoName)
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value.sorted { ($0.committedAt ?? .distantPast)
                                              > ($1.committedAt ?? .distantPast) }) }
    }

    var body: some View {
        List {
            // 原生摘要决定待办数量；旧节点下发的完整内容仍需可达，
            // 不能把缺少 reviews/ 的机器误当成没有成果。
            if FeedPage.resolving("review", in: store.feeds) != nil {
                Section {
                    NavigationLink("查看完整复核内容") {
                        FeedPageView(page: "review", title: "完整复核内容")
                    }
                }
            }
            if store.reviews.isEmpty {
                ContentUnavailableView(
                    "当前没有待确认成果",
                    systemImage: "checkmark.seal",
                    description: Text("这里展示已同步的成果确认状态；下拉刷新可重新同步。"))
            }
            if !store.decidedIDs.isEmpty {
                Section {
                    Label("\(store.decidedIDs.count) 份已表态，等电脑那边执行"
                          + "（合入前还要跑一遍构建和测试）",
                          systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(byRepo, id: \.0) { repoName, items in
                Section(repoName + "（\(items.count)）") {
                    ForEach(items) { d in row(d) }
                }
            }
        }
        .navigationTitle("成果确认与进展")
        .refreshable { await store.refresh() }
        // **只留一个 alert。**
        //
        // 同一个 view 上挂两个 `.alert`，SwiftUI 只有最后一个生效 ——
        // 前面那个（合入）根本不显示，症状就是「点合入没反应」。
        //
        // 合入干脆不弹窗：Mac 端合入前还会跑一遍构建和测试，跑不过不会合，
        // 这里再确认一次纯属拖慢验收 —— 而验收慢正是落地率只有 40% 的原因。
        // 反馈靠那一行立刻从列表里消失。
        .alert("丢弃这份产出", isPresented: Binding(
            get: { discarding != nil }, set: { if !$0 { discarding = nil } })
        ) {
            TextField("为什么丢（下次派同类活会看）", text: $reason)
            Button("丢弃", role: .destructive) {
                if let d = discarding {
                    let discardReason = reason.isEmpty ? nil : reason
                    Task {
                        await store.decideReview(d, action: "discard", reason: discardReason)
                    }
                }
                discarding = nil; reason = ""
            }
            Button("取消", role: .cancel) { discarding = nil; reason = "" }
        } message: {
            Text("理由是下次派同类活时唯一的历史依据，尽量写清楚。")
        }
    }

    @ViewBuilder
    private func row(_ d: ReviewDigest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(d.subject).font(.subheadline).lineLimit(expanded.contains(d.id) ? nil : 2)
            if let submission = store.reviewSubmission(d) {
                MobileActionStatusView(submission: submission)
            }
            if let submission = d.actionID("continue").flatMap({ store.actionSubmission(for: $0) }) {
                MobileActionStatusView(submission: submission)
                if submission.receipt?.state == "succeeded" {
                    Text("已交回原任务继续完善，等待电脑刷新进度。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if store.reviewSubmission(d)?.preventsResubmission != true {
                if let reason = d.confirmationBlockReason {
                    Label("保留成果，无需你确认", systemImage: "hourglass")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text(reason).font(.caption).foregroundStyle(.orange)
                } else {
                    Label("待你确认", systemImage: "checkmark.seal")
                        .font(.caption.weight(.medium)).foregroundStyle(.blue)
                }
            }
            if let machineID = d.sourceMachineID {
                Text(machineDisplayName(machineID, in: store.dashboard))
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Label(d.platform, systemImage: "person.fill")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("\(d.files.count) 个文件")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("+\(d.insertions)").font(.caption2).foregroundStyle(.green)
                Text("−\(d.deletions)").font(.caption2).foregroundStyle(.red)
                if let summary = d.evidenceSummary {
                    Label(summary, systemImage: "photo")
                        .font(.caption2).foregroundStyle(.blue)
                } else if case .syncing(let count) = d.evidenceAvailability {
                    Label("\(count) 个证据待同步", systemImage: "clock")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            // 冲突和重叠是**决定先合哪个**的关键信息，不能藏起来。
            if !d.mergesCleanly {
                Label("有冲突，需要在电脑上处理", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else if !d.overlapsWith.isEmpty {
                Label("和另外 \(d.overlapsWith.count) 个分支改了同一个文件——"
                      + "合完这个，那些可能就冲突了",
                      systemImage: "arrow.triangle.branch")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if expanded.contains(d.id) {
                // **证据图排在最前面。**
                //
                // 老板要做的是「看效果」,不是读文档。原来的顺序是
                // 任务原文 → 文件清单 → 图,而任务原文里带着整份 PLAN.md
                // (续活任务会把目标文档注进提示词),于是展开之后要划过
                // 五六屏字才看得到第一张渲染图 —— 实测 2026-08-23 在模拟器上
                // 划了 6 屏还没到图。验收页的第一屏必须是图。
                if case .available(let files) = d.evidenceAvailability {
                    Text("它交的证据截图（点开看大图）")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(files, id: \.self) { f in
                                EvidenceThumb(file: f)
                            }
                        }
                    }
                }
                if let p = d.prompt, !p.isEmpty {
                    Text("当初派的活").font(.caption).foregroundStyle(.secondary)
                    // **只给前几行。** 整份提示词里注了目标文档(PLAN.md 全文),
                    // 一条续活任务能有六千字 —— 摊在验收卡片里就是一堵墙。
                    // 想看全的点「全文」。
                    Text(TaskBrief.headline(of: p, lines: 6))
                        .font(.caption).textSelection(.enabled)
                    if TaskBrief.hasMore(p, lines: 6) {
                        Button(fullPrompt.contains(d.id) ? "收起全文" : "全文") {
                            if fullPrompt.contains(d.id) { fullPrompt.remove(d.id) }
                            else { fullPrompt.insert(d.id) }
                        }
                        .font(.caption2).buttonStyle(.plain).foregroundStyle(.tint)
                        if fullPrompt.contains(d.id) {
                            Text(p).font(.caption2).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                Text("改了这些文件").font(.caption).foregroundStyle(.secondary)
                ForEach(d.files.prefix(12), id: \.self) { f in
                    Text("· " + f).font(.caption2).foregroundStyle(.secondary)
                }
                if d.files.count > 12 {
                    Text("…还有 \(d.files.count - 12) 个")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                // **证据截图要真显示出来。**
                //
                // 老板的原话：「验收只有文字看不到图片，那还不如别让我验收」。
                // 他是对的 —— agent 交的是实跑截图，只给一行文件名，
                // 人根本没法判断这活干得怎么样，验收就成了走过场。
                switch d.evidenceAvailability {
                case .available:
                    EmptyView()
                case .syncing(let count):
                    Label("它声明了 \(count) 个证据文件，但还没同步过来",
                          systemImage: "clock")
                        .font(.caption2).foregroundStyle(.secondary)
                case .missing:
                    // 没交证据本身就是**重要信息**：这活没法验收，
                    // 要么打回要它补，要么自己去电脑上跑一遍。
                    Label("没有交证据截图 —— 没法从这里判断它干得对不对",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }

            // **每个按钮都要 .buttonStyle(.borderless)。**
            //
            // List 的行里放多个 Button 时，SwiftUI 默认把整行当成一个可点区域，
            // 点任何位置都会触发**所有**按钮的 action —— 实测点「看详情」
            // 会同时弹出「丢弃」对话框。这是 List + 多按钮的经典陷阱，
            // 只有显式指定按钮样式才会各管各的。
            HStack(spacing: 16) {
                Button(expanded.contains(d.id) ? "收起"
                       : (store.canConfirmReview(d) ? "查看并决定" : "查看详情")) {
                    if expanded.contains(d.id) { expanded.remove(d.id) }
                    else { expanded.insert(d.id) }
                }
                .font(.subheadline)
                .buttonStyle(.borderless)

                if expanded.contains(d.id) {
                    Spacer()
                    if d.sourceMachineID == nil {
                        Text("这份旧成果未标明来源机器，请更新 Mac 后刷新。")
                            .font(.caption).foregroundStyle(.orange)
                    } else if store.reviewSubmission(d)?.preventsResubmission != true,
                              store.canConfirmReview(d) {
                        Button("丢弃") { discarding = d; reason = "" }
                            .font(.subheadline).foregroundStyle(.red)
                            .buttonStyle(.borderless)

                        Button {
                            Task { await store.decideReview(d, action: "merge", reason: nil) }
                        } label: {
                            Text("通过并合入").font(.subheadline)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Text("当前不需要你操作，来源电脑会继续处理。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if expanded.contains(d.id) {
                if d.actionID("continue") != nil {
                    Button {
                        Task { await store.decideReview(d, action: "continue", reason: nil) }
                    } label: {
                        Label("保留成果，继续完善", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!store.canContinueReview(d))
                    Text("沿用原任务和现有分支继续工作，完成后重新验收；不会合入或丢弃成果。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(d.continuationBlockReason ?? "成果会保留。续作入口尚未就绪，请刷新来源 Mac 或查看原任务。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = store.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }
}


/// 一张证据截图的缩略图，点开看大图。
/// 证据截图缩略图。`Feed` 也用它 —— 下发的卡片可以带图。
struct EvidenceThumb: View {
    /// 封面缓存 —— 滚动来回不重复解码同一段录屏。
    static let posterCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 30
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    @EnvironmentObject var store: Store
    /// 文件名已经带了分支标识（`<分支>__<原名>.jpg`）—— 图是平铺放的，
    /// 因为镜像的目录推送不递归子目录。
    let file: String
    @State private var image: UIImage?
    @State private var poster: UIImage?
    @State private var videoURL: URL?
    @State private var showFull = false
    @State private var loadFailed = false
    @State private var retryID = 0

    var body: some View {
        Group {
            // **录屏和截图走两条不同的路。**
            //
            // 有些东西静态图证明不了：存档扛不扛得住强杀，要看
            //「玩到某个状态 → 强杀 → 重开、数字还对得上」这一整串动作。
            // 一张结果图既看不出中间强杀过，也看不出前后是同一局。
            if Store.isVideo(file) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.65))
                    if let poster { 
                        Image(uiImage: poster)
                            .resizable().scaledToFill()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if loadFailed {
                        VStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise")
                            Text("重新加载").font(.caption2)
                        }
                        .foregroundStyle(.white.opacity(0.92))
                    } else if videoURL == nil {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white.opacity(0.92))
                            .shadow(radius: 3)
                    }
                }
                .frame(width: 88, height: 156)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onTapGesture {
                    if videoURL != nil { showFull = true } else { retry() }
                }
            } else if let img = image {
                Image(uiImage: img)
                    .resizable().scaledToFill()
                    .frame(width: 88, height: 156)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { showFull = true }
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 88, height: 156)
                    .overlay {
                        if loadFailed {
                            VStack(spacing: 5) {
                                Image(systemName: "arrow.clockwise")
                                Text("重新加载").font(.caption2)
                            }
                            .foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .onTapGesture { if loadFailed { retry() } }
            }
        }
        .task(id: retryID) {
            // **一律不在主线程上干这些。**
            //
            // 原来这里直接调同步的 `localVideoURL`（把 7MB 录屏整个读进
            // 内存再写盘，iCloud 上还得先下载）和 `copyCGImage`（同步解码），
            // 而 `.task` 跑在主线程。一次验收好几段录屏、队列里好几条待审，
            // 主线程一卡就是几十秒 —— iOS 看门狗按无响应把进程杀掉。
            // 老板 2026-08-22 的原话是「待我审批太多了之后会卡死」
            // 和「移动端崩溃了好几次」，就是这一条。
            loadFailed = false
            if Store.isVideo(file) {
                guard let u = await retrying({ await store.localVideoURLAsync(file: file) })
                else { loadFailed = true; return }
                videoURL = u
                // 首帧当封面 —— 只有一个播放按钮的黑框，人分不清
                // 哪段是哪段（一次验收可能有好几段录屏）。
                let posterKey = u.path as NSString
                if let hit = Self.posterCache.object(forKey: posterKey) {
                    poster = hit
                    return
                }
                let img = await Task.detached(priority: .utility) { () -> UIImage? in
                    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: u))
                    gen.appliesPreferredTrackTransform = true
                    gen.maximumSize = CGSize(width: 264, height: 468)
                    guard let cg = try? gen.copyCGImage(
                        at: CMTime(seconds: 1, preferredTimescale: 60), actualTime: nil)
                    else { return nil }
                    return UIImage(cgImage: cg)
                }.value
                if let img {
                    let cost = Int(img.size.width * img.size.height * img.scale * img.scale * 4)
                    Self.posterCache.setObject(img, forKey: posterKey, cost: cost)
                    poster = img
                }
            } else {
                image = await retrying { await store.loadEvidenceAsync(file: file) }
                loadFailed = image == nil
            }
        }
        .sheet(isPresented: $showFull) {
            if Store.isVideo(file), let u = videoURL {
                NavigationStack {
                    VideoPlayer(player: AVPlayer(url: u))
                        .ignoresSafeArea(edges: .bottom)
                        .navigationTitle(file.components(separatedBy: "__").last ?? file)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("关闭") { showFull = false }
                            }
                        }
                }
            } else if let img = image {
                NavigationStack {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: img).resizable().scaledToFit()
                    }
                    .navigationTitle(file.components(separatedBy: "__").last ?? file)
                    .navigationBarTitleDisplayMode(.inline)
                    // **必须有明确的关闭按钮。**
                    //
                    // 只靠下拉手势关不掉：全屏 ScrollView 把垂直手势全吃了，
                    // sheet 的 dismiss 手势根本收不到 —— 实测就是「点击图片关不了」，
                    // 人被困在大图里。
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("关闭") { showFull = false }
                        }
                    }
                }
            }
        }
    }

    /// 大录屏第一次打开时经常还只是 iCloud 占位符。以前只试一次，2.5 秒
    /// 没下完就永久转圈；这里给同步继续推进的机会，仍然全在后台执行。
    private func retrying<T>(_ operation: () async -> T?) async -> T? {
        for attempt in 0..<3 {
            if let value = await operation() { return value }
            if attempt < 2 {
                try? await Task.sleep(for: .seconds(Double(attempt + 1)))
                if Task.isCancelled { return nil }
            }
        }
        return nil
    }

    private func retry() {
        loadFailed = false
        retryID += 1
    }
}
