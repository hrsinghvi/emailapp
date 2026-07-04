import SwiftUI

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
            .onHover { isHovering = $0 }
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
}
