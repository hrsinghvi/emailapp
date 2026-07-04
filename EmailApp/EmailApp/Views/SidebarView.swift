import SwiftUI

struct SidebarView: View {
    @Bindable var vm: InboxViewModel
    @State private var isConnectingGmail = false
    @State private var isConnectingOutlook = false
    @State private var isInboxExpanded = false

    private let mailFolders: [(id: String, label: String, icon: String)] = [
        ("all", "All Mail", "tray.2"),
        ("sent", "Sent", "paperplane"),
        ("drafts", "Drafts", "doc"),
        ("archive", "Archive", "archivebox"),
        ("trash", "Trash", "trash")
    ]

    private var primaryAccount: Account? { vm.accounts.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 14)

            SearchRow(vm: vm)
                .padding(.bottom, 14)

            SectionLabel("Views")
            VStack(alignment: .leading, spacing: 2) {
                InboxNavItem(vm: vm, isExpanded: $isInboxExpanded)
                ForEach([MessageCategory.social, .promotions, .updates, .forums], id: \.self) { category in
                    CategoryNavItem(vm: vm, category: category)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 14)

            SectionLabel("Mail")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(mailFolders, id: \.id) { folder in
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
            .padding(.top, 6)

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

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(primaryAccount?.provider.color ?? Color.appHover)
                .frame(width: 32, height: 32)
                .overlay(
                    Text(primaryAccount?.prettyLocalName.prefix(1) ?? "?")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(primaryAccount?.prettyLocalName ?? "No account")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(primaryAccount?.email ?? "Connect an account below")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                vm.composeContext = .new
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(Circle().fill(Color.appHover))
            }
            .buttonStyle(.plain)
        }
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

/// Tapping this focuses the existing search field in the top bar (same
/// trigger Cmd+K already uses) rather than duplicating a second search
/// implementation in the sidebar.
private struct SearchRow: View {
    let vm: InboxViewModel

    var body: some View {
        Button {
            vm.searchFocusTrigger += 1
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .frame(width: 18)
                Text("Search")
                    .font(.subheadline)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
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

/// The "Inbox" row doubles as the Primary category view (colored icon +
/// unread count, like the other Views rows) and a disclosure: the chevron
/// expands Gmail/Outlook shortcuts that open the inbox pre-filtered to that
/// provider — same `vm.providerFilter` that used to live in top-bar chips.
private struct InboxNavItem: View {
    @Bindable var vm: InboxViewModel
    @Binding var isExpanded: Bool

    private var isActive: Bool { vm.selectedFolder == "inbox" && vm.categoryFilter == .primary }
    private var unreadBadge: String? { vm.totalUnreadCount > 0 ? "\(vm.totalUnreadCount)" : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                vm.selectedFolder = "inbox"
                vm.categoryFilter = .primary
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: MessageCategory.primary.icon)
                        .foregroundStyle(MessageCategory.primary.tint)
                        .frame(width: 18)
                    Text("Inbox")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if let unreadBadge {
                        Text(unreadBadge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.up")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : 180))
                        .contentShape(Rectangle())
                        .onTapGesture { isExpanded.toggle() }
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(isActive ? Color.appHover : .clear))
            }
            .buttonStyle(.plain)

            if isExpanded {
                ProviderShortcut(label: "Gmail", color: Provider.gmail.color, isActive: isActive && vm.providerFilter == .gmail) {
                    vm.selectedFolder = "inbox"
                    vm.categoryFilter = .primary
                    vm.providerFilter = .gmail
                }
                ProviderShortcut(label: "Outlook", color: Provider.outlook.color, isActive: isActive && vm.providerFilter == .outlook) {
                    vm.selectedFolder = "inbox"
                    vm.categoryFilter = .primary
                    vm.providerFilter = .outlook
                }
            }
        }
    }
}

/// A Views row for one of the non-Primary categories (Social, Promotions,
/// Updates, Forums) — colored icon + right-aligned unread count, Notion
/// Mail style.
private struct CategoryNavItem: View {
    @Bindable var vm: InboxViewModel
    let category: MessageCategory

    private var isActive: Bool { vm.selectedFolder == "inbox" && vm.categoryFilter == category }
    private var badge: String? {
        let count = vm.unreadCount(for: category)
        return count > 0 ? "\(count)" : nil
    }

    var body: some View {
        Button {
            vm.selectedFolder = "inbox"
            vm.categoryFilter = category
            vm.providerFilter = nil
        } label: {
            HStack(spacing: 10) {
                Image(systemName: category.icon)
                    .foregroundStyle(category.tint)
                    .frame(width: 18)
                Text(category.label)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(isActive ? Color.appHover : .clear))
        }
        .buttonStyle(.plain)
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
