import SwiftUI

extension View {
    /// Icon-only buttons render a tiny glyph but should be clickable across
    /// a comfortable square around it, not just the exact outline of the
    /// SF Symbol — apply to the icon inside the button's label.
    func iconButtonHitArea(_ padding: CGFloat = 6) -> some View {
        self
            .padding(padding)
            .contentShape(Rectangle())
    }
}
