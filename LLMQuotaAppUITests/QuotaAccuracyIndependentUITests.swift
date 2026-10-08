import XCTest

@MainActor
final class QuotaAccuracyIndependentUITests: XCTestCase {
    func testBoardRoundsProducerFractionInsteadOfTruncatingIt() throws {
        let root = URL(fileURLWithPath: "/tmp/llmq-quota-format-ui-" + UUID().uuidString,
                       isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now)
        let expires = ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))
        let dashboard: [String: Any] = [
            "generatedAt": stamp,
            "machines": [["machineID": "quota-qa", "machineName": "额度验收机",
                           "lastSeen": stamp, "isStale": false]],
            "reports": [[
                "platform": "codex", "planName": "ChatGPT Pro", "detected": true,
                "installed": true, "machines": ["额度验收机"], "last30dRequests": 1,
                "last30dBillableTokens": 1,
                "statuses": [[
                    "platform": "codex", "limitID": "official-codex:primary",
                    "label": "每周", "metric": "percent", "used": 57,
                    "usedFraction": 0.57, "health": "healthy", "isOfficial": true,
                    "sourceKind": "officialFact", "observedAt": stamp,
                    "expiresAt": expires, "sourceNote": "平台直报"
                ]]
            ]]
        ]
        try JSONSerialization.data(withJSONObject: dashboard, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("dashboard.json"), options: .atomic)

        let app = XCUIApplication()
        app.launchEnvironment["LLMQ_FOLDER"] = root.path
        app.launch()
        let board = navigationTab("看板", in: app)
        XCTAssertTrue(board.waitForExistence(timeout: 10))
        board.tap()
        XCTAssertTrue(app.staticTexts["已用 57%"].waitForExistence(timeout: 5),
                      "Core 的 0.57 必须显示为 57%，不能因二进制浮点截断为 56%")
        XCTAssertFalse(app.staticTexts["已用 56%"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "额度57百分比四舍五入"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testEstimatedQuotaShowsConfidenceInsteadOfLookingOfficial() throws {
        let root = URL(fileURLWithPath: "/tmp/llmq-estimated-quota-ui-" + UUID().uuidString,
                       isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now)
        let expires = ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))
        let dashboard: [String: Any] = [
            "generatedAt": stamp,
            "machines": [["machineID": "quota-qa", "machineName": "额度验收机",
                           "lastSeen": stamp, "isStale": false]],
            "reports": [[
                "platform": "qwen", "planName": "Qwen Token Plan", "detected": true,
                "installed": true, "machines": ["额度验收机"], "last30dRequests": 1,
                "last30dBillableTokens": 1,
                "statuses": [[
                    "platform": "qwen", "limitID": "weekly", "label": "7 天",
                    "metric": "billableTokens", "used": 1_000_000, "limit": 6_000_000,
                    "usedFraction": 1.0 / 6.0, "health": "healthy", "isOfficial": false,
                    "sourceKind": "localEstimate", "observedAt": stamp,
                    "expiresAt": expires,
                    "sourceNote": "持续学习估算 · 2 个完整周期 · 置信度 70%"
                ]]
            ]]
        ]
        try JSONSerialization.data(withJSONObject: dashboard, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("dashboard.json"), options: .atomic)

        let app = XCUIApplication()
        app.launchEnvironment["LLMQ_FOLDER"] = root.path
        app.launch()
        let board = navigationTab("看板", in: app)
        XCTAssertTrue(board.waitForExistence(timeout: 10))
        board.tap()
        XCTAssertTrue(app.staticTexts["经验估算 · 置信度 70%"].waitForExistence(timeout: 5))

        let more = navigationTab("更多", in: app)
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        let quota = app.staticTexts["额度与用量"]
        XCTAssertTrue(quota.waitForExistence(timeout: 5))
        quota.tap()
        XCTAssertTrue(app.staticTexts["经验估算 · 置信度 70%"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["样本不足，暂不预测重置时余量"].exists)
        XCTAssertFalse(app.staticTexts["暂无可换算的额度上限"].exists)
        XCTAssertFalse(app.staticTexts["平台直报"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "经验额度显式置信度"
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func navigationTab(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let conventional = app.tabBars.buttons[title]
        if conventional.exists { return conventional }
        return app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ AND (elementType == %d OR elementType == %d OR elementType == %d)",
            title, XCUIElement.ElementType.button.rawValue,
            XCUIElement.ElementType.cell.rawValue,
            XCUIElement.ElementType.other.rawValue)).firstMatch
    }
}
