import SwiftUI
import AppKit

/// Forces the window to a solid opaque fill (no vibrancy/blur behind it) and
/// disables macOS's automatic window-tabbing strip.
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
        window.isOpaque = true
        window.backgroundColor = NSColor(Color.appBackground)
        // Single-window app — the native tab bar ("+ / EmailApp" strip)
        // only appears because macOS's automatic window tabbing defaults
        // it in; this app has no use for it.
        window.tabbingMode = .disallowed
        NSWindow.allowsAutomaticWindowTabbing = false
    }
}
