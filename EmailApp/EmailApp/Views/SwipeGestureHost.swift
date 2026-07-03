import AppKit
import SwiftUI

/// Catches a genuine two-finger trackpad swipe (no click needed) on its
/// content. Click-and-drag is a `DragGesture` (mouse-down + move); a bare
/// trackpad swipe is a `scrollWheel` event with a `.phase` — a different
/// AppKit event entirely, which is why `DragGesture` alone never saw it.
///
/// Hosts `content` inside itself via `NSHostingView` (rather than attaching
/// as a `.background()`, which would make it a sibling, not an ancestor) so
/// an unhandled `scrollWheel` reliably bubbles up the responder chain to
/// this view's override. Vertical two-finger scrolls are passed to `super`
/// untouched so the message list keeps scrolling normally.
struct SwipeGestureHost<Content: View>: NSViewRepresentable {
    let onHorizontalDelta: (CGFloat) -> Void
    let onGestureEnd: () -> Void
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onDelta = onHorizontalDelta
        view.onEnd = onGestureEnd
        let hosting = NSHostingView(rootView: content())
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        view.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        view.hostingView = hosting
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onDelta = onHorizontalDelta
        nsView.onEnd = onGestureEnd
        nsView.hostingView?.rootView = content()
    }

    final class CatcherView: NSView {
        var onDelta: ((CGFloat) -> Void)?
        var onEnd: (() -> Void)?
        fileprivate var hostingView: NSHostingView<Content>?

        private var isTrackingHorizontal = false
        private var accumulated: CGFloat = 0

        override func scrollWheel(with event: NSEvent) {
            // Only genuine trackpad/Force Touch input reports precise
            // deltas + gesture phases — a plain scroll wheel doesn't, so
            // this naturally excludes mice.
            guard event.hasPreciseScrollingDeltas else {
                super.scrollWheel(with: event)
                return
            }
            if event.phase == .began {
                isTrackingHorizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                accumulated = 0
            }
            guard isTrackingHorizontal else {
                super.scrollWheel(with: event)
                return
            }
            accumulated += event.scrollingDeltaX
            onDelta?(accumulated)
            if event.phase == .ended || event.phase == .cancelled {
                onEnd?()
                isTrackingHorizontal = false
                accumulated = 0
            }
        }
    }
}
