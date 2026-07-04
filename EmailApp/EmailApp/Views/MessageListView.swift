import AppKit
import SwiftUI

struct MessageListView: View {
    @Bindable var vm: InboxViewModel

    var body: some View {
        VStack(spacing: 8) {
            if !vm.selectedThreadKeys.isEmpty {
                BulkActionBar(vm: vm)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(vm.pagedThreads) { thread in
                        SwipeableRow(
                            onSwipeRight: { vm.archiveThread(thread) },
                            onSwipeLeft: { vm.markThreadUnread(thread) }
                        ) {
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
                        }
                        Divider().overlay(Color.appBorder)
                    }
                }
            }
        }
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct BulkActionBar: View {
    @Bindable var vm: InboxViewModel

    var body: some View {
        HStack(spacing: 10) {
            Button {
                vm.toggleSelectAll()
            } label: {
                Image(systemName: allSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(allSelected ? Color.appAccent : .secondary)
            }
            .buttonStyle(.plain)

            Text("\(vm.selectedThreadKeys.count) selected")
                .font(.appCaption)
                .foregroundStyle(.secondary)

            Spacer()

            bulkButton("Archive", icon: "archivebox") { vm.bulkArchive() }
            bulkButton("Delete", icon: "trash") { vm.bulkDelete() }
            bulkButton("Mark Read", icon: "envelope.open") { vm.bulkMarkRead(true) }
            bulkButton("Mark Unread", icon: "envelope.badge") { vm.bulkMarkRead(false) }

            Button {
                vm.selectedThreadKeys.removeAll()
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 10))
    }

    private var allSelected: Bool {
        !vm.filteredThreads.isEmpty && Set(vm.filteredThreads.map(\.id)) == vm.selectedThreadKeys
    }

    private func bulkButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.appCaption.weight(.medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

private struct ThreadRow: View {
    let vm: InboxViewModel
    let thread: MessageThread
    let isOpen: Bool
    let isChecked: Bool
    let onToggleCheck: () -> Void
    @State private var isHovering = false

    /// Fixed regardless of hover/selection/attachment state, so the row
    /// never visually shifts.
    private let leadingInset: CGFloat = 14
    private let checkboxClusterWidth: CGFloat = 22
    private let starClusterWidth: CGFloat = 22
    private let importantClusterWidth: CGFloat = 22
    private let rowHorizontalPadding: CGFloat = 16

    /// Sum of the 4 fixed leading elements (spacer/checkbox/star/important)
    /// plus the 4 row-spacing gaps between them, so the attachment row
    /// below can align under the subject text precisely.
    private var contentIndent: CGFloat {
        leadingInset + checkboxClusterWidth + starClusterWidth + importantClusterWidth + 4 * 10
    }

    var body: some View {
        let message = thread.latest

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Color.clear.frame(width: leadingInset)

                Button(action: onToggleCheck) {
                    Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(isChecked ? Color.appAccent : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: checkboxClusterWidth, alignment: .leading)
                .padding(.top, 2)

                Button { vm.toggleStarred(message) } label: {
                    Image(systemName: message.isStarred ? "star.fill" : "star")
                        .foregroundStyle(message.isStarred ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: starClusterWidth, alignment: .leading)
                .padding(.top, 2)

                Button { vm.toggleImportant(message) } label: {
                    Image(systemName: message.isImportant ? "bookmark.fill" : "bookmark")
                        .foregroundStyle(message.isImportant ? Color.appAccent : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: importantClusterWidth, alignment: .leading)
                .padding(.top, 2)

                Text(message.senderName)
                    .font(.appSubheadline.weight(thread.hasUnread ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)

                if thread.count > 1 {
                    Text("\(thread.count)")
                        .font(.appCaption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.appHover))
                }

                (
                    Text(message.subject).font(.appSubheadline.weight(thread.hasUnread ? .semibold : .regular))
                    + Text("  —  ").foregroundColor(.secondary)
                    + Text(message.snippet).foregroundColor(.secondary)
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
                        AttachmentPill(attachment: attachment)
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
            .fill(message.provider.color.opacity(thread.hasUnread ? 1 : 0.35))
            .frame(width: 8)
            .frame(maxHeight: .infinity)
        }
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }
}

/// Small filename chip shown under a row when its message has attachments —
/// Gmail shows the same thing inline in the message list, not just once
/// you've opened the message.
private struct AttachmentPill: View {
    let attachment: Attachment

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: AttachmentIcon.systemName(forMimeType: attachment.mimeType))
                .font(.custom("DM Sans", size: 7).weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(tint))
            Text(attachment.filename)
                .font(.appCaption2)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: 170, alignment: .leading)
        .background(Capsule().strokeBorder(Color.appBorder))
    }

    private var tint: Color {
        if attachment.mimeType == "application/pdf" { return Color(hex: "#e5493f") }
        if attachment.mimeType.hasPrefix("image/") { return Color(hex: "#5b9bd5") }
        if attachment.mimeType.contains("sheet") || attachment.mimeType.contains("excel") { return Color(hex: "#5fb488") }
        return Color(hex: "#8a8f98")
    }
}
