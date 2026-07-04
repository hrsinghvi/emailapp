import SwiftUI

struct SidebarView: View {
    @Bindable var vm: InboxViewModel
    @State private var isConnectingGmail = false
    @State private var isConnectingOutlook = false

    private let folders: [(id: String, label: String, icon: String)] = [
        ("inbox", "Inbox", "tray"),
        ("sent", "Sent", "paperplane"),
        ("drafts", "Drafts", "doc"),
        ("archive", "Archive", "archivebox"),
        ("trash", "Trash", "trash")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                vm.composeContext = .new
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil")
                    Text("Compose")
                    Spacer()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.appSurfaceRaised))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.appBorder))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(folders, id: \.id) { folder in
                    NavItem(
                        label: folder.label,
                        icon: folder.icon,
                        isActive: vm.selectedFolder == folder.id,
                        badge: folder.id == "drafts" && !vm.drafts.isEmpty ? "\(vm.drafts.count)" : nil
                    ) {
                        vm.selectedFolder = folder.id
                    }
                }
            }

            Spacer()

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

                connectButton(
                    isConnecting: isConnectingGmail, label: "Connect Gmail",
                    action: {
                        isConnectingGmail = true
                        Task {
                            await vm.loadGmail()
                            isConnectingGmail = false
                        }
                    }
                )
                connectButton(
                    isConnecting: isConnectingOutlook, label: "Connect Outlook",
                    action: {
                        isConnectingOutlook = true
                        Task {
                            await vm.loadOutlook()
                            isConnectingOutlook = false
                        }
                    }
                )
            }
            .padding(.top, 8)
            .overlay(alignment: .top) { Divider().overlay(Color.appBorder) }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.appSurface)
    }

    private func connectButton(isConnecting: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isConnecting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus.circle")
                }
                Text(isConnecting ? "Connecting…" : label)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .disabled(isConnecting)
    }
}

private struct NavItem: View {
    let label: String
    let icon: String
    let isActive: Bool
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 18)
                Text(label)
                    .font(.subheadline)
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.appHover))
                }
            }
            .foregroundStyle(isActive ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.appHover : .clear)
            )
        }
        .buttonStyle(.plain)
    }
}
