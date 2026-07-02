import SwiftUI

struct MailCategory: Identifiable, Hashable {
    let id: UUID
    let name: String
    let colorHex: String
    let isSystem: Bool

    var color: Color {
        Color(hex: colorHex)
    }
}

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
}
