import AppKit
import SwiftUI

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
                .font(.custom("DM Sans", size: 38))
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
                .fill(message.provider.color)
                .frame(width: 3, height: 32)
            Circle()
                .fill(message.provider.color)
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
    }
}

/// A single expanded message within a thread. Its own View struct (not a
/// helper function) so `@State htmlHeight` is stable per-message rather than
/// being recreated on every parent body re-evaluation.
private struct ExpandedMessageCard: View {
    let vm: InboxViewModel
    let message: Message
    @State private var htmlHeight: CGFloat

    init(vm: InboxViewModel, message: Message) {
        self.vm = vm
        self.message = message
        // If this message was prewarmed, its height is already known —
        // start there so there's no loading-spinner flash at all.
        _htmlHeight = State(initialValue: HTMLPrewarmCache.shared.height(for: message.id) ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(message.provider.color)
                    .frame(width: 3, height: 44)
                Circle()
                    .fill(message.provider.color)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Text(message.senderInitials)
                            .font(.appHeadline)
                            .foregroundStyle(.white)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.senderName)
                        .font(.appHeadline)
                    Text(message.senderEmail)
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

            bodyContent

            if !message.attachments.isEmpty {
                attachmentsView
            }

            actionBar
        }
        .padding(16)
        .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 12))
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
                        systemIconName: AttachmentIcon.systemName(forMimeType: attachment.mimeType)
                    )
                    .onTapGesture { saveAttachment(attachment) }
                }
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

    private var actionBar: some View {
        HStack(spacing: 10) {
            ActionPill(title: "Reply", icon: "arrowshape.turn.up.left", tint: .white) {
                vm.composeContext = .reply(message)
            }
            ActionPill(title: "Reply All", icon: "arrowshape.turn.up.left.2", tint: .white) {
                vm.composeContext = .replyAll(message)
            }
            ActionPill(title: "Forward", icon: "arrowshape.turn.up.right", tint: .white) {
                vm.composeContext = .forward(message)
            }
            ActionPill(
                title: message.isRead ? "Mark Unread" : "Mark Read",
                icon: "envelope.badge",
                tint: .white
            ) {
                vm.toggleReadStatus(message)
            }
            ActionPill(title: "Archive", icon: "archivebox", tint: .white) {
                vm.archive(message)
            }
            Spacer()
            ActionPill(title: "Ask Claude", icon: "sparkles", tint: Color.appAccent, filled: true) {}
        }
    }
}

private struct ActionPill: View {
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
        .buttonStyle(.plain)
    }
}
