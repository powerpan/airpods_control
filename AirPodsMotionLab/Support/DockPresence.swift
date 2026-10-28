import AppKit
import SwiftUI

/// The app runs as a menu-bar agent (`LSUIElement`). While one of its own
/// windows is open it becomes a regular app, so the window gets a Dock icon,
/// the app menu and ⌘Tab; closing the last one hides them again. Privacy
/// overlays and the menu-bar extra never opt in.
@MainActor
enum DockPresence {
    private static var openWindows = Set<ObjectIdentifier>()

    static func windowAppeared(_ window: NSWindow) {
        // A background utility should not reopen debug windows at login.
        window.isRestorable = false
        guard openWindows.insert(ObjectIdentifier(window)).inserted else { return }
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        // Opening from the menu-bar extra leaves the window behind the
        // frontmost app; bring it forward once SwiftUI has ordered it in.
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    static func windowClosed(_ window: NSWindow) {
        guard openWindows.remove(ObjectIdentifier(window)) != nil, openWindows.isEmpty else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}

extension View {
    /// Marks the hosting window as an app window for `DockPresence`.
    func appWindow() -> some View { background(DockPresenceObserver()) }
}

private struct DockPresenceObserver: NSViewRepresentable {
    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ nsView: ObserverView, context: Context) {}

    @MainActor
    final class ObserverView: NSView {
        private var observations: [CloseObservation] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observations = []
            guard let window else { return }
            DockPresence.windowAppeared(window)
            let center = NotificationCenter.default
            // SwiftUI may reuse a closed window for the same scene; becoming
            // key again re-registers it.
            observations = [
                CloseObservation(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { DockPresence.windowAppeared(window) }
                }),
                CloseObservation(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { DockPresence.windowClosed(window) }
                })
            ]
        }
    }
}
