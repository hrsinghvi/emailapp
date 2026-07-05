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
        // Deliberately NOT window.isMovableByWindowBackground = true — that
        // makes EVERY empty pixel in the whole window draggable (way more
        // than just the top strip), and it actively conflicts with the
        // double-click-to-zoom gesture on the same region: AppKit's own
        // drag-recognition on the first mouseDown can preempt SwiftUI's
        // gesture recognizer before it ever sees a second click, which is
        // exactly why double-click-to-zoom kept breaking. Drag + zoom are
        // both handled by TitleBarDragZoneView instead, scoped to only the
        // 34pt strip above TopBar — see ContentView.
    }
}

/// Real titlebar behavior (click-drag to move, double-click to zoom) for
/// exactly the empty 34pt strip above TopBar — nowhere else. Handling both
/// from one NSView's mouseDown (the same approach a real titlebar uses) is
/// what keeps drag and double-click-zoom from fighting each other; using
/// NSWindow's isMovableByWindowBackground flag for drag while relying on a
/// separate SwiftUI gesture for zoom made the two interfere (see above).
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
