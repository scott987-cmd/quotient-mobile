import Foundation
import CryptoKit

/// 给旧版跨端数据补一个可重复的身份，也给共享目录里的命令生成无碰撞文件名。
/// Swift 的 `hashValue` 每次进程启动都会变，不能用于持久化或跨设备协议。
enum StableID {
    static func make(namespace: String, parts: [String]) -> String {
        let raw = ([namespace] + parts).joined(separator: "\u{1}")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// 电脑名来自 macOS，常见格式会把登录用户名带进去，例如
/// “某某的Mac mini”或“username MacBook Pro”。手机只需要用设备名区分机器，
/// 原始名称仍保留给匹配和派活，避免展示层的隐私处理改变协议身份。
func machineNameForDisplay(_ raw: String) -> String {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return "未知机器" }

    // Only display a recognized hardware type. A machine name can also place
    // the owner's name *after* the model, such as "MacBook Pro (Alice)".
    let markers = ["MacBook Pro", "MacBook Air", "MacBook", "Mac mini",
                   "Mac Studio", "Mac Pro", "iMac"]
    for marker in markers {
        if name.range(of: marker, options: [.caseInsensitive]) != nil {
            return marker
        }
    }
    // Unknown and legacy names may consist only of a person's name. Keep the
    // original value for routing; the stable machine ID distinguishes the UI.
    return "Mac"
}

/// 隐私安全、同时可区分同型号机器的名称。
/// 这三台生产节点的稳定 nodeName 已经是部署契约的一部分，优先给出人能认出的
/// 硬件代际；未知节点才退回稳定 machineID 短码，绝不回退用户名。
func machineLabelForDisplay(_ raw: String, machineID: String, nodeName: String? = nil) -> String {
    let base = machineNameForDisplay(raw)
    let node = nodeName?.lowercased() ?? ""
    let qualifier: String?
    if node == "mac-mini" || node.contains("mac-mini-m4") {
        qualifier = "M4"
    } else if node == "macbook-pro-arm64" || node.contains("macbook-pro-m2") {
        qualifier = "M2 Pro"
    } else if node.contains("arm64") || node.contains("apple-silicon") {
        qualifier = "Apple 芯片"
    } else if node.contains("intel") || node.contains("x86") {
        qualifier = "Intel"
    } else {
        let compactID = machineID.filter { $0.isLetter || $0.isNumber }
        qualifier = compactID.isEmpty ? nil : String(compactID.prefix(4)).uppercased()
    }
    return qualifier.map { "\(base) · \($0)" } ?? base
}

// MARK: - 与 Mac 端约定的数据结构
//
// 这里只重复 Mac 端 Dashboard 里**手机上真正要显示的字段**，不是整个模型的拷贝。
// 用 decodeIfPresent 兜底：Mac 端加字段时手机端不该崩，少显示一项而已。
// 反过来手机端也永远不写这些文件 —— 它只往 inbox 投任务，其余全是只读。

struct Dashboard: Codable {
    var generatedAt: Date
    var machines: [MachineInfo]
    var reports: [PlatformReport]

    /// 现在在跑 / 在排队 / 卡住的任务，外加最近几条终态。
    ///
    /// **可选不是为了省事，是因为 nil 和 [] 意思完全不同：**
    /// - `nil` = 这台 Mac 上的 llmq 还没有这个功能，压根没发这份数据；
    /// - `[]`  = 发了，此刻确实一件任务都没有。
    ///
    /// 合并成 `[]` 的话，手机会对着一台旧 Mac 理直气壮地说「没有任务在跑」——
    /// 那是假话，而且是查不出来的假话：屏幕上没有任何东西提示你它其实不知道。
    var tasks: [TaskBrief]?
    /// Mac 端因为条数上限砍掉过任务。
    /// 砍了不吭声的话，「一共 3 件」就成了谎；这个标志是它唯一的痕迹。
    var tasksTruncated: Bool

    // 这里以前有个 `tasksPublished`。现在「知不知道有哪些任务」这件事
    // 归 `TaskDigest.published` 管 —— 因为任务已经不只来自这一份文件了，
    // 还来自 `taskboards/` 下每台机器各自的板子。留着一个只看得见
    // dashboard 的判据，早晚会有人拿它去回答一个它答不了的问题。

    /// **手写解码。**
    ///
    /// 理由和 PlatformReport 那边一样：合成解码器对缺键零容忍，
    /// 而 `tasksTruncated` 是非可选 Bool —— 老 Mac 发来的看板里没有这个键，
    /// 合成解码会抛 `keyNotFound`，**整个 Dashboard 解不出来**，
    /// 手机上就从「多了一块任务区」直接退化成「连额度都看不到了」。
    /// 在属性上写默认值救不了：合成解码器根本不看默认值。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt) ?? .distantPast
        machines = try c.decodeIfPresent([MachineInfo].self, forKey: .machines) ?? []
        reports = try c.decodeIfPresent([PlatformReport].self, forKey: .reports) ?? []
        tasks = try c.decodeIfPresent([TaskBrief].self, forKey: .tasks)
        tasksTruncated = try c.decodeIfPresent(Bool.self, forKey: .tasksTruncated) ?? false
    }
}

struct MachineInfo: Codable, Identifiable {
    var machineID: String
    var machineName: String
    var nodeName: String?
    var maxConcurrentTasks: Int
    var runningTaskCount: Int
    var repoAliases: [String]
    var automaticRepoAliases: [String]
    var runningRepoAliases: [String]
    /// 目标机协调器最近一轮的权威结论。可选是为了继续读取旧 Mac 的看板；
    /// nil 只能解释成“旧版本未上报”，不能擅自解释成空闲。
    var coordinatorState: String?
    var coordinatorSummary: String?
    var coordinatorUpdatedAt: Date?
    var lastSeen: Date
    var isStale: Bool
    var id: String { machineID }
    var displayName: String {
        machineLabelForDisplay(machineName, machineID: machineID, nodeName: nodeName)
    }

    /// 配置中的机器选择器可能是新 machineID、可读 nodeName，或旧 machineName。
    func matches(selector: String) -> Bool {
        selector == machineID || selector == nodeName || selector == machineName
    }

    /// 把滚动升级期间的机器选择器解析成唯一节点。稳定 ID 永远优先；可读节点名
    /// 和旧机器名只有在集群内唯一时才接受。同名时返回 nil，调用方必须阻止投递，
    /// 不能拿数组第一项猜是哪台 MacBook。
    static func resolve(selector: String, among machines: [MachineInfo]) -> MachineInfo? {
        if let exact = machines.first(where: { $0.machineID == selector }) { return exact }
        let byNode = machines.filter { $0.nodeName == selector }
        if byNode.count == 1 { return byNode[0] }
        let byLegacyName = machines.filter { $0.machineName == selector }
        return byLegacyName.count == 1 ? byLegacyName[0] : nil
    }

    static func selectorIsAmbiguous(_ selector: String,
                                    among machines: [MachineInfo]) -> Bool {
        if machines.contains(where: { $0.machineID == selector }) { return false }
        let nodeMatches = machines.filter { $0.nodeName == selector }.count
        if nodeMatches > 1 { return true }
        if nodeMatches == 1 { return false }
        return machines.filter { $0.machineName == selector }.count > 1
    }

    var coordinatorStatusText: String {
        let label: String
        switch coordinatorState {
        case "idle": label = "空闲"
        case "running": label = "执行中"
        case "waiting": label = "等待资源"
        case "dispatching": label = "正在派发"
        case "paused": label = "已暂停"
        case "offline": label = "未运行"
        case "starting": label = "启动中"
        case .some(let raw): label = raw
        case nil: return "调度器：旧版本未上报状态"
        }
        let reason = coordinatorSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "调度器：" + label + (reason.isEmpty ? "" : " · " + reason)
    }

    func coordinatorNeedsAttention(now: Date = Date()) -> Bool {
        if coordinatorState == "paused" || coordinatorState == "offline" { return true }
        if let updated = coordinatorUpdatedAt,
           now.timeIntervalSince(updated) > 20 * 60 { return true }
        return false
    }

    /// 跨机器传的结构手写 decodeIfPresent:一台老 Mac 少写一个键,不能让整份 dashboard 解不出。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machineID = try c.decodeIfPresent(String.self, forKey: .machineID) ?? ""
        machineName = try c.decodeIfPresent(String.self, forKey: .machineName) ?? "未知机器"
        nodeName = try c.decodeIfPresent(String.self, forKey: .nodeName)
        maxConcurrentTasks = try c.decodeIfPresent(
            Int.self, forKey: .maxConcurrentTasks) ?? 0
        runningTaskCount = try c.decodeIfPresent(Int.self, forKey: .runningTaskCount) ?? 0
        repoAliases = try c.decodeIfPresent([String].self, forKey: .repoAliases) ?? []
        automaticRepoAliases = try c.decodeIfPresent(
            [String].self, forKey: .automaticRepoAliases) ?? []
        runningRepoAliases = try c.decodeIfPresent(
            [String].self, forKey: .runningRepoAliases) ?? []
        coordinatorState = try c.decodeIfPresent(String.self, forKey: .coordinatorState)
        coordinatorSummary = try c.decodeIfPresent(String.self, forKey: .coordinatorSummary)
        coordinatorUpdatedAt = try c.decodeIfPresent(
            Date.self, forKey: .coordinatorUpdatedAt)
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen) ?? .distantPast
        isStale = try c.decodeIfPresent(Bool.self, forKey: .isStale) ?? true
    }
}

/// 同平台不同订阅独立判断，不能让一个已用尽的账号代表所有账号。
struct QuotaPoolReport: Codable {
    var poolID: String
    var displayName: String
    var statuses: [QuotaStatus]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        poolID = try c.decodeIfPresent(String.self, forKey: .poolID) ?? ""
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? poolID
        statuses = try c.decodeIfPresent([QuotaStatus].self, forKey: .statuses) ?? []
    }
}

struct PlatformReport: Codable, Identifiable {
    var platform: String
    var planName: String
    var detected: Bool
    var installed: Bool
    /// 你在套餐配置里把它关掉了没有。关掉的不该出现在办公室里。
    /// 用可选 + 默认值兜底：旧版 Mac 端不发这个字段。
    var enabled: Bool? = true
    /// 真正干活的那个 agent 的名字。员工用这个称呼，不用模型名 ——
    /// 干活的是 CLI，模型只是它当时接的哪个端点。
    var agentName: String?
    var agentBinary: String?
    /// 岗位职责。规则只写在 Mac 的配置文件里的话，手机上就看不见
    /// 调度为什么这么派 —— 而「为什么」恰恰是这套规则唯一值得看的部分。
    var role: AgentRole?
    var lastActivity: Date?
    var statuses: [QuotaStatus]
    var quotaPools: [QuotaPoolReport]?
    var last30dRequests: Int
    var last30dBillableTokens: Int
    /// 稳定机器身份。新服务端优先发这个字段，避免两台同名 MacBook Pro
    /// 被办公室错误地合并或同时认领同一个员工。
    var machineIDs: [String] = []
    var machines: [String]
    var monthlyCost: Double?
    var currency: String?
    var last7dRequests: Int = 0

    /// 空窗统计：每个窗口长度一条。Mac 端算好发过来。
    ///
    /// **这是「浪费了多少」在没有上限时唯一站得住的口径。**
    /// 13 个额度窗口里只有 3 个有 limit，其余算不出「浪费量」——
    /// 但「这个窗口一次都没用过」跟上限是多少无关。
    var idleWindows: [IdleWindow] = []
    /// 正在冷却到什么时候、为什么。
    var cooldownUntil: Date?
    var cooldownReason: String?

    /// **空窗要不要当成「在漏」，取决于它是不是被限流了。**
    ///
    /// 实测：Kimi 连续空了 19 个 5 小时窗，看起来是「没在用」，
    /// 真相是额度用尽被限流 —— 我们试过、被拒了、退避了。
    /// 那是订阅被用满，正好是浪费的反面。
    var isCooling: Bool {
        guard let u = cooldownUntil else { return false }
        return u > Date()
    }

    var id: String { platform }

    /// **手写解码。**
    ///
    /// 合成解码器对缺键零容忍，而这个结构里 statuses / last30dRequests /
    /// machines 都是非可选。手机和 Mac 永远不可能同时更新 ——
    /// Mac 端加一个字段、手机还是旧版，或者反过来，
    /// 缺一个键就整条 report 解不出来，**那个平台从界面上静默消失**。
    /// 这个坑在 Mac 端踩过五次，这边不重蹈。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? "?"
        planName = try c.decodeIfPresent(String.self, forKey: .planName) ?? ""
        detected = try c.decodeIfPresent(Bool.self, forKey: .detected) ?? false
        installed = try c.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        agentName = try c.decodeIfPresent(String.self, forKey: .agentName)
        agentBinary = try c.decodeIfPresent(String.self, forKey: .agentBinary)
        role = try c.decodeIfPresent(AgentRole.self, forKey: .role)
        lastActivity = try c.decodeIfPresent(Date.self, forKey: .lastActivity)
        statuses = try c.decodeIfPresent([QuotaStatus].self, forKey: .statuses) ?? []
        quotaPools = try c.decodeIfPresent([QuotaPoolReport].self, forKey: .quotaPools)
        last30dRequests = try c.decodeIfPresent(Int.self, forKey: .last30dRequests) ?? 0
        last30dBillableTokens = try c.decodeIfPresent(Int.self, forKey: .last30dBillableTokens) ?? 0
        machineIDs = try c.decodeIfPresent([String].self, forKey: .machineIDs) ?? []
        machines = try c.decodeIfPresent([String].self, forKey: .machines) ?? []
        monthlyCost = try c.decodeIfPresent(Double.self, forKey: .monthlyCost)
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        last7dRequests = try c.decodeIfPresent(Int.self, forKey: .last7dRequests) ?? 0
        idleWindows = try c.decodeIfPresent([IdleWindow].self, forKey: .idleWindows) ?? []
        cooldownUntil = try c.decodeIfPresent(Date.self, forKey: .cooldownUntil)
        cooldownReason = try c.decodeIfPresent(String.self, forKey: .cooldownReason)
    }

    /// 员工名。优先用 agent 名 —— 三个「Claude Code · X」摆在一起时，
    /// 你一眼就知道干活的是同一个工具，只是额度池不同。
    var displayName: String {
        if let a = agentName, !a.isEmpty { return a }
        return PlatformNames.map[platform] ?? platform
    }
    /// 平台本身的名字。额度归属还是按平台算的，详情页要说清楚。
    var platformName: String { PlatformNames.map[platform] ?? platform }

    /// 新旧协议兼容的机器归属判定。只要服务端提供了 ID，就不能再退回同名匹配；
    /// 否则两台都叫“MacBook Pro”时，一个 agent 会被画到两台机器上。
    func isReported(on machine: MachineInfo) -> Bool {
        if !machineIDs.isEmpty { return machineIDs.contains(machine.machineID) }
        return machines.contains(machine.machineName)
    }

    /// 平台自己回报的用量里有没有非零的。
    ///
    /// 用来把「这条路子看不见它」和「它真的没在动」分开 ——
    /// MiniMax 不产生本地会话日志，last7dRequests 恒为 0，
    /// 但官方接口明明白白显示它在用。
    var hasOfficialUsage: Bool {
        statuses.contains { $0.isOfficial && $0.isCurrent && $0.hasUsageValue && $0.used > 0 }
    }

    /// 每个账号先看最紧窗口，再看是否仍有账号可用；辅助额度不参与编码能力判断。
    var headline: QuotaStatus? {
        func tightest(_ values: [QuotaStatus]) -> QuotaStatus? {
            values.filter { !$0.advisory && $0.displayUsedFraction != nil }.max {
                ($0.displayUsedFraction ?? 0) < ($1.displayUsedFraction ?? 0)
            }
        }
        guard let pools = quotaPools, !pools.isEmpty else { return tightest(statuses) }
        let heads = pools.map { pool -> QuotaStatus? in
            guard var status = tightest(pool.statuses) else { return nil }
            if pools.count > 1 { status.label = pool.displayName + " · " + status.label }
            return status
        }
        let known = heads.compactMap { $0 }
        if known.allSatisfy({ ($0.displayUsedFraction ?? 0) >= 1 }),
           heads.contains(where: { $0 == nil }) { return nil }
        return known.min { ($0.displayUsedFraction ?? 0) < ($1.displayUsedFraction ?? 0) }
    }

}

struct QuotaStatus: Codable, Identifiable {
    var platform: String
    var limitID: String
    var label: String
    var metric: String
    var used: Double
    var hasUsageValue: Bool
    var advisory: Bool
    var sourceKind: String?
    var observedAt: Date?
    var expiresAt: Date?
    var limit: Double?
    var usedFraction: Double?
    var resetsAt: Date?
    var projectedUsedFraction: Double?
    /// 没有官方上限时，历史上一个同长度窗口里确实用出去过的最大量。
    /// 这是容量下限，不是假装精确的额度上限。
    var observedFloor: Double?

    /// 预计浪费的**比例**（0–1）。显示和排序都用它，不用 projectedWaste ——
    /// 那个字段的单位是「原始计量单位」（百分比口径=百分点、次数口径=次数），
    /// 拿来当小数乘 100 显示过 9741%（2026-08-20），跨口径排序也没有意义。
    /// projectedWaste 只剩一个用途：非空 = 这窗口的浪费值得一提。
    var wasteFraction: Double {
        guard isCurrent, hasUsageValue else { return 0 }
        return max(0, 1 - (projectedUsedFraction ?? 1))
    }
    var projectedWaste: Double?
    var health: Health
    var isOfficial: Bool
    var sourceNote: String

    var id: String { platform + limitID }

    /// 手写解码:Mac 加一种健康状态 / 少写一个键,不能让整份看板消失并把人往
    /// 「选错文件夹」的方向带(对账实锤 2026-08-23)。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? ""
        limitID = try c.decodeIfPresent(String.self, forKey: .limitID) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        metric = try c.decodeIfPresent(String.self, forKey: .metric) ?? ""
        let decodedUsed = try c.decodeIfPresent(Double.self, forKey: .used)
        used = decodedUsed ?? 0
        hasUsageValue = (try c.decodeIfPresent(Bool.self, forKey: .hasUsageValue))
            ?? (decodedUsed?.isFinite == true)
        advisory = try c.decodeIfPresent(Bool.self, forKey: .advisory) ?? false
        sourceKind = try c.decodeIfPresent(String.self, forKey: .sourceKind)
        observedAt = try c.decodeIfPresent(Date.self, forKey: .observedAt)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        limit = try c.decodeIfPresent(Double.self, forKey: .limit)
        usedFraction = try c.decodeIfPresent(Double.self, forKey: .usedFraction)
        resetsAt = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
        projectedUsedFraction = try c.decodeIfPresent(Double.self, forKey: .projectedUsedFraction)
        observedFloor = try c.decodeIfPresent(Double.self, forKey: .observedFloor)
        projectedWaste = try c.decodeIfPresent(Double.self, forKey: .projectedWaste)
        health = try c.decodeIfPresent(Health.self, forKey: .health) ?? .unknown
        isOfficial = try c.decodeIfPresent(Bool.self, forKey: .isOfficial) ?? false
        sourceNote = try c.decodeIfPresent(String.self, forKey: .sourceNote) ?? ""
    }

    func isFresh(now: Date = Date()) -> Bool {
        if let deadline = expiresAt ?? resetsAt { return now <= deadline }
        return true // 旧协议没有时效字段时保留兼容；有重置时刻则仍检查。
    }

    var isCurrent: Bool { isFresh() && sourceKind != "unknown" }
    var effectiveHealth: Health { isCurrent && hasUsageValue ? health : .unknown }
    var displayUsedFraction: Double? {
        guard isCurrent, hasUsageValue, let usedFraction, usedFraction.isFinite else { return nil }
        return usedFraction
    }
    var usageText: String {
        guard hasUsageValue, sourceKind != "unknown" else { return "用量未知" }
        return (isFresh() ? "已用 " : "历史已用 ") + Fmt.metricValue(used, metric: metric)
    }

    /// 非官方经验容量必须在百分比旁边显式标明，避免用户把推算值当成平台真值。
    var estimationBadge: String? {
        guard !isOfficial, sourceNote.hasPrefix("持续学习估算") else { return nil }
        let confidence = sourceNote.split(separator: "·")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("置信度") }
        return ["经验估算", confidence].compactMap { $0 }.joined(separator: " · ")
    }

    var timeToReset: TimeInterval? {
        guard let resetsAt else { return nil }
        return max(0, resetsAt.timeIntervalSinceNow)
    }

    /// 当前还剩多少比例。只有平台直报或配置了可信上限时才有答案。
    var remainingFraction: Double? {
        guard let usedFraction = displayUsedFraction else { return nil }
        return max(0, 1 - usedFraction)
    }

    /// 按当前烧速，到重置时预计还剩多少比例。
    var projectedRemainingFraction: Double? {
        guard isCurrent, hasUsageValue, let projectedUsedFraction,
              projectedUsedFraction.isFinite else { return nil }
        return max(0, 1 - projectedUsedFraction)
    }

    /// 有绝对额度时，给出原始计量单位下的剩余量（次数、token 等）。
    var remainingValue: Double? {
        guard isCurrent, hasUsageValue, metric != "percent",
              let limit, limit.isFinite, used.isFinite else { return nil }
        return max(0, limit - used)
    }

    /// 历史峰值未绑定当前套餐权益，不能换算成当前保证可用的余量。
    var minimumRemainingValue: Double? { nil }
}

enum Health: String, Codable {
    case unconfigured, idle, wasting, healthy, atRisk, exhausted
    /// Mac 端新加的、这版手机还不认识的状态。不能因为它让整份看板解不出来。
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Health(rawValue: raw) ?? .unknown
    }

    var displayName: String {
        switch self {
        case .unknown: return "未知状态"
        case .unconfigured: return "未配上限"
        case .idle: return "闲置"
        case .wasting: return "将作废"
        case .healthy: return "正常"
        case .atRisk: return "烧速预警"
        case .exhausted: return "已用尽"
        }
    }

    /// 数字越大越该被顶到前面。
    var urgency: Int {
        switch self {
        case .healthy: return 0
        case .unknown: return 0
        case .unconfigured: return 1
        case .exhausted: return 2
        case .atRisk: return 3
        case .idle: return 4
        case .wasting: return 5
        }
    }
}

// MARK: - 现在在跑什么

/// 一件任务的摘要。看板顶层 `tasks` 数组里的一条。
///
/// **和 `TaskResult` 不是一回事**：`TaskResult` 是 outbox 里的**回执**，
/// 只有跑完了才有，而且带完整 prompt；这个是 Mac 端每次采集时对
/// **此刻任务库**的快照，跑到一半的、还在排队的、卡住的都在里面。
/// 用户说的「看不到现在进行中的任务」缺的正是后者 ——
/// 回执再全，也回答不了「现在在干嘛」。
///
/// 这份东西走 iCloud 同步到手机，所以字段刻意少、刻意短。
extension TaskBrief {
    /// 提示词的前 `lines` 行(去掉空行),给卡片当摘要。
    ///
    /// 续活任务的提示词里注了整份目标文档(PLAN.md 全文,六千字上限),
    /// 摊进验收卡片就是一堵墙 —— 老板要的是看图,不是读文档。
    static func headline(of prompt: String, lines: Int) -> String {
        let kept = prompt.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(lines)
        return kept.joined(separator: "\n")
    }

    static func hasMore(_ prompt: String, lines: Int) -> Bool {
        prompt.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count > lines
    }
}

struct TaskBrief: Codable, Identifiable, Sendable {
    /// Mac 端给这条任务的编号。**它是 UUID 的前 8 位，跨机器不保证唯一。**
    ///
    /// 所以它只在**一台机器内部**算身份。跨机器的身份是 `id`，
    /// 也就是 `(machineID, taskID)` —— 只按这个编号去重的话，
    /// 两台机器撞上同一个前缀时，一台的活会把另一台的活整条盖掉，
    /// 而屏幕上不会有任何迹象。这正是这次要修的那个 bug 的翻版。
    var taskID: String
    /// 给人看的一句话。**不是 prompt 原文**，见 `clampTitle`。
    var title: String
    /// queued / running / done / failed / blocked。
    /// 存字符串不存枚举：Mac 端将来加一种状态时，
    /// 枚举解码会连带整条任务一起丢掉，而丢掉的很可能正是新状态里最要紧的那种。
    var state: String
    var waitReason: String?
    var landedAt: Date?
    /// 还没派出去的时候没有。
    var platform: String?
    /// 哪台机器在跑。办公室里同一个平台可能坐两台机器上，靠它对号入座。
    var machineName: String
    var startedAt: Date?
    /// Mac 端记的「跑了多久」。注意这是**快照那一刻**的值。
    var elapsedSeconds: Double?
    var graphID: String?
    var stepIndex: Int?
    var stepTotal: Int?
    var repoAlias: String?
    /// Agent 最近一次可核验里程碑。Mac 端会在每次汇报时立即重发任务板。
    var progressPhase: String?
    var progressSummary: String?
    var progressNextStep: String?
    var progressUpdatedAt: Date?
    var progressEvidenceCount: Int?

    // MARK: - 出身（不从 JSON 解，是合并那一步填进来的）

    /// 这条任务来自哪块板子 —— `taskboards/<machineID>.json` 文件名那一段。
    ///
    /// 空 = 从老路 `dashboard.tasks` 读来的。那条路上根本没有机器 ID，
    /// 因为那份数据本来就只可能属于最后一台写 dashboard.json 的机器。
    var machineID: String = ""
    /// 它所在那块板子有多新。见 `Freshness`。
    ///
    /// **默认 `.live` 只对「刚读到的板子」成立**，所以合并那一步必须显式赋值；
    /// 忘了赋值的后果是把一台离线机器上的 running 当成实时的在跑 —— 撒谎。
    var freshness: Freshness = .live

    /// 这条任务此刻还该不该当真。
    ///
    /// **终态不受板子新旧影响**：一件三小时前 done 的任务，现在还是 done。
    /// 会随时间失真的只有 running / queued / blocked ——
    /// 它们描述的是「此刻正在发生」，而板子已经不代表此刻了。
    var isFromColdBoard: Bool { freshness != .live && !isTerminal }

    /// **跨机器的身份。** 见 `taskID` 上那段。
    ///
    /// 分隔符用 U+0001 而不是 `|`：机器 ID 里出现竖线的概率不高，
    /// 但一旦出现，`a|b` + `c` 和 `a` + `b|c` 会撞成同一个 id，
    /// 而那种碰撞查起来能查一天。控制字符不可能出现在这两个字段里。
    var id: String {
        machineID.isEmpty ? taskID : machineID + "\u{1}" + taskID
    }

    /// **显式 CodingKeys。**
    ///
    /// 两个理由：
    /// 1. `taskID` 在 JSON 里叫 `id`（Mac 端的字段名），名字对不上；
    /// 2. `machineID` / `freshness` 是合并时填的，**不该从 JSON 里解**，
    ///    也不该被编码出去。不列进来就自动跳过。
    enum CodingKeys: String, CodingKey {
        case taskID = "id"
        case title, state, waitReason, landedAt, platform, machineName, startedAt
        case elapsedSeconds, graphID, stepIndex, stepTotal, repoAlias
        case progressPhase, progressSummary, progressNextStep
        case progressUpdatedAt, progressEvidenceCount
    }

    /// 一块任务板有多新。**「不知道」是独立取值，不能塌进「新鲜」里。**
    enum Freshness: Sendable, Equatable {
        /// 板子刚更新过，上面写的就是此刻。
        case live
        /// 板子太久没更新了（超过 `TaskDigest.staleAfter`）。
        /// 带的是它有多旧 —— 界面上要说「N 分钟前的状态」，得有这个数。
        case stale(TimeInterval)
        /// 板子没说自己什么时候生成的。新旧不知道，
        /// **所以一样不能当实时** —— 不知道就是不知道。
        case unknown
    }

    enum Known: String {
        case queued, running, done, failed, blocked
    }
    /// 认得出来的状态；认不出来就是 nil（不是「不存在」）。
    var known: Known? { Known(rawValue: state) }

    var isRunning: Bool { known == .running }
    var isQueued: Bool { known == .queued }
    var isBlocked: Bool { known == .blocked }
    var isTerminal: Bool { known == .done || known == .failed }

    var stateLabel: String {
        switch known {
        case .queued:  return "排队中"
        case .running: return "在跑"
        case .done:
            if landedAt != nil || progressPhase == "已合入 main" { return "已合入" }
            return progressPhase == "等待合入" ? "等待合入" : "执行已结束"
        case .failed:  return "失败"
        case .blocked:
            if progressPhase == "系统诊断中" { return "系统诊断中" }
            switch waitReason {
            case "humanAnswer": return "等待你的答复"
            case "humanApproval": return "等待你的确认"
            case "architectureReview": return "等待架构复核"
            case "productionGate": return "等待质量复验"
            case "ownerUnavailable": return "等待原负责人恢复"
            case "dependency": return "等待上游任务"
            case "paused": return "已暂停"
            default: return "等待处理"
            }
        // 认不出来的状态**原样显示**。写成「未知」等于把 Mac 端刚加的
        // 那种状态藏起来，而新状态多半是因为出了新情况才加的。
        case nil:      return state.isEmpty ? "状态不明" : state
        }
    }

    /// 属于一张任务图的第几步。单步任务没有。
    var stepText: String? {
        guard let i = stepIndex, let n = stepTotal, n > 1 else { return nil }
        return "第 \(i + 1)/\(n) 步"
    }

    /// 已经跑了多久，以及这个数**是不是活的**。
    ///
    /// - 有 `startedAt`：按现在算，一直是准的。
    /// - 只有 `elapsedSeconds`：那是快照那一刻的值，**不外推**。
    ///   外推等于假设它到现在还在跑，而快照可能是 15 分钟前的 ——
    ///   界面上多出来的那 15 分钟没有任何依据。
    var elapsed: (seconds: TimeInterval, live: Bool)? {
        if isRunning, freshness == .live, let s = startedAt {
            return (max(0, Date().timeIntervalSince(s)), true)
        }
        if let e = elapsedSeconds, e.isFinite, e >= 0 { return (e, false) }
        return nil
    }

    var elapsedText: String? {
        guard let e = elapsed else { return nil }
        // 板子已经冷了的时候，「已 3 小时」这句话是**外推**出来的 ——
        // startedAt 还在，Date() 也照走，但那台机器可能半小时前就关机了。
        // 换成「板子上写着已 3 小时」，句子里就带上了它的依据。
        if isFromColdBoard {
            return "板子上写着已 " + Fmt.elapsed(e.seconds)
        }
        return (e.live ? "已 " : "快照时已 ") + Fmt.elapsed(e.seconds)
    }

    var progressHeadline: String? {
        let phase = progressPhase?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary = progressSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !phase.isEmpty || !summary.isEmpty else { return nil }
        if phase.isEmpty { return summary }
        if summary.isEmpty { return phase }
        return phase + " · " + summary
    }

    var progressAgeText: String? {
        guard let at = progressUpdatedAt else { return nil }
        let age = max(0, Date().timeIntervalSince(at))
        if age < 60 { return "刚刚汇报" }
        return Fmt.duration(age) + "前汇报"
    }

    /// 「<机器名> N 分钟前的状态」。
    ///
    /// 冷板子上的任务**必须带着这句话出现**，不能光挪个位置了事：
    /// 一条挪到别的区块里的 running，只要文字还写着「在跑」，
    /// 读的人照样会当成此刻在跑。
    var coldLabel: String? {
        let who = machineName.isEmpty ? "这台"
            : machineLabelForDisplay(machineName, machineID: machineID)
        switch freshness {
        case .live: return nil
        case .stale(let age): return "\(who) \(Fmt.duration(age))前的状态"
        case .unknown: return "\(who) 的板子没说是什么时候的"
        }
    }

    /// 标题**按字截，不按字节截**。
    ///
    /// 按字节截中文会切在一个 UTF-8 序列中间，界面上就是一串乱码方块；
    /// Swift 的 `prefix` 走的是字符（grapheme cluster），emoji 和
    /// 组合字也不会被劈开。
    ///
    /// Mac 端已经截过一次，这里再截一次不是多余：手机不该假设发过来的东西
    /// 一定守规矩 —— 一条几千字的 prompt 混进 title，会把整块界面顶开。
    /// 顺手只取第一行，prompt 首行之后的内容常常是仓库路径这类不该上屏的东西。
    static func clampTitle(_ raw: String) -> String {
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let t = firstLine.trimmingCharacters(in: .whitespaces)
        guard t.count > 80 else { return t }
        return String(t.prefix(79)) + "…"
    }

    /// **手写解码。** 缺一个键就丢一条任务，而丢掉的可能正是在跑的那条。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = TaskBrief.clampTitle(try c.decodeIfPresent(String.self, forKey: .title) ?? "")
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        waitReason = try c.decodeIfPresent(String.self, forKey: .waitReason)
        landedAt = try c.decodeIfPresent(Date.self, forKey: .landedAt)
        platform = try c.decodeIfPresent(String.self, forKey: .platform)
        machineName = try c.decodeIfPresent(String.self, forKey: .machineName) ?? ""
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        elapsedSeconds = try c.decodeIfPresent(Double.self, forKey: .elapsedSeconds)
        graphID = try c.decodeIfPresent(String.self, forKey: .graphID)
        stepIndex = try c.decodeIfPresent(Int.self, forKey: .stepIndex)
        stepTotal = try c.decodeIfPresent(Int.self, forKey: .stepTotal)
        repoAlias = try c.decodeIfPresent(String.self, forKey: .repoAlias)
        progressPhase = try c.decodeIfPresent(String.self, forKey: .progressPhase)
        progressSummary = try c.decodeIfPresent(String.self, forKey: .progressSummary)
        progressNextStep = try c.decodeIfPresent(String.self, forKey: .progressNextStep)
        progressUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .progressUpdatedAt)
        progressEvidenceCount = try c.decodeIfPresent(Int.self, forKey: .progressEvidenceCount)
        // id 缺了也得有个**稳定**的身份：用 UUID 的话每次刷新都算新的一行，
        // ForEach 会把整块重建，滚动位置和动画全丢。
        let raw = try c.decodeIfPresent(String.self, forKey: .taskID)
        taskID = (raw?.isEmpty == false) ? raw! : (machineName + "|" + state + "|" + title)
    }
}

// MARK: - 按机器分的任务板

/// `taskboards/<machineID>.json` 的整个内容。
///
/// ## 为什么任务不能只放在 dashboard.json 里
///
/// `dashboard.json` 在 iCloud 上是**一个文件、每台机器都往里写**。
/// 每条任务身上虽然带着 `machineName`，但整份 `tasks` 数组永远是
/// **最后一台跑采集的机器**那一刻的内容 —— 另一台的活压根不在里面。
/// 两台机器同时干活时，手机上的任务会随着谁最后采集**整批切换**，
/// 而屏幕上没有任何东西提示你刚才那批去哪了。
///
/// 快照（`snapshots/<machineID>.json`）早就是按机器分文件再合并的，
/// 任务这条路照抄那个模式：一台机器一个文件，谁也盖不掉谁。
struct TaskBoardFile: Codable, Sendable {
    var machineID: String
    var machineName: String
    /// 这块板子什么时候生成的。
    ///
    /// **可选，而且缺了就是 nil，不给默认值。** 这个时间是判断
    /// 「板子上写的还算不算此刻」的唯一依据 —— 编一个 `Date()` 出来，
    /// 等于把一块来路不明的板子盖章成新鲜的。
    var generatedAt: Date?
    var tasks: [TaskBrief]
    var tasksTruncated: Bool
    /// Mac 明确设置的本机项目作用域。旧版缺失时为 nil。
    var focusedRepoAlias: String?

    /// 这台机器的计划清单（人排的、还没放行的）。
    ///
    /// **nil 和 [] 是两句话**：nil = 这台 Mac 版本旧、没发这份数据；
    /// [] = 发了，但确实一条计划都没有。混成一个的话，
    /// 老 Mac 会被显示成「没有计划」—— 那是假话。
    var planned: [PlannedBrief]?

    struct PlannedBrief: Codable, Sendable, Identifiable {
        var id: String
        var title: String
        var repoAlias: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            repoAlias = try c.decodeIfPresent(String.self, forKey: .repoAlias)
        }
    }

    /// **手写解码。** 和这个文件里其它结构同一个理由：合成解码器对缺键
    /// 零容忍，`tasks` / `tasksTruncated` 都是非可选，缺一个键就整块板子
    /// 解不出来 —— 那台机器的活会**整台消失**，而这正是要修的病。
    /// 属性上写默认值救不了：合成解码器根本不看默认值。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machineID = try c.decodeIfPresent(String.self, forKey: .machineID) ?? ""
        machineName = try c.decodeIfPresent(String.self, forKey: .machineName) ?? ""
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt)
        focusedRepoAlias = try c.decodeIfPresent(String.self, forKey: .focusedRepoAlias)
        planned = try c.decodeIfPresent([PlannedBrief].self, forKey: .planned)
        tasks = try c.decodeIfPresent([TaskBrief].self, forKey: .tasks) ?? []
        tasksTruncated = try c.decodeIfPresent(Bool.self, forKey: .tasksTruncated) ?? false
    }
}

/// 读一块板子的结果。**「读不到」是一个取值，不是空数组。**
///
/// 这个区分是硬要求：某台机器的板子读不动（iCloud 没响应、只同步了一半、
/// 还是个占位符）跟「那台机器确实没有任务」，屏幕上必须长得不一样 ——
/// 前者要你去看同步，后者什么都不用做。这个项目在别的地方已经犯过三次
/// 「把读不到说成没有」的错。
struct TaskBoardLoad: Sendable {
    var machineID: String
    var machineName: String
    var generatedAt: Date?
    var tasks: [TaskBrief] = []
    var truncated: Bool = false
    var focusedRepoAlias: String?
    /// 读不到 / 解不出来的原因。有值时 `tasks` 是空的，
    /// 但那个空**读作「不知道」**。
    var unreadable: String?
    /// 这台机器的计划清单。nil = 那台 Mac 版本旧、没发这份数据。
    var planned: [TaskBoardFile.PlannedBrief]?
    /// 这份不是从 `taskboards/` 来的，是从 `dashboard.tasks` 退回读的。
    /// 老 Mac（还没有按机器分板子的版本）走这条路。
    var isFallback: Bool = false
}

/// 一块板子在界面上的处境。`TaskDigest` 把每台机器的下场都留着，
/// 好让界面能对**每一台**分别说清楚：在跑、离线了、还是读不到。
struct BoardStatus: Sendable, Identifiable {
    var machineID: String
    var machineName: String
    var generatedAt: Date?
    /// nil = 读到了。
    var unreadable: String?
    /// 板子多久没更新了。`generatedAt` 缺失时 nil（不知道）。
    var ageSeconds: TimeInterval?
    /// 板子冷了或者来路不明 —— 上面的 running 别当实时看。
    var isCold: Bool
    /// 这块板子贡献了几条还没进终态的任务。
    /// **读不到时是 nil，不是 0** —— 0 是「这台没活」，nil 是「不知道」。
    var liveCount: Int?
    var isFallback: Bool
    var id: String { machineID.isEmpty ? "\u{1}fallback" : machineID }

    /// 机器名没读到时退回机器 ID：说「有一台读不到」没法让人去哪台上查，
    /// 说「C15DF1AA… 读不到」至少还认得出是哪一台。
    var displayName: String {
        if !machineName.isEmpty {
            return machineLabelForDisplay(machineName, machineID: machineID)
        }
        if !machineID.isEmpty { return String(machineID.prefix(8)) }
        return "这台 Mac"
    }

    var ageText: String? { ageSeconds.map { Fmt.duration($0) } }
}

/// 任务列表算好之后的现成结论。
///
/// **在后台线程算好再交给界面。** 界面上要的是「谁在跑什么」「排了几个」，
/// 每次重绘都去 60 条里筛一遍是白烧主线程 —— 而这个 App 今天正是
/// 因为主线程干了不该干的事卡死过。
struct TaskDigest: Sendable {
    /// 板子多久没更新就不能再当「此刻」用。
    ///
    /// 采集默认 15 分钟一轮，所以 30 分钟 = **两轮没到**。
    /// 一轮没到可能只是 iCloud 慢了半拍，两轮没到基本就是那台机器
    /// 睡了、关了、或者 llmq 掉了 —— 那时候板子上挂着的 running
    /// 多半早就不在跑，照原样显示就是撒谎。
    static let staleAfter: TimeInterval = 30 * 60
    static let futureTolerance: TimeInterval = 5 * 60

    /// 到底有没有读到过任何一份任务数据。false 时下面所有数组都是空的，
    /// 但那个空**不能读作「没有任务」**。
    let published: Bool
    /// Mac 端砍过条数。界面上任何「一共 N 件」都得跟着这个字打折。
    let truncated: Bool

    // 下面四个只装**来自还热着的板子**的任务。冷板子上的活在 `cold` 里，
    // 混进来的话「正在干」这三个字就成了假话。
    let running: [TaskBrief]
    let blocked: [TaskBrief]
    let queued: [TaskBrief]
    /// 最近的终态（done/failed）。Mac 端只发最近若干条。
    ///
    /// **终态不分冷热**：一件三小时前 done 的任务，板子再旧它也还是 done。
    /// 会随时间失真的只有「正在发生」那几种状态。
    let finished: [TaskBrief]
    /// 状态字符串认不出来的。**单独留着而不是丢掉** ——
    /// 丢掉的话手机比 Mac 少几条任务，而少了谁完全无从查起。
    let unrecognized: [TaskBrief]
    /// 冷板子上还没进终态的任务。
    ///
    /// 它们**要显示**（那台机器上确实挂着这些活），但要带着
    /// 「N 分钟前的状态」出现，而不是混进「正在干」里冒充实时。
    let cold: [TaskBrief]

    /// 每台机器那块板子的处境。界面靠它对**每一台**分别交代。
    let boards: [BoardStatus]

    /// 原始板子（含计划清单）。计划页要按机器分组、逐条放行，
    /// BoardStatus 那份摘要不带 planned，这里保留原始输入。
    let rawBoards: [TaskBoardLoad]

    /// 读不到的板子。**这些机器上有没有活，此刻是「不知道」**，
    /// 跟「那台没有活」是两回事。
    var unreadableBoards: [BoardStatus] { boards.filter { $0.unreadable != nil } }
    /// 读到了但已经冷掉的板子。
    var coldBoards: [BoardStatus] { boards.filter { $0.unreadable == nil && $0.isCold } }

    /// 需要人关心的那些：在跑 + 卡住 + 排队。终态不算，冷的也不算。
    var live: [TaskBrief] { running + blocked + queued }
    struct DeliveryStatus {
        var running: Int
        var diagnosing: Int
        var qualityWaiting: Int
        var mergeWaiting: Int
        var landed: Int
    }
    /// 当前任务与最近终态的快照计数，不把有限条数当成累计交付率。
    var deliveryStatus: DeliveryStatus {
        DeliveryStatus(running: running.count,
            diagnosing: blocked.filter { $0.progressPhase == "系统诊断中" }.count,
            qualityWaiting: blocked.filter { $0.waitReason == "productionGate" }.count,
            mergeWaiting: finished.filter { $0.known == .done && $0.landedAt == nil && $0.progressPhase == "等待合入" }.count,
            landed: finished.filter { $0.landedAt != nil || $0.progressPhase == "已合入 main" }.count)
    }
    var hasAnythingLive: Bool { !live.isEmpty || !unrecognized.isEmpty }
    /// 这一块到底有没有话要说 —— 活的任务、冷板子上挂着的活、
    /// 或者干脆有板子读不到。三种都值得占地方。
    var hasAnythingToSay: Bool {
        hasAnythingLive || !cold.isEmpty || !unreadableBoards.isEmpty
    }

    /// 这台机器那块板子怎么了。办公室里按机器分节，
    /// 一台机器的桌子全空着时，得能说出是「他们真闲着」还是「板子冷了」。
    ///
    /// **先按 machineID 查。** 一块读不到的板子只剩文件名，
    /// 也就是只剩 machineID —— 机器名在文件里面，而文件正是打不开的那个。
    /// 只按机器名查的话，最需要被指出来的那种情况恰好查不到，
    /// 于是那一节桌子会安安静静地空着，看起来像「他们闲着」。
    func board(machineID: String, machineName: String = "") -> BoardStatus? {
        if !machineID.isEmpty, let b = boardByMachineID[machineID] { return b }
        guard !machineName.isEmpty else { return nil }
        return boardByMachineName[machineName]
    }
    private let boardByMachineID: [String: BoardStatus]
    private let boardByMachineName: [String: BoardStatus]

    /// 桌位查询用的索引。键是**稳定 machineID + 平台**；只有旧任务确实
    /// 没有 ID 时才退回机器名。
    /// 只按平台建索引的话，同一个平台装在两台机器上时，
    /// A 机器的活会画到 B 机器的桌子上 —— 而且看起来毫无破绽。
    private let runByDesk: [String: TaskBrief]
    private let runByPlatform: [String: TaskBrief]
    private let blockByDesk: [String: TaskBrief]
    private let blockByPlatform: [String: TaskBrief]
    private let queueByDesk: [String: Int]
    private let queueByPlatform: [String: Int]

    static func deskKey(machineID: String, machineName: String, platform: String) -> String {
        let machine = machineID.isEmpty ? "name:" + machineName : "id:" + machineID
        return machine + "|" + platform
    }

    /// 这个工位上正在跑的活。
    ///
    /// `machine` 给了就**只**按机器 + 平台精确匹配，不做退化 ——
    /// 退化到「这个平台在别处的活」等于把另一台机器的活画到这张桌子上，
    /// 那比空着更糟。机器对不上的任务不会消失：「现在」页列的是全量。
    func running(platform: String, machineID: String?, machineName: String?) -> TaskBrief? {
        if let id = machineID, !id.isEmpty {
            return runByDesk[Self.deskKey(
                machineID: id, machineName: machineName ?? "", platform: platform)]
        }
        if let name = machineName, !name.isEmpty {
            return runByDesk[Self.deskKey(
                machineID: "", machineName: name, platform: platform)]
        }
        return runByPlatform[platform]
    }

    /// 这个工位上卡住的活。
    ///
    /// 卡住的也得画在桌上：它**看起来**和「闲着」一模一样，
    /// 而实际上它是唯一一种在等人的状态。头顶的问号只在
    /// questions/ 里有对应文件时才冒出来，那份文件可能还没同步过来。
    func blocked(platform: String, machineID: String?, machineName: String?) -> TaskBrief? {
        if let id = machineID, !id.isEmpty {
            return blockByDesk[Self.deskKey(
                machineID: id, machineName: machineName ?? "", platform: platform)]
        }
        if let name = machineName, !name.isEmpty {
            return blockByDesk[Self.deskKey(
                machineID: "", machineName: name, platform: platform)]
        }
        return blockByPlatform[platform]
    }

    /// 桌上该写哪一件。在跑的优先 —— 手头正动着的那件比卡住的更能说明「现在」。
    func onDesk(platform: String, machineID: String?, machineName: String?) -> TaskBrief? {
        running(platform: platform, machineID: machineID, machineName: machineName)
            ?? blocked(platform: platform, machineID: machineID, machineName: machineName)
    }

    func queuedCount(platform: String, machineID: String?, machineName: String?) -> Int {
        if let id = machineID, !id.isEmpty {
            return queueByDesk[Self.deskKey(
                machineID: id, machineName: machineName ?? "", platform: platform)] ?? 0
        }
        if let name = machineName, !name.isEmpty {
            return queueByDesk[Self.deskKey(
                machineID: "", machineName: name, platform: platform)] ?? 0
        }
        return queueByPlatform[platform] ?? 0
    }

    /// 没有任务数据（老 Mac、还没读到任何东西、或者还没连上文件夹）。
    static let unpublished = TaskDigest(boards: [])

    // **故意没有 `init(tasks:truncated:)` 这个便利入口。**
    //
    // 它看着无害，但少了 `generatedAt` 这一项 —— 而少了它就等于说
    //「这批任务什么时候的不知道」，于是每条都会被判成冷的。
    // 调用方十有八九手上是有那个时间的（`dashboard.generatedAt`），
    // 只是被这个签名劝着不去传。老路（`dashboard.tasks`）现在也包成
    // 一块 `TaskBoardLoad` 走下面这个入口，时间必须显式给出来。

    /// **多台机器合并。**
    ///
    /// 三条规则，每条都是为了修一个具体的谎：
    ///
    /// 1. 去重按 `(machineID, taskID)`。任务编号是 UUID 前 8 位，
    ///    跨机器会撞 —— 只按编号去重会让一台的活**整条盖掉**另一台的，
    ///    而且盖得毫无痕迹。
    /// 2. 冷板子的活单独放。一份 30 分钟没更新的板子上挂着的 running，
    ///    多半早就不在跑了；把它算进「正在干」就是在编。
    /// 3. 排序全序。有一处并列没定死，两台机器返回的先后一变，
    ///    整个列表就会跳一下 —— 而人会以为是数据变了。
    init(boards input: [TaskBoardLoad], now: Date = Date()) {
        self.rawBoards = input
        // 至少读到过一块板子（哪怕它是空的），才谈得上「知道」。
        // 全都读不到时 published 是 false —— 界面于是说「不知道」，
        // 而不是理直气壮地说「没有任务」。
        published = input.contains { $0.unreadable == nil }
        truncated = input.contains { $0.truncated }

        // 板子之间先定个序：合并结果里同名同状态的任务谁在前，
        // 不能取决于 `contentsOfDirectory` 这次返回的顺序。
        let ordered = input.sorted {
            ($0.machineName, $0.machineID) < ($1.machineName, $1.machineID)
        }

        var statuses: [BoardStatus] = []
        var merged: [TaskBrief] = []
        var seen = Set<String>()

        for b in ordered {
            let rawAge = b.generatedAt.map { now.timeIntervalSince($0) }
            let age = rawAge.flatMap { $0 >= -Self.futureTolerance ? max(0, $0) : nil }
            let freshness: TaskBrief.Freshness
            switch (rawAge, age) {
            case (_, let a?) where a > Self.staleAfter: freshness = .stale(a)
            case (_, .some): freshness = .live
            // 板子没说自己什么时候生成的 —— 新旧不知道，不能当实时。
            default: freshness = .unknown
            }

            var liveCount = 0
            if b.unreadable == nil {
                // 热更新窗口里，旧 Mac worker 可能仍会把别的项目留下的
                // blocked / queued 一并发来。同一块板子已经明确只有一个项目
                // 在真实运行时，那些旧项不能再冒充「当前协作」。
                //
                // 真有两个项目同时 running 时一条也不藏：那是需要暴露的
                // 作用域异常，不能为了界面干净而掩盖事实。
                let runningRepos = Set(b.tasks.compactMap { task -> String? in
                    guard task.isRunning, let alias = task.repoAlias else { return nil }
                    let normalized = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    return normalized.isEmpty ? nil : normalized
                })
                let declaredRepo = b.focusedRepoAlias?
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let soleRunningRepo = (declaredRepo?.isEmpty == false ? declaredRepo : nil)
                    ?? (runningRepos.count == 1 ? runningRepos.first : nil)
                for var t in b.tasks {
                    if let soleRunningRepo,
                       t.isBlocked || t.isQueued,
                       let alias = t.repoAlias?.trimmingCharacters(
                        in: .whitespacesAndNewlines).lowercased(),
                       !alias.isEmpty, alias != soleRunningRepo {
                        continue
                    }
                    t.machineID = b.machineID
                    // 板子头上的机器名是文件级的事实，比每条任务里那个更可信；
                    // 但任务自己写了名字就别覆盖 —— 老 Mac 只在任务里写。
                    if t.machineName.isEmpty { t.machineName = b.machineName }
                    t.freshness = freshness
                    // **这里就是修 bug 的那一行。** 见上面第 1 条。
                    guard seen.insert(t.id).inserted else { continue }
                    if !t.isTerminal { liveCount += 1 }
                    merged.append(t)
                }
            }

            statuses.append(BoardStatus(
                machineID: b.machineID,
                machineName: b.machineName,
                generatedAt: b.generatedAt,
                unreadable: b.unreadable,
                ageSeconds: age,
                isCold: freshness != .live,
                // 读不到时是 nil，不是 0。0 会被读成「这台没活」。
                liveCount: b.unreadable == nil ? liveCount : nil,
                isFallback: b.isFallback))
        }
        boards = statuses
        var nameIndex: [String: BoardStatus] = [:]
        var idIndex: [String: BoardStatus] = [:]
        for s in statuses {
            // 同名机器（改过名、或者真撞名）时留先出现的那块：
            // 顺序已经定死，所以这个选择每次都一样。
            if !s.machineName.isEmpty, nameIndex[s.machineName] == nil {
                nameIndex[s.machineName] = s
            }
            if !s.machineID.isEmpty, idIndex[s.machineID] == nil {
                idIndex[s.machineID] = s
            }
        }
        boardByMachineName = nameIndex
        boardByMachineID = idIndex

        // 顺序不指望 Mac 端排好。约定里写了排法，但手机自己再排一次
        // 才不会因为对面一次改动就把「在跑的」挤到列表底下去。
        let all = merged.sorted(by: TaskDigest.before)

        // 冷板子上的活抽出来单放。**终态不抽** —— 见 `finished` 上那段。
        cold = all.filter(\.isFromColdBoard)
        running = all.filter { $0.isRunning && !$0.isFromColdBoard }
        blocked = all.filter { $0.isBlocked && !$0.isFromColdBoard }
        queued = all.filter { $0.isQueued && !$0.isFromColdBoard }
        finished = all.filter(\.isTerminal)
        unrecognized = all.filter { $0.known == nil && !$0.isFromColdBoard }

        var byDesk: [String: TaskBrief] = [:]
        var byPlatform: [String: TaskBrief] = [:]
        var bDesk: [String: TaskBrief] = [:]
        var bPlatform: [String: TaskBrief] = [:]
        var qDesk: [String: Int] = [:]
        var qPlatform: [String: Int] = [:]
        for t in running {
            guard let p = t.platform, !p.isEmpty else { continue }
            let key = Self.deskKey(
                machineID: t.machineID, machineName: t.machineName, platform: p)
            byDesk[key] = byDesk[key] ?? t
            byPlatform[p] = byPlatform[p] ?? t
        }
        for t in blocked {
            guard let p = t.platform, !p.isEmpty else { continue }
            let key = Self.deskKey(
                machineID: t.machineID, machineName: t.machineName, platform: p)
            bDesk[key] = bDesk[key] ?? t
            bPlatform[p] = bPlatform[p] ?? t
        }
        for t in queued {
            // 排队的任务多半还没派人，platform 是 nil —— 那种进不了工位索引，
            // 只会出现在「现在」页的总数里。这是对的：还不知道派给谁。
            guard let p = t.platform, !p.isEmpty else { continue }
            qDesk[Self.deskKey(
                machineID: t.machineID, machineName: t.machineName, platform: p), default: 0] += 1
            qPlatform[p, default: 0] += 1
        }
        runByDesk = byDesk
        runByPlatform = byPlatform
        blockByDesk = bDesk
        blockByPlatform = bPlatform
        queueByDesk = qDesk
        queueByPlatform = qPlatform
    }

    /// 排序：状态 → 机器名 → 时间 → 编号。
    ///
    /// ## 为什么必须是**全序**
    ///
    /// 合并多台机器之后，同一档里并列的任务变多了（两台机器各有一件
    /// 刚开跑的活是常态）。只要有一处并列没定死，`contentsOfDirectory`
    /// 这次返回的目录顺序一变，列表就会跳一下 —— 而跳动看起来
    /// 完全像「数据变了」，人会去找根本不存在的变化。
    /// 所以最后一级用 `id` 兜底：它是 `(machineID, taskID)`，一定不并列。
    ///
    /// ## 状态档次
    ///
    /// running → queued → blocked → 认不出来的 → 终态，按契约。
    ///
    /// 注意这**不是**「现在」页上看到的顺序：那一页读的是
    /// `live`（= running + blocked + queued），把「卡住的」提到了
    /// 「排队的」前面，因为卡住是唯一一种**在等人**的状态，
    /// 压在一堆排队的下面等于把唯一需要你动手的那条藏起来。
    /// 两处各管各的：这里定的是同一档内部的次序，那里定的是档次先后。
    private static func before(_ a: TaskBrief, _ b: TaskBrief) -> Bool {
        func rank(_ t: TaskBrief) -> Int {
            switch t.known {
            case .running: return 0
            case .queued:  return 1
            case .blocked: return 2
            case nil:      return 3
            case .done, .failed: return 4
            }
        }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        // 同状态内先按机器名聚在一起：两台机器的活交错排列时，
        // 读的人得一行一行去看机器名才知道哪件是哪台的。
        if a.machineName != b.machineName { return a.machineName < b.machineName }
        // 再按时间。同一档里新的在前；没有时间的排最后 ——
        // 排不出先后就别硬排。
        switch (a.startedAt, b.startedAt) {
        case let (x?, y?) where x != y: return x > y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.id < b.id
        }
    }
}

/// Mac 端回写的任务状态。
struct TaskResult: Codable, Identifiable {
    var taskID: String
    var state: String
    var note: String
    var prompt: String
    var platform: String?
    var branch: String?
    var changedFiles: Int?
    var updatedAt: Date
    var id: String { taskID }

    var isDone: Bool { state == "done" }
    var isFailed: Bool { state == "failed" }
    var isRunning: Bool { state == "running" }
}

/// 手机把任务写进共享收件箱后立即得到的本地回执。
///
/// 这只证明文件写成功，不冒充 Mac 已经领取。领取状态由收件箱文件是否仍在，
/// 任务状态则继续以 outbox 的 `TaskResult` 为准。
struct SubmissionReceipt: Identifiable {
    var requestID: String
    var filename: String
    var submittedAt: Date
    var prompt: String
    var repo: String?
    var platform: String?
    var machineID: String?
    var machineName: String?

    var id: String { requestID }
    var shortID: String { String(requestID.prefix(8)).uppercased() }
}

struct RepoItem: Codable, Identifiable {
    var alias: String
    var isDefault: Bool
    /// 这个仓库在哪几台机器上有目录(来自 config/repos.json 的 pathByMachine)。
    /// 空 = 老数据没带,界面按「不知道」处理,别写成「哪台都没有」。
    var machines: [String] = []
    var id: String { alias }

    enum CodingKeys: String, CodingKey { case alias, isDefault, machines }
    init(alias: String, isDefault: Bool, machines: [String] = []) {
        self.alias = alias; self.isDefault = isDefault; self.machines = machines
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alias = try c.decode(String.self, forKey: .alias)
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        machines = try c.decodeIfPresent([String].self, forKey: .machines) ?? []
    }

    /// repos.json 在滚动升级期会同时保留 machineID 和旧 machineName 两个键。
    /// 手机若原样展示，会把一台电脑列两遍。能解析的统一折叠成 machineID；
    /// 解析不了的旧选择器原样保留，不能静默丢掉仓库归属。
    func normalized(using knownMachines: [MachineInfo]) -> RepoItem {
        var copy = self
        var seen = Set<String>()
        copy.machines = machines.compactMap { selector in
            // 有歧义的旧机器名原样保留并由投递页明确拦下，不能静默绑定到
            // `knownMachines` 的第一项。等任一 Mac 用稳定 ID 重发 repo 配置后
            // 会自然归一化，不需要人猜旧名字属于谁。
            let stable = MachineInfo.resolve(selector: selector, among: knownMachines)?.machineID
                ?? selector
            return seen.insert(stable).inserted ? stable : nil
        }.sorted()
        return copy
    }
}

/// config/repos.json 里的完整条目 —— 手机只关心 alias 和 pathByMachine 的键。
struct RepoConfigEntry: Codable {
    var alias: String
    var isDefault: Bool?
    var pathByMachine: [String: String]?

    enum CodingKeys: String, CodingKey { case alias, isDefault, pathByMachine }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alias = try c.decode(String.self, forKey: .alias)
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault)
        pathByMachine = try c.decodeIfPresent([String: String].self, forKey: .pathByMachine)
    }
}

enum PlatformNames {
    static let map = [
        "claude": "Claude", "codex": "Codex", "gemini": "Gemini",
        "qwen": "Qwen", "kimi": "Kimi", "glm": "GLM",
        "minimax": "MiniMax", "deepseek": "DeepSeek", "volcark": "火山方舟",
    ]
}

// MARK: - 格式化

enum Fmt {
    static func compact(_ v: Double) -> String {
        guard v.isFinite else { return "—" }
        let a = abs(v)
        switch a {
        case 0..<1000: return v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
        case 1000..<1_000_000: return String(format: "%.1fK", v / 1000)
        case 1_000_000..<1_000_000_000: return String(format: "%.1fM", v / 1_000_000)
        default: return String(format: "%.1fB", v / 1_000_000_000)
        }
    }
    static func compact(_ v: Int) -> String { compact(Double(v)) }

    static func percent(_ f: Double?) -> String {
        guard let f, f.isFinite else { return "—" }
        return String(format: "%.0f%%", f * 100)
    }

    static func duration(_ s: TimeInterval?) -> String {
        guard let s, s.isFinite, s > 0, s <= Double(Int.max) else { return "—" }
        let t = Int(s), d = t / 86400, h = (t % 86400) / 3600, m = (t % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)天\(h)小时" : "\(d)天" }
        if h > 0 { return m > 0 ? "\(h)小时\(m)分" : "\(h)小时" }
        return "\(m)分钟"
    }

    /// 「跑了多久」。和 `duration` 分开是因为那个对 60 秒以内会说成「0分钟」——
    /// 一件刚开跑的任务显示「已 0分钟」，看着像卡住了。
    static func elapsed(_ s: TimeInterval) -> String {
        guard s.isFinite, s >= 0 else { return "—" }
        if s < 60 { return "不到 1 分钟" }
        return duration(s)
    }

    static func relative(_ d: Date?) -> String {
        guard let d, d != .distantPast else { return "从未" }
        let delta = Date().timeIntervalSince(d)
        guard delta.isFinite else { return "从未" }
        if delta < -90 { return "稍后" }
        if delta < 90 { return "刚刚" }
        if delta < 3600 { return "\(Int(delta / 60)) 分钟前" }
        if delta < 86400 { return "\(Int(delta / 3600)) 小时前" }
        if delta > 100 * 365 * 86400 { return "很久以前" }
        return "\(Int(delta / 86400)) 天前"
    }

    static func metricValue(_ v: Double, metric: String) -> String {
        switch metric {
        case "percent": return String(format: "%.0f%%", v)
        case "prompts": return compact(v) + " 条"
        case "requests": return compact(v) + " 次"
        case "cost": return String(format: "%.2f", v)
        default: return compact(v)
        }
    }
}


/// 一个窗口长度的空窗统计。
struct IdleWindow: Codable {
    var windowMinutes: Int
    /// 统计区间里有多少个**完整过去**的窗口。0 = 算不出来
    /// （这个平台没有本地用量日志，或者数据还不够一个窗口）。
    var total: Int
    var idle: Int
    /// 到现在为止连续空了几个。它和空窗率回答的是不同问题：
    /// 空窗率说「长期用得够不够」，连续空窗说「**现在**是不是正闲着」。
    var currentStreak: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windowMinutes = try c.decodeIfPresent(Int.self, forKey: .windowMinutes) ?? 0
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        idle = try c.decodeIfPresent(Int.self, forKey: .idle) ?? 0
        currentStreak = try c.decodeIfPresent(Int.self, forKey: .currentStreak) ?? 0
    }

    var idleFraction: Double { total > 0 ? Double(idle) / Double(total) : 0 }
    var measurable: Bool { total > 0 }

    var windowLabel: String {
        switch windowMinutes {
        case 240: return "4 小时窗"
        case 300: return "5 小时窗"
        case 1440: return "每日窗"
        case 10080: return "每周窗"
        case 43200: return "每月窗"
        default: return windowMinutes >= 60 ? "\(windowMinutes / 60) 小时窗"
                                            : "\(windowMinutes) 分钟窗"
        }
    }
}

/// 岗位职责。字段和 Mac 端 AgentRole 对应。
struct AgentRole: Codable {
    var platform: String
    var title: String
    var maxRisk: String
    var maxTier: String?
    var prefers: [String]
    var note: String
    /// 在这些机器上它是**指挥**（控制面），不是干活的。
    var dispatcherOn: [String] = []

    /// 给人自己留的余量：剩余额度低于这个比例时，调度器就不再往这里派活。
    ///
    /// **这是 Mac 端解析后的「生效值」，不是覆盖值。**
    /// Mac 端的 `AgentRole.reserveFraction` 是覆盖值，nil 表示继承全局默认；
    /// 发布给手机的必须是 `AgentRoles.reserve(for:default:)` 的结果，
    /// 否则界面上一片空白，人会以为「一个都没设」—— 而默认其实是 25%。
    ///
    /// 这边仍然是可选：老版本 llmq 根本不发这个键。
    /// 那种情况下要显示成「不知道」而不是假装知道，见 `reserveIsPublished`。
    var reserveFraction: Double?
    var reserveUpdatedAt: Double?
    var reserveIntentID: String?
    var reserveConflict: Bool?
    /// true = 这个平台没单独设过，用的是全局默认。
    /// 界面上必须标出来 —— 不标的话人会以为 25% 是自己设的。
    var reserveIsDefault: Bool?

    /// 服务端下发的「能不能派活给它」。缺省 true —— 见 `canEditFiles`。
    var canTakeWork: Bool = true
    /// 不能派活时的原因，直接显示给人看。空串表示能派。
    var cannotTakeWorkReason: String = ""

    /// Mac 端到底发没发这个字段。
    /// 把「它说是 25%」和「我猜是 25%」分开 —— 后者不能拿来当既成事实展示。
    var reserveIsPublished: Bool { reserveFraction != nil }
    /// 拿不到发布值时退回内置默认。和 Mac 端 `WorkScheduler.humanReserve` 对齐。
    static let builtinDefaultReserve = 0.25
    var effectiveReserve: Double { reserveFraction ?? Self.builtinDefaultReserve }
    var reserveUsesDefault: Bool { reserveIsDefault ?? true }

    /// 至少在一台机器上是指挥。
    var isDispatcher: Bool { !dispatcherOn.isEmpty }

    /// 指挥绑定优先按稳定 machineID，兼容 nodeName 和历史 machineName。
    /// 两台同名 MacBook Pro 不能因为显示名相同而同时被隐藏工位。
    func isDispatcher(on machine: MachineInfo) -> Bool {
        dispatcherOn.contains { machine.matches(selector: $0) }
    }

    /// **手写解码。**
    ///
    /// 合成解码器对缺键零容忍：`prefers` / `note` 是非可选又没默认值，
    /// 老看板里少一个键，整个 AgentRole 就解不出来 —— 而它挂在
    /// `role: AgentRole?` 上，抛错会顺着把整条 PlatformReport 一起带走，
    /// 那个平台从界面上**静默消失**。
    ///
    /// 这个坑在 Mac 端踩过五次。加 `dispatcherOn` 更非走这条路不可：
    /// 手机上的 App 和 Mac 上的 llmq 永远不可能同时更新。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "未分配"
        maxRisk = try c.decodeIfPresent(String.self, forKey: .maxRisk) ?? "safe"
        maxTier = try c.decodeIfPresent(String.self, forKey: .maxTier)
        prefers = try c.decodeIfPresent([String].self, forKey: .prefers) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        dispatcherOn = try c.decodeIfPresent([String].self, forKey: .dispatcherOn) ?? []
        reserveFraction = try c.decodeIfPresent(Double.self, forKey: .reserveFraction)
        reserveUpdatedAt = try c.decodeIfPresent(Double.self, forKey: .reserveUpdatedAt)
        reserveIntentID = try c.decodeIfPresent(String.self, forKey: .reserveIntentID)
        reserveConflict = try c.decodeIfPresent(Bool.self, forKey: .reserveConflict)
        reserveIsDefault = try c.decodeIfPresent(Bool.self, forKey: .reserveIsDefault)
        canTakeWork = try c.decodeIfPresent(Bool.self, forKey: .canTakeWork) ?? true
        cannotTakeWorkReason =
            try c.decodeIfPresent(String.self, forKey: .cannotTakeWorkReason) ?? ""
    }

    var riskLabel: String {
        switch maxRisk {
        case "safe": return "低危"
        case "normal": return "常规"
        case "sensitive": return "高危"
        default: return maxRisk
        }
    }
    static func tierLabel(_ t: String) -> String {
        switch t {
        case "trivial": return "简单"
        case "standard": return "常规"
        case "complex": return "复杂"
        default: return t
        }
    }
    var tierLabel: String? { maxTier.map(Self.tierLabel) }
    var prefersLabel: String { prefers.map(Self.tierLabel).joined(separator: " / ") }

    /// 能不能派活给它。**由 Mac 端算好下发，客户端不再自己判断。**
    ///
    /// 这里原来写的是 `platform != "minimax"` —— 那条判断写于 MiniMax
    /// 只会文本聊天的年代。它后来长出了媒体和评审两个执行器，都写文件，
    /// 而手机上这行代码停在原地，于是「点名让他干一件活」按钮一直是灰的，
    /// 点了毫无反应。
    ///
    /// 平台能力会变，客户端要走审核 —— 所以这类事实一律问服务端。
    /// **缺字段时默认能派**：老服务端没有这个字段，不能因此把按钮全锁死。
    var canEditFiles: Bool { canTakeWork }
}


/// 币种。**不同币种绝不相加。**
///
/// 第一版把所有月费都硬写成 `¥`，于是 ChatGPT Plus 的 $20 被显示成
/// ¥20 —— 差了七倍，而且是往少了说，正好让最该被注意的浪费看起来最小。
///
/// 也不做汇率换算：汇率会变，而这个数字是拿来做决定的
/// （「这个订阅值不值得退」）。用一个每天都在漂的换算结果去回答那个问题，
/// 不如把两个币种分开摆着。
enum Money {
    static func symbol(_ currency: String?) -> String {
        switch (currency ?? "CNY").uppercased() {
        case "USD": return "$"
        case "CNY", "RMB": return "¥"
        case "EUR": return "€"
        case "JPY": return "¥"
        case "GBP": return "£"
        default: return (currency ?? "") + " "
        }
    }

    static func text(_ amount: Double, _ currency: String?) -> String {
        guard amount.isFinite else { return symbol(currency) + "—" }
        guard amount >= Double(Int.min), amount <= Double(Int.max) else {
            return symbol(currency) + String(format: "%.2e", amount)
        }
        let n = amount == amount.rounded() ? String(Int(amount))
                                           : String(format: "%.2f", amount)
        return symbol(currency) + n
    }

    /// 按币种分组求和。返回按金额降序，**每个币种一条，不合并**。
    static func group(_ items: [(amount: Double, currency: String?)])
        -> [(currency: String?, total: Double)] {
        var m: [String: (String?, Double)] = [:]
        for i in items where i.amount.isFinite && i.amount > 0 {
            let k = (i.currency ?? "CNY").uppercased()
            m[k] = (i.currency, (m[k]?.1 ?? 0) + i.amount)
        }
        return m.values.map { (currency: $0.0, total: $0.1) }
            .sorted { $0.total > $1.total }
    }
}
