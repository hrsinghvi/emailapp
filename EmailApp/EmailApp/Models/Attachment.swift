import Foundation

/// An attachment on a *received* message. `id` is the provider's attachment
/// id (Gmail attachmentId / Graph attachment id) — bytes are fetched lazily
/// on click, not eagerly with the message list.
struct Attachment: Identifiable, Hashable {
    let id: String
    let filename: String
    let mimeType: String
    let sizeBytes: Int

    var sizeMB: Double { Double(sizeBytes) / 1_048_576 }
}

/// An attachment being composed — read into memory immediately when picked
/// so there's no need to hold a security-scoped bookmark past the
/// NSOpenPanel call.
struct OutgoingAttachment: Identifiable, Hashable {
    let id = UUID()
    let filename: String
    let mimeType: String
    let data: Data

    var sizeMB: Double { Double(data.count) / 1_048_576 }
}
