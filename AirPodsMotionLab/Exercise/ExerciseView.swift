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
                        Text("镜像跟随 · 模型向它的右侧转，你向左转")
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
                    Button("结束并返回", action: finish)
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
                    Label("设置", systemImage: "slider.horizontal.3")
                }
                .help("调整舒适角度范围与方向")
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
                Text("给颈部一点活动空间")
                    .font(.system(size: 25, weight: .medium, design: .rounded))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                Label(isSimulated ? "模拟姿态" : (store.snapshot.sensorReady ? "姿态已连接" : "等待 AirPods"),
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
        .accessibilityLabel("动作流程：左转、右转、左侧倾、右侧倾、轻微低头")
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
                    metric(phase == .returning ? "偏离中立" : "当前动作幅度", value: measuredLabel)
                    metric(phase == .returning ? "返回范围" : "设定幅度", value: thresholdLabel)
                    metric("活动用时", value: duration(exercise.elapsed))
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 18) {
                    poseValue("转头", angle: exercise.currentPose.map { $0.yaw * store.exerciseSettings.yawSign })
                    poseValue("侧倾", angle: exercise.currentPose.map { $0.roll * store.exerciseSettings.rollSign })
                    poseValue("低头", angle: exercise.currentPose.map { $0.pitch * store.exerciseSettings.pitchSign })
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
                Text(phase == .returning ? "返回中立 · 保持" : "达到幅度 · 保持")
                Spacer()
                Text("\(Int((min(1, max(0, exercise.progress)) * 100).rounded()))%")
                    .monospacedDigit()
            }
            .font(.caption.weight(.medium))
            ProgressView(value: min(1, max(0, exercise.progress)), total: 1)
                .tint(.teal)
                .accessibilityLabel("持续保持进度")
            Text(phase == .returning
                 ? "回到自然正视姿态，稍作停留后进入下一步。"
                 : "沿示范方向达到设定幅度后，连续保持即可；无需精确对准角度。")
                .font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 460)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if phase == .idle {
                Button("开始一组活动", action: store.startExercise)
                    .buttonStyle(.borderedProminent)
            } else if phase == .awaitingCalibration || phase == .signalLost {
                Button("校准并开始", action: store.calibrateExercise)
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.snapshot.sensorReady)
                    .help("自然坐好并看向屏幕，将此刻作为舒适的中立位置")
            } else if phase == .paused {
                Button("继续", action: store.resumeExercise)
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.snapshot.sensorReady)
            } else {
                Button("暂停", action: store.pauseExercise)
                    .buttonStyle(.bordered)
            }

            if !isPreparing {
                Button("跳过", action: store.skipExercise)
                    .disabled(phase == .signalLost)
                Button("重新校准", action: store.calibrateExercise)
                    .disabled(!store.snapshot.sensorReady)
            }
            Spacer(minLength: 24)
            Button("结束活动", action: finish)
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
                Text(exercise.completedCount == 5 ? "这一组，完成了" : "这一组，结束了")
                    .font(.system(size: 30, weight: .medium, design: .rounded))
                Text("回到自然、舒服的位置。")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 38) {
                metric("完成动作", value: "\(exercise.completedCount)")
                metric("跳过动作", value: "\(exercise.skippedCount)")
                metric("活动用时", value: duration(exercise.elapsed))
            }
            .padding(.vertical, 14)
            Text("回到工作位置后，请重新校准隐私检测的中立方向。")
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
                Text("只在舒适范围内缓慢活动；疼痛或眩晕时立即停止。这是轻缓活动引导，不是医疗或康复训练。")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .padding(.top, 6)
            if store.snapshot.automaticSuspended {
                Text("活动期间，隐私保护的自动姿态触发已暂停。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if isSimulated {
                Label("当前为模拟数据，活动结果不代表真实动作。", systemImage: "waveform.path")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var instructionTitle: String {
        switch phase {
        case .idle, .awaitingCalibration: "先找到舒服的中立位置"
        case .approaching: exercise.currentStep?.title ?? "缓慢活动"
        case .returning: "慢慢回到中间"
        case .paused: "休息一下，随时继续"
        case .signalLost: "等待头部姿态恢复"
        case .completed: "这一组，完成了"
        }
    }

    private var instructionDetail: String {
        switch phase {
        case .idle, .awaitingCalibration:
            "自然坐好，面向屏幕。校准后，缓慢跟随面向你的模型做镜像动作。"
        case .approaching:
            "在舒适范围内达到 \(Int(targetRange.rounded()))°，保持 \(store.exerciseSettings.stableHold.formatted(.number.precision(.fractionLength(1)))) 秒。模型会停下来等你。"
        case .returning:
            "跟随模型回到自然正视位置，放松并稍作停留，再进入下一个动作。"
        case .paused:
            "当前动作的保持进度已暂停。继续时仍需通过实际姿态完成动作。"
        case .signalLost:
            "动作判定已暂停。确认耳机连接后，面向屏幕重新校准。"
        case .completed:
            "你可以结束活动，回到工作。"
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
        case .turnLeft: "左转"
        case .turnRight: "右转"
        case .tiltLeft: "左侧倾"
        case .tiltRight: "右侧倾"
        case .nod: "轻微低头"
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
