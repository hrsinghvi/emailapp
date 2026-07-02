import SwiftUI

struct ReadingPaneView: View {
    @Bindable var vm: InboxViewModel

    var body: some View {
        Group {
            if let message = vm.selectedMessage {
                messageView(message)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "envelope.open")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Select a message")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    private func messageView(_ message: Message) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(message.provider.color)
                            .frame(width: 44, height: 44)
                            .overlay(
                                Text(message.senderInitials)
                                    .font(.headline)
                                    .foregroundStyle(.white)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.senderName)
                                .font(.headline)
                            Text(message.senderEmail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(message.receivedAt, format: .dateTime.month().day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(message.subject)
                        .font(.title2.weight(.semibold))

                    Text(message.body)
                        .font(.body)
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
            }

            actionBar(message)
        }
    }

    private func actionBar(_ message: Message) -> some View {
        HStack(spacing: 10) {
            ActionPill(title: "Reply", icon: "arrowshape.turn.up.left", tint: .white) {}
            ActionPill(title: "Forward", icon: "arrowshape.turn.up.right", tint: .white) {}
            ActionPill(
                title: message.isArchived ? "Unarchive" : "Archive",
                icon: "archivebox",
                tint: .white
            ) {
                vm.toggleArchive(message)
            }
            Spacer()
            ActionPill(title: "Ask Claude", icon: "sparkles", tint: Color(hex: "#b58ee0"), filled: true) {}
        }
        .padding(16)
        .background(.regularMaterial)
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
            .font(.subheadline.weight(.medium))
            .foregroundStyle(filled ? tint : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(filled ? tint.opacity(0.18) : Color.white.opacity(0.07))
            )
        }
        .buttonStyle(.plain)
    }
}
