import SwiftUI

/// 按请求身份显示发送、拒绝和采纳状态；数值相同不能证明这次请求已执行。
struct ReserveView: View {
    @EnvironmentObject var store: Store

    /// 手机上刚拖出来、还没被 Mac 确认的值（百分比）。
    @State private var draft: [String: Double] = [:]

    /// 只列**已检测到的**平台。没装的没有额度可留，摆出来只是噪音。
    private var platforms: [PlatformReport] {
        (store.dashboard?.reports ?? [])
            .filter { $0.detected && ($0.enabled ?? true) }
    }

    /// Mac 端一个都没发布这个字段 —— 说明那头还是老版本。
    private var nothingPublished: Bool {
        !platforms.contains { $0.role?.reserveIsPublished == true }
    }

    var body: some View {
        List {
            if platforms.isEmpty {
                ContentUnavailableView(
                    "还没有识别到平台", systemImage: "gauge.with.dots.needle.bottom.50percent",
                    description: Text("在 Mac 上跑一次 llmq collect，这里才知道有哪些额度池"))
            } else {
                if nothingPublished {
                    Section {
                        Text("Mac 端还没在看板里发布留白比例，下面显示的是内置默认值 "
                             + "\(Int(AgentRole.builtinDefaultReserve * 100))%，"
                             + "不一定是那边真正在用的。\n"
                             + "改动照样会写成意图文件，等 Mac 上的 llmq 升级后一起生效。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    ForEach(platforms) { r in
                        ReserveRow(report: r,
                                   percent: percent(for: r),
                                   note: note(for: r),
                                   onDrag: { draft[r.platform] = $0 },
                                   onCommit: { commit(r) })
                    }
                } header: {
                    Text("每个平台留多少给你自己")
                } footer: {
                    Text("留白是给你自己留的余量：这个平台的剩余额度达到这个比例时，"
                         + "调度器就不再往它派活，把剩下的留给你在别的程序里用。\n"
                         + "留 0% = 允许调度把它用满。标着「默认」的是没单独设过，"
                         + "跟着全局默认走。")
                }

                if let e = store.lastError {
                    Section { Text(e).font(.footnote).foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle("调度留白")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
    }

    // MARK: - 值

    /// 这一行现在该显示几 %：手机上刚改的优先，否则用 Mac 发布的生效值。
    private func percent(for r: PlatformReport) -> Double {
        if let d = draft[r.platform] { return d }
        if r.role?.reserveConflict == true && !hasNewerConflictRequest(r) { return live(r) }
        if let request = store.reserveSubmissions[r.platform], request.accepted != false {
            // 等待期间展示本次请求；已生效后跟随服务端更新。
            if request.accepted == nil { return request.fraction * 100 }
        }
        return live(r)
    }

    /// Mac 那边此刻生效的值（百分比）。
    private func live(_ r: PlatformReport) -> Double {
        (r.role?.effectiveReserve ?? AgentRole.builtinDefaultReserve) * 100
    }

    /// 改完之后那行下面的那句话。**这是「改了到底有没有出去」的唯一反馈。**
    private func note(for r: PlatformReport) -> ReserveRow.Note? {
        if r.role?.reserveConflict == true && !hasNewerConflictRequest(r) {
            return .init(text: "多台 Mac 收到顺序冲突的设置，暂按较高预留保护额度；请重新设置确认。", landed: false, failed: true)
        }
        guard let request = store.reserveSubmissions[r.platform] else { return nil }
        let pct = Int((request.fraction * 100).rounded())
        if request.accepted == false {
            return .init(text: request.note ?? "Mac 未采纳此次设置，可重新调整后提交", landed: false, failed: true)
        }
        if request.accepted == true {
            return .init(text: "Mac 已采纳此次 \(pct)% 设置；当前回报 \(Int(live(r).rounded()))%", landed: true)
        }
        return .init(text: "已请求 \(pct)%，等待 Mac 确认（当前回报 \(Int(live(r).rounded()))%）", landed: false)
    }

    /// 冲突参与者的旧请求不能盖掉保守生效值；冲突后重设则须保留发送反馈。
    private func hasNewerConflictRequest(_ r: PlatformReport) -> Bool {
        guard let stamp = r.role?.reserveUpdatedAt,
              let request = store.reserveSubmissions[r.platform] else { return false }
        return request.requestedAt > stamp
    }

    private func commit(_ r: PlatformReport) {
        guard let pct = draft[r.platform] else { return }
        Task {
            _ = await store.setReserve(platform: r.platform, fraction: pct / 100)
            // Slider 松手后仍可能回写最后一个值；提交结束再清理，避免草稿永久遮住新状态。
            // 较早提交返回时不能清掉用户随后拖出的不同值。
            if draft[r.platform] == pct { draft.removeValue(forKey: r.platform) }
        }
    }

}

/// 一个平台一行。
///
/// 拆成独立视图不只是为了好看：这一整块（Slider + 条件文案 + 徽章）
/// 塞在 ForEach 里编译器会类型检查超时，Asks.swift 里已经栽过一次。
struct ReserveRow: View {
    struct Note { let text: String; let landed: Bool; var failed = false }

    let report: PlatformReport
    let percent: Double
    let note: Note?
    let onDrag: (Double) -> Void
    let onCommit: () -> Void

    private var usesDefault: Bool { report.role?.reserveUsesDefault ?? true }
    /// 改过之后就不该再标「默认」了 —— 那会让人以为自己白改了。
    private var showDefaultTag: Bool { usesDefault && note == nil }

    private var value: Binding<Double> {
        Binding(get: { percent }, set: { onDrag($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(report.platformName).font(.headline)
                if showDefaultTag {
                    Text("默认")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("\(Int(percent.rounded()))%")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(percent > 0 ? .primary : .secondary)
            }

            if percent > 0 && !report.statuses.contains(where: {
                !$0.advisory && $0.displayUsedFraction != nil
            }) {
                Text("预留配置已保留；当前剩余额度未知，暂不能按比例保证预留。")
                    .font(.caption2).foregroundStyle(.orange)
            }

            Slider(value: value, in: 0...95, step: 5) { editing in
                // 只在松手时写文件。拖动过程中写的话，一次拖拽会在
                // config-intents/ 里留下十几份意图，Mac 那边全要处理一遍。
                if !editing { onCommit() }
            }
            .accessibilityLabel("\(report.platformName) 的调度留白")
            .accessibilityValue("\(Int(percent.rounded()))%")

            if let n = note {
                Label(n.text, systemImage: n.failed ? "exclamationmark.circle.fill" : (n.landed ? "checkmark.circle.fill" : "paperplane.fill"))
                    .font(.caption2)
                    .foregroundStyle(n.failed ? Color.red : (n.landed ? Color.green : Color.accentColor))
            } else {
                Text(explain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    /// 不带术语地说清这个数字的后果。
    private var explain: String {
        if percent <= 0 {
            return "不留 —— 调度器可以把它用满"
        }
        return "剩余达到 \(Int(percent.rounded()))% 时，调度器不再往这里派活"
    }
}
