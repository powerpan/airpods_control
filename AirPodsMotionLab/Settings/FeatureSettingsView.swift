import SwiftUI
import InteractionCore

@MainActor
struct FeatureSettingsView: View {
    let store: InteractionStore

    var body: some View {
        TabView {
            privacySettings
                .tabItem { Label("隐私保护", systemImage: "eye.slash") }
            exerciseSettings
                .tabItem { Label("颈部活动", systemImage: "figure.mind.and.body") }
        }
        .padding(18)
        .frame(width: 590, height: 590)
    }

    private var privacySettings: some View {
        Form {
            Section {
                Toggle("自动隐私保护", isOn: Binding(
                    get: { store.privacyEnabled },
                    set: { store.setPrivacyEnabled($0) }
                ))
                Text(store.snapshot.privacy.status)
                    .font(.caption).foregroundStyle(.secondary)
                Button("将当前正视方向设为中立", action: store.calibrateNeutral)
                    .disabled(!store.snapshot.sensorReady || store.snapshot.privacy.isShielded || store.snapshot.automaticSuspended)
            } header: {
                Text("面向屏幕时校准")
            } footer: {
                Text("自动检测使用校准后的相对姿态。颈部活动期间暂停自动触发，结束后需要重新校准。")
            }

            Section("离开屏幕方向") {
                SettingSlider(label: "触发角度", value: privacyBinding(\.triggerAngle), range: 20...75, step: 1, unit: "°")
                SettingSlider(label: "持续时间", value: privacyBinding(\.triggerDelay), range: 0.2...3, step: 0.1, unit: "秒", fractionDigits: 1)
            }

            Section("回到中立方向") {
                SettingSlider(label: "恢复范围", value: privacyBinding(\.returnAngle), range: 5...(store.privacySettings.triggerAngle - 5), step: 1, unit: "°")
                SettingSlider(label: "稳定时间", value: privacyBinding(\.returnDelay), range: 0.3...3, step: 0.1, unit: "秒", fractionDigits: 1)
                Text("恢复角度始终小于触发角度，避免阈值附近反复遮挡。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button(store.snapshot.privacy.isShielded ? "解除遮挡" : "立即遮挡") {
                        if store.snapshot.privacy.isShielded { store.hideShield() }
                        else { store.showShield() }
                    }
                    Spacer()
                    Text("遮挡时可按 Esc 解除")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("这是视觉遮挡，不是系统锁屏。耳机断连时保留已有遮挡；遮挡界面的解除按钮始终可用。系统安全窗口及某些 Spaces 场景可能不被覆盖。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var exerciseSettings: some View {
        Form {
            Section {
                Text("跟随面向你的 3D 模型做镜像动作。超过设定幅度并保持，再返回中立进入下一步；不需要精确对准角度。")
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("舒适范围")
            }

            Section {
                SettingSlider(label: "左右转头", value: exerciseBinding(\.yawAngle), range: 10...35, step: 1, unit: "°")
                SettingSlider(label: "左右侧倾", value: exerciseBinding(\.tiltAngle), range: 5...20, step: 1, unit: "°")
                SettingSlider(label: "轻微低头", value: exerciseBinding(\.nodAngle), range: 5...20, step: 1, unit: "°")
                SettingSlider(label: "达幅保持", value: exerciseBinding(\.stableHold), range: 0.3...2, step: 0.1, unit: "秒", fractionDigits: 1)
                SettingSlider(label: "返回保持", value: exerciseBinding(\.returnHold), range: 0.3...2, step: 0.1, unit: "秒", fractionDigits: 1)
            }
            .disabled(exerciseSettingsLocked)

            Section {
                Toggle("反转转头方向", isOn: signBinding(\.yawSign))
                Toggle("反转侧倾方向", isOn: signBinding(\.rollSign))
                Toggle("反转低头方向", isOn: signBinding(\.pitchSign))
                Text("模型面向你：模型向它的右侧转，你向左转。校准后小幅核对；若动作幅度被识别为相反方向，再反转相应轴。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("方向校验")
            }
            .disabled(exerciseSettingsLocked)

            if exerciseSettingsLocked {
                Text("活动进行中。请先结束活动，再调整角度或方向，避免目标在动作中改变。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("疼痛、眩晕或不适时立即停止。这是轻缓活动引导，不用于医疗诊断、治疗或康复。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var exerciseSettingsLocked: Bool {
        let phase = store.snapshot.exercise.phase
        return phase != .idle && phase != .awaitingCalibration && phase != .completed
    }

    private func privacyBinding(_ keyPath: WritableKeyPath<PrivacySettings, Double>) -> Binding<Double> {
        Binding(
            get: { store.privacySettings[keyPath: keyPath] },
            set: { value in
                var settings = store.privacySettings
                settings[keyPath: keyPath] = value
                store.updatePrivacySettings(settings)
            }
        )
    }

    private func exerciseBinding(_ keyPath: WritableKeyPath<NeckExerciseSettings, Double>) -> Binding<Double> {
        Binding(
            get: { store.exerciseSettings[keyPath: keyPath] },
            set: { value in
                var settings = store.exerciseSettings
                settings[keyPath: keyPath] = value
                store.updateExerciseSettings(settings)
            }
        )
    }

    private func signBinding(_ keyPath: WritableKeyPath<NeckExerciseSettings, Double>) -> Binding<Bool> {
        Binding(
            get: { store.exerciseSettings[keyPath: keyPath] < 0 },
            set: { value in
                var settings = store.exerciseSettings
                settings[keyPath: keyPath] = value ? -1 : 1
                store.updateExerciseSettings(settings)
            }
        )
    }
}

private struct SettingSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    var fractionDigits = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                Spacer()
                Text("\(value.formatted(.number.precision(.fractionLength(fractionDigits))))\(unit)")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(label)
        }
        .padding(.vertical, 3)
    }
}
