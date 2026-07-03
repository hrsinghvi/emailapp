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
    var categories: [MailCategory]
    var messages: [Message]

    var selectedMessageId: UUID?
    var selectedFolder: String = "inbox"
    var providerFilter: Provider?
    var searchText: String = ""
    var composeContext: ComposeContext?
    var errorMessage: String?

    init() {
        accounts = []
        categories = []
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

    var groupedByCategory: [(category: MailCategory?, messages: [Message])] {
        let msgs = filteredMessages
        var groups: [(category: MailCategory?, messages: [Message])] = []
        for category in categories {
            let inCategory = msgs.filter { $0.categoryId == category.id }
            if !inCategory.isEmpty {
                groups.append((category, inCategory))
            }
        }
        let uncategorized = msgs.filter { $0.categoryId == nil }
        if !uncategorized.isEmpty {
            groups.append((nil, uncategorized))
        }
        return groups
    }

    func unreadCount(for categoryId: UUID?) -> Int {
        filteredMessages.filter { $0.categoryId == categoryId && !$0.isRead }.count
    }

    func count(for categoryId: UUID?) -> Int {
        filteredMessages.filter { $0.categoryId == categoryId }.count
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
            let token = try await OAuthManager.shared.validAccessToken(for: account)
            async let inboxTask = GmailAPI.fetchInbox(for: account, accessToken: token)
            async let sentTask = GmailAPI.fetchSent(for: account, accessToken: token)
            let (inbox, sent) = try await (inboxTask, sentTask)
            merge(account: account, fetched: inbox + sent)
        } catch {
            print("Gmail load failed: \(error.localizedDescription)")
        }
    }

    /// Interactive Outlook (Microsoft Graph) sign-in + inbox/sent fetch. Merges
    /// live mail into `messages` alongside any Gmail account already loaded.
    func loadOutlook() async {
        do {
            let account = try await OAuthManager.shared.signInWithMicrosoft()
            let token = try await OAuthManager.shared.validAccessToken(for: account)
            async let inboxTask = GraphAPI.fetchInbox(for: account, accessToken: token)
            async let sentTask = GraphAPI.fetchSent(for: account, accessToken: token)
            let (inbox, sent) = try await (inboxTask, sentTask)
            merge(account: account, fetched: inbox + sent)
        } catch {
            print("Outlook load failed: \(error.localizedDescription)")
        }
    }

    private func merge(account: Account, fetched: [Message]) {
        if !accounts.contains(where: { $0.email == account.email && $0.provider == account.provider }) {
            accounts.append(account)
        }
        let existing = Set(messages.map(\.id))
        messages.append(contentsOf: fetched.filter { !existing.contains($0.id) })
    }
}
