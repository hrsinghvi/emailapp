import SwiftUI

enum Provider: String, Codable, Hashable {
    case gmail
    case outlook

    var color: Color {
        switch self {
        case .gmail: return Color(hex: "#e0796b")
        case .outlook: return Color(hex: "#5b9bd5")
        }
    }
}

struct Account: Identifiable, Hashable {
    let id: UUID
    let provider: Provider
    let email: String
    let displayName: String
}
