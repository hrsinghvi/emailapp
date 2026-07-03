import Observation
import SwiftUI

@Observable
final class InboxViewModel {
    enum ComposeContext: Identifiable {
        case new
        case reply(Message)
        case forward(Message)

        var id: String {
            switch self {
            case .new: return "new"
            case .reply(let message): return "reply-\(message.id)"
            case .forward(let message): return "forward-\(message.id)"
            }
        }
    }

    enum SendError: LocalizedError {
        case noAccount
        var errorDescription: String? { "No connected account to send from." }
    }

    var accounts: [Account]
    var messages: [Message]

    var selectedMessageId: UUID?
    var selectedFolder: String = "inbox"
    var providerFilter: Provider?
    var searchText: String = ""
    var composeContext: ComposeContext?
    var errorMessage: String?

    init() {
        accounts = []
        messages = []
    }

    var selectedMessage: Message? {
        guard let id = selectedMessageId else { return nil }
        return messages.first { $0.id == id }
    }

    var filteredMessages: [Message] {
        messages
            .filter { $0.folder == selectedFolder }
            .filter { providerFilter == nil || $0.provider == providerFilter }
            .filter { message in
                guard !searchText.isEmpty else { return true }
                let q = searchText.lowercased()
                return message.subject.lowercased().contains(q)
                    || message.senderName.lowercased().contains(q)
                    || message.snippet.lowercased().contains(q)
            }
            .sorted { $0.receivedAt > $1.receivedAt }
    }

    func select(_ message: Message) {
        selectedMessageId = message.id
        markRead(message)
    }

    func markRead(_ message: Message) {
        guard !message.isRead else { return }
        Task { await setRead(message, read: true) }
    }

    func toggleReadStatus(_ message: Message) {
        Task { await setRead(message, read: !message.isRead) }
    }

    /// Optimistic update, rolled back if the provider call fails.
    private func setRead(_ message: Message, read: Bool) async {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let previous = messages[index].isRead
        messages[index].isRead = read
        do {
            let token = try await accessToken(for: message)
            switch message.provider {
            case .gmail: try await GmailAPI.setRead(id: message.providerId, accessToken: token, read: read)
            case .outlook: try await GraphAPI.setRead(id: message.providerId, accessToken: token, read: read)
            }
        } catch {
            messages[index].isRead = previous
            errorMessage = "Couldn't update read status: \(error.localizedDescription)"
        }
    }

    /// Sends a brand-new message from the first connected account.
    /// - ponytail: no sender picker — single default account. Add one if
    ///   multi-account send-from becomes a real need.
    func send(to: String, subject: String, body: String) async throws {
        guard let account = accounts.first else { throw SendError.noAccount }
        let token = try await OAuthManager.shared.validAccessToken(for: account)
        switch account.provider {
        case .gmail: try await GmailAPI.send(to: to, subject: subject, body: body, accessToken: token)
        case .outlook: try await GraphAPI.send(to: to, subject: subject, body: body, accessToken: token)
        }
    }

    /// Sends a threaded reply from the account the original message arrived on.
    func reply(to message: Message, body: String) async throws {
        let token = try await accessToken(for: message)
        switch message.provider {
        case .gmail: try await GmailAPI.reply(to: message, body: body, accessToken: token)
        case .outlook: try await GraphAPI.reply(to: message, body: body, accessToken: token)
        }
    }

    private func accessToken(for message: Message) async throws -> String {
        guard let account = accounts.first(where: { $0.id == message.accountId }) else {
            throw SendError.noAccount
        }
        return try await OAuthManager.shared.validAccessToken(for: account)
    }

    /// Interactive Gmail sign-in + inbox/sent fetch. Merges live mail into `messages`.
    func loadGmail() async {
        do {
            let account = try await OAuthManager.shared.signInWithGoogle()
            try await fetchAndMerge(account)
        } catch {
            print("Gmail load failed: \(error.localizedDescription)")
        }
    }

    /// Interactive Outlook (Microsoft Graph) sign-in + inbox/sent fetch. Merges
    /// live mail into `messages` alongside any Gmail account already loaded.
    func loadOutlook() async {
        do {
            let account = try await OAuthManager.shared.signInWithMicrosoft()
            try await fetchAndMerge(account)
        } catch {
            print("Outlook load failed: \(error.localizedDescription)")
        }
    }

    /// Restores any accounts signed in during a prior launch (silent token
    /// refresh, no browser prompt) and loads their mail. Call once at startup.
    func restoreSession() async {
        for account in await OAuthManager.shared.restoreAccounts() {
            do {
                try await fetchAndMerge(account)
            } catch {
                print("Silent restore failed for \(account.email): \(error.localizedDescription)")
            }
        }
    }

    /// Subscribes to live inserts from the backend so new mail (delivered via
    /// Gmail/Graph webhooks) appears within seconds, without polling. Runs
    /// until cancelled — call from a long-lived `.task {}`.
    func startRealtimeUpdates() async {
        await RealtimeService.subscribeToMessages { [weak self] row in
            Task { @MainActor in self?.handleRealtimeInsert(row) }
        }
    }

    private func handleRealtimeInsert(_ row: RealtimeService.MessageRow) {
        guard let provider = Provider(rawValue: row.provider),
              let accountId = accounts.first(where: { $0.provider == provider && $0.email == row.accountEmail })?.id
        else { return } // mail for an account not connected in this session — ignore
        guard !messages.contains(where: { $0.id == row.id }) else { return }
        messages.append(
            Message(
                id: row.id,
                accountId: accountId,
                provider: provider,
                providerId: row.providerMessageId,
                threadId: row.threadId,
                messageIdHeader: row.messageIdHeader,
                references: row.referencesHeader,
                senderName: row.senderName,
                senderEmail: row.senderEmail,
                subject: row.subject,
                snippet: row.snippet,
                body: row.body,
                receivedAt: row.receivedAt,
                isRead: row.isRead,
                folder: row.folder
            )
        )
    }

    private func fetchAndMerge(_ account: Account) async throws {
        let token = try await OAuthManager.shared.validAccessToken(for: account)
        let fetched: [Message]
        switch account.provider {
        case .gmail:
            async let inboxTask = GmailAPI.fetchInbox(for: account, accessToken: token)
            async let sentTask = GmailAPI.fetchSent(for: account, accessToken: token)
            let (inbox, sent) = try await (inboxTask, sentTask)
            fetched = inbox + sent
        case .outlook:
            async let inboxTask = GraphAPI.fetchInbox(for: account, accessToken: token)
            async let sentTask = GraphAPI.fetchSent(for: account, accessToken: token)
            let (inbox, sent) = try await (inboxTask, sentTask)
            fetched = inbox + sent
        }
        merge(account: account, fetched: fetched)
    }

    private func merge(account: Account, fetched: [Message]) {
        if !accounts.contains(where: { $0.email == account.email && $0.provider == account.provider }) {
            accounts.append(account)
        }
        let existing = Set(messages.map(\.id))
        messages.append(contentsOf: fetched.filter { !existing.contains($0.id) })
    }
}
