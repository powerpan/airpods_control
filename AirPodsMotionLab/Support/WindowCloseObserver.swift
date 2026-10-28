import AppKit
import SwiftUI

/// Observes only the exercise window, without replacing SwiftUI's delegate.
struct WindowCloseObserver: NSViewRepresentable {
    let onClose: @MainActor () -> Void
    func makeNSView(context: Context) -> ObserverView { ObserverView(onClose: onClose) }
    func updateNSView(_ nsView: ObserverView, context: Context) {}

    @MainActor
    final class ObserverView: NSView {
        private let onClose: @MainActor () -> Void
        private var observer: CloseObservation?
        init(onClose: @escaping @MainActor () -> Void) { self.onClose = onClose; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observer = nil
            guard let window else { return }
            let action = onClose
            let token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                Task { @MainActor in action() }
            }
            observer = CloseObservation(token)
        }
    }
}

/// NotificationCenter removal is thread-safe; the immutable token may be
/// released off the main actor when SwiftUI destroys its view hierarchy.
final class CloseObservation: @unchecked Sendable {
    private let token: any NSObjectProtocol
    init(_ token: any NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}
