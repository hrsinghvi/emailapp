import AppKit
import CryptoKit
import PDFKit
import QuickLook
import SwiftUI

/// In-memory only — thumbnails regenerate from the (also-cached-on-disk)
/// attachment temp file cheaply enough that persisting this across launches
/// isn't worth the complexity. Keyed by the provider attachment id, same as
/// the on-disk temp file cache in ExpandedMessageCard.
final class AttachmentThumbnailCache {
    static let shared = AttachmentThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(for attachmentId: String) -> NSImage? {
        cache.object(forKey: attachmentId as NSString)
    }

    func store(_ image: NSImage, for attachmentId: String) {
        cache.setObject(image, forKey: attachmentId as NSString)
    }
}

struct ReadingPaneView: View {
    @Bindable var vm: InboxViewModel

    var body: some View {
        Group {
            if let thread = vm.selectedThread {
                threadView(thread)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "envelope.open")
                .font(.custom("Inter", size: 38))
                .foregroundStyle(.tertiary)
            Text("Select a message")
                .font(.appHeadline)
                .foregroundStyle(.secondary)
        }
    }

    private func threadView(_ thread: MessageThread) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(thread.latest.subject)
                        .font(.appTitle2.weight(.semibold))
                        .padding(.horizontal, 4)

                    ForEach(thread.messages) { message in
                        if vm.expandedMessageIds.contains(message.id) {
                            ExpandedMessageCard(vm: vm, message: message)
                                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                        } else {
                            collapsedRow(message)
                                .transition(.opacity)
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    private func collapsedRow(_ message: Message) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(vm.color(for: message))
                .frame(width: 3, height: 32)
            Circle()
                .fill(vm.color(for: message))
                .frame(width: 28, height: 28)
                .overlay(
                    Text(message.senderInitials)
                        .font(.appCaption2.weight(.semibold))
                        .foregroundStyle(.white)
                )
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(message.senderName)
                        .font(.appSubheadline.weight(message.isRead ? .regular : .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(message.receivedAt, format: .dateTime.month().day().hour().minute())
                        .font(.appCaption2)
                        .foregroundStyle(.secondary)
                }
                Text(message.snippet)
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { vm.toggleExpand(message) }
        .pointerOnHover()
    }
}

/// A single expanded message within a thread. Its own View struct (not a
/// helper function) so `@State htmlHeight` is stable per-message rather than
/// being recreated on every parent body re-evaluation.
private struct ExpandedMessageCard: View {
    let vm: InboxViewModel
    let message: Message
    @State private var htmlHeight: CGFloat
    @State private var previewURL: URL?
    @State private var isLoadingPreview: Attachment.ID?
    @State private var thumbnails: [String: NSImage] = [:]

    init(vm: InboxViewModel, message: Message) {
        self.vm = vm
        self.message = message
        // If this message was prewarmed, its height is already known —
        // start there so there's no loading-spinner flash at all.
        _htmlHeight = State(initialValue: HTMLPrewarmCache.shared.height(for: message.id) ?? 0)
    }

    /// Avatar circle (44) + its spacing (12) — bodyContent/attachments below
    /// indent by exactly this so they line up under the name/email text
    /// instead of starting flush under the avatar itself.
    private static let avatarColumnWidth: CGFloat = 44 + 12

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(vm.color(for: message))
                    .frame(width: 3, height: 44)
                Circle()
                    .fill(vm.color(for: message))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Text(message.senderInitials)
                            .font(.appHeadline)
                            .foregroundStyle(.white)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(message.senderName)
                            .font(.appHeadline)
                        Text("<\(message.senderEmail)>")
                            .font(.appCaption)
                            .foregroundStyle(.secondary)
                    }
                    Text("to \(recipientSummary)")
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(message.receivedAt, format: .dateTime.month().day().hour().minute())
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { vm.toggleExpand(message) }
            .pointerOnHover()

            VStack(alignment: .leading, spacing: 16) {
                bodyContent

                if !message.attachments.isEmpty {
                    attachmentsView
                }
            }
            .padding(.leading, Self.avatarColumnWidth)
            .padding(.top, 4)
        }
        .padding(16)
        .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 12))
        .quickLookPreview($previewURL)
    }

    /// "me" for any recipient that matches one of the connected accounts,
    /// otherwise the actual address — same convention Gmail's own "to"
    /// line uses. Falls back to the sender's own address for the rare
    /// message with no recorded recipients (a self-send, or an older
    /// realtime-webhook row synced before To/Cc were carried).
    private var recipientSummary: String {
        guard !message.toRecipients.isEmpty else { return message.senderEmail }
        let connectedEmails = Set(vm.accounts.map { $0.email.lowercased() })
        return message.toRecipients
            .map { connectedEmails.contains($0.lowercased()) ? "me" : $0 }
            .joined(separator: ", ")
    }

    @ViewBuilder
    private var bodyContent: some View {
        if let html = message.htmlBody {
            ZStack {
                if htmlHeight == 0 {
                    ProgressView()
                        .controlSize(.small)
                        .frame(height: 120)
                }
                HTMLBodyView(messageId: message.id, html: html, height: $htmlHeight)
                    .frame(height: max(htmlHeight, 1))
                    .opacity(htmlHeight == 0 ? 0 : 1)
            }
            .animation(.easeOut(duration: 0.25), value: htmlHeight)
            // A visible light "sheet" behind the email, same as Gmail's own
            // dark-mode reading pane — the HTML itself renders unmodified
            // (see HTMLBodyView.wrap), so it needs an actual light surface
            // under it rather than blending into this card's dark
            // background.
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Text(message.body)
                .font(.appBody)
                .foregroundStyle(.primary.opacity(0.85))
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var attachmentsView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(message.attachments) { attachment in
                    AttachmentCardView(
                        filename: attachment.filename,
                        sizeMB: attachment.sizeMB,
                        thumbnail: thumbnails[attachment.id],
                        systemIconName: AttachmentIcon.systemName(forMimeType: attachment.mimeType)
                    )
                    .overlay(alignment: .topTrailing) {
                        if isLoadingPreview == attachment.id {
                            ProgressView()
                                .controlSize(.small)
                                .padding(6)
                        }
                    }
                    // Click previews inline via QuickLook — matches Mail.app/
                    // Finder convention (click/space previews, an explicit
                    // action saves). Save As is still available via
                    // right-click, it's just no longer what a plain click does.
                    .onTapGesture { previewAttachment(attachment) }
                    .contextMenu {
                        Button("Save As…") { saveAttachment(attachment) }
                    }
                    .pointerOnHover()
                    .task(id: attachment.id) { await loadThumbnailIfNeeded(attachment) }
                }
            }
        }
    }

    /// Real thumbnails for images/PDFs, Gmail-style, instead of a generic
    /// file-type icon — only for these two types since they're cheap to
    /// turn into a small preview (a resizable image already, or PDFKit's
    /// built-in page thumbnail renderer); other types keep the icon.
    /// AttachmentThumbnailCache dedupes across re-renders of the same
    /// message so switching threads and back doesn't re-fetch.
    private func loadThumbnailIfNeeded(_ attachment: Attachment) async {
        guard thumbnails[attachment.id] == nil else { return }
        guard attachment.mimeType.hasPrefix("image/") || attachment.mimeType == "application/pdf" else { return }
        if let cached = AttachmentThumbnailCache.shared.image(for: attachment.id) {
            thumbnails[attachment.id] = cached
            return
        }
        guard let data = try? await vm.attachmentData(attachment, on: message) else { return }
        let image: NSImage?
        if attachment.mimeType == "application/pdf" {
            image = PDFDocument(data: data)?.page(at: 0)?.thumbnail(of: CGSize(width: 168, height: 120), for: .cropBox)
        } else {
            image = NSImage(data: data)
        }
        guard let image else { return }
        AttachmentThumbnailCache.shared.store(image, for: attachment.id)
        thumbnails[attachment.id] = image
    }

    /// Fetches the attachment's real bytes directly from Gmail/Graph on
    /// first click (never pre-downloaded, never routed through Supabase or
    /// any other storage), writes them to a temp file, and hands that URL
    /// straight to QuickLook — no save dialog anywhere in this path.
    /// Subsequent clicks on the same attachment reuse the temp file instead
    /// of re-fetching.
    private func previewAttachment(_ attachment: Attachment) {
        if let cached = cachedTempFileURL(for: attachment), FileManager.default.fileExists(atPath: cached.path) {
            previewURL = cached
            return
        }
        isLoadingPreview = attachment.id
        Task {
            defer { isLoadingPreview = nil }
            do {
                let data = try await vm.attachmentData(attachment, on: message)
                let url = try writeTempFile(data, for: attachment)
                previewURL = url
            } catch {
                vm.errorMessage = "Couldn't load attachment: \(error.localizedDescription)"
            }
        }
    }

    private func saveAttachment(_ attachment: Attachment) {
        Task {
            do {
                let data = try await vm.attachmentData(attachment, on: message)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = attachment.filename
                if panel.runModal() == .OK, let url = panel.url {
                    try data.write(to: url)
                }
            } catch {
                vm.errorMessage = "Couldn't download attachment: \(error.localizedDescription)"
            }
        }
    }

    private func cachedTempFileURL(for attachment: Attachment) -> URL? {
        try? tempFileURL(for: attachment)
    }

    private func writeTempFile(_ data: Data, for attachment: Attachment) throws -> URL {
        let url = try tempFileURL(for: attachment)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Namespaced by message + attachment id so two different attachments
    /// that happen to share a filename (or the same attachment opened from
    /// two different messages) never collide on disk. The raw provider
    /// attachment id (Gmail's can run 100+ characters) used to be
    /// concatenated straight into the filename, which could push the whole
    /// path component past macOS's 255-byte filename limit and make the
    /// write fail with "the file name ... is invalid" — hashing it to a
    /// fixed-length directory component instead means the on-disk filename
    /// is always just the real, human filename.
    private func tempFileURL(for attachment: Attachment) throws -> URL {
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

/// Shared with DetailToolbar's Reply/Reply All/Forward row — that row used
/// to be duplicated per expanded message in a thread; it's one row per
/// thread now, at the top, next to back/archive/trash.
struct ActionPill: View {
    let title: String
    let icon: String
    let tint: Color
    var filled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.appSubheadline.weight(.medium))
            .foregroundStyle(filled ? tint : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(filled ? tint.opacity(0.18) : Color.appHover)
            )
        }
        .buttonStyle(.pointerPlain)
    }
}
