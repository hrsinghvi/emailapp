import Foundation

struct Message: Identifiable, Hashable {
    let id: UUID
    let accountId: UUID
    let provider: Provider
    /// Raw provider-side id (Gmail message id / Graph message id) — needed for
    /// API calls, since `id` above is a derived stable UUID for SwiftUI identity.
    let providerId: String
    /// Gmail thread id, used to keep replies in the same thread. Nil for Outlook
    /// (Graph's /reply endpoint threads automatically off providerId).
    let threadId: String?
    /// Gmail RFC822 "Message-ID" header, needed to build In-Reply-To/References.
    let messageIdHeader: String?
    /// Gmail "References" header from the original message, chained on reply.
    let references: String?
    let senderName: String
    let senderEmail: String
    let subject: String
    let snippet: String
    let body: String
    let receivedAt: Date
    var isRead: Bool
    var categoryId: UUID?
    var folder: String = "inbox"

    var senderInitials: String {
        senderName
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
            .map { String($0).uppercased() }
            .joined()
    }
}
