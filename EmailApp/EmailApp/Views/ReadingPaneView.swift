import AppKit
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
    /// In-memory only, per message id — dismissal doesn't need to survive
    /// relaunch. ponytail: no persistence, add to AppSettings if users ask
    /// for it to stick across launches.
    @State private var dismissedSummaryCardIds: Set<UUID> = []

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
                    HStack {
                        Text(thread.latest.subject)
                            .font(.appTitle2.weight(.semibold))
                        Spacer()
                        if thread.count >= 3 && AppSettings.shared.aiFeaturesEnabled {
                            SummarizeChip(thread: thread)
                        }
                    }
                    .padding(.horizontal, 4)

                    if !dismissedSummaryCardIds.contains(thread.latest.id) {
                        let senderSignal = isOwnAccount(thread.latest.senderEmail)
                            ? SenderReputationService.Signal(isFirstContact: false, priorCount: 0, firstSeen: nil)
                            : SenderReputationService.signal(for: thread.latest.senderEmail, in: vm.messages, excluding: thread.latest.id)
                        let signals = EmailSignalScanner.scan(thread.latest, isBcc: false, senderSignal: senderSignal)
                        if !signals.isEmpty {
                            AutoSummaryCard(signals: signals) {
                                dismissedSummaryCardIds.insert(thread.latest.id)
                            }
                            .padding(.horizontal, 4)
                        }
                    }

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

    /// Never badge/flag the user's own sent mail as "first contact" — that
    /// signal is only meaningful for other people's addresses.
    private func isOwnAccount(_ email: String) -> Bool {
        vm.accounts.contains { $0.email.lowercased() == email.lowercased() }
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
    @State private var preview = AttachmentPreviewController()
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
                        if !vm.accounts.contains(where: { $0.email.lowercased() == message.senderEmail.lowercased() }),
                           SenderReputationService.signal(for: message.senderEmail, in: vm.messages, excluding: message.id).isFirstContact {
                            FirstContactBadge()
                        }
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
                    Divider().overlay(Color.appBorder)
                    attachmentsView
                }
            }
            .padding(.leading, Self.avatarColumnWidth)
            .padding(.top, 4)
        }
        .padding(16)
        .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 12))
        .quickLookPreview($preview.previewURL)
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
                        if preview.loadingAttachmentId == attachment.id {
                            ProgressView()
                                .controlSize(.small)
                                .padding(6)
                        }
                    }
                    // Click previews inline via QuickLook — matches Mail.app/
                    // Finder convention (click/space previews, an explicit
                    // action saves). Save As is still available via
                    // right-click, it's just no longer what a plain click does.
                    .onTapGesture { preview.preview(attachment, on: message, vm: vm) }
                    .contextMenu {
                        Button("Save As…") { saveAttachment(attachment) }
                    }
                    .pointerOnHover()
                    .task(id: attachment.id) { await loadThumbnailIfNeeded(attachment) }
                }
            }
            // ScrollView centers content shorter than its own width by
            // default — with only one or two attachments that put the row
            // floating in the middle of the pane instead of flush left
            // under the body text above it.
            .frame(maxWidth: .infinity, alignment: .leading)
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

}

/// Subtle icon next to a first-contact sender's name (3f) — click for a
/// popover with the signal detail. No network; purely from the local
/// message cache via SenderReputationService.
private struct FirstContactBadge: View {
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.appCaption)
                .foregroundStyle(.orange.opacity(0.85))
        }
        .buttonStyle(.pointerPlain)
        .popover(isPresented: $isPresented) {
            Text("First message you've received from this sender.")
                .font(.appCaption)
                .padding(10)
                .frame(width: 220)
        }
    }
}

/// 3c — appears in the subject header once a thread has 3+ messages; one
/// click summarizes locally via Ollama (never Claude — see plan constraint
/// 1) and shows the result in a dismissible card below.
private struct SummarizeChip: View {
    let thread: MessageThread
    @State private var isExpanded = false
    @State private var summary = ""
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Button {
                if isExpanded {
                    isExpanded = false
                } else {
                    isExpanded = true
                    if summary.isEmpty { summarize() }
                }
            } label: {
                HStack(spacing: 6) {
                    if isLoading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    }
                    Text("Summarize")
                }
                .font(.appCaption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.appHover))
            }
            .buttonStyle(.pointerPlain)
        }
        .overlay(alignment: .topTrailing) {
            if isExpanded {
                summaryCard
                    .offset(y: 34)
                    .frame(width: 320)
            }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("qwen2.5 · local")
                    .font(.appCaption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { isExpanded = false } label: {
                    Image(systemName: "xmark").iconButtonHitArea(2)
                }
                .buttonStyle(.pointerPlain)
                .foregroundStyle(.secondary)
            }
            if let errorText {
                Text(errorText).font(.appCaption).foregroundStyle(.orange)
            } else {
                Text(summary.isEmpty ? "Summarizing…" : summary)
                    .font(.appCaption)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.appBorder))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }

    private func summarize() {
        isLoading = true
        errorText = nil
        Task {
            do {
                summary = try await AIService.summarizeThread(thread.messages)
            } catch {
                errorText = "Ollama not running — couldn't summarize."
            }
            isLoading = false
        }
    }
}

/// 3h — compact, dismissible card at the top of the reading pane when
/// EmailSignalScanner finds at least one signal; absent entirely otherwise.
private struct AutoSummaryCard: View {
    let signals: [EmailSignalScanner.Signal]
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(signals) { signal in
                    Text(signal.text)
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark").iconButtonHitArea(2)
            }
            .buttonStyle(.pointerPlain)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.appBorder))
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
