import SwiftUI

struct SidebarView: View {
    @Bindable var vm: InboxViewModel
    @State private var isConnectingGmail = false
    @State private var isConnectingOutlook = false
    @State private var isInboxExpanded = true

    /// Plain (non-category) folders shown below the colored Views rows,
    /// in one continuous list — no section dividers.
    private let mailFolders: [(id: String, label: String, icon: String)] = [
        ("sent", "Sent", "paperplane"),
        ("drafts", "Drafts", "doc")
    ]

    private var primaryAccount: Account? { vm.accounts.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            composeButton
                .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 2) {
                InboxNavItem(vm: vm, isExpanded: $isInboxExpanded)
                ForEach([MessageCategory.social, .promotions, .updates, .forums], id: \.self) { category in
                    CategoryNavItem(vm: vm, category: category)
                }

                NavItem(label: "Starred", icon: "star", isActive: vm.selectedFolder == "starred") {
                    vm.selectedFolder = "starred"
                }

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

                NavItem(label: "Important", icon: "bookmark", isActive: vm.selectedFolder == "important") {
                    vm.selectedFolder = "important"
                }
                NavItem(label: "Archive", icon: "archivebox", isActive: vm.selectedFolder == "archive") {
                    vm.selectedFolder = "archive"
                }
                NavItem(label: "Trash", icon: "trash", isActive: vm.selectedFolder == "trash") {
                    vm.selectedFolder = "trash"
                }
                NavItem(label: "All Mail", icon: "envelope", isActive: vm.selectedFolder == "all") {
                    vm.selectedFolder = "all"
                }
            }

            Spacer()

            connectRow
                .padding(.bottom, 8)

            footer
        }
        .padding(14)
        .padding(.top, 34)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.appSurface)
    }

    private var composeButton: some View {
        Button {
            vm.composeContext = .new
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                Text("Compose")
                Spacer()
            }
            .font(.appSubheadline.weight(.semibold))
            .foregroundStyle(Color.appBackground)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.92)))
        }
        .buttonStyle(.plain)
    }

    /// Real account-connection management (distinct from `Provider`
    /// shortcuts on the Inbox row) — kept out of the flat nav list since
    /// it's setup/utility, not a view you navigate into.
    private var connectRow: some View {
        VStack(alignment: .leading, spacing: 2) {
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
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(primaryAccount?.provider.color ?? Color.appHover)
                .frame(width: 32, height: 32)
                .overlay(
                    Text(primaryAccount?.prettyLocalName.prefix(1) ?? "?")
                        .font(.appSubheadline.weight(.semibold))
                        .foregroundStyle(.white)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(primaryAccount?.prettyLocalName ?? "No account")
                    .font(.appCaption.weight(.semibold))
                    .lineLimit(1)
                Text(primaryAccount?.email ?? "Connect below")
                    .font(.appCaption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // No settings screen exists yet — this doesn't do anything.
            Image(systemName: "gearshape")
                .foregroundStyle(.secondary)
        }
        .padding(.top, 10)
        .overlay(alignment: .top) { Divider().overlay(Color.appBorder) }
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
                    .font(.appCaption)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .disabled(isConnecting)
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
                        .font(.appSubheadline.weight(.medium))
                    Spacer()
                    if let unreadBadge {
                        Text(unreadBadge)
                            .font(.appCaption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.appHover))
                    }
                    Image(systemName: "chevron.up")
                        .font(.appCaption2.weight(.semibold))
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
                    .font(.appSubheadline.weight(.medium))
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.appCaption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.appHover))
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
                    .font(.appSubheadline)
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
                    .font(.appSubheadline)
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.appCaption2.weight(.semibold))
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
