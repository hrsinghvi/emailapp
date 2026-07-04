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

/// `.windowStyle(.hiddenTitleBar)` draws our own SwiftUI content over the
/// real titlebar strip, which normally means double-click-to-zoom and
/// click-drag-to-move (standard for the empty part of any Mac app's title
/// bar) stop working — SwiftUI's content swallows the click before AppKit's
/// titlebar ever sees it. This re-adds both to whatever region it's placed
/// behind (the empty top strip above TopBar, not any actual button/field),
/// calling the exact same NSWindow APIs a real titlebar would.
struct TitleBarDragZoneView: NSViewRepresentable {
    func makeNSView(context: Context) -> DragZoneNSView { DragZoneNSView() }
    func updateNSView(_ nsView: DragZoneNSView, context: Context) {}
}

final class DragZoneNSView: NSView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performZoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }
}
