import SwiftUI
import ServiceManagement
import os

enum QuitBehavior: String, Codable, CaseIterable {
    case stayInDock
    case quitFully

    var label: String {
        switch self {
        case .stayInDock: return "Keep running when the last window closes"
        case .quitFully: return "Quit fully when the last window closes"
        }
    }
}

enum DefaultReplyBehavior: String, Codable, CaseIterable {
    case reply
    case replyAll

    var label: String {
        switch self {
        case .reply: return "Reply"
        case .replyAll: return "Reply All"
        }
    }
}

/// Every local (non-MCP) setting the app has, backed by UserDefaults so it
/// survives relaunches. MCP settings live in Supabase instead (the backend
/// has to read them too) — see `MCPSettingsService`.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let launchAtLogin = "settings.launchAtLogin"
        static let keepAwakeDuringSync = "settings.keepAwakeDuringSync"
        static let quitBehavior = "settings.quitBehavior"
        static let syncFrequencyMinutes = "settings.syncFrequencyMinutes"
        static let notificationsEnabled = "settings.notificationsEnabled"
        static let mutedAccountEmails = "settings.mutedAccountEmails"
        static let undoSendDelay = "settings.undoSendDelay"
        static let defaultReplyBehavior = "settings.defaultReplyBehavior"
        static let signatures = "settings.signatures"
        static let accountColors = "settings.accountColors"
        static let gesturesEnabled = "settings.gesturesEnabled"
        static let hasBackfilledMailHistory = "settings.hasBackfilledMailHistory"
        static let hasBackfilledCategories = "settings.hasBackfilledCategories"
        static let hasBackfilledCategoryMail = "settings.hasBackfilledCategoryMail"
    }

    private let defaults = UserDefaults.standard

    var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
            applyLoginItem()
        }
    }

    var keepAwakeDuringSync: Bool {
        didSet { defaults.set(keepAwakeDuringSync, forKey: Key.keepAwakeDuringSync) }
    }

    var quitBehavior: QuitBehavior {
        didSet { defaults.set(quitBehavior.rawValue, forKey: Key.quitBehavior) }
    }

    /// 0 means "realtime only, no polling" — realtime push already covers
    /// new mail; this is a belt-and-suspenders periodic refresh.
    var syncFrequencyMinutes: Int {
        didSet { defaults.set(syncFrequencyMinutes, forKey: Key.syncFrequencyMinutes) }
    }

    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) }
    }

    var mutedAccountEmails: Set<String> {
        didSet { defaults.set(Array(mutedAccountEmails), forKey: Key.mutedAccountEmails) }
    }

    var undoSendDelay: Double {
        didSet { defaults.set(undoSendDelay, forKey: Key.undoSendDelay) }
    }

    var defaultReplyBehavior: DefaultReplyBehavior {
        didSet { defaults.set(defaultReplyBehavior.rawValue, forKey: Key.defaultReplyBehavior) }
    }

    /// Keyed by account email — appended to the compose body when starting
    /// a new message, reply, or forward from that account.
    var signatures: [String: String] {
        didSet { defaults.set(signatures, forKey: Key.signatures) }
    }

    /// Keyed by account email, hex string — overrides the default
    /// per-provider color (Gmail red / Outlook blue) for every color
    /// indicator tied to that account: the row accent bar, reading pane,
    /// sidebar account dot, Settings account rows.
    var accountColors: [String: String] {
        didSet { defaults.set(accountColors, forKey: Key.accountColors) }
    }

    var gesturesEnabled: Bool {
        didSet { defaults.set(gesturesEnabled, forKey: Key.gesturesEnabled) }
    }

    /// One-time deep-history backfill (2000 latest from Gmail, everything
    /// from Outlook) — runs once ever, not on every sync.
    var hasBackfilledMailHistory: Bool {
        didSet { defaults.set(hasBackfilledMailHistory, forKey: Key.hasBackfilledMailHistory) }
    }

    /// One-time re-categorization of Gmail mail synced before this app
    /// started reading Gmail's real CATEGORY_* label instead of guessing.
    var hasBackfilledCategories: Bool {
        didSet { defaults.set(hasBackfilledCategories, forKey: Key.hasBackfilledCategories) }
    }

    /// One-time deep backfill of Social/Updates/Forums/Primary (each up to
    /// 2000), separate from the flat inbox-history backfill so every
    /// category gets its own budget instead of competing for one limit.
    var hasBackfilledCategoryMail: Bool {
        didSet { defaults.set(hasBackfilledCategoryMail, forKey: Key.hasBackfilledCategoryMail) }
    }

    private init() {
        launchAtLogin = defaults.object(forKey: Key.launchAtLogin) as? Bool ?? false
        keepAwakeDuringSync = defaults.object(forKey: Key.keepAwakeDuringSync) as? Bool ?? false
        quitBehavior = QuitBehavior(rawValue: defaults.string(forKey: Key.quitBehavior) ?? "") ?? .stayInDock
        syncFrequencyMinutes = defaults.object(forKey: Key.syncFrequencyMinutes) as? Int ?? 0
        notificationsEnabled = defaults.object(forKey: Key.notificationsEnabled) as? Bool ?? true
        mutedAccountEmails = Set(defaults.stringArray(forKey: Key.mutedAccountEmails) ?? [])
        undoSendDelay = defaults.object(forKey: Key.undoSendDelay) as? Double ?? 8
        defaultReplyBehavior = DefaultReplyBehavior(rawValue: defaults.string(forKey: Key.defaultReplyBehavior) ?? "") ?? .reply
        signatures = defaults.dictionary(forKey: Key.signatures) as? [String: String] ?? [:]
        accountColors = defaults.dictionary(forKey: Key.accountColors) as? [String: String] ?? [:]
        gesturesEnabled = defaults.object(forKey: Key.gesturesEnabled) as? Bool ?? true
        hasBackfilledMailHistory = defaults.object(forKey: Key.hasBackfilledMailHistory) as? Bool ?? false
        hasBackfilledCategories = defaults.object(forKey: Key.hasBackfilledCategories) as? Bool ?? false
        hasBackfilledCategoryMail = defaults.object(forKey: Key.hasBackfilledCategoryMail) as? Bool ?? false
    }

    /// Registers/unregisters with `SMAppService` — the real macOS login-item
    /// mechanism (System Settings > General > Login Items reflects this).
    private func applyLoginItem() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            AppLog.sync.error("Login item registration failed: \(error.localizedDescription)")
        }
    }
}
