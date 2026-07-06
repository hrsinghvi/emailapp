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

private struct DriftUpModifier: ViewModifier {
    let isActive: Bool
    func body(content: Content) -> some View {
        content
            .offset(y: isActive ? 6 : 0)
            .opacity(isActive ? 0 : 1)
    }
}

/// Builds a `Text` with every case-insensitive occurrence of any `terms`
/// highlighted — the same idea as Gmail bolding the words in a subject/
/// snippet that matched your search, but a pastel yellow background instead
/// of bold (easier to notice at a glance, per explicit request). Terms are
/// matched independently and can overlap in the source text — each match is
/// found via `range(of:options:.caseInsensitive)` scanning left to right, so
/// multiple different search words all get highlighted, not just the first.
func highlightedText(_ text: String, terms: [String]) -> Text {
    guard !terms.isEmpty else { return Text(text) }
    var attributed = AttributedString(text)
    for term in terms {
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: term, options: .caseInsensitive, range: searchRange) {
            if let attrRange = Range(found, in: attributed) {
                attributed[attrRange].backgroundColor = Color.yellow.opacity(0.45)
            }
            searchRange = found.upperBound..<text.endIndex
        }
    }
    return Text(attributed)
}

extension AnyTransition {
    /// A small fade + upward drift for rows appearing in a list (message
    /// rows, search results) — deliberately subtle (6pt, not a full
    /// off-screen slide) so it reads as a light polish rather than a
    /// distracting swoop.
    static var driftUp: AnyTransition {
        .modifier(active: DriftUpModifier(isActive: true), identity: DriftUpModifier(isActive: false))
    }
}
