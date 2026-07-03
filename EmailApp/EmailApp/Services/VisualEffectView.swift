import SwiftUI
import AppKit

/// Real macOS vibrancy: blurs whatever's behind the window (desktop, other
/// windows), not just sibling SwiftUI content. `.ultraThinMaterial` alone
/// only blurs what's drawn behind it in the same window — over a flat opaque
/// fill that's indistinguishable from no material at all.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// `.behindWindow` blending only shows through if the window itself isn't
/// opaque. Grabs the hosting NSWindow once and flips the flags that block it.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView) }
    }

    private func configure(_ view: NSView) {
        guard let window = view.window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
    }
}
