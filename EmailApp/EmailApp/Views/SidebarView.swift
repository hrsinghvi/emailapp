import SwiftUI

struct SidebarView: View {
    @Bindable var vm: InboxViewModel
    @State private var isConnectingGmail = false
    @State private var isConnectingOutlook = false

    private let folders: [(id: String, label: String, icon: String)] = [
        ("inbox", "Inbox", "tray"),
        ("sent", "Sent", "paperplane"),
        ("drafts", "Drafts", "doc")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                vm.composeContext = .new
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "pencil")
                    Text("Compose")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color(hex: "#b58ee0").opacity(0.9)))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(folders, id: \.id) { folder in
                    NavItem(
                        label: folder.label,
                        icon: folder.icon,
                        isActive: vm.selectedFolder == folder.id
                    ) {
                        vm.selectedFolder = folder.id
                    }
                }
            }

            SectionLabel("Accounts")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(vm.accounts) { account in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(account.provider.color)
                            .frame(width: 8, height: 8)
                        Text(account.email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }

                Button {
                    isConnectingGmail = true
                    Task {
                        await vm.loadGmail()
                        isConnectingGmail = false
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isConnectingGmail {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "plus.circle")
                        }
                        Text(isConnectingGmail ? "Connecting…" : "Connect Gmail")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .disabled(isConnectingGmail)

                Button {
                    isConnectingOutlook = true
                    Task {
                        await vm.loadOutlook()
                        isConnectingOutlook = false
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isConnectingOutlook {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "plus.circle")
                        }
                        Text(isConnectingOutlook ? "Connecting…" : "Connect Outlook")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .disabled(isConnectingOutlook)
            }

            Spacer()
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct NavItem: View {
    let label: String
    let icon: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 18)
                Text(label)
                    .font(.subheadline)
                Spacer()
            }
            .foregroundStyle(isActive ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.white.opacity(0.10) : .clear)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
    }
}
