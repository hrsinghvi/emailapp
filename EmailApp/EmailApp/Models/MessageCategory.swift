import Foundation

/// Gmail-style inbox categories. There's no ML classifier backing this (Gmail's
/// is server-side and proprietary) — this is a sender/subject heuristic, same
/// spirit as a mail client's rule-based "smart folder", not a stub.
enum MessageCategory: String, CaseIterable, Codable {
    case primary, social, promotions, updates, forums

    var label: String {
        switch self {
        case .primary: return "Primary"
        case .social: return "Social"
        case .promotions: return "Promotions"
        case .updates: return "Updates"
        case .forums: return "Forums"
        }
    }

    var icon: String {
        switch self {
        case .primary: return "tray"
        case .social: return "person.2"
        case .promotions: return "tag"
        case .updates: return "bell"
        case .forums: return "bubble.left.and.bubble.right"
        }
    }

    private static let socialDomains: Set<String> = [
        "facebookmail.com", "linkedin.com", "twitter.com", "x.com", "instagram.com",
        "pinterest.com", "tiktok.com", "reddit.com", "discord.com", "snapchat.com"
    ]

    private static let promoLocalParts: Set<String> = [
        "marketing", "promo", "promotions", "newsletter", "deals", "offers", "sales"
    ]
    private static let promoDomains: Set<String> = [
        "mailchimp.com", "sendgrid.net", "klaviyo.com", "hubspot.com", "constantcontact.com"
    ]
    private static let promoKeywords = ["% off", "sale", "discount", "coupon", "deal", "limited time", "clearance"]

    private static let updateLocalParts: Set<String> = [
        "no-reply", "noreply", "notifications", "notification", "alerts", "alert",
        "receipts", "receipt", "billing", "support", "team", "info", "security", "account"
    ]
    private static let updateKeywords = [
        "receipt", "invoice", "confirmation", "order", "shipped", "delivered", "statement",
        "verify your", "reset your password", "your account", "payment"
    ]

    private static let forumDomains: Set<String> = ["groups.google.com", "googlegroups.com"]
    private static let forumKeywords = ["digest", "mailing list"]

    /// Classifies a message from its sender/subject alone — cheap enough to
    /// compute on every access rather than caching.
    static func classify(senderEmail: String, subject: String) -> MessageCategory {
        let email = senderEmail.lowercased()
        let domain = email.split(separator: "@").last.map(String.init) ?? ""
        let localPart = email.split(separator: "@").first.map(String.init) ?? ""
        let subjectLower = subject.lowercased()

        if socialDomains.contains(where: { domain.hasSuffix($0) }) { return .social }
        if forumDomains.contains(where: { domain.hasSuffix($0) }) { return .forums }
        if forumKeywords.contains(where: subjectLower.contains) || subjectLower.hasPrefix("[") { return .forums }
        if promoDomains.contains(where: { domain.hasSuffix($0) }) { return .promotions }
        if promoLocalParts.contains(where: { localPart.contains($0) }) { return .promotions }
        if promoKeywords.contains(where: subjectLower.contains) { return .promotions }
        if updateLocalParts.contains(where: { localPart.contains($0) }) { return .updates }
        if updateKeywords.contains(where: subjectLower.contains) { return .updates }
        return .primary
    }
}
