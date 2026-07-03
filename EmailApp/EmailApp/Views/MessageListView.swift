import SwiftUI

struct MessageListView: View {
    @Bindable var vm: InboxViewModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(vm.filteredMessages) { message in
                    MessageRow(
                        message: message,
                        isSelected: vm.selectedMessageId == message.id
                    )
                    .onTapGesture { vm.select(message) }
                }
            }
            .padding(8)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct MessageRow: View {
    let message: Message
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(message.provider.color)
                .frame(width: 3)

            Circle()
                .fill(message.isRead ? Color.clear : Color(hex: "#5b9bd5"))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(message.senderName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
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
