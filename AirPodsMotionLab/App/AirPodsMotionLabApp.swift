import AppKit
import SwiftUI

@main
@MainActor
struct AirPodsMotionLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var model: ApplicationModel { delegate.model }

    // The menu-bar extra is declared first: SwiftUI opens the first window
    // scene at launch, and this utility should start with no window at all.
    // Every window below opens only from the menu.
    var body: some Scene {
        MenuBarExtra {
            FeatureMenu(motion: model.motion, features: model.features)
        } label: {
            Label("AirPods Motion Lab · \(model.features.privacyIndicator.title)",
                  systemImage: model.features.privacyIndicator.symbol)
        }
        .menuBarExtraStyle(.menu)

        Window("運動數據調試", id: "motion-lab") {
            ContentView(store: model.motion, features: model.features)
                .appWindow()
        }
        .defaultSize(width: 1040, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("採集") {
                Button("開始採集", action: model.motion.start)
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(!model.motion.canStart)
                Button("停止採集", action: model.motion.stop)
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(!model.motion.canStop)
                Divider()
                Button(model.motion.isDisplayPaused ? "恢復顯示" : "暫停顯示", action: model.motion.toggleDisplayPause)
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Button("重新校準", action: model.motion.calibrate)
                    .keyboardShortcut("k", modifiers: [.command])
                    .disabled(!model.motion.canCalibrate)
            }
        }

        Window("頸部活動", id: "neck-exercise") {
            ExerciseView(store: model.features)
                .appWindow()
                .background(WindowCloseObserver { model.features.endExercise() })
                .onDisappear { model.features.endExercise() }
        }
        .defaultSize(width: 840, height: 860)
        .windowResizability(.contentMinSize)

        Settings {
            FeatureSettingsView(store: model.features, system: model.system)
                .appWindow()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Owned here rather than by a view so sensing, the privacy shield and the
    // global shortcut start at launch even though no window opens.
    let model = ApplicationModel()
    private var terminationRequested = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await model.activate() }
    }

    // Closing a utility/debug window leaves the explicit menu-bar controls alive.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationRequested else { return .terminateNow }
        terminationRequested = true
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
