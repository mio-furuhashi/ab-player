import SwiftUI

struct ABXTestView: View {
    @ObservedObject var vm: PlayerViewModel
    @ObservedObject private var settings = SettingsStore.shared

    /// ABX 的字比播放列表大一档，并随它一起缩放：字号 13 时恰好是设计基准。
    private var k: CGFloat { settings.abxFontScale }
    /// 结果表四列的宽度。40 × 基准倍率 1.25 = 原来的 50，字放大时列跟着放大才不折行。
    private var colW: CGFloat { 40 * k }

    var body: some View {
        VStack(spacing: 16) {
            if vm.abxShowSetup {
                setupDialog
            } else if vm.abxShowConfirm {
                confirmDialog
            } else if vm.abxShowResult {
                resultView
            } else {
                testView
            }
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 400)
    }

    // MARK: - Setup Dialog

    private var setupDialog: some View {
        VStack(spacing: 16) {
            Text("ABX 测试设置").font(.system(size: 17 * k, weight: .bold))
            Text("请输入测试轮数，0为无限")
            TextField("轮数", text: $vm.abxSetupRoundText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
            HStack {
                Button("取消") {
                    vm.abxIsActive = false
                    vm.abxShowSetup = false
                    vm.compareMode = .versionCompare
                }
                Button("确认") {
                    vm.abxShowSetup = false
                    vm.abxShowConfirm = true
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Confirm Dialog

    private var confirmDialog: some View {
        VStack(spacing: 12) {
            Text("确认测试信息").font(.system(size: 17 * k, weight: .bold))
            if let nameA = vm.trackA?.displayName {
                Text("\(nameA) 作为A轨道")
            }
            if let nameB = vm.trackB?.displayName {
                Text("\(nameB) 作为B轨道")
            }
            let rounds = Int(vm.abxSetupRoundText) ?? 0
            Text("测试轮数：\(rounds == 0 ? "无限" : "\(rounds)")")
            Text("是否开始？")
            HStack {
                Button("取消") {
                    vm.abxShowConfirm = false
                    vm.abxShowSetup = true
                }
                Button("返回主界面") {
                    vm.abxIsActive = false
                    vm.abxShowConfirm = false
                    vm.abxShowSetup = false
                    vm.compareMode = .versionCompare
                }
                Button("确认开始") {
                    vm.startABX()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Test View

    private var testView: some View {
        VStack(spacing: 16) {
            let totalText = vm.abxTotalRounds == 0 ? "无限" : "\(vm.abxTotalRounds)"
            Text("第 \(vm.abxRounds.count) 轮 / \(totalText)")
                .font(.system(size: 15 * k, weight: .bold))

            let round = vm.abxCurrentRound

            HStack(spacing: 16) {
                abxButton(label: "A", action: { vm.abxSelectA() },
                          isActive: vm.abxLastChoice == "A")
                abxButton(label: "X", action: { vm.abxSelectX() },
                          isActive: vm.abxLastChoice == "X")
                abxButton(label: "B", action: { vm.abxSelectB() },
                          isActive: vm.abxLastChoice == "B")
            }

            progressBarSection

            HStack(spacing: 16) {
                Button(action: { vm.stopPlayback() }) {
                    Image(systemName: "stop.fill")
                }
                Button(action: { vm.playFromStart() }) {
                    Image(systemName: "play.fill")
                }
                Button(action: { vm.pause() }) {
                    Image(systemName: "pause.fill")
                }
            }
            .buttonStyle(.bordered)

            Divider()

            Text("X是？")
                .font(.system(size: 13 * k, weight: .semibold))
            HStack(spacing: 20) {
                abxAnswerButton(label: "A", chosen: round?.userAnswer == true) {
                    vm.abxAnswer(true)
                }
                abxAnswerButton(label: "B", chosen: round?.userAnswer == false) {
                    vm.abxAnswer(false)
                }
            }

            HStack(spacing: 20) {
                Button("结束") { vm.abxEnd() }
                    .buttonStyle(.bordered)
                Button("确定并继续 (Z)") { vm.abxContinue() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func abxAnswerButton(label: String, chosen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13 * k, weight: .semibold))
                .frame(width: 60, height: 36)
                .background(chosen ? Color.accentColor.opacity(0.6) : Color(white: 0.25))
                .foregroundColor(.white)
                .cornerRadius(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func abxButton(label: String, action: @escaping () -> Void, isActive: Bool) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 22 * k, weight: .bold))
                .frame(width: 80, height: 60)
                .background(isActive ? Color.accentColor.opacity(0.3) : Color(white: 0.2))
                .cornerRadius(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var progressBarSection: some View {
        // 轨内跨度：偏移在双轨视图里就能拧，切到盲听时那一轨的尺子也跟着变了。
        let duration = vm.laneDuration(vm.activeTrack)

        return VStack(spacing: 4) {
            // Waveform deliberately hidden in ABX: its green/blue tint would
            // reveal which side is routed to the listener and spoil the blind test.
            // 同一条理由也管着这条进度条 —— 它画的就是当前路由那一轨，
            // 所以填充色换成两轨共用的 .abxPlayed，不再跟着分轨。
            LiveProgress(clock: vm.clock,
                         side: vm.activeTrack,
                         duration: duration,
                         markers: [],
                         range: nil,
                         isSelectingRange: false,
                         fillColor: .abxPlayed,
                         onSeek: { time, _ in vm.seek(to: time) })
                .frame(height: 32)

            LiveTimeRow(clock: vm.clock, side: vm.activeTrack, duration: duration, onSeek: { _ in })
        }
    }

    // MARK: - Result View

    private var resultView: some View {
        VStack(spacing: 12) {
            Text("ABX 测试结果").font(.system(size: 17 * k, weight: .bold))

            ScrollView {
                VStack(spacing: 0) {
                    HStack {
                        Text("轮次").frame(width: colW)
                        Text("X 是").frame(width: colW)
                        Text("回答").frame(width: colW)
                        Text("结果").frame(width: colW)
                    }
                    .font(.system(size: 13 * k, weight: .semibold))
                    .padding(.vertical, 4)
                    Divider()

                    ForEach(vm.abxRounds) { round in
                        HStack {
                            Text("\(round.roundNumber)").frame(width: colW)
                            Text(round.xIsA ? "A" : "B").frame(width: colW)
                            Text(round.userAnswer == true ? "A" : (round.userAnswer == false ? "B" : "-")).frame(width: colW)
                            Text(round.isCorrect == true ? "✅" : "❌").frame(width: colW)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxHeight: 250)

            Divider()
            let answered = vm.abxRounds.filter { $0.userAnswer != nil }.count
            let correct = vm.abxCorrectCount
            Text("合计正确: \(correct)/\(answered)")
                .font(.system(size: 13 * k, weight: .semibold))

            if answered > 0 {
                let p = abxGuessProbability(correct: correct, trials: answered)
                Text("置信度 \(abxPercent(1 - p))% · 随机命中概率 p = \(abxPercent(p))%（单侧二项检验）")
                    .font(.system(size: 13 * k))
                Text(abxVerdict(p))
                    .font(.system(size: 13 * k, weight: .semibold))
                    .foregroundColor(p < 0.05 ? .green : .orange)
                Text("p 值是「完全靠随机猜测也能达到或超过这一成绩」的概率，p 越小成绩越不可能是蒙出来的；通常以 p < 0.05 作为可分辨的判定线。未作答的轮次不计入。")
                    .font(.system(size: 11 * k))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("没有已作答的轮次，无法计算置信度。")
                    .font(.system(size: 13 * k))
                    .foregroundColor(.secondary)
            }

            Button("关闭") { vm.abxCloseResult() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - 置信度（单侧二项检验）

/// 完全靠随机猜测（每轮 50%）也能答对 ≥ correct 轮的概率，就是单侧 p 值。
/// 精确二项：p = Σ_{i=k}^{N} C(N,i) / 2^N。组合数走 lgamma，轮数上百也不溢出。
private func abxGuessProbability(correct: Int, trials: Int) -> Double {
    guard trials > 0 else { return 1 }
    let k = max(0, min(correct, trials))
    var sum = 0.0
    for i in k...trials {
        let logC = lgamma(Double(trials) + 1) - lgamma(Double(i) + 1) - lgamma(Double(trials - i) + 1)
        sum += exp(logC - Double(trials) * log(2))
    }
    return min(max(sum, 0), 1)
}

/// 百分比按量级给位数：常规两位，不到 0.01% 留四位小数，接近满格时写 >99.99 而不是 100。
private func abxPercent(_ fraction: Double) -> String {
    let v = fraction * 100
    if v >= 99.995 { return ">99.99" }
    if v < 0.01 { return String(format: "%.4f", v) }
    return String(format: "%.2f", v)
}

private func abxVerdict(_ p: Double) -> String {
    if p < 0.01 { return "判定：高度显著（p < 1%），可分辨。" }
    if p < 0.05 { return "判定：显著（p < 5%），可分辨。" }
    return "判定：未达显著（p ≥ 5%），还不能排除随机命中。"
}
