import Foundation
import Observation
import SwiftUI

/// A collapsed thread row groups every `Message` sharing a `threadKey`
/// (Gmail threadId / Outlook conversationId), sorted oldest-first so the
/// reading pane can render them chronologically.
struct MessageThread: Identifiable {
    let id: String
    let messages: [Message]

    var latest: Message { messages[messages.count - 1] }
    var count: Int { messages.count }
    var hasUnread: Bool { messages.contains { !$0.isRead } }
}

@Observable
final class InboxViewModel {
    enum ComposeContext: Identifiable {
        case new
        case reply(Message)
        case replyAll(Message)
        case forward(Message)

        var id: String {
            switch self {
            case .new: return "new"
            case .reply(let message): return "reply-\(message.id)"
            case .replyAll(let message): return "replyAll-\(message.id)"
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

    /// Which thread is open in the reading pane.
    var selectedThreadKey: String?
    /// Which message inside the open thread is expanded and "focused" for
    /// keyboard actions (reply/forward/archive/toggle-read).
    var expandedMessageIds: Set<UUID> = []
    var focusedMessageId: UUID?

    var selectedFolder: String = "inbox"
    var providerFilter: Provider?
    var searchText: String = ""
    var composeContext: ComposeContext?
    var errorMessage: String?
    /// Bumped to request the search field take keyboard focus (Cmd+K).
    var searchFocusTrigger = 0

    init() {
        accounts = []
        messages = []
    }

    // MARK: - Thread grouping

    var filteredThreads: [MessageThread] {
        let grouped = Dictionary(grouping: filteredMessages, by: \.threadKey)
        return grouped.map { key, messages in
            MessageThread(id: key, messages: messages.sorted { $0.receivedAt < $1.receivedAt })
        }
        .sorted { $0.latest.receivedAt > $1.latest.receivedAt }
    }

    var selectedThread: MessageThread? {
        guard let key = selectedThreadKey else { return nil }
        return filteredThreads.first { $0.id == key }
    }

    /// The message keyboard shortcuts (reply/forward/archive/toggle-read) act on.
    var focusedMessage: Message? {
        guard let thread = selectedThread else { return nil }
        if let id = focusedMessageId, let match = thread.messages.first(where: { $0.id == id }) {
            return match
        }
        return thread.latest
    }

    private var filteredMessages: [Message] {
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
    }

    /// Opens a thread: focuses + expands its most recent message, marks it read.
    func select(_ thread: MessageThread) {
        selectedThreadKey = thread.id
        focusedMessageId = thread.latest.id
        expandedMessageIds = [thread.latest.id]
        markRead(thread.latest)
    }

    /// Expands/collapses one message within the open thread. Expanding
    /// marks it read and makes it the focus for keyboard actions.
    func toggleExpand(_ message: Message) {
        if expandedMessageIds.contains(message.id) {
            expandedMessageIds.remove(message.id)
        } else {
            expandedMessageIds.insert(message.id)
            focusedMessageId = message.id
            markRead(message)
        }
    }

    /// Moves the open thread selection up/down through the current list —
    /// backs the Up/Down arrow key shortcuts.
    func selectAdjacent(_ delta: Int) {
        let threads = filteredThreads
        guard !threads.isEmpty else { return }
        guard let currentIndex = threads.firstIndex(where: { $0.id == selectedThreadKey }) else {
            select(delta >= 0 ? threads[0] : threads[threads.count - 1])
            return
        }
        let next = max(0, min(threads.count - 1, currentIndex + delta))
        select(threads[next])
    }

    /// Re-opens the current selection — backs the Enter key shortcut.
    func openSelected() {
        guard let thread = selectedThread else { return }
        select(thread)
    }

    func markRead(_ message: Message) {
        guard !message.isRead else { return }
        Task { await setRead(message, read: true) }
    }

    func toggleReadStatus(_ message: Message) {
        Task { await setRead(message, read: !message.isRead) }
    }

    func toggleReadFocused() {
        guard let message = focusedMessage else { return }
        toggleReadStatus(message)
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

    // MARK: - Archive

    func archiveFocused() {
        guard let message = focusedMessage else { return }
        archive(message)
    }

    /// Optimistic: message disappears from the inbox list immediately,
    /// rolled back to "inbox" if the provider call fails.
    func archive(_ message: Message) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let previousFolder = messages[index].folder
        messages[index].folder = "archive"
        if selectedThreadKey == message.threadKey, selectedThread == nil {
            selectedThreadKey = nil
        }
        Task {
            do {
                let token = try await accessToken(for: message)
                switch message.provider {
                case .gmail: try await GmailAPI.setArchived(id: message.providerId, accessToken: token)
                case .outlook: try await GraphAPI.setArchived(id: message.providerId, accessToken: token)
                }
            } catch {
                if let idx = messages.firstIndex(where: { $0.id == message.id }) {
                    messages[idx].folder = previousFolder
                }
                errorMessage = "Couldn't archive: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Compose / send

    /// Sends a brand-new message from the first connected account.
    /// - ponytail: no sender picker — single default account. Add one if
    ///   multi-account send-from becomes a real need.
    func send(to: String, subject: String, body: String, attachments: [OutgoingAttachment] = []) async throws {
        guard let account = accounts.first else { throw SendError.noAccount }
        let token = try await OAuthManager.shared.validAccessToken(for: account)
        switch account.provider {
        case .gmail: try await GmailAPI.send(to: to, subject: subject, body: body, attachments: attachments, accessToken: token)
        case .outlook: try await GraphAPI.send(to: to, subject: subject, body: body, attachments: attachments, accessToken: token)
        }
    }

    /// Sends a threaded reply-to-sender from the account the original message arrived on.
    func reply(to message: Message, body: String, attachments: [OutgoingAttachment] = []) async throws {
        let token = try await accessToken(for: message)
        switch message.provider {
        case .gmail: try await GmailAPI.reply(to: message, body: body, attachments: attachments, accessToken: token)
        case .outlook: try await GraphAPI.reply(to: message, body: body, attachments: attachments, accessToken: token)
        }
    }

    /// Sends a threaded reply to the sender plus every original To/Cc recipient.
    func replyAll(to message: Message, body: String, attachments: [OutgoingAttachment] = []) async throws {
        guard let account = accounts.first(where: { $0.id == message.accountId }) else { throw SendError.noAccount }
        let token = try await OAuthManager.shared.validAccessToken(for: account)
        switch message.provider {
        case .gmail:
            try await GmailAPI.replyAll(to: message, selfEmail: account.email, body: body, attachments: attachments, accessToken: token)
        case .outlook:
            try await GraphAPI.replyAll(to: message, body: body, attachments: attachments, accessToken: token)
        }
    }

    private func accessToken(for message: Message) async throws -> String {
        guard let account = accounts.first(where: { $0.id == message.accountId }) else {
            throw SendError.noAccount
        }
        return try await OAuthManager.shared.validAccessToken(for: account)
    }

    // MARK: - Attachments (received messages)

    /// Fetches attachment bytes on demand — never pulled in bulk with the list.
    func attachmentData(_ attachment: Attachment, on message: Message) async throws -> Data {
        let token = try await accessToken(for: message)
        switch message.provider {
        case .gmail:
            return try await GmailAPI.fetchAttachmentData(
                messageId: message.providerId, attachmentId: attachment.id, accessToken: token)
        case .outlook:
            return try await GraphAPI.fetchAttachmentData(
                messageId: message.providerId, attachmentId: attachment.id, accessToken: token)
        }
    }

    // MARK: - Sync

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
