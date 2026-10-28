import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class PrivacyOverlayPresentation {
    var status = "屏幕内容已被视觉遮挡。"
    var foregroundVisible = false
}

@MainActor
struct PrivacyOverlayView: View {
    let presentation: PrivacyOverlayPresentation
    let onDismiss: @MainActor () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            // The controller supplies the actual behind-window blur. Do not
            // paint an opaque SwiftUI background over that native material.
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            }

            foreground
            .opacity(presentation.foregroundVisible ? 1 : 0)
            .offset(y: presentation.foregroundVisible || reduceMotion ? 0 : 4)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: presentation.foregroundVisible)
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Match the native backdrop's light appearance while preserving its
        // actual desktop colours instead of replacing them with a flat fill.
        .preferredColorScheme(.light)
        .onExitCommand(perform: onDismiss)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var foreground: some View {
        VStack(spacing: 20) {
            if #available(macOS 26.0, *), !reduceTransparency {
                liquidGlassContent
            } else {
                classicContent
            }
            keyboardHint
            Text("视觉遮挡，不是系统锁屏")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 5)
        }
    }

    @available(macOS 26.0, *)
    private var liquidGlassContent: some View {
        // Nearby floating controls share the system glass renderer above the
        // full-window AppKit backdrop blur.
        GlassEffectContainer(spacing: 20) {
            VStack(spacing: 24) {
                statusContent
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32))

                dismissButton
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
            }
        }
    }

    private var classicContent: some View {
        VStack(spacing: 24) {
            statusContent
                .background {
                    if reduceTransparency {
                        RoundedRectangle(cornerRadius: 32).fill(Color.white)
                    } else {
                        ShieldMaterialView()
                            .clipShape(RoundedRectangle(cornerRadius: 32))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 32)
                        .strokeBorder(.white.opacity(0.75), lineWidth: 1)
                }
                .shadow(color: Color(red: 0.28, green: 0.36, blue: 0.45).opacity(0.09), radius: 22, y: 12)

            dismissButton
                .buttonStyle(.bordered)
                .controlSize(.large)
                .buttonBorderShape(.capsule)
        }
    }

    private var statusContent: some View {
        VStack(spacing: 22) {
            Image(systemName: "eye.slash")
                .font(.system(size: 31, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary)
                .frame(height: 46)
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text("Privacy Mode")
                    .font(.system(size: 31, weight: .medium, design: .rounded))
                    .tracking(0.2)
                    .foregroundStyle(.primary)
                Text(presentation.status)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 330)
            }
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 38)
        .frame(maxWidth: 440)
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Label("解除遮挡", systemImage: "arrow.uturn.backward")
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 18)
                .padding(.vertical, 5)
        }
        .help("解除所有显示器的遮挡。也可按 Escape 或 ⇧⌘P。")
        .accessibilityIdentifier("privacy-overlay-dismiss")
    }

    private var keyboardHint: some View {
        HStack(spacing: 8) {
            Text("esc").font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
            Text("或  ⇧⌘P  解除").font(.system(size: 12))
        }
        .foregroundStyle(.secondary)
    }
}

/// Fallback frosting for the floating status card on older macOS versions.
private struct ShieldMaterialView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .withinWindow
        view.state = .active
        view.appearance = NSAppearance(named: .aqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
