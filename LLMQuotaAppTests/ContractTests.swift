import XCTest
import UIKit
import UserNotifications
@testable import LLMQuotaApp

final class ContractTests: XCTestCase {
    func testMachineRouteRejectsMalformedNestedAndContradictorySources() {
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
        let id = "machine:" + a + ":review:merge:/tmp/repo|branch"
        XCTAssertEqual(MobileActionRoute.scoped(id, scope: a), id)
        XCTAssertNil(MobileActionRoute.scoped(id, scope: b))
        for bad in ["machine::x", "machine:" + a + ":", "machine:" + a.uppercased() + ":x",
                    "machine:" + a + ":" + id, "review:merge:/tmp/repo|branch"] {
            XCTAssertNil(MobileActionRoute.parse(bad), bad)
        }
        let page = FeedPage(schema: 1, page: "review-" + b, generatedAt: Date(), sections: [
            FeedSection(kind: "cards", cards: [FeedCard(id: "same", title: "wrong source",
                                                       actions: [FeedAction(id: id, label: "合入")])])])
        let resolved = FeedPage.resolving("review", in: [page.page: page])
        XCTAssertTrue(resolved?.sections.first?.cards?.first?.actions?.isEmpty == true)
        XCTAssertTrue(resolved?.sections.first?.note?.contains("来源") == true)
    }

    func testOfficeQuestionsAndPlanStateUseMachineIdentity() throws {
        let asks = try decoder().decode([Ask].self, from: Data(#"[{"id":"qa","machineID":"a","platform":"codex"},{"id":"qb","machineID":"b","platform":"codex"}]"#.utf8))
        XCTAssertEqual(OfficeView.asksByPlatform(asks, machineID: "a")["codex"]?.id, "qa")
        XCTAssertEqual(OfficeView.asksByPlatform(asks, machineID: "b")["codex"]?.id, "qb")
        XCTAssertTrue(OfficeView.asksByPlatform(asks, machineID: "c").isEmpty)
        XCTAssertTrue(OfficeView.asksByPlatform(asks, machineID: "").isEmpty)
        XCTAssertNotEqual(PlanView.releaseKey(machineID: "a", planID: "same"),
                          PlanView.releaseKey(machineID: "b", planID: "same"))
    }

    @MainActor
    func testActionReceiptRequiresMatchingMachineAndRequestAndSurvivesRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(); store.debugAttachRoot(root)
        let a = FeedAction(id: "machine:" + MobileActionRoute.digest("a") + ":task:approve:same", label: "A")
        let b = FeedAction(id: "machine:" + MobileActionRoute.digest("b") + ":task:approve:same", label: "B")
        let sent = await store.invoke(a, note: nil)
        XCTAssertTrue(sent)
        let submission = try XCTUnwrap(store.actionSubmissions[a.id])
        XCTAssertNil(submission.receipt)
        XCTAssertNil(store.actionSubmissions[b.id])
        let again = await store.invoke(a, note: nil)
        XCTAssertFalse(again)
        let unsafe = await store.invoke(FeedAction(id: "task:approve:same", label: "unsafe"), note: nil)
        XCTAssertFalse(unsafe)
        let restarted = Store(); restarted.debugAttachRoot(root)
        XCTAssertEqual(restarted.actionSubmissions[a.id]?.invocationID, submission.invocationID)
        let dir = root.appendingPathComponent("action-receipts")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(MobileActionRoute.receiptName(
            actionID: a.id, invocationID: submission.invocationID))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        var receipt = MobileActionReceipt(actionID: a.id, invocationID: submission.invocationID,
            machineID: "b", state: "succeeded", message: "wrong machine", updatedAt: Date(), attempts: 1)
        try enc.encode(receipt).write(to: url)
        await restarted.refreshActionReceipts()
        XCTAssertNil(restarted.actionSubmissions[a.id]?.receipt)
        receipt.machineID = "a"; receipt.invocationID = "older-click"
        try enc.encode(receipt).write(to: url)
        await restarted.refreshActionReceipts()
        XCTAssertNil(restarted.actionSubmissions[a.id]?.receipt)
        receipt.invocationID = submission.invocationID; receipt.state = "failed"
        try enc.encode(receipt).write(to: url)
        await restarted.refreshActionReceipts()
        XCTAssertEqual(restarted.actionSubmissions[a.id]?.receipt?.state, "failed")
        let retry = await restarted.invoke(a, note: "retry")
        XCTAssertTrue(retry)
        XCTAssertNotEqual(restarted.actionSubmissions[a.id]?.invocationID, submission.invocationID)
        let newer = try XCTUnwrap(restarted.actionSubmissions[a.id])
        receipt.invocationID = newer.invocationID; receipt.state = "succeeded"
        try enc.encode(receipt).write(to: dir.appendingPathComponent(MobileActionRoute.receiptName(
            actionID: a.id, invocationID: newer.invocationID)))
        await restarted.refreshActionReceipts()
        XCTAssertEqual(restarted.actionSubmissions[a.id]?.statusText, "目标 Mac 已执行成功")
        let duplicate = await restarted.invoke(a, note: nil)
        XCTAssertFalse(duplicate)
        XCTAssertNil(restarted.actionSubmissions[b.id])
    }

    @MainActor
    func testRestartDropsExpiredActionSubmissionSoItCannotHideCurrentActionForever() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let key = "llmq.pending." + StableID.make(namespace: "shared-root", parts: [root.path])
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            try? FileManager.default.removeItem(at: root)
        }
        let actionID = "machine:" + MobileActionRoute.digest("a") + ":task:approve:old|version"
        let old = MobileActionSubmission(actionID: actionID, invocationID: "old-request",
            submittedAt: Date().addingTimeInterval(-8 * 24 * 3600), receipt: nil)
        struct Stored: Encodable {
            let answered: [String: Date]
            let approved: [String: Date]
            let reviews: [String: Date]
            let actions: [String: MobileActionSubmission]
        }
        let data = try JSONEncoder().encode(Stored(
            answered: [:], approved: [:], reviews: [:], actions: [actionID: old]))
        UserDefaults.standard.set(data, forKey: key)

        let restarted = Store()
        restarted.debugAttachRoot(root)
        XCTAssertNil(restarted.actionSubmissions[actionID],
                     "超过意图保留期仍无回执的动作不能永久隐藏当前按钮")
    }

    @MainActor
    func testNativeReviewWritesRoutedActionAndKeepsLegacyEvidencePath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(); store.debugAttachRoot(root)
        var review = try decoder().decode(ReviewDigest.self, from: Data(#"{"repo":"/tmp/repo","branch":"feature/a","mergesCleanly":true}"#.utf8))
        let missingSource = await store.decideReview(review, action: "merge", reason: nil)
        XCTAssertFalse(missingSource)
        let oldFolder = review.evidenceFolder
        review.sourceMachineID = "a"
        XCTAssertEqual(review.evidenceFolder, oldFolder)
        let missingVersion = await store.decideReview(review, action: "merge", reason: nil)
        XCTAssertFalse(missingVersion, "缺版本的旧成果应可读，不能发出合入请求")
        review.head = String(repeating: "1", count: 40)
        let sent = await store.decideReview(review, action: "merge", reason: nil)
        XCTAssertTrue(sent)
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("actions"), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: files[0])) as? [String: Any])
        XCTAssertEqual(json["id"] as? String, review.actionID("merge"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("verdicts").path))
        var other = review; other.sourceMachineID = "b"
        XCTAssertNil(store.reviewSubmission(other))
        XCTAssertNotEqual(other.id, review.id)
    }

    func testScopedPageRoutesCardAndSectionActionsIndependently() throws {
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
        let pages = [a, b].map { scope in
            FeedPage(schema: 1, page: "review-" + scope, generatedAt: Date(), sections: [
                FeedSection(kind: "cards", cards: [FeedCard(id: "same", title: scope,
                    actions: [FeedAction(id: "review:merge:/tmp/repo|branch", label: "合入")])],
                    actions: [FeedAction(id: "task:approve:same", label: "放行")])])
        }
        let merged = try XCTUnwrap(FeedPage.resolving("review", in:
            Dictionary(uniqueKeysWithValues: pages.map { ($0.page, $0) })))
        XCTAssertEqual(merged.sections.compactMap { $0.cards?.first?.actions?.first?.id },
                       [a, b].map { "machine:" + $0 + ":review:merge:/tmp/repo|branch" })
        XCTAssertEqual(merged.sections.compactMap { $0.actions?.first?.id },
                       [a, b].map { "machine:" + $0 + ":task:approve:same" })
    }

    @MainActor
    func testNativeReviewKeepsSameBranchOnBothMachines() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("reviews")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"[{"repo":"/tmp/repo","repoName":"repo","branch":"same","platform":"codex","subject":"same","files":[],"insertions":0,"deletions":0,"mergesCleanly":true,"overlapsWith":[],"evidence":[]}]"#
        for machine in ["a", "b"] { try Data(json.utf8).write(to: dir.appendingPathComponent(machine + ".json")) }
        let snapshot = await Store.loadSecond(root: root)
        let reviews = try XCTUnwrap(snapshot.reviews)
        XCTAssertEqual(reviews.count, 2, "分机成果不得按相同 repo/branch 丢掉一台")
        XCTAssertEqual(Set(reviews.map(\.id)).count, 2)
    }

    @MainActor
    func testColdStartRegistersNotificationDelegateBeforeSwiftUITask() {
        let center = UNUserNotificationCenter.current()
        let previous = center.delegate
        defer { center.delegate = previous }
        center.delegate = nil
        let delegate: UIApplicationDelegate = AppDelegate()
        _ = delegate.application?(UIApplication.shared, didFinishLaunchingWithOptions: nil)
        XCTAssertTrue(center.delegate === AppDelegate.push,
                      "系统冷启动投递点击回调前必须已绑定通知接收者")
    }

    func testNotificationRetainsMessageAndRejectsUnsafePaths() throws {
        let id = String(repeating: "a", count: 64)
        let current = "review-" + id
        let target = try XCTUnwrap(NotificationDestination(userInfo: [
            "page": "review", "notificationID": id, "sourcePage": current,
            "aps": ["alert": ["body": "M2 新成果等你看"]]
        ]))
        XCTAssertEqual(target.notificationID, id)
        XCTAssertEqual(target.sourcePage, current)
        XCTAssertEqual(target.message, "M2 新成果等你看")
        let unsafe = try XCTUnwrap(NotificationDestination(userInfo: [
            "page": "roadmap", "notificationID": "../../secret", "sourcePage": "review-../../secret"
        ]))
        XCTAssertNil(unsafe.notificationID)
        XCTAssertEqual(unsafe.sourcePage, "roadmap")
        XCTAssertEqual(unsafe.title, "项目进度")
        let old = try XCTUnwrap(NotificationDestination(userInfo: [
            "aps": ["alert": ["body": "旧版任务停滞提醒"]]
        ]))
        XCTAssertEqual(old.page, "now")
        XCTAssertEqual(old.message, "旧版任务停滞提醒")
        XCTAssertNotEqual(old.id, NotificationDestination(userInfo: ["page": "now"])?.id)

        let consultationFailure = try XCTUnwrap(NotificationDestination(userInfo: [
            "page": "collaboration", "sourcePage": "collaboration",
            "aps": ["alert": ["body": "Agent 协作中断：咨询执行失败"]]
        ]))
        XCTAssertEqual(consultationFailure.page, "collaboration")
        XCTAssertEqual(consultationFailure.sourcePage, "collaboration")
        XCTAssertEqual(consultationFailure.title, "Agent 协作")
    }

    func testActionPagesAggregateMachinesInsteadOfLastWriter() {
        let now = Date()
        let a = "review-" + String(repeating: "a", count: 64)
        let b = "review-" + String(repeating: "b", count: 64)
        let pages = [
            "review": FeedPage(schema: 1, page: "review", generatedAt: now, sections: []),
            a: FeedPage(schema: 1, page: a, generatedAt: now, sections: [
                FeedSection(kind: "cards", title: "M2", cards: [FeedCard(id: "same", title: "M2 成果")])]),
            b: FeedPage(schema: 1, page: b, generatedAt: now, sections: [
                FeedSection(kind: "cards", title: "Mini", cards: [FeedCard(id: "same", title: "Mini 成果")])])
        ]
        let cards = FeedPage.resolving("review", in: pages, now: now)?.sections.flatMap { $0.cards ?? [] }
        XCTAssertEqual(cards?.map(\.title), ["M2 成果", "Mini 成果"])
        XCTAssertEqual(Set(cards?.map(\.id) ?? []).count, 2)
        XCTAssertEqual(FeedPage.resolving(a, in: pages)?.sections.first?.cards?.first?.title, "M2 成果")
    }

    func testExpiredMachineSourceCannotOfferOldActions() {
        let name = "review-" + String(repeating: "a", count: 64)
        let old = FeedPage(schema: 1, page: name, generatedAt: .distantPast, sections: [
            FeedSection(kind: "cards", title: "M2", cards: [
                FeedCard(id: "old", title: "旧事项", actions: [FeedAction(id: "approve", label: "合入")])])])
        let section = FeedPage.resolving("review", in: [name: old])?.sections.first
        XCTAssertTrue(section?.cards?.first?.actions?.isEmpty == true)
        XCTAssertTrue(section?.note?.contains("过期") == true)
        let direct = FeedPage.resolving(name, in: [name: old])?.sections.first
        XCTAssertTrue(direct?.cards?.first?.actions?.isEmpty == true,
                      "通知的当前事项深链也不能绕过过期保护")
        XCTAssertTrue(direct?.note?.contains("过期") == true)
        let legacy = FeedPage(schema: 1, page: "review", generatedAt: Date(), sections: old.sections)
        XCTAssertEqual(FeedPage.resolving("review", in: ["review": legacy])?.sections.count, 1)
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func testNotificationDestinationRoutesOnlyKnownActionPages() {
        XCTAssertEqual(NotificationDestination(userInfo: ["page": "review"])?.title,
                       "成果复核")
        XCTAssertEqual(NotificationDestination(userInfo: ["page": "blocked"])?.page,
                       "blocked")
        XCTAssertNil(NotificationDestination(userInfo: ["page": "unknown"]))
        XCTAssertNil(NotificationDestination(userInfo: [:]))
    }

    func testMachineNamesHideOwnerIdentityOnlyForDisplay() throws {
        XCTAssertEqual(machineNameForDisplay("示例用户的Mac mini"), "Mac mini")
        XCTAssertEqual(machineNameForDisplay("exampleuser MacBook Pro"), "MacBook Pro")
        XCTAssertEqual(machineNameForDisplay("MacBook Pro (Alice)"), "MacBook Pro")
        XCTAssertEqual(machineNameForDisplay("MacBook Pro"), "MacBook Pro")
        XCTAssertEqual(machineNameForDisplay("渲染节点"), "Mac")
        XCTAssertEqual(machineNameForDisplay("alice"), "Mac")
        XCTAssertEqual(machineNameForDisplay("王小明"), "Mac")
        XCTAssertEqual(machineNameForDisplay("exampleuser"), "Mac")
        XCTAssertEqual(machineNameForDisplay("示例用户"), "Mac")
        XCTAssertEqual(machineLabelForDisplay("exampleuser的MacBook Pro",
                                              machineID: "9FBD0428-xxxx",
                                              nodeName: "macbook-pro-intel"),
                       "MacBook Pro · Intel")
        XCTAssertEqual(machineLabelForDisplay("MacBook Pro",
                                              machineID: "FC54828B-xxxx",
                                              nodeName: "macbook-pro-arm64"),
                       "MacBook Pro · M2 Pro")
        XCTAssertEqual(machineLabelForDisplay("示例用户的Mac mini",
                                              machineID: "0A9B7D48-xxxx",
                                              nodeName: "mac-mini"),
                       "Mac mini · M4")
        XCTAssertEqual(machineLabelForDisplay("MacBook Pro", machineID: "ABCD-1234"),
                       "MacBook Pro · ABCD")

        let machine = try decoder().decode(MachineInfo.self, from: Data(
            #"{"machineID":"m1","machineName":"示例用户的Mac mini","lastSeen":"2026-08-24T00:30:00Z","isStale":false}"#.utf8))
        XCTAssertEqual(machine.machineName, "示例用户的Mac mini",
                       "协议和调度匹配仍应保留原始电脑名")
        XCTAssertEqual(machine.displayName, "Mac mini · M1")
        XCTAssertTrue(machine.matches(selector: "m1"))
        XCTAssertTrue(machine.matches(selector: "示例用户的Mac mini"))
        XCTAssertFalse(machine.matches(selector: "m2"))
        XCTAssertEqual(MachineInfo.resolve(selector: "m1", among: [machine])?.machineID, "m1")
        XCTAssertEqual(machine.coordinatorStatusText, "调度器：旧版本未上报状态")

        let paused = try decoder().decode(MachineInfo.self, from: Data(
            #"{"machineID":"m2","machineName":"exampleuser MacBook Pro","nodeName":"macbook-pro-arm64","coordinatorState":"paused","coordinatorSummary":"本机处于仅手工执行模式","coordinatorUpdatedAt":"2026-09-03T00:00:00Z","lastSeen":"2026-09-03T00:00:00Z","isStale":false}"#.utf8))
        XCTAssertEqual(paused.displayName, "MacBook Pro · M2 Pro")
        XCTAssertEqual(paused.coordinatorStatusText,
                       "调度器：已暂停 · 本机处于仅手工执行模式")
        XCTAssertTrue(paused.coordinatorNeedsAttention(
            now: Date(timeIntervalSince1970: 1_788_397_200)))
    }

    func testOfficeUsesStableMachineIDBeforeDuplicateComputerName() throws {
        let report = try decoder().decode(PlatformReport.self, from: Data(
            #"{"platform":"kimi","planName":"Kimi","machineIDs":["arm-id"],"machines":["MacBook Pro · arm-id"],"statuses":[],"last30dRequests":0,"last30dBillableTokens":0}"#.utf8))
        let arm = try decoder().decode(MachineInfo.self, from: Data(
            #"{"machineID":"arm-id","machineName":"MacBook Pro","lastSeen":"2026-09-03T00:00:00Z","isStale":false}"#.utf8))
        let intel = try decoder().decode(MachineInfo.self, from: Data(
            #"{"machineID":"intel-id","machineName":"MacBook Pro","lastSeen":"2026-09-03T00:00:00Z","isStale":false}"#.utf8))

        XCTAssertTrue(report.isReported(on: arm))
        XCTAssertFalse(report.isReported(on: intel),
                       "同名机器不能同时认领只属于其中一台的 agent")

        let legacy = try decoder().decode(PlatformReport.self, from: Data(
            #"{"platform":"qwen","planName":"Qwen","machines":["旧机器"],"statuses":[],"last30dRequests":0,"last30dBillableTokens":0}"#.utf8))
        let oldMachine = try decoder().decode(MachineInfo.self, from: Data(
            #"{"machineID":"old-id","machineName":"旧机器","lastSeen":"2026-09-03T00:00:00Z","isStale":false}"#.utf8))
        XCTAssertTrue(legacy.isReported(on: oldMachine), "旧服务端仍须按原机器名兼容")

        let role = try decoder().decode(AgentRole.self, from: Data(
            #"{"platform":"codex","dispatcherOn":["arm-id"]}"#.utf8))
        XCTAssertTrue(role.isDispatcher(on: arm))
        XCTAssertFalse(role.isDispatcher(on: intel),
                       "同名机器不能同时命中只属于其中一台的指挥绑定")

        XCTAssertNil(MachineInfo.resolve(selector: "MacBook Pro", among: [arm, intel]),
                     "旧机器名有歧义时不能取数组中的第一台")
        XCTAssertTrue(MachineInfo.selectorIsAmbiguous(
            "MacBook Pro", among: [arm, intel]))
        XCTAssertEqual(MachineInfo.resolve(
            selector: "intel-id", among: [arm, intel])?.machineID, "intel-id")

        let repo = RepoItem(alias: "flint", isDefault: true,
                            machines: ["arm-id", "intel-id", "MacBook Pro"])
        let normalized = repo.normalized(using: [arm, intel])
        XCTAssertEqual(normalized.machines, ["MacBook Pro", "arm-id", "intel-id"],
                       "有歧义的旧机器名必须留作可见待修数据，不能暗绑到第一台")
    }

    func testOfficePresentationFollowsAvailableWidthInsteadOfDeviceName() {
        XCTAssertEqual(OfficePresentation.resolve(width: 430, regularWidth: false), .phone)
        XCTAssertEqual(OfficePresentation.resolve(width: 959, regularWidth: true), .tabletStacked)
        XCTAssertEqual(OfficePresentation.resolve(width: 960, regularWidth: true), .tabletSplit)
        XCTAssertEqual(OfficePresentation.resolve(width: 1_200, regularWidth: false), .phone,
                       "紧凑 size class 下即使窗口很宽也不能硬塞控制台")
        XCTAssertEqual(OfficePresentation.deskColumnCount(width: 430, staffCount: 1), 2)
        XCTAssertEqual(OfficePresentation.deskColumnCount(width: 980, staffCount: 2), 2,
                       "iPad 上两名员工应铺满整行，不能只占六列中的前两列")
        XCTAssertEqual(OfficePresentation.deskColumnCount(width: 980, staffCount: 9), 6)
    }

    func testReviewEvidenceStatesAreMutuallyExclusive() throws {
        func review(evidence: [String], files: [String]?) -> ReviewDigest {
            ReviewDigest(repo: "/repo", repoName: "repo", branch: "feature/a",
                         platform: "codex", subject: "subject", prompt: nil, files: [],
                         insertions: 0, deletions: 0, mergesCleanly: true,
                         overlapsWith: [], committedAt: nil,
                         evidence: evidence, evidenceFiles: files)
        }

        XCTAssertEqual(review(evidence: ["raw.png"], files: ["ready.png"]).evidenceAvailability,
                       .available(["ready.png"]))
        XCTAssertEqual(review(evidence: ["raw.png"], files: nil).evidenceAvailability,
                       .syncing(1))
        XCTAssertEqual(review(evidence: [], files: []).evidenceAvailability, .missing)
    }

    func testReviewMediaSummaryUsesOnlyFilesActuallyAvailableOnPhone() {
        let digest = ReviewDigest(
            repo: "/repo", repoName: "repo", branch: "feature/a",
            platform: "volcark", subject: "subject", prompt: nil, files: [],
            insertions: 0, deletions: 0, mergesCleanly: true,
            overlapsWith: [], committedAt: nil,
            evidence: (0..<17).map { "raw-\($0).png" },
            evidenceFiles: ["grip-idle.jpg", "grip-fire.jpg", "match.m4v"])

        XCTAssertEqual(digest.evidenceSummary, "2 张图片 · 1 个视频",
                       "不能把 agent 声明的 17 个路径冒充成 17 张已同步图片")
    }

    func testExtremeNumbersNeverTrap() {
        XCTAssertEqual(Fmt.duration(1e19), "—")
        XCTAssertEqual(Fmt.compact(.infinity), "—")
        XCTAssertEqual(Fmt.percent(.nan), "—")
        XCTAssertEqual(Fmt.relative(.distantPast), "从未")
        XCTAssertEqual(Money.text(.infinity, "CNY"), "¥—")
        XCTAssertFalse(Money.text(1e30, "USD").isEmpty)
    }

    func testLegacyAskGetsStableIdentity() throws {
        let data = Data(#"{"taskID":"t1","machineID":"m1","round":2,"askedAt":"2026-08-23T12:34:56Z"}"#.utf8)
        let first = try decoder().decode(Ask.self, from: data)
        let second = try decoder().decode(Ask.self, from: data)
        XCTAssertEqual(first.id, second.id)
        XCTAssertFalse(first.id.isEmpty)
    }

    func testLegacyOfficeEventGetsStableIdentity() throws {
        let data = Data(#"{"at":"2026-08-23T12:34:56Z","kind":"future-kind","taskID":"t1","machineID":"m1"}"#.utf8)
        let first = try decoder().decode(OfficeEvent.self, from: data)
        let second = try decoder().decode(OfficeEvent.self, from: data)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.kind, .other)
    }

    @MainActor
    func testOfficeOnlyAnimatesRecentEvents() throws {
        let recent = try decoder().decode(OfficeEvent.self, from: Data(
            #"{"id":"recent","at":"2026-08-24T00:29:30Z","kind":"finished"}"#.utf8))
        let history = try decoder().decode(OfficeEvent.self, from: Data(
            #"{"id":"history","at":"2026-08-23T20:00:00Z","kind":"finished"}"#.utf8))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-24T00:30:00Z"))
        XCTAssertTrue(OfficeView.shouldAnimate(recent, now: now))
        XCTAssertFalse(OfficeView.shouldAnimate(history, now: now))
    }

    func testFractionalISO8601DatesDecodeOnSupportedRuntime() throws {
        let data = Data(#"{"taskID":"t1","machineID":"m1","askedAt":"2026-08-23T12:34:56.123Z"}"#.utf8)
        XCTAssertNoThrow(try decoder().decode(Ask.self, from: data))
    }

    func testDemoTasksKeepDeclaredIDs() {
        let ids = Demo.boards().flatMap(\.tasks).map(\.taskID)
        XCTAssertEqual(ids, ["d1", "d2", "d3", "d4"])
    }

    func testTaskTitleClamping() {
        let clamped = TaskBrief.clampTitle(String(repeating: "为", count: 200))
        XCTAssertEqual(clamped.count, 80)
        XCTAssertTrue(clamped.hasSuffix("…"))
        XCTAssertEqual(TaskBrief.clampTitle("第一行\n/path"), "第一行")
    }

    func testRecentResultsAreBoundedAndNewestFirst() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recent-results-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("old.json")
        let middle = dir.appendingPathComponent("middle.json")
        let newest = dir.appendingPathComponent("newest.json")
        let ignored = dir.appendingPathComponent("note.txt")
        for file in [old, middle, newest, ignored] { try Data().write(to: file) }
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: middle.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 3)], ofItemAtPath: newest.path)

        XCTAssertEqual(Store.recentResultFiles(
            [old, ignored, newest, middle], limit: 2).map(\.lastPathComponent),
            ["newest.json", "middle.json"])
    }

    func testTaskProgressDecodesWithoutBreakingLegacyTasks() throws {
        let current = Data(#"{"id":"t1","title":"长任务","state":"running","machineName":"M","progressPhase":"移动端验收","progressSummary":"模拟器截图已生成","progressNextStep":"检查真机手势","progressUpdatedAt":"2026-08-24T00:30:00Z","progressEvidenceCount":2}"#.utf8)
        let task = try decoder().decode(TaskBrief.self, from: current)
        XCTAssertEqual(task.progressHeadline, "移动端验收 · 模拟器截图已生成")
        XCTAssertEqual(task.progressNextStep, "检查真机手势")
        XCTAssertEqual(task.progressEvidenceCount, 2)

        let legacy = Data(#"{"id":"old","title":"旧任务","state":"running","machineName":"M"}"#.utf8)
        let old = try decoder().decode(TaskBrief.self, from: legacy)
        XCTAssertNil(old.progressHeadline)
        XCTAssertNil(old.progressUpdatedAt)
    }

    func testMachineOrderDropsCorruptDuplicates() {
        XCTAssertEqual(Store.uniqueMachineIDs(["m2", "m1", "m2", "", "m1"]),
                       ["m2", "m1"])
    }

    @MainActor
    func testBoardKeepsZeroUsageWarningsVisible() throws {
        func status(_ health: String) throws -> QuotaStatus {
            let json = """
            {"platform":"kimi","limitID":"weekly","label":"周额度",\
            "metric":"requests","used":0,"health":"\(health)",\
            "isOfficial":true,"sourceNote":""}
            """
            return try decoder().decode(QuotaStatus.self, from: Data(json.utf8))
        }

        XCTAssertTrue(BoardView.worthWatching(try status("wasting")),
                      "零使用正是额度将作废的原因，不能从看板消失")
        XCTAssertFalse(BoardView.worthWatching(try status("healthy")))
    }

    func testQuotaStatusKeepsCapacityFloorWithoutClaimingCurrentRemaining() throws {
        let exact = try decoder().decode(QuotaStatus.self, from: Data(#"""
        {
            "platform":"minimax","limitID":"video","label":"每日","metric":"requests",
            "used":12,"limit":21,"usedFraction":0.571428,"projectedUsedFraction":0.8,
            "health":"healthy","isOfficial":true,"sourceNote":"平台回报"
        }
        """#.utf8))
        XCTAssertEqual(exact.remainingValue, 9)
        XCTAssertEqual(exact.remainingFraction ?? -1, 0.428572, accuracy: 0.000001)
        XCTAssertEqual(exact.projectedRemainingFraction ?? -1, 0.2, accuracy: 0.000001)
        XCTAssertNil(exact.minimumRemainingValue)

        let estimated = try decoder().decode(QuotaStatus.self, from: Data(#"""
        {
            "platform":"qwen","limitID":"daily","label":"每日","metric":"requests",
            "used":337,"observedFloor":898,"health":"unconfigured",
            "isOfficial":false,"sourceNote":"上限未知"
        }
        """#.utf8))
        XCTAssertEqual(estimated.observedFloor, 898,
                       "Mac 已算出的实测容量下限不能在手机解码时被静默丢弃")
        XCTAssertNil(estimated.remainingFraction,
                     "容量下限不是精确上限，不能伪造剩余百分比")
        XCTAssertNil(estimated.minimumRemainingValue,
                     "历史峰值不绑定当前套餐、池和时效，不能伪装成本窗保证剩余")
    }

    func testDynamicMenuKeepsServerGroupOrderAndHidesNativeRoutes() {
        let menu = FeedMenu(schema: 1, generatedAt: Date(), entries: [
            FeedMenuEntry(page: "roadmap", title: "计划", group: "看进展"),
            FeedMenuEntry(page: "review", title: "验收", group: "要你拍板"),
            FeedMenuEntry(page: "release", title: "发布", group: "看进展"),
        ])
        let groups = menu.groups(excluding: ["review"])
        XCTAssertEqual(groups.map(\.title), ["看进展"])
        XCTAssertEqual(groups[0].entries.map(\.page), ["roadmap", "release"])
    }

    func testDynamicActionsRequireReviewMaterialToBeOpened() {
        let plain = FeedCard(id: "plain", title: "公告")
        let detailed = FeedCard(id: "detail", title: "验收", detail: "证据")
        let pictured = FeedCard(id: "picture", title: "验收", images: ["one.png"])
        XCTAssertFalse(plain.requiresReviewBeforeAction)
        XCTAssertTrue(detailed.requiresReviewBeforeAction)
        XCTAssertTrue(pictured.requiresReviewBeforeAction)
    }

    func testStableFileKeysDoNotCollapseSlashAndUnderscore() {
        let slash = StableID.make(namespace: "review-verdict", parts: ["repo", "feature/x"])
        let underscore = StableID.make(namespace: "review-verdict", parts: ["repo", "feature_x"])
        XCTAssertNotEqual(slash, underscore)
        XCTAssertEqual(slash, StableID.make(
            namespace: "review-verdict", parts: ["repo", "feature/x"]))
    }

    func testPendingProjectPreventsAllQuietMessage() {
        XCTAssertFalse(shouldShowAllQuiet(
            bleedingCount: 0, askCount: 0, pendingProjectCount: 1))
        XCTAssertFalse(shouldShowAllQuiet(
            bleedingCount: 0, askCount: 0, pendingProjectCount: 0, reviewCount: 1))
        XCTAssertFalse(shouldShowAllQuiet(
            bleedingCount: 0, askCount: 0, pendingProjectCount: 0, plannedCount: 1))
        XCTAssertTrue(shouldShowAllQuiet(
            bleedingCount: 0, askCount: 0, pendingProjectCount: 0))
    }

    @MainActor
    func testSubmissionReceiptSeparatesWrittenFromClaimed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "submission-receipt-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = Store()
        store.debugAttachRoot(root)
        let submitted = await store.submit(
            prompt: "完成移动端派活回执测试", repo: "LLMQuotaApp",
            machineID: "mini", machineName: "测试 Mac mini")
        let receipt = try XCTUnwrap(submitted)

        XCTAssertTrue(store.submissionIsWaiting(receipt) == true,
                      "写成功只代表还在收件箱，不能提前显示 Mac 已领取")
        let file = root.appendingPathComponent("inbox/" + receipt.filename)
        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
            as? [String: Any]
        XCTAssertEqual(payload?["machineID"] as? String, "mini")

        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(store.submissionIsWaiting(receipt) == false,
                      "收件箱文件被抢走后才显示 Mac 已领取")
    }

    func testApprovalReplyUsesExplicitDecision() throws {
        let data = Data(#"{"id":"a1","taskID":"t1","machineID":"m1","round":1,"askedAt":"2026-08-23T12:34:56Z","kind":"approval","questions":[{"id":"q1","text":"要放行吗？","options":["放行并提交","丢弃这次改动"]}]}"#.utf8)
        let ask = try decoder().decode(Ask.self, from: data)
        XCTAssertEqual(ask.approvalReplies(approve: true), ["q1": "放行并提交"])
        XCTAssertEqual(ask.approvalReplies(approve: false), ["q1": "丢弃这次改动"])
    }

    func testOldDashboardKeepsUnknownSeparateFromEmpty() throws {
        let data = Data(#"{"generatedAt":"2026-08-23T12:00:00Z","machines":[],"reports":[]}"#.utf8)
        let dashboard = try decoder().decode(Dashboard.self, from: data)
        XCTAssertNil(dashboard.tasks)
        XCTAssertFalse(TaskDigest(boards: []).published)
    }

    func testPhoneUsesTaskBoardFileNameAsMachineIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir = root.appendingPathComponent("taskboards")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"machineID":"forged-inside","machineName":"Mac","generatedAt":"2026-09-04T00:00:00Z","tasks":[],"tasksTruncated":false}"#.utf8)
            .write(to: dir.appendingPathComponent("actual-file.json"))

        let snapshot = await Store.loadFirst(root: root)
        XCTAssertEqual(snapshot.tasks.rawBoards.first?.machineID, "actual-file",
                       "任务板文件名是机器路由身份，内容自报值不能造成跨机错位")
    }

    func testPhoneUsesQuestionDirectoryAsMachineIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir = root.appendingPathComponent("questions/actual-machine")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"id":"ask-route","taskID":"task-route","machineID":"forged-machine","platform":"codex","askedAt":"2026-09-04T00:00:00Z","questions":[{"id":"q","text":"继续吗？"}]}"#.utf8)
            .write(to: dir.appendingPathComponent("task-route.json"))

        let snapshot = await Store.loadSecond(root: root)
        XCTAssertEqual(snapshot.asks?.first?.machineID, "actual-machine",
                       "问题目录是答复路由身份，内容不能把回答送往另一台机器")
    }

    func testTaskDigestClassifiesAndKeepsMissingIDStable() throws {
        let data = Data(#"{"generatedAt":"2026-08-23T12:00:00Z","machines":[],"reports":[],"tasksTruncated":true,"tasks":[{"id":"a1","title":"跑着","state":"running","platform":"claude","machineName":"mini"},{"title":"缺 ID","state":"running","platform":"qwen","machineName":"mini"},{"id":"a3","title":"卡住","state":"blocked","machineName":"mini"},{"id":"a4","title":"排队","state":"queued","machineName":"mini"},{"id":"a5","title":"新状态","state":"paused","machineName":"mini"}]}"#.utf8)
        let first = try decoder().decode(Dashboard.self, from: data)
        let second = try decoder().decode(Dashboard.self, from: data)
        let now = first.generatedAt.addingTimeInterval(60)
        func digest(_ dashboard: Dashboard) -> TaskDigest {
            TaskDigest(boards: [TaskBoardLoad(
                machineID: "m1", machineName: "mini",
                generatedAt: dashboard.generatedAt,
                tasks: dashboard.tasks ?? [], truncated: dashboard.tasksTruncated)], now: now)
        }
        let one = digest(first)
        let two = digest(second)
        XCTAssertEqual(one.running.count, 2)
        XCTAssertEqual(one.blocked.count, 1)
        XCTAssertEqual(one.queued.count, 1)
        XCTAssertEqual(one.unrecognized.map(\.state), ["paused"])
        XCTAssertTrue(one.truncated)
        XCTAssertEqual(one.running.map(\.id), two.running.map(\.id))
    }

    func testTaskDigestKeepsSameNamedMachineDesksSeparate() throws {
        let first = try decoder().decode(TaskBrief.self, from: Data(
            #"{"id":"a","title":"A 的任务","state":"running","platform":"kimi","machineName":"MacBook Pro"}"#.utf8))
        let second = try decoder().decode(TaskBrief.self, from: Data(
            #"{"id":"b","title":"B 的任务","state":"running","platform":"kimi","machineName":"MacBook Pro"}"#.utf8))
        let now = Date(timeIntervalSince1970: 1_788_397_200)
        let digest = TaskDigest(boards: [
            TaskBoardLoad(machineID: "hardware-A", machineName: "MacBook Pro",
                          generatedAt: now, tasks: [first]),
            TaskBoardLoad(machineID: "hardware-B", machineName: "MacBook Pro",
                          generatedAt: now, tasks: [second]),
        ], now: now)

        XCTAssertEqual(digest.onDesk(
            platform: "kimi", machineID: "hardware-A", machineName: "MacBook Pro")?.taskID,
                       "a")
        XCTAssertEqual(digest.onDesk(
            platform: "kimi", machineID: "hardware-B", machineName: "MacBook Pro")?.taskID,
                       "b")
    }

    func testTaskDigestTreatsFarFutureBoardAsUnreliable() throws {
        let task = try decoder().decode(TaskBrief.self, from: Data(
            #"{"id":"future","title":"未来状态","state":"running","platform":"kimi","machineName":"偏时钟机器"}"#.utf8))
        let now = Date(timeIntervalSince1970: 1_788_397_200)
        let digest = TaskDigest(boards: [TaskBoardLoad(
            machineID: "future-machine", machineName: "偏时钟机器",
            generatedAt: now.addingTimeInterval(3600), tasks: [task])], now: now)

        XCTAssertTrue(digest.running.isEmpty,
                      "未来快照不能被当作当前运行状态并长期压过后续数据")
        XCTAssertEqual(digest.cold.map(\.taskID), ["future"])
        XCTAssertTrue(digest.boards.first?.isCold == true)
    }

    func testCurrentDigestDoesNotMistakeAnotherProjectsPausedWorkForActiveWork() throws {
        let data = Data(#"{"generatedAt":"2026-08-31T13:50:00Z","machines":[],"reports":[],"tasks":[{"id":"flint-run","title":"Flint 功能 Beta","state":"running","platform":"kimi","machineName":"mini","repoAlias":"flint"},{"id":"maw-blocked","title":"Maw 旧任务","state":"blocked","platform":"minimax","machineName":"mini","repoAlias":"maw"},{"id":"maw-queued","title":"Maw 排队任务","state":"queued","machineName":"mini","repoAlias":"maw"}]}"#.utf8)
        let dashboard = try decoder().decode(Dashboard.self, from: data)
        let digest = TaskDigest(boards: [TaskBoardLoad(
            machineID: "mini", machineName: "mini",
            generatedAt: dashboard.generatedAt, tasks: dashboard.tasks ?? [])],
            now: dashboard.generatedAt.addingTimeInterval(30))

        XCTAssertEqual(digest.running.map(\.taskID), ["flint-run"])
        XCTAssertTrue(digest.blocked.isEmpty)
        XCTAssertTrue(digest.queued.isEmpty)

        let declared = Data(#"{"machineID":"mini","machineName":"mini","generatedAt":"2026-08-31T13:50:00Z","focusedRepoAlias":"flint","tasks":[{"id":"flint-blocked","title":"Flint 等待","state":"blocked","machineName":"mini","repoAlias":"flint"},{"id":"maw-blocked","title":"Maw 暂停","state":"blocked","machineName":"mini","repoAlias":"maw"}],"tasksTruncated":false}"#.utf8)
        let declaredBoard = try decoder().decode(TaskBoardFile.self, from: declared)
        let declaredDigest = TaskDigest(boards: [TaskBoardLoad(
            machineID: declaredBoard.machineID, machineName: declaredBoard.machineName,
            generatedAt: declaredBoard.generatedAt, tasks: declaredBoard.tasks,
            focusedRepoAlias: declaredBoard.focusedRepoAlias)],
            now: dashboard.generatedAt.addingTimeInterval(30))
        XCTAssertEqual(declaredDigest.blocked.map(\.taskID), ["flint-blocked"],
                       "没有运行任务时也必须按 Mac 明确发布的项目作用域过滤")

        let breach = Data(#"{"generatedAt":"2026-08-31T13:50:00Z","machines":[],"reports":[],"tasks":[{"id":"flint-run","title":"Flint","state":"running","machineName":"mini","repoAlias":"flint"},{"id":"maw-run","title":"Maw","state":"running","machineName":"mini","repoAlias":"maw"}]}"#.utf8)
        let breachedDashboard = try decoder().decode(Dashboard.self, from: breach)
        let breachedDigest = TaskDigest(boards: [TaskBoardLoad(
            machineID: "mini", machineName: "mini",
            generatedAt: breachedDashboard.generatedAt,
            tasks: breachedDashboard.tasks ?? [])],
            now: breachedDashboard.generatedAt.addingTimeInterval(30))
        XCTAssertEqual(Set(breachedDigest.running.map(\.taskID)), ["flint-run", "maw-run"],
                       "真有跨项目运行时必须完整暴露，不能被展示层过滤")
    }
}

final class DeliveryPresentationTests: XCTestCase {
    private func task(_ fields: [String: Any]) throws -> TaskBrief {
        var object: [String: Any] = ["id": "isolated", "title": "隔离任务", "state": "blocked", "machineName": "测试机器"]
        object.merge(fields) { _, new in new }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TaskBrief.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testAutomaticDiagnosisIsNotPresentedAsUserBlocker() throws {
        XCTAssertEqual(try task(["waitReason": "architectureReview", "progressPhase": "系统诊断中"]).stateLabel, "系统诊断中")
        XCTAssertEqual(try task(["waitReason": "humanAnswer"]).stateLabel, "等待你的答复")
        XCTAssertEqual(try task(["waitReason": "productionGate"]).stateLabel, "等待质量复验")
        XCTAssertEqual(try task(["waitReason": "futureReason"]).stateLabel, "等待处理")
    }
    func testFinishedAndColdTasksDoNotKeepAccumulatingRuntime() throws {
        let old = "2020-01-01T00:00:00Z"
        for state in ["done", "blocked", "queued", "failed"] {
            let value = try task(["state": state, "startedAt": old, "elapsedSeconds": 42])
            XCTAssertEqual(value.elapsed?.seconds, 42)
            XCTAssertEqual(value.elapsed?.live, false)
        }
        var cold = try task(["state": "running", "startedAt": old, "elapsedSeconds": 42])
        cold.freshness = .stale(3600)
        XCTAssertEqual(cold.elapsed?.seconds, 42)
        XCTAssertEqual(cold.elapsed?.live, false)
    }
    func testExecutedAndLandedAreDifferentOutcomes() throws {
        XCTAssertEqual(try task(["state": "done", "progressPhase": "等待合入"]).stateLabel, "等待合入")
        XCTAssertEqual(try task(["state": "done", "landedAt": "2026-09-06T00:00:00Z"]).stateLabel, "已合入")
    }
}

@MainActor
final class ReviewContinuationIndependentTests: XCTestCase {
    private func digest(machine: String = "continue-a", version: String = "v1") throws -> ReviewDigest {
        let head = String(repeating: "a", count: 40)
        let object: [String: Any] = ["repo": "/tmp/independent-continue", "branch": "agent/kimi/task", "head": head,
            "sourceMachineID": machine, "mergesCleanly": true,
            "continuationActionID": "review-continuation:request:/tmp/independent-continue|agent/kimi/task|" + head + "|task|" + version]
        return try JSONDecoder().decode(ReviewDigest.self, from: JSONSerialization.data(withJSONObject: object))
    }
    func testPendingContinuationExcludesDispositionAndSuccessDoesNotPoisonLaterReview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("continue-contract-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(); store.debugAttachRoot(root)
        let review = try digest(), other = try digest(machine: "continue-b")
        let sent = await store.decideReview(review, action: "continue", reason: nil)
        XCTAssertTrue(sent)
        XCTAssertFalse(store.canConfirmReview(review)); XCTAssertFalse(store.canContinueReview(review))
        XCTAssertTrue(store.canConfirmReview(other)); XCTAssertTrue(store.canContinueReview(other))
        let discard = await store.decideReview(review, action: "discard", reason: nil)
        XCTAssertFalse(discard, "待回执续作与同份成果丢弃不得同时写入")
        let action = try XCTUnwrap(review.actionID("continue"))
        let submission = try XCTUnwrap(store.actionSubmission(for: action))
        let restarted = Store(); restarted.debugAttachRoot(root)
        XCTAssertFalse(restarted.canConfirmReview(review), "重启仍需等待原续作回执")
        let dir = root.appendingPathComponent("action-receipts")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let receipt = MobileActionReceipt(actionID: action, invocationID: submission.invocationID,
            machineID: "continue-a", state: "succeeded", message: "已保留成果继续完善", updatedAt: Date(), attempts: 1)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(receipt).write(to: dir.appendingPathComponent(MobileActionRoute.receiptName(actionID: action, invocationID: submission.invocationID)))
        await restarted.refreshActionReceipts()
        XCTAssertFalse(restarted.canContinueReview(review), "同一版本成功续作不能重复发送")
        XCTAssertFalse(restarted.canConfirmReview(review), "续作成功后旧快照必须等待新状态，不能立刻开放旧合入入口")
        XCTAssertTrue(restarted.canConfirmReview(try digest(version: "v2")), "同 HEAD 的新任务版本完成后不能被旧续作回执封死")
        XCTAssertTrue(restarted.canContinueReview(try digest(version: "v2")), "新任务版本不能被旧续作回执封死")
    }
    func testContinuationRequiresMatchingServerTokenAndLegacyReviewRemainsReadable() throws {
        var review = try digest()
        XCTAssertNotNil(review.actionID("continue"))
        review.continuationActionID = review.continuationActionID?.replacingOccurrences(of: "|task|v1", with: "|task")
        XCTAssertNil(review.actionID("continue"))
        review = try digest(); review.head = String(repeating: "b", count: 40)
        XCTAssertNil(review.actionID("continue"), "旧 token 不能绑定整改后的新 HEAD")
        review = try digest(); review.continuationActionID = nil
        XCTAssertNil(review.actionID("continue")); XCTAssertNotNil(review.actionID("merge"))
    }
}

@MainActor
final class CurrentCoreReviewContinuationTests: XCTestCase {
    func testActualProducerPhoneWriteAndConsumerReceipt() async throws {
        let root = URL(fileURLWithPath: "/tmp/llmq-independent-review-chain/cloud")
        let originalURL = root.deletingLastPathComponent().appendingPathComponent("initial-review.json")
        guard FileManager.default.fileExists(atPath: originalURL.path) else {
            throw XCTSkip("需先运行当前 Core 隔离成果生产者")
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let original = try XCTUnwrap(decoder.decode([ReviewDigest].self, from: Data(contentsOf: originalURL)).first)
        XCTAssertEqual(original.head?.count, 40, "真实生产者必须发布完整 HEAD")
        let store = Store(); store.debugAttachRoot(root); await store.refresh()
        let id = try XCTUnwrap(original.actionID("continue"))
        XCTAssertEqual(MobileActionRoute.parse(id)?.scope, MobileActionRoute.digest("actual-review-producer"))
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("acceptance-consumed").path) {
            await store.refreshActionReceipts()
            XCTAssertEqual(store.actionSubmission(for: id)?.receipt?.state, "succeeded")
            XCTAssertEqual(store.actionSubmission(for: id)?.receipt?.machineID, "actual-review-producer")
            XCTAssertFalse(store.reviews.contains { $0.repo == original.repo }, "续作排队后实际成果卡必须移除")
            XCTAssertFalse(store.canConfirmReview(original), "回执成功时旧页不得开放处置")
        } else {
            let review = try XCTUnwrap(store.reviews.first { $0.repo == original.repo })
            XCTAssertEqual(review.continuationActionID, original.continuationActionID)
            if store.actionSubmission(for: id) == nil {
                let sent = await store.decideReview(review, action: "continue", reason: "隔离手机真实请求")
                XCTAssertTrue(sent)
            }
            let submission = try XCTUnwrap(store.actionSubmission(for: id))
            XCTAssertNil(submission.receipt)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("actions/" + MobileActionRoute.receiptName(actionID: id, invocationID: submission.invocationID)).path))
        }
    }
}
