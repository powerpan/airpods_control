import AppKit
import SwiftUI

@main
@MainActor
struct AirPodsMotionLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = ApplicationModel()

    var body: some Scene {
        Window("AirPods Motion Lab", id: "motion-lab") {
            ContentView(store: model.motion, features: model.features)
                .task {
                    delegate.model = model
                    await model.activate()
                }
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

        MenuBarExtra {
            FeatureMenu(motion: model.motion, features: model.features)
                .task { await activateModel() }
        } label: {
            Label("AirPods Motion Lab · \(model.features.privacyIndicator.title)",
                  systemImage: model.features.privacyIndicator.symbol)
                .task { await activateModel() }
        }
        .menuBarExtraStyle(.menu)

        Window("Neck Exercise", id: "neck-exercise") {
            ExerciseView(store: model.features)
                .task { await activateModel() }
                .background(WindowCloseObserver { model.features.endExercise() })
                .onDisappear { model.features.endExercise() }
        }
        .defaultSize(width: 840, height: 860)
        .windowResizability(.contentMinSize)

        Settings {
            FeatureSettingsView(store: model.features)
                .task { await activateModel() }
        }
    }

    private func activateModel() async {
        delegate.model = model
        await model.activate()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: ApplicationModel?
    private var terminationRequested = false

    // Closing a utility/debug window leaves the explicit menu-bar controls alive.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationRequested, let model else { return .terminateNow }
        terminationRequested = true
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
