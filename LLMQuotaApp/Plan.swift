import SwiftUI

/// 计划清单：Mac 上排好的、还没放行的任务 —— 手机上看得到、也能放行。
///
/// # 数据从哪来、往哪去
///
/// - **下行**：每台 Mac 的 `taskboards/<machineID>.json` 里带 `planned` 数组。
/// - **上行**：点「放行」→ 写 `config-intents/<uuid>.json`
///   （kind=plan-go，**必须带 targetMachineID**）→ 那台 Mac 的镜像按目标
///   抢下来 → 走和 CLI `work plan go` 同一个入队口（查重、分诊、拆图）。
///
/// # 三句必须分开说的话
///
/// - `planned == nil`：那台 Mac 版本旧，没发计划数据 —— 显示「不知道」
/// - `planned == []`：发了，确实没有计划 —— 什么都不占
/// - 放行发出后：「已发出」≠「已生效」。真正的确认是下次刷新时
///   这一条从计划里消失、出现在任务列表里。
struct PlanView: View {
    @EnvironmentObject var store: Store
    /// 放行状态归 Store 持久保存，按机器和计划区分。
    nonisolated static func releaseKey(machineID: String, planID: String) -> String {
        StableID.make(namespace: "plan-release", parts: [machineID, planID])
    }

    private var boards: [TaskBoardLoad] {
        // 和办公室同一套顺序：主力机在哪儿，这里就在哪儿。
        store.orderedByMachine(store.taskDigest.rawBoards, id: { $0.machineID })
    }

    var body: some View {
        List {
            ForEach(boards, id: \.machineID) { board in
                section(for: board)
            }
            if boards.isEmpty {
                Section {
                    Text("还没读到任何机器的任务板。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("计划清单")
        .refreshable { await store.refresh() }
    }

    @ViewBuilder
    private func section(for board: TaskBoardLoad) -> some View {
        Section(board.machineName.isEmpty ? String(board.machineID.prefix(8))
                                          : machineLabelForDisplay(
                                            board.machineName, machineID: board.machineID)) {
            if board.unreadable != nil {
                Text("这台的板子读不到 —— 有没有计划**不知道**。")
                    .font(.caption).foregroundStyle(.orange)
            } else if let planned = board.planned {
                if planned.isEmpty {
                    Text("没有排着的计划").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(planned.enumerated()), id: \.element.id) { i, item in
                        row(item, position: i + 1, machineID: board.machineID)
                    }
                }
            } else {
                // 老 Mac：没发这份数据。「不知道」和「没有」是两句话。
                Text("这台 Mac 的版本还没发计划数据。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: TaskBoardFile.PlannedBrief,
                     position: Int, machineID: String) -> some View {
        let pending = store.isPlanPending(machineID: machineID, planID: item.id)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(position).").font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.subheadline)
                    if let repo = item.repoAlias {
                        Text(repo).font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                Spacer()
            }
            if let failure = store.planReleaseFailure(machineID: machineID, planID: item.id) {
                Text("放行未生效：" + failure).font(.caption2).foregroundStyle(.orange)
            }
            if pending {
                Text("已发出，等待目标 Mac 确认。真正生效后，这条计划会从这里消失并出现在任务里。")
                    .font(.caption2).foregroundStyle(.blue)
                    .accessibilityIdentifier("plan-pending-" + PlanView.releaseKey(machineID: machineID, planID: item.id))
            } else {
                Button {
                    Task {
                        _ = await store.releasePlan(machineID: machineID, planID: item.id)
                    }
                } label: {
                    Label("放行", systemImage: "paperplane.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            if let e = store.lastError, !pending {
                Text(e).font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}
