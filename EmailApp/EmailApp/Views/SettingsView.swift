import SwiftUI
import AppKit
import Combine

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, accounts, notifications, compose, shortcuts, mcp, advanced, about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "General"
        case .accounts: return "Accounts"
        case .notifications: return "Notifications"
        case .compose: return "Compose"
        case .shortcuts: return "Shortcuts"
        case .mcp: return "MCP"
        case .advanced: return "Advanced"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .accounts: return "person.crop.circle"
        case .notifications: return "bell"
        case .compose: return "square.and.pencil"
        case .shortcuts: return "keyboard"
        case .mcp: return "bolt.horizontal.circle"
        case .advanced: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    let vm: InboxViewModel
    let onClose: () -> Void
    @State private var selection: SettingsSection = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Color.appBorder)
            ScrollView {
                content
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 720, height: 540)
        .background(Color.appBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.appBorder))
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(Circle().fill(Color.appHover))
            }
            .buttonStyle(.pointerPlain)
            .padding(12)
        }
        .shadow(color: .black.opacity(0.5), radius: 32, y: 12)
        .animation(.easeOut(duration: 0.18), value: selection)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { section in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { selection = section }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.icon).frame(width: 18)
                        Text(section.label).font(.appSubheadline)
                        Spacer()
                    }
                    .foregroundStyle(selection == section ? .primary : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(selection == section ? Color.appHover : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pointerPlain)
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 190)
        .background(Color.appSurface)
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .general: GeneralSettingsSection(vm: vm)
        case .accounts: AccountsSettingsSection(vm: vm)
        case .notifications: NotificationsSettingsSection(vm: vm)
        case .compose: ComposeSettingsSection(vm: vm)
        case .shortcuts: ShortcutsSettingsSection()
        case .mcp: MCPSettingsSectionView(vm: vm)
        case .advanced: AdvancedSettingsSection(vm: vm)
        case .about: AboutSettingsSection()
        }
    }
}

// MARK: - Shared building blocks

private struct SettingsHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.appTitle2.weight(.semibold))
            .padding(.bottom, 4)
    }
}

private struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.appSubheadline)
                if let subtitle {
                    Text(subtitle).font(.appCaption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            trailing()
        }
        .padding(.vertical, 8)
    }
}

// MARK: - General

private struct GeneralSettingsSection: View {
    let vm: InboxViewModel
    @Bindable private var settings = AppSettings.shared
    private let syncOptions = [0, 5, 15, 30, 60]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsHeader(title: "General")

            SettingsRow(title: "Launch at login") {
                Toggle("", isOn: $settings.launchAtLogin).labelsHidden().toggleStyle(.switch)
            }
            Divider().overlay(Color.appBorder)

            SettingsRow(title: "Keep computer awake during sync", subtitle: "Prevents sleep only while a sync is actually in flight") {
                Toggle("", isOn: $settings.keepAwakeDuringSync).labelsHidden().toggleStyle(.switch)
            }
            Divider().overlay(Color.appBorder)

            SettingsRow(title: "When the last window closes") {
                Picker("", selection: $settings.quitBehavior) {
                    ForEach(QuitBehavior.allCases, id: \.self) { behavior in
                        Text(behavior == .stayInDock ? "Stay in Dock" : "Quit fully").tag(behavior)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 160)
            }
            Divider().overlay(Color.appBorder)

            SettingsRow(title: "Sync frequency", subtitle: "Realtime push already covers new mail — this is a backup periodic refresh") {
                Picker("", selection: $settings.syncFrequencyMinutes) {
                    Text("Off").tag(0)
                    Text("Every 5 min").tag(5)
                    Text("Every 15 min").tag(15)
                    Text("Every 30 min").tag(30)
                    Text("Every hour").tag(60)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 160)
                .onChange(of: settings.syncFrequencyMinutes) { _, _ in
                    vm.applySyncFrequencyChange()
                }
            }
        }
    }
}

// MARK: - Accounts

private struct AccountsSettingsSection: View {
    let vm: InboxViewModel
    @Bindable private var settings = AppSettings.shared
    @State private var isConnectingGmail = false
    @State private var isConnectingOutlook = false
    @State private var pendingDisconnect: Account?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsHeader(title: "Accounts")

            if vm.accounts.isEmpty {
                Text("No accounts connected yet.").font(.appCaption).foregroundStyle(.secondary)
            }

            ForEach(vm.accounts) { account in
                HStack(spacing: 10) {
                    // Colors every indicator tied to this account: row
                    // accent bar, reading pane, sidebar dot, this row.
                    // A plain ColorPicker's swatch button doesn't shrink
                    // below its default (fairly wide) size, which is what
                    // was overlapping the email text — this is a small
                    // circle instead, opening the real macOS color panel.
                    AccountColorSwatch(colorHex: Binding(
                        get: { settings.accountColors[account.email] },
                        set: { settings.accountColors[account.email] = $0 }
                    ), fallback: account.provider.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.email).font(.appSubheadline)
                        Text("Connected · \(account.provider == .gmail ? "Gmail" : "Outlook")")
                            .font(.appCaption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Mute", isOn: Binding(
                        get: { settings.mutedAccountEmails.contains(account.email) },
                        set: { muted in
                            if muted { settings.mutedAccountEmails.insert(account.email) }
                            else { settings.mutedAccountEmails.remove(account.email) }
                        }
                    ))
                    .toggleStyle(.switch)
                    .font(.appCaption)

                    Button("Disconnect") { pendingDisconnect = account }
                        .buttonStyle(.pointerPlain)
                        .font(.appCaption.weight(.medium))
                        .foregroundStyle(.red)
                }
                .padding(.vertical, 6)
                Divider().overlay(Color.appBorder)
            }

            HStack(spacing: 10) {
                connectButton(isConnecting: isConnectingGmail, label: "Connect Gmail") {
                    isConnectingGmail = true
                    Task { await vm.loadGmail(); isConnectingGmail = false }
                }
                connectButton(isConnecting: isConnectingOutlook, label: "Connect Outlook") {
                    isConnectingOutlook = true
                    Task { await vm.loadOutlook(); isConnectingOutlook = false }
                }
            }
            .padding(.top, 8)
        }
        .alert("Disconnect \(pendingDisconnect?.email ?? "")?", isPresented: Binding(
            get: { pendingDisconnect != nil }, set: { if !$0 { pendingDisconnect = nil } }
        )) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) {
                if let account = pendingDisconnect { vm.disconnectAccount(account) }
                pendingDisconnect = nil
            }
        } message: {
            Text("Its mail stays deleted from this app until you reconnect it.")
        }
    }

    private func connectButton(isConnecting: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isConnecting { ProgressView().controlSize(.small) } else { Image(systemName: "plus.circle") }
                Text(isConnecting ? "Connecting…" : label)
            }
            .font(.appCaption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.appHover))
        }
        .buttonStyle(.pointerPlain)
        .disabled(isConnecting)
    }
}

/// A small circular color swatch (matching the app's existing avatar/dot
/// sizing convention) that opens the real macOS color panel on click —
/// unlike SwiftUI's ColorPicker, whose default swatch button doesn't
/// shrink below a fairly wide fixed size and was overlapping adjacent text.
private struct AccountColorSwatch: View {
    @Binding var colorHex: String?
    let fallback: Color
    @State private var isHovering = false
    @StateObject private var coordinator = ColorPanelCoordinator()

    private var currentColor: Color { colorHex.map { Color(hex: $0) } ?? fallback }

    var body: some View {
        Circle()
            .fill(currentColor)
            .frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(Color.white.opacity(isHovering ? 0.5 : 0.25), lineWidth: 1.5))
            .contentShape(Circle())
            .onHover { isHovering = $0 }
            .onTapGesture { openColorPanel() }
            .pointerOnHover()
            .onDisappear { NSColorPanel.shared.close() }
    }

    private func openColorPanel() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = NSColor(currentColor)
        coordinator.onChange = { newColor in
            colorHex = Color(nsColor: newColor).toHex()
        }
        panel.setTarget(coordinator)
        panel.setAction(#selector(ColorPanelCoordinator.colorChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
    }
}

private final class ColorPanelCoordinator: NSObject, ObservableObject {
    var onChange: ((NSColor) -> Void)?

    @objc func colorChanged(_ sender: NSColorPanel) {
        onChange?(sender.color)
    }
}

// MARK: - Notifications

private struct NotificationsSettingsSection: View {
    let vm: InboxViewModel
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsHeader(title: "Notifications")

            SettingsRow(title: "Enable notifications", subtitle: "Global switch — off silences every account regardless of its own mute setting") {
                Toggle("", isOn: $settings.notificationsEnabled).labelsHidden().toggleStyle(.switch)
            }
            Divider().overlay(Color.appBorder)

            Text("Per-account mutes").font(.appCaption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.top, 8)
            if vm.accounts.isEmpty {
                Text("Connect an account first.").font(.appCaption).foregroundStyle(.secondary)
            }
            ForEach(vm.accounts) { account in
                HStack {
                    Circle().fill(account.color).frame(width: 8, height: 8)
                    Text(account.email).font(.appSubheadline)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { !settings.mutedAccountEmails.contains(account.email) },
                        set: { notify in
                            if notify { settings.mutedAccountEmails.remove(account.email) }
                            else { settings.mutedAccountEmails.insert(account.email) }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!settings.notificationsEnabled)
                }
                .padding(.vertical, 4)
                .opacity(settings.notificationsEnabled ? 1 : 0.4)
            }
        }
    }
}

// MARK: - Compose

private struct ComposeSettingsSection: View {
    let vm: InboxViewModel
    @Bindable private var settings = AppSettings.shared
    @State private var editingSignatureFor: String?
    @State private var signatureDraft = ""

    private let delayOptions: [Double] = [3, 5, 8, 15]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsHeader(title: "Compose")

            SettingsRow(title: "Undo send delay") {
                Picker("", selection: $settings.undoSendDelay) {
                    ForEach(delayOptions, id: \.self) { seconds in
                        Text("\(Int(seconds))s").tag(seconds)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            Divider().overlay(Color.appBorder)

            SettingsRow(title: "Default reply behavior", subtitle: "What ⌘R does — ⌘⇧R always does the other one") {
                Picker("", selection: $settings.defaultReplyBehavior) {
                    ForEach(DefaultReplyBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.label).tag(behavior)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            Divider().overlay(Color.appBorder)

            Text("Signatures").font(.appCaption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
            if vm.accounts.isEmpty {
                Text("Connect an account first.").font(.appCaption).foregroundStyle(.secondary)
            }
            ForEach(vm.accounts) { account in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle().fill(account.color).frame(width: 8, height: 8)
                        Text(account.email).font(.appSubheadline)
                        Spacer()
                    }
                    TextEditor(text: Binding(
                        get: { settings.signatures[account.email] ?? "" },
                        set: { settings.signatures[account.email] = $0 }
                    ))
                    .font(.appCaption)
                    .frame(height: 70)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.appSurface))
                    .scrollContentBackground(.hidden)
                }
                .padding(.vertical, 6)
            }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsSettingsSection: View {
    @Bindable private var settings = AppSettings.shared

    private let shortcuts: [(String, String)] = [
        ("⌘N", "New message"),
        ("⌘R", "Reply (or Reply All — see Compose settings)"),
        ("⌘⇧R", "The other of Reply / Reply All"),
        ("⌘F", "Forward"),
        ("⌘E", "Archive"),
        ("⌘⇧U", "Toggle read/unread"),
        ("⌘K", "Focus search"),
        ("⌘1 / ⌘2 / ⌘3", "All mail / Gmail only / Outlook only"),
        ("↑ / ↓", "Move selection"),
        ("Return", "Open selected thread"),
        ("Delete", "Archive selected"),
        ("⌘,", "Settings"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsHeader(title: "Shortcuts")

            SettingsRow(title: "Swipe gestures", subtitle: "Swipe right to archive, left to mark unread, on message rows") {
                Toggle("", isOn: $settings.gesturesEnabled).labelsHidden().toggleStyle(.switch)
            }
            Divider().overlay(Color.appBorder).padding(.bottom, 6)

            ForEach(shortcuts, id: \.1) { shortcut, action in
                HStack {
                    Text(shortcut).font(.appCaption.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 130, alignment: .leading)
                    Text(action).font(.appSubheadline)
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Advanced

private struct AdvancedSettingsSection: View {
    let vm: InboxViewModel
    @State private var didClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsHeader(title: "Advanced")

            SettingsRow(title: "Local cache", subtitle: "Drops the on-disk message cache and prewarmed HTML, then refetches. Drafts and queued offline actions aren't touched.") {
                Button(didClear ? "Cleared" : "Clear local cache") {
                    vm.clearLocalCache()
                    didClear = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        didClear = false
                    }
                }
                .buttonStyle(.pointerPlain)
                .font(.appCaption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.appHover))
                .animation(.easeOut(duration: 0.15), value: didClear)
            }
        }
    }
}

// MARK: - About

private struct AboutSettingsSection: View {
    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
    private var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsHeader(title: "About")
            Text("EmailApp").font(.appHeadline)
            Text("Version \(version) (\(build))").font(.appCaption).foregroundStyle(.secondary)

            Button("View on GitHub") {
                if let url = URL(string: "https://github.com/hrsinghvi/emailapp") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.pointerPlain)
            .font(.appCaption.weight(.medium))
            .foregroundStyle(Color.appAccent)
            .padding(.top, 8)
        }
    }
}

// MARK: - MCP

private struct MCPSettingsSectionView: View {
    let vm: InboxViewModel
    @State private var settings: RemoteMCPSettings?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isShowingToken = false
    @State private var isRegenerating = false
    @State private var justRegenerated = false
    @State private var callLog: [MCPCallLogEntry] = []
    @State private var isTogglingConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsHeader(title: "MCP")

            if isLoading {
                ProgressView().padding(.top, 20)
            } else if let settings {
                confirmationToggle(settings)
                Divider().overlay(Color.appBorder)
                toolsChecklist(settings)
                Divider().overlay(Color.appBorder)
                bearerTokenRow(settings)
                Divider().overlay(Color.appBorder)
                pendingApprovals
                Divider().overlay(Color.appBorder)
                callLogSection
            } else {
                Text(loadError ?? "Couldn't load MCP settings.")
                    .font(.appCaption).foregroundStyle(.secondary)
                Button("Retry") { Task { await load() } }
                    .buttonStyle(.pointerPlain).font(.appCaption.weight(.medium)).foregroundStyle(Color.appAccent)
            }
        }
        .task { await load() }
        .animation(.easeOut(duration: 0.2), value: settings?.mcpEnabledTools)
        .animation(.easeOut(duration: 0.2), value: vm.pendingMCPActions)
    }

    private func load() async {
        isLoading = true
        do {
            settings = try await MCPSettingsService.fetchSettings()
            callLog = try await MCPSettingsService.fetchCallLog()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func confirmationToggle(_ settings: RemoteMCPSettings) -> some View {
        SettingsRow(
            title: "Require confirmation before write actions",
            subtitle: "When on, send/archive/mark-read tool calls wait for your approval below instead of running immediately"
        ) {
            Toggle("", isOn: Binding(
                get: { settings.mcpRequireConfirmation },
                set: { newValue in
                    guard !isTogglingConfirmation else { return }
                    isTogglingConfirmation = true
                    self.settings?.mcpRequireConfirmation = newValue
                    Task {
                        try? await MCPSettingsService.setRequireConfirmation(newValue)
                        isTogglingConfirmation = false
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
    }

    private func toolsChecklist(_ settings: RemoteMCPSettings) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Enabled tools").font(.appCaption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(MCPToolCatalog.all, id: \.self) { tool in
                HStack {
                    Text(tool).font(.appSubheadline)
                    if MCPToolCatalog.writeTools.contains(tool) {
                        Text("write").font(.appCaption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.appHover))
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { settings.mcpEnabledTools.contains(tool) },
                        set: { enabled in
                            Task {
                                if let updated = try? await MCPSettingsService.setToolEnabled(tool, enabled: enabled, currentTools: settings.mcpEnabledTools) {
                                    self.settings?.mcpEnabledTools = updated
                                }
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                .padding(.vertical, 3)
            }
        }
        .padding(.vertical, 6)
    }

    private func bearerTokenRow(_ settings: RemoteMCPSettings) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Bearer token").font(.appCaption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(isShowingToken ? settings.mcpBearerToken : String(repeating: "•", count: 32))
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.appSurface))
                Button(isShowingToken ? "Hide" : "Reveal") { isShowingToken.toggle() }
                    .buttonStyle(.pointerPlain).font(.appCaption.weight(.medium)).foregroundStyle(Color.appAccent)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(settings.mcpBearerToken, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").iconButtonHitArea()
                }
                .buttonStyle(.pointerPlain).foregroundStyle(.secondary)
                Spacer()
                Button(justRegenerated ? "Regenerated" : (isRegenerating ? "Regenerating…" : "Regenerate")) {
                    guard !isRegenerating else { return }
                    isRegenerating = true
                    Task {
                        if let newToken = try? await MCPSettingsService.regenerateToken() {
                            self.settings?.mcpBearerToken = newToken
                            justRegenerated = true
                            try? await Task.sleep(for: .seconds(2))
                            justRegenerated = false
                        }
                        isRegenerating = false
                    }
                }
                .buttonStyle(.pointerPlain)
                .font(.appCaption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.appHover))
                .disabled(isRegenerating)
            }
            Text("The old token stops working the instant this changes — update any client using it.")
                .font(.appCaption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private var pendingApprovals: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pending approvals").font(.appCaption.weight(.semibold)).foregroundStyle(.secondary)
            if vm.pendingMCPActions.isEmpty {
                Text("Nothing waiting.").font(.appCaption).foregroundStyle(.secondary)
            }
            ForEach(vm.pendingMCPActions) { action in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(action.tool).font(.appSubheadline.weight(.medium))
                        Text(summarize(action)).font(.appCaption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Reject") { Task { await vm.rejectPendingMCPAction(action) } }
                        .buttonStyle(.pointerPlain).font(.appCaption.weight(.medium)).foregroundStyle(.red)
                    Button("Approve") { Task { await vm.approvePendingMCPAction(action) } }
                        .buttonStyle(.pointerPlain).font(.appCaption.weight(.semibold)).foregroundStyle(Color.appAccent)
                }
                .padding(.vertical, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 6)
    }

    private func summarize(_ action: PendingAction) -> String {
        switch action.tool {
        case "send_email":
            let to = action.args["to"]?.arrayValue?.compactMap(\.stringValue).joined(separator: ", ") ?? "?"
            let subject = action.args["subject"]?.stringValue ?? ""
            return "To \(to) — \(subject)"
        case "reply_email":
            return "Reply: \(action.args["body"]?.stringValue?.prefix(60) ?? "")"
        case "archive_email":
            return "Archive message \(action.args["message_id"]?.stringValue ?? "")"
        case "mark_read":
            let read = action.args["is_read"]?.boolValue ?? true
            return read ? "Mark as read" : "Mark as unread"
        default:
            return ""
        }
    }

    private var callLogSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Recent tool calls").font(.appCaption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { Task { callLog = (try? await MCPSettingsService.fetchCallLog()) ?? callLog } }
                    .buttonStyle(.pointerPlain).font(.appCaption2).foregroundStyle(Color.appAccent)
            }
            if callLog.isEmpty {
                Text("No calls yet.").font(.appCaption).foregroundStyle(.secondary)
            }
            ForEach(callLog.prefix(50)) { entry in
                HStack {
                    Text(entry.createdAt, format: .dateTime.month().day().hour().minute())
                        .font(.appCaption2).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                    Text(entry.tool).font(.appCaption).frame(width: 130, alignment: .leading)
                    Text(entry.result).font(.appCaption2.weight(.medium)).foregroundStyle(resultColor(entry.result))
                    Spacer()
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.vertical, 6)
    }

    private func resultColor(_ result: String) -> Color {
        switch result {
        case "success", "approved": return .green
        case "error", "rejected": return .red
        case "pending_approval": return .orange
        default: return .secondary
        }
    }
}
