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
            Text("实时数据 \(rate, specifier: "%.1f") Hz")
        }
        Divider()
        Toggle("自动隐私保护", isOn: Binding(get: { features.privacyEnabled }, set: features.setPrivacyEnabled))
        Text(features.snapshot.privacy.status)
        Button(features.snapshot.privacy.isShielded ? "解除隐私遮挡" : "立即遮挡所有屏幕") {
            if features.snapshot.privacy.isShielded { features.hideShield() } else { features.showShield() }
        }
        .keyboardShortcut("p", modifiers: [.command, .control])
        Button("校准屏幕中立方向", action: features.calibrateNeutral)
            .disabled(!features.snapshot.sensorReady || features.snapshot.privacy.isShielded || features.snapshot.exercise.isActive)
        Divider()
        Button(features.snapshot.exercise.isActive ? "打开颈部活动" : "开始颈部活动") {
            features.startExercise()
            openWindow(id: "neck-exercise")
            NSApp.activate(ignoringOtherApps: true)
        }
        .disabled(features.snapshot.privacy.isShielded)
        if features.snapshot.automaticSuspended { Text("活动期间，隐私自动触发已暂停") }
        Divider()
        Button("运动数据调试") {
            openWindow(id: "motion-lab")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(motion.snapshot.isRequested ? "停止传感器采集" : "开始传感器采集") {
            if motion.snapshot.isRequested { motion.stop() } else { motion.start() }
        }
        SettingsLink { Text("功能设置…") }
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
