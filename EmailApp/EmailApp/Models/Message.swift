import Foundation

struct Message: Identifiable, Hashable, Codable {
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
    /// Plain-text body — used for search/snippets, and as the reading-pane
    /// fallback when no HTML part exists.
    let body: String
    /// Raw HTML part, preferred for reading-pane display whenever present.
    /// Nil for realtime-webhook-delivered rows (the cache doesn't carry it) —
    /// falls back to plain text until the next full sync backfills it.
    var htmlBody: String? = nil
    let receivedAt: Date
    var isRead: Bool
    var folder: String = "inbox"
    /// Original To/Cc recipients, needed to build a correct reply-all list.
    var toRecipients: [String] = []
    var ccRecipients: [String] = []
    var attachments: [Attachment] = []
    /// Local-only flags — not synced to Gmail/Outlook star or importance
    /// markers server-side, just persisted in this app's own message cache.
    var isStarred: Bool = false
    var isImportant: Bool = false
    /// Gmail's own inbox-tab category (from the message's CATEGORY_* label)
    /// — nil for Outlook (no equivalent) and for realtime-webhook-delivered
    /// rows (minimal payload, backfilled on the next full sync). `category`
    /// below falls back to the sender/subject heuristic only when this is
    /// nil, so Gmail mail lands in the same tab it does in actual Gmail.
    var providerCategory: MessageCategory? = nil
    /// True only for a message inserted straight from a realtime webhook row
    /// (see `InboxViewModel.handleRealtimeInsert`) — that payload is
    /// deliberately minimal (no htmlBody, attachments, providerCategory,
    /// To/Cc), so the regular sync's `merge` needs an explicit signal to
    /// replace this entry with the full version instead of treating the id
    /// as already-known-so-skip. Absent (false) for anything ever fetched
    /// from Gmail/Graph directly, including old cached JSON with no such key.
    var needsFullSync: Bool = false

    /// Grouping key for thread view: falls back to the message's own id so
    /// a message with no thread/conversation id still renders as a
    /// single-message "thread".
    var threadKey: String { threadId ?? id.uuidString }

    /// Prefers Gmail's real category label; only guesses via heuristic when
    /// the provider doesn't supply one (Outlook, or a not-yet-backfilled
    /// realtime row).
    var category: MessageCategory {
        providerCategory ?? MessageCategory.classify(senderEmail: senderEmail, subject: subject)
    }

    var senderInitials: String {
        senderName
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
            .map { String($0).uppercased() }
            .joined()
    }
}
