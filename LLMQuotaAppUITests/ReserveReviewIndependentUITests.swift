import XCTest

@MainActor
final class ReserveReviewIndependentUITests: XCTestCase {
    private func makeFixture() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp/llmq-reserve-ui-" + UUID().uuidString,
                       isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeDashboard(root: root, fraction: 0.25)
        return root
    }

    private func writeDashboard(root: URL, fraction: Double, conflict: Bool = false,
                                reserveUpdatedAt: Double? = nil) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        var role: [String: Any] = [
            "platform": "kimi", "title": "主力", "maxRisk": "normal",
            "prefers": [], "note": "", "reserveFraction": fraction,
            "reserveIsDefault": false, "reserveConflict": conflict,
        ]
        if let reserveUpdatedAt { role["reserveUpdatedAt"] = reserveUpdatedAt }
        let dashboard: [String: Any] = [
            "generatedAt": now,
            "machines": [],
            "reports": [[
                "platform": "kimi", "planName": "Kimi", "detected": true,
                "installed": true, "enabled": true, "statuses": [],
                "last30dRequests": 1, "last30dBillableTokens": 1, "machines": [],
                "role": role
            ]]
        ]
        try JSONSerialization.data(withJSONObject: dashboard, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("dashboard.json"), options: .atomic)
    }

    private func openReserve(_ app: XCUIApplication) {
        let conventional = app.tabBars.buttons["更多"]
        let more = conventional.exists ? conventional : app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "label == %@ AND (elementType == %d OR elementType == %d OR elementType == %d)",
                "更多", XCUIElement.ElementType.button.rawValue,
                XCUIElement.ElementType.cell.rawValue,
                XCUIElement.ElementType.other.rawValue)).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10)); more.tap()
        let settings = app.staticTexts["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5)); settings.tap()
        let entry = app.staticTexts["Agent 可用额度"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
        XCTAssertTrue(app.navigationBars["调度留白"].waitForExistence(timeout: 5))
    }

    private func drag(_ slider: XCUIElement, from old: Double, to new: Double) {
        XCTAssertTrue(waitForValue("\(Int(old))%", of: slider), "先等待夹具的实际滑块值")
        slider.coordinate(withNormalizedOffset: CGVector(dx: old / 95, dy: 0.5))
            .press(forDuration: 0.15,
                   thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: new / 95, dy: 0.5)))
        XCTAssertNotEqual(slider.value as? String, "\(Int(old))%", "真实手势必须改变滑块值")
    }

    private func intents(in root: URL, minimumCount: Int = 1) throws -> [[String: Any]] {
        let directory = root.appendingPathComponent("config-intents")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let files = ((try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }
            if files.count >= minimumCount {
                return try files.map {
                    try XCTUnwrap(try JSONSerialization.jsonObject(
                        with: Data(contentsOf: $0)) as? [String: Any])
                }.sorted { ($0["requestedAt"] as? Double ?? 0) < ($1["requestedAt"] as? Double ?? 0) }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("5秒内没有写出预期数量的留白意图")
        return []
    }

    private func pendingText(_ intent: [String: Any]) throws -> String {
        let fraction = try XCTUnwrap(intent["fraction"] as? Double)
        return "已请求 \(Int((fraction * 100).rounded()))%"
    }

    private func refresh(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        app.activate()
    }

    private func waitForValue(_ value: String, of element: XCUIElement,
                              timeout: TimeInterval = 15) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func writeAcceptedReceipt(for intent: [String: Any], root: URL) throws {
        let id = try XCTUnwrap(intent["id"] as? String)
        let directory = root.appendingPathComponent("config-intents/processed")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: intent).write(
            to: directory.appendingPathComponent("done-" + id + ".json"))
        let receipt: [String: Any] = [
            "id": id, "verdict": "applied", "accepted": true,
            "note": "隔离Core已采纳", "processedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        try JSONSerialization.data(withJSONObject: receipt).write(
            to: directory.appendingPathComponent("done-" + id + ".result.json"))
    }

    func testReturningToLiveValueCannotClaimMacAcceptedWithoutReceipt() throws {
        let root = try makeFixture()
        defer {
            let info = XCTAttachment(string: "fixture=" + root.path); info.name = "reserve-fixture-path"; info.lifetime = .keepAlways; add(info)
        }
        let app = XCUIApplication()
        app.launchEnvironment["LLMQ_FOLDER"] = root.path
        app.launch()
        openReserve(app)

        let slider = app.sliders["Kimi 的调度留白"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        XCTAssertEqual(slider.value as? String, "25%", "夹具首次展示必须是25%")
        let before = XCTAttachment(string: "value=\(String(describing: slider.value)) frame=\(slider.frame)"); before.name = "reserve-before"; before.lifetime = .keepAlways; add(before)
        drag(slider, from: 25, to: 65)
        XCTAssertNotEqual(slider.value as? String, "25%", "拖动必须真实改变滑块，不能用未改变或同值请求当成功")
        let after = XCTAttachment(string: "value=\(String(describing: slider.value)) frame=\(slider.frame)"); after.name = "reserve-after"; after.lifetime = .keepAlways; add(after)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "reserve-after-real-drag"; shot.lifetime = .keepAlways; add(shot)
        let first = try XCTUnwrap(try intents(in: root).last)
        let actual = try XCTUnwrap(slider.value as? String).replacingOccurrences(of: "%", with: "")
        XCTAssertEqual(try XCTUnwrap(first["fraction"] as? Double), try XCTUnwrap(Double(actual)) / 100, accuracy: 0.000001)
        let firstText = try pendingText(first)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", firstText)).firstMatch
            .waitForExistence(timeout: 5))
        try writeDashboard(root: root, fraction: try XCTUnwrap(first["fraction"] as? Double))
        refresh(app)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", firstText)).firstMatch
            .waitForExistence(timeout: 5))
        let falseConfirmation = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Mac 已采纳此次"))
            .firstMatch
        XCTAssertFalse(falseConfirmation.waitForExistence(timeout: 2),
                       "dashboard 的旧值刚好等于草稿，不等于这个 UUID 已被 Mac 接收")
    }

    func testPendingReserveFeedbackSurvivesPageReentry() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = XCUIApplication()
        app.launchEnvironment["LLMQ_FOLDER"] = root.path
        app.launch()
        openReserve(app)

        let slider = app.sliders["Kimi 的调度留白"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        drag(slider, from: 25, to: 65)
        let request = try XCTUnwrap(try intents(in: root).last)
        let requestText = try pendingText(request)
        let sent = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", requestText)).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 5))
        let beforeFiles = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("config-intents"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let before = try XCTUnwrap(beforeFiles.first)
        let beforeJSON = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: before)) as? [String: Any])
        XCTAssertEqual(beforeFiles.count, 1)
        XCTAssertEqual(beforeJSON["fraction"] as? Double, request["fraction"] as? Double)
        let beforeID = try XCTUnwrap(beforeJSON["id"] as? String)

        app.navigationBars.buttons.firstMatch.tap()
        let entry = app.staticTexts["Agent 可用额度"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
        XCTAssertTrue(app.navigationBars["调度留白"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", requestText)).firstMatch.exists,
                      "离开再回来仍应显示该请求的真实 pending/失败/已采纳状态")
        let afterFiles = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("config-intents"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(afterFiles.count, 1)
        let afterJSON = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: try XCTUnwrap(afterFiles.first))) as? [String: Any])
        XCTAssertEqual(afterJSON["id"] as? String, beforeID)
        XCTAssertEqual(afterJSON["fraction"] as? Double, request["fraction"] as? Double)
    }

    func testConflictShowsConservativeLiveValueInsteadOfLocalPendingValue() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = XCUIApplication(); app.launchEnvironment["LLMQ_FOLDER"] = root.path
        app.launch(); openReserve(app)
        let slider = app.sliders["Kimi 的调度留白"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        drag(slider, from: 25, to: 45)
        let request = try XCTUnwrap(try intents(in: root).last)
        XCTAssertLessThan(try XCTUnwrap(request["fraction"] as? Double), 0.60, "旧草稿必须严格低于随后服务端保守值，不能同值误过")
        let requestText = try pendingText(request)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", requestText)).firstMatch.waitForExistence(timeout: 5))

        try writeDashboard(root: root, fraction: 0.60, conflict: true,
                           reserveUpdatedAt: try XCTUnwrap(request["requestedAt"] as? Double))
        refresh(app)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", "顺序冲突" )).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue("60%", of: app.sliders["Kimi 的调度留白"]),
                      "冲突文案已刷新后必须显示实际保守值60%，旧draft不能遮挡")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", requestText)).firstMatch.exists)

        drag(app.sliders["Kimi 的调度留白"], from: 60, to: 40)
        let reset = try XCTUnwrap(try intents(in: root, minimumCount: 2).last)
        XCTAssertGreaterThan(try XCTUnwrap(reset["requestedAt"] as? Double),
                             try XCTUnwrap(request["requestedAt"] as? Double))
        let resetText = try pendingText(reset)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", resetText)).firstMatch.waitForExistence(timeout: 5),
                      "冲突后重设必须显示新请求，不能继续只显示旧冲突")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", "顺序冲突" )).firstMatch.exists)

        try writeAcceptedReceipt(for: reset, root: root)
        refresh(app)
        let resetPct = Int((try XCTUnwrap(reset["fraction"] as? Double) * 100).rounded())
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", "Mac 已采纳此次 \(resetPct)%"))
            .firstMatch.waitForExistence(timeout: 5),
                      "回执先于角色看板同步时仍须按UUID显示已采纳")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", "顺序冲突" )).firstMatch.exists)
    }
}
