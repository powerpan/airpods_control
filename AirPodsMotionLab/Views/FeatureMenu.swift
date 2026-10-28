import AppKit
import SwiftUI

@MainActor
struct FeatureMenu: View {
    let motion: MotionStore
    let features: InteractionStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("\(motion.snapshot.source.title) · \(motion.snapshot.phase.title)")
        if let rate = motion.snapshot.latest?.measuredFrequency, motion.snapshot.phase == .streaming {
            Text("實時數據 \(rate, specifier: "%.1f") Hz")
        }
        Divider()
        Toggle("自動隱私保護", isOn: Binding(get: { features.privacyEnabled }, set: features.setPrivacyEnabled))
        Text(features.snapshot.privacy.status)
        if features.privacyEnabled, features.privacySettings.departureDetectionEnabled {
            Text(features.snapshot.departureStatus)
        }
        Button(features.snapshot.privacy.isShielded ? "解除隱私遮擋" : "立即遮擋所有屏幕") {
            if features.snapshot.privacy.isShielded { features.hideShield() } else { features.showShield() }
        }
        .keyboardShortcut("p", modifiers: [.command, .control])
        Button("校準屏幕中立方向", action: features.calibrateNeutral)
            .disabled(!features.snapshot.sensorReady || features.snapshot.privacy.isShielded || features.snapshot.exercise.isActive)
        Divider()
        Button(features.snapshot.exercise.isActive ? "打開頸部活動" : "開始頸部活動") {
            features.startExercise()
            openWindow(id: "neck-exercise")
            NSApp.activate(ignoringOtherApps: true)
        }
        .disabled(features.snapshot.privacy.isShielded)
        if features.snapshot.automaticSuspended { Text("活動期間，轉頭與離座判定已暫停") }
        Divider()
        Button("運動數據調試") {
            openWindow(id: "motion-lab")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(motion.snapshot.isRequested ? "停止傳感器採集" : "開始傳感器採集") {
            if motion.snapshot.isRequested { motion.stop() } else { motion.start() }
        }
        SettingsLink { Text("功能設置…") }
        Divider()
        Button("退出 AirPods Motion Lab") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
struct FeatureToolbarMenu: View {
    let motion: MotionStore
    let features: InteractionStore
    var body: some View {
        Menu {
            FeatureMenu(motion: motion, features: features)
        } label: {
            Label("功能", systemImage: "square.grid.2x2")
        }
    }
}
