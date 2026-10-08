import XCTest
import CryptoKit

private extension XCUIApplication {
    /// iPadOS 26 exposes floating tab items as Cell/Other rather than TabBar buttons.
    /// Match the same visible navigation label, while excluding page titles.
    func navigationTab(_ title: String) -> XCUIElement {
        let conventional = tabBars.buttons[title]
        if conventional.exists { return conventional }
        return descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ AND (elementType == %d OR elementType == %d OR elementType == %d)",
            title, XCUIElement.ElementType.button.rawValue,
            XCUIElement.ElementType.cell.rawValue, XCUIElement.ElementType.other.rawValue)).firstMatch
    }
}

@MainActor
final class IndependentRoutingUITests: XCTestCase {
    private var root: URL!
    private let machines = [("acceptance-a", "验收 MacBook Pro"), ("acceptance-b", "验收 Mac mini")]
    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private var now: String { ISO8601DateFormatter().string(from: Date()) }
    private func write(_ value: Any, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .atomic)
    }
    private func setup(office: Bool = false) throws -> XCUIApplication {
        root = URL(fileURLWithPath: "/tmp/llmq-independent-routing-ui-" + UUID().uuidString)
        let reports: [[String: Any]] = office ? [["platform": "codex", "agentName": "Codex", "detected": true,
            "installed": true, "machines": machines.map { $0.1 }, "last30dRequests": 20]] : []
        try write(["generatedAt": now, "machines": machines.map { ["machineID": $0.0, "machineName": $0.1,
            "lastSeen": now, "isStale": false] as [String: Any] }, "reports": reports], "dashboard.json")
        let app = XCUIApplication(); app.launchEnvironment["LLMQ_FOLDER"] = root.path
        return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "独立路由验收-" + name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func actions() throws -> [(URL, [String: Any])] {
        try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("actions"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { ($0, try JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as! [String: Any]) }
    }
    private func showFeed(_ app: XCUIApplication) {
        app.launch()
        XCTAssertTrue(app.navigationTab("更多").waitForExistence(timeout: 10))
        app.navigationTab("更多").tap(); app.staticTexts["成果复核"].tap()
        XCTAssertTrue(app.buttons["查看完整复核内容"].waitForExistence(timeout: 5))
        app.buttons["查看完整复核内容"].tap()
    }
    private func receipt(_ pair: (URL, [String: Any]), machine: String, state: String) throws {
        try write(["actionID": pair.1["id"]!, "invocationID": pair.1["invocationID"]!,
            "machineID": machine, "state": state, "message": "隔离环境执行回执", "updatedAt": now, "attempts": 1],
            "action-receipts/" + pair.0.lastPathComponent)
    }

    func testFeedReceiptRestartWrongMachineFailureRetryAndOppositeActionIsolation() throws {
        let app = try setup()
        for (machine, label) in [(machines[0].0, "A"), (machines[1].0, "B")] {
            let page = "review-" + digest(machine)
            try write(["schema": 1, "page": page, "generatedAt": now, "sections": [["kind": "cards", "cards": [
                ["id": "same", "title": "独立 \(label) 成果", "actions": [
                    ["id": "review:merge:/tmp/isolated|same|head", "label": "\(label) 合入"],
                    ["id": "review:discard:/tmp/isolated|same|head", "label": "\(label) 丢弃"]]]]]]], "views/" + page + ".json")
        }
        showFeed(app)
        XCTAssertTrue(app.buttons["A 合入"].waitForExistence(timeout: 5)); app.buttons["A 合入"].tap()
        XCTAssertTrue(app.staticTexts.matching(identifier: "已写入，等待目标 Mac 确认").firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "已写入，等待目标 Mac 确认").count, 1,
                       "同卡相反按钮必须共享一份状态，不能重复挤占手机宽度")
        XCTAssertFalse(app.buttons["A 丢弃"].exists, "同一资源不能同时合入和丢弃")
        XCTAssertTrue(app.buttons["B 合入"].exists)
        let sent = try XCTUnwrap(actions().first)
        XCTAssertEqual(try actions().count, 1)
        XCTAssertTrue((sent.1["id"] as? String)?.hasPrefix("machine:" + digest(machines[0].0) + ":") == true)
        app.terminate(); showFeed(app)
        XCTAssertTrue(app.staticTexts.matching(identifier: "已写入，等待目标 Mac 确认").firstMatch.waitForExistence(timeout: 5))
        try receipt(sent, machine: machines[1].0, state: "succeeded")
        app.buttons.matching(identifier: "刷新处理状态").firstMatch.tap()
        XCTAssertFalse(app.staticTexts["目标 Mac 已执行成功"].exists)
        try receipt(sent, machine: machines[0].0, state: "failed")
        app.buttons.matching(identifier: "刷新处理状态").firstMatch.tap()
        XCTAssertTrue(app.staticTexts.matching(identifier: "目标 Mac 执行失败，可重试").firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "目标 Mac 执行失败，可重试").count, 1)
        XCTAssertTrue(app.buttons["A 合入"].exists); XCTAssertTrue(app.buttons["B 合入"].exists)
        capture(app, "失败可重试且未串另一机")
        app.buttons["A 合入"].tap()
        let retried = try XCTUnwrap(actions().first { $0.0 != sent.0 })
        XCTAssertNotEqual(retried.1["invocationID"] as? String, sent.1["invocationID"] as? String)
        try receipt(retried, machine: machines[0].0, state: "succeeded")
        app.buttons.matching(identifier: "刷新处理状态").firstMatch.tap()
        XCTAssertTrue(app.staticTexts.matching(identifier: "目标 Mac 已执行成功").firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "目标 Mac 已执行成功").count, 1)
        XCTAssertTrue(app.buttons["B 合入"].exists)
        XCTAssertFalse(app.buttons["A 丢弃"].exists)
        capture(app, "真实匹配回执终态只属于A")
    }

    func testNativeReviewSameBranchKeepsTwoMachinesAndWritesOneTarget() throws {
        let app = try setup()
        for (machine, label) in [(machines[0].0, "A"), (machines[1].0, "B")] {
            try write([["repo": "/tmp/isolated", "repoName": "独立验收", "branch": "same", "head": String(repeating: "1", count: 40),
                "platform": "codex", "subject": "原生 \(label) 的成果", "mergesCleanly": true]], "reviews/" + machine + ".json")
        }
        app.launch()
        XCTAssertTrue(app.staticTexts["2 份成果等你验收"].waitForExistence(timeout: 10))
        app.staticTexts["2 份成果等你验收"].tap()
        XCTAssertTrue(app.staticTexts["原生 A 的成果"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["原生 B 的成果"].exists)
        app.buttons.matching(identifier: "查看并决定").element(boundBy: 0).tap()
        if !app.buttons["通过并合入"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["通过并合入"].waitForExistence(timeout: 5))
        app.buttons["通过并合入"].tap()
        XCTAssertTrue(app.staticTexts.matching(identifier: "已写入，等待目标 Mac 确认").firstMatch.waitForExistence(timeout: 5))
        let payloads = try actions(); XCTAssertEqual(payloads.count, 1)
        XCTAssertTrue((payloads[0].1["id"] as? String)?.hasPrefix("machine:" + digest(machines[0].0) + ":review:merge:") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("verdicts").path))
        let second = app.buttons.matching(identifier: "查看并决定").firstMatch
        if !second.isHittable { app.swipeUp() }; second.tap()
        XCTAssertTrue(app.buttons["通过并合入"].waitForExistence(timeout: 5), "B仍能独立验收")
        capture(app, "原生双机同分支独立处理")
    }

    func testSamePlanIDOnlyMarksSelectedMachineReleased() throws {
        let app = try setup()
        for (machine, name) in machines {
            try write(["machineID": machine, "machineName": name, "generatedAt": now, "tasks": [], "tasksTruncated": false,
                "planned": [["id": "same-plan", "title": "独立计划 " + machine]]], "taskboards/" + machine + ".json")
        }
        app.launch()
        XCTAssertTrue(app.staticTexts["2 个计划等你放行"].waitForExistence(timeout: 10))
        app.staticTexts["2 个计划等你放行"].tap()
        XCTAssertEqual(app.buttons.matching(identifier: "放行").count, 2)
        app.buttons.matching(identifier: "放行").element(boundBy: 0).tap()
        let pending = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "plan-pending-"))
        XCTAssertTrue(pending.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(pending.firstMatch.label.hasPrefix("已发出，等待目标 Mac 确认"))
        XCTAssertEqual(pending.count, 1); XCTAssertEqual(app.buttons.matching(identifier: "放行").count, 1)
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("config-intents"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(files.count, 1)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: files[0])) as? [String: Any])
        XCTAssertEqual(payload["targetMachineID"] as? String, machines[0].0)
        XCTAssertEqual(payload["planID"] as? String, "same-plan")
        capture(app, "计划同ID仅选中机器已发出")
    }

    func testOfficeSamePlatformOpensAndAnswersSelectedMachineQuestion() throws {
        let app = try setup(office: true)
        for (machine, _) in machines {
            try write(["id": "question-" + machine, "taskID": "same-task", "machineID": machine,
                "round": 1, "askedAt": now, "platform": "codex", "taskPrompt": "隔离审批 " + machine,
                "repoName": "isolated", "kind": "approval", "questions": [["id": "decision",
                    "text": "仅属于 " + machine + " 的审批问题", "options": ["放行并提交", "丢弃这次改动"]]]],
                "questions/" + machine + "/same-task.json")
        }
        app.launch()
        XCTAssertTrue(app.navigationTab("办公室").waitForExistence(timeout: 10)); app.navigationTab("办公室").tap()
        if app.windows.firstMatch.frame.width >= 960 {
            app.buttons.matching(identifier: "office-role-codex").element(boundBy: 1).tap()
        } else {
            let mini = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Mac mini")).firstMatch
            XCTAssertTrue(mini.waitForExistence(timeout: 5)); mini.tap()
            app.buttons.matching(identifier: "office-role-codex").firstMatch.tap()
        }
        XCTAssertTrue(app.staticTexts["仅属于 acceptance-b 的审批问题"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["仅属于 acceptance-a 的审批问题"].exists)
        capture(app, "同平台工位打开B机问题")
        app.buttons["放行并提交"].tap()
        XCTAssertTrue(app.alerts["决定已送达"].waitForExistence(timeout: 5))
        let answerFiles = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("answers/acceptance-b"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(answerFiles.count, 1)
        let path = try XCTUnwrap(answerFiles.first)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        XCTAssertEqual(payload["machineID"] as? String, "acceptance-b")
        XCTAssertEqual(payload["askID"] as? String, "question-acceptance-b")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("answers/acceptance-a").path))
    }
}

@MainActor
final class SmokeUITests: XCTestCase {
    func testNotificationColdLaunchOpensExactReadOnlyDetail() throws {
        let root = URL(fileURLWithPath: try moreFixture())
        let id = String(repeating: "a", count: 64)
        let dir = root.appendingPathComponent("notification-details")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let current = "review-" + id
        try Data("""
        {"id":"\(id)","createdAt":"2026-09-03T01:00:00Z","sourcePage":"\(current)","body":"M2 的新成果就绪","content":{"schema":1,"page":"review","generatedAt":"2026-09-03T01:00:00Z","sections":[{"kind":"cards","cards":[{"id":"m2-card","title":"M2 阶段成果","detail":"完整说明自动展开，不会被 Mac mini 覆盖","actions":[{"id":"stale-approve","label":"危险旧操作"}]}]}]}}
        """.utf8).write(to: dir.appendingPathComponent(id + ".json"))
        try Data("""
        {"schema":1,"page":"\(current)","generatedAt":"2026-09-03T01:00:00Z","sections":[{"kind":"text","text":"M2 当前事项，不是 Mac mini"}]}
        """.utf8).write(to: root.appendingPathComponent("views/\(current).json"))
        let app = XCUIApplication()
        app.launchEnvironment["LLMQ_FOLDER"] = root.path
        app.launchEnvironment["LLMQ_NOTIFICATION_JSON"] = """
        {"page":"review","notificationID":"\(id)","sourcePage":"\(current)","aps":{"alert":{"body":"M2 的新成果就绪"}}}
        """
        app.launch()
        XCTAssertTrue(app.staticTexts["完整说明自动展开，不会被 Mac mini 覆盖"].waitForExistence(timeout: 12))
        XCTAssertFalse(app.buttons["危险旧操作"].exists)
        app.buttons["notification-current"].tap()
        XCTAssertTrue(app.staticTexts["M2 当前事项，不是 Mac mini"].waitForExistence(timeout: 8))
    }

    func testNotificationMissingDownloadAndLegacyPayloadShowMessage() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LLMQ_FOLDER"] = try moreFixture()
        app.launchEnvironment["LLMQ_NOTIFICATION_JSON"] = """
        {"page":"roadmap","notificationID":"\(String(repeating: "b", count: 64))","aps":{"alert":{"body":"任务进度提醒，正文不能丢"}}}
        """
        app.launch()
        XCTAssertTrue(app.staticTexts["任务进度提醒，正文不能丢"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["notification-sync-status"].exists)
        XCTAssertTrue(app.buttons["重新加载详情"].exists)
        app.terminate()
        app.launchEnvironment["LLMQ_NOTIFICATION_JSON"] = #"{"aps":{"alert":{"body":"旧版无路由提醒，也能阅读"}}}"#
        app.launch()
        XCTAssertTrue(app.staticTexts["旧版无路由提醒，也能阅读"].waitForExistence(timeout: 10))
    }

    func testConsultationFailureNotificationOpensCollaborationPage() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LLMQ_FOLDER"] = try collaborationFixture()
        app.launchEnvironment["LLMQ_NOTIFICATION_JSON"] = """
        {"page":"collaboration","sourcePage":"collaboration","aps":{"alert":{"body":"Agent 协作中断：咨询执行失败"}}}
        """
        app.launch()

        XCTAssertTrue(app.staticTexts["Agent 协作中断：咨询执行失败"]
            .waitForExistence(timeout: 10))
        app.buttons["notification-current"].tap()
        XCTAssertTrue(app.navigationBars["Agent 协作"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["opencode.openrouter.code → claude-runner"]
            .waitForExistence(timeout: 5))
    }

    private func moreFixture() throws -> String {
        let root = URL(fileURLWithPath: "/tmp/llmq-more-ui-fixture", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter().string(from: Date())
        try Data("""
        {"generatedAt":"\(now)","machines":[{"machineID":"mini","machineName":"测试 Mac mini","lastSeen":"\(now)","isStale":false}],"reports":[]}
        """.utf8).write(to: root.appendingPathComponent("dashboard.json"), options: .atomic)

        let outbox = root.appendingPathComponent("outbox", isDirectory: true)
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        try Data("""
        {"taskID":"task-more","state":"done","note":"单元测试和真机烟测通过","prompt":"精简移动端更多页面","platform":"codex","branch":"agent/codex/task-more","changedFiles":4,"updatedAt":"\(now)"}
        """.utf8).write(to: outbox.appendingPathComponent("task-more.json"), options: .atomic)

        let boards = root.appendingPathComponent("taskboards", isDirectory: true)
        try FileManager.default.createDirectory(at: boards, withIntermediateDirectories: true)
        try Data("""
        {"machineID":"mini","machineName":"测试 Mac mini","generatedAt":"\(now)","planned":[{"id":"plan-1","title":"补齐派活回执","repoAlias":"LLMQuotaApp"}],"tasks":[],"tasksTruncated":false}
        """.utf8).write(to: boards.appendingPathComponent("mini.json"), options: .atomic)

        let views = root.appendingPathComponent("views", isDirectory: true)
        try FileManager.default.createDirectory(at: views, withIntermediateDirectories: true)
        try Data("""
        {"schema":1,"generatedAt":"\(now)","entries":[{"page":"roadmap","title":"计划进度","icon":"map","group":"项目"},{"page":"collaboration","title":"Agent 协作","icon":"person.2","group":"团队"}]}
        """.utf8).write(to: views.appendingPathComponent("menu.json"), options: .atomic)
        try Data("""
        {"schema":1,"page":"roadmap","generatedAt":"\(now)","sections":[{"kind":"text","title":"Flint","text":"功能 Alpha"}]}
        """.utf8).write(to: views.appendingPathComponent("roadmap.json"), options: .atomic)
        return root.path
    }

    private func officeFixture() throws -> String {
        let root = URL(fileURLWithPath: "/tmp/llmq-office-ui-fixture", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter().string(from: Date())
        let dashboard = """
        {"generatedAt":"\(now)","machines":[{"machineID":"book","machineName":"测试 MacBook","lastSeen":"\(now)","isStale":false},{"machineID":"mini","machineName":"测试 Mac mini","lastSeen":"\(now)","isStale":false}],"reports":[{"platform":"claude","agentName":"Claude","detected":true,"installed":true,"machines":["测试 MacBook"],"last30dRequests":20,"role":{"platform":"claude","title":"架构师","maxRisk":"sensitive","maxTier":"complex","prefers":["complex"],"note":"负责架构决策"}},{"platform":"codex","agentName":"Codex","detected":true,"installed":true,"machines":["测试 MacBook"],"last30dRequests":10},{"platform":"kimi","agentName":"Kimi","detected":true,"installed":true,"machines":["测试 Mac mini"],"last30dRequests":8,"statuses":[{"platform":"kimi","limitID":"weekly","label":"周额度","metric":"percent","used":100,"usedFraction":1,"health":"exhausted","isOfficial":true,"sourceNote":""}]},{"platform":"qwen","agentName":"Qwen","detected":true,"installed":true,"machines":["测试 Mac mini"],"last30dRequests":6,"statuses":[{"platform":"qwen","limitID":"weekly","label":"周额度","metric":"percent","used":2,"usedFraction":0.02,"projectedUsedFraction":0.02,"projectedWaste":98,"health":"wasting","isOfficial":true,"sourceNote":""}]}],"tasks":[{"id":"ipad-dashboard","title":"优化 iPad 团队控制台","state":"running","platform":"codex","machineName":"测试 MacBook","progressPhase":"移动端验收","progressSummary":"横屏团队视图已经生成","progressNextStep":"检查真机布局","progressUpdatedAt":"\(now)","progressEvidenceCount":1}],"tasksTruncated":false}
        """
        try Data(dashboard.utf8)
            .write(to: root.appendingPathComponent("dashboard.json"), options: .atomic)
        return root.path
    }

    private func approvalFixture() throws -> String {
        let root = URL(fileURLWithPath: "/tmp/llmq-approval-ui-fixture", isDirectory: true)
        let questions = root.appendingPathComponent("questions/machine-1", isDirectory: true)
        try FileManager.default.createDirectory(at: questions, withIntermediateDirectories: true)
        try Data(#"{"generatedAt":"2026-08-24T00:30:00Z","machines":[{"machineID":"machine-1","machineName":"测试 Mac mini","lastSeen":"2026-08-24T00:30:00Z","isStale":false}],"reports":[]}"#.utf8)
            .write(to: root.appendingPathComponent("dashboard.json"), options: .atomic)
        try Data(#"{"id":"approval-1","taskID":"task-1","machineID":"machine-1","round":1,"askedAt":"2026-08-24T00:29:00Z","platform":"codex","taskPrompt":"调整发布脚本并更新签名配置","repoName":"LLMQuotaBar","questions":[{"id":"decision","text":"这次改动碰到了高危路径，要放行吗？\nTools/release.sh\nExportOptions.plist","options":["放行并提交","丢弃这次改动"]}],"progressNote":"改了 2 个文件，工作区改动尚未提交","kind":"approval"}"#.utf8)
            .write(to: questions.appendingPathComponent("approval-1.json"), options: .atomic)
        return root.path
    }

    private func boardFixture() throws -> String {
        let root = URL(fileURLWithPath: "/tmp/llmq-board-ui-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dashboardTemplate = #"{"generatedAt":"2026-08-24T00:30:00Z","machines":[{"machineID":"mini","machineName":"测试 Mac mini","lastSeen":"2026-08-24T00:30:00Z","isStale":false}],"reports":[{"platform":"claude","agentName":"Claude","detected":true,"installed":true,"statuses":[{"platform":"claude","limitID":"weekly","label":"周额度","metric":"percent","used":10,"usedFraction":0.1,"projectedUsedFraction":0.2,"projectedWaste":80,"health":"wasting","isOfficial":true,"sourceNote":""}]},{"platform":"codex","agentName":"Codex","detected":true,"installed":true,"statuses":[{"platform":"codex","limitID":"weekly","label":"周额度","metric":"percent","used":95,"usedFraction":0.95,"health":"atRisk","isOfficial":true,"sourceNote":""}]},{"platform":"kimi","agentName":"Kimi","detected":true,"installed":true,"statuses":[{"platform":"kimi","limitID":"weekly","label":"周额度","metric":"requests","used":0,"health":"idle","isOfficial":true,"sourceNote":""}]},{"platform":"qwen","agentName":"Qwen","detected":true,"installed":true,"statuses":[{"platform":"qwen","limitID":"weekly","label":"周额度","metric":"requests","used":20,"health":"healthy","isOfficial":true,"sourceNote":""}]},{"platform":"gemini","agentName":"Gemini","detected":true,"installed":true,"statuses":[{"platform":"gemini","limitID":"weekly","label":"周额度","metric":"requests","used":10,"health":"healthy","isOfficial":true,"sourceNote":""}]}],"tasks":[{"id":"running","title":"优化移动端看板","state":"running","platform":"codex","machineName":"测试 Mac mini","progressPhase":"模拟器验收","progressSummary":"18 项移动端测试已通过","progressNextStep":"连接 iPad 检查布局","progressUpdatedAt":"2026-08-24T00:29:00Z","progressEvidenceCount":2},{"id":"blocked","title":"等待签名确认","state":"blocked","platform":"claude","machineName":"测试 Mac mini"}],"tasksTruncated":false}"#
        let fresh = ISO8601DateFormatter().string(from: Date())
        let dashboard = dashboardTemplate
            .replacingOccurrences(of: "2026-08-24T00:30:00Z", with: fresh)
            .replacingOccurrences(of: "2026-08-24T00:29:00Z", with: fresh)
        try Data(dashboard.utf8)
            .write(to: root.appendingPathComponent("dashboard.json"), options: .atomic)
        return root.path
    }

    private func productionGateFixture() throws -> String {
        let root = URL(fileURLWithPath: "/tmp/llmq-production-gate-ui-fixture",
                       isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter().string(from: Date())
        let dashboard = """
        {"generatedAt":"\(now)","machines":[{"machineID":"mini","machineName":"测试 Mac mini","lastSeen":"\(now)","isStale":false}],"reports":[],"tasks":[{"id":"fanout","title":"按样板生产第二只僵尸","state":"blocked","platform":"kimi","machineName":"测试 Mac mini","progressPhase":"批量扩张","progressSummary":"扩张自样板 zombie-v1 · zombie-character","progressNextStep":"黄金样板尚未合入主线","productionStage":"fanOut","deliverableKind":"zombie-character","productionBlockedReason":"黄金样板尚未合入主线"}],"tasksTruncated":false}
        """
        try Data(dashboard.utf8)
            .write(to: root.appendingPathComponent("dashboard.json"), options: .atomic)
        return root.path
    }
    /// 协作夹具：views/collaboration.json 严格按 Mac 端 ViewFeed.collaborationPage
    /// 的线格式 —— 一条待回应（warn）、一条已交付（good，带证据文件名）。
    private func collaborationFixture() throws -> String {
        let root = URL(fileURLWithPath: "/tmp/llmq-collab-ui-fixture", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter().string(from: Date())
        try Data("""
        {"generatedAt":"\(now)","machines":[{"machineID":"mini","machineName":"测试 Mac mini","lastSeen":"\(now)","isStale":false}],"reports":[]}
        """.utf8)
            .write(to: root.appendingPathComponent("dashboard.json"), options: .atomic)
        let views = root.appendingPathComponent("views", isDirectory: true)
        try FileManager.default.createDirectory(at: views, withIntermediateDirectories: true)
        try Data("""
        {"schema":1,"page":"collaboration","generatedAt":"\(now)","sections":[\
        {"kind":"facts","title":"协作状态","facts":[\
        {"key":"待回应","value":"1","tone":"warn"},\
        {"key":"最近记录","value":"2","tone":"neutral"}]},\
        {"kind":"cards","title":"最近动态","note":"只显示 Agent 主动留下的结论、问题、证据和交接",\
        "cards":[\
        {"id":"e1","title":"移动端首屏分阶段提交已经钉住",\
        "body":"opencode.openrouter.code → claude-runner",\
        "detail":"分支：agent/openrouter/ff763a1f\\n提交：51b7cfe\\n材料：StagedRefreshTests.swift",\
        "tone":"warn","icon":"bubble.left.and.exclamationmark.bubble.right",\
        "trailing":"LLMQuotaApp","eventKind":"question","taskID":"4b23aed9"},\
        {"id":"e2","title":"基线单测 21 条全部通过",\
        "body":"opencode.openrouter.code · 项目广播",\
        "tone":"good","icon":"arrow.triangle.branch",\
        "trailing":"LLMQuotaBar","images":["shot.png"],\
        "eventKind":"answer","replyTo":"e1","taskID":"4b23aed9"}]}]}
        """.utf8)
            .write(to: views.appendingPathComponent("collaboration.json"), options: .atomic)
        return root.path
    }

    /// 老服务端夹具：连 views/ 目录都没有 —— 协作入口必须在，
    /// 内容必须诚实说「还没有」。
    private func legacyCollaborationFixture() throws -> String {
        let root = URL(fileURLWithPath: "/tmp/llmq-legacy-collab-ui-fixture",
                       isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter().string(from: Date())
        try Data("""
        {"generatedAt":"\(now)","machines":[{"machineID":"mini","machineName":"测试 Mac mini","lastSeen":"\(now)","isStale":false}],"reports":[]}
        """.utf8)
            .write(to: root.appendingPathComponent("dashboard.json"), options: .atomic)
        return root.path
    }

    @MainActor
    func testBoardShowsAgentCollaborationEntryAndTimelineOnPhone() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LLMQ_FOLDER"] = try collaborationFixture()
        app.launch()
        app.navigationTab("看板").tap()

        XCTAssertTrue(app.staticTexts["Agent 协作"].waitForExistence(timeout: 8),
                      "看板上必须有一级协作入口，不能再埋进「更多」")
        let entry = app.buttons["board-collaboration-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()

        XCTAssertTrue(app.navigationBars["Agent 协作"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[
            "opencode.openrouter.code → claude-runner"].waitForExistence(timeout: 5),
            "时间线要能看出谁发给谁")
        XCTAssertTrue(app.staticTexts["待回应"].exists, "pending 必须显式标出")
        XCTAssertTrue(app.staticTexts["LLMQuotaApp"].exists, "项目要可辨识")
        XCTAssertTrue(app.staticTexts["任务 4b23aed9"].exists, "任务归属必须在手机上可见")
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "回应提问：移动端首屏")
        ).firstMatch.exists, "回复关系必须独占一行，不能和项目标签挤在一起")

        // 详情和证据按需展开，不在首屏读媒体。detail 是多行文本，
        // 可访问性标签是整串，所以按包含匹配。
        let branchEvidence = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "agent/openrouter/ff763a1f")
        ).firstMatch
        app.buttons["展开协作详情-e1"].tap()
        XCTAssertTrue(branchEvidence.waitForExistence(timeout: 5),
                      "证据引用在展开的详情里")
    }

    @MainActor
    func testLegacyServerKeepsEntryWithHonestEmptyState() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LLMQ_FOLDER"] = try legacyCollaborationFixture()
        app.launch()
        app.navigationTab("看板").tap()

        XCTAssertTrue(app.staticTexts["Agent 协作"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["电脑还没有同步协作记录"].waitForExistence(timeout: 3),
                      "老服务端不下发这一页时要说实话，不能装作没有这个功能")
        app.buttons["board-collaboration-entry"].tap()
        XCTAssertTrue(app.navigationBars["Agent 协作"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Mac 端还没有发来 Agent 协作记录"]
            .waitForExistence(timeout: 3))
    }

    @MainActor
    func testConversationShowsFullQuestionAnswerAndFeedbackBeforeAgentRoster() throws {
        let root = try collaborationFixture()
        let url = URL(fileURLWithPath: root).appendingPathComponent("views/collaboration.json")
        var page = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let detail = "提问 · Kimi → Codex\n为何单测通过却不能完成首波？\n\n回复 · Codex → Kimi\n验证真实操作链，不要用理想命中率代替试玩。\n\n确认反馈 · Kimi → Codex\n部分采用：保留控制方案，补实际命中与补给验证。"
        page["sections"] = [
            ["kind": "facts", "title": "协作状态", "facts": [
                ["key": "Agent 互问", "value": "1/1"], ["key": "待回应", "value": "0"]]],
            ["kind": "cards", "title": "交互关系", "cards": [
                ["id": "conv-q", "title": "Kimi ⇄ Codex｜问题 · 首波无法完成", "eventKind": "conversation",
                 "body": "提问　Kimi → Codex\n回复　Codex → Kimi\n确认　Kimi → Codex\n采用反馈　Kimi 已确认（见详情）",
                 "detail": detail, "trailing": "Flint", "taskID": "flint-task"]]],
            ["kind": "cards", "title": "可用 Agent", "cards": (0..<17).map {
                ["id": "agent-\($0)", "title": "名录占位 \($0)", "body": "测试设备", "eventKind": "agent", "trailing": "今天 10:00"] }],
        ]
        try JSONSerialization.data(withJSONObject: page).write(to: url, options: .atomic)
        let app = XCUIApplication()
        app.launchEnvironment["LLMQ_FOLDER"] = root
        app.launch()
        app.navigationTab("看板").tap()
        let entry = app.buttons["board-collaboration-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        entry.tap()
        XCTAssertTrue(app.staticTexts["1/1"].waitForExistence(timeout: 5))
        let expand = app.buttons["展开协作详情-conv-q"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        XCTAssertTrue(expand.isHittable, "问答必须在首屏可展开，不能被 17 个 Agent 名录挤掉")
        XCTAssertFalse(app.staticTexts["名录占位 0"].exists, "名录默认折叠")
        expand.tap()
        XCTAssertTrue(app.staticTexts[detail].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Agent 问答全文与采用反馈"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testIPadRailCollaborationOpensTimeline() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }

        let app = XCUIApplication()
        app.launchEnvironment["LLMQ_FOLDER"] = try collaborationFixture()
        app.launch()
        let officeTab = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "办公室")).firstMatch
        XCTAssertTrue(officeTab.waitForExistence(timeout: 8))
        officeTab.tap()

        guard app.windows.firstMatch.frame.width >= 960 else {
            throw XCTSkip("需要宽度至少 960pt 的 iPad 横屏窗口")
        }
        XCTAssertTrue(app.descendants(matching: .any)["office-ipad-dashboard"]
            .waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Agent 协作"].exists,
                      "iPad 控制台保留协作摘要")
        let link = app.buttons["rail-collaboration-link"]
        XCTAssertTrue(link.waitForExistence(timeout: 3),
                      "iPad 摘要必须能一键进入完整时间线")
        link.tap()
        XCTAssertTrue(app.navigationBars["Agent 协作"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[
            "opencode.openrouter.code → claude-runner"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testMainTabsAndReviewEmptyState() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["LLMQ_FOLDER"] = try moreFixture()
        app.launch()

        XCTAssertTrue(app.navigationTab("现在").waitForExistence(timeout: 8))
        // 空 fixture 可能被归为“已发布但当前无事”或“尚未发布”；两种都不能
        // 编造一条正在运行的任务。烟测只固定这条诚实边界和页面可导航性。
        XCTAssertTrue(app.navigationBars["现在"].waitForExistence(timeout: 5))
        let fabricatedRunning = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "正在干：")).firstMatch
        XCTAssertFalse(fabricatedRunning.exists)
        XCTAssertTrue(app.staticTexts["1 个计划等你放行"].waitForExistence(timeout: 5),
                      "计划只在确有待放行内容时出现在“现在”")

        app.navigationTab("办公室").tap()
        XCTAssertTrue(app.navigationBars["办公室"].waitForExistence(timeout: 5))

        app.navigationTab("更多").tap()
        XCTAssertTrue(app.navigationBars["更多"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["常用"].exists)
        XCTAssertTrue(app.staticTexts["额度与用量"].exists)
        XCTAssertTrue(app.staticTexts["任务记录"].exists)
        XCTAssertTrue(app.staticTexts["派新任务"].exists)
        XCTAssertTrue(app.staticTexts["设置"].exists)
        XCTAssertFalse(app.staticTexts["计划清单"].exists)
        XCTAssertFalse(app.staticTexts["全部问题"].exists)
        XCTAssertFalse(app.staticTexts["项目清单"].exists)
        XCTAssertFalse(app.staticTexts["调度留白"].exists)
        XCTAssertFalse(app.staticTexts["计划进度"].exists)
        XCTAssertFalse(app.staticTexts["Agent 协作"].exists)
        XCTAssertTrue(app.staticTexts["成果复核"].exists,
                      "成果推送必须有稳定入口，不能只依赖一次性通知")
        XCTAssertFalse(app.staticTexts["等你验收"].exists,
                       "旧的重复入口不应复活")

        // iOS 26 exposes the row as a Button with a nested StaticText. Tapping
        // the text can be acknowledged by XCTest without activating the link.
        app.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Agent 可用额度"].exists)
        XCTAssertTrue(app.staticTexts["连接"].exists)
        XCTAssertTrue(app.staticTexts["通知"].exists)

        app.navigationBars.buttons["更多"].tap()
        app.staticTexts["任务记录"].tap()
        XCTAssertTrue(app.navigationBars["任务"].waitForExistence(timeout: 5))
        app.staticTexts["精简移动端更多页面"].tap()
        XCTAssertTrue(app.navigationBars["任务详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "agent/codex/task-more")
        ).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["单元测试和真机烟测通过"].exists)
    }

    @MainActor
    func testHighRiskApprovalHasExplicitDecisions() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LLMQ_FOLDER"] = try approvalFixture()
        app.launch()

        let card = app.staticTexts["Codex 有高危改动等你决定 · Mac mini · MACH"]
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        card.tap()

        XCTAssertTrue(app.buttons["放行并提交"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["丢弃这次改动"].exists)
        XCTAssertTrue(app.staticTexts["为什么被拦下"].exists)

        app.buttons["丢弃这次改动"].tap()
        XCTAssertTrue(app.buttons["确认丢弃"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testOfficeFocusesOneMachineOnPhone() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LLMQ_FOLDER"] = try officeFixture()
        app.launch()
        // iOS 26 的标签栏在不同设备上会暴露成 Button、Cell 或 Other。
        // 按可访问名称定位，避免把 UIKit 内部类型当成产品契约。
        let officeTab = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "办公室")).firstMatch
        XCTAssertTrue(officeTab.waitForExistence(timeout: 8))
        officeTab.tap()

        guard app.windows.firstMatch.frame.width < 600 else {
            throw XCTSkip("这是手机单机聚焦测试；iPad 由大屏控制台用例覆盖")
        }

        XCTAssertTrue(app.buttons["office-role-claude"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["office-role-codex"].exists)
        XCTAssertFalse(app.buttons["office-role-kimi"].exists,
                       "手机首屏不应同时挤入另一台机器的全部工位")

        let mini = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Mac mini · MINI")).firstMatch
        XCTAssertTrue(mini.exists)
        mini.tap()
        XCTAssertTrue(app.buttons["office-role-kimi"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["office-role-qwen"].exists)
        XCTAssertFalse(app.buttons["office-role-claude"].exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "office-phone-two-columns"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testOfficeShowsTeamDashboardOnWideIPad() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }

        let app = XCUIApplication()
        app.launchEnvironment["LLMQ_FOLDER"] = try officeFixture()
        app.launch()
        let officeTab = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "办公室")).firstMatch
        XCTAssertTrue(officeTab.waitForExistence(timeout: 8))
        officeTab.tap()

        guard app.windows.firstMatch.frame.width >= 960 else {
            throw XCTSkip("需要宽度至少 960pt 的 iPad 横屏窗口")
        }

        let dashboard = app.descendants(matching: .any)["office-ipad-dashboard"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["团队控制台"].exists)
        XCTAssertTrue(app.staticTexts["任务"].exists)
        XCTAssertTrue(app.staticTexts["额度风险"].exists)
        XCTAssertTrue(app.staticTexts["Agent 协作"].exists)
        XCTAssertTrue(app.staticTexts["移动端验收 · 横屏团队视图已经生成"].exists)
        XCTAssertTrue(app.buttons["office-role-claude"].exists)
        XCTAssertTrue(app.buttons["office-role-kimi"].exists,
                      "iPad 横屏应同时展示两台机器，不需要逐台切换")

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "office-ipad-team-dashboard"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testBoardPrioritizesSummaryAndCapsQuotaPreview() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LLMQ_FOLDER"] = try boardFixture()
        app.launch()
        app.navigationTab("现在").tap()
        XCTAssertTrue(app.staticTexts["模拟器验收 · 18 项移动端测试已通过"]
            .waitForExistence(timeout: 8),
            "长任务的最新里程碑必须在『现在』首屏显示，不能只让耗时数字自己增长")
        app.navigationTab("看板").tap()

        XCTAssertTrue(app.navigationBars["看板"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["现在"].exists)
        XCTAssertTrue(app.staticTexts["最需要关注的额度"].exists)
        XCTAssertTrue(app.staticTexts["查看全部 5 个额度窗口"].exists)
        XCTAssertFalse(app.staticTexts["Gemini"].exists,
                       "手机首屏只预览最值得关注的四个额度窗口")

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "board-phone-priority"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testGoldenSampleGateReasonIsVisibleWithoutANewClientSchema() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LLMQ_FOLDER"] = try productionGateFixture()
        app.launch()

        XCTAssertTrue(app.staticTexts["批量扩张 · 扩张自样板 zombie-v1 · zombie-character"]
            .waitForExistence(timeout: 8),
            "被挡住的批量任务必须说明所处阶段，不能只显示一个 blocked 状态")
        XCTAssertTrue(app.staticTexts["下一步：黄金样板尚未合入主线"].exists,
                      "手机必须显示真实阻断原因，避免用户以为任务没有动静")

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "golden-sample-gate-visible"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testRoleCanBeEditedFromOfficeWithoutOverwritingProtectedFields() throws {
        XCUIDevice.shared.orientation = .portrait
        let root = try officeFixture()
        let app = XCUIApplication()
        app.launchEnvironment["LLMQ_FOLDER"] = root
        app.launch()
        app.navigationTab("办公室").tap()

        let claude = app.buttons["office-role-claude"]
        XCTAssertTrue(claude.waitForExistence(timeout: 8))
        claude.tap()
        XCTAssertTrue(app.buttons["调整岗位规则"].waitForExistence(timeout: 5))
        app.buttons["调整岗位规则"].tap()

        let title = app.textFields["role-title-field"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(title.isHittable)
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2) {
            title.tap()
        }
        title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20))
        title.typeText("首席架构师")
        app.buttons["提交修改"].tap()
        XCTAssertTrue(app.buttons["已送达 Mac"].waitForExistence(timeout: 5))

        let dir = URL(fileURLWithPath: root).appendingPathComponent("config-intents")
        let files = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        XCTAssertEqual(files.count, 1)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: try XCTUnwrap(files.first)))
                as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "role")
        XCTAssertEqual(object["title"] as? String, "首席架构师")
        XCTAssertEqual(object["prefers"] as? [String], ["complex"])
        XCTAssertNil(object["dispatcherOn"], "手机不应发送指挥身份字段")
        XCTAssertNil(object["mutedOn"], "手机不应发送机器静音字段")
    }
}

/// 独立验收补测。所有数据只写隔离的 /tmp 虚拟目录，绝不连接真实 iCloud。
@MainActor
final class MobileAcceptanceUITests: XCTestCase {
    private let sourceA = "review-" + String(repeating: "c", count: 64)
    private let sourceB = "review-" + String(repeating: "d", count: 64)

    private func write(_ object: [String: Any], to path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: url, options: .atomic)
    }

    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp/llmq-independent-virtual-" + UUID().uuidString)
        let now = ISO8601DateFormatter().string(from: Date())
        try write(["generatedAt": now, "machines": [
            ["machineID": "virtual-a", "machineName": "独立验收虚拟 MacBook Pro",
             "lastSeen": now, "isStale": false],
            ["machineID": "virtual-b", "machineName": "独立验收虚拟 Mac mini",
             "lastSeen": now, "isStale": false]], "reports": []],
                  to: "dashboard.json", in: root)
        return root
    }

    private func page(_ name: String, sections: [[String: Any]], stale: Bool = false) -> [String: Any] {
        ["schema": 1, "page": name,
         "generatedAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(stale ? -3600 : 0)),
         "sections": sections]
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "独立验收虚拟数据-" + name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testNotificationRetryRestoresSnapshotAndKeepsStaleSourceReadOnly() throws {
        let root = try fixture()
        let id = String(repeating: "e", count: 64)
        try write(page(sourceA, sections: [["kind": "cards", "title": "虚拟 A 来源", "cards": [
            ["id": "same-card", "title": "虚拟 A 当前过期事项", "detail": "只属于虚拟 A 的当前全文",
             "actions": [["id": "stale-approve", "label": "不应出现的过期合入"]]]]]], stale: true),
                  to: "views/\(sourceA).json", in: root)
        try write(page(sourceB, sections: [["kind": "cards", "title": "虚拟 B 来源", "cards": [
            ["id": "same-card", "title": "虚拟 B 不应串入此通知"]]]]),
                  to: "views/\(sourceB).json", in: root)
        let app = XCUIApplication()
        app.launchEnvironment["LLMQ_FOLDER"] = root.path
        let payload: [String: Any] = ["page": "review", "sourcePage": sourceA, "notificationID": id,
                                     "aps": ["alert": ["body": "独立验收虚拟提醒：A 正文保留"]]]
        app.launchEnvironment["LLMQ_NOTIFICATION_JSON"] = String(
            decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        app.launch()
        XCTAssertTrue(app.staticTexts["独立验收虚拟提醒：A 正文保留"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["notification-sync-status"].exists)
        capture(app, "通知未下载保留正文")

        let fullText = "独立验收虚拟快照全文\n原题与完整结论仍然保留。\n证据引用：virtual-proof.txt"
        let snapshot: [String: Any] = ["id": id, "createdAt": "2026-09-03T01:00:00Z",
            "sourcePage": sourceA, "body": "独立验收虚拟提醒：A 正文保留",
            "content": page("review", sections: [["kind": "cards", "title": "虚拟发送快照", "cards": [
                ["id": "historic-card", "title": "虚拟历史内容", "detail": fullText,
                 "actions": [["id": "historic-approve", "label": "不应出现的历史合入"]]]]]])]
        try write(snapshot, to: "notification-details/\(id).json", in: root)
        app.buttons["重新加载详情"].tap()
        XCTAssertTrue(app.staticTexts[fullText].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["notification-sync-status"].exists)
        XCTAssertFalse(app.buttons["不应出现的历史合入"].exists)
        capture(app, "通知重试恢复全文历史只读")
        app.buttons["notification-current"].tap()
        XCTAssertTrue(app.staticTexts["虚拟 A 当前过期事项"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["虚拟 B 不应串入此通知"].exists)
        XCTAssertTrue(app.staticTexts["此来源采样已过期，暂时只读。"].exists)
        app.buttons["看详情"].tap()
        XCTAssertTrue(app.staticTexts["只属于虚拟 A 的当前全文"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["不应出现的过期合入"].exists)
        capture(app, "通知来源当前页过期只读")
    }

    @MainActor
    func testMoreReviewOpensBothMachinesWithoutSharedCardExpansion() throws {
        let root = try fixture()
        for (name, label) in [(sourceA, "A"), (sourceB, "B")] {
            try write(page(name, sections: [["kind": "cards", "title": "虚拟 \(label) 来源", "cards": [
                ["id": "same-card", "title": "虚拟 \(label) 的成果", "detail": "虚拟 \(label) 独立全文",
                 "actions": [["id": "virtual-shared-action", "label": "虚拟 \(label) 确认"]]]]]]),
                      to: "views/\(name).json", in: root)
        }
        try write(page("review", sections: [["kind": "text", "text": "旧共享页不能遮掉分机成果"]]),
                  to: "views/review.json", in: root)
        let app = XCUIApplication()
        app.launchEnvironment["LLMQ_FOLDER"] = root.path
        app.launch()
        XCTAssertTrue(app.navigationTab("更多").waitForExistence(timeout: 8))
        app.navigationTab("更多").tap()
        app.staticTexts["成果复核"].tap()
        XCTAssertTrue(app.buttons["查看完整复核内容"].waitForExistence(timeout: 5))
        app.buttons["查看完整复核内容"].tap()
        XCTAssertTrue(app.staticTexts["虚拟 A 的成果"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["虚拟 B 的成果"].exists)
        XCTAssertFalse(app.staticTexts["旧共享页不能遮掉分机成果"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "看详情").count, 2)
        app.buttons.matching(identifier: "看详情").element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["虚拟 A 独立全文"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["虚拟 B 独立全文"].exists, "同名卡片展开不能串到另一台机器")
        capture(app, "两机同卡ID独立展开")
        app.buttons["看详情"].tap()
        XCTAssertTrue(app.staticTexts["虚拟 B 独立全文"].waitForExistence(timeout: 3))
        app.buttons["虚拟 A 确认"].tap()
        XCTAssertTrue(app.staticTexts.matching(identifier: "已写入，等待目标 Mac 确认").firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["目标 Mac 已执行成功"].exists,
                       "只有本地写入，不能显示 Mac 已执行成功")
        let actionFiles = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("actions"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(actionFiles.count, 1, "只点击一次虚拟 A，隔离目录只能收到一条动作")
        for file in actionFiles {
            let payload = XCTAttachment(string: String(decoding: try Data(contentsOf: file), as: UTF8.self))
            payload.name = "独立验收虚拟动作回写.json"
            payload.lifetime = .keepAlways
            add(payload)
        }
        capture(app, "同ID动作回执应只属于被点击来源")
        XCTAssertTrue(app.buttons["虚拟 B 确认"].exists,
                      "只点击 A 后，B 的同 ID 动作不能被误标为已送达")
        app.navigationBars.buttons["成果确认与进展"].tap()
        XCTAssertTrue(app.buttons["查看完整复核内容"].waitForExistence(timeout: 3))
        app.navigationBars.buttons["更多"].tap()
        XCTAssertTrue(app.staticTexts["额度与用量"].waitForExistence(timeout: 3))
        app.navigationTab("现在").tap()
        XCTAssertTrue(app.navigationBars["现在"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testRejectedFeedbackRosterAndProjectFilterRemainUsable() throws {
        let root = try fixture()
        let fullText = "提问 · 虚拟 Kimi → 虚拟 Codex\n是否直接采用未经试玩的方案？\n\n回复 · 虚拟 Codex → 虚拟 Kimi\n建议先比较实测结果。\n\n确认反馈 · 虚拟 Kimi → 虚拟 Codex\n拒绝：证据缺少真实操作验证，当前建议不予采用。"
        try write(page("collaboration", sections: [
            ["kind": "cards", "title": "交互关系", "cards": [
                ["id": "virtual-rejected", "title": "虚拟项目 A 的拒绝问答", "eventKind": "conversation",
                 "body": "虚拟 Kimi → 虚拟 Codex\n虚拟 Codex → 虚拟 Kimi\n确认：拒绝，理由见全文",
                 "detail": fullText, "trailing": "虚拟项目 A"],
                ["id": "virtual-chain", "title": "虚拟项目 B 的工作链", "eventKind": "chain",
                 "body": "虚拟设计 → 虚拟实现", "trailing": "虚拟项目 B"]]],
            ["kind": "cards", "title": "最近动作", "cards": [
                ["id": "virtual-ack", "title": "虚拟拒绝反馈已送达", "eventKind": "ack",
                 "body": "拒绝建议不等于已采纳", "trailing": "虚拟项目 A"]]],
            ["kind": "cards", "title": "可用 Agent", "cards": (0..<17).map {
                ["id": "virtual-agent-\($0)", "title": "独立虚拟名录 \($0)", "eventKind": "agent",
                 "body": "独立验收虚拟设备", "trailing": "不是项目的时间值"] }]
        ]), to: "views/collaboration.json", in: root)
        let app = XCUIApplication()
        app.launchEnvironment["LLMQ_FOLDER"] = root.path
        app.launch()
        app.navigationTab("看板").tap()
        XCTAssertTrue(app.buttons["board-collaboration-entry"].waitForExistence(timeout: 8))
        app.buttons["board-collaboration-entry"].tap()
        XCTAssertTrue(app.buttons["展开协作详情-virtual-rejected"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["展开协作详情-virtual-rejected"].isHittable)
        XCTAssertFalse(app.staticTexts["独立虚拟名录 0"].exists)
        app.buttons["展开协作详情-virtual-rejected"].tap()
        XCTAssertTrue(app.staticTexts[fullText].waitForExistence(timeout: 3))
        capture(app, "拒绝理由与问答全文")
        app.buttons["展开协作详情-virtual-rejected"].tap()
        XCTAssertTrue(app.staticTexts["确认反馈"].exists)
        XCTAssertFalse(app.staticTexts["已采纳"].exists)
        app.buttons["collab-project-filter"].tap()
        XCTAssertFalse(app.buttons["不是项目的时间值"].exists)
        app.buttons["虚拟项目 A"].tap()
        XCTAssertTrue(app.staticTexts["虚拟项目 A 的拒绝问答"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["虚拟项目 B 的工作链"].exists)
        let roster = app.buttons["可用 Agent · 17"]
        if !roster.isHittable { app.swipeUp() }
        XCTAssertTrue(roster.waitForExistence(timeout: 3))
        roster.tap()
        XCTAssertTrue(app.staticTexts["独立虚拟名录 0"].waitForExistence(timeout: 3))
        capture(app, "项目筛选后展开虚拟名录")
    }
}

/// 本批办公室趣味动作的独立端到端夹具；无真实任务或服务写入。
@MainActor
final class IndependentOfficeLifeUITests: XCTestCase {
    private var root: URL!
    private var stamp: String { ISO8601DateFormatter().string(from: Date()) }
    private func write(_ value: Any, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .atomic)
    }
    private func setup(platforms: [String] = ["codex", "kimi"], twoMachines: Bool = false) throws -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        root = URL(fileURLWithPath: "/tmp/llmq-office-life-ui-" + UUID().uuidString)
        let machines = twoMachines ? ["life-a", "life-b"] : ["life-a"]
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-4000))
        try write(["generatedAt": stamp, "machines": machines.map { id in
            ["machineID": id, "machineName": id == "life-a" ? "验收 MacBook Pro" : "验收 Mac mini", "lastSeen": stamp, "isStale": false] as [String: Any]
        }, "reports": platforms.enumerated().map { index, platform in
            ["platform": platform, "agentName": platform.capitalized, "detected": true, "installed": true,
             "machineIDs": machines, "machines": machines.map { $0 == "life-a" ? "验收 MacBook Pro" : "验收 Mac mini" },
             "lastActivity": old, "last30dRequests": 20 - index] as [String: Any]
        }], "dashboard.json")
        for id in machines { try board([], machine: id) }
        let app = XCUIApplication(); app.launchEnvironment["LLMQ_FOLDER"] = root.path
        return app
    }
    private func board(_ tasks: [[String: Any]], machine: String = "life-a") throws {
        try write(["machineID": machine, "machineName": machine, "generatedAt": stamp,
                   "tasks": tasks, "tasksTruncated": false], "taskboards/" + machine + ".json")
    }
    private func open(_ app: XCUIApplication) {
        app.launch(); XCTAssertTrue(app.navigationTab("办公室").waitForExistence(timeout: 10))
        app.navigationTab("办公室").tap()
    }
    private func expect(_ element: XCUIElement, _ value: String, timeout: Double = 6, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "value == %@", value)
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "Expected office state: \(value), actual: \(String(describing: element.value))", file: file, line: line)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "独立办公室生活感-" + name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func refresh(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        app.activate() // 使用应用真实的前台恢复刷新入口。
    }

    func testQuestionStaysVisibleAndClickAnswersExactMachine() throws {
        let app = try setup(platforms: ["codex"], twoMachines: true)
        try board([["id": "same", "state": "running", "platform": "codex", "title": "B独立工作"]], machine: "life-b")
        try write(["id": "life-question-a", "taskID": "same", "machineID": "life-a", "platform": "codex",
                   "round": 1, "askedAt": "2026-09-01T00:00:00Z", "kind": "approval", "taskPrompt": "A的问题",
                   "questions": [["id": "decision", "text": "只属于A的持久问号", "options": ["放行并提交", "丢弃这次改动"]]]],
                  "questions/life-a/same.json")
        open(app)
        let a = app.buttons.matching(identifier: "office-role-codex").element(boundBy: 0)
        expect(a, "有个问题想问你")
        if app.windows.firstMatch.frame.width >= 960 {
            expect(app.buttons.matching(identifier: "office-role-codex").element(boundBy: 1), "认真干活中")
        }
        capture(app, "问号与其他机器工作分开")
        a.tap()
        XCTAssertTrue(app.staticTexts["只属于A的持久问号"].waitForExistence(timeout: 5))
        app.buttons["放行并提交"].tap()
        XCTAssertTrue(app.alerts["决定已送达"].waitForExistence(timeout: 5))
        let answerDir = root.appendingPathComponent("answers/life-a")
        let answers = try FileManager.default.contentsOfDirectory(at: answerDir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        XCTAssertEqual(answers.count, 1)
        let data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: answers[0])) as? [String: Any])
        XCTAssertEqual(data["machineID"] as? String, "life-a"); XCTAssertEqual(data["askID"] as? String, "life-question-a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("answers/life-b").path))
    }

    func testFreshCompletionAfterRefreshCelebratesPromptlyAndOldHistoryDoesNotReplay() throws {
        let app = try setup()
        try board([["id": "working", "state": "running", "platform": "codex", "title": "隔离中的当前工作"]])
        open(app)
        expect(app.buttons["office-role-codex"], "认真干活中")
        expect(app.buttons["office-role-kimi"], "没活先躺一会儿")
        capture(app, "工作与横躺互不冒充")
        try board([["id": "working", "state": "done", "platform": "codex", "title": "隔离中的当前工作"]])
        try write([["id": "new-finished", "machineID": "life-a", "platform": "codex", "kind": "finished",
                    "at": stamp, "taskID": "working", "taskTitle": "隔离中的当前工作", "detail": "隔离交活"]], "office.json")
        refresh(app)
        expect(app.buttons["office-role-codex"], "交活啦！", timeout: 5)
        capture(app, "新完成及时举手庆祝")
        // 用真实过去时间替换持久事件，再重启；不能把历史当新交付重播。
        try write([["id": "new-finished", "machineID": "life-a", "platform": "codex", "kind": "finished",
                    "at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60)), "taskID": "working"]], "office.json")
        app.terminate(); open(app)
        expect(app.buttons["office-role-codex"], "随时可以开工")
        capture(app, "历史不重新庆祝")
    }

    func testFailedFinishedEventDoesNotCelebrateOrClaimDelivery() throws {
        let app = try setup(platforms: ["codex"])
        try board([["id": "failed-work", "state": "running", "platform": "codex", "title": "隔离失败任务"]])
        open(app)
        expect(app.buttons["office-role-codex"], "认真干活中")
        try board([["id": "failed-work", "state": "failed", "platform": "codex", "title": "隔离失败任务"]])
        try write([["id": "failed-finished", "machineID": "life-a", "platform": "codex", "kind": "finished", "at": stamp,
                    "taskID": "failed-work", "taskTitle": "隔离失败任务", "detail": "没干成"]], "office.json")
        refresh(app)
        expect(app.buttons["office-role-codex"], "这次没完成", timeout: 5)
        XCTAssertTrue(app.staticTexts["本轮未完成"].exists)
        XCTAssertFalse(app.staticTexts["交活"].exists, "失败的finished不能在字幕里冒充成功交活")
        capture(app, "失败结束不庆祝不交绿纸")
    }

    func testSharedRestStopsForTaskAndNewIdleDoesNotImmediatelySleep() throws {
        let app = try setup()
        open(app)
        let shared = app.descendants(matching: .any)["office-shared-break-life-a"]
        XCTAssertTrue(shared.waitForExistence(timeout: 125), "两人已闲一小时，应在实际两分钟节奏中一起休息")
        // 休息只占每两分钟的前 30 秒；慢速 CI 的 AX 查询可能在标签出现
        // 后跨过本轮窗口。等待下一轮员工状态，仍要求实际看到休息动作。
        let resting = NSPredicate(format: "value IN %@", ["一起伸个懒腰", "一起喝口水"])
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: resting, object: app.buttons["office-role-codex"]
        )], timeout: 125), .completed)
        capture(app, "两人一起休息")
        try board([["id": "new-work", "state": "running", "platform": "kimi", "title": "打断休息的新工作"]])
        refresh(app)
        expect(app.buttons["office-role-kimi"], "认真干活中")
        XCTAssertFalse(shared.exists)
        capture(app, "新工作立即打断休息")
        try board([])
        refresh(app)
        expect(app.buttons["office-role-kimi"], "随时可以开工")
        XCTAssertFalse(shared.exists, "刚结束工作必须重新累计空闲，不能借旧lastActivity马上集体休息")
        capture(app, "新一轮空闲重新计时")
        if app.windows.firstMatch.frame.width >= 960 {
            XCUIDevice.shared.orientation = .landscapeLeft
            capture(app, "横屏动作和控制台")
            XCUIDevice.shared.orientation = .portrait
        }
    }
}


/// 本批首页成果准备状态验收：只连接每个测试独有的临时目录。
@MainActor
final class IndependentReviewReadinessUITests: XCTestCase {
    private var root: URL!
    private let blocker = "质量契约要求先逐帧验收截图/录屏；当前还没有视觉结论。"
    private var stamp: String { ISO8601DateFormatter().string(from: Date()) }
    private func write(_ value: Any, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .atomic)
    }
    private func review(_ branch: String, blocked: Bool) -> [String: Any] {
        var result: [String: Any] = ["repo": "/tmp/readiness-only", "repoName": "隔离成果项目", "branch": branch,
            "head": "6ea0cee", "platform": "codex", "subject": blocked ? "需要视觉结论的隔离成果" : "已准备完成的隔离成果",
            "mergesCleanly": true, "files": ["View.swift"], "insertions": 4, "deletions": 2,
            "prompt": "隔离成果原始任务，只有满足质量门槛才能确认。"]
        if blocked { result["landingBlockReason"] = blocker }
        return result
    }
    private func setup() throws -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        root = URL(fileURLWithPath: "/tmp/llmq-review-ready-ui-" + UUID().uuidString)
        try write(["generatedAt": stamp, "machines": [["machineID": "ready-a", "machineName": "隔离 MacBook Pro", "lastSeen": stamp, "isStale": false]], "reports": []], "dashboard.json")
        let app = XCUIApplication(); app.launchEnvironment["LLMQ_FOLDER"] = root.path
        return app
    }
    private func capture(_ app: XCUIApplication, _ title: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "成果准备状态-" + title; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func refresh(_ app: XCUIApplication) { XCUIDevice.shared.press(.home); app.activate() }
    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 6))
        for _ in 0..<3 where !element.isHittable { app.swipeUp() }
        element.tap()
    }
    private func back(_ app: XCUIApplication) { app.navigationBars.buttons.element(boundBy: 0).tap() }
    private func actions() throws -> [(URL, [String: Any])] {
        let folder = root.appendingPathComponent("actions")
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { ($0, try JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as! [String: Any]) }
    }

    func testBlockedOnlyShowsProgressReasonAndRefreshRestoresRealConfirmation() throws {
        let app = try setup()
        try write([review("blocked", blocked: true)], "reviews/ready-a.json")
        app.launch()
        XCTAssertTrue(app.staticTexts["1 份保留成果，无需你确认"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["1 份成果等你验收"].exists)
        XCTAssertFalse(app.staticTexts["待我处理"].exists)
        XCTAssertFalse(app.staticTexts["下次这种事，要不要直接通知你？"].exists)
        XCTAssertTrue(app.staticTexts[blocker].exists)
        XCTAssertFalse(app.staticTexts["没有要你做的事"].exists,
                       "仍有来源 Mac 检查/处理要求时不能笼统宣称无事")
        XCTAssertTrue(app.staticTexts["当前没有需要你在手机上确认的事项"].exists)
        capture(app, "仅质量阻断-首页不催确认")
        tap(app.staticTexts["1 份保留成果，无需你确认"], in: app)
        XCTAssertTrue(app.staticTexts["保留成果，无需你确认"].waitForExistence(timeout: 5))
        tap(app.buttons["查看详情"], in: app)
        XCTAssertFalse(app.buttons["通过并合入"].exists)
        XCTAssertFalse(app.buttons["丢弃"].exists)
        XCTAssertTrue(app.staticTexts[blocker].exists)
        capture(app, "阻断详情-原因与禁用按钮一致")
        XCTAssertTrue(try actions().isEmpty)
        back(app)
        try write([review("blocked", blocked: false)], "reviews/ready-a.json")
        refresh(app)
        XCTAssertTrue(app.staticTexts["1 份成果等你验收"].waitForExistence(timeout: 7))
        XCTAssertTrue(app.staticTexts["待我处理"].exists)
        XCTAssertFalse(app.staticTexts["1 份保留成果，无需你确认"].exists)
        tap(app.staticTexts["1 份成果等你验收"], in: app)
        tap(app.buttons["查看并决定"], in: app)
        XCTAssertTrue(app.buttons["通过并合入"].isEnabled)
        capture(app, "质量准备完成-重新可确认")
    }

    func testMixedCountsSubmitStopsPromptAndFailureAllowsRetry() throws {
        let app = try setup()
        try write([review("ready", blocked: false), review("blocked", blocked: true)], "reviews/ready-a.json")
        app.launch()
        XCTAssertTrue(app.staticTexts["1 份成果等你验收"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["1 份保留成果，无需你确认"].exists)
        XCTAssertFalse(app.staticTexts["2 份成果等你验收"].exists)
        capture(app, "混合成果-数量分开")
        tap(app.staticTexts["1 份成果等你验收"], in: app)
        XCTAssertTrue(app.staticTexts["需要视觉结论的隔离成果"].exists)
        tap(app.buttons["查看并决定"], in: app)
        tap(app.buttons["通过并合入"], in: app)
        XCTAssertTrue(app.staticTexts["已写入，等待目标 Mac 确认"].waitForExistence(timeout: 6))
        XCTAssertFalse(app.staticTexts["待你确认"].exists)
        capture(app, "已提交-详情展示处理中")
        let first = try XCTUnwrap(actions().first)
        XCTAssertEqual(try actions().count, 1)
        back(app)
        XCTAssertTrue(app.staticTexts["2 份保留成果，无需你确认"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["待我处理"].exists)
        XCTAssertFalse(app.staticTexts["1 份成果等你验收"].exists)
        XCTAssertFalse(app.staticTexts["尚未到确认环节，可查看当前原因"].exists,
                       "决定已经提交，不能误称尚未到确认阶段")
        capture(app, "已提交-首页停止催确认")
        try write(["actionID": first.1["id"]!, "invocationID": first.1["invocationID"]!, "machineID": "ready-a",
            "state": "failed", "message": "隔离合入检查失败", "updatedAt": stamp, "attempts": 1], "action-receipts/" + first.0.lastPathComponent)
        refresh(app)
        XCTAssertTrue(app.staticTexts["1 份成果等你验收"].waitForExistence(timeout: 7))
        tap(app.staticTexts["1 份成果等你验收"], in: app)
        tap(app.buttons["查看并决定"], in: app)
        XCTAssertTrue(app.staticTexts["目标 Mac 执行失败，可重试"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["通过并合入"].isEnabled)
        XCTAssertLessThan(app.staticTexts["目标 Mac 执行失败，可重试"].frame.maxY,
                          app.buttons["通过并合入"].frame.minY,
                          "失败状态须独立一行，不能挤占合入按钮空间")
        capture(app, "失败可重试-仍保留另一阻断成果")
        tap(app.buttons["通过并合入"], in: app)
        XCTAssertTrue(app.staticTexts["已写入，等待目标 Mac 确认"].waitForExistence(timeout: 5))
        let sent = try actions(); XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(Set(sent.compactMap { $0.1["invocationID"] as? String }).count, 2)
    }

    func testBlockedReviewDoesNotHideQuestionsOrPlansAndLandscapeIsReadable() throws {
        let app = try setup()
        try write([review("blocked", blocked: true)], "reviews/ready-a.json")
        try write(["id": "ready-question", "taskID": "question-task", "platform": "codex", "machineID": "ready-a",
            "machineName": "隔离 MacBook Pro", "repoName": "隔离成果项目", "taskPrompt": "隔离提问任务", "askedAt": stamp,
            "questions": [["id": "ready-q1", "text": "准备期间仍需回答的问题", "options": ["采用方案甲", "采用方案乙"]]]], "questions/ready-a/question-task.json")
        try write(["machineID": "ready-a", "machineName": "隔离 MacBook Pro", "generatedAt": stamp, "tasks": [],
                   "planned": [["id": "ready-plan", "title": "准备期间仍需放行的计划"]]], "taskboards/ready-a.json")
        app.launch()
        XCTAssertTrue(app.staticTexts["待我处理"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["准备期间仍需回答的问题"].exists)
        XCTAssertTrue(app.staticTexts["1 个计划等你放行"].exists)
        XCTAssertTrue(app.staticTexts["1 份保留成果，无需你确认"].exists)
        capture(app, "阻断成果不影响问答和计划")
        tap(app.staticTexts["准备期间仍需回答的问题"], in: app)
        XCTAssertTrue(app.staticTexts["采用方案甲"].waitForExistence(timeout: 5))
        // AnswerView 的 sheet 没有取消按钮；只读检查后重新进入首页，绝不提交假答案。
        app.terminate(); app.launch()
        tap(app.staticTexts["1 个计划等你放行"], in: app)
        XCTAssertTrue(app.staticTexts["准备期间仍需放行的计划"].waitForExistence(timeout: 5))
        back(app)
        if app.windows.firstMatch.frame.width > 700 {
            XCUIDevice.shared.orientation = .landscapeRight
            let horizontal = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [horizontal], timeout: 8), .completed)
            capture(app, "实际横屏-首页问答计划与成果进展")
            tap(app.staticTexts["1 份保留成果，无需你确认"], in: app)
            tap(app.buttons["查看详情"], in: app)
            XCTAssertFalse(app.buttons["通过并合入"].exists)
            XCTAssertFalse(app.buttons["丢弃"].exists)
            capture(app, "实际横屏-阻断详情与合入禁用")
            XCUIDevice.shared.orientation = .portrait
        }
    }
}

@MainActor
final class DeliveryInboxUITests: XCTestCase {
    func testTasksAndQuestionsStayActionableWithoutDashboard() throws {
        let root = URL(fileURLWithPath: "/tmp/llmq-delivery-ui-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ object: [String: Any], _ path: String) throws {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object).write(to: file)
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        try write(["machineID": "isolated-a", "generatedAt": stamp, "tasksTruncated": false, "tasks": [
            ["id": "repair", "title": "隔离诊断任务", "state": "blocked", "waitReason": "architectureReview", "progressPhase": "系统诊断中", "machineName": "测试机器"]]], "taskboards/isolated-a.json")
        try write(["id": "isolated-ask", "machineID": "isolated-a", "platform": "kimi", "taskID": "repair", "questions": [["id": "q", "text": "仅供验收的授权选择", "options": ["隔离方案甲", "隔离方案乙"]]]], "questions/isolated-a/repair.json")
        let app = XCUIApplication(); app.launchEnvironment["LLMQ_FOLDER"] = root.path; app.launch()
        XCTAssertTrue(app.staticTexts["交付进展"].waitForExistence(timeout: 12))
        XCTAssertFalse(app.staticTexts["卡住了："].exists)
        for _ in 0..<4 where !app.staticTexts["仅供验收的授权选择"].isHittable { app.swipeUp() }
        let question = app.staticTexts["仅供验收的授权选择"]
        XCTAssertTrue(question.isHittable)
        let screen = XCTAttachment(screenshot: app.screenshot()); screen.name = "无额度快照的可操作待办"; screen.lifetime = .keepAlways; add(screen)
        question.tap()
        XCTAssertTrue(app.staticTexts["隔离方案甲"].waitForExistence(timeout: 5))
    }
}

@MainActor
final class ReviewContinuationIndependentUITests: XCTestCase {
    private var root: URL!
    private var stamp: String { ISO8601DateFormatter().string(from: Date()) }
    private func write(_ object: Any, _ path: String) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file)
    }
    private func setup() throws -> XCUIApplication {
        root = URL(fileURLWithPath: "/tmp/llmq-continue-independent-ui-" + UUID().uuidString)
        try write(["generatedAt": stamp, "machines": [["machineID": "continue-a", "machineName": "验收 MacBook Pro", "lastSeen": stamp, "isStale": false]], "reports": []], "dashboard.json")
        let app = XCUIApplication(); app.launchEnvironment["LLMQ_FOLDER"] = root.path
        return app
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<4 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    private func reach(_ element: XCUIElement, app: XCUIApplication) {
        reveal(element, app: app); element.tap()
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    func testOrdinaryQuestionDeferralWritesNothingAndQuestionRemains() throws {
        let app = try setup()
        defer { app.terminate(); try? FileManager.default.removeItem(at: root) }
        let path = "questions/continue-a/task.json"
        try write(["id": "defer-question", "taskID": "task", "machineID": "continue-a", "round": 1,
            "askedAt": stamp, "platform": "kimi", "taskPrompt": "保留 Flint 当前成果", "repoName": "隔离验收", "kind": "question",
            "progressNote": "已提交的进度保留", "questions": [["id": "q", "text": "账号暂时不可用，请确认后续安排"]]], path)
        let original = try Data(contentsOf: root.appendingPathComponent(path))
        app.launch()
        let question = app.staticTexts["账号暂时不可用，请确认后续安排"]
        XCTAssertTrue(question.waitForExistence(timeout: 10)); reach(question, app: app)
        let later = app.buttons["稍后处理，保留进度"]
        reveal(later, app: app)
        XCTAssertTrue(later.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["回复并继续"].isEnabled, "无选项/无建议的普通问题不能空答复")
        capture(app, "普通执行问题-可稍后处理")
        reach(later, app: app)
        XCTAssertTrue(question.waitForExistence(timeout: 5), "稍后处理不能撤掉原问题")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("answers").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("actions").path))
        reach(question, app: app)
        reveal(later, app: app)
        XCTAssertTrue(later.waitForExistence(timeout: 5), "原问题仍可再次进入处理")
    }
    func testBlockedReviewCanContinueAndPendingDispositionIsNotOperable() throws {
        let app = try setup()
        defer { app.terminate(); try? FileManager.default.removeItem(at: root) }
        let head = String(repeating: "a", count: 40)
        try write([["repo": "/tmp/independent-continue", "repoName": "隔离验收", "branch": "agent/kimi/task", "head": head,
            "platform": "kimi", "subject": "有成果，质量仍需完善", "mergesCleanly": true, "landingBlockReason": "尚缺独立视觉验收",
            "continuationActionID": "review-continuation:request:/tmp/independent-continue|agent/kimi/task|" + head + "|task|v1"]], "reviews/continue-a.json")
        app.launch()
        let card = app.staticTexts["1 份保留成果，无需你确认"]
        XCTAssertTrue(card.waitForExistence(timeout: 10)); reach(card, app: app)
        reach(app.buttons["查看详情"], app: app)
        let continuation = app.buttons["保留成果，继续完善"]
        XCTAssertTrue(continuation.waitForExistence(timeout: 5)); XCTAssertTrue(continuation.isEnabled)
        XCTAssertFalse(app.buttons["通过并合入"].exists)
        XCTAssertFalse(app.buttons["丢弃"].exists)
        capture(app, "质量受阻-保留成果继续完善")
        reach(continuation, app: app)
        XCTAssertTrue(app.staticTexts.matching(identifier: "已写入，等待目标 Mac 确认").firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["丢弃"].exists && app.buttons["丢弃"].isEnabled, "续作待回执时不能保留可点的丢弃入口")
        XCTAssertFalse(continuation.isEnabled)
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("actions"), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "json" }.count, 1)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: files.first!)) as? [String: Any])
        XCTAssertTrue((body["id"] as? String)?.contains(":review-continuation:request:") == true)
        capture(app, "续作待回执-互斥操作")
    }
}
