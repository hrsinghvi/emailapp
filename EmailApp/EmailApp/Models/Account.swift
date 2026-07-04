import SwiftUI
import CryptoKit

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

    /// `id` is derived from provider+email (not random) so it stays stable
    /// across relaunches — cached messages persist their `accountId` to
    /// disk, and a random id would orphan them (breaking reply/reply-all)
    /// the moment the account is restored in a new session.
    init(provider: Provider, email: String, displayName: String) {
        self.id = UUID(stableFrom: "\(provider.rawValue):\(email)")
        self.provider = provider
        self.email = email
        self.displayName = displayName
    }

    /// Neither OAuth provider hands back a display name from just the
    /// refresh flow here — humanize the address's local part ("hritvik.singhvi"
    /// -> "Hritvik Singhvi") for the sidebar header rather than showing the
    /// raw email twice.
    var prettyLocalName: String {
        let localPart = email.split(separator: "@").first.map(String.init) ?? email
        return localPart
            .split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

private nonisolated extension UUID {
    init(stableFrom string: String) {
        let bytes = Array(SHA256.hash(data: Data(string.utf8)).prefix(16))
        let raw = bytes.withUnsafeBytes { $0.load(as: uuid_t.self) }
        self = UUID(uuid: raw)
    }
}
