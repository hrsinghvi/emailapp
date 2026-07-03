import Foundation

/// A send/reply queued offline — mirrors `InboxViewModel.PendingSend` but
/// Codable, since it has to survive a relaunch while offline.
struct QueuedSend: Codable {
    let origin: DraftOrigin
    let to: String
    let cc: String
    let bcc: String
    let subject: String
    let bodyHTML: String
    let attachments: [DraftAttachment]
}

enum OfflineAction: Codable {
    case archive(messageId: UUID)
    case delete(messageId: UUID)
    case markRead(messageId: UUID, read: Bool)
    case send(QueuedSend)
}

/// One entry in the offline queue — a transaction log entry, replayed in
/// the exact order actions originally occurred.
struct QueuedActionEnvelope: Codable, Identifiable {
    let id: UUID
    let action: OfflineAction
    let queuedAt: Date
}
