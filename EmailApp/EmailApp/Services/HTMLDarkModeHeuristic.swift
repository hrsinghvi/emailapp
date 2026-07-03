import Foundation

/// Decides whether an HTML email needs the lightness-invert dark mode
/// treatment. Most real-world email templates (marketing, transactional,
/// personal) are authored on a white/light canvas with no dark-mode
/// awareness — those get inverted so they merge into the app's dark theme,
/// same as Notion Mail / Apple Mail. Templates that already declare a dark
/// background are left alone so they don't get double-inverted into light
/// mode.
enum HTMLDarkModeHeuristic {
    static func isAlreadyDark(_ html: String) -> Bool {
        let pattern = "background(?:-color)?\\s*:\\s*#?([0-9a-fA-F]{6}|[0-9a-fA-F]{3})\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        let ns = html as NSString
        let searchRange = NSRange(location: 0, length: min(ns.length, 4000))
        guard let match = regex.firstMatch(in: html, options: [], range: searchRange), match.numberOfRanges > 1 else {
            return false
        }
        let hex = ns.substring(with: match.range(at: 1))
        guard let lightness = relativeLightness(hex: hex) else { return false }
        return lightness < 0.25
    }

    private static func relativeLightness(hex: String) -> Double? {
        var expanded = hex
        if expanded.count == 3 {
            expanded = expanded.map { "\($0)\($0)" }.joined()
        }
        guard expanded.count == 6, let value = UInt32(expanded, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        return 0.299 * r + 0.587 * g + 0.114 * b
    }
}
