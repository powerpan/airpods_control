import SwiftUI
import InteractionCore

@MainActor
struct FeatureSettingsView: View {
    let store: InteractionStore
    let system: SystemIntegrationStore

    var body: some View {
        TabView {
            privacySettings
                .tabItem { Label("隱私保護", systemImage: "eye.slash") }
            exerciseSettings
                .tabItem { Label("頸部活動", systemImage: "figure.mind.and.body") }
        }
        .padding(18)
        .frame(width: 590, height: 590)
    }

    private var privacySettings: some View {
        Form {
            Section {
                Toggle("自動隱私保護", isOn: Binding(
                    get: { store.privacyEnabled },
                    set: { store.setPrivacyEnabled($0) }
                ))
                Text(store.snapshot.privacy.status)
                    .font(.caption).foregroundStyle(.secondary)
                Button("將目前正視方向設為中立", action: store.calibrateNeutral)
                    .disabled(!store.snapshot.sensorReady || store.snapshot.privacy.isShielded || store.snapshot.automaticSuspended)
            } header: {
                Text("面向屏幕時校準")
            } footer: {
                Text("校準觀看屏幕的中立方向。頸部活動期間暫停轉頭判定，結束後需要重新校準。")
            }

            Section("耳機資料中斷") {
                Toggle("啟用資料中斷保護", isOn: privacyBinding(\.shieldOnDataLossEnabled))
                Text("資料短暫停滯時，從最後一筆有效資料起等待 3 秒；同一連線及有效參考下及時恢復，就保留校準並繼續偵測。明確斷連、裝置切換造成的斷連、睡眠或超時會保持遮擋，需手動解除後重新校準。手動停止採集、結束應用及頸部活動期間不新增遮擋。關閉後資料中斷只會停止偵測。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("保護由已就緒變為未就緒並持續數秒時，會發出系統通知提醒重新校準。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("離開屏幕方向") {
                SettingSlider(label: "觸發角度", value: privacyBinding(\.triggerAngle), range: 20...75, step: 1, unit: "°")
                SettingSlider(label: "持續時間", value: privacyBinding(\.triggerDelay), range: 0.2...3, step: 0.1, unit: "秒", fractionDigits: 1)
            }

            Section("回到中立方向") {
                SettingSlider(label: "恢復範圍", value: privacyBinding(\.returnAngle), range: 5...(store.privacySettings.triggerAngle - 5), step: 1, unit: "°")
                SettingSlider(label: "穩定時間", value: privacyBinding(\.returnDelay), range: 0.3...3, step: 0.1, unit: "秒", fractionDigits: 1)
                Text("只適用於普通轉頭遮擋。恢復角度始終小於觸發角度，避免閾值附近反覆遮擋。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button(store.snapshot.privacy.isShielded ? "解除遮擋" : "立即遮擋") {
                        if store.snapshot.privacy.isShielded { store.hideShield() }
                        else { store.showShield() }
                    }
                    Spacer()
                    Text("遮擋窗口收到按鍵時可按 Esc 解除")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("這是視覺遮擋，不是系統鎖屏。耳機斷連時保留已有遮擋；遮擋界面的解除按鈕始終可用。系統安全窗口及某些 Spaces 場景可能不被覆蓋。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("開機時啟動", isOn: Binding(
                    get: { system.launchAtLogin },
                    set: { system.setLaunchAtLogin($0) }
                ))
                Text(system.loginItemStatusText)
                    .font(.caption).foregroundStyle(.secondary)
                if system.loginItemStatus == .requiresApproval {
                    Button("打開登入項目設定", action: system.openLoginItemsSettings)
                }
                if let error = system.loginItemError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Toggle("全局快捷鍵 \(system.shieldHotKeyTitle) 立即遮擋所有屏幕", isOn: Binding(
                    get: { system.shieldHotKeyEnabled },
                    set: { system.setShieldHotKeyEnabled($0) }
                ))
                Text(system.shieldHotKeyStatusText)
                    .font(.caption).foregroundStyle(system.shieldHotKeyError == nil ? .secondary : Color.red)
            } header: {
                Text("背景運行")
            } footer: {
                Text("應用常駐菜單欄，沒有打開窗口時不顯示 Dock 圖標。快捷鍵只會遮擋，不會解除遮擋。")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: system.refreshLoginItem)
    }

    private var exerciseSettings: some View {
        Form {
            Section {
                Text("跟隨面向你的 3D 模型做鏡像動作。超過設定幅度並保持，再返回中立進入下一步；不需要精確對準角度。")
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("舒適範圍")
            }

            Section {
                SettingSlider(label: "左右轉頭", value: exerciseBinding(\.yawAngle), range: 10...35, step: 1, unit: "°")
                SettingSlider(label: "左右側傾", value: exerciseBinding(\.tiltAngle), range: 5...20, step: 1, unit: "°")
                SettingSlider(label: "輕微低頭", value: exerciseBinding(\.nodAngle), range: 5...20, step: 1, unit: "°")
                SettingSlider(label: "達幅保持", value: exerciseBinding(\.stableHold), range: 0.3...2, step: 0.1, unit: "秒", fractionDigits: 1)
                SettingSlider(label: "返回保持", value: exerciseBinding(\.returnHold), range: 0.3...2, step: 0.1, unit: "秒", fractionDigits: 1)
            }
            .disabled(exerciseSettingsLocked)

            Section {
                Toggle("反轉轉頭方向", isOn: signBinding(\.yawSign))
                Toggle("反轉側傾方向", isOn: signBinding(\.rollSign))
                Toggle("反轉低頭方向", isOn: signBinding(\.pitchSign))
                Text("模型面向你：模型向它的右側轉，你向左轉。校準後小幅核對；若動作幅度被識別為相反方向，再反轉相應軸。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("方向校驗")
            }
            .disabled(exerciseSettingsLocked)

            if exerciseSettingsLocked {
                Text("活動進行中。請先結束活動，再調整角度或方向，避免目標在動作中改變。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("疼痛、眩暈或不適時立即停止。這是輕緩活動引導，不用於醫療診斷、治療或康復。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var exerciseSettingsLocked: Bool {
        let phase = store.snapshot.exercise.phase
        return phase != .idle && phase != .awaitingCalibration && phase != .completed
    }

    private func privacyBinding<Value>(_ keyPath: WritableKeyPath<PrivacySettings, Value>) -> Binding<Value> {
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
    // A drag edits this draft; the setting (saved, sent to the session, and
    // re-arming detection) is committed once on release. Keyboard and
    // VoiceOver adjustments have no drag and commit immediately.
    @State private var draft: Double?

    private var shown: Double { draft ?? value }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                Spacer()
                Text("\(shown.formatted(.number.precision(.fractionLength(fractionDigits))))\(unit)")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { shown },
                set: { newValue in
                    if draft != nil { draft = newValue } else { value = newValue }
                }
            ), in: range, step: step) { editing in
                if editing {
                    draft = value
                } else if let final = draft {
                    draft = nil
                    if final != value { value = final }
                }
            }
            .accessibilityLabel(label)
        }
        .padding(.vertical, 3)
    }
}
