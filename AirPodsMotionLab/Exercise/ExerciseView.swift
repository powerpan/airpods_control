import SwiftUI
import InteractionCore

@MainActor
struct ExerciseView: View {
    let store: InteractionStore
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var exercise: NeckExerciseMachine { store.snapshot.exercise }
    private var phase: ExercisePhase { exercise.phase }
    private var isPreparing: Bool { phase == .idle || phase == .awaitingCalibration }
    private var isPaused: Bool { phase == .paused || phase == .signalLost }
    private var isSimulated: Bool { store.snapshot.capture.source == .simulation }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    if phase == .completed {
                        completion
                    } else {
                        stepStrip
                        instruction
                        HeadDemonstrationView(
                            yaw: demonstration.yaw,
                            pitch: demonstration.pitch,
                            roll: demonstration.roll,
                            isPaused: isPaused,
                            reduceMotion: reduceMotion
                        )
                        .frame(height: 240)
                        .padding(.horizontal, 20)
                        Text("鏡像跟隨 · 模型向它的右側轉，你向左轉")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.bottom, 8)
                        detailLine
                    }
                }
                .padding(.horizontal, 30)
                .padding(.top, 18)
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
            }
            VStack(spacing: 0) {
                if !isPreparing && phase != .completed {
                    holdFeedback
                        .padding(.top, 12)
                }
                if phase == .completed {
                    Button("結束並返回", action: finish)
                        .buttonStyle(.borderedProminent)
                        .tint(.teal)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .padding(.bottom, 22)
                } else {
                    controls
                }
                footer
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 18)
        }
        .background {
            LinearGradient(colors: [.teal.opacity(0.055), .clear, .indigo.opacity(0.035)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
        }
        .frame(minWidth: 740, minHeight: 650)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: phase)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: exercise.stepIndex)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                SettingsLink {
                    Label("設置", systemImage: "slider.horizontal.3")
                }
                .help("調整舒適角度範圍與方向")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text("NECK EXERCISE")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(2.3)
                    .foregroundStyle(.secondary)
                Text("給頸部一點活動空間")
                    .font(.system(size: 25, weight: .medium, design: .rounded))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                Label(isSimulated ? "模擬姿態" : (store.snapshot.sensorReady ? "姿態已連接" : "等待 AirPods"),
                      systemImage: isSimulated ? "waveform.path" : "airpodspro")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(store.snapshot.sensorReady ? Color.teal : Color.secondary)
                Text("\(exercise.completedCount) / 5 已完成")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 16)
    }

    private var stepStrip: some View {
        HStack(spacing: 0) {
            ForEach(Array(ExerciseStep.allCases.enumerated()), id: \.offset) { index, step in
                let isCurrent = index == exercise.stepIndex && !isPreparing
                HStack(spacing: 7) {
                    Circle()
                        .fill(isCurrent ? Color.teal : Color.secondary.opacity(index < exercise.stepIndex ? 0.45 : 0.14))
                        .frame(width: 6, height: 6)
                    Text(shortTitle(step))
                        .font(.caption.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("動作流程：左轉、右轉、左側傾、右側傾、輕微低頭")
    }

    private var instruction: some View {
        VStack(spacing: 9) {
            Text(instructionTitle)
                .font(.system(size: 28, weight: .medium, design: .rounded))
                .contentTransition(.opacity)
            Text(instructionDetail)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 570)
        }
        .frame(minHeight: 82)
        .padding(.top, 14)
    }

    private var detailLine: some View {
        VStack(spacing: 13) {
            if !isPreparing {
                HStack(spacing: 24) {
                    metric(phase == .returning ? "偏離中立" : "當前動作幅度", value: measuredLabel)
                    metric(phase == .returning ? "返回範圍" : "設定幅度", value: thresholdLabel)
                    metric("活動用時", value: duration(exercise.elapsed))
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 18) {
                    poseValue("轉頭", angle: exercise.currentPose.map { $0.yaw * store.exerciseSettings.yawSign })
                    poseValue("側傾", angle: exercise.currentPose.map { $0.roll * store.exerciseSettings.rollSign })
                    poseValue("低頭", angle: exercise.currentPose.map { $0.pitch * store.exerciseSettings.pitchSign })
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            if let message = store.snapshot.message, !message.isEmpty {
                Text(message)
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 10)
    }

    private var holdFeedback: some View {
        VStack(spacing: 7) {
            Text(exercise.status)
                .font(.callout.weight(.semibold))
                .foregroundStyle(phase == .signalLost ? Color.orange : Color.primary)
                .multilineTextAlignment(.center)
            HStack {
                Text(phase == .returning ? "返回中立 · 保持" : "達到幅度 · 保持")
                Spacer()
                Text("\(Int((min(1, max(0, exercise.progress)) * 100).rounded()))%")
                    .monospacedDigit()
            }
            .font(.caption.weight(.medium))
            ProgressView(value: min(1, max(0, exercise.progress)), total: 1)
                .tint(.teal)
                .accessibilityLabel("持續保持進度")
            Text(phase == .returning
                 ? "回到自然正視姿態，稍作停留後進入下一步。"
                 : "沿示範方向達到設定幅度後，連續保持即可；無需精確對準角度。")
                .font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 460)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if phase == .idle {
                Button("開始一組活動", action: store.startExercise)
                    .buttonStyle(.borderedProminent)
            } else if phase == .awaitingCalibration || phase == .signalLost {
                Button("校準並開始", action: store.calibrateExercise)
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.snapshot.sensorReady)
                    .help("自然坐好並看向屏幕，將此刻作為舒適的中立位置")
            } else if phase == .paused {
                Button("繼續", action: store.resumeExercise)
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.snapshot.sensorReady)
            } else {
                Button("暫停", action: store.pauseExercise)
                    .buttonStyle(.bordered)
            }

            if !isPreparing {
                Button("跳過", action: store.skipExercise)
                    .disabled(phase == .signalLost)
                Button("重新校準", action: store.calibrateExercise)
                    .disabled(!store.snapshot.sensorReady)
            }
            Spacer(minLength: 24)
            Button("結束活動", action: finish)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .controlSize(.large)
        .tint(.teal)
        .padding(.top, 15)
        .padding(.bottom, 22)
    }

    private var completion: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle().fill(.teal.opacity(0.06)).frame(width: 160, height: 160)
                Circle().stroke(.teal.opacity(0.18), lineWidth: 1).frame(width: 130, height: 130)
                Image(systemName: "checkmark")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.teal)
            }
            .padding(.top, 35)
            VStack(spacing: 10) {
                Text(exercise.completedCount == 5 ? "這一組，完成了" : "這一組，結束了")
                    .font(.system(size: 30, weight: .medium, design: .rounded))
                Text("回到自然、舒服的位置。")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 38) {
                metric("完成動作", value: "\(exercise.completedCount)")
                metric("跳過動作", value: "\(exercise.skippedCount)")
                metric("活動用時", value: duration(exercise.elapsed))
            }
            .padding(.vertical, 14)
            Text("回到工作位置後，請重新校準隱私檢測的中立方向。")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 40)
    }

    private var footer: some View {
        VStack(spacing: 9) {
            Divider().opacity(0.5)
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "leaf")
                    .foregroundStyle(.teal)
                Text("只在舒適範圍內緩慢活動；疼痛或眩暈時立即停止。這是輕緩活動引導，不是醫療或康復訓練。")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .padding(.top, 6)
            if store.snapshot.automaticSuspended {
                Text("活動期間，隱私保護的自動姿態觸發已暫停。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if isSimulated {
                Label("當前為模擬數據，活動結果不代表真實動作。", systemImage: "waveform.path")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var instructionTitle: String {
        switch phase {
        case .idle, .awaitingCalibration: "先找到舒服的中立位置"
        case .approaching: exercise.currentStep?.title ?? "緩慢活動"
        case .returning: "慢慢回到中間"
        case .paused: "休息一下，隨時繼續"
        case .signalLost: "等待頭部姿態恢復"
        case .completed: "這一組，完成了"
        }
    }

    private var instructionDetail: String {
        switch phase {
        case .idle, .awaitingCalibration:
            "自然坐好，面向屏幕。校準後，緩慢跟隨面向你的模型做鏡像動作。"
        case .approaching:
            "在舒適範圍內達到 \(Int(targetRange.rounded()))°，保持 \(store.exerciseSettings.stableHold.formatted(.number.precision(.fractionLength(1)))) 秒。模型會停下來等你。"
        case .returning:
            "跟隨模型回到自然正視位置，放鬆並稍作停留，再進入下一個動作。"
        case .paused:
            "當前動作的保持進度已暫停。繼續時仍需通過實際姿態完成動作。"
        case .signalLost:
            "動作判定已暫停。確認耳機連接後，面向屏幕重新校準。"
        case .completed:
            "你可以結束活動，回到工作。"
        }
    }

    private var measuredAngle: Double {
        guard let pose = exercise.currentPose else { return 0 }
        switch exercise.currentStep {
        case .turnLeft: return -pose.yaw * store.exerciseSettings.yawSign
        case .turnRight: return pose.yaw * store.exerciseSettings.yawSign
        case .tiltLeft: return -pose.roll * store.exerciseSettings.rollSign
        case .tiltRight: return pose.roll * store.exerciseSettings.rollSign
        case .nod: return pose.pitch * store.exerciseSettings.pitchSign
        case nil: return 0
        }
    }

    private var measuredLabel: String {
        guard let pose = exercise.currentPose else { return "—" }
        let value = phase == .returning
            ? max(abs(pose.yaw), abs(pose.pitch), abs(pose.roll))
            : measuredAngle
        return "\(Int(value.rounded()))°"
    }

    private var thresholdLabel: String {
        if phase == .returning {
            let tolerance = min(6, min(store.exerciseSettings.yawAngle,
                                       store.exerciseSettings.tiltAngle,
                                       store.exerciseSettings.nodAngle) * 0.5)
            return "≤ \(tolerance.formatted(.number.precision(.fractionLength(0...1))))°"
        }
        return "≥ \(Int(targetRange.rounded()))°"
    }

    private var demonstration: ExerciseTarget {
        guard !isPreparing else { return ExerciseTarget() }
        func withMargin(_ angle: Double) -> Double {
            angle == 0 ? 0 : angle + (angle > 0 ? 2 : -2)
        }
        return ExerciseTarget(
            yaw: withMargin(exercise.target.yaw * store.exerciseSettings.yawSign),
            pitch: withMargin(exercise.target.pitch * store.exerciseSettings.pitchSign),
            roll: withMargin(exercise.target.roll * store.exerciseSettings.rollSign)
        )
    }

    private var targetRange: Double {
        switch exercise.currentStep {
        case .tiltLeft, .tiltRight: store.exerciseSettings.tiltAngle
        case .nod: store.exerciseSettings.nodAngle
        default: store.exerciseSettings.yawAngle
        }
    }

    private func metric(_ label: String, value: String) -> some View {
        VStack(spacing: 5) {
            Text(value).font(.system(size: 19, weight: .medium, design: .rounded)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func poseValue(_ label: String, angle: Double?) -> some View {
        HStack(spacing: 4) {
            Text(label)
            Text(angle.map { "\(Int($0.rounded()))°" } ?? "—")
                .monospacedDigit()
                .frame(minWidth: 29, alignment: .trailing)
        }
    }

    private func shortTitle(_ step: ExerciseStep) -> String {
        switch step {
        case .turnLeft: "左轉"
        case .turnRight: "右轉"
        case .tiltLeft: "左側傾"
        case .tiltRight: "右側傾"
        case .nod: "輕微低頭"
        }
    }

    private func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func finish() {
        store.endExercise()
        dismissWindow(id: "neck-exercise")
    }
}
