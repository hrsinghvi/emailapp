import Foundation
import Supabase

/// Subscribes to new rows on the backend's `messages` table so mail
/// delivered via the Phase 5 webhook shows up in the app within seconds —
/// no polling, no relaunch needed.
enum RealtimeService {
    struct MessageRow: Decodable {
        let id: UUID
        let accountEmail: String
        let provider: String
        let providerMessageId: String
        let threadId: String?
        let messageIdHeader: String?
        let referencesHeader: String?
        let senderName: String
        let senderEmail: String
        let subject: String
        let snippet: String
        let body: String
        let receivedAt: Date
        let isRead: Bool
        let folder: String

        enum CodingKeys: String, CodingKey {
            case id
            case accountEmail = "account_email"
            case provider
            case providerMessageId = "provider_message_id"
            case threadId = "thread_id"
            case messageIdHeader = "message_id_header"
            case referencesHeader = "references_header"
            case senderName = "sender_name"
            case senderEmail = "sender_email"
            case subject, snippet, body
            case receivedAt = "received_at"
            case isRead = "is_read"
            case folder
        }
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Streams every new `messages` row as it's inserted. Runs until its
    /// enclosing Task is cancelled — call from a long-lived `.task {}`.
    static func subscribeToMessages(onInsert: @escaping (MessageRow) -> Void) async {
        let channel = SupabaseService.client.channel("messages-inserts")
        let insertions = channel.postgresChange(InsertAction.self, schema: "public", table: "messages")
        try? await channel.subscribeWithError()
        for await insertion in insertions {
            guard let row = try? insertion.decodeRecord(as: MessageRow.self, decoder: decoder) else { continue }
            onInsert(row)
        }
    }
}
