import AppKit
import QuickLook
import SwiftUI

struct MessageListView: View {
    @Bindable var vm: InboxViewModel

    var body: some View {
        VStack(spacing: 8) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(vm.pagedThreads) { thread in
                        let message = thread.latest
                        // Right-click (and drag) act on the whole current
                        // multi-selection when this row is part of it,
                        // otherwise just this one thread.
                        let targetKeys: Set<String> = vm.selectedThreadKeys.contains(thread.id) ? vm.selectedThreadKeys : [thread.id]
                        let targetThreads: [MessageThread] = vm.pagedThreads.filter { targetKeys.contains($0.id) }

                        ThreadRow(
                            vm: vm,
                            thread: thread,
                            isOpen: vm.selectedThreadKey == thread.id,
                            isChecked: vm.selectedThreadKeys.contains(thread.id),
                            onToggleCheck: { vm.toggleSelection(thread) }
                        )
                        .onTapGesture {
                            let flags = NSEvent.modifierFlags
                            vm.handleRowClick(thread, shift: flags.contains(.shift), command: flags.contains(.command))
                        }
                        .contextMenu {
                            if targetKeys.count == 1 {
                                Button("Reply") { vm.composeContext = .reply(message) }
                                Button("Reply All") { vm.composeContext = .replyAll(message) }
                                Button("Forward") { vm.composeContext = .forward(message) }
                                Divider()
                            }
                            Button("Archive") { for t in targetThreads { vm.archiveThread(t) } }
                            Button("Delete") { for t in targetThreads { vm.deleteThread(t) } }
                            Button("Mark as unread") { for t in targetThreads { vm.markThreadUnread(t) } }
                            Divider()
                            Button(message.isStarred ? "Remove from Starred" : "Star") {
                                for t in targetThreads { for m in t.messages { vm.toggleStarred(m) } }
                            }
                            Button(message.isImportant ? "Remove from Important" : "Mark as Important") {
                                for t in targetThreads { for m in t.messages { vm.toggleImportant(m) } }
                            }
                            Divider()
                            Menu("Move to") {
                                Button("Inbox") { vm.handleDrop(threadKeys: targetKeys, onto: "inbox") }
                                Button("Promotions") { vm.handleDrop(threadKeys: targetKeys, onto: "promotions") }
                                Button("Social") { vm.handleDrop(threadKeys: targetKeys, onto: "social") }
                                Button("Updates") { vm.handleDrop(threadKeys: targetKeys, onto: "updates") }
                                Button("Forums") { vm.handleDrop(threadKeys: targetKeys, onto: "forums") }
                                Button("Archive") { vm.handleDrop(threadKeys: targetKeys, onto: "archive") }
                                Button("Trash") { vm.handleDrop(threadKeys: targetKeys, onto: "trash") }
                            }
                            Divider()
                            Button("Ask about this email") {
                                vm.selectedThreadKey = thread.id
                                vm.isAskAIPanelPresented = true
                            }
                        }
                        .pointerOnHover()
                        .transition(.driftUp)
                        Divider().overlay(Color.appBorder)
                    }
                }
            }
        }
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}


private struct ThreadRow: View {
    let vm: InboxViewModel
    let thread: MessageThread
    let isOpen: Bool
    let isChecked: Bool
    let onToggleCheck: () -> Void
    @State private var isHovering = false
    @State private var preview = AttachmentPreviewController()

    /// Fixed regardless of hover/selection/attachment state, so the row
    /// never visually shifts. `leadingInset` + `senderExtraLeadingPadding`
    /// are sized so the checkbox/star/important cluster sits centered
    /// between the provider color indicator and the sender name, instead
    /// of hugging the sender side.
    private let leadingInset: CGFloat = 3
    private let checkboxClusterWidth: CGFloat = 22
    private let starClusterWidth: CGFloat = 22
    private let importantClusterWidth: CGFloat = 22
    private let senderExtraLeadingPadding: CGFloat = 11
    private let rowHorizontalPadding: CGFloat = 16

    /// Sum of the 4 fixed leading elements (spacer/checkbox/star/important)
    /// plus the 4 row-spacing gaps between them plus the sender's extra
    /// leading padding, so the attachment row below can align under the
    /// subject text precisely.
    private var contentIndent: CGFloat {
        leadingInset + checkboxClusterWidth + starClusterWidth + importantClusterWidth + 4 * 10 + senderExtraLeadingPadding
    }

    var body: some View {
        let message = thread.latest

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Color.clear.frame(width: leadingInset)

                Button(action: onToggleCheck) {
                    Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                        .font(.custom("Inter", size: 13))
                        .foregroundStyle(isChecked ? Color.appAccent : .secondary)
                        .scaleEffect(isChecked ? 1.08 : 1)
                        .animation(.spring(response: 0.22, dampingFraction: 1), value: isChecked)
                        .frame(width: checkboxClusterWidth, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pointerPlain)
                .frame(width: checkboxClusterWidth, alignment: .leading)

                Button { withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) { vm.toggleStarred(message) } } label: {
                    Image(systemName: message.isStarred ? "star.fill" : "star")
                        .font(.custom("Inter", size: 13))
                        .foregroundStyle(message.isStarred ? .yellow : .secondary)
                        .scaleEffect(message.isStarred ? 1.1 : 1)
                        .frame(width: starClusterWidth, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pointerPlain)
                .frame(width: starClusterWidth, alignment: .leading)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: message.isStarred)

                Button { withAnimation(.easeOut(duration: 0.18)) { vm.toggleImportant(message) } } label: {
                    Image(systemName: message.isImportant ? "bookmark.fill" : "bookmark")
                        .font(.custom("Inter", size: 13))
                        // Matches the sidebar's own Important nav item tint.
                        .foregroundStyle(message.isImportant ? Color(hex: "#e2678f").opacity(0.85) : .secondary)
                        .frame(width: importantClusterWidth, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pointerPlain)
                .frame(width: importantClusterWidth, alignment: .leading)

                highlightedText(message.senderName, terms: vm.searchHighlightTerms)
                    .font(.appSubheadline.weight(thread.hasUnread ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)
                    .animation(.easeOut(duration: 0.2), value: thread.hasUnread)
                    .padding(.leading, senderExtraLeadingPadding)

                if thread.count > 1 {
                    Text("\(thread.count)")
                        .font(.appCaption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.appHover))
                }

                (
                    highlightedText(message.subject, terms: vm.searchHighlightTerms)
                        .font(.appSubheadline.weight(thread.hasUnread ? .semibold : .regular))
                    + Text("  —  ").foregroundColor(.secondary)
                    + highlightedText(message.snippet, terms: vm.searchHighlightTerms).foregroundColor(.secondary)
                )
                .lineLimit(1)
                .truncationMode(.tail)

                Spacer(minLength: 8)

                Text(message.receivedAt, format: .relative(presentation: .numeric))
                    .font(.appCaption2)
                    .foregroundStyle(.secondary)
            }

            if !message.attachments.isEmpty {
                HStack(spacing: 8) {
                    // Aligned under the subject/snippet text, not the
                    // sender column.
                    Color.clear.frame(width: contentIndent + 150 + 10)
                    ForEach(message.attachments.prefix(3)) { attachment in
                        AttachmentPill(attachment: attachment, isLoading: preview.loadingAttachmentId == attachment.id)
                            // A plain tap on this pill is handled here, by
                            // the pill itself, before it can ever reach the
                            // row's own onTapGesture (attached in
                            // MessageListView) — that's what keeps clicking
                            // an attachment from also opening the thread.
                            .onTapGesture { preview.preview(attachment, on: message, vm: vm) }
                            .pointerOnHover()
                    }
                }
            }
        }
        .padding(.horizontal, rowHorizontalPadding)
        .padding(.vertical, 14)
        .background(isOpen || isChecked ? Color.appHover : (isHovering ? Color.appHover.opacity(0.6) : .clear))
        .contentShape(Rectangle())
        .overlay(alignment: .leading) {
            // Provider color "flag" — flat on the left/top/bottom, spans
            // the row's full height edge-to-edge, rounded only where it
            // bulges into the row on the right.
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 0,
                bottomTrailingRadius: 6, topTrailingRadius: 6,
                style: .continuous
            )
            .fill(vm.color(for: message).opacity(thread.hasUnread ? 1 : 0.35))
            .frame(width: 8)
            .frame(maxHeight: .infinity)
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .quickLookPreview($preview.previewURL)
        .draggable(vm.beginDrag(for: thread)) {
            DragCountPill(count: vm.selectedThreadKeys.count)
        }
    }
}

/// Cursor-follow drag preview shown while dragging one or more selected rows
/// onto a sidebar folder — replaces the default full-row snapshot with a
/// compact "Move N conversations" pill, matching Mail's own drag affordance.
private struct DragCountPill: View {
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "envelope.fill")
                .foregroundStyle(Color.black.opacity(0.55))
            Text(count == 1 ? "Move 1 conversation" : "Move \(count) conversations")
                .font(.appSubheadline.weight(.medium))
                .foregroundStyle(.black)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(height: 40, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
    }
}

/// Small filename chip shown under a row when its message has attachments —
/// Gmail shows the same thing inline in the message list, not just once
/// you've opened the message.
private struct AttachmentPill: View {
    let attachment: Attachment
    var isLoading: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: AttachmentIcon.systemName(forMimeType: attachment.mimeType))
                    .font(.custom("Inter", size: 7).weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(RoundedRectangle(cornerRadius: 4).fill(tint))
            }
            Text(attachment.filename)
                .font(.appCaption2)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: 170, alignment: .leading)
        .background(Capsule().strokeBorder(Color.appBorder))
        .contentShape(Rectangle())
    }

    private var tint: Color {
        if attachment.mimeType == "application/pdf" { return Color(hex: "#e5493f") }
        if attachment.mimeType.hasPrefix("image/") { return Color(hex: "#5b9bd5") }
        if attachment.mimeType.contains("sheet") || attachment.mimeType.contains("excel") { return Color(hex: "#5fb488") }
        return Color(hex: "#8a8f98")
    }
}
