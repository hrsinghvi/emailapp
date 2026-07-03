import Foundation

struct Message: Identifiable, Hashable {
    let id: UUID
    let accountId: UUID
    let provider: Provider
    /// Raw provider-side id (Gmail message id / Graph message id) — needed for
    /// API calls, since `id` above is a derived stable UUID for SwiftUI identity.
    let providerId: String
    /// Thread grouping key: Gmail's threadId, or Outlook's conversationId.
    /// Both are stable per-provider ids that group a reply chain together.
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
    var folder: String = "inbox"
    /// Original To/Cc recipients, needed to build a correct reply-all list.
    var toRecipients: [String] = []
    var ccRecipients: [String] = []
    var attachments: [Attachment] = []

    /// Grouping key for thread view: falls back to the message's own id so
    /// a message with no thread/conversation id still renders as a
    /// single-message "thread".
    var threadKey: String { threadId ?? id.uuidString }

    var senderInitials: String {
        senderName
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
            .map { String($0).uppercased() }
            .joined()
    }
}
