import AppKit
import SwiftUI

/// Owns visual shielding only. The feature state machine decides when to show
/// or hide it, including keeping it visible after a sensor interruption.
@MainActor
final class PrivacyOverlayController {
    private let onDismiss: @MainActor () -> Void
    private let presentation = PrivacyOverlayPresentation()
    private let resources = PrivacyOverlayResources()
    private var wantsVisible = false
    private var transitionGeneration = 0
    private var transitionTask: Task<Void, Never>?
    private var previousApplication: NSRunningApplication?
    private weak var previousKeyWindow: NSWindow?

    var isVisible: Bool { !resources.panels.isEmpty }
    /// Requested state differs from isVisible during the brief exit animation.
    var isRequestedVisible: Bool { wantsVisible }
    var coveredScreenCount: Int { resources.panels.count }

    init(onDismiss: @escaping @MainActor () -> Void) {
        self.onDismiss = onDismiss
        installObservers()
    }

    func show(status: String) {
        updateStatus(status)
        guard !wantsVisible else { return }
        let wasVisible = isVisible
        wantsVisible = true
        transitionGeneration += 1
        transitionTask?.cancel()
        transitionTask = nil

        if !wasVisible {
            previousApplication = NSWorkspace.shared.frontmostApplication
            previousKeyWindow = NSApp.keyWindow
            presentation.foregroundVisible = false
        }
        refreshScreens()
        installKeyboardMonitor()
        makePreferredPanelKey()

        // The native backdrop material is ordered in before the foreground
        // animation begins. The window itself never fades its blur in or out.
        let token = transitionGeneration
        transitionTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.wantsVisible, self.transitionGeneration == token else { return }
            self.presentation.foregroundVisible = true
            self.transitionTask = nil
        }
    }

    func updateStatus(_ status: String) {
        if presentation.status != status { presentation.status = status }
    }

    func hide() {
        // Snapshot polling may repeat the same desired state. Once an exit
        // begins, do not restart its timer while the panels still exist.
        guard wantsVisible else { return }
        wantsVisible = false
        transitionGeneration += 1
        let token = transitionGeneration
        transitionTask?.cancel()
        presentation.foregroundVisible = false

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            finishHiding(generation: token)
            return
        }
        // Keep the backdrop blur during the small foreground fade. A rapid
        // show cancels this task, so an old completion cannot close new panels.
        transitionTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            self?.finishHiding(generation: token)
        }
    }

    func shutdown() {
        wantsVisible = false
        transitionGeneration += 1
        transitionTask?.cancel()
        transitionTask = nil
        resources.cleanup()
        previousApplication = nil
        previousKeyWindow = nil
    }

    private func finishHiding(generation: Int) {
        guard !wantsVisible, generation == transitionGeneration else { return }
        resources.closePanels()
        resources.removeKeyboardMonitor()
        transitionTask = nil
        restorePreviousFocusIfAppropriate()
    }

    private func installObservers() {
        let screens = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshScreens() }
        }
        resources.observers.append((NotificationCenter.default, screens))

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            let observer = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshScreens() }
            }
            resources.observers.append((workspace, observer))
        }
    }

    private func installKeyboardMonitor() {
        guard resources.keyboardMonitor == nil else { return }
        resources.keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local event monitors execute in AppKit's main-thread event path.
            let dismissed = MainActor.assumeIsolated {
                guard let self, self.wantsVisible, Self.isDismissKey(event) else { return false }
                self.onDismiss()
                return true
            }
            return dismissed ? nil : event
        }
    }

    fileprivate static func isDismissKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { return true } // Escape, independent of keyboard layout.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains([.command, .shift]) && !flags.contains(.option) && !flags.contains(.control)
            && event.charactersIgnoringModifiers?.lowercased() == "p"
    }

    private func refreshScreens() {
        guard wantsVisible else { return }
        let screens = NSScreen.screens
        // Display reconfiguration can transiently report no screens. Retain
        // existing covers until the next screen-change notification.
        guard !screens.isEmpty else { return }
        var replacements: [String: PrivacyShieldPanel] = [:]

        for (index, screen) in screens.enumerated() {
            let key = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                .map { String(describing: $0) } ?? "screen-\(index)"
            if let panel = resources.panels[key], panel.frame == screen.frame {
                replacements[key] = panel
                panel.orderFrontRegardless()
            } else {
                let panel = makePanel(for: screen)
                replacements[key] = panel
                panel.orderFrontRegardless()
            }
        }

        // New/repositioned display covers are ordered in before old ones go
        // away. AppKit does not provide an atomic all-display transaction.
        for (key, old) in resources.panels where replacements[key] !== old {
            old.orderOut(nil)
            old.close()
        }
        resources.panels = replacements
        if NSApp.keyWindow == nil { makePreferredPanelKey() }
    }

    private func makePanel(for screen: NSScreen) -> PrivacyShieldPanel {
        let panel = PrivacyShieldPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false, screen: screen
        )
        panel.onDismiss = { [weak self] in self?.onDismiss() }
        panel.title = "Privacy Mode · \(screen.localizedName)"
        panel.identifier = NSUserInterfaceItemIdentifier("privacy-shield")
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.alphaValue = 1
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [
            .canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary,
            .stationary, .ignoresCycle
        ]
        panel.isMovable = false
        panel.canHide = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.worksWhenModal = true
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.tabbingMode = .disallowed
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = false
        let backdrop = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
        // Use a floating HUD treatment while retaining native behind-window
        // blur. The system determines its exact tint and translucency.
        // Keep alpha at 1: fading the whole material would
        // mix sharp desktop pixels back in and also fade its foreground.
        // There is no screen-image capture, filter-radius override or private API.
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.appearance = NSAppearance(named: .aqua)
        let foreground = ShieldHostingView(rootView: PrivacyOverlayView(presentation: presentation) { [weak self] in
            self?.onDismiss()
        })
        foreground.translatesAutoresizingMaskIntoConstraints = false
        foreground.wantsLayer = true
        foreground.layer?.backgroundColor = NSColor.clear.cgColor
        backdrop.addSubview(foreground)
        NSLayoutConstraint.activate([
            foreground.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            foreground.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            foreground.topAnchor.constraint(equalTo: backdrop.topAnchor),
            foreground.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor)
        ])
        panel.contentView = backdrop
        panel.setFrame(screen.frame, display: true)
        return panel
    }

    private func makePreferredPanelKey() {
        let pointer = NSEvent.mouseLocation
        let panel = resources.panels.values.first(where: { $0.frame.contains(pointer) })
            ?? resources.panels.values.first
        // A nonactivating panel can receive keys without activating this app
        // or switching the user's frontmost application merely to show a cover.
        panel?.makeKeyAndOrderFront(nil)
    }

    private func restorePreviousFocusIfAppropriate() {
        defer { previousApplication = nil; previousKeyWindow = nil }
        if let window = previousKeyWindow, window.isVisible,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            window.makeKeyAndOrderFront(nil)
        } else if let previousApplication, !previousApplication.isTerminated,
                  previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            previousApplication.activate(options: [])
        }
    }

    deinit {
        transitionTask?.cancel()
        let resources = resources
        Task { @MainActor in resources.cleanup() }
    }
}

/// Main-actor methods own every AppKit object. The sendable reference lets a
/// nonisolated controller deinit schedule cleanup without moving window access
/// to a background thread; no mutable member is exposed outside the main actor.
private final class PrivacyOverlayResources: @unchecked Sendable {
    @MainActor var panels: [String: PrivacyShieldPanel] = [:]
    @MainActor var keyboardMonitor: Any?
    @MainActor var observers: [(NotificationCenter, NSObjectProtocol)] = []

    @MainActor init() {}

    @MainActor func closePanels() {
        for panel in panels.values { panel.orderOut(nil); panel.close() }
        panels.removeAll()
    }

    @MainActor func removeKeyboardMonitor() {
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        keyboardMonitor = nil
    }

    @MainActor func cleanup() {
        closePanels()
        removeKeyboardMonitor()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }
}

@MainActor
private final class PrivacyShieldPanel: NSPanel {
    var onDismiss: (@MainActor () -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func cancelOperation(_ sender: Any?) { onDismiss?() }

    override func keyDown(with event: NSEvent) {
        if PrivacyOverlayController.isDismissKey(event) { onDismiss?() }
        else { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if PrivacyOverlayController.isDismissKey(event) { onDismiss?(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private final class ShieldHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
