import XCTest
@testable import LLMQuotaApp

/// 本批非实现者补充的协议边界；只用独立临时文件夹。
final class IndependentRoutingContractTests: XCTestCase {
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    @MainActor
    func testActualMacProducerMobileWriteAndReceiptReadContract() async throws {
        let root = URL(fileURLWithPath: "/tmp/llmq-independent-real-chain/cloud")
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("views/playbook.json").path) else {
            throw XCTSkip("需先运行独立验收真实Mac生产者夹具；不以手写JSON替代这条链路")
        }
        let store = Store(); store.debugAttachRoot(root)
        await store.refresh()
        let now = Date()
        guard store.feeds.values.contains(where: {
            $0.page.hasPrefix("playbook-")
                && (0...30 * 60).contains(now.timeIntervalSince($0.generatedAt))
        }) else {
            throw XCTSkip("实际 Mac 生产者夹具已过期，需由独立验收重新生成")
        }
        let page = try XCTUnwrap(FeedPage.resolving("playbook", in: store.feeds))
        let action = try XCTUnwrap(page.sections.flatMap { $0.cards ?? [] }.flatMap { $0.actions ?? [] }.first)
        XCTAssertEqual(MobileActionRoute.parse(action.id)?.scope, MobileActionRoute.digest("real-producer-a"))
        XCTAssertEqual(action.label, "批准")
        if store.actionSubmissions[action.id] == nil {
            let sent = await store.invoke(action, note: "来自真实手机Store的隔离验收")
            XCTAssertTrue(sent)
        }
        let submission = try XCTUnwrap(store.actionSubmissions[action.id])
        let written = root.appendingPathComponent("actions/" + MobileActionRoute.receiptName(actionID: action.id, invocationID: submission.invocationID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("acceptance-consumed").path) {
            await store.refreshActionReceipts()
            XCTAssertEqual(store.actionSubmissions[action.id]?.receipt?.state, "succeeded")
            XCTAssertEqual(store.actionSubmissions[action.id]?.receipt?.machineID, "real-producer-a")
        } else {
            XCTAssertNil(submission.receipt, "Mac尚未消费时不能显示成功")
        }
    }

    @MainActor
    func testActualCoreArtifactProgressTaskBoardIsReadByPhoneStore() async throws {
        let root = URL(fileURLWithPath: "/tmp/llmq-artifact-progress-mobile-fixture")
        let payload = root.appendingPathComponent("taskboards/qa-core.json")
        guard FileManager.default.fileExists(atPath: payload.path) else {
            throw XCTSkip("需先运行本批隔离 Core 生产者夹具")
        }
        let store = Store()
        store.debugAttachRoot(root)
        await store.refresh()
        let board = try XCTUnwrap(store.taskDigest.rawBoards.first(where: { $0.machineID == "qa-core" }))
        let task = try XCTUnwrap(board.tasks.first(where: { $0.id == "qa-kimi-artifact" }))
        XCTAssertEqual(task.state, "running")
        XCTAssertEqual(task.platform, "kimi")
        XCTAssertEqual(task.progressPhase, "子任务产物已更新")
        XCTAssertEqual(task.progressSummary, "检测到当前执行会话生成或更新 1 份临时产物；尚未质量验收")
        XCTAssertEqual(task.progressEvidenceCount, 1)
    }

    @MainActor
    func testConflictingReviewShardSourceRemainsReadableButCannotWriteAction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let review = try JSONDecoder().decode(ReviewDigest.self, from: Data(#"{"sourceMachineID":"a","repo":"/tmp/isolated","branch":"same","subject":"来源冲突也要可读","mergesCleanly":true}"#.utf8))
        try write([review], to: root.appendingPathComponent("reviews/b.json"))
        let snapshot = await Store.loadSecond(root: root)
        let actual = try XCTUnwrap(snapshot.reviews?.first)
        XCTAssertEqual(actual.subject, "来源冲突也要可读")
        XCTAssertNil(actual.sourceMachineID)
        XCTAssertNotNil(actual.landingBlockReason)
        let store = Store(); store.debugAttachRoot(root)
        let sent = await store.decideReview(actual, action: "discard", reason: "隔离拒绝")
        XCTAssertFalse(sent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("actions").path))
    }

    @MainActor
    func testSuccessfulOldRevisionDoesNotBlockNewReviewRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var review = try JSONDecoder().decode(ReviewDigest.self, from: Data(#"{"sourceMachineID":"a","repo":"/tmp/isolated","branch":"same","head":"1111111111111111111111111111111111111111","mergesCleanly":true}"#.utf8))
        let store = Store(); store.debugAttachRoot(root)
        let first = await store.decideReview(review, action: "discard", reason: "第一轮")
        XCTAssertTrue(first)
        let submission = try XCTUnwrap(store.reviewSubmission(review))
        let receipt = MobileActionReceipt(actionID: submission.actionID, invocationID: submission.invocationID,
            machineID: "a", state: "succeeded", message: "已交回整改", updatedAt: Date(), attempts: 1)
        try write(receipt, to: root.appendingPathComponent("action-receipts/" + MobileActionRoute.receiptName(
            actionID: submission.actionID, invocationID: submission.invocationID)))
        await store.refreshActionReceipts()
        XCTAssertEqual(store.reviewSubmission(review)?.receipt?.state, "succeeded")
        let same = await store.decideReview(review, action: "merge", reason: nil)
        XCTAssertFalse(same, "同一成果版本不能接着提交相反决定")
        let oldID = review.actionID("discard")
        review.head = String(repeating: "2", count: 40)
        XCTAssertNotEqual(review.actionID("discard"), oldID)
        XCTAssertNil(store.reviewSubmission(review), "新HEAD不能继承旧版成功回执")
        let next = await store.decideReview(review, action: "discard", reason: "新版本第二轮")
        XCTAssertTrue(next)
        XCTAssertNotEqual(store.reviewSubmission(review)?.invocationID, submission.invocationID)
    }

    @MainActor
    func testOppositeActionsSharePendingResourceButOtherMachineDoesNot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(); store.debugAttachRoot(root)
        func action(_ machine: String, _ operation: String) -> FeedAction {
            FeedAction(id: "machine:" + MobileActionRoute.digest(machine) + ":review:" + operation + ":/tmp/isolated|same|head", label: operation)
        }
        let first = await store.invoke(action("a", "merge"), note: nil)
        let opposite = await store.invoke(action("a", "discard"), note: "opposite")
        let otherMachine = await store.invoke(action("b", "merge"), note: nil)
        XCTAssertTrue(first)
        XCTAssertFalse(opposite, "合入已排队时不得同时发出丢弃")
        XCTAssertTrue(otherMachine, "另一台机器同资源仍然可以独立操作")
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("actions"), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
    }
}

/// 分阶段刷新的契约：首屏轻量提交（dashboard + 任务摘要 + 已缓存的下发页），
/// 问题/验收/历史结果后补。三条硬边界各有一条测试钉住：
/// 旧请求不得越过连接边界、并发刷新不得重复读盘、单一来源失败不得清掉旧画面。
///
/// 全部跑在本地临时目录上 —— 不依赖真实 iCloud，也没有任何网络等待。
@MainActor
final class StagedRefreshTests: XCTestCase {
    func testNotificationIsLoadedByExactIDAndSurvivesMissingLivePage() async throws {
        let root = try makeRoot(heavy: false)
        let id = String(repeating: "a", count: 64)
        let dir = root.appendingPathComponent("notification-details")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("""
        {"id":"\(id)","createdAt":"2026-09-03T01:00:00Z","body":"通知原文","content":{"schema":1,"page":"review","generatedAt":"2026-09-03T01:00:00Z","sections":[{"kind":"cards","cards":[{"id":"card","title":"M2 的完整详情","detail":"旧实时页被覆盖仍可阅读"}]}]}}
        """.utf8).write(to: dir.appendingPathComponent(id + ".json"))
        let s = store(root: root)
        let value = await s.loadNotificationDetail(id: id)
        XCTAssertEqual(value?.body, "通知原文")
        XCTAssertEqual(value?.content?.sections.first?.cards?.first?.detail, "旧实时页被覆盖仍可阅读")
        let wrong = await s.loadNotificationDetail(id: String(repeating: "b", count: 64))
        XCTAssertNil(wrong)
        let unsafe = await s.loadNotificationDetail(id: "../../outside")
        XCTAssertNil(unsafe)
        try Data("{\"id\":\"wrong\"}".utf8).write(to: dir.appendingPathComponent(id + ".json"))
        let corrupt = await s.loadNotificationDetail(id: id)
        XCTAssertNil(corrupt)
    }

    private var roots: [URL] = []
    private let decoder = JSONDecoder()

    override func setUpWithError() throws {
        decoder.dateDecodingStrategy = .iso8601
    }

    override func tearDown() async throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        DashboardCache.directoryOverride = nil
    }

    // MARK: - 夹具

    /// 标准根目录：dashboard.json + 一块在跑的任务板。
    /// heavy = 再塞满 questions/reviews/outbox/evidence 四个大目录 ——
    /// 首屏阶段对它们应当视而不见，而不是等它们读完。
    private func makeRoot(heavy: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llmq-staged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        let now = ISO8601DateFormatter().string(from: Date())
        try Data("""
        {"generatedAt":"\(now)","machines":[{"machineID":"m1","machineName":"测试机","lastSeen":"\(now)","isStale":false}],"reports":[]}
        """.utf8)
            .write(to: root.appendingPathComponent("dashboard.json"), options: .atomic)
        let boards = root.appendingPathComponent("taskboards", isDirectory: true)
        try FileManager.default.createDirectory(at: boards, withIntermediateDirectories: true)
        try Data("""
        {"machineID":"m1","machineName":"测试机","generatedAt":"\(now)",\
        "tasks":[{"id":"t1","title":"首屏就要看见的活","state":"running",\
        "platform":"codex","machineName":"测试机"}],"tasksTruncated":false}
        """.utf8)
            .write(to: boards.appendingPathComponent("m1.json"), options: .atomic)

        if heavy {
            // ~2.9MB 的垃圾负载：首屏阶段哪怕多看它们一眼都会超时。
            let junk = "[" + (0..<600).map { "\"占位内容-\($0)\"" }
                .joined(separator: ",") + "]"
            for dir in ["outbox", "questions/m1", "reviews", "evidence"] {
                let d = root.appendingPathComponent(dir, isDirectory: true)
                try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                for i in 0..<30 {
                    try Data(junk.utf8).write(
                        to: d.appendingPathComponent("heavy-\(i).json"), options: .atomic)
                }
            }
        }
        return root
    }

    private func store(root url: URL) -> Store {
        let s = Store()
        s.debugAttachRoot(url)
        return s
    }

    private func decodedDashboard(from root: URL) throws -> Dashboard {
        let data = try Data(contentsOf: root.appendingPathComponent("dashboard.json"))
        return try decoder.decode(Dashboard.self, from: data)
    }

    // MARK: 首屏性能边界

    /// 边界之一（结构）：首屏阶段允许触碰的路径白名单里，
    /// 不许出现问题、验收、历史结果、媒体这些慢速来源。
    func testFirstStagePlanExcludesSlowSources() throws {
        let root = try makeRoot(heavy: false)
        let plan = Store.firstStageInputs(root: root)
        let paths = (plan.files + plan.dirs).map(\.path)

        XCTAssertTrue(paths.contains(root.appendingPathComponent("dashboard.json").path),
                      "额度总览依赖 dashboard.json，必须在首屏名单里")
        XCTAssertTrue(plan.dirs.contains(root.appendingPathComponent("taskboards")),
                      "任务摘要来自 taskboards/，必须在首屏名单里")
        for banned in ["questions", "reviews", "outbox", "evidence",
                       "office.json", "playbook.json", "repos.json"] {
            XCTAssertFalse(paths.contains { $0.contains(banned) },
                           "首屏阶段不许触碰慢速来源 \(banned)")
        }
    }

    /// 边界之二（实测）：塞满四个大目录的根目录上，首屏阶段照样秒回，
    /// 而且任务摘要是真的。谁把整包读盘改回来，这条先红。
    func testFastStageIgnoresHeavyDirectoriesAndStaysBounded() async throws {
        let root = try makeRoot(heavy: true)
        let start = Date()
        let snap = await Store.loadFirst(root: root)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 1.0,
                          "首屏阶段读盘 \(Int(elapsed * 1000))ms —— 它在等慢速来源了")
        XCTAssertNotNil(snap.dashboard)
        XCTAssertTrue(snap.tasks.published, "任务摘要在首屏就必须可用")
        XCTAssertEqual(snap.tasks.running.first?.title, "首屏就要看见的活")
    }

    /// 边界之三（职责）：慢阶段**类型上就没有** dashboard/tasks ——
    /// 重算既浪费也不归它管，想重算编译都过不去。
    /// （目录存在但内容为空的来源返回 [] 是权威的「确实没有」，不是失败。）
    func testSlowStageCarriesOnlyDeferredSources() async throws {
        let root = try makeRoot(heavy: false)
        let snap = await Store.loadSecond(root: root)
        XCTAssertNotNil(snap.feeds, "慢阶段要把 views/ 催完再整体校正一次")
        XCTAssertTrue(snap.asks?.isEmpty ?? true,
                      "questions/ 目录都不存在时，权威地就是没有问题")
    }

    // MARK: 提交顺序

    func testFastStageCommitsBeforeSlowStageFinishes() async throws {
        let root = try makeRoot(heavy: false)
        let s = store(root: root)
        let gate = AsyncStream.makeStream(of: Void.self)
        let dash = try decodedDashboard(from: root)
        let fast = FirstStageSnapshot(dashboard: dash)
        let menu = FeedMenu(schema: 1, generatedAt: Date(), entries: [])
        s.loadFirstStage = { _ in fast }
        s.loadSecondStage = { _ in
            // AsyncSequence 没有零参 first() —— 等到第一个信号就走。
            for await _ in gate.stream { break }
            return SecondStageSnapshot(menu: menu)
        }

        let run = Task { await s.refresh() }
        var waited = 0
        while s.dashboard == nil, waited < 500 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        XCTAssertNotNil(s.dashboard, "快阶段必须在慢阶段还在路上时就先提交")
        XCTAssertNil(s.menu, "慢阶段没回来之前，它的产物不该出现")

        gate.continuation.yield()
        gate.continuation.finish()
        await run.value
        XCTAssertNotNil(s.menu, "慢阶段完成后产物要落进界面")
    }

    // MARK: 连接 generation 隔离

    func testStageThatOutlivesItsConnectionIsDropped() async throws {
        let root = try makeRoot(heavy: false)
        let s = store(root: root)
        let dash = try decodedDashboard(from: root)
        s.loadFirstStage = { _ in
            try? await Task.sleep(nanoseconds: 300_000_000)
            return FirstStageSnapshot(dashboard: dash)
        }
        let run = Task { await s.refresh() }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(s.isConnected)
        s.disconnect()
        await run.value

        XCTAssertNil(s.dashboard, "断开之后旧阶段的产物不得贴到新会话上")
        XCTAssertTrue(s.feeds.isEmpty)
        XCTAssertNil(s.menu)
        XCTAssertFalse(s.taskDigest.published,
                       "断开后「有没有任务」回到不知道，不是旧板子的答案")
    }

    // MARK: 并发去重

    func testConcurrentRefreshRunsEachStageOnce() async throws {
        let root = try makeRoot(heavy: false)
        let s = store(root: root)
        actor Counter {
            var n = 0
            func inc() { n += 1 }
            func value() -> Int { n }
        }
        let firstCount = Counter()
        let secondCount = Counter()
        s.loadFirstStage = { _ in
            await firstCount.inc()
            try? await Task.sleep(nanoseconds: 250_000_000)
            return FirstStageSnapshot()
        }
        s.loadSecondStage = { _ in
            await secondCount.inc()
            return SecondStageSnapshot()
        }

        async let a: Void = s.refresh()
        async let b: Void = s.refresh()
        _ = await (a, b)

        // XCTest 断言的参数是 autoclosure，里面不许写 await —— 先取出来。
        let firstRuns = await firstCount.value()
        let secondRuns = await secondCount.value()
        XCTAssertEqual(firstRuns, 1,
                       "进行中的刷新必须挡住并发的第二次")
        XCTAssertEqual(secondRuns, 1)
    }

    // MARK: 单源失败保留旧数据

    func testFailedRoundKeepsEverythingAlreadyOnScreen() async throws {
        let root = try makeRoot(heavy: false)
        let s = store(root: root)
        let dash = try decodedDashboard(from: root)
        let feed = FeedPage(schema: 1, page: "collaboration",
                            generatedAt: Date(), sections: [])
        let menu = FeedMenu(schema: 1, generatedAt: Date(), entries: [])
        // 首屏阶段本来就会读到已缓存的下发页和入口 —— 快照要照实带。
        let fast = FirstStageSnapshot(
            dashboard: dash,
            feeds: FeedsLoad(pages: ["collaboration": feed], complete: true),
            menu: menu)
        let good = SecondStageSnapshot(
            events: [], results: [],
            feeds: FeedsLoad(pages: ["collaboration": feed], complete: true),
            menu: menu)
        s.loadFirstStage = { _ in fast }
        s.loadSecondStage = { _ in good }
        await s.refresh()
        XCTAssertEqual(s.feeds["collaboration"]?.page, "collaboration")
        XCTAssertNotNil(s.menu)

        // 下一轮慢阶段整体失手（nil = 这一轮没读到）：
        // 屏幕上已经有的东西必须原样保留。
        s.loadSecondStage = { _ in SecondStageSnapshot() }
        await s.refresh()

        XCTAssertEqual(s.feeds["collaboration"]?.page, "collaboration",
                       "一轮读盘失败不该把已显示的下发页抹成空白")
        XCTAssertNotNil(s.menu, "menu 读不到时保留上一份，而不是清空入口")
        XCTAssertNotNil(s.dashboard)
    }

    func testDashboardCacheSurvivesRestartWhenSharedFileIsTemporarilyUnavailable() async throws {
        let root = try makeRoot(heavy: false)
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("dashboard-cache-\(UUID().uuidString)", isDirectory: true)
        roots.append(cache)
        DashboardCache.directoryOverride = cache

        let first = await Store.loadFirst(root: root)
        let generatedAt = try XCTUnwrap(first.dashboard?.generatedAt)
        XCTAssertNil(first.dashboardError)

        // 模拟 App 被杀掉后重新启动时，iCloud 只给到半个 JSON。
        try Data(#"{"generatedAt":"#.utf8)
            .write(to: root.appendingPathComponent("dashboard.json"), options: .atomic)
        let afterRestart = await Store.loadFirst(root: root)

        XCTAssertEqual(afterRestart.dashboard?.generatedAt, generatedAt)
        XCTAssertNotNil(afterRestart.dashboardError,
                        "缓存只能兜底，必须同时告诉人本轮共享数据不可用")
    }

    // MARK: 下发页完整性

    func testPartialFeedsRoundMergesOverOldPagesInsteadOfWiping() throws {
        let good = FeedPage(schema: 1, page: "collaboration",
                            generatedAt: Date(), sections: [])
        let stale = FeedPage(schema: 1, page: "roadmap",
                             generatedAt: Date(), sections: [])
        let s = Store()
        s.apply(FirstStageSnapshot(
            feeds: FeedsLoad(pages: ["collaboration": good, "roadmap": stale],
                             complete: true)))
        // 下一轮只有 collaboration 读到了，roadmap 解码失败（complete=false）：
        // 读到的新鲜页照常换，读不到的旧页原地保留。
        let fresh = FeedPage(schema: 1, page: "collaboration",
                             generatedAt: Date(), sections: [])
        s.apply(FirstStageSnapshot(
            feeds: FeedsLoad(pages: ["collaboration": fresh], complete: false)))

        XCTAssertEqual(s.feeds["collaboration"]?.generatedAt,
                       fresh.generatedAt, "读到的页要用新鲜的")
        XCTAssertNotNil(s.feeds["roadmap"],
                        "解不开的那一页不许悄悄消失 —— 那是把读不到说成了没有")
    }

    /// finding 158d91ba 第 2 条：快阶段读的是「已在本机」的子集，
    /// 它没看到一页 ≠ 服务端撤了这一页 —— **快阶段永远只加不删**。
    /// 权威增删只归催完整个 views/ 的慢阶段。
    func testFastStageMergeOnlyNeverDeletesPages() throws {
        let roadmap = FeedPage(schema: 1, page: "roadmap",
                               generatedAt: Date(), sections: [])
        let collab = FeedPage(schema: 1, page: "collaboration",
                              generatedAt: Date(), sections: [])
        let s = Store()
        s.apply(SecondStageSnapshot(
            feeds: FeedsLoad(pages: ["roadmap": roadmap, "collaboration": collab],
                             complete: true)))
        // 快阶段这一轮缓存为空（同步抖动/全在云上），哪怕它自称 complete：
        s.apply(FirstStageSnapshot(feeds: FeedsLoad(pages: [:], complete: true)))

        XCTAssertNotNil(s.feeds["roadmap"], "快阶段空缓存不得删旧页")
        XCTAssertNotNil(s.feeds["collaboration"], "快阶段空缓存不得删旧页")
    }

    func testSlowStageCompleteRoundReplacesAuthoritatively() throws {
        let stale = FeedPage(schema: 1, page: "roadmap",
                             generatedAt: Date(), sections: [])
        let s = Store()
        s.apply(SecondStageSnapshot(
            feeds: FeedsLoad(pages: ["roadmap": stale], complete: true)))
        // 慢阶段完整的一轮里 roadmap 已经不在了 —— 它催完过整个 views/，
        // 服务端撤下的页面就该跟着撤下；快阶段无权做这个结论。
        s.apply(SecondStageSnapshot(feeds: FeedsLoad(pages: [:], complete: true)))
        XCTAssertFalse(s.feeds.contains(where: { $0.key == "roadmap" }))
    }

    func testSlowStageIncompleteRoundKeepsPagesInsteadOfWiping() throws {
        let stale = FeedPage(schema: 1, page: "roadmap",
                             generatedAt: Date(), sections: [])
        let fresh = FeedPage(schema: 1, page: "collaboration",
                             generatedAt: Date(), sections: [])
        let s = Store()
        s.apply(SecondStageSnapshot(
            feeds: FeedsLoad(pages: ["roadmap": stale], complete: true)))
        s.apply(SecondStageSnapshot(
            feeds: FeedsLoad(pages: ["collaboration": fresh], complete: false)))
        XCTAssertNotNil(s.feeds["roadmap"])
        XCTAssertEqual(s.feeds["collaboration"]?.generatedAt, fresh.generatedAt)
    }

    // MARK: loadFeeds 目录层面的三种情况（finding 158d91ba）

    func testLoadFeedsIgnoresMenuJSONForCompleteness() throws {
        let root = try makeRoot(heavy: false)
        let views = root.appendingPathComponent("views", isDirectory: true)
        try FileManager.default.createDirectory(at: views, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter().string(from: Date())
        try Data("""
        {"schema":1,"page":"collaboration","generatedAt":"\(now)","sections":[]}
        """.utf8).write(to: views.appendingPathComponent("collaboration.json"))
        try Data("""
        {"schema":1,"generatedAt":"\(now)","entries":[]}
        """.utf8).write(to: views.appendingPathComponent("menu.json"))

        let out = Store.loadFeeds(root: root, decoder: decoder, freshenFirst: false)
        XCTAssertEqual(out.pages.map(\.key), ["collaboration"])
        XCTAssertTrue(out.complete,
                      "menu.json 是入口名单不是下发页，不许把它当解不开的页按住 complete")
    }

    func testMissingViewsDirIsAuthoritativeEmptyButUnreadableViewsKeepOldPages() throws {
        // 目录真的不存在：老服务端从没发过页面 —— 权威地为空。
        let absent = try makeRoot(heavy: false)
        let outAbsent = Store.loadFeeds(root: absent, decoder: decoder, freshenFirst: false)
        XCTAssertTrue(outAbsent.complete)
        XCTAssertTrue(outAbsent.pages.isEmpty)

        // views/ 被占位成了普通文件 / 列不出内容：这轮不可信，保留旧页面。
        let broken = try makeRoot(heavy: false)
        try Data("not a directory".utf8)
            .write(to: broken.appendingPathComponent("views"))
        let outBroken = Store.loadFeeds(root: broken, decoder: decoder, freshenFirst: false)
        XCTAssertFalse(outBroken.complete, "views 在但读不了时必须报不完整")
        XCTAssertTrue(outBroken.pages.isEmpty)

        let s = Store()
        let roadmap = FeedPage(schema: 1, page: "roadmap",
                               generatedAt: Date(), sections: [])
        s.apply(SecondStageSnapshot(
            feeds: FeedsLoad(pages: ["roadmap": roadmap], complete: true)))
        s.apply(SecondStageSnapshot(
            feeds: FeedsLoad(pages: [:], complete: false)))
        XCTAssertNotNil(s.feeds["roadmap"],
                        "views 列不出来的一轮不许把已显示的页面清掉")
    }

    func testMenuPlaceholderAlsoDoesNotBreakCompleteness() throws {
        let root = try makeRoot(heavy: false)
        let views = root.appendingPathComponent("views", isDirectory: true)
        try FileManager.default.createDirectory(at: views, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter().string(from: Date())
        try Data("""
        {"schema":1,"page":"collaboration","generatedAt":"\(now)","sections":[]}
        """.utf8).write(to: views.appendingPathComponent("collaboration.json"))
        try Data("placeholder".utf8)
            .write(to: views.appendingPathComponent(".menu.json.icloud"))

        let out = Store.loadFeeds(root: root, decoder: decoder, freshenFirst: false)
        XCTAssertEqual(out.pages.map(\.key), ["collaboration"])
        XCTAssertTrue(out.complete,
                      "menu 的 iCloud 占位符同理，不该按住页面完整性")
    }

    func testLoadFeedsReportsCompletenessInsteadOfSilentlyDropping() throws {
        let root = try makeRoot(heavy: false)
        let views = root.appendingPathComponent("views", isDirectory: true)
        try FileManager.default.createDirectory(at: views, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter().string(from: Date())
        try Data("""
        {"schema":1,"page":"collaboration","generatedAt":"\(now)","sections":[]}
        """.utf8).write(to: views.appendingPathComponent("collaboration.json"))
        try Data("{broken".utf8).write(to: views.appendingPathComponent("roadmap.json"))

        let out = Store.loadFeeds(root: root, decoder: decoder, freshenFirst: false)
        XCTAssertEqual(out.pages.map(\.key).sorted(), ["collaboration"])
        XCTAssertFalse(out.complete, "有一页解不出来时必须如实报告不完整")
    }
}

/// 办公室生活感的独立验收；时间由用例控制，数据只来自隔离夹具。
final class IndependentOfficeLifeTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
    private func decode<T: Decodable>(_ object: Any, _ type: T.Type = T.self) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: JSONSerialization.data(withJSONObject: object))
    }
    private func machine(_ id: String = "a") throws -> MachineInfo {
        try decode(["machineID": id, "machineName": "同名 Mac", "lastSeen": iso(now), "isStale": false])
    }
    private func report(_ platform: String = "codex", age: Double? = nil, ids: [String] = ["a"]) throws -> PlatformReport {
        var value: [String: Any] = ["platform": platform, "detected": true, "installed": true,
                                    "machineIDs": ids, "machines": ["同名 Mac"], "last30dRequests": 1]
        if let age { value["lastActivity"] = iso(now.addingTimeInterval(-age)) }
        return try decode(value)
    }
    private func task(_ state: String, _ platform: String? = "codex", id: String = UUID().uuidString) throws -> TaskBrief {
        var value: [String: Any] = ["id": id, "title": "隔离任务", "state": state]
        if let platform { value["platform"] = platform }
        return try decode(value)
    }
    private func event(_ kind: String, age: Double, machine: String = "a", platform: String = "codex") throws -> OfficeEvent {
        try decode(["id": UUID().uuidString, "kind": kind, "at": iso(now.addingTimeInterval(-age)),
                    "machineID": machine, "platform": platform, "taskID": "office-test-task"])
    }
    private func board(_ tasks: [TaskBrief] = [], machine: String = "a") -> TaskBoardLoad {
        TaskBoardLoad(machineID: machine, machineName: "同名 Mac", generatedAt: now, tasks: tasks)
    }
    private func mood(_ report: PlatformReport, board: TaskBoardLoad, asks: [Ask] = [], events: [OfficeEvent] = [], observed: Date? = nil) throws -> OfficeActivity {
        OfficeActivity.resolve(report: report, machine: try machine(), tasks: TaskDigest(boards: [board], now: now),
                               asks: asks, events: events, idleSince: observed, now: now)
    }
    func testPriorityKeepsQuestionsAndLiveTasksAheadOfQuotaAndIdle() throws {
        var r = try report(age: 4000); r.cooldownUntil = now.addingTimeInterval(100)
        let asks: [Ask] = try decode([["id": "a-q", "machineID": "a", "platform": "codex"]])
        XCTAssertEqual(try mood(r, board: board([task("running")]), asks: asks), .asking)
        XCTAssertEqual(try mood(r, board: board([task("queued"), task("blocked"), task("running")])), .working)
        XCTAssertEqual(try mood(r, board: board([task("queued"), task("blocked")])), .blocked)
        XCTAssertEqual(try mood(r, board: board([task("new-server-state")])), .blocked)
        XCTAssertEqual(try mood(r, board: board([task("queued")])), .queued)
        XCTAssertEqual(try mood(r, board: board()), .depleted)
        let otherAsks: [Ask] = try decode([["id": "b-q", "machineID": "b", "platform": "codex"]])
        XCTAssertEqual(try mood(try report(), board: board(), asks: otherAsks), .ready)
        XCTAssertEqual(try mood(try report(age: 4000), board: board([task("queued", nil)])), .unknown)
    }
    func testUnreliableBoardsAndMachineNeverBecomeSleepingOrWorking() throws {
        let m = try machine(), r = try report(age: 4000)
        let asks: [Ask] = try decode([["id": "stale-q", "machineID": "a", "platform": "codex"]])
        var invalid = [TaskBoardLoad]()
        var b = board(); b.generatedAt = now.addingTimeInterval(-1801); invalid.append(b)
        b = board(); b.generatedAt = nil; invalid.append(b)
        b = board(); b.generatedAt = now.addingTimeInterval(TaskDigest.futureTolerance + 1); invalid.append(b)
        b = board(); b.truncated = true; invalid.append(b)
        b = board(); b.unreadable = "not downloaded"; invalid.append(b)
        b = board(); b.isFallback = true; invalid.append(b)
        invalid.append(board(machine: "b"))
        for source in invalid {
            XCTAssertNil(OfficeActivity.freshBoard(machine: m, tasks: TaskDigest(boards: [source], now: now), now: now))
            XCTAssertEqual(try mood(r, board: source), .unknown)
            XCTAssertEqual(try mood(r, board: source, asks: asks), .unknown,
                           "过期问题文件不能越过机器/任务板新鲜度，把离线员工演成正在提问")
        }
        for age in [-(TaskDigest.futureTolerance + 1), 1801] {
            var stale = m; stale.lastSeen = now.addingTimeInterval(-age)
            XCTAssertNil(OfficeActivity.freshBoard(machine: stale, tasks: TaskDigest(boards: [board()], now: now), now: now))
        }
        var stale = m; stale.isStale = true
        XCTAssertNil(OfficeActivity.freshBoard(machine: stale, tasks: TaskDigest(boards: [board()], now: now), now: now))
        XCTAssertEqual(OfficeActivity.resolve(report: r, machine: nil, tasks: TaskDigest(boards: [board()], now: now), asks: [], events: [], idleSince: now.addingTimeInterval(-4000), now: now), .unknown)
    }
    func testSleepBoundaryAndObservedIdleDoNotBorrowAnotherMachineHistory() throws {
        XCTAssertEqual(try mood(try report(age: 1199), board: board()), .ready)
        XCTAssertEqual(try mood(try report(age: 1200), board: board()), .sleeping)
        XCTAssertEqual(try mood(try report(age: 4000), board: board(), observed: now.addingTimeInterval(-1199)), .ready)
        XCTAssertEqual(try mood(try report(age: 4000, ids: ["a", "b"]), board: board()), .ready)
        XCTAssertEqual(try mood(try report(age: 4000, ids: []), board: board()), .ready, "无稳定ID的单个名字也可能来自两台同名机器，不能借用其lastActivity")
        XCTAssertEqual(try mood(try report(), board: board(), events: [event("finished", age: 4000, machine: "b")]), .ready)
        XCTAssertEqual(try mood(try report(), board: board(), observed: now.addingTimeInterval(-1200)), .sleeping)
        XCTAssertEqual(try mood(try report(), board: board(), events: [event("idle", age: 5000)]), .ready)
        XCTAssertNil(OfficeActivity.idleStart(report: try report(age: -1), machine: try machine(), events: [], observed: now.addingTimeInterval(-5000), now: now))
    }
    func testCelebrationUsesOnlyRecentExactMachineEventAndCannotReplayHistory() throws {
        let r = try report()
        let completed = board([try task("done", id: "office-test-task")])
        XCTAssertEqual(try mood(r, board: completed, events: [event("finished", age: 0)]), .celebrating)
        XCTAssertEqual(try mood(r, board: completed, events: [event("finished", age: 11)]), .celebrating)
        XCTAssertEqual(try mood(r, board: completed, events: [event("finished", age: 12)]), .ready)
        XCTAssertEqual(try mood(r, board: completed, events: [event("finished", age: -1)]), .ready)
        XCTAssertEqual(try mood(r, board: completed, events: [event("finished", age: 1, machine: "b")]), .ready)
        XCTAssertEqual(try mood(r, board: completed, events: [event("finished", age: 1, machine: "")]), .ready)
        XCTAssertEqual(try mood(r, board: board([task("running")]), events: [event("finished", age: 0)]), .working)
        XCTAssertEqual(try mood(r, board: completed, events: [event("finished", age: 2), event("answered", age: 1)]), .ready)
    }
    func testFinishedEventRequiresMatchingActualTerminalTaskBeforeCelebration() throws {
        let r = try report(), finished = try event("finished", age: 1)
        for (state, expected) in [("done", "celebrating"), ("failed", "failed"), ("blocked", "blocked"), ("running", "working"), ("queued", "queued")] {
            XCTAssertEqual(try mood(r, board: board([task(state, id: "office-test-task")]), events: [finished]).rawValue, expected)
        }
        XCTAssertEqual(try mood(r, board: board(), events: [finished]).rawValue, "unknown")
        XCTAssertEqual(try mood(r, board: board([task("done", id: "different-task")]), events: [finished]).rawValue, "unknown")
        XCTAssertEqual(try mood(r, board: board([task("done", "kimi", id: "office-test-task")]), events: [finished]).rawValue, "unknown")
        XCTAssertEqual(try mood(r, board: board([task("done", id: "office-test-task")], machine: "b"), events: [finished]).rawValue, "unknown")
        var directed = finished; directed.platform = "kimi"; directed.toPlatform = "codex"
        XCTAssertEqual(try mood(r, board: board([task("done", "kimi", id: "office-test-task")]), events: [directed]).rawValue, "ready", "finished不能让toPlatform员工跟着庆祝")
    }
    func testSharedBreakRequiresEveryPersonAndEntireMachineToBeIdle() throws {
        let start = now.addingTimeInterval(-120)
        func rest(_ states: [OfficeActivity] = [.ready, .sleeping], _ starts: [Date?]? = nil,
                  _ source: TaskBoardLoad? = nil, _ question: Bool = false, phase: Double = 0) -> OfficeActivity? {
            OfficeActivity.sharedBreak(activities: states, idleStarts: starts ?? [start, start],
                                       board: source ?? board(), hasQuestions: question, now: now.addingTimeInterval(phase))
        }
        XCTAssertEqual(rest(), .stretching)
        XCTAssertEqual(rest(phase: 15), .sipping)
        XCTAssertNil(rest(phase: 30))
        XCTAssertNil(rest([.ready], [start]))
        XCTAssertNil(rest([.ready, .working]))
        XCTAssertNil(rest([.ready, .unknown]))
        XCTAssertNil(rest([.ready, .depleted]))
        XCTAssertNil(rest([.ready, .ready], [nil, start]))
        XCTAssertNil(rest([.ready, .ready], [now.addingTimeInterval(-119), start]))
        XCTAssertNil(rest([.ready, .ready], nil, board([try task("queued", "other")])) )
        XCTAssertNil(rest([.ready, .ready], nil, board([try task("new-server-state", nil)])))
        XCTAssertNil(rest([.ready, .ready], nil, nil, true))
        XCTAssertEqual(rest([.ready, .ready], nil, board([try task("done")])), .stretching)
    }
}

import SwiftUI
import UIKit

extension IndependentOfficeLifeTests {
    @MainActor
    func testSystemMotionSettingAndBackgroundFreezeOfficeWhileLegacyStaffStillRenders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("office-render-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ object: Any, _ path: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        try write(["generatedAt": stamp, "machines": [["machineID": "render-a", "machineName": "验收 MacBook Pro", "lastSeen": stamp, "isStale": false]],
            "reports": [["platform": "codex", "agentName": "Codex", "detected": true, "installed": true,
                         "machineIDs": ["render-a"], "machines": ["验收 MacBook Pro"], "last30dRequests": 20]]], "dashboard.json")
        try write(["machineID": "render-a", "generatedAt": stamp, "tasks": [], "tasksTruncated": false], "taskboards/render-a.json")
        try write(["id": "render-ask", "machineID": "render-a", "platform": "codex", "taskID": "render", "questions": [["id": "q", "text": "减少动态仍有问号"]]], "questions/render-a/render.json")
        let store = Store(); store.debugAttachRoot(root); await store.refresh()
        XCTAssertEqual(store.asks.count, 1)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        defer { window.isHidden = true; window.rootViewController = nil }
        func snapshot(_ view: UIView) -> UIImage {
            UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
                view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            }
        }
        func pair(phase: ScenePhase, staff: Bool = false) async throws -> (Data, Data) {
            let content = staff ? AnyView(StaffView().environmentObject(store)) : AnyView(OfficeView().environmentObject(store))
            let host = UIHostingController(rootView: content.environment(\.scenePhase, phase))
            window.rootViewController = host; window.makeKeyAndVisible()
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(1500))
            let first = snapshot(host.view)
            let before = XCTAttachment(image: first); before.name = "独立办公室-首帧-\(UIAccessibility.isReduceMotionEnabled)-\(phase)-\(staff)"; before.lifetime = .keepAlways; add(before)
            try await Task.sleep(for: .milliseconds(450))
            let second = snapshot(host.view)
            let attachment = XCTAttachment(image: second)
            attachment.name = staff ? "独立办公室-原员工页默认形象" : "独立办公室-减少动态\(UIAccessibility.isReduceMotionEnabled)-\(phase)"
            attachment.lifetime = .keepAlways; add(attachment)
            // The iOS glass toolbar changes pixels as its window material settles.
            // Compare the work area below that toolbar, including the full staff row.
            func workArea(_ image: UIImage) throws -> Data {
                let cg = try XCTUnwrap(image.cgImage)
                let top = Int(160 * image.scale)
                let cropped = try XCTUnwrap(cg.cropping(to: CGRect(x: 0, y: top, width: cg.width, height: cg.height - top)))
                return try XCTUnwrap(UIImage(cgImage: cropped).pngData())
            }
            return (try workArea(first), try workArea(second))
        }
        let reduced = UIAccessibility.isReduceMotionEnabled
        print("OFFICE_SYSTEM_REDUCE_MOTION=\(reduced)")
        let active = try await pair(phase: .active)
        XCTAssertGreaterThan(active.0.count, 10_000, "必须渲染实际页面，不能用空白图相等冒充动画关闭")
        if reduced {
            XCTAssertTrue(active.0 == active.1, "系统减少动态开启时，问号和机器人都应静止")
        } else {
            XCTAssertTrue(active.0 != active.1, "正常前台应确实有局部动作")
        }
        let background = try await pair(phase: .background)
        XCTAssertTrue(background.0 == background.1, "后台不能继续播放办公室小人动作")
        let legacy = try await pair(phase: .active, staff: true)
        XCTAssertGreaterThan(legacy.0.count, 10_000)
        if reduced { XCTAssertTrue(legacy.0 == legacy.1, "原员工页默认姿态也服从系统减少动态") }

    }
}


/// 首页可确认数量必须与真实操作门槛一致，证据存在不代表质量结论已通过。
@MainActor
final class IndependentReviewReadinessTests: XCTestCase {
    private let blocker = "质量契约要求先逐帧验收截图/录屏；当前还没有视觉结论。"
    private func digest(_ extra: [String: Any] = [:]) throws -> ReviewDigest {
        var fields: [String: Any] = ["sourceMachineID": "ready-a", "repo": "/tmp/ready-isolated", "repoName": "隔离项目", "branch": "work", "head": "6ea0cee", "platform": "codex", "subject": "隔离成果", "mergesCleanly": true]
        fields.merge(extra) { _, new in new }
        return try JSONDecoder().decode(ReviewDigest.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    private func write<T: Encodable>(_ value: T, root: URL, path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(value).write(to: url, options: .atomic)
    }
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-readiness-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testQualityReasonIsNotOverruledByCleanMergeOrExistingEvidenceAndMissingIdentityIsReadOnly() throws {
        let ready = try digest()
        XCTAssertNil(ready.confirmationBlockReason)
        var blocked = try digest(["landingBlockReason": blocker, "evidenceFiles": ["recording.mp4", "shot.png"]])
        XCTAssertEqual(blocked.confirmationBlockReason, blocker)
        XCTAssertEqual(blocked.evidenceAvailability, .available(["recording.mp4", "shot.png"]))
        blocked.mergesCleanly = false
        XCTAssertEqual(blocked.confirmationBlockReason, blocker, "保持服务端的质量原因，不用本地冲突文案覆盖")
        for field in ["sourceMachineID", "head", "repo", "branch"] {
            for missing in [NSNull() as Any, "", " \n "] {
                let value = try digest([field: missing])
                XCTAssertNotNil(value.confirmationBlockReason, "缺身份字段 \(field) 不能催人确认")
                XCTAssertFalse(value.confirmationBlockReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }
        }
        let emptyReason = try digest(["landingBlockReason": " \n "])
        XCTAssertFalse(emptyReason.confirmationBlockReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
                       "服务端阻断字段为空也须解释，不能放行或显示空白原因")
        XCTAssertTrue(try digest(["mergesCleanly": false]).confirmationBlockReason?.contains("冲突") == true)
        let partial = try JSONDecoder().decode(ReviewDigest.self, from: Data(#"{"subject":"旧格式仍可阅读","platform":"future-agent","futureStatus":"future"}"#.utf8))
        XCTAssertEqual(partial.subject, "旧格式仍可阅读")
        XCTAssertEqual(partial.platform, "future-agent")
        XCTAssertNotNil(partial.confirmationBlockReason)
    }

    func testMixedCollectionTracksSubmitFailureRetryAndSuccessWithoutLosingReadableResults() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let ready = try digest(), blocked = try digest(["branch": "blocked", "landingBlockReason": blocker])
        try write([ready, blocked], root: root, path: "reviews/ready-a.json")
        let store = Store(); store.debugAttachRoot(root); await store.refresh()
        XCTAssertEqual(store.actionableReviews.map(\.id), [ready.id])
        XCTAssertEqual(store.unavailableReviews.map(\.id), [blocked.id])
        let forbidden = await store.decideReview(blocked, action: "merge", reason: nil)
        XCTAssertFalse(forbidden); XCTAssertEqual(store.lastError, blocker)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("actions").path))
        let sent = await store.decideReview(ready, action: "merge", reason: nil)
        XCTAssertTrue(sent)
        let first = try XCTUnwrap(store.reviewSubmission(ready))
        XCTAssertTrue(store.actionableReviews.isEmpty, "已提交不能继续列为等人确认")
        XCTAssertEqual(store.unavailableReviews.count, 2)
        XCTAssertEqual(store.reviews.count, 2, "进行中成果仍然可读")
        let restarted = Store(); restarted.debugAttachRoot(root); await restarted.refresh()
        XCTAssertTrue(restarted.actionableReviews.isEmpty, "重启不能恢复催办")
        for state in ["running", "failed"] {
            try write(MobileActionReceipt(actionID: first.actionID, invocationID: first.invocationID,
                machineID: "ready-a", state: state, message: "隔离回执", updatedAt: Date(), attempts: 1),
                root: root, path: "action-receipts/" + MobileActionRoute.receiptName(actionID: first.actionID, invocationID: first.invocationID))
            await store.refreshActionReceipts()
            XCTAssertEqual(store.canConfirmReview(ready), state == "failed")
            XCTAssertEqual(store.actionableReviews.count, state == "failed" ? 1 : 0)
        }
        let retried = await store.decideReview(ready, action: "merge", reason: nil)
        XCTAssertTrue(retried)
        let second = try XCTUnwrap(store.reviewSubmission(ready))
        XCTAssertNotEqual(second.invocationID, first.invocationID)
        try write(MobileActionReceipt(actionID: second.actionID, invocationID: second.invocationID,
            machineID: "ready-a", state: "succeeded", message: "隔离成功", updatedAt: Date(), attempts: 1),
            root: root, path: "action-receipts/" + MobileActionRoute.receiptName(actionID: second.actionID, invocationID: second.invocationID))
        await store.refreshActionReceipts()
        XCTAssertFalse(store.canConfirmReview(ready))
        XCTAssertTrue(store.actionableReviews.isEmpty)
        XCTAssertEqual(store.reviews.count, 2)
    }

    func testFreshReadinessMovesBackToActionableWhileMissingVersionCannotWriteMerge() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        var review = try digest(["landingBlockReason": blocker])
        try write([review], root: root, path: "reviews/ready-a.json")
        let store = Store(); store.debugAttachRoot(root); await store.refresh()
        XCTAssertTrue(store.actionableReviews.isEmpty)
        XCTAssertEqual(store.unavailableReviews.count, 1)
        review.landingBlockReason = nil; review.head = nil
        try write([review], root: root, path: "reviews/ready-a.json"); await store.refresh()
        XCTAssertTrue(store.actionableReviews.isEmpty)
        let missingVersion = await store.decideReview(review, action: "merge", reason: nil)
        XCTAssertFalse(missingVersion)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("actions").path))
        review.head = "ready-new-head"
        try write([review], root: root, path: "reviews/ready-a.json"); await store.refresh()
        XCTAssertEqual(store.actionableReviews.count, 1)
        XCTAssertTrue(store.unavailableReviews.isEmpty)
        let sent = await store.decideReview(try XCTUnwrap(store.reviews.first), action: "merge", reason: nil)
        XCTAssertTrue(sent)
        XCTAssertTrue(store.actionableReviews.isEmpty)
    }
}

@MainActor
final class DeliveryInboxTests: XCTestCase {
    private func write(_ value: [String: Any], root: URL, path: String) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value).write(to: file)
    }
    func testRejectedPlanReceiptRestoresRetryOnlyForMatchingInvocationAndTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plan-receipt-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(); store.debugAttachRoot(root)
        let sent = await store.releasePlan(machineID: "a", planID: "plan-a")
        XCTAssertTrue(sent)
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("config-intents"), includingPropertiesForKeys: nil)
        let file = try XCTUnwrap(files.first { $0.pathExtension == "json" })
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let id = try XCTUnwrap(original["id"] as? String)
        let base = "config-intents/processed/2026-09-06T000000Z-rejected-" + id
        let receipt: [String: Any] = ["id": id, "accepted": false, "note": "查重拦下：需核对已有任务", "processedAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-120)), "machine": "同名机器"]
        var wrong = original; wrong["targetMachineID"] = "b"
        try write(wrong, root: root, path: base + ".json")
        try write(receipt, root: root, path: base + ".result.json")
        let restored = Store(); restored.debugAttachRoot(root); await restored.refresh()
        XCTAssertTrue(restored.isPlanPending(machineID: "a", planID: "plan-a"), "其他目标的回执不能解除这条请求")
        try write(original, root: root, path: base + ".json")
        await restored.refresh()
        XCTAssertFalse(restored.isPlanPending(machineID: "a", planID: "plan-a"), "Mac 已明确拒绝时不能把按钮禁用七天")
        XCTAssertEqual(restored.planReleaseFailure(machineID: "a", planID: "plan-a"), "查重拦下：需核对已有任务")
        let retried = await restored.releasePlan(machineID: "a", planID: "plan-a")
        XCTAssertTrue(retried)
        await restored.refresh()
        XCTAssertTrue(restored.isPlanPending(machineID: "a", planID: "plan-a"), "上一轮失败回执不能解除新请求")
        let retryFiles = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("config-intents"), includingPropertiesForKeys: nil)
        let retryFile = try XCTUnwrap(retryFiles.first { $0.pathExtension == "json" && $0.lastPathComponent != file.lastPathComponent })
        let newIntent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: retryFile)) as? [String: Any])
        let newID = try XCTUnwrap(newIntent["id"] as? String)
        let newBase = "config-intents/processed/2026-09-06T000001Z-rejected-" + newID
        try write(newIntent, root: root, path: newBase + ".json")
        try write(receipt, root: root, path: newBase + ".result.json")
        await restored.refresh()
        XCTAssertTrue(restored.isPlanPending(machineID: "a", planID: "plan-a"), "即使文件名像新请求，回执正文的旧 UUID 也必须拒绝")
        var accepted = receipt; accepted["id"] = newID; accepted["accepted"] = true
        accepted["processedAt"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(1))
        try write(accepted, root: root, path: newBase + ".result.json")
        await restored.refresh()
        XCTAssertTrue(restored.isPlanPending(machineID: "a", planID: "plan-a"), "接受回执不能替代权威任务板的实际入队确认")
    }
    func testPlanSubmissionSurvivesNavigationRestartAndIsScopedToMachine() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-inbox-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stamp = ISO8601DateFormatter().string(from: Date())
        for machine in ["a", "b"] {
            try write(["machineID": machine, "generatedAt": stamp, "tasks": [], "tasksTruncated": false,
                "planned": [["id": "same-plan", "title": "隔离计划"]]], root: root, path: "taskboards/\(machine).json")
        }
        let store = Store(); store.debugAttachRoot(root); await store.refresh()
        XCTAssertNil(store.dashboard)
        XCTAssertEqual(store.actionInbox.plannedCount, 2)
        XCTAssertEqual(store.actionInbox.count, 2)
        let sent = await store.releasePlan(machineID: "a", planID: "same-plan")
        XCTAssertTrue(sent)
        XCTAssertEqual(store.actionInbox.plannedCount, 1)
        XCTAssertTrue(store.isPlanPending(machineID: "a", planID: "same-plan"))
        XCTAssertFalse(store.isPlanPending(machineID: "b", planID: "same-plan"))
        let restarted = Store(); restarted.debugAttachRoot(root); await restarted.refresh()
        XCTAssertEqual(restarted.actionInbox.plannedCount, 1)
        let duplicate = await restarted.releasePlan(machineID: "a", planID: "same-plan")
        XCTAssertFalse(duplicate)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("config-intents").path).count, 1)
    }
    func testInboxAndDeliveryRemainVisibleWithoutQuotaDashboard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-no-quota-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stamp = ISO8601DateFormatter().string(from: Date())
        try write(["machineID": "a", "generatedAt": stamp, "tasksTruncated": false, "tasks": [
            ["id": "repair", "title": "独立待复验任务", "state": "blocked", "waitReason": "productionGate", "machineName": "测试机器"],
            ["id": "landed", "title": "独立已合入任务", "state": "done", "landedAt": stamp, "machineName": "测试机器"],
            ["id": "waiting", "title": "独立待合入任务", "state": "done", "progressPhase": "等待合入", "machineName": "测试机器"]]], root: root, path: "taskboards/a.json")
        try write(["id": "isolated-ask", "machineID": "a", "platform": "kimi", "taskID": "repair", "questions": [["id": "q", "text": "隔离授权选择"]]], root: root, path: "questions/a/repair.json")
        let store = Store(); store.debugAttachRoot(root); await store.refresh()
        XCTAssertNil(store.dashboard)
        XCTAssertEqual(store.actionInbox.count, 1)
        XCTAssertEqual(store.taskDigest.deliveryStatus.qualityWaiting, 1)
        XCTAssertEqual(store.taskDigest.deliveryStatus.mergeWaiting, 1)
        XCTAssertEqual(store.taskDigest.deliveryStatus.landed, 1)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 1200)
        let host = UIHostingController(rootView: NowView().environmentObject(store).environmentObject(PushRegistrar()))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
        let shot = XCTAttachment(image: image); shot.name = "无额度快照时的任务与待办"; shot.lifetime = .keepAlways; add(shot)
        // SwiftUI 的 accessibility 元素不一定落在 UIView 上；截图由独立验收者实看。
        XCTAssertGreaterThan(image.pngData()?.count ?? 0, 10_000)
    }
}
