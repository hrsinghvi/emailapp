import SwiftUI

struct MessageListView: View {
    @Bindable var vm: InboxViewModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 4, pinnedViews: .sectionHeaders) {
                ForEach(vm.groupedByCategory, id: \.category?.id) { group in
                    Section {
                        ForEach(group.messages) { message in
                            MessageRow(
                                message: message,
                                category: group.category,
                                isSelected: vm.selectedMessageId == message.id
                            )
                            .onTapGesture { vm.select(message) }
                        }
                    } header: {
                        SectionHeader(
                            title: group.category?.name ?? "Other",
                            color: group.category?.color ?? .gray,
                            count: group.messages.count
                        )
                    }
                }
            }
            .padding(8)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct SectionHeader: View {
    let title: String
    let color: Color
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }
}

private struct MessageRow: View {
    let message: Message
    let category: MailCategory?
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
                if let category {
                    Text(category.name)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(category.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(category.color.opacity(0.15)))
                }
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
