import XCTest
@testable import LLMQuotaApp

/// 独立验收反例：额度窗口的来源和时效不能污染员工状态，未知值也不能变成零。
@MainActor
final class QuotaAccuracyIndependentTests: XCTestCase {
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func report(statusesJSON: String, requests: Int = 3) throws -> PlatformReport {
        let json = """
        {
          "platform":"codex", "planName":"pro", "detected":true,
          "installed":true, "last30dRequests":\(requests),
          "last30dBillableTokens":42, "machines":["qa"],
          "statuses":\(statusesJSON)
        }
        """
        return try decoder().decode(PlatformReport.self, from: Data(json.utf8))
    }

    func testAdvisoryWindowDoesNotDrainCodingStaff() throws {
        let value = try report(statusesJSON: """
        [
          {"platform":"minimax","limitID":"video","label":"视频辅助窗",\
           "metric":"percent","used":100,"usedFraction":1,"health":"exhausted",\
           "advisory":true,"sourceKind":"officialFact"},
          {"platform":"codex","limitID":"primary","label":"主窗口",\
           "metric":"percent","used":20,"usedFraction":0.2,"health":"healthy",\
           "advisory":false,"sourceKind":"officialFact"}
        ]
        """)

        XCTAssertEqual(StaffState.classify(value), .working,
                       "辅助素材窗口只供展示，不能把编码员工判为产能耗尽")
    }

    func testExpiredAndUnknownSourceWindowsDoNotOverrideCurrentHealth() throws {
        let value = try report(statusesJSON: """
        [
          {"platform":"codex","limitID":"expired","label":"旧窗口",\
           "metric":"percent","used":100,"usedFraction":1,"health":"exhausted",\
           "sourceKind":"officialFact","observedAt":"2025-01-01T00:00:00Z",\
           "expiresAt":"2025-01-01T06:00:00Z"},
          {"platform":"codex","limitID":"unknown","label":"未知来源",\
           "metric":"percent","used":100,"usedFraction":1,"health":"exhausted",\
           "sourceKind":"unknown","observedAt":"2099-01-01T00:00:00Z",\
           "expiresAt":"2099-01-01T06:00:00Z"},
          {"platform":"codex","limitID":"current","label":"当前窗口",\
           "metric":"percent","used":20,"usedFraction":0.2,"health":"healthy",\
           "sourceKind":"officialFact","observedAt":"2099-01-01T00:00:00Z",\
           "expiresAt":"2099-01-01T06:00:00Z"}
        ]
        """)

        XCTAssertEqual(StaffState.classify(value), .working,
                       "过期窗口和未知来源都不应覆盖当前可信窗口的健康度")
    }

    func testLegacyResetTimeStillDefinesWhetherWindowIsCurrent() throws {
        let expiredLegacy = try report(statusesJSON: """
        [
          {"platform":"codex","limitID":"old","label":"旧协议已过期",\
           "metric":"percent","used":100,"usedFraction":1,"health":"exhausted",\
           "resetsAt":"2025-01-01T00:00:00Z"},
          {"platform":"codex","limitID":"current","label":"当前窗口",\
           "metric":"percent","used":20,"usedFraction":0.2,"health":"healthy",\
           "resetsAt":"2099-01-01T00:00:00Z"}
        ]
        """)
        XCTAssertEqual(StaffState.classify(expiredLegacy), .working,
                       "旧协议没有 expiresAt 时应退回 resetsAt 判断时效")

        let currentLegacy = try report(statusesJSON: """
        [{"platform":"codex","limitID":"current","label":"旧协议当前窗口",\
          "metric":"percent","used":100,"usedFraction":1,"health":"exhausted",\
          "resetsAt":"2099-01-01T00:00:00Z"}]
        """)
        XCTAssertEqual(StaffState.classify(currentLegacy), .drained,
                       "仍在有效期的旧协议窗口不能被兼容逻辑丢掉")
    }

    func testExpiresAtTakesPrecedenceOverLegacyResetFallback() throws {
        let status = try decoder().decode(QuotaStatus.self, from: Data(#"""
        {
          "platform":"codex","limitID":"current","label":"当前窗口",
          "metric":"percent","used":20,"usedFraction":0.2,"health":"healthy",
          "sourceKind":"officialFact","observedAt":"2026-09-06T00:00:00Z",
          "expiresAt":"2099-01-01T06:00:00Z","resetsAt":"2025-01-01T00:00:00Z"
        }
        """#.utf8))

        XCTAssertTrue(status.isFresh(now: Date(timeIntervalSince1970: 1_788_652_800)),
                      "新协议已有 expiresAt 时应以它为准；仅缺失时才回退 resetsAt")
    }

    func testOneExhaustedPoolDoesNotDrainPlatformWhenAnotherPoolIsUsable() throws {
        let statuses = """
        [
          {"platform":"codex","limitID":"personal|weekly","label":"个人池 · 周窗口",\
           "metric":"percent","used":100,"usedFraction":1,"health":"exhausted",\
           "sourceKind":"officialFact","observedAt":"2099-01-01T00:00:00Z",\
           "expiresAt":"2099-01-01T06:00:00Z"},
          {"platform":"codex","limitID":"team|weekly","label":"团队池 · 周窗口",\
           "metric":"percent","used":20,"usedFraction":0.2,"health":"healthy",\
           "sourceKind":"officialFact","observedAt":"2099-01-01T00:00:00Z",\
           "expiresAt":"2099-01-01T06:00:00Z"}
        ]
        """
        let json = """
        {
          "platform":"codex", "planName":"pro", "detected":true,
          "installed":true, "last30dRequests":3, "last30dBillableTokens":42,
          "machines":["qa-a","qa-b"], "statuses":\(statuses),
          "quotaPools":[
            {
              "poolID":"personal","displayName":"个人池","machineIDs":["a"],
              "machines":["qa-a"],"detected":true,"installed":true,
              "statuses":[
                {"platform":"codex","limitID":"weekly","label":"周窗口",\
                 "metric":"percent","used":100,"usedFraction":1,"health":"exhausted",\
                 "sourceKind":"officialFact","observedAt":"2099-01-01T00:00:00Z",\
                 "expiresAt":"2099-01-01T06:00:00Z"}
              ]
            },
            {
              "poolID":"team","displayName":"团队池","machineIDs":["b"],
              "machines":["qa-b"],"detected":true,"installed":true,
              "statuses":[
                {"platform":"codex","limitID":"weekly","label":"周窗口",\
                 "metric":"percent","used":20,"usedFraction":0.2,"health":"healthy",\
                 "sourceKind":"officialFact","observedAt":"2099-01-01T00:00:00Z",\
                 "expiresAt":"2099-01-01T06:00:00Z"}
              ]
            }
          ],
          "localQuotaPoolID":"personal"
        }
        """
        let value = try decoder().decode(PlatformReport.self, from: Data(json.utf8))

        XCTAssertEqual(StaffState.classify(value), .working,
                       "仍有一个可用额度池时，整个平台不能显示产能耗尽")
    }

    func testSinglePoolUsesTightestWindowInsteadOfWarningUrgencyOrder() throws {
        let statuses = """
        [
          {"platform":"codex","limitID":"short","label":"短窗",\
           "metric":"percent","used":0,"usedFraction":0,"health":"wasting",\
           "sourceKind":"officialFact","observedAt":"2099-01-01T00:00:00Z",\
           "expiresAt":"2099-01-01T06:00:00Z"},
          {"platform":"codex","limitID":"weekly","label":"周窗",\
           "metric":"percent","used":100,"usedFraction":1,"health":"exhausted",\
           "sourceKind":"officialFact","observedAt":"2099-01-01T00:00:00Z",\
           "expiresAt":"2099-01-01T06:00:00Z"}
        ]
        """
        let json = """
        {
          "platform":"codex", "planName":"pro", "detected":true,
          "installed":true, "last30dRequests":3, "last30dBillableTokens":42,
          "machines":["qa"], "statuses":\(statuses),
          "quotaPools":[{
            "poolID":"personal","displayName":"个人池","machineIDs":["a"],
            "machines":["qa"],"detected":true,"installed":true,
            "statuses":\(statuses)
          }],
          "localQuotaPoolID":"personal"
        }
        """
        let value = try decoder().decode(PlatformReport.self, from: Data(json.utf8))

        XCTAssertEqual(StaffState.classify(value), .drained,
                       "同池有耗尽窗口时不能被更高提醒优先级的闲置/将作废窗口盖住")
    }

    func testQuotaStatusPreservesUnknownUsageAndCompatibilityMetadata() throws {
        let data = Data(#"""
        {
          "platform":"codex","limitID":"weekly","label":"周窗口",
          "metric":"percent","usedFraction":null,"health":"healthy",
          "advisory":true,"sourceKind":"unknown",
          "observedAt":"2026-09-06T00:00:00Z","expiresAt":"2026-09-06T06:00:00Z"
        }
        """#.utf8)
        let status = try decoder().decode(QuotaStatus.self, from: data)
        let stored = Dictionary(uniqueKeysWithValues: Mirror(reflecting: status).children.compactMap {
            child -> (String, Any)? in
            guard let label = child.label else { return nil }
            return (label, child.value)
        })

        XCTAssertEqual(stored["hasUsageValue"] as? Bool, false,
                       "缺失 used 必须保持未知，不能按 0 或剩余 100% 处理")
        XCTAssertEqual(stored["advisory"] as? Bool, true)
        XCTAssertNotNil(stored["sourceKind"], "sourceKind 不能在手机解码时丢失")
        XCTAssertNotNil(stored["observedAt"], "observedAt 不能在手机解码时丢失")
        XCTAssertNotNil(stored["expiresAt"], "expiresAt 不能在手机解码时丢失")
    }

    func testHistoricalPeakDoesNotClaimCurrentMinimumRemaining() throws {
        let status = try decoder().decode(QuotaStatus.self, from: Data(#"""
        {
          "platform":"qwen","limitID":"daily","label":"每日",
          "metric":"requests","used":337,"observedFloor":898,
          "health":"unconfigured","isOfficial":false,"sourceNote":"历史观测"
        }
        """#.utf8))

        XCTAssertNil(status.minimumRemainingValue,
                     "历史峰值未绑定当前套餐、额度池和有效期，不能宣称当前至少还能用")
    }

    func testExpiredAndUnknownUsageAreNotPromotedToAttentionBoard() throws {
        let expired = try decoder().decode(QuotaStatus.self, from: Data(#"""
        {"platform":"codex","limitID":"old","label":"旧窗口","metric":"percent",
         "used":100,"usedFraction":1,"health":"exhausted","sourceKind":"officialFact",
         "expiresAt":"2025-01-01T00:00:00Z"}
        """#.utf8))
        let unknown = try decoder().decode(QuotaStatus.self, from: Data(#"""
        {"platform":"codex","limitID":"unknown","label":"未知来源","metric":"percent",
         "used":100,"usedFraction":1,"health":"exhausted","sourceKind":"unknown",
         "expiresAt":"2099-01-01T00:00:00Z"}
        """#.utf8))

        XCTAssertFalse(BoardView.worthWatching(expired),
                       "过期事实可以在详情保留，但不能进入“最需要关注”或待办计数")
        XCTAssertFalse(BoardView.worthWatching(unknown),
                       "未知来源不能用红色健康值制造额度告警")
    }

    func testExpiredAndUnknownOfficialUsageDoNotMaskBrokenActivityLink() throws {
        let expired = try report(statusesJSON: """
        [{"platform":"codex","limitID":"old","label":"旧窗口","metric":"percent",
          "used":30,"usedFraction":0.3,"health":"healthy","isOfficial":true,
          "sourceKind":"officialFact","expiresAt":"2025-01-01T00:00:00Z"}]
        """, requests: 0)
        let unknown = try report(statusesJSON: """
        [{"platform":"codex","limitID":"unknown","label":"未知来源","metric":"percent",
          "used":30,"usedFraction":0.3,"health":"healthy","isOfficial":true,
          "sourceKind":"unknown","expiresAt":"2099-01-01T00:00:00Z"}]
        """, requests: 0)

        XCTAssertFalse(expired.hasOfficialUsage,
                       "过期额度不能掩盖最近一周没有可验证活动的断链风险")
        XCTAssertFalse(unknown.hasOfficialUsage,
                       "未知来源即使携带旧 isOfficial 标记，也不能证明链路仍活跃")
    }
}
