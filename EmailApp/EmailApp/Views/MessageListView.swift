import AppKit
import SwiftUI

struct MessageListView: View {
    @Bindable var vm: InboxViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            if !vm.selectedThreadKeys.isEmpty {
                BulkActionBar(vm: vm)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
            }

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(vm.filteredThreads) { thread in
                        SwipeableRow(
                            onSwipeRight: { vm.archiveThread(thread) },
                            onSwipeLeft: { vm.markThreadUnread(thread) }
                        ) {
                            ThreadRow(
                                thread: thread,
                                isOpen: vm.selectedThreadKey == thread.id,
                                isChecked: vm.selectedThreadKeys.contains(thread.id),
                                anySelectionActive: !vm.selectedThreadKeys.isEmpty,
                                onToggleCheck: { vm.toggleSelection(thread) }
                            )
                            .onTapGesture {
                                isFocused = true
                                let flags = NSEvent.modifierFlags
                                vm.handleRowClick(thread, shift: flags.contains(.shift), command: flags.contains(.command))
                            }
                        }
                    }
                }
                .padding(8)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.upArrow) { vm.selectAdjacent(-1); return .handled }
        .onKeyPress(.downArrow) { vm.selectAdjacent(1); return .handled }
        .onKeyPress(.return) { vm.openSelected(); return .handled }
        .onKeyPress(.delete) { vm.archiveFocused(); return .handled }
        .onKeyPress(.deleteForward) { vm.archiveFocused(); return .handled }
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
                    .foregroundStyle(allSelected ? Color(hex: "#b58ee0") : .secondary)
            }
            .buttonStyle(.plain)

            Text("\(vm.selectedThreadKeys.count) selected")
                .font(.caption)
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var allSelected: Bool {
        !vm.filteredThreads.isEmpty && Set(vm.filteredThreads.map(\.id)) == vm.selectedThreadKeys
    }

    private func bulkButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

private struct ThreadRow: View {
    let thread: MessageThread
    let isOpen: Bool
    let isChecked: Bool
    let anySelectionActive: Bool
    let onToggleCheck: () -> Void
    @State private var isHovering = false

    var body: some View {
        let message = thread.latest

        HStack(spacing: 10) {
            Button(action: onToggleCheck) {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isChecked ? Color(hex: "#b58ee0") : .secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovering || anySelectionActive ? 1 : 0)
            .frame(width: (isHovering || anySelectionActive) ? nil : 0)

            RoundedRectangle(cornerRadius: 2)
                .fill(message.provider.color)
                .frame(width: 3)

            Circle()
                .fill(thread.hasUnread ? Color(hex: "#5b9bd5") : Color.clear)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(message.senderName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if thread.count > 1 {
                        Text("\(thread.count)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                    }
                    Spacer()
                    Text(message.receivedAt, format: .relative(presentation: .numeric))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(message.subject)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(message.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isOpen || isChecked ? Color.white.opacity(0.07) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }
}
