import SwiftUI

// MARK: - 工作状态

/// 每个平台在「数字员工」视角下的状态。
///
/// 判定顺序和 Mac 端看板**必须一致**，否则同一份 dashboard.json
/// 在两块屏幕上会显示成不同的结论，那比不显示更糟。
/// 顺序的讲究：先看在不在岗，再看岗上干得怎么样。
enum StaffState: String {
    case working    // 在岗
    case strained   // 超负荷：逼近上限
    case drained    // 产能耗尽
    case dozing     // 产能闲置 / 无产出
    case asleep     // 在编未上岗

    static func classify(_ r: PlatformReport) -> StaffState {
        guard r.detected else { return .asleep }
        switch worstHealth(r) {
        case .exhausted: return .drained
        case .atRisk:    return .strained
        case .wasting:   return .dozing
        default:
            return r.last30dRequests == 0 ? .dozing : .working
        }
    }

    private static func worstHealth(_ r: PlatformReport) -> Health {
        r.headline?.effectiveHealth ?? .unknown
    }

    var pill: String {
        switch self {
        case .working:  return "在岗"
        case .strained: return "超负荷"
        case .drained:  return "产能耗尽"
        case .dozing:   return "产能闲置"
        case .asleep:   return "在编未上岗"
        }
    }

    var tint: Color {
        switch self {
        case .working:  return .green
        case .strained: return .red
        case .drained:  return .red
        case .dozing:   return .orange
        case .asleep:   return .secondary
        }
    }

    /// 越靠前越该代表全队的表情。一个人烧穿了额度，
    /// 整队的状态就该是那个人的状态 —— 取最坏而不是取平均。
    static let rank: [StaffState] = [.drained, .strained, .dozing, .asleep, .working]

    var teamMood: String {
        switch self {
        case .drained:  return "有成员产能已经烧穿，工作得往别处转"
        case .strained: return "有成员逼近上限，随时会失败"
        case .dozing:   return "有产能正在闲置，再不派活就作废了"
        case .asleep:   return "有成员在编未上岗"
        case .working:  return "全员在岗，产能分配正常"
        }
    }
}

enum StaffHue {
    /// 和 Mac 端看板同一套身份色。
    static let map: [String: Color] = [
        "claude": Color(hex: 0x2E6F7E), "codex": Color(hex: 0x5C7A52),
        "gemini": Color(hex: 0x7A6096), "qwen": Color(hex: 0xB07B3E),
        "kimi": Color(hex: 0x9C5566), "glm": Color(hex: 0x3F7D8C),
        "minimax": Color(hex: 0x6E6A9B), "deepseek": Color(hex: 0x4A7C6E),
        "volcark": Color(hex: 0xA2663F),
    ]
    static func of(_ platform: String) -> Color { map[platform] ?? .gray }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - 工牌头像

/// 画成显示器造型的小人：上面有工牌夹，脸是一块屏。
///
/// 用原生图形而不是把 Mac 端那套 Three.js 塞进 WebView：
/// 那个 bundle 有 530KB，在手机上为了几个待机小人开一个 GL 上下文
/// 不划算，而且深色模式、动效降级都得自己再实现一遍。
/// 这里的每个部件是独立视图，眨眼/冒汗/飘 zzz 各自动画，互不干扰。
/// 员工的物种。
///
/// 为什么要有物种：同一个平台装在两台机器上时，原来两张桌子坐着
/// **一模一样**的机器人（用户原话：「两台电脑的用的角色一样」）——
/// 色调的差别在小尺寸下根本看不出来。物种改的是**剪影**：
/// 耳朵、触手、翅膀在 34pt 下依然一眼可辨。
///
/// 分配按 (machineID, platform) 稳定散列：同一个员工永远同一张脸，
/// 换机器名、刷新、重装都不换 —— 换脸等于换了个陌生人。
enum MascotSpecies: CaseIterable {
    case robot      // 显示器机器人（初代造型）
    case cat        // 三角耳 + 胡须
    case owl        // 圆脑袋 + 耳羽 + 翅膀
    case octopus    // 圆顶 + 触手，没有手臂
    case ghost      // 幽灵：波浪下摆，飘着
    case blocky     // 方块星：斜切角脑袋

    /// 稳定分配。用 FNV-1a 而不是 hashValue：后者每次启动都换种子。
    static func pick(machineID: String, platform: String) -> MascotSpecies {
        var h: UInt64 = 0xcbf29ce484222325
        for b in (machineID + "|" + platform).utf8 {
            h = (h ^ UInt64(b)) &* 0x100000001b3
        }
        let all = MascotSpecies.allCases
        return all[Int(h % UInt64(all.count))]
    }
}

enum MascotPose { case neutral, waving, stretching, sipping }

struct Mascot: View {
    let state: StaffState
    let hue: Color
    var species: MascotSpecies = .robot
    var size: CGFloat = 48
    /// 忙碌程度 0…1，决定指示灯跑得多快 —— 忙的人手速就是快。
    var activity: Double = 0.4
    /// 手臂摆动角度。走路时由外面驱动，静止时是 0。
    var armSwing: Double = 0
    var pose: MascotPose = .neutral
    var gesture: Double = 0
    var animates = true
    var showsStatusAccessory = true
    var statusTint: Color? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var beat = false
    private var motionEnabled: Bool { animates && !reduceMotion && scenePhase == .active }

    private var s: CGFloat { size / 48 }   // 设计稿按 48pt 画，按比例缩放

    /// 五官的颜色。**固定深色，不能用 Color.primary。**
    ///
    /// 脸是一块固定浅色的面板（这个吉祥物本体是台显示器），
    /// 而 `Color.primary` 在深色模式下会变成白色 —— 白眼睛白嘴巴画在
    /// 白面板上，脸就是一片空白。实测就是这个现象：
    /// 「脸有问题，一片白色，也看不到眼睛、嘴巴」。
    ///
    /// 凡是画在固定颜色底子上的东西，颜色也必须固定；
    /// 只有画在系统背景上的（比如工牌夹）才该跟随主题。
    private let ink = Color(white: 0.16)
    private var dim: Bool { state == .asleep }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 状态灯是全物种共有的（那是额度状态的信号灯，不是装饰）——
            // 只是挂的位置随物种走：机器人在天线尖，猫和猫头鹰在耳侧，
            // 章鱼和幽灵悬在头顶。
            crest

            Circle()
                .fill(statusTint ?? state.tint)
                .frame(width: 5 * s, height: 5 * s)
                .offset(x: lightX * s,
                        y: dim ? lightY * s : (beat ? (lightY - 1) * s : lightY * s))
                .animation(!motionEnabled ? nil :
                    .easeInOut(duration: cycle).repeatForever(autoreverses: true), value: beat)

            lowerBody

            // 平时章鱼和幽灵没有手臂；举手与伸展时用同色触手表现手势。
            if (species != .octopus && species != .ghost) || pose != .neutral {
                ForEach([6.5, 37.5], id: \.self) { x in
                    Capsule()
                        .fill(hue.opacity(dim ? 0.3 : 0.8))
                        .frame(width: 4.5 * s, height: 12 * s)
                        .rotationEffect(.degrees(armAngle(left: x < 20)),
                                        anchor: .top)
                        .offset(x: x * s, y: 34 * s)
                }
            }

            head

            // 面板（脸）。所有物种共用同一块脸和同一套表情 ——
            // 表情是额度状态的语言，物种只改剪影，不改语言。
            RoundedRectangle(cornerRadius: species == .owl ? 9 * s : 3.5 * s)
                .fill(Color(white: 0.97))
                .frame(width: 29 * s, height: 21 * s)
                .offset(x: 9.5 * s, y: 9.5 * s)

            face
            if showsStatusAccessory { accessory }
        }
        .frame(width: 48 * s, height: 50 * s)
        .onChange(of: motionEnabled, initial: true) { _, enabled in
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { beat = false }
            guard enabled else { return }
            withAnimation(.easeInOut(duration: cycle).repeatForever(autoreverses: true)) {
                beat = true
            }
        }
        .accessibilityLabel(state.pill)
    }

    private func armAngle(left: Bool) -> Double {
        switch pose {
        case .neutral: return left ? armSwing : -armSwing
        case .waving: return left ? 0 : -150 + gesture * 14
        case .stretching: return (left ? 1 : -1) * (135 + gesture * 15)
        case .sipping: return left ? 0 : -105 + gesture * 4
        }
    }

    // MARK: 物种部件

    /// 状态灯坐标（48pt 设计稿坐标系）。
    private var lightX: CGFloat {
        switch species {
        case .robot: return 21.5
        case .cat, .owl: return 36
        case .octopus, .ghost: return 21.5
        case .blocky: return 38
        }
    }
    private var lightY: CGFloat {
        switch species {
        case .robot: return -1.5
        case .cat, .owl: return -1
        case .octopus, .ghost: return -2.5
        case .blocky: return 2
        }
    }

    /// 头顶识别件：天线/耳朵/耳羽/无。
    @ViewBuilder private var crest: some View {
        switch species {
        case .robot:
            Rectangle()
                .fill(hue.opacity(dim ? 0.4 : 0.85))
                .frame(width: 1.6 * s, height: 5 * s)
                .offset(x: 23.2 * s, y: 1 * s)
        case .cat:
            // 三角耳，左右各一
            ForEach([9.0, 29.0], id: \.self) { x in
                Triangle()
                    .fill(hue.opacity(dim ? 0.4 : 1))
                    .frame(width: 10 * s, height: 9 * s)
                    .offset(x: x * s, y: 0)
            }
        case .owl:
            // 短耳羽
            ForEach([8.0, 32.0], id: \.self) { x in
                Capsule()
                    .fill(hue.opacity(dim ? 0.4 : 0.9))
                    .frame(width: 3.5 * s, height: 7 * s)
                    .rotationEffect(.degrees(x < 20 ? -18 : 18))
                    .offset(x: x * s, y: 0.5 * s)
            }
        case .octopus, .ghost:
            EmptyView()
        case .blocky:
            // 斜切角上的小方块
            Rectangle()
                .fill(hue.opacity(dim ? 0.4 : 0.9))
                .frame(width: 5 * s, height: 5 * s)
                .rotationEffect(.degrees(45))
                .offset(x: 36 * s, y: 1 * s)
        }
    }

    /// 头。物种的主剪影。
    @ViewBuilder private var head: some View {
        switch species {
        case .robot:
            RoundedRectangle(cornerRadius: 7 * s)
                .fill(hue.opacity(dim ? 0.4 : 1))
                .frame(width: 38 * s, height: 34 * s)
                .offset(x: 5 * s, y: 5 * s)
        case .cat:
            RoundedRectangle(cornerRadius: 13 * s)
                .fill(hue.opacity(dim ? 0.4 : 1))
                .frame(width: 38 * s, height: 33 * s)
                .offset(x: 5 * s, y: 6 * s)
        case .owl:
            RoundedRectangle(cornerRadius: 16 * s)
                .fill(hue.opacity(dim ? 0.4 : 1))
                .frame(width: 38 * s, height: 35 * s)
                .offset(x: 5 * s, y: 4.5 * s)
        case .octopus, .ghost:
            // 圆顶：上圆下方，身体和头一体
            UnevenRoundedRectangle(
                topLeadingRadius: 19 * s, bottomLeadingRadius: 4 * s,
                bottomTrailingRadius: 4 * s, topTrailingRadius: 19 * s)
                .fill(hue.opacity(dim ? 0.4 : (species == .ghost ? 0.88 : 1)))
                .frame(width: 38 * s, height: 36 * s)
                .offset(x: 5 * s, y: 4 * s)
        case .blocky:
            // 斜切一角的方脑袋
            UnevenRoundedRectangle(
                topLeadingRadius: 3 * s, bottomLeadingRadius: 3 * s,
                bottomTrailingRadius: 3 * s, topTrailingRadius: 14 * s)
                .fill(hue.opacity(dim ? 0.4 : 1))
                .frame(width: 38 * s, height: 34 * s)
                .offset(x: 5 * s, y: 5 * s)
        }
    }

    /// 下半身：躯干+胸灯 / 触手 / 波浪摆。
    @ViewBuilder private var lowerBody: some View {
        switch species {
        case .octopus:
            ForEach([10.0, 18.5, 27.0, 34.0], id: \.self) { x in
                Capsule()
                    .fill(hue.opacity(dim ? 0.3 : 0.85))
                    .frame(width: 5 * s, height: 10 * s)
                    .rotationEffect(.degrees(x < 22 ? 8 : -8), anchor: .top)
                    .offset(x: x * s, y: 37 * s)
            }
        case .ghost:
            // 波浪下摆：三个半圆
            ForEach([9.0, 19.5, 30.0], id: \.self) { x in
                Circle()
                    .fill(hue.opacity(dim ? 0.3 : 0.88))
                    .frame(width: 9.5 * s, height: 9.5 * s)
                    .offset(x: x * s, y: 36 * s)
            }
        default:
            RoundedRectangle(cornerRadius: 4 * s)
                .fill(hue.opacity(dim ? 0.3 : 0.85))
                .frame(width: 26 * s, height: 14 * s)
                .offset(x: 11 * s, y: 34 * s)
            Capsule()
                .fill(Color(white: 0.97).opacity(0.9))
                .frame(width: 9 * s, height: 2.6 * s)
                .offset(x: 19.5 * s, y: 39 * s)
        }
    }

    /// 动画周期直接来自状态：超负荷的抖得快，打盹的慢悠悠。
    private var cycle: Double {
        switch state {
        case .strained: return 0.28
        case .working:  return 0.7 - activity * 0.35
        case .drained:  return 1.9
        default:        return 1.5
        }
    }

    // MARK: 眼睛和嘴 —— 光看静态形状就能区分状态

    @ViewBuilder private var face: some View {
        switch state {
        case .drained:
            // 两只叉眼
            Cross().stroke(ink, style: .init(lineWidth: 1.6 * s, lineCap: .round))
                .frame(width: 6 * s, height: 6 * s).offset(x: 14.5 * s, y: 16.5 * s)
            Cross().stroke(ink, style: .init(lineWidth: 1.6 * s, lineCap: .round))
                .frame(width: 6 * s, height: 6 * s).offset(x: 27.5 * s, y: 16.5 * s)
            // 嘴：一条直线
            Capsule().fill(ink)
                .frame(width: 8 * s, height: 1.6 * s).offset(x: 20 * s, y: 26.2 * s)

        case .strained:
            // 瞪圆的眼睛
            ForEach([17.5, 30.5], id: \.self) { cx in
                ZStack {
                    Circle().stroke(ink, lineWidth: 1.2 * s)
                        .frame(width: 8 * s, height: 8 * s)
                    Circle().fill(ink).frame(width: 4.4 * s, height: 4.4 * s)
                }
                .offset(x: (cx - 4) * s, y: 15.5 * s)
            }
            // 嘴：向下的弧
            Arc(down: false).stroke(ink,
                                    style: .init(lineWidth: 1.6 * s, lineCap: .round))
                .frame(width: 8 * s, height: 3 * s).offset(x: 20 * s, y: 26 * s)

        case .dozing, .asleep:
            // 眯着的半月眼
            ForEach([13.5, 26.5], id: \.self) { x in
                Arc(down: true).stroke(ink,
                                       style: .init(lineWidth: 1.5 * s, lineCap: .round))
                    .frame(width: 8 * s, height: 3.4 * s).offset(x: x * s, y: 19 * s)
            }
            Capsule().fill(ink)
                .frame(width: 4 * s, height: 1.5 * s).offset(x: 22 * s, y: 26.5 * s)

        case .working:
            // 实心圆眼 + 会眨的眼睑
            ForEach([17.5, 30.5], id: \.self) { cx in
                Circle().fill(ink)
                    .frame(width: 5.2 * s, height: 5.2 * s)
                    .offset(x: (cx - 2.6) * s, y: 16.9 * s)
            }
            if motionEnabled {
                ForEach([14.5, 27.5], id: \.self) { x in
                    Rectangle().fill(Color(white: 0.97))
                        .frame(width: 6 * s, height: beat ? 0.5 * s : 6 * s)
                        .offset(x: x * s, y: 16.5 * s)
                }
            }
            // 嘴：向上的弧
            Arc(down: true).stroke(ink,
                                   style: .init(lineWidth: 1.6 * s, lineCap: .round))
                .frame(width: 8 * s, height: 3 * s).offset(x: 20 * s, y: 25.5 * s)
        }
    }

    // MARK: 配件 —— 在岗有活动指示灯，超负荷冒汗，打盹飘 zzz

    @ViewBuilder private var accessory: some View {
        switch state {
        case .working:
            HStack(spacing: 3.3 * s) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(state.tint)
                        .frame(width: 3.4 * s, height: 3.4 * s)
                        .opacity(reduceMotion ? 0.9 : (beat ? 1 : 0.25))
                        .animation(reduceMotion ? nil :
                            .easeInOut(duration: cycle)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * cycle / 3), value: beat)
                }
            }
            .offset(x: 17.3 * s, y: 33.8 * s)

        case .strained:
            // 汗珠沿着头的右侧往下滑
            Drop()
                .fill(Color(hex: 0x5B9BD5))
                .frame(width: 4.8 * s, height: 6.6 * s)
                .offset(x: 37 * s, y: (beat ? 16 : 10) * s)
                .opacity(beat ? 0 : 1)

        case .dozing, .asleep:
            Text("z").font(.system(size: 9 * s, weight: .bold))
                .foregroundStyle(.primary.opacity(beat ? 0.15 : 0.7))
                .offset(x: 37 * s, y: (beat ? 1 : 5) * s)
            Text("z").font(.system(size: 6.5 * s, weight: .bold))
                .foregroundStyle(.primary.opacity(beat ? 0.7 : 0.15))
                .offset(x: 42 * s, y: (beat ? -3 : 1) * s)

        case .drained:
            EmptyView()
        }
    }
}

// MARK: 形状零件

private struct Cross: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.move(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        return p
    }
}

/// down = true 时是笑弧（两端上翘），false 是苦弧。
private struct Arc: Shape {
    let down: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: down ? r.minY : r.maxY))
        p.addQuadCurve(
            to: CGPoint(x: r.maxX, y: down ? r.minY : r.maxY),
            control: CGPoint(x: r.midX, y: down ? r.maxY * 2 : r.minY - r.maxY))
        return p
    }
}

private struct Drop: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY * 0.66),
                       control: CGPoint(x: r.maxX, y: r.maxY * 0.34))
        p.addArc(center: CGPoint(x: r.midX, y: r.maxY * 0.66),
                 radius: r.width / 2, startAngle: .degrees(0), endAngle: .degrees(180),
                 clockwise: false)
        p.addQuadCurve(to: CGPoint(x: r.midX, y: r.minY),
                       control: CGPoint(x: r.minX, y: r.maxY * 0.34))
        return p
    }
}

// MARK: - 员工页

struct StaffView: View {
    @EnvironmentObject var store: Store

    private var staff: [PlatformReport] {
        (store.dashboard?.reports ?? [])
            .filter { $0.detected || $0.installed }
            .sorted {
                let a = StaffState.rank.firstIndex(of: StaffState.classify($0)) ?? 9
                let b = StaffState.rank.firstIndex(of: StaffState.classify($1)) ?? 9
                return a < b
            }
    }

    /// 全队取最坏的那个状态 —— 和 Mac 端看板同一条规则。
    private var teamState: StaffState {
        let all = Set(staff.map(StaffState.classify))
        return StaffState.rank.first(where: all.contains) ?? .working
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Mascot(state: teamState, hue: .accentColor, size: 62)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(teamState.pill)
                                .font(.title3.bold())
                                .foregroundStyle(teamState.tint)
                            Text(teamState.teamMood)
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                } footer: {
                    if let d = store.dashboard {
                        Text("\(d.machines.count) 台设备 · \(staff.count) 名在编 · "
                             + "数据 \(Fmt.relative(d.generatedAt))")
                    }
                }

                Section("在编成员") {
                    ForEach(staff) { r in
                        StaffRow(report: r, task: currentTask(for: r.platform))
                    }
                }

                if staff.isEmpty {
                    ContentUnavailableView(
                        "还没有识别到成员", systemImage: "person.2.slash",
                        description: Text("在 Mac 上跑一次 llmq collect"))
                }
            }
            .navigationTitle("员工")
            .refreshable { await store.refresh() }
        }
    }

    /// 这个平台手头正在干的活；没有在跑的就退回到它最近干完的一件。
    /// 「动作和任务关联起来」靠的就是这个字段 —— 卡片上写的是真实的活，
    /// 不是编出来的忙碌感。
    private func currentTask(for platform: String) -> TaskResult? {
        let mine = store.results.filter {
            ($0.platform ?? "").caseInsensitiveCompare(
                PlatformNames.map[platform] ?? platform) == .orderedSame
        }
        return mine.first(where: \.isRunning) ?? mine.first
    }
}

struct StaffRow: View {
    let report: PlatformReport
    let task: TaskResult?

    private var state: StaffState { StaffState.classify(report) }

    /// 忙碌程度：拿最吃紧那条额度的已用比例当代理指标。
    private var activity: Double {
        report.statuses.compactMap(\.usedFraction).max() ?? 0.2
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Mascot(state: state, hue: StaffHue.of(report.platform),
                   size: 46, activity: activity)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(report.displayName).font(.headline)
                    Text(state.pill)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(state.tint.opacity(0.15),
                                    in: Capsule())
                        .foregroundStyle(state.tint)
                    Spacer(minLength: 0)
                }

                Text(report.planName)
                    .font(.caption2).foregroundStyle(.tertiary)

                if let s = report.headline, let f = s.usedFraction {
                    HStack(spacing: 6) {
                        Text(s.label).font(.caption2).foregroundStyle(.secondary)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.1))
                                Capsule().fill(state.tint)
                                    .frame(width: max(2, geo.size.width * min(1, max(0, f))))
                            }
                        }
                        .frame(height: 5)
                        Text(Fmt.percent(f))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }

                Text(workline)
                    .font(.caption2)
                    .foregroundStyle(task?.isRunning == true ? state.tint : .secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    /// 一句话说清这个人此刻在干嘛。
    private var workline: String {
        if let t = task, t.isRunning { return "手头：\(t.prompt)" }
        switch state {
        case .asleep:
            return "装了但还没跑过，派一个任务就能上岗"
        case .drained:
            let reset = report.headline?.timeToReset
            return "额度已用尽" + (reset.map { "，\(Fmt.duration($0))后恢复" } ?? "")
        case .strained:
            return "逼近上限，这会儿派活容易失败"
        case .dozing where report.last30dRequests == 0:
            return "30 天没有产出"
        case .dozing:
            let reset = report.headline?.timeToReset
            return "闲着" + (reset.map { "，额度 \(Fmt.duration($0))后清零" } ?? "")
        case .working:
            if let t = task {
                return "刚做完：\(t.prompt)"
            }
            return "在岗，30 天 \(report.last30dRequests) 次调用"
        }
    }
}

/// 猫耳用的三角形。
struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
