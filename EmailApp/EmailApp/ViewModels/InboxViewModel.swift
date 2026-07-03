import Observation
import SwiftUI

@Observable
final class InboxViewModel {
    var accounts: [Account]
    var categories: [MailCategory]
    var messages: [Message]

    var selectedMessageId: UUID?
    var selectedFolder: String = "inbox"
    var providerFilter: Provider?
    var searchText: String = ""

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
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].isRead = true
    }

    func toggleArchive(_ message: Message) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].isArchived.toggle()
    }

    /// Interactive Gmail sign-in + inbox fetch. Merges live mail into `messages`.
    func loadGmail() async {
        do {
            let account = try await OAuthManager.shared.signInWithGoogle()
            let token = try await OAuthManager.shared.validAccessToken(for: account)
            let fetched = try await GmailAPI.fetchInbox(for: account, accessToken: token)
            merge(account: account, fetched: fetched)
        } catch {
            print("Gmail load failed: \(error.localizedDescription)")
        }
    }

    /// Interactive Outlook (Microsoft Graph) sign-in + inbox fetch. Merges
    /// live mail into `messages` alongside any Gmail account already loaded.
    func loadOutlook() async {
        do {
            let account = try await OAuthManager.shared.signInWithMicrosoft()
            let token = try await OAuthManager.shared.validAccessToken(for: account)
            let fetched = try await GraphAPI.fetchInbox(for: account, accessToken: token)
            merge(account: account, fetched: fetched)
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
