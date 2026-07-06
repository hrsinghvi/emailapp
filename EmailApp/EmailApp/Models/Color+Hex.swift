import SwiftUI
import AppKit

extension Color {
    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value & 0xFF0000) >> 16) / 255.0
        let g = Double((value & 0x00FF00) >> 8) / 255.0
        let b = Double(value & 0x0000FF) / 255.0
        self.init(red: r, green: g, blue: b)
    }

    /// Round-trips through NSColor's sRGB space — good enough for a settings
    /// swatch, not meant to preserve exotic color spaces.
    func toHex() -> String? {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

}

/// Flat Notion-Mail/Gmail-inspired dark palette — replaces the old
/// frosted-glass materials with opaque fills so nothing behind the window
/// shows or blurs through.
extension Color {
    static let appBackground = Color(hex: "#191919")
    static let appSurface = Color(hex: "#212121")
    static let appSurfaceRaised = Color(hex: "#252525")
    static let appBorder = Color.white.opacity(0.08)
    static let appHover = Color.white.opacity(0.06)
    /// Fixed — no accent-color picker anymore, just plain white.
    static let appAccent = Color.white

    /// Subtle multi-stop gradient identifying an AI-powered surface (Ask AI,
    /// Summarize, Draft with AI) — kept low-opacity so it reads as a quiet
    /// signal, not a bright decoration, against the flat dark theme.
    static let aiGradientStops: [Color] = [
        Color(hex: "#8AB4FF"), Color(hex: "#C79CFF"), Color(hex: "#FF9CC7"),
    ]
}

extension View {
    /// A faint gradient outline marking a view as an AI feature. `lineWidth`
    /// stays hairline and opacity low by design — noticeable on close look,
    /// invisible from a glance across the UI.
    func aiGradientBorder(cornerRadius: CGFloat = 12, lineWidth: CGFloat = 1.2, opacity: Double = 0.55) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: Color.aiGradientStops, startPoint: .leading, endPoint: .trailing)
                        .opacity(opacity),
                    lineWidth: lineWidth
                )
        )
    }
}
