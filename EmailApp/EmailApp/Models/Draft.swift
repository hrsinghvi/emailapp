import Foundation

/// What a draft was originally composing — mirrors `InboxViewModel.ComposeContext`
/// but Codable, since the original `Message` isn't (and doesn't need to be;
/// only the handful of fields needed to resume a threaded reply do).
enum DraftOrigin: Codable, Hashable {
    case new
    case reply(messageId: UUID)
    case replyAll(messageId: UUID)
    case forward(messageId: UUID)
}

struct DraftAttachment: Identifiable, Codable, Hashable {
    let id: UUID
    let filename: String
    let mimeType: String
    let dataBase64: String

    var sizeMB: Double { Double(dataBase64.count) * 0.75 / 1_048_576 }

    init(id: UUID = UUID(), filename: String, mimeType: String, data: Data) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.dataBase64 = data.base64EncodedString()
    }

    var outgoing: OutgoingAttachment? {
        guard let data = Data(base64Encoded: dataBase64) else { return nil }
        return OutgoingAttachment(filename: filename, mimeType: mimeType, data: data)
    }
}

/// An unsent compose session, autosaved to disk so it survives app relaunch
/// and can be listed in the sidebar's Drafts section.
struct Draft: Identifiable, Codable, Hashable {
    let id: UUID
    var accountEmail: String?
    var to: String
    var cc: String
    var bcc: String
    var subject: String
    /// Formatted body, stored as HTML so rich formatting survives the
    /// save/reopen round-trip exactly.
    var bodyHTML: String
    var attachments: [DraftAttachment]
    var origin: DraftOrigin
    var lastModified: Date

    var snippet: String {
        bodyHTML
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
