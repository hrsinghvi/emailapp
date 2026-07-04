import SwiftUI

struct SidebarView: View {
    @Bindable var vm: InboxViewModel
    @State private var isConnectingGmail = false
    @State private var isConnectingOutlook = false
    @State private var isInboxExpanded = true

    /// Plain (non-category) folders shown below the colored Views rows,
    /// in one continuous list — no section dividers. Each still gets its
    /// own muted icon tint, matching the Views rows above them — every
    /// sidebar icon (these plus the MessageCategory ones) uses a distinct
    /// hue, not just a different shade of one already in use.
    private let mailFolders: [(id: String, label: String, icon: String, tint: Color)] = [
        ("sent", "Sent", "paperplane", Color(hex: "#4fc3c7").opacity(0.8)),
        ("drafts", "Drafts", "doc", Color(hex: "#9099a3").opacity(0.8))
    ]

    private var primaryAccount: Account? { vm.accounts.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            composeButton
                .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 2) {
                InboxNavItem(vm: vm, isExpanded: $isInboxExpanded)
                ForEach([MessageCategory.promotions, .social, .updates, .forums], id: \.self) { category in
                    CategoryNavItem(vm: vm, category: category)
                }

                NavItem(
                    label: "Starred", icon: "star", isActive: vm.selectedFolder == "starred",
                    tint: Color(hex: "#e8c547").opacity(0.85)
                ) {
                    vm.selectedFolder = "starred"
                }

                ForEach(mailFolders, id: \.id) { folder in
                    NavItem(
                        label: folder.label,
                        icon: folder.icon,
                        isActive: vm.selectedFolder == folder.id,
                        tint: folder.tint,
                        badge: folder.id == "drafts" && !vm.drafts.isEmpty ? "\(vm.drafts.count)" : nil
                    ) {
                        vm.selectedFolder = folder.id
                    }
                }

                NavItem(
                    label: "Important", icon: "bookmark", isActive: vm.selectedFolder == "important",
                    tint: Color(hex: "#e2678f").opacity(0.85)
                ) {
                    vm.selectedFolder = "important"
                }
                NavItem(
                    label: "Archive", icon: "archivebox", isActive: vm.selectedFolder == "archive",
                    tint: Color(hex: "#a8c14e").opacity(0.8)
                ) {
                    vm.selectedFolder = "archive"
                }
                NavItem(
                    label: "Trash", icon: "trash", isActive: vm.selectedFolder == "trash",
                    tint: Color(hex: "#7b8fe0").opacity(0.8)
                ) {
                    vm.selectedFolder = "trash"
                }
                NavItem(
                    label: "All Mail", icon: "envelope", isActive: vm.selectedFolder == "all",
                    tint: Color(hex: "#c766c9").opacity(0.8)
                ) {
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
    /// it's setup/utility, not a view you navigate into. Each button
    /// disappears once that provider is already connected, instead of
    /// permanently cluttering the bottom of the sidebar.
    private var connectRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !vm.accounts.contains(where: { $0.provider == .gmail }) {
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
            }
            if !vm.accounts.contains(where: { $0.provider == .outlook }) {
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
    }

    private var footer: some View {
        ProfileFooterButton(vm: vm, primaryAccount: primaryAccount)
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
                vm.providerFilter = nil
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
                        .iconButtonHitArea()
                        .onTapGesture { isExpanded.toggle() }
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(isActive ? Color.appHover : .clear))
                .animation(.easeOut(duration: 0.18), value: isActive)
                .contentShape(Rectangle())
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(isActive ? Color.appHover : .clear))
                .animation(.easeOut(duration: 0.18), value: isActive)
            .contentShape(Rectangle())
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(isActive ? Color.appHover : .clear))
                .animation(.easeOut(duration: 0.18), value: isActive)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Its own struct (not a computed property) so the hover state is stable
/// per-instance instead of being recreated on every SidebarView re-render.
private struct ProfileFooterButton: View {
    let vm: InboxViewModel
    let primaryAccount: Account?
    @State private var isHovering = false

    var body: some View {
        Button { vm.isSettingsPresented = true } label: {
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

                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(isHovering ? Color.appHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .padding(.top, 10)
        .overlay(alignment: .top) { Divider().overlay(Color.appBorder) }
    }
}

private struct NavItem: View {
    let label: String
    let icon: String
    let isActive: Bool
    var tint: Color = .secondary
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 18)
                Text(label)
                    .font(.appSubheadline)
                    .foregroundStyle(isActive ? .primary : .secondary)
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
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.appHover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
