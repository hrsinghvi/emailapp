import SwiftUI

struct SidebarView: View {
    @Bindable var vm: InboxViewModel
    @State private var isConnectingGmail = false
    @State private var isConnectingOutlook = false

    @State private var isInboxExpanded = true

    private let folders: [(id: String, label: String, icon: String)] = [
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
                InboxNavItem(vm: vm, isExpanded: $isInboxExpanded)

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

/// The "Inbox" row is a disclosure: tapping the label opens the inbox with
/// no provider filter ("All"), the chevron expands/collapses Gmail/Outlook
/// shortcuts that open the inbox pre-filtered to that provider — same
/// filtering `vm.providerFilter` already did as a chip row up top.
private struct InboxNavItem: View {
    @Bindable var vm: InboxViewModel
    @Binding var isExpanded: Bool

    private var isActive: Bool { vm.selectedFolder == "inbox" }
    private var unreadBadge: String? { vm.totalUnreadCount > 0 ? "\(vm.totalUnreadCount)" : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                vm.selectedFolder = "inbox"
                vm.providerFilter = nil
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "tray")
                        .frame(width: 18)
                    Text("Inbox")
                        .font(.subheadline)
                    Spacer()
                    if let unreadBadge {
                        Text(unreadBadge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.appHover))
                    }
                    Image(systemName: "chevron.up")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : 180))
                        .contentShape(Rectangle())
                        .onTapGesture { isExpanded.toggle() }
                }
                .foregroundStyle(isActive ? .primary : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(isActive && vm.providerFilter == nil ? Color.appHover : .clear))
            }
            .buttonStyle(.plain)

            if isExpanded {
                ProviderShortcut(label: "Gmail", color: Provider.gmail.color, isActive: isActive && vm.providerFilter == .gmail) {
                    vm.selectedFolder = "inbox"
                    vm.providerFilter = .gmail
                }
                ProviderShortcut(label: "Outlook", color: Provider.outlook.color, isActive: isActive && vm.providerFilter == .outlook) {
                    vm.selectedFolder = "inbox"
                    vm.providerFilter = .outlook
                }
            }
        }
    }
}

private struct ProviderShortcut: View {
    let label: String
    let color: Color
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 6, height: 6)
                    .padding(.leading, 18)
                Text(label)
                    .font(.subheadline)
                Spacer()
            }
            .foregroundStyle(isActive ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(isActive ? Color.appHover : .clear))
        }
        .buttonStyle(.plain)
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
