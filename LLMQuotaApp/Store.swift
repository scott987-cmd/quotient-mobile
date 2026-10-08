import Foundation
import SwiftUI
import UIKit

struct ReserveSubmission: Codable, Sendable {
    var id: String
    var platform: String
    var fraction: Double
    var requestedAt: Double
    var accepted: Bool?
    var note: String?
}

struct MobileActionReceipt: Codable, Sendable {
    var actionID: String
    var invocationID: String
    var machineID: String
    var state: String
    var message: String
    var updatedAt: Date
    var attempts: Int
    var isTerminal: Bool { state == "succeeded" || state == "failed" }
}

extension MobileActionReceipt {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        actionID = try c.decodeIfPresent(String.self, forKey: .actionID) ?? ""
        invocationID = try c.decodeIfPresent(String.self, forKey: .invocationID) ?? ""
        machineID = try c.decodeIfPresent(String.self, forKey: .machineID) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "unknown"
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
    }
}

struct MobileActionSubmission: Codable, Sendable {
    var actionID: String
    var invocationID: String
    var submittedAt: Date
    var receipt: MobileActionReceipt?
    var preventsResubmission: Bool { receipt?.state != "failed" }
    var statusText: String {
        switch receipt?.state {
        case "running": return "目标 Mac 正在处理"
        case "retrying": return "目标 Mac 处理失败，正在重试"
        case "succeeded": return "目标 Mac 已执行成功"
        case "failed": return "目标 Mac 执行失败，可重试"
        default: return "已写入，等待目标 Mac 确认"
        }
    }
}

/// 保存手机自己提交的计划请求身份；处理回执只用于解释失败，
/// 成功入队仍以任务板为准，不能用机器显示名作为身份。
struct PlanReleaseRecord: Codable, Sendable {
    var invocationID: String
    var machineID: String
    var planID: String
    var submittedAt: Date
    var accepted: Bool?
    var failure: String?
    init(invocationID: String, machineID: String, planID: String, submittedAt: Date) {
        self.invocationID = invocationID; self.machineID = machineID
        self.planID = planID; self.submittedAt = submittedAt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        invocationID = try c.decodeIfPresent(String.self, forKey: .invocationID) ?? ""
        machineID = try c.decodeIfPresent(String.self, forKey: .machineID) ?? ""
        planID = try c.decodeIfPresent(String.self, forKey: .planID) ?? ""
        submittedAt = try c.decodeIfPresent(Date.self, forKey: .submittedAt) ?? .distantPast
        accepted = try c.decodeIfPresent(Bool.self, forKey: .accepted)
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
    }
}

/// 数据源：iCloud Drive 里 Mac 端维护的那个 LLMQuotaBar 目录。
///
/// 为什么用文件夹选择器而不是 iCloud 容器：
/// App 自己的 ubiquity container 会在 iCloud Drive 里另开一个文件夹，
/// 那就要改 Mac 端去读两个地方。让用户选一次现成的目录，双方读写同一份，
/// 而且**不需要任何 iCloud 权限配置** —— 拿到的是普通的安全作用域文件访问。
///
/// 书签存进 UserDefaults，之后每次启动直接恢复，不用再选。
@MainActor
final class Store: ObservableObject {
    /// 手机只需要最近的任务回执；当前任务由 taskboards 单独提供。
    /// outbox 是追加式的，多机运行一周就会有几百份。全部下载、解码并塞进
    /// List 会让「任务结果」越来越长，也会拖慢每 15 秒一次的全局刷新。
    nonisolated static let recentResultLimit = 80
    private let commandWriter = SharedDirectoryWriter()
    @Published private(set) var actionSubmissions: [String: MobileActionSubmission] = [:]
    private var actionWritesInFlight: Set<String> = []
    /// 只取点开的通知，不让历史详情拖累所有页面。连接切换后丢弃旧结果。
    func loadNotificationDetail(id: String) async -> NotificationDetailRecord? {
        guard NotificationDestination.validID(id), let root = rootURL else { return nil }
        let data = await Task.detached(priority: .utility) { () -> Data? in
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            let url = root.appendingPathComponent("notification-details/\(id).json")
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return Self.readAvailableData(url)
        }.value
        guard rootURL == root, let data else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let value = try? dec.decode(NotificationDetailRecord.self, from: data), value.id == id
        else { return nil }
        return value
    }
    @Published private(set) var dashboard: Dashboard?
    @Published private(set) var results: [TaskResult] = []
    /// 本次连接期间最近一次手机投递。离开“派新任务”再回来仍能继续看领取状态。
    @Published private(set) var lastSubmissionReceipt: SubmissionReceipt?
    @Published private(set) var repos: [RepoItem] = []
    @Published private(set) var asks: [Ask] = []
    /// 项目清单。空窗时自动取活的那些项目，未批准的等老板过目。
    @Published private(set) var projects: [PlaybookProject] = []
    /// 等验收的产出。推送里的那个数字指的就是这些。
    @Published private(set) var reviews: [ReviewDigest] = []

    /// Mac 端下发的页面内容（`views/<页面>.json`）。
    ///
    /// 有这个的页面，客户端不做任何判断 —— 排序、文案、该显示什么，
    /// 全在 Mac 端算完了。**改这些不需要重新上架。**
    @Published private(set) var feeds: [String: FeedPage] = [:]

    /// 服务端下发的入口列表。有它就用它，没有就用内置的那份。
    @Published private(set) var menu: FeedMenu?
    @Published private(set) var events: [OfficeEvent] = []
    /// 现在在跑什么。**在后台线程算好的现成结论**，界面直接用。
    /// 初值是 `.unpublished` 而不是空 —— 还没读到东西的时候，
    /// 正确的说法是「不知道」，不是「没有任务」。
    @Published private(set) var taskDigest: TaskDigest = .unpublished
    @Published private(set) var lastError: String?
    @Published private(set) var folderName: String?
    private(set) var isLoading = false

    /// 已经在手机上表过态、但 Mac 端还没执行完的那些。
    ///
    /// **不记住它们，点完立刻就会反弹回来。** decideReview 里本地移除了
    /// 一行，但 15 秒后自动刷新会重读 reviews.json —— 而 Mac 端要等
    /// work loop 那一轮才执行合并并重新发布，这中间那行又冒出来了。
    /// 老板的原话：「点击验收还是在验收列表」。
    ///
    /// Mac 端处理完之后那条会从 reviews.json 里消失，那时再把它从
    /// 这个集合里清掉（见 apply）。
    @Published private(set) var decidedIDs: Set<String> = []

    /// 演示模式：不连任何东西，用内置假数据把功能走一遍。
    ///
    /// **必须能一眼看出是演示、一键退出。** 否则人会以为看到的是自己的
    /// 真实额度 —— 那比不给演示更糟。界面上顶着一条横幅，随时能退。
    @Published private(set) var isDemo = false

    func enterDemo() {
        isDemo = true
        dashboard = Demo.dashboard()
        reviews = Demo.reviews()
        projects = Demo.projects()
        // 任务和事件也要填 —— 少了它们，「现在」页会显示
        //「还没读到任何快照」「把 Mac 上的 llmq 升级一下」，
        // 看的人以为这是个报错的 App，而不是一个在工作的 App。
        taskDigest = TaskDigest(boards: Demo.boards())
        events = Demo.events()
        // 演示也要能看见「Agent 协作」时间线长什么样 ——
        // 审核员和没升级 Mac 端的人没有共享文件夹，这是他们唯一的入口。
        feeds = ["collaboration": Demo.collaborationFeed()].compactMapValues { $0 }
        asks = []
        lastError = nil
    }

    func exitDemo() {
        isDemo = false
        dashboard = nil
        reviews = []
        projects = []
        taskDigest = .unpublished
        events = []
        feeds = [:]
    }

    /// 当前连接是一个可观察的单一状态源。推送注册等旁路能力跟着它变化，
    /// 不再各自保存一份只在启动时赋值的目录。
    @Published private(set) var rootURL: URL?
    private var connectionGeneration = UUID()
    private var answeredPending: [String: Date] = [:]
    private var approvedPending: [String: Date] = [:]
    private var reviewPending: [String: Date] = [:]
    @Published private var planPending: [String: Date] = [:]
    private var planWritesInFlight: Set<String> = []
    @Published private(set) var reserveSubmissions: [String: ReserveSubmission] = [:]
    @Published private var planReleases: [String: PlanReleaseRecord] = [:]

    private struct PendingIntents: Codable {
        var answered: [String: Date] = [:]
        var approved: [String: Date] = [:]
        var reviews: [String: Date] = [:]
        var actions: [String: MobileActionSubmission]?
        var plans: [String: Date]?
        var planReleases: [String: PlanReleaseRecord]?
        var reserves: [String: ReserveSubmission]?
    }

    private var root: URL? {
        get { rootURL }
        set {
            guard rootURL != newValue else { return }
            rootURL = newValue
            connectionGeneration = UUID()
            isLoading = false
            Self.clearMediaCaches()
            actionWritesInFlight = []
            loadPendingIntents(for: newValue)
        }
    }
    /// 共享目录（只读暴露）。推送注册要往里写 device token ——
    /// Mac 端读同一个目录，不需要任何服务器。
    private let bookmarkKey = "llmq.folder.bookmark"

    private func pendingKey(for root: URL) -> String {
        "llmq.pending." + StableID.make(namespace: "shared-root", parts: [root.path])
    }

    private func loadPendingIntents(for root: URL?) {
        answeredPending = [:]
        approvedPending = [:]
        reviewPending = [:]
        planPending = [:]
        planReleases = [:]
        reserveSubmissions = [:]
        planWritesInFlight = []
        decidedIDs = []
        actionSubmissions = [:]
        guard let root,
              let data = UserDefaults.standard.data(forKey: pendingKey(for: root)),
              let stored = try? JSONDecoder().decode(PendingIntents.self, from: data)
        else { return }

        // 回执目录尚未统一前，意图不能永久藏住真实数据。七天仍未消费的
        // 重新显示，让用户能看见并重试；正常路径会在权威快照缺席时更早清掉。
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        answeredPending = stored.answered.filter { $0.value >= cutoff }
        approvedPending = stored.approved.filter { $0.value >= cutoff }
        reviewPending = stored.reviews.filter { $0.value >= cutoff }
        planPending = (stored.plans ?? [:]).filter { $0.value >= cutoff }
        planReleases = (stored.planReleases ?? [:]).filter {
            $0.value.submittedAt >= cutoff && UUID(uuidString: $0.value.invocationID) != nil
                && $0.key == PlanView.releaseKey(machineID: $0.value.machineID, planID: $0.value.planID)
        }
        reserveSubmissions = (stored.reserves ?? [:]).filter {
            $0.key == $0.value.platform && UUID(uuidString: $0.value.id) != nil
                && $0.value.requestedAt.isFinite
                && ($0.value.accepted == nil || $0.value.requestedAt >= cutoff.timeIntervalSince1970)
        }
        decidedIDs = Set(reviewPending.keys)
        actionSubmissions = (stored.actions ?? [:]).filter {
            MobileActionRoute.parse($0.key) != nil && $0.value.submittedAt >= cutoff
        }
    }

    private func savePendingIntents() {
        guard let root else { return }
        let value = PendingIntents(answered: answeredPending,
                                   approved: approvedPending,
                                   reviews: reviewPending, actions: actionSubmissions, plans: planPending, planReleases: planReleases, reserves: reserveSubmissions)
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: pendingKey(for: root))
        }
    }

    // MARK: - 机器显示顺序
    //
    // 用户手动排的（办公室/计划清单的机器分节都按它来）。
    // 存 machineID 而不是机器名：改名不该打乱顺序。
    @Published private(set) var machineOrder: [String]

    nonisolated static func uniqueMachineIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func setMachineOrder(_ ids: [String]) {
        let unique = Self.uniqueMachineIDs(ids)
        machineOrder = unique
        UserDefaults.standard.set(unique, forKey: "llmq.machine.order")
    }

    /// 按用户排的顺序整理任何「有 machineID 的东西」。
    /// 没排过时保持来源顺序；排过的在前、名单外的新机器按原相对顺序排后面。
    func orderedByMachine<T>(_ items: [T], id: (T) -> String) -> [T] {
        guard !machineOrder.isEmpty else { return items }
        let rank = Dictionary(machineOrder.enumerated().map { ($0.element, $0.offset) },
                              uniquingKeysWith: min)
        return items.enumerated().sorted { a, b in
            let ra = rank[id(a.element)] ?? (machineOrder.count + a.offset)
            let rb = rank[id(b.element)] ?? (machineOrder.count + b.offset)
            return ra < rb
        }.map(\.element)
    }

    init() {
        machineOrder = Self.uniqueMachineIDs(
            UserDefaults.standard.stringArray(forKey: "llmq.machine.order") ?? [])
        restoreBookmark()
    }

    var isConnected: Bool { root != nil }

    // MARK: - 目录授权

    func connect(to url: URL) {
        // 安全作用域资源必须成对开关，否则会泄漏内核资源，
        // 而且下次启动恢复书签时可能拿不到权限。
        guard url.startAccessingSecurityScopedResource() else {
            lastError = "拿不到这个文件夹的访问权限"
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        // **选完要校验。**
        //
        // 不校验的话，选错文件夹一样会「连上」，然后界面一片空白 ——
        // 而人完全分不清是「选错了」「Mac 没在采集」还是「App 坏了」。
        // 判据用 Mac 端必然会写出来的两样东西之一。
        let fm = FileManager.default
        let looksRight = fm.fileExists(atPath: url.appendingPathComponent("snapshots").path)
            || fm.fileExists(atPath: url.appendingPathComponent("dashboard.json").path)
        guard looksRight else {
            lastError = "这个文件夹里没有 snapshots/ 或 dashboard.json，"
                + "看起来不是 Mac 上 llmq 用的那个。\n"
                + "要选的是 iCloud Drive 根目录下的 LLMQuotaBar，"
                + "不是「文稿」或别的同名文件夹。\n"
                + "你选的是：\(url.lastPathComponent)"
            return
        }

        do {
            let data = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            root = url
            folderName = url.lastPathComponent
            lastError = nil
            reload()
        } catch {
            lastError = "保存文件夹授权失败：\(error.localizedDescription)"
        }
    }

    private func restoreBookmark() {
        #if DEBUG
        // **调试用:直接指一个目录,跳过文件夹选择器。**
        //
        // 手机端的 bug 一直靠老板当眼睛报(「看不到进行中的任务」「点进去是空的」),
        // 一来一回半天,而我自己在模拟器里跑起来五分钟就能看见。挡路的只有安全作用域
        // 书签 —— 模拟器里没法用文件选择器指向 Mac 上的共享目录。
        // 这个入口只在 DEBUG 构建里存在(Release 编译时整段不存在,不是运行时判断),
        // 启动时传 LLMQ_FOLDER=/path 即可。
        if let p = ProcessInfo.processInfo.environment["LLMQ_FOLDER"], !p.isEmpty {
            let u = URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: u.path) {
                root = u
                folderName = u.lastPathComponent + "（调试直连）"
                return
            }
        }
        #endif
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data, options: [],
            relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return }
        root = url
        folderName = url.lastPathComponent
        if stale {
            // 书签失效通常是文件夹被移动或重装了 App。重新存一份，
            // 存不上也不致命 —— 下次启动会再提示选一次。
            _ = url.startAccessingSecurityScopedResource()
            if let fresh = try? url.bookmarkData(options: .minimalBookmark,
                                                 includingResourceValuesForKeys: nil,
                                                 relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: bookmarkKey)
            }
            url.stopAccessingSecurityScopedResource()
        }
    }

    func disconnect() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        root = nil
        folderName = nil
        dashboard = nil
        results = []
        lastSubmissionReceipt = nil
        repos = []
        asks = []
        projects = []
        reviews = []
        feeds = [:]
        menu = nil
        events = []
        decidedIDs = []
        lastError = nil
        // 断开之后「有没有任务」重新变成不知道，而不是没有。
        taskDigest = .unpublished
    }

    // MARK: - 读
    //
    // **读盘和解析全在后台线程，主线程只负责发起和贴结果。**
    //
    // iCloud 上的读会阻塞：一个还没下载下来的占位符，`Data(contentsOf:)`
    // 可以等很久，而且没有超时可言。挂在主线程上就是整个界面冻住 ——
    // 今天 Mac 那边的菜单栏 App 正是因为在主线程读 iCloud 卡死了十几分钟。
    // 这个 App 每次切页、每次下拉都要走这条路，更受不起。

    /// 发起一次刷新，不等结果。给 onAppear 和菜单里的「刷新」用。
    func reload() { Task { await refresh() } }

    /// 测试接缝：生产路径就是真实读盘的两个阶段函数。
    /// 测试注入受控加载器来编排时序 —— 提交顺序、断开隔离、
    /// 并发去重这些边界都靠它钉住，不需要真实 iCloud。
    var loadFirstStage: @Sendable (URL) async -> FirstStageSnapshot = Store.loadFirst
    var loadSecondStage: @Sendable (URL) async -> SecondStageSnapshot = Store.loadSecond

    /// 等这一次读完。给下拉刷新用 —— 转圈得转到真读完，
    /// 立刻收起来的话人以为刷过了，其实屏幕上还是旧数据。
    ///
    /// **分两个阶段提交**（2026-08-26）：
    /// 原来一次 Snapshot 串行等完 dashboard/taskboards/views/questions/
    /// reviews/outbox 才整包 apply，手机实测首屏要 20 秒。
    /// 现在轻量的先上屏（dashboard + 任务摘要 + 已在本机的下发页），
    /// 慢速来源在后台补齐后二次提交。每个阶段各自过连接闸：
    /// 读盘的几秒里断开或换目录的话，旧阶段的产物到不了新会话；
    /// isLoading 盖住整个流程，并发刷新不会把同一批文件读两遍。
    func refresh() async {
        // 演示模式不去碰文件系统 —— 没有 root，读了也是空，
        // 反而会把假数据清掉。
        guard !isDemo else { return }
        guard let root, !isLoading else { return }
        let generation = connectionGeneration
        isLoading = true
        defer {
            if generation == connectionGeneration { isLoading = false }
        }

        // 阶段一：首屏。只催 dashboard/taskboards 一小会儿，
        // questions/reviews/outbox/evidence 连目录都不看。
        let first = await loadFirstStage(root)
        // 用户可能在读 iCloud 的几秒里断开或改连了另一个目录。
        guard generation == connectionGeneration, self.root == root else { return }
        apply(first)

        // 阶段二：慢速来源后补。这一轮任何来源失手都只保留旧画面。
        let second = await loadSecondStage(root)
        guard generation == connectionGeneration, self.root == root else { return }
        apply(second)
        await refreshActionReceipts()
        await refreshPlanReceipts()
        await refreshReserveReceipts()
    }

#if DEBUG
    /// 单元测试接缝：绕过安全作用域书签直连一个本地目录。
    /// 只存在于调试构建，生产路径不走这里。
    func debugAttachRoot(_ url: URL) {
        root = url
        folderName = url.lastPathComponent
    }
#endif
}

// MARK: - 分阶段快照

/// 首屏阶段的一次读盘产物。**只装轻量来源**：
/// dashboard、任务摘要、已经在本机上的下发页和入口名单。
struct FirstStageSnapshot: Sendable {
    var dashboard: Dashboard?
    var dashboardError: String?
    /// 任务摘要每次都是新算的结论，包括「什么都没读到」—— 见 apply。
    var tasks: TaskDigest = .unpublished
    var feeds = FeedsLoad()
    var menu: FeedMenu?
}

/// 慢速阶段的产物。所有来源都是可选的：
/// **nil = 这一轮没读到（失败 / 占位符），必须保留旧画面**；
/// [] = 权威地为空。dashboard/tasks 不在这里 —— 它们归首屏管，
/// 慢阶段不重算（重算既浪费也不归它管）。
struct SecondStageSnapshot: Sendable {
    var repos: [RepoItem]?
    /// nil = 本轮来源不完整/解码失败；[] = 权威地为空。
    var asks: [Ask]?
    var projects: [PlaybookProject]?
    var reviews: [ReviewDigest]?
    var events: [OfficeEvent]?
    var results: [TaskResult]?
    /// 慢阶段把 views/ 催完之后再整体校正一次下发页。
    var feeds: FeedsLoad?
    var menu: FeedMenu?
}

/// `views/` 目录一轮读取的结果。
///
/// complete=false 表示有页面没读到或解不开 —— 这时调用方要**合并**
/// 而不是整包替换：读到的页照常换新，读不到的旧页原地保留。
/// 把「这页这轮读不到」显示成「没有这页」，是「一次来源失败抹掉旧数据」
/// 最常见的形状。
struct FeedsLoad: Sendable {
    var pages: [String: FeedPage] = [:]
    var complete = true
}

/// 最近一次成功解码的额度看板。
///
/// iCloud 文件可能在 App 重启时尚未下载；只靠内存保留旧画面，重启后仍会整页空白。
/// 这里缓存的是已经通过完整 JSON 解码的看板，不缓存半文件，也不拿它冒充实时数据：
/// `generatedAt` 原样保留，界面会明确显示数据时间和本轮读取警告。
enum DashboardCache {
    // 只由串行 XCTest 安装临时目录；生产环境始终为 nil。
    nonisolated(unsafe) static var directoryOverride: URL?

    private static func directory() -> URL? {
        if let directoryOverride { return directoryOverride }
        return FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask).first?
            .appendingPathComponent("LLMQuotaApp/DashboardCache", isDirectory: true)
    }

    private static func file(for root: URL) -> URL? {
        directory()?.appendingPathComponent(
            StableID.make(namespace: "dashboard-cache", parts: [root.path]) + ".json")
    }

    static func save(_ dashboard: Dashboard, for root: URL) {
        guard let file = file(for: root) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(dashboard) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    static func load(for root: URL) -> Dashboard? {
        guard let file = file(for: root), let data = try? Data(contentsOf: file) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Dashboard.self, from: data)
    }
}

extension Store {
    /// 首屏阶段落屏。慢速来源一概不碰 —— 它们的旧值原样留在界面上，
    /// 等阶段二回来再更新。
    func apply(_ s: FirstStageSnapshot) {
        // 演示模式下不接受真实数据 —— 否则连上文件夹的瞬间假数据被冲掉，
        // 而人还以为自己在看演示。
        guard !isDemo else { return }
        if let d = s.dashboard {
            dashboard = d
            // 有数据但同时带警告，表示这是上次成功缓存，不是本轮实时文件。
            // 不能为了“画面不空”就把来源异常藏掉。
            lastError = s.dashboardError
        } else if dashboard == nil {
            lastError = s.dashboardError
        }
        // 任务这一份**每次都换成新算的**，包括「什么都没读到」那种结果。
        //
        // 保留上一份看起来更体贴，其实是这个项目最熟的那个坑：
        // 屏幕上会一直显示半小时前的活，而且长得和实时的一模一样。
        // 读不到就让它退回「不知道」，界面自己会说清楚。
        taskDigest = s.tasks
        mergeOnlyFeeds(s.feeds)
        if let m = s.menu { menu = m }
    }

    /// 慢速来源落屏。nil 的来源不动屏幕上已有的东西 ——
    /// 一轮读盘失败不该把任何一块已经显示着的内容抹成空白。
    func apply(_ s: SecondStageSnapshot) {
        guard !isDemo else { return }
        if let r = s.repos {
            repos = r.map { $0.normalized(using: dashboard?.machines ?? []) }
        }
        if let source = s.asks {
            let live = Set(source.map(\.id))
            answeredPending = answeredPending.filter { live.contains($0.key) }
            asks = source.filter { answeredPending[$0.id] == nil }
        }
        if let source = s.projects {
            let stillUnapproved = Set(source.filter { !$0.isApproved }.map(\.id))
            approvedPending = approvedPending.filter { stillUnapproved.contains($0.key) }
            projects = source.map { project in
                guard let at = approvedPending[project.id], !project.isApproved else {
                    return project
                }
                var hidden = project
                hidden.approvedAt = at
                return hidden
            }
        }
        if let source = s.reviews {
            // Mac 端已经处理掉的，从「等它执行」名单里清掉；还在来源里的
            // 继续本地隐藏。只有完整权威快照能清 pending，失败/占位符不参与。
            let live = Set(source.map(\.id))
            reviewPending = reviewPending.filter { live.contains($0.key) }
            decidedIDs = Set(reviewPending.keys)
            reviews = source.filter { reviewPending[$0.id] == nil }
        }
        savePendingIntents()
        if let f = s.feeds { mergeFeeds(f) }
        if let m = s.menu { menu = m }
        if let e = s.events { events = e }
        if let r = s.results { results = r }
    }

    /// 慢阶段下发页规则：完整的一轮整包替换（服务端撤下的页跟着撤下，
    /// **权威增删只归它** —— 它催完过整个 views/，有资格下这个结论）；
    /// 不完整的一轮只换读到的页，读不到的保留上一份。
    private func mergeFeeds(_ load: FeedsLoad) {
        if load.complete {
            feeds = load.pages
        } else {
            var merged = feeds
            for (page, value) in load.pages { merged[page] = value }
            feeds = merged
        }
    }

    /// 快阶段专用：读到的页并进现有字典，**从不删除、无视 complete**。
    ///
    /// 首屏读的只是「已在本机」的子集 —— 它没看到一页 ≠ 服务端撤了
    /// 这一页（可能还在云上没下来）。快阶段要是拿一个空缓存当权威结论，
    /// 断网/同步抖动一下就能把屏幕上的协作页整块抹掉。
    /// （finding 158d91ba 第 2 条。）
    private func mergeOnlyFeeds(_ load: FeedsLoad) {
        var merged = feeds
        for (page, value) in load.pages { merged[page] = value }
        feeds = merged
    }

    /// **`nonisolated` 是这里的关键词。** Store 标了 @MainActor，
    /// 不写这个词的话这段照样跑在主线程上，等于什么都没改。
    /// nonisolated 的 async 函数不继承调用方的执行器，会落到后台线程池。

    // MARK: 阶段一：首屏

    /// 首屏阶段允许触碰的输入。**这条名单就是首屏性能边界的声明处**：
    /// questions/reviews/outbox/evidence 一概不在里面 —— 手机打开 App
    /// 要先看到「在干什么、额度怎么样」，而不是等全部历史读完。
    nonisolated static func firstStageInputs(root: URL) -> (files: [URL], dirs: [URL]) {
        (files: [root.appendingPathComponent("dashboard.json")],
         dirs: [root.appendingPathComponent("taskboards"),
                root.appendingPathComponent("views")])
    }

    /// 轻量阶段：dashboard + 任务摘要 + 已经在本机的下发页。
    ///
    /// 催下载只给 1.2 秒：这一步结束就该出画面。views 里还没同步到的页
    /// 触发下载但不等 —— 它们由慢阶段催完再补上，不挡首屏。
    nonisolated static func loadFirst(root: URL) async -> FirstStageSnapshot {
        var out = FirstStageSnapshot()

        // 安全作用域是进程级的，不绑线程，在后台开关一样有效。
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601

        let inputs = firstStageInputs(root: root)
        freshen(dirs: inputs.dirs, files: inputs.files, timeout: 1.2)

        if let d = readAvailableData(root.appendingPathComponent("dashboard.json")),
           let parsed = try? dec.decode(Dashboard.self, from: d) {
            out.dashboard = parsed
            DashboardCache.save(parsed, for: root)
        } else if let cached = DashboardCache.load(for: root) {
            out.dashboard = cached
            out.dashboardError = "本轮读不到共享额度文件，正在显示上次成功数据（数据时间见页面底部）"
        } else {
            out.dashboardError = "读不到 dashboard.json —— 确认选的是 LLMQuotaBar 文件夹，"
                + "并且 Mac 上已经跑过一次 llmq collect"
        }

        // **任务不挂在 dashboard.json 的成败上。**
        //
        // 任务来自 `taskboards/` 下每台机器各自的板子。dashboard.json
        // 一次读失败（iCloud 抖一下就会）不能连带整块任务一起没有。
        // 分档排序、去重、冷热判定照旧全在这条后台路径上算完。
        out.tasks = taskDigest(root: root, dec: dec, dashboard: out.dashboard)

        // 只读已经在本机且是当前版本的下发页（见 loadFeeds）——
        // 「已缓存的先上屏」，云上的留给慢阶段。
        out.feeds = loadFeeds(root: root, decoder: dec, freshenFirst: false)
        out.menu = readAvailableData(root.appendingPathComponent("views/menu.json"))
            .flatMap { try? dec.decode(FeedMenu.self, from: $0) }

        return out
    }

    // MARK: 阶段二：慢速来源

    /// 慢速阶段：问题、验收、项目清单、仓库清单、历史结果、办公室事件，
    /// 以及把 views/ 催完后对下发页做一次整体校正。
    ///
    /// 这里才允许等满时限 —— 画面已经在上了，多等一秒换的是数据完整。
    nonisolated static func loadSecond(root: URL) async -> SecondStageSnapshot {
        var out = SecondStageSnapshot()

        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601

        // 根上点名这轮真的要读的几个文件；目录整个扫的
        //（questions/reviews/views/outbox）各自在下面催。
        freshen(dirs: [],
                files: [root.appendingPathComponent("office.json"),
                        root.appendingPathComponent("repos.json"),
                        root.appendingPathComponent("config/repos.json"),
                        root.appendingPathComponent("playbook.json")])

        // 仓库清单优先读 config/repos.json：它带 pathByMachine，
        // 手机才知道「这个仓库在哪台机器上有目录」。老的导出文件只有别名，
        // 不同电脑的目录混在一张平面清单里 —— 用户就是被这个绊到的。
        if let d = readAvailableData(root.appendingPathComponent("config/repos.json")),
           let cfg = try? dec.decode([RepoConfigEntry].self, from: d), !cfg.isEmpty {
            out.repos = cfg.map { e in
                RepoItem(alias: e.alias, isDefault: e.isDefault ?? false,
                         machines: Array((e.pathByMachine ?? [:]).keys).sorted())
            }
        } else if let d = readAvailableData(root.appendingPathComponent("repos.json")),
                  let parsed = try? dec.decode([RepoItem].self, from: d) {
            out.repos = parsed
        }

        // 待回答的问题。目录按机器分 —— Mac 端的任务库是本机私有的，
        // 平铺的话手机分不清哪个答案该回给哪台机器。
        let qRoot = root.appendingPathComponent("questions")
        var found: [Ask] = []
        var questionsComplete = true
        if let machines = try? FileManager.default.contentsOfDirectory(
            at: qRoot, includingPropertiesForKeys: nil, options: []) {
            // 一次性催全部机器的问题目录 —— 挨个催的话限时等待会按机器数叠加。
            freshen(dirs: machines, files: [], timeout: 1.5)
            for m in machines {
                if m.lastPathComponent.hasPrefix(".") || m.pathExtension == "icloud" {
                    if m.pathExtension == "icloud" { questionsComplete = false }
                    continue
                }
                guard let files = try? FileManager.default.contentsOfDirectory(
                    at: m, includingPropertiesForKeys: nil, options: [])
                else { questionsComplete = false; continue }
                if files.contains(where: { $0.pathExtension == "icloud" }) {
                    questionsComplete = false
                }
                for f in files where f.pathExtension == "json" {
                    guard let d = readAvailableData(f),
                          var a = try? dec.decode(Ask.self, from: d)
                    else { questionsComplete = false; continue }
                    // 上级目录由发布路径决定，是答复应写回哪台机器的路由。
                    // 内容中的自报值只用于旧格式解码，不能把回答导向别处。
                    a.machineID = m.lastPathComponent
                    found.append(a)
                }
            }
        } else if FileManager.default.fileExists(atPath: qRoot.path) {
            questionsComplete = false
        }
        out.asks = questionsComplete ? found.sorted { $0.askedAt > $1.askedAt } : nil
        out.projects = loadProjects(root: root, dec: dec)
        // **待审清单：每台机器一份，读的时候合起来。**
        //
        // 以前 Mac 端两台机器都往 `reviews.json` 整份写，后写的盖先写的。
        // 而**每台机器看得见的仓库不一样**：MacBook 上根本没有 Greed 和
        // Maw 两个目录，它推上去的空清单把 Mac mini 的 3 条盖掉 ——
        // 人收到推送、点开是空的，过几分钟 Mac mini 写回来又出现
        //（2026-08-19 实测，老板原话「弹消息有两份待验收，但是点击去
        // 验收的页面又没有，过了好几分钟才加载出来」）。
        //
        // 现在每台写 `reviews/<machineID>.json`，各写各的，谁也盖不着谁，
        // 合并交给这里。和 `questions/` 是同一套办法。
        //
        // **有这个目录就用它**（哪怕合出来是空的 —— 那说明真的没有待审）；
        // 目录压根不存在才回退到 `reviews.json`，那是 Mac 端还没升级。
        let revDir = root.appendingPathComponent("reviews", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(
            at: revDir, includingPropertiesForKeys: nil, options: []) {
            freshen(dirs: [revDir], files: files, timeout: 1.5)
            var merged: [ReviewDigest] = []
            var seen = Set<String>()
            var complete = !files.contains { $0.pathExtension == "icloud" }
            for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where f.pathExtension == "json" {
                guard let d = readAvailableData(f),
                      let a = try? dec.decode([ReviewDigest].self, from: d)
                else { complete = false; continue }
                // 来源缺字段时由分片补齐；声明矛盾时保留阅读，但禁止操作。
                for var r in a {
                    let machine = f.deletingPathExtension().lastPathComponent
                    if let source = r.sourceMachineID, source != machine {
                        r.sourceMachineID = nil
                        r.landingBlockReason = "成果来源与机器分片不一致，请等待电脑端重新同步"
                    } else {
                        r.sourceMachineID = machine
                    }
                    if seen.insert(r.id).inserted { merged.append(r) }
                }
            }
            out.reviews = complete ? merged : nil
        } else {
            let legacy = root.appendingPathComponent("reviews.json")
            if FileManager.default.fileExists(atPath: legacy.path) {
                out.reviews = readAvailableData(legacy)
                    .flatMap { try? dec.decode([ReviewDigest].self, from: $0) }
            } else {
                let placeholder = root.appendingPathComponent(".reviews.json.icloud")
                out.reviews = FileManager.default.fileExists(atPath: placeholder.path) ? nil : []
            }
        }
        out.feeds = loadFeeds(root: root, decoder: dec, freshenFirst: true)
        out.menu = readAvailableData(root.appendingPathComponent("views/menu.json"))
            .flatMap { try? dec.decode(FeedMenu.self, from: $0) }

        // 办公室事件流。Mac 端每发生一件真事就往里加一条。
        if let d = readAvailableData(root.appendingPathComponent("office.json")),
           let parsed = try? dec.decode([OfficeEvent].self, from: d) {
            out.events = parsed.sorted { $0.at < $1.at }
        }

        let outbox = root.appendingPathComponent("outbox")
        if let files = try? FileManager.default.contentsOfDirectory(
            at: outbox,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) {
            // 先只看轻量元数据，选出最近一小段；不要为了 80 行 UI 下载并
            // 解码几百份历史 JSON。正在跑的任务不依赖这里，taskboards 会显示。
            let recent = recentResultFiles(files, limit: recentResultLimit)
            freshen(dirs: [], files: recent, timeout: 1.5)
            out.results = recent
                .compactMap { url -> TaskResult? in
                    guard let d = readAvailableData(url) else { return nil }
                    return try? dec.decode(TaskResult.self, from: d)
                }
                .sorted { $0.updatedAt > $1.updatedAt }
        }

        return out
    }

    /// 按文件更新时间挑最近的结果。单独抽出，避免加载路径再长出第二份排序规则。
    nonisolated static func recentResultFiles(_ files: [URL], limit: Int) -> [URL] {
        files.filter { $0.pathExtension == "json" }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if lhs != rhs { return lhs > rhs }
                return $0.lastPathComponent > $1.lastPathComponent
            }
            .prefix(max(0, limit)).map { $0 }
    }

    // MARK: - 任务：按机器分文件，合并

    /// 把 `taskboards/` 下每台机器的板子合成一份现成结论。
    ///
    /// ## 为什么不再直接读 dashboard.tasks
    ///
    /// `dashboard.json` 是**一个文件、每台机器都往里写**。里面那份 `tasks`
    /// 永远只是最后一台跑采集的机器那一刻的内容 —— 每条任务身上带着
    /// `machineName`，看起来像多机数据，实际另一台的活压根不在里面。
    /// 两台机器同时干活时，手机上的任务会随着谁最后采集**整批切换**。
    ///
    /// 快照早就是 `snapshots/<machineID>.json` 分文件再合并的，这里照抄。
    ///
    /// ## 退路
    ///
    /// `taskboards/` 一个文件都没有（老 Mac）→ 退回 `dashboard.tasks`。
    /// 有文件但一块都读不出来 → 也退回，**同时把读不到的那几块一起带上**，
    /// 否则 dashboard 那份单机数据会把「有两台读不到」盖成「就这些」。
    ///
    /// **全程在后台线程**（调用方是 nonisolated static）：iCloud 上的读
    /// 可以永久阻塞 —— 一个还没下载下来的占位符，`Data(contentsOf:)`
    /// 能等很久且没有超时。挂在主线程上就是整个界面冻住。
    private nonisolated static func taskDigest(
        root: URL, dec: JSONDecoder, dashboard: Dashboard?
    ) -> TaskDigest {
        var input = loadTaskBoards(root: root, dec: dec)

        if !input.contains(where: { $0.unreadable == nil }), let dashboard {
            // **只有 dashboard 真的带了 tasks 才退回。**
            //
            // `tasks == nil` 是老 Mac 压根没发这份数据。这时候补一块
            // 空板子进去会让 `published` 变成 true，屏幕上于是出现
            //「没有任务在跑」—— 一句它没有任何依据说出口的话。
            if let t = dashboard.tasks {
                input.append(TaskBoardLoad(
                    machineID: "", machineName: "",
                    // dashboard 自己的生成时间就是这份任务的时间。
                    // `.distantPast` 是解码时缺键的兜底，那读作「不知道」，
                    // 不是「56 年前」—— 传成日期会让每条任务都被标成古董。
                    generatedAt: dashboard.generatedAt == .distantPast
                        ? nil : dashboard.generatedAt,
                    tasks: t,
                    truncated: dashboard.tasksTruncated,
                    isFallback: true))
            }
        }
        return TaskDigest(boards: input)
    }

    /// 读 `taskboards/` 下所有板子。读不出来的**也要返回一条**，
    /// 带上原因 —— 静默跳过等于把「读不到」说成「那台没有任务」。
    private nonisolated static func loadTaskBoards(
        root: URL, dec: JSONDecoder
    ) -> [TaskBoardLoad] {
        let fm = FileManager.default
        let dir = root.appendingPathComponent("taskboards")

        // **不能加 .skipsHiddenFiles。**
        //
        // 还没下载下来的 iCloud 文件在本机是个叫 `.<原名>.icloud` 的
        // 占位符 —— 以点开头，正好被 skipsHiddenFiles 滤掉。滤掉之后
        // 那台机器**整台从列表上消失**，屏幕上看起来就像它没有任务，
        // 而真相是它的板子还在云上。这正是要区分的那两件事。
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [])
        else { return [] }  // 目录不存在 = 老 Mac，交给调用方退回 dashboard

        var out: [TaskBoardLoad] = []
        var placeholders: [String] = []
        var real = Set<String>()

        for url in entries {
            let name = url.lastPathComponent

            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                // 占位符。催一下下载，这一轮先如实说「读不到」。
                try? fm.startDownloadingUbiquitousItem(at: url)
                let stripped = URL(fileURLWithPath: String(
                    name.dropFirst().dropLast(".icloud".count)))
                guard stripped.pathExtension == "json" else { continue }
                placeholders.append(stripped.deletingPathExtension().lastPathComponent)
                continue
            }

            guard url.pathExtension == "json" else { continue }
            // 文件名就是 machineID。板子读不出来的时候这是唯一还认得出
            //「是哪一台」的东西 ——「有一台读不到」这句话没法让人去查。
            let idFromName = url.deletingPathExtension().lastPathComponent
            real.insert(idFromName)

            guard let data = readAvailableData(url) else {
                out.append(TaskBoardLoad(
                    machineID: idFromName, machineName: "", generatedAt: nil,
                    unreadable: "这块板子读不出来（iCloud 可能正在同步）"))
                continue
            }
            guard let file = try? dec.decode(TaskBoardFile.self, from: data) else {
                // 解不出来最常见的原因是只同步了半个文件。
                // 当成「这台没有任务」的话，下一轮同步完又会冒出来一批活，
                // 而中间那段时间人以为它闲着。
                out.append(TaskBoardLoad(
                    machineID: idFromName, machineName: "", generatedAt: nil,
                    unreadable: "这块板子解不出来（文件可能只同步了一半）"))
                continue
            }
            // **任务行回填机器名。** 每台机器的板子是独立文件，Mac 端写
            // 单条任务时经常不带 machineName（对它自己是废话）—— 但合并
            // 到手机上之后，没有机器名的任务就成了「不知道跑在哪」。
            let boardName = file.machineName
            let filledTasks = file.tasks.map { t -> TaskBrief in
                guard t.machineName.isEmpty, !boardName.isEmpty else { return t }
                var x = t; x.machineName = boardName; return x
            }
            out.append(TaskBoardLoad(
                // 文件名由发布路径决定，是这块板子的路由身份；内容不能
                // 把自己改报成另一台机器，否则任务会归到错误的电脑。
                machineID: idFromName,
                machineName: file.machineName,
                generatedAt: file.generatedAt,
                tasks: filledTasks,
                truncated: file.tasksTruncated,
                focusedRepoAlias: file.focusedRepoAlias,
                planned: file.planned))
        }

        // 下载到一半时，占位符和真文件会**同时**在目录里。
        // 两条都留着的话，同一台机器既报「有活」又报「读不到」——
        // 自相矛盾的两句话比其中任何一句单独错都糟。真文件读到了就以它为准。
        for id in placeholders where !real.contains(id) {
            out.append(TaskBoardLoad(
                machineID: id, machineName: "", generatedAt: nil,
                unreadable: "板子还在 iCloud 上，这台手机还没下下来"))
        }
        return out
    }

    /// 读项目清单。Mac 端只推不拉这个文件 —— 清单内容由那边说了算，
    /// 手机只能通过 approvals/ 表达「我批了」。
    private nonisolated static func loadProjects(
        root: URL, dec: JSONDecoder
    ) -> [PlaybookProject]? {
        let f = root.appendingPathComponent("playbook.json")
        if FileManager.default.fileExists(atPath: f.path) {
            guard let d = readAvailableData(f) else { return nil }
            return try? dec.decode([PlaybookProject].self, from: d)
        }
        let placeholder = root.appendingPathComponent(".playbook.json.icloud")
        return FileManager.default.fileExists(atPath: placeholder.path) ? nil : []
    }

    /// 批准一个项目方案。
    ///
    /// 不直接改 playbook.json：那个文件两边都会写（Mac 改 runs、
    /// 手机改 approvedAt），整文件同步必然丢一边。改成往 approvals/
    /// 放一个小文件，Mac 端下一轮读到就应用。
    @discardableResult
    func approveProject(_ id: String, note: String) async -> Bool {
        guard let root else { lastError = "还没连上文件夹"; return false }

        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = PlaybookApproval(
            projectID: id, approvedAt: Date(),
            device: UIDevice.current.name,
            note: trimmed.isEmpty ? nil : trimmed)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        // 和答复一样：日期策略必须显式设成 ISO8601，
        // 默认的浮点秒数 Mac 端解不出来，而且失败得很安静。
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(a) else { lastError = "批准序列化失败"; return false }
        do {
            try await commandWriter.write(data, root: root,
                                          directory: "approvals", filename: id + ".json")
            // 本地先标上，别等下一轮同步 —— 否则点完批准那一条还挂在「等你过目」里
            if let i = projects.firstIndex(where: { $0.id == id }) {
                projects[i].approvedAt = a.approvedAt
            }
            approvedPending[id] = a.approvedAt
            savePendingIntents()
            lastError = nil
            return true
        } catch {
            lastError = "写入失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 读 Mac 端下发的页面内容。
    ///
    /// freshenFirst=false 用于**首屏**：只读已经在本机且是当前版本的字节，
    /// 还在云上的页触发下载但不等 —— 「已缓存的先上屏」，云上的留给慢阶段。
    /// freshenFirst=true 用于慢阶段：先把整个 views/ 催一遍再读。
    ///
    /// 返回值带 complete：有一页没读到/解不开时为 false，调用方据此
    /// 合并而不是整包替换（见 mergeFeeds）。解不开 ≠ 没有 ——
    /// 静默丢页就是把「读不到」说成「没有」，旧画面会被一次抖动抹掉。
    ///
    /// 三种「目录层面」的情况必须分开（finding 158d91ba）：
    /// - views/ 真的不存在 → 老服务端从没发过页面，权威地为空；
    /// - views/ 在但列不出内容（或路径被占位成了普通文件）→ 这轮不可信，
    ///   complete=false，旧页面原地保留；
    /// - menu.json 不是下发页，永远跳过 —— 不跳过的话它每次都解不成
    ///   FeedPage，会把 complete 永久按在 false 上。
    nonisolated static func loadFeeds(
        root: URL, decoder dec: JSONDecoder, freshenFirst: Bool
    ) -> FeedsLoad {
        var out = FeedsLoad()
        let dir = root.appendingPathComponent("views")
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir)
        guard exists else { return out }  // 真的没有：老服务端，权威地为空
        guard isDir.boolValue,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else {
            // 路径在但不是目录、或者列不出内容（iCloud 抖动）：
            // 这一轮不可信 —— complete=false，调用方保留旧页面。
            out.complete = false
            return out
        }

        if freshenFirst { freshen(dirs: [dir], files: [], timeout: 2.5) }

        for n in names.sorted() where n.hasSuffix(".json") {
            if n == "menu.json" { continue }
            let url = dir.appendingPathComponent(n)
            guard let d = readAvailableData(url),
                  let p = try? dec.decode(FeedPage.self, from: d) else {
                // 首屏阶段走到这里多半是字节还在云上；慢阶段再催。
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                out.complete = false
                continue
            }
            out.pages[p.page] = p
        }
        // `.xxx.json.icloud` 占位符不带 .json 后缀，得单独认：
        // 它意味着这页存在但还没下来，不能算成「服务端没发这一页」。
        for n in names.sorted() where n.hasSuffix(".icloud") {
            let stripped = String(n.dropLast(".icloud".count))
            let base = stripped.hasPrefix(".") ? String(stripped.dropFirst()) : stripped
            if base.hasSuffix(".json"), base != "menu.json" {
                out.complete = false
                break
            }
        }
        return out
    }

    /// 用户点了下发的动作。
    ///
    /// **客户端不理解这个 id 是什么意思**，原样写回去，Mac 端解释。
    /// 加一种新动作因此不需要动客户端。
    @discardableResult
    func invoke(_ action: FeedAction, note: String?) async -> Bool {
        guard let root else { lastError = "还没连上文件夹"; return false }
        guard MobileActionRoute.parse(action.id) != nil else {
            lastError = "操作缺少可靠的来源机器，请更新 Mac 后刷新。"; return false
        }
        let resource = MobileActionRoute.reviewResourceKey(action.id) ?? MobileActionRoute.resourceKey(action.id)
        guard !actionWritesInFlight.contains(resource),
              !hasPendingReviewAction(action.id),
              actionSubmission(for: action.id)?.preventsResubmission != true else { return false }
        let generation = connectionGeneration
        actionWritesInFlight.insert(resource)
        defer { if generation == connectionGeneration { actionWritesInFlight.remove(resource) } }
        let submission = MobileActionSubmission(actionID: action.id,
            invocationID: UUID().uuidString, submittedAt: Date())
        struct Envelope: Encodable {
            let id: String; let invocationID: String; let at: Date; let device: String; let note: String?
        }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(Envelope(id: action.id, invocationID: submission.invocationID,
            at: submission.submittedAt, device: UIDevice.current.name, note: note)) else { return false }
        do {
            try await commandWriter.write(
                data, root: root, directory: "actions",
                filename: MobileActionRoute.receiptName(actionID: action.id, invocationID: submission.invocationID))
            guard generation == connectionGeneration else { return false }
            actionSubmissions[action.id] = submission
            savePendingIntents()
            lastError = nil
            return true
        } catch {
            guard generation == connectionGeneration else { return false }
            lastError = "写入失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 只读取本机实际提交过、尚未收到终态的请求；不把别台/旧请求的回执贴过来。
    func refreshActionReceipts() async {
        guard let root else { return }
        let generation = connectionGeneration
        let pending = actionSubmissions.values.filter { $0.receipt?.isTerminal != true }
        guard !pending.isEmpty else { return }
        let receipts = await Task.detached(priority: .utility) {
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            return pending.compactMap { submission -> MobileActionReceipt? in
                let name = MobileActionRoute.receiptName(actionID: submission.actionID,
                                                        invocationID: submission.invocationID)
                let url = root.appendingPathComponent("action-receipts/" + name)
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                guard let data = Self.readAvailableData(url) else { return nil }
                guard let receipt = try? dec.decode(MobileActionReceipt.self, from: data),
                      receipt.actionID == submission.actionID,
                      receipt.invocationID == submission.invocationID else { return nil }
                return receipt
            }
        }.value
        guard generation == connectionGeneration else { return }
        for receipt in receipts {
            guard var submission = actionSubmissions[receipt.actionID],
                  submission.invocationID == receipt.invocationID,
                  submission.receipt?.isTerminal != true,
                  MobileActionRoute.parse(receipt.actionID)?.scope == MobileActionRoute.digest(receipt.machineID),
                  ["running", "retrying", "succeeded", "failed"].contains(receipt.state),
                  receipt.updatedAt >= (submission.receipt?.updatedAt ?? .distantPast) else { continue }
            submission.receipt = receipt
            actionSubmissions[receipt.actionID] = submission
        }
        savePendingIntents()
    }

    /// 现有配置回执没有稳定机器 ID：必须同时核对同目录中已处理的原始
    /// plan-go 意图的请求 UUID、目标机器和计划。接受回执不被当成已入队。
    func refreshPlanReceipts() async {
        guard let root else { return }
        let generation = connectionGeneration
        let pending = planReleases.values.filter { $0.accepted == nil }
        guard !pending.isEmpty else { return }
        struct Reply: Sendable { var record: PlanReleaseRecord; var accepted: Bool; var note: String }
        let replies = await Task.detached(priority: .utility) { () -> [Reply] in
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            let directory = root.appendingPathComponent("config-intents/processed")
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
            let formatter = ISO8601DateFormatter()
            var replies: [Reply] = []
            for record in pending {
                for file in files.sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
                    where file.lastPathComponent.hasSuffix("-" + record.invocationID + ".result.json") {
                    let original = directory.appendingPathComponent(String(file.lastPathComponent.dropLast(".result.json".count)) + ".json")
                    try? FileManager.default.startDownloadingUbiquitousItem(at: file)
                    try? FileManager.default.startDownloadingUbiquitousItem(at: original)
                    guard let data = Self.readAvailableData(file), data.count <= 16_384,
                          let intentData = Self.readAvailableData(original), intentData.count <= 16_384,
                          let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let intent = try? JSONSerialization.jsonObject(with: intentData) as? [String: Any],
                          receipt["id"] as? String == record.invocationID,
                          intent["id"] as? String == record.invocationID,
                          intent["kind"] as? String == "plan-go",
                          intent["targetMachineID"] as? String == record.machineID,
                          intent["planID"] as? String == record.planID,
                          let accepted = receipt["accepted"] as? Bool,
                          let stamp = receipt["processedAt"] as? String,
                          formatter.date(from: stamp) != nil else { continue }
                    // 请求身份决定因果；Mac 与手机的墙钟可能不同步。
                    // 不能把有效拒绝按跨机时间先后丢弃，否则按钮会一直禁用。
                    replies.append(Reply(record: record, accepted: accepted,
                        note: String((receipt["note"] as? String ?? "Mac 拒绝了这次放行，请核对计划后重试").prefix(1_000))))
                    break
                }
            }
            return replies
        }.value
        guard generation == connectionGeneration else { return }
        for reply in replies {
            let key = PlanView.releaseKey(machineID: reply.record.machineID, planID: reply.record.planID)
            guard var current = planReleases[key], current.invocationID == reply.record.invocationID else { continue }
            current.accepted = reply.accepted
            current.failure = reply.accepted ? nil : reply.note
            planReleases[key] = current
            if !reply.accepted { planPending.removeValue(forKey: key) }
        }
        savePendingIntents()
    }

    func planReleaseFailure(machineID: String, planID: String) -> String? {
        planReleases[PlanView.releaseKey(machineID: machineID, planID: planID)]?.failure
    }

    /// 读一张证据截图。
    ///
    /// 图在共享目录的 `evidence/<目录>/<文件>`，Mac 端已经压到宽 800
    ///（原图一张 4.7MB，压完 80KB）。读一次缓存一次 —— 列表滚动时
    /// 每个缩略图都会问一遍，不缓存会反复读盘。
    private static let evidenceCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 80
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    private static func clearMediaCaches() {
        evidenceCache.removeAllObjects()
        videoCache.removeAllObjects()
    }

    /// 这份证据是不是录屏。
    ///
    /// **判据必须和 Mac 端 `Review.isVideoName` 一致** —— 分叉的话会出现
    /// 「Mac 抽出来了、手机不认」这种静默失败：文件明明在共享目录里，
    /// 界面上却是个永远转圈的占位框。
    static func isVideo(_ file: String) -> Bool {
        let l = file.lowercased()
        return l.hasSuffix(".mp4") || l.hasSuffix(".mov") || l.hasSuffix(".m4v")
    }

    private static let videoCache: NSCache<NSString, NSURL> = {
        let cache = NSCache<NSString, NSURL>()
        cache.countLimit = 20
        return cache
    }()

    private static func mediaKey(root: URL, file: String) -> NSString {
        (root.path + "\u{1}" + file) as NSString
    }

    /// 录屏取一份可播放的本地副本。
    ///
    /// 不把 iCloud 里那个 URL 直接交给播放器：那份文件在
    /// security-scoped 目录里，而播放器持有 URL 的时间远长于我们能
    /// 保持访问权的时间，播到一半会断。拷到临时目录再播 ——
    /// Mac 端压过的录屏一段一两 MB，这点代价可以忽略。
    /// 后台版:把录屏从 iCloud 取到本地临时文件。
    ///
    /// **必须在主线程之外调。** 同步版把整段 7MB 录屏读进内存再写盘,
    /// 一次验收好几段,主线程一卡就是几十秒 —— iOS 看门狗直接杀进程。
    /// 老板 2026-08-22:「移动端待我审批太多了之后会卡死」「崩溃了好几次」。
    func localVideoURLAsync(file: String) async -> URL? {
        guard let root else { return nil }
        let key = Self.mediaKey(root: root, file: file)
        if let hit = Self.videoCache.object(forKey: key) as URL?,
           (try? hit.checkResourceIsReachable()) == true { return hit }
        let url = await Task.detached(priority: .utility) {
            Store.fetchToTemp(root: root, file: file)
        }.value
        if let url { Self.videoCache.setObject(url as NSURL, forKey: key) }
        return url
    }

    /// 真正干重活的那一段 —— **不属于任何 actor,可以在后台跑**。
    /// 读 iCloud 上的文件可能要先下载,再整个读进内存写临时文件;
    /// 这件事放在主线程上就是几十秒的卡顿(见 localVideoURLAsync 的说明)。
    nonisolated static func fetchToTemp(root: URL, file: String) -> URL? {
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        let src = root.appendingPathComponent("evidence").appendingPathComponent(file)
        freshen(dirs: [], files: [src], timeout: 2.5)
        guard let d = readAvailableData(src) else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmq-evidence-videos", isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        let digest = StableID.make(namespace: "evidence-video", parts: [root.path, file])
        let ext = URL(fileURLWithPath: file).pathExtension
        let dst = dir.appendingPathComponent(ext.isEmpty ? digest : digest + "." + ext)
        guard (try? d.write(to: dst, options: .atomic)) != nil else { return nil }
        return dst
    }

    nonisolated static func loadImage(root: URL, file: String) -> UIImage? {
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        let url = root.appendingPathComponent("evidence").appendingPathComponent(file)
        freshen(dirs: [], files: [url], timeout: 2.5)
        guard let d = readAvailableData(url) else { return nil }
        return UIImage(data: d)
    }

    /// 后台版:读证据图片。同上,`Data(contentsOf:)` 对 iCloud 占位符会阻塞。
    func loadEvidenceAsync(file: String) async -> UIImage? {
        guard let root else { return nil }
        let key = Self.mediaKey(root: root, file: file)
        if let hit = Self.evidenceCache.object(forKey: key) { return hit }
        let img = await Task.detached(priority: .utility) {
            Store.loadImage(root: root, file: file)
        }.value
        if let img {
            let cost = Int(img.size.width * img.size.height * img.scale * img.scale * 4)
            Self.evidenceCache.setObject(img, forKey: key, cost: cost)
        }
        return img
    }

    /// 验收一份产出：合入或丢弃。
    ///
    /// 写入带机器和版本的动作，Mac 回传实际执行状态；合入前仍运行验收。
    /// 跑不过不会合。手机这边只表达意愿，不做判断。
    @discardableResult
    func decideReview(_ d: ReviewDigest, action: String, reason: String?) async -> Bool {
        guard ["merge", "discard", "continue"].contains(action), let id = d.actionID(action) else {
            lastError = "成果缺少来源机器，请更新 Mac 后刷新。"; return false
        }
        guard reviewSubmission(d)?.preventsResubmission != true else { return false }
        if action == "continue", !canContinueReview(d) { return false }
        if action != "continue", !canDisposeReview(d) { return false }
        if action == "merge", let block = d.confirmationBlockReason {
            lastError = block; return false
        }
        return await invoke(FeedAction(id: id, label: action == "continue" ? "保留成果，继续完善"
            : (action == "merge" ? "合入" : "丢弃")), note: reason)
    }

    func hasPendingReviewAction(_ id: String) -> Bool {
        guard let key = MobileActionRoute.reviewResourceKey(id) else { return false }
        return actionSubmissions.values.contains {
            MobileActionRoute.reviewResourceKey($0.actionID) == key
                && $0.receipt?.state != "succeeded" && $0.receipt?.state != "failed"
        }
    }

    func canContinueReview(_ review: ReviewDigest) -> Bool {
        guard let id = review.actionID("continue"), review.continuationBlockReason == nil else { return false }
        return reviewSubmission(review)?.preventsResubmission != true
            && actionSubmission(for: id)?.preventsResubmission != true && !hasPendingReviewAction(id)
    }

    func canDisposeReview(_ review: ReviewDigest) -> Bool {
        guard let id = review.actionID("merge") else { return false }
        return reviewSubmission(review)?.preventsResubmission != true && !hasPendingReviewAction(id)
            && review.actionID("continue").flatMap { actionSubmission(for: $0) }?.receipt?.state != "succeeded"
    }

    func reviewSubmission(_ review: ReviewDigest) -> MobileActionSubmission? {
        review.actionID("merge").flatMap { actionSubmission(for: $0) }
    }

    func canConfirmReview(_ review: ReviewDigest) -> Bool {
        review.confirmationBlockReason == nil
            && canDisposeReview(review)
    }

    var actionableReviews: [ReviewDigest] { reviews.filter { canConfirmReview($0) } }
    var unavailableReviews: [ReviewDigest] { reviews.filter { !canConfirmReview($0) } }

    struct ActionInbox {
        var questions: [Ask]
        var projects: [PlaybookProject]
        var reviews: [ReviewDigest]
        var plannedCount: Int
        var count: Int { questions.count + projects.count + reviews.count + plannedCount }
    }

    /// 所有入口只投影现有事实与已提交意图，不另外保存一份待办状态。
    var actionInbox: ActionInbox {
        ActionInbox(questions: asks, projects: projects.filter { !$0.isApproved },
            reviews: actionableReviews, plannedCount: taskDigest.rawBoards.reduce(0) { count, board in
                count + (board.planned ?? []).filter {
                    !isPlanPending(machineID: board.machineID, planID: $0.id)
                }.count
            })
    }
    func isPlanPending(machineID: String, planID: String) -> Bool {
        let key = PlanView.releaseKey(machineID: machineID, planID: planID)
        return planWritesInFlight.contains(key)
            || (planPending[key].map { Date().timeIntervalSince($0) < 7 * 86400 } ?? false)
    }

    func actionSubmission(for id: String) -> MobileActionSubmission? {
        let resource = MobileActionRoute.resourceKey(id)
        return actionSubmissions.values.filter { MobileActionRoute.resourceKey($0.actionID) == resource }
            .max { $0.submittedAt < $1.submittedAt }
    }

    /// 回答一个问题。写进 answers/<machineID>/<taskID>.json。
    ///
    /// 答案必须带上 askID —— Mac 端只有在任务仍然 blocked **且** askID
    /// 和它当前挂着的那个问题对得上时才采纳。少了这一层，一份迟到的答复
    /// 会把一个已经完成的任务复活重跑，白烧一次额度。
    func answer(ask: Ask, replies: [String: String], abandon: Bool) async -> Bool {
        guard let root else { lastError = "还没连上文件夹"; return false }

        let env = AskAnswer(askID: ask.id, taskID: ask.taskID, machineID: ask.machineID,
                            answeredAt: Date(),
                            answers: replies.filter { !$0.value.trimmingCharacters(
                                in: .whitespacesAndNewlines).isEmpty },
                            abandon: abandon)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        // **日期策略必须显式设**。默认是 secondsSince1970 的浮点数，
        // 而 Mac 端用 ISO8601 解 —— 不设的话答复信封解不出来，
        // 而且失败得很安静：文件写成功了，Mac 那边只是当成坏文件跳过。
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(env) else { lastError = "答复序列化失败"; return false }

        do {
            let filename = StableID.make(namespace: "ask-answer", parts: [ask.id])
            try await commandWriter.write(
                data, root: root, directory: "answers/\(ask.machineID)",
                filename: "\(filename).json")
            // 本地先把它拿掉，别等下一次 reload —— 否则刚回答完还看得见它。
            answeredPending[ask.id] = env.answeredAt
            savePendingIntents()
            asks.removeAll { $0.id == ask.id }
            lastError = nil
            return true
        } catch {
            lastError = "写入失败：\(error.localizedDescription)"
            return false
        }
    }

    private nonisolated static func requestDownloads(in dir: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: []) else { return }
        for url in entries where url.pathExtension == "icloud" {
            try? fm.startDownloadingUbiquitousItem(at: url)
        }
    }

    /// 只读已经在本机且确认是当前版本的字节。
    ///
    /// `Data(contentsOf:)` 自己没有超时，碰到 iCloud 占位符可能无限等；
    /// Task cancellation 也不能中断这个同步系统调用。所以超时后不能“再试着读”，
    /// 而是本轮保留旧数据，等下载完成后的下一轮刷新。
    private nonisolated static func readAvailableData(_ url: URL) -> Data? {
        if url.pathExtension == "icloud" { return nil }
        if let status = try? url.resourceValues(
            forKeys: [.ubiquitousItemDownloadingStatusKey]
        ).ubiquitousItemDownloadingStatus, status != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return nil
        }
        return try? Data(contentsOf: url)
    }

    /// 把这些目录里**过期**的文件催成最新，再限时等它们下完。
    ///
    /// ## 为什么占位符逻辑不够（「不实时」的根因）
    ///
    /// `.icloud` 占位符只出现在**从没下载过**的文件上。下载过一次、
    /// 云上有了新版本的文件在本机是个普通文件 —— `Data(contentsOf:)`
    /// 不报任何错，安安静静给你旧字节。iOS 不会主动替你拉更新：
    /// 不催的话，手机显示的永远是它上次心血来潮同步的那一版。
    /// 判据是 `ubiquitousItemDownloadingStatus != .current`，
    /// 对这种文件 `startDownloadingUbiquitousItem` 一样有效。
    ///
    /// ## 为什么要等、又为什么只等一小会
    ///
    /// 催完立刻读，读到的还是旧的，「下拉刷新」就成了「下拉预约下一次」。
    /// 但 iCloud 上的等待没有天然上限（Mac 端在这上面冻死过菜单栏）——
    /// 所以限时：到点没下完就先读现有的，下一轮自然会读到新的。
    /// 全程在后台线程，堵的只是转圈时间。
    private nonisolated static func freshen(dirs: [URL], files: [URL],
                                            timeout: TimeInterval = 2.5) {
        let fm = FileManager.default
        var candidates = files
        for dir in dirs {
            if let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: []) {
                candidates.append(contentsOf: entries)
            }
        }
        var pending: [String] = []
        for url in candidates {
            if url.pathExtension == "icloud" {
                try? fm.startDownloadingUbiquitousItem(at: url)
                continue   // 占位符没有「读旧字节」问题，别让它拖住限时等待
            }
            let vals = try? url.resourceValues(
                forKeys: [.ubiquitousItemDownloadingStatusKey])
            guard let status = vals?.ubiquitousItemDownloadingStatus,
                  status != .current else { continue }
            try? fm.startDownloadingUbiquitousItem(at: url)
            pending.append(url.path)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !pending.isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.15)
            pending.removeAll { path in
                // 每次用新 URL 查：resourceValues 有缓存，旧 URL 会把
                // 「已下完」一直报成「还没好」，白等满整个限时。
                let vals = try? URL(fileURLWithPath: path).resourceValues(
                    forKeys: [.ubiquitousItemDownloadingStatusKey])
                return (vals?.ubiquitousItemDownloadingStatus ?? .current) == .current
            }
        }
    }

    // MARK: - 写（只往 inbox 投任务）

    /// 把任务投进收件箱。Mac 上的常驻循环会捞走。
    func submit(prompt: String, repo: String?, platform: String? = nil,
                machineID: String? = nil,
                machineName: String? = nil) async -> SubmissionReceipt? {
        guard let root else { lastError = "还没连上文件夹"; return nil }

        // 用 json 而不是 txt：txt 只能带提示词，指定不了仓库。
        // platform 是「点名让谁干」。Mac 端把它当**优先**不是命令 ——
        // 点名一个接不了这活的人，岗位规则照样会拦下来换人。
        struct Envelope: Codable {
            var prompt: String; var repo: String?; var platform: String?
            /// 点名哪台机器干。仓库只在一台机器上有目录时必须带 ——
            /// 让别的机器抢走就是一次注定失败的白跑。老 Mac 不认识这俩字段，
            /// 解码会忽略（Mac 端是 decodeIfPresent），不会因此丢任务。
            var machineID: String?; var machineName: String?
        }
        let env = Envelope(prompt: prompt, repo: repo, platform: platform,
                           machineID: machineID, machineName: machineName)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? enc.encode(env) else {
            lastError = "任务序列化失败"; return nil
        }

        // 时间只方便排序，UUID 才负责保证同一秒内连续投递不互相覆盖。
        let submittedAt = Date()
        let requestID = UUID().uuidString
        let stamp = ISO8601DateFormatter().string(from: submittedAt)
            .replacingOccurrences(of: ":", with: "")
        let filename = "phone-\(stamp)-\(requestID).json"
        do {
            try await commandWriter.write(data, root: root,
                                          directory: "inbox", filename: filename)
            lastError = nil
            let receipt = SubmissionReceipt(
                requestID: requestID, filename: filename, submittedAt: submittedAt,
                prompt: prompt, repo: repo, platform: platform,
                machineID: machineID, machineName: machineName)
            lastSubmissionReceipt = receipt
            return receipt
        } catch {
            lastError = "写入失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// nil = 当前没连接，不能判断；true = 仍在收件箱，false = 已被某台 Mac 抢走。
    func submissionIsWaiting(_ receipt: SubmissionReceipt) -> Bool? {
        guard let root else { return nil }
        return FileManager.default.fileExists(
            atPath: root.appendingPathComponent("inbox/" + receipt.filename).path)
    }

    /// Mac 领取后会把任务状态写进 outbox。旧协议没有显式 requestID，
    /// 只能在投递时间之后按完整 prompt 对上；同文重复投递时取最早出现的一条。
    func result(for receipt: SubmissionReceipt) -> TaskResult? {
        let cutoff = receipt.submittedAt.addingTimeInterval(-5)
        let sentPrompt = String(receipt.prompt.prefix(500))
        return results
            .filter { $0.updatedAt >= cutoff && $0.prompt == sentPrompt }
            .sorted { $0.updatedAt < $1.updatedAt }
            .first
    }

    // MARK: - 写（调度留白的意图）

    /// 手机上改「给这个平台留多少白」。
    ///
    /// **写意图文件，不直接改 config/roles.json。**
    ///
    /// 那份配置是多机共享的，而手机端的 `AgentRole` 只是它的一个子集 ——
    /// 手机不认识的键（比如各机器的安装路径）在读进来的时候就丢了，
    /// 原样写回去等于把它们静默洗掉。这个坑这个项目**已经踩过一次**：
    /// 一台机器用旧二进制写了共享配置，把另一台刚写进去的 pathByMachine
    /// 整个抹掉，两边都没有任何报错。
    ///
    /// 所以手机只声明「我想让 minimax 留 20%」，Mac 端用带合并的正规路径落地。
    /// 处理完 Mac 会把文件挪到 config-intents/processed/ 而不是删掉 ——
    /// 删了的话手机上会看到文件凭空消失，让人怀疑根本没送达。
    /// 放行某台机器计划清单里的一条 —— 写 plan-go 意图。
    ///
    /// **必须带 targetMachineID**：计划清单按机器存，抢占是先移者赢、
    /// 移走即消费 —— 不带目标的话，另一台机器把它抢走，这条放行就永久丢了
    /// （那台的清单里没有这个 id，回执写「已放行过或被删了」，全是误导）。
    func releasePlan(machineID: String, planID: String) async -> Bool {
        guard let root else { lastError = "还没连上文件夹"; return false }
        guard !machineID.isEmpty else { lastError = "这块板子没带机器 ID，放行发不出去"; return false }

        let key = PlanView.releaseKey(machineID: machineID, planID: planID)
        guard !isPlanPending(machineID: machineID, planID: planID) else { return false }
        let generation = connectionGeneration
        planWritesInFlight.insert(key)
        defer { if generation == connectionGeneration { planWritesInFlight.remove(key) } }
        struct Intent: Codable {
            var id: String
            var createdAt: Date
            var source: String
            var kind: String
            var platform: String
            var planID: String
            var targetMachineID: String
        }
        let id = UUID().uuidString
        let intent = Intent(id: id, createdAt: Date(), source: "phone",
                            kind: "plan-go", platform: "",
                            planID: planID, targetMachineID: machineID)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601   // Mac 按 ISO8601 解，见 setReserve 的注释
        guard let data = try? enc.encode(intent) else {
            lastError = "放行意图序列化失败"; return false
        }
        do {
            try await commandWriter.write(data, root: root,
                                          directory: "config-intents",
                                          filename: "\(id).json")
            guard generation == connectionGeneration else { return false }
            planPending[key] = intent.createdAt
            planReleases[key] = PlanReleaseRecord(invocationID: intent.id, machineID: machineID,
                planID: planID, submittedAt: intent.createdAt)
            savePendingIntents()
            lastError = nil
            return true
        } catch {
            guard generation == connectionGeneration else { return false }
            lastError = "写入失败：\(error.localizedDescription)"
            return false
        }
    }

    func setReserve(platform: String, fraction: Double) async -> Bool {
        guard let root else { lastError = "还没连上文件夹"; return false }
        guard fraction.isFinite, fraction >= 0, fraction <= 0.95 else {
            lastError = "留白只能在 0% 到 95% 之间，没有写出去"; return false
        }
        guard !platform.isEmpty else { lastError = "缺少平台，没有写出去"; return false }
        let generation = connectionGeneration
        let previous = reserveSubmissions[platform]?.requestedAt ?? 0
        let published = dashboard?.reports.first { $0.platform == platform }?.role?.reserveUpdatedAt ?? 0
        let stamp = max(Date().timeIntervalSince1970, max(previous, published) + 0.001)
        let id = UUID().uuidString
        struct Intent: Codable {
            var id: String; var createdAt: Date; var source = "phone"; var kind = "reserve"
            var platform: String; var fraction: Double; var requestedAt: Double
        }
        let intent = Intent(id: id, createdAt: Date(timeIntervalSince1970: stamp),
                            platform: platform, fraction: fraction, requestedAt: stamp)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(intent) else { return false }
        // await 前保留请求身份，页面重进和进程重启仍能等待这一条的回执。
        reserveSubmissions[platform] = ReserveSubmission(id: id, platform: platform,
            fraction: fraction, requestedAt: stamp)
        savePendingIntents()
        do {
            try await commandWriter.write(data, root: root, directory: "config-intents", filename: id + ".json")
            guard generation == connectionGeneration else { return false }
            if reserveSubmissions[platform]?.id == id { lastError = nil }
            return true
        } catch {
            guard generation == connectionGeneration else { return false }
            if reserveSubmissions[platform]?.id == id {
                reserveSubmissions[platform]?.accepted = false
                reserveSubmissions[platform]?.note = "写入失败：" + error.localizedDescription
                lastError = reserveSubmissions[platform]?.note
                savePendingIntents()
            }
            return false
        }
    }

    func refreshReserveReceipts() async {
        guard let root else { return }
        let generation = connectionGeneration
        let pending = reserveSubmissions.values.filter { $0.accepted == nil }
        guard !pending.isEmpty else { return }
        let replies = await Task.detached(priority: .utility) { () -> [ReserveSubmission] in
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            let dir = root.appendingPathComponent("config-intents/processed")
            let files = (try? FileManager.default.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: nil)) ?? []
            var replies: [ReserveSubmission] = []
            for var record in pending {
                for file in files where file.lastPathComponent.hasSuffix("-" + record.id + ".result.json") {
                    let original = dir.appendingPathComponent(String(file.lastPathComponent
                        .dropLast(".result.json".count)) + ".json")
                    try? FileManager.default.startDownloadingUbiquitousItem(at: file)
                    try? FileManager.default.startDownloadingUbiquitousItem(at: original)
                    guard let data = Self.readAvailableData(file), data.count <= 16384,
                        let source = Self.readAvailableData(original), source.count <= 16384,
                        let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                        let intent = try? JSONSerialization.jsonObject(with: source) as? [String: Any],
                        receipt["id"] as? String == record.id, intent["id"] as? String == record.id,
                        intent["kind"] as? String == "reserve", intent["platform"] as? String == record.platform,
                        intent["fraction"] as? Double == record.fraction,
                        intent["requestedAt"] as? Double == record.requestedAt,
                        let processedAt = receipt["processedAt"] as? String,
                        ISO8601DateFormatter().date(from: processedAt) != nil,
                        let accepted = receipt["accepted"] as? Bool else { continue }
                    record.accepted = accepted
                    record.note = String((receipt["note"] as? String ?? "Mac 已处理此次请求").prefix(1000))
                    replies.append(record)
                    break
                }
            }
            return replies
        }.value
        guard generation == connectionGeneration else { return }
        for reply in replies where reserveSubmissions[reply.platform]?.id == reply.id {
            reserveSubmissions[reply.platform] = reply
        }
        // 当前生效配置也携带精确请求身份，可在归档尚未同步时确认。
        for report in dashboard?.reports ?? [] {
            guard var record = reserveSubmissions[report.platform], record.accepted == nil,
                report.role?.reserveIntentID == record.id,
                report.role?.reserveFraction == record.fraction else { continue }
            record.accepted = true
            record.note = "Mac 已采纳此次设置"
            reserveSubmissions[report.platform] = record
        }
        savePendingIntents()
    }

    /// 手机上只提交岗位的可编辑字段，由 Mac 合并进完整 AgentRole。
    /// 指挥身份、机器静音、留白等字段不在信封里，因此旧客户端不可能洗掉它们。
    func updateRole(platform: String, title: String, maxRisk: String,
                    tierLimit: String, prefers: [String], note: String) async -> Bool {
        guard let root else { lastError = "还没连上文件夹"; return false }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, cleanTitle.count <= 30 else {
            lastError = "岗位名必须是 1–30 个字符"; return false
        }
        guard ["safe", "normal", "sensitive"].contains(maxRisk) else {
            lastError = "风险上限不受支持"; return false
        }
        guard ["auto", "trivial", "standard", "complex"].contains(tierLimit) else {
            lastError = "难度上限不受支持"; return false
        }
        guard cleanNote.count <= 200 else {
            lastError = "岗位说明不能超过 200 个字符"; return false
        }

        struct Intent: Codable {
            var id: String
            var createdAt: Date
            var source: String
            var kind: String
            var platform: String
            var title: String
            var maxRisk: String
            var tierLimit: String
            var prefers: [String]
            var note: String
        }
        let id = UUID().uuidString
        let intent = Intent(id: id, createdAt: Date(), source: "phone", kind: "role",
                            platform: platform, title: cleanTitle, maxRisk: maxRisk,
                            tierLimit: tierLimit, prefers: prefers, note: cleanNote)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(intent) else {
            lastError = "岗位修改序列化失败"; return false
        }
        do {
            try await commandWriter.write(data, root: root,
                                          directory: "config-intents",
                                          filename: "\(id).json")
            lastError = nil
            return true
        } catch {
            lastError = "写入失败：\(error.localizedDescription)"
            return false
        }
    }
}
