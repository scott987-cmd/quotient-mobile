import SwiftUI
import UserNotifications
import UIKit

/// 保留发送正文，并按通知快照 ID / 来源机器定位；旧通知仍按页面兼容。
struct NotificationDestination: Identifiable, Equatable {
    let page: String
    let notificationID: String?
    let sourcePage: String
    let message: String?
    let id = UUID().uuidString

    init?(userInfo: [AnyHashable: Any]) {
        let aps = userInfo["aps"] as? [String: Any]
        let alert = aps?["alert"] as? [String: Any]
        let body = alert?["body"] as? String
        let rawPage = userInfo["page"] as? String
        let known = rawPage.flatMap { Self.validPage($0) ? $0 : nil }
        guard known != nil || !(body ?? "").isEmpty else { return nil }
        page = known ?? "now"
        notificationID = (userInfo["notificationID"] as? String).flatMap {
            Self.validID($0) ? $0 : nil
        }
        sourcePage = (userInfo["sourcePage"] as? String).flatMap {
            Self.validPage($0) ? $0 : nil
        } ?? page
        message = body
    }

    static func validID(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func validPage(_ value: String) -> Bool {
        if ["review", "blocked", "playbook", "roadmap", "collaboration", "now"]
            .contains(value) { return true }
        return ["review-", "blocked-", "playbook-"].contains { prefix in
            value.hasPrefix(prefix) && validID(String(value.dropFirst(prefix.count)))
        }
    }

    var title: String {
        switch page {
        case "review": return "成果复核"
        case "blocked": return "风险放行"
        case "playbook": return "项目方案"
        case "roadmap": return "项目进度"
        case "collaboration": return "Agent 协作"
        default: return "需要你处理"
        }
    }
}

/// 推送：让手机在**该找你的时候**主动响一下。
///
/// ## 为什么之前一次都没收到过
///
/// 因为整个 App 里一行通知代码都没有。审批界面做了、看板做了、
/// 办公室做了 —— 唯独没有「主动来找你」这一步，全靠人主动打开 App。
/// 而一个不被打开的 App，防浪费率是 0。
///
/// ## 通路
///
///     App 启动 → 申请通知权限 → 拿 APNs device token
///        ↓ 写进 iCloud 共享目录（Mac 端已经在读这个目录）
///     Mac 端 llmq → 有事发生 → 用 .p8 签 JWT → POST api.push.apple.com
///        ↓
///     手机横幅
///
/// device token 走已有的 iCloud 通道传给 Mac，**不需要任何服务器** ——
/// 这台 Mac 自己就是服务端。
@MainActor
final class PushRegistrar: NSObject, ObservableObject {

    @Published var authorized = false
    @Published var token: String?
    /// 最近一次出错的原因。给「设置」页显示用 ——
    /// 推送不通时人得能看出来卡在哪一步，而不是干等。
    @Published var lastError: String?
    /// 用户点通知后要打开的服务端页面。RootView 通过 sheet 消费。
    @Published var destination: NotificationDestination?

    /// 共享目录（用户选的那个 iCloud 里的 LLMQuotaBar 文件夹）。
    /// 由 Store 在连上之后塞进来。
    private var sharedRoot: URL?

    func attachSharedRoot(_ root: URL?) {
        sharedRoot = root
        guard let token else { return }
        writeToken(hex: token, to: root)
    }

    /// 启动时做的事：**只注册，不弹窗。**
    ///
    /// `registerForRemoteNotifications` 拿的是 device token，本身不弹任何东西 ——
    /// 有了它，Mac 端就能推静默通知（比如同步角标）。
    /// 而 `requestAuthorization` 会弹系统权限框，那个必须等到有上下文再问。
    func start() {
        UNUserNotificationCenter.current().delegate = self
        UIApplication.shared.registerForRemoteNotifications()
        refreshAuthorizationState()
        #if DEBUG
        if let json = ProcessInfo.processInfo.environment["LLMQ_NOTIFICATION_JSON"],
           let data = json.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            destination = NotificationDestination(userInfo: payload)
        }
        #endif
    }

    /// 系统里现在到底授没授权。人可能在设置里改过，每次回前台都要重读。
    func refreshAuthorizationState() {
        // 用 async 版本：闭包版的 UNNotificationSettings 不是 Sendable，
        // 跨到 MainActor 会被并发检查拦下。
        Task { @MainActor in
            let s = await UNUserNotificationCenter.current().notificationSettings()
            self.authorized = s.authorizationStatus == .authorized
                || s.authorizationStatus == .provisional
            self.asked = s.authorizationStatus != .notDetermined
        }
    }

    /// 系统权限框问过没有。
    ///
    /// **只有一次机会。** iOS 上被拒之后再调 requestAuthorization 不会
    /// 再弹，人得自己去设置里翻 —— 所以不能在启动时白白花掉这一次，
    /// 那时候人还什么都没看到，本能就是点「不允许」。
    @Published var asked = false

    /// 真的去问系统要权限。**调用方要保证此刻人知道自己为什么被问。**
    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let ok = (try? await center.requestAuthorization(
            options: [.alert, .sound, .badge])) ?? false
        await MainActor.run {
            self.authorized = ok
            self.asked = true
            UIApplication.shared.registerForRemoteNotifications()
        }
        return ok
    }

    /// 去系统设置里开 —— 已经拒过一次的人只有这条路。
    @MainActor
    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// 把 device token 写给 Mac 端。
    ///
    /// 一台手机一个文件（按 token 前 8 位命名）—— 以后多设备时天然不打架，
    /// 而且 Mac 端读目录就知道要推给几台。
    func publish(token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        self.token = hex
        writeToken(hex: hex, to: sharedRoot)
    }

    private func writeToken(hex: String, to root: URL?) {
        guard let root else { return }
        let payload: [String: Any] = [
            "token": hex,
            "device": UIDevice.current.name,
            "system": UIDevice.current.systemVersion,
            // APNs token 和 Bundle ID 强绑定。把 topic 跟设备一起登记，避免应用
            // 改包名后 Mac 仍用旧配置发送，表现成“配置都正常但手机收不到”。
            "bundleID": Bundle.main.bundleIdentifier ?? "",
            // 沙盒和生产是两套 APNs 主机，推错了会一直静默失败。
            // TestFlight/App Store 装的是 production，Xcode 直连装的是 sandbox。
            "environment": Self.isSandbox ? "sandbox" : "production",
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.prettyPrinted])
        else { lastError = "推送 token 序列化失败"; return }

        Task { @MainActor in
            let error = await Task.detached(priority: .utility) { () -> String? in
                let dir = root.appendingPathComponent("push-tokens")
                let ok = root.startAccessingSecurityScopedResource()
                defer { if ok { root.stopAccessingSecurityScopedResource() } }
                do {
                    try FileManager.default.createDirectory(
                        at: dir, withIntermediateDirectories: true)
                    try data.write(
                        to: dir.appendingPathComponent(String(hex.prefix(8)) + ".json"),
                        options: .atomic)
                    return nil
                } catch {
                    return "推送 token 写入失败：\(error.localizedDescription)"
                }
            }.value
            // 目录已经切换时，旧写入结果不再污染当前连接的错误状态。
            guard self.sharedRoot == root else { return }
            self.lastError = error
        }
    }

    /// 这个构建连的是沙盒还是生产 APNs。
    ///
    /// 判据是 embedded.mobileprovision 里有没有 `aps-environment: development`。
    /// TestFlight 和 App Store 的包没有这个文件 —— 那就是生产。
    static var isSandbox: Bool {
        guard let url = Bundle.main.url(forResource: "embedded",
                                        withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1)
        else { return false }
        return text.contains("<key>aps-environment</key>")
            && text.contains("<string>development</string>")
    }
}

/// 和服务端同契约；详情不进全局 feed 扫描，只在点通知时读一份。
struct NotificationDetailRecord: Decodable {
    let id: String
    let createdAt: Date
    let sourcePage: String?
    let title: String
    let body: String
    let content: FeedPage?

    enum CodingKeys: String, CodingKey { case id, createdAt, sourcePage, title, body, content }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        sourcePage = try c.decodeIfPresent(String.self, forKey: .sourcePage)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "提醒详情"
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        content = try c.decodeIfPresent(FeedPage.self, forKey: .content)
    }
}

struct NotificationDetailView: View {
    @EnvironmentObject var store: Store
    let target: NotificationDestination
    @State private var detail: NotificationDetailRecord?
    @State private var loading = false
    private let refresh = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if target.notificationID == nil, target.message == nil {
                currentPage
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(detail?.body ?? target.message ?? "正在读取这条提醒")
                            .font(.headline).textSelection(.enabled)
                            .accessibilityIdentifier("notification-message")
                        if let detail {
                            Text("发送时的内容 · \(detail.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("以下是只读记录；事项可能已更新或处理，请到当前事项操作。")
                                .font(.caption).foregroundStyle(.secondary)
                            if let content = detail.content, content.schema <= FeedPage.supportedSchema {
                                FeedView(sections: content.sections, allowsActions: false,
                                         expandAllOnAppear: true) { _, _ in false }
                            } else if detail.content != nil {
                                Text("部分详情需要更新 App 后查看。")
                            }
                        } else {
                            Text(target.notificationID == nil
                                 ? "这是旧版提醒，未携带独立详情；发送正文已保留，下方可查看当前事项。"
                                 : "详情尚未下载到手机，可能仍在同步或当前目录不可用；这不代表没有内容。")
                                .font(.callout).foregroundStyle(.secondary)
                                .accessibilityIdentifier("notification-sync-status")
                            Button("重新加载详情") { Task { await load() } }
                                .disabled(loading || target.notificationID == nil)
                        }
                        NavigationLink("查看当前事项") { currentPage }
                            .accessibilityIdentifier("notification-current")
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle(target.title)
        .task(id: store.rootURL) { detail = nil; await load() }
        .onReceive(refresh) { _ in if detail == nil { Task { await load() } } }
        .refreshable { await load() }
    }

    @ViewBuilder private var currentPage: some View {
        if target.sourcePage == "now" { NowView() }
        else { FeedPageView(page: target.sourcePage, title: target.title) }
    }

    private func load() async {
        // iCloud 尚未返回时不叠加定时读取；正文始终可读，主界面不会等待它。
        guard !loading, let id = target.notificationID else { return }
        loading = true
        defer { loading = false }
        if let loaded = await store.loadNotificationDetail(id: id) { detail = loaded }
    }
}

extension PushRegistrar: @preconcurrency UNUserNotificationCenterDelegate {
    /// App 在前台时也把横幅显示出来。
    ///
    /// 默认行为是前台不显示 —— 但这个 App 的典型用法就是「开着看办公室」，
    /// 那时候来了个要确认的事，不显示等于没通知。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    /// 点通知必须落到对应待办，而不是只打开 App 的上次页面。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let target = NotificationDestination(
            userInfo: response.notification.request.content.userInfo) else { return }
        await MainActor.run { self.destination = target }
    }
}

/// UIKit 的 app delegate。SwiftUI 生命周期下拿 device token 只有这一条路：
/// `didRegisterForRemoteNotificationsWithDeviceToken` 没有 SwiftUI 等价物。
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor static let push = PushRegistrar()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 冷启动的通知点击可能早于 SwiftUI .task，必须在启动完成前接住回调。
        UNUserNotificationCenter.current().delegate = Self.push
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Self.push.publish(token: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            Self.push.lastError = error.localizedDescription
        }
    }
}
