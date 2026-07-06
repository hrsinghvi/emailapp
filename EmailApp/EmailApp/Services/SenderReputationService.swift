import Foundation

/// Local-only, no network — first-contact detection from the already-synced
/// message cache. Backs the small badge next to a sender's name (3f) and
/// feeds 3h's auto summary card.
enum SenderReputationService {
    struct Signal {
        let isFirstContact: Bool
        let priorCount: Int
        let firstSeen: Date?
    }

    /// `messages` is the full local cache; `excluding` is the message being
    /// displayed (never counted against itself).
    static func signal(for senderEmail: String, in messages: [Message], excluding: UUID) -> Signal {
        let email = senderEmail.lowercased()
        let prior = messages.filter { $0.id != excluding && $0.senderEmail.lowercased() == email }
        return Signal(
            isFirstContact: prior.isEmpty,
            priorCount: prior.count,
            firstSeen: prior.map(\.receivedAt).min()
        )
    }
}
