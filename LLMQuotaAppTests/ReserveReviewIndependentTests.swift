import XCTest
@testable import LLMQuotaApp

final class ReserveReviewIndependentTests: XCTestCase {
    private func root() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reserve-app-review-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func intent(in root: URL) throws -> (URL, [String: Any]) {
        let directory = root.appendingPathComponent("config-intents")
        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file))
            as? [String: Any])
        return (file, object)
    }

    private func park(_ original: [String: Any], root: URL, id: String,
                      requestedAt: Double, processedAt: String,
                      accepted: Bool = true) throws {
        let directory = root.appendingPathComponent("config-intents/processed")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var copy = original
        copy["requestedAt"] = requestedAt
        try JSONSerialization.data(withJSONObject: copy).write(
            to: directory.appendingPathComponent("done-" + id + ".json"))
        let receipt: [String: Any] = [
            "id": id, "verdict": accepted ? "applied" : "rejected",
            "accepted": accepted, "note": "fixture", "processedAt": processedAt,
        ]
        try JSONSerialization.data(withJSONObject: receipt).write(
            to: directory.appendingPathComponent("done-" + id + ".result.json"))
    }

    @MainActor
    func testRapidRequestsHaveMonotonicSubsecondOrderAndSurviveStoreRecreation() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(); store.debugAttachRoot(root)
        let sentFirst = await store.setReserve(platform: "kimi", fraction: 0.2)
        XCTAssertTrue(sentFirst)
        let first = try XCTUnwrap(store.reserveSubmissions["kimi"])
        let sentSecond = await store.setReserve(platform: "kimi", fraction: 0.6)
        XCTAssertTrue(sentSecond)
        let second = try XCTUnwrap(store.reserveSubmissions["kimi"])
        XCTAssertGreaterThan(second.requestedAt, first.requestedAt)
        XCTAssertNotEqual(second.id, first.id)

        let reopened = Store(); reopened.debugAttachRoot(root)
        let restored = try XCTUnwrap(reopened.reserveSubmissions["kimi"])
        XCTAssertEqual(restored.id, second.id)
        XCTAssertNil(restored.accepted)
    }

    @MainActor
    func testReceiptMustBindRequestedAtAndHaveValidProcessedTime() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(); store.debugAttachRoot(root)
        let sent = await store.setReserve(platform: "kimi", fraction: 0.6)
        XCTAssertTrue(sent)
        let record = try XCTUnwrap(store.reserveSubmissions["kimi"])
        let (_, original) = try intent(in: root)

        try park(original, root: root, id: record.id, requestedAt: record.requestedAt - 1,
                 processedAt: ISO8601DateFormatter().string(from: Date()))
        await store.refreshReserveReceipts()
        XCTAssertNil(store.reserveSubmissions["kimi"]?.accepted,
                     "同 UUID 但顺序字段被改写，不能冒充本次回执")

        try park(original, root: root, id: record.id, requestedAt: record.requestedAt,
                 processedAt: "不是时间")
        await store.refreshReserveReceipts()
        XCTAssertNil(store.reserveSubmissions["kimi"]?.accepted)

        try park(original, root: root, id: record.id, requestedAt: record.requestedAt,
                 processedAt: ISO8601DateFormatter().string(from: Date()))
        await store.refreshReserveReceipts()
        XCTAssertEqual(store.reserveSubmissions["kimi"]?.accepted, true)
    }

    @MainActor
    func testWriteFailureClearsPendingAndSurvivesPageModelRecreation() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        // 用普通文件占住目标目录，稳定制造真实文件系统写失败，不依赖权限弹窗。
        try Data("occupied".utf8).write(to: root.appendingPathComponent("config-intents"))

        let store = Store(); store.debugAttachRoot(root)
        let sent = await store.setReserve(platform: "kimi", fraction: 0.4)
        XCTAssertFalse(sent)
        let failed = try XCTUnwrap(store.reserveSubmissions["kimi"])
        XCTAssertEqual(failed.accepted, false)
        XCTAssertTrue(failed.note?.contains("写入失败") == true)

        let reopened = Store(); reopened.debugAttachRoot(root)
        let restored = try XCTUnwrap(reopened.reserveSubmissions["kimi"])
        XCTAssertEqual(restored.id, failed.id)
        XCTAssertEqual(restored.fraction, 0.4)
        XCTAssertEqual(restored.accepted, false,
                       "写失败后重进页面不能重新显示成仍待确认")
    }
}
