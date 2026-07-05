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
        // Click-drag-to-move on any empty background, same as a real
        // titlebar — a plain NSWindow flag, no custom hit-testing to get
        // wrong. Previously this app used a full-width invisible NSView
        // overlay for both drag and double-click-zoom, but that view's
        // AppKit-level hit-testing didn't reliably respect SwiftUI's frame
        // constraints, and ended up silently swallowing clicks meant for
        // real SwiftUI controls sitting at the same height elsewhere in
        // the window (most recently the Mail/Calendar switch). Window-
        // background dragging doesn't need any of that — it's automatic
        // for any point with no view underneath.
        window.isMovableByWindowBackground = true
    }
}
