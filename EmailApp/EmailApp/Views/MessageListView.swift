import SwiftUI

struct MessageListView: View {
    @Bindable var vm: InboxViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(vm.filteredThreads) { thread in
                    ThreadRow(
                        thread: thread,
                        isSelected: vm.selectedThreadKey == thread.id
                    )
                    .onTapGesture {
                        isFocused = true
                        vm.select(thread)
                    }
                }
            }
            .padding(8)
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

private struct ThreadRow: View {
    let thread: MessageThread
    let isSelected: Bool

    var body: some View {
        let message = thread.latest

        HStack(spacing: 10) {
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
                .fill(isSelected ? Color.white.opacity(0.07) : .clear)
        )
        .contentShape(Rectangle())
    }
}
