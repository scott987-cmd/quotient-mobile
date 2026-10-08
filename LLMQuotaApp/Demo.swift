import Foundation

/// 演示数据：不连接任何东西也能完整看一遍这个 App 在干什么。
///
/// ## 为什么必须有它
///
/// 这个 App 的首屏要求选择 iCloud 里的共享文件夹 —— 而**审核员的设备上
/// 没有那个文件夹**。他选不了，进去是一片空白，于是「无法评估 App 功能」
///（App Store 审核指南 2.1）。工具类 App 被拒最常见的原因就是这个。
///
/// 对真实用户也一样有用：先看看长什么样，再决定要不要去装 Mac 端。
///
/// ## 为什么用 JSON 而不是直接构造
///
/// 这些模型只有 `init(from: Decoder)` —— 它们是**为解码而生**的，
/// 真实数据也是从 JSON 来的。演示数据走同一条路有两个好处：
/// 不用给模型加一堆只有演示才用的构造器；模型字段改了之后，
/// 演示数据会**解码失败**而不是悄悄错位成另一个样子。
///
/// 数字是编的，但**编得自洽**：健康度对得上百分比、快过期的那条真的快过期、
/// 待验收的产出真有冲突和证据。假数据自相矛盾的话，看的人反而更迷惑。
enum Demo {

    private static func decode<T: Decodable>(_ json: String) -> T? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(T.self, from: Data(json.utf8))
    }

    /// 相对现在的时刻，写成 ISO8601。演示数据里的时间必须是活的 ——
    /// 写死日期的话，「3 小时后重置」会变成「去年就过期了」。
    private static func at(_ offset: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date().addingTimeInterval(offset))
    }

    static func dashboard() -> Dashboard? {
        decode("""
        {
          "generatedAt": "\(at(-120))",
          "machines": [
            {"machineID":"demo-mini","machineName":"演示 · Mac mini",
             "lastSeen":"\(at(-90))","isStale":false},
            {"machineID":"demo-mbp","machineName":"演示 · MacBook",
             "lastSeen":"\(at(-300))","isStale":false}
          ],
          "reports": [
            {
              "platform": "claude", "planName": "Claude Max 5x",
              "detected": true, "installed": true,
              "lastActivity": "\(at(-600))",
              "last30dRequests": 28280, "last30dBillableTokens": 254300000,
              "machines": ["演示 · Mac mini"],
              "statuses": [
                {"platform":"claude","limitID":"c5h","label":"5 小时","metric":"requests",
                 "used":62,"limit":100,"usedFraction":0.62,
                 "resetsAt":"\(at(2.1 * 3600))",
                 "projectedUsedFraction":0.81,"projectedWaste":19,
                 "health":"healthy","isOfficial":true,"sourceNote":"演示数据"},
                {"platform":"claude","limitID":"cw","label":"每周","metric":"requests",
                 "used":41,"limit":100,"usedFraction":0.41,
                 "resetsAt":"\(at(3.5 * 86400))",
                 "projectedUsedFraction":0.53,"projectedWaste":47,
                 "health":"healthy","isOfficial":true,"sourceNote":"演示数据"}
              ]
            },
            {
              "platform": "codex", "planName": "ChatGPT Plus",
              "detected": true, "installed": true,
              "lastActivity": "\(at(-9000))",
              "last30dRequests": 4001, "last30dBillableTokens": 27400000,
              "machines": ["演示 · Mac mini"],
              "statuses": [
                {"platform":"codex","limitID":"x5h","label":"5 小时","metric":"requests",
                 "used":4,"limit":100,"usedFraction":0.04,
                 "resetsAt":"\(at(0.6 * 3600))",
                 "projectedUsedFraction":0.05,"projectedWaste":95,
                 "health":"wasting","isOfficial":true,
                 "sourceNote":"演示数据 · 这条就是要抓的浪费：快过期了还几乎没用"},
                {"platform":"codex","limitID":"xw","label":"每周","metric":"requests",
                 "used":78,"limit":100,"usedFraction":0.78,
                 "resetsAt":"\(at(2.2 * 86400))",
                 "projectedUsedFraction":0.96,"projectedWaste":4,
                 "health":"atRisk","isOfficial":true,"sourceNote":"演示数据"}
              ]
            },
            {
              "platform": "qwen", "planName": "Qwen Code",
              "detected": true, "installed": true,
              "lastActivity": "\(at(-1800))",
              "last30dRequests": 519, "last30dBillableTokens": 5200000,
              "machines": ["演示 · MacBook"],
              "statuses": [
                {"platform":"qwen","limitID":"qd","label":"每日","metric":"requests",
                 "used":93,"limit":100,"usedFraction":0.93,
                 "resetsAt":"\(at(5.5 * 3600))",
                 "projectedUsedFraction":1.0,"projectedWaste":0,
                 "health":"exhausted","isOfficial":true,"sourceNote":"演示数据"}
              ]
            },
            {
              "platform": "minimax", "planName": "MiniMax",
              "detected": true, "installed": true,
              "last30dRequests": 0, "last30dBillableTokens": 0,
              "machines": ["演示 · Mac mini"],
              "statuses": [
                {"platform":"minimax","limitID":"m5h","label":"5 小时","metric":"requests",
                 "used":2,"limit":100,"usedFraction":0.02,
                 "resetsAt":"\(at(1.2 * 3600))",
                 "projectedUsedFraction":0.03,"projectedWaste":97,
                 "health":"wasting","isOfficial":true,
                 "sourceNote":"演示数据 · 官方只报剩余额度，数不出 token"},
                {"platform":"minimax","limitID":"mw","label":"每周","metric":"requests",
                 "used":15,"limit":100,"usedFraction":0.15,
                 "resetsAt":"\(at(4 * 86400))",
                 "projectedUsedFraction":0.2,"projectedWaste":80,
                 "health":"wasting","isOfficial":true,"sourceNote":"演示数据"}
              ]
            }
          ]
        }
        """)
    }

    static func reviews() -> [ReviewDigest] {
        decode("""
        [
          {
            "repo":"/demo/game","repoName":"示例游戏",
            "branch":"agent/claude/a1b2c3d4","platform":"claude",
            "subject":"修黑屏：把散装 PNG 收进 Assets.xcassets",
            "prompt":"游戏启动后一片黑，只有 HUD 能看见。查清楚为什么，修掉，并在模拟器上实跑一局截图为证。",
            "files":["Sources/Game/Assets.xcassets","Sources/Game/Scene.swift"],
            "insertions":148,"deletions":12,
            "mergesCleanly":true,"overlapsWith":[],
            "committedAt":"\(at(-3600))",
            "evidence":["docs/evidence/01-开局.png","docs/evidence/02-通关.png"]
          },
          {
            "repo":"/demo/tool","repoName":"示例工具",
            "branch":"agent/codex/e5f6a7b8","platform":"codex",
            "subject":"补测试：额度窗口边界的三种情况",
            "prompt":"为额度引擎补单元测试，覆盖窗口刚开始、快结束、以及跨重置点这三种情况。",
            "files":["Tests/QuotaEngineTests.swift"],
            "insertions":96,"deletions":0,
            "mergesCleanly":false,
            "overlapsWith":["agent/qwen/c9d0e1f2"],
            "committedAt":"\(at(-7200))",
            "evidence":[]
          }
        ]
        """) ?? []
    }

    /// 任务板：**演示里必须有活在跑。**
    ///
    /// 只填额度不填任务的话，「现在」页会显示「还没读到任何快照」
    /// 和「看不到在跑的任务，把 Mac 上的 llmq 升级一下」——
    /// 审核员看到的是一个报错的 App，而不是一个在工作的 App。
    static func boards() -> [TaskBoardLoad] {
        // TaskBoardLoad 是本地组装的（不是从 JSON 解出来的），
        // 里面的 tasks 才是 Decodable —— 所以两段分开写。
        let tasks: [TaskBrief] = decode("""
        [
          {"id":"d1","title":"给卡牌补一版新美术，风格对齐已有的三张",
           "state":"running","platform":"minimax","machineName":"演示 · Mac mini",
           "startedAt":"\(at(-420))","elapsedSeconds":420,"repoAlias":"示例游戏",
           "machineID":"demo-mini"},
          {"id":"d2","title":"修黑屏：把散装 PNG 收进 Assets.xcassets",
           "state":"done","platform":"claude","machineName":"演示 · Mac mini",
           "startedAt":"\(at(-4200))","elapsedSeconds":880,"repoAlias":"示例游戏",
           "machineID":"demo-mini"},
          {"id":"d3","title":"补测试：额度窗口边界的三种情况",
           "state":"done","platform":"codex","machineName":"演示 · Mac mini",
           "startedAt":"\(at(-8000))","elapsedSeconds":640,"repoAlias":"示例工具",
           "machineID":"demo-mini"},
          {"id":"d4","title":"清一条 TODO：重试次数改成可配置",
           "state":"queued","machineName":"演示 · Mac mini",
           "repoAlias":"示例工具","machineID":"demo-mini"}
        ]
        """) ?? []
        return [TaskBoardLoad(machineID: "demo-mini",
                              machineName: "演示 · Mac mini",
                              generatedAt: Date().addingTimeInterval(-90),
                              tasks: tasks)]
    }

    /// 办公室事件流：数字员工在干什么。这是这个 App 最有辨识度的一屏。
    static func events() -> [OfficeEvent] {
        decode("""
        [
          {"id":"e1","at":"\(at(-2400))","kind":"dispatched","taskID":"d2",
           "platform":"claude","machineID":"demo-mini",
           "detail":"接到新活","taskTitle":"修黑屏：把散装 PNG 收进 Assets.xcassets"},
          {"id":"e2","at":"\(at(-1800))","kind":"asked","taskID":"d2",
           "platform":"claude","machineID":"demo-mini",
           "detail":"素材要放 Assets.xcassets 还是保持散装？",
           "taskTitle":"修黑屏：把散装 PNG 收进 Assets.xcassets"},
          {"id":"e3","at":"\(at(-1500))","kind":"answered","taskID":"d2",
           "platform":"claude","machineID":"demo-mini",
           "detail":"收到答复：收进 catalog","taskTitle":"修黑屏"},
          {"id":"e4","at":"\(at(-900))","kind":"finished","taskID":"d2",
           "platform":"claude","machineID":"demo-mini",
           "detail":"改了 2 个文件，验证通过，附了 2 张实跑截图",
           "taskTitle":"修黑屏：把散装 PNG 收进 Assets.xcassets"},
          {"id":"e5","at":"\(at(-420))","kind":"dispatched","taskID":"d1",
           "platform":"minimax","machineID":"demo-mini",
           "detail":"接到新活（空窗填活：周窗还剩 85% 没用）",
           "taskTitle":"给卡牌补一版新美术"}
        ]
        """) ?? []
    }

    /// 「Agent 协作」演示页。线格式和 Mac 端 ViewFeed.collaborationPage
    /// 完全一致 —— 演示数据走的就是真实契约，不是另一套形状。
    static func collaborationFeed() -> FeedPage? {
        decode("""
        {
          "schema": 1, "page": "collaboration", "generatedAt": "\(at(-60))",
          "sections": [
            {"kind": "facts", "title": "协作状态", "facts": [
              {"key": "待回应", "value": "1", "tone": "warn"},
              {"key": "最近记录", "value": "3", "tone": "neutral"}
            ]},
            {"kind": "cards", "title": "最近动态",
             "note": "只显示 Agent 主动留下的结论、问题、证据和交接",
             "cards": [
               {"id": "demo-c1",
                "title": "卡牌新美术的第二版方向需要拍板",
                "body": "minimax-art → claude-runner",
                "detail": "两个候选方向都出了草图，等确认走哪一版再继续。",
                "tone": "warn",
                "icon": "bubble.left.and.exclamationmark.bubble.right",
                "trailing": "示例游戏"},
               {"id": "demo-c2",
                "title": "黑屏修复已交付，附实跑截图",
                "body": "claude-code · 项目广播",
                "detail": "分支：agent/claude/a1b2c3d4\\n材料：01-开局.png、02-通关.png",
                "tone": "good", "icon": "arrow.triangle.branch",
                "trailing": "示例游戏"},
               {"id": "demo-c3",
                "title": "额度窗口边界测试补齐，交 codex 复核",
                "body": "codex-cli → qwen-coder",
                "detail": "跨重置点那条的断言写法和现有测试风格对齐过。",
                "tone": "neutral", "icon": "arrow.triangle.branch",
                "trailing": "示例工具"}
             ]}
          ]
        }
        """)
    }

    static func projects() -> [PlaybookProject] {
        decode("""
        [
          {
            "id":"demo-content","name":"示例：素材包产线",
            "brief":"**做什么**：用闲置的生图额度做素材包，上架卖。\\n\\n**为什么是这个**：生图额度每周都有大半没用完就清零，而这条产线已经跑通。\\n\\n**怎么算合格**：同一批风格统一、抽验 4 张没有明显跑偏、每张都裁掉底部签名区。\\n\\n**产出去哪**：packs/ 目录，上架前停下来等你确认。",
            "recipes":[
              {"title":"出一个新主题包","prompt":"主题已经定了：{{topic}}。别自己换题——方向由人定，你负责把它做好。",
               "tier":"complex","platform":"minimax","publishes":true}
            ],
            "runs":0,"paused":false
          }
        ]
        """) ?? []
    }
}
