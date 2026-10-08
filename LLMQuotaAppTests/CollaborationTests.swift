import XCTest
@testable import LLMQuotaApp

/// 协作时间线只消费服务端下发的显式事实（`views/collaboration.json`），
/// 线格式以 Mac 端 `ViewFeed.collaborationPage` 为准：
/// facts 给「待回应 / 最近记录」，cards 按最近在前给 sender → recipient、
/// pending 用 warn 语气、结果用 good 语气、证据文件名放 images。
/// 客户端不另立第二套协作状态源，也不显示任何模型隐藏推理。
final class CollaborationTests: XCTestCase {
    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// 严格照 ViewFeed.swift collaborationPage 的产出形状拼的样例。
    private func contractJSON() -> String {
        """
        {"schema":1,"page":"collaboration","generatedAt":"2026-08-26T03:00:00Z",\
        "sections":[\
        {"kind":"facts","title":"协作状态","facts":[\
        {"key":"待回应","value":"1","tone":"warn"},\
        {"key":"最近记录","value":"2","tone":"neutral"},\
        {"key":"主动认领","value":"1","tone":"neutral"},\
        {"key":"问答","value":"1/1","tone":"neutral"}]},\
        {"kind":"cards","title":"最近动态","note":"只显示 Agent 主动留下的结论、问题、证据和交接",\
        "cards":[\
        {"id":"e1","title":"替换成一句可执行结论",\
        "body":"opencode.openrouter.code → claude-runner",\
        "detail":"分支：agent/openrouter/ff763a1f\\n提交：51b7cfe",\
        "tone":"warn","icon":"bubble.left.and.exclamationmark.bubble.right",\
        "trailing":"LLMQuotaApp","eventKind":"question","taskID":"74726e09"},\
        {"id":"e2","title":"首屏性能边界已经用单测钉住",\
        "body":"opencode.openrouter.code · 项目广播",\
        "tone":"good","icon":"arrow.triangle.branch",\
        "trailing":"LLMQuotaBar","images":["shot.png"],"eventKind":"answer",\
        "replyTo":"e1","taskID":"74726e09"}]}]}
        """
    }

    private func contractPage() throws -> FeedPage {
        try decoder().decode(FeedPage.self, from: Data(contractJSON().utf8))
    }

    func testTimelineFollowsCollaborationPageContract() throws {
        let digest = CollaborationDigest(try contractPage())

        XCTAssertEqual(digest.availability, .ready)
        XCTAssertEqual(digest.pendingCount, 1, "待回应数取自服务端算好的 facts")
        XCTAssertEqual(digest.recentCount, 2)
        XCTAssertEqual(digest.claimCount, 1)
        XCTAssertEqual(digest.questionAnswerCount, "1/1")
        XCTAssertEqual(digest.entries.count, 2)

        let pending = digest.entries[0]
        XCTAssertEqual(pending.id, "e1")
        XCTAssertTrue(pending.pending, "契约里 warn 语气就是待回应，客户端不再另判")
        XCTAssertEqual(pending.kindLabel, "提问",
                       "事件类型与等待状态必须分开；待回应由 pending 表达")
        XCTAssertEqual(pending.direction, "opencode.openrouter.code → claude-runner")
        XCTAssertEqual(pending.project, "LLMQuotaApp", "项目要可辨识（卡片 trailing）")
        XCTAssertEqual(pending.eventKind, "question")
        XCTAssertEqual(pending.taskID, "74726e09")
        XCTAssertTrue(pending.detail?.contains("agent/openrouter/ff763a1f") ?? false,
                      "分支/提交这些证据引用放在可展开的详情里")
        XCTAssertEqual(pending.images.count, 0)

        let resolved = digest.entries[1]
        XCTAssertFalse(resolved.pending)
        XCTAssertEqual(resolved.kindLabel, "回复", "结构化事件类型优先于颜色推断")
        XCTAssertEqual(resolved.replyTo, "e1")
        XCTAssertEqual(resolved.direction, "opencode.openrouter.code · 项目广播")
        XCTAssertEqual(resolved.images, ["shot.png"], "证据引用原样透传，加载仍按需")
        XCTAssertEqual(digest.replyContext(for: resolved),
                       "回应提问：替换成一句可执行结论",
                       "回复要直接说清所回应的人类可读事项，不能只露事件 ID")
    }

    func testCurrentServerStatsAndConversationsAreNotMixedWithRoster() throws {
        var page = try contractPage()
        page.sections[0].facts?.removeAll { $0.key == "问答" }
        page.sections[0].facts?.append(FeedFact(key: "Agent 互问", value: "1/1"))
        page.sections.append(FeedSection(kind: "cards", title: "交互关系", cards: [
            FeedCard(id: "conversation", title: "Kimi ⇄ Codex｜问题", body: "提问 → 回复 → 确认",
                     detail: "提问全文\n答复全文\n部分采用及理由", trailing: "Flint", eventKind: "conversation"),
            FeedCard(id: "task-chain", title: "任务交接", trailing: "Flint", eventKind: "chain"),
        ]))
        page.sections.append(FeedSection(kind: "cards", title: "可用 Agent", cards: [
            FeedCard(id: "agent", title: "Codex", body: "Mac mini", trailing: "今天 10:00", eventKind: "agent"),
        ]))
        let digest = CollaborationDigest(page)
        XCTAssertEqual(digest.questionAnswerCount, "1/1")
        XCTAssertFalse(digest.entries.contains { $0.id == "agent" })
        XCTAssertFalse(digest.projects.contains("今天 10:00"))
        XCTAssertEqual(digest.entries.first { $0.id == "conversation" }?.kindLabel, "问答")
        XCTAssertEqual(digest.entries.first { $0.id == "task-chain" }?.kindLabel, "工作链")
    }

    func testAcknowledgementDoesNotClaimAdoption() throws {
        var page = try contractPage()
        page.sections[1].cards?[0].eventKind = "ack"
        page.sections[1].cards?[0].title = "拒绝建议，已说明证据"
        XCTAssertEqual(CollaborationDigest(page).entries[0].kindLabel, "确认反馈")
    }

    func testReplyContextDegradesWithoutExposingOpaqueEventID() throws {
        let json = contractJSON().replacingOccurrences(of: "\"replyTo\":\"e1\"",
                                                        with: "\"replyTo\":\"older-event-id\"")
        let digest = CollaborationDigest(try decoder().decode(
            FeedPage.self, from: Data(json.utf8)))
        XCTAssertEqual(digest.replyContext(for: digest.entries[1]), "回应较早的协作事项")
        XCTAssertFalse(digest.replyContext(for: digest.entries[1])?.contains("older") == true)
    }

    func testMissingFeedDegradesHonestNotFake() {
        // 老服务端压根没发过这一页：不能编一个「0 条待回应」，
        // 也不能让入口消失 —— 入口在、内容诚实说没有。
        let digest = CollaborationDigest(nil)
        XCTAssertEqual(digest.availability, .unavailable)
        XCTAssertTrue(digest.entries.isEmpty)
        XCTAssertNil(digest.pendingCount)
        XCTAssertNil(digest.recentCount)
    }

    func testEmptyServerFeedKeepsServerCopyWithoutInventingEntries() throws {
        let json = """
        {"schema":1,"page":"collaboration","generatedAt":"2026-08-26T03:00:00Z",\
        "sections":[{"kind":"text","title":"还没有 Agent 协作记录","tone":"neutral",\
        "text":"任务开始、交接、发现和结果会自动出现在这里。"}]}
        """
        let page = try decoder().decode(FeedPage.self, from: Data(json.utf8))
        let digest = CollaborationDigest(page)

        XCTAssertEqual(digest.availability, .ready)
        XCTAssertTrue(digest.entries.isEmpty)
        XCTAssertEqual(digest.emptyNotice?.text,
                       "任务开始、交接、发现和结果会自动出现在这里。",
                       "服务端的空态文案原样展示，客户端不替它编内容")
        XCTAssertNil(digest.pendingCount)
    }

    func testNewerSchemaAsksForAppUpdate() throws {
        var page = try contractPage()
        page.schema = FeedPage.supportedSchema + 1
        XCTAssertEqual(CollaborationDigest(page).availability, .needsUpdate)
    }

    func testUnknownToneStillBuildsTimeline() throws {
        // 服务端以后加第 5 种语气：整页不能解不出来，条目降级成普通动态。
        let json = contractJSON()
            .replacingOccurrences(of: "\"tone\":\"good\"", with: "\"tone\":\"critical\"")
        let page = try decoder().decode(FeedPage.self, from: Data(json.utf8))
        let digest = CollaborationDigest(page)
        XCTAssertEqual(digest.entries.count, 2)
        XCTAssertEqual(digest.entries[1].kindLabel, "回复",
                       "不认识的语气不能覆盖显式事件类型，更不能让时间线消失")
    }

    func testProjectFilterListIsUniqueAndStable() throws {
        let digest = CollaborationDigest(try contractPage())
        XCTAssertEqual(digest.projects, ["LLMQuotaApp", "LLMQuotaBar"],
                       "筛项目用的名单去重且保持服务端顺序")
    }

    func testDemoCollaborationFeedMatchesContractShape() throws {
        let page = try XCTUnwrap(Demo.collaborationFeed(),
                                 "演示模式也要能看见这个功能长什么样")
        let digest = CollaborationDigest(page)
        XCTAssertEqual(digest.availability, .ready)
        XCTAssertTrue(digest.entries.contains(where: \.pending), "演示得有等回应的一条")
        XCTAssertTrue(digest.entries.contains { !$0.pending }, "也得有已解决的一条")
        XCTAssertTrue(digest.entries.allSatisfy { !$0.direction.isEmpty },
                      "每条都要看得出谁发给谁")
    }
}
