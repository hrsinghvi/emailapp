import SwiftUI
import AppKit

/// A per-instance `@State` needs a real modifier type, not a plain function —
/// each icon button using `iconButtonHitArea()` gets its own hover state.
private struct IconHoverHitArea: ViewModifier {
    let padding: CGFloat
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Circle().fill(isHovering ? Color.appHover : .clear))
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pointingHand.pop() }
            }
            .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}

extension View {
    /// Icon-only buttons render a tiny glyph but should be clickable — and
    /// visibly hoverable — across a comfortable circle around it, not just
    /// the exact outline of the SF Symbol. Apply to the icon inside the
    /// button's label.
    func iconButtonHitArea(_ padding: CGFloat = 6) -> some View {
        modifier(IconHoverHitArea(padding: padding))
    }

    /// Anything clickable that isn't a `Button` (a whole row driven by
    /// `.onTapGesture`, for instance) — swaps to the pointing-hand cursor
    /// on hover, same as a real link/button, instead of the plain arrow.
    func pointerOnHover() -> some View {
        onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pointingHand.pop() }
        }
    }
}

/// Drop-in replacement for `.buttonStyle(.pointerPlain)` — identical rendering (no
/// button chrome added), plus the pointing-hand cursor on hover that macOS's
/// buttons don't show by default but this app wants everywhere clickable.
struct PointerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.pointerOnHover()
    }
}

extension ButtonStyle where Self == PointerButtonStyle {
    static var pointerPlain: PointerButtonStyle { PointerButtonStyle() }
}
