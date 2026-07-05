import CryptoKit
import Foundation

/// Shared QuickLook-preview plumbing for any view that shows an
/// `Attachment` — the reading pane's expanded message card and the message
/// list row's inline attachment pill both need the identical fetch-to-temp-
/// file-then-preview flow. One controller per view that embeds it (each
/// gets its own `@State`), not a singleton — nothing here needs to be
/// shared across views, just the logic.
@Observable
final class AttachmentPreviewController {
    var previewURL: URL?
    var loadingAttachmentId: Attachment.ID?

    /// Fetches the attachment's real bytes directly from Gmail/Graph on
    /// first preview (never pre-downloaded, never routed through Supabase
    /// or any other storage), writes them to a temp file, and hands that
    /// URL to QuickLook — no save dialog anywhere in this path. Repeat
    /// previews of the same attachment reuse the temp file instead of
    /// re-fetching.
    func preview(_ attachment: Attachment, on message: Message, vm: InboxViewModel) {
        if let cached = try? Self.tempFileURL(for: attachment, on: message),
           FileManager.default.fileExists(atPath: cached.path) {
            previewURL = cached
            return
        }
        loadingAttachmentId = attachment.id
        Task {
            defer { loadingAttachmentId = nil }
            do {
                let data = try await vm.attachmentData(attachment, on: message)
                let url = try Self.tempFileURL(for: attachment, on: message)
                try data.write(to: url, options: .atomic)
                previewURL = url
            } catch {
                vm.errorMessage = "Couldn't load attachment: \(error.localizedDescription)"
            }
        }
    }

    /// Namespaced by message + attachment id so two different attachments
    /// that happen to share a filename (or the same attachment opened from
    /// two different messages) never collide on disk. The raw provider
    /// attachment id (Gmail's can run 100+ characters) is hashed rather
    /// than used directly — concatenated straight into a filename it could
    /// push the whole path component past macOS's 255-byte filename limit.
    static func tempFileURL(for attachment: Attachment, on message: Message) throws -> URL {
        let idHash = SHA256.hash(data: Data(attachment.id.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ThreadwellAttachmentPreviews", isDirectory: true)
            .appendingPathComponent(message.id.uuidString, isDirectory: true)
            .appendingPathComponent(idHash, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(attachment.filename)
    }
}
