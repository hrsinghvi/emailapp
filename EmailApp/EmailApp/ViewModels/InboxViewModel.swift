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
        /// Reopens an existing draft, or a send that was just undone —
        /// both are "resume this exact compose session".
        case draft(Draft)

        var id: String {
            switch self {
            case .new: return "new"
            case .reply(let message): return "reply-\(message.id)"
            case .replyAll(let message): return "replyAll-\(message.id)"
            case .forward(let message): return "forward-\(message.id)"
            case .draft(let draft): return "draft-\(draft.id)"
            }
        }
    }

    enum SendError: LocalizedError {
        case noAccount
        var errorDescription: String? { "No connected account to send from." }
    }

    /// A send in its 8-second undoable window — nothing has been
    /// transmitted yet, the email exists only locally.
    struct PendingSend: Identifiable {
        let id = UUID()
        let draftId: UUID?
        let origin: DraftOrigin
        let to: String
        let cc: String
        let bcc: String
        let subject: String
        let bodyHTML: String
        let attachments: [OutgoingAttachment]
        let scheduledAt: Date
        var task: Task<Void, Never>?

        var asDraft: Draft {
            Draft(
                id: draftId ?? UUID(), accountEmail: nil, to: to, cc: cc, bcc: bcc, subject: subject,
                bodyHTML: bodyHTML,
                attachments: attachments.map { DraftAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) },
                origin: origin, lastModified: Date()
            )
        }
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

    var drafts: [Draft] = []
    var pendingSends: [PendingSend] = []

    init() {
        accounts = []
        messages = []
        drafts = DraftStore.loadAll()
    }

    // MARK: - Drafts

    func saveDraft(_ draft: Draft) {
        DraftStore.save(draft)
        if let index = drafts.firstIndex(where: { $0.id == draft.id }) {
            drafts[index] = draft
        } else {
            drafts.insert(draft, at: 0)
        }
    }

    func deleteDraft(id: UUID) {
        DraftStore.delete(id: id)
        drafts.removeAll { $0.id == id }
    }

    // MARK: - Undo Send

    /// Queues a send for an 8-second undoable window. Nothing is
    /// transmitted until the window elapses uninterrupted — the email
    /// exists only locally until then.
    func queueSend(
        draftId: UUID?, origin: DraftOrigin, to: String, cc: String, bcc: String,
        subject: String, bodyHTML: String, attachments: [OutgoingAttachment]
    ) {
        // A pending send is its own state, not simultaneously a draft — drop
        // it from the drafts list now. The file itself stays on disk until
        // the real send succeeds, so a crash mid-countdown doesn't lose it.
        if let draftId { drafts.removeAll { $0.id == draftId } }

        var pending = PendingSend(
            draftId: draftId, origin: origin, to: to, cc: cc, bcc: bcc, subject: subject,
            bodyHTML: bodyHTML, attachments: attachments, scheduledAt: Date().addingTimeInterval(8)
        )
        let sendId = pending.id
        pending.task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            await self?.performActualSend(sendId)
        }
        pendingSends.append(pending)
    }

    /// Cancels a pending send and reopens Compose with everything restored
    /// exactly as it was.
    func undoSend(_ id: UUID) {
        guard let index = pendingSends.firstIndex(where: { $0.id == id }) else { return }
        let pending = pendingSends[index]
        pending.task?.cancel()
        pendingSends.remove(at: index)
        composeContext = .draft(pending.asDraft)
    }

    private func performActualSend(_ id: UUID) async {
        guard let index = pendingSends.firstIndex(where: { $0.id == id }) else { return }
        let pending = pendingSends[index]
        do {
            try await dispatchSend(pending)
            pendingSends.removeAll { $0.id == id }
            if let draftId = pending.draftId { deleteDraft(id: draftId) }
        } catch {
            pendingSends.removeAll { $0.id == id }
            // Falls back to a resumable draft rather than silently dropping
            // the content the user wrote.
            saveDraft(pending.asDraft)
            errorMessage = "Send failed, saved as a draft: \(error.localizedDescription)"
        }
    }

    private func dispatchSend(_ pending: PendingSend) async throws {
        func plainSend() async throws {
            try await send(
                to: pending.to, cc: pending.cc, bcc: pending.bcc, subject: pending.subject,
                bodyHTML: pending.bodyHTML, attachments: pending.attachments
            )
        }
        switch pending.origin {
        case .new, .forward:
            try await plainSend()
        case .reply(let messageId):
            guard let message = messages.first(where: { $0.id == messageId }) else { try await plainSend(); return }
            try await reply(to: message, cc: pending.cc, bcc: pending.bcc, bodyHTML: pending.bodyHTML, attachments: pending.attachments)
        case .replyAll(let messageId):
            guard let message = messages.first(where: { $0.id == messageId }) else { try await plainSend(); return }
            try await replyAll(to: message, cc: pending.cc, bcc: pending.bcc, bodyHTML: pending.bodyHTML, attachments: pending.attachments)
        }
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

    /// Every message in a thread — swiping/archiving a collapsed row acts
    /// on the whole conversation, not just whichever message happens to be
    /// latest.
    func archiveThread(_ thread: MessageThread) {
        for message in thread.messages { archive(message) }
    }

    func markThreadUnread(_ thread: MessageThread) {
        for message in thread.messages { markUnread(message) }
    }

    private func markUnread(_ message: Message) {
        guard message.isRead else { return }
        Task { await setRead(message, read: false) }
    }

    // MARK: - Delete (soft — Trash / Deleted Items, never permanent)

    /// Optimistic: message disappears from the current view immediately,
    /// rolled back to its prior folder if the provider call fails.
    func delete(_ message: Message) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let previousFolder = messages[index].folder
        messages[index].folder = "trash"
        Task {
            do {
                let token = try await accessToken(for: message)
                switch message.provider {
                case .gmail: try await GmailAPI.trash(id: message.providerId, accessToken: token)
                case .outlook: try await GraphAPI.delete(id: message.providerId, accessToken: token)
                }
            } catch {
                if let idx = messages.firstIndex(where: { $0.id == message.id }) {
                    messages[idx].folder = previousFolder
                }
                errorMessage = "Couldn't delete: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Bulk selection

    var selectedThreadKeys: Set<String> = []
    private var lastClickedThreadKey: String?

    private var selectedMessages: [Message] {
        filteredThreads.filter { selectedThreadKeys.contains($0.id) }.flatMap(\.messages)
    }

    /// Plain click opens the thread as before; Cmd-click toggles just this
    /// row; Shift-click selects the continuous range from the last click.
    func handleRowClick(_ thread: MessageThread, shift: Bool, command: Bool) {
        if command {
            if selectedThreadKeys.contains(thread.id) {
                selectedThreadKeys.remove(thread.id)
            } else {
                selectedThreadKeys.insert(thread.id)
            }
            lastClickedThreadKey = thread.id
        } else if shift, let anchor = lastClickedThreadKey {
            let ids = filteredThreads.map(\.id)
            if let a = ids.firstIndex(of: anchor), let b = ids.firstIndex(of: thread.id) {
                selectedThreadKeys.formUnion(ids[(a <= b ? a...b : b...a)])
            }
        } else {
            selectedThreadKeys.removeAll()
            select(thread)
        }
    }

    func toggleSelection(_ thread: MessageThread) {
        if selectedThreadKeys.contains(thread.id) {
            selectedThreadKeys.remove(thread.id)
        } else {
            selectedThreadKeys.insert(thread.id)
        }
        lastClickedThreadKey = thread.id
    }

    func toggleSelectAll() {
        let all = Set(filteredThreads.map(\.id))
        selectedThreadKeys = selectedThreadKeys == all ? [] : all
    }

    func bulkArchive() {
        for message in selectedMessages { archive(message) }
        selectedThreadKeys.removeAll()
    }

    func bulkDelete() {
        for message in selectedMessages { delete(message) }
        selectedThreadKeys.removeAll()
    }

    func bulkMarkRead(_ read: Bool) {
        let targets = selectedMessages
        Task { for message in targets { await setRead(message, read: read) } }
        selectedThreadKeys.removeAll()
    }

    // MARK: - Compose / send

    /// Sends a brand-new message from the first connected account. Body is
    /// always HTML now that compose is rich text.
    /// - ponytail: no sender picker — single default account. Add one if
    ///   multi-account send-from becomes a real need.
    func send(to: String, cc: String = "", bcc: String = "", subject: String, bodyHTML: String, attachments: [OutgoingAttachment] = []) async throws {
        guard let account = accounts.first else { throw SendError.noAccount }
        let token = try await OAuthManager.shared.validAccessToken(for: account)
        switch account.provider {
        case .gmail:
            try await GmailAPI.send(to: to, cc: cc, bcc: bcc, subject: subject, body: bodyHTML, isHTML: true, attachments: attachments, accessToken: token)
        case .outlook:
            try await GraphAPI.send(to: to, cc: cc, bcc: bcc, subject: subject, body: bodyHTML, isHTML: true, attachments: attachments, accessToken: token)
        }
    }

    /// Sends a threaded reply-to-sender from the account the original message arrived on.
    func reply(to message: Message, cc: String = "", bcc: String = "", bodyHTML: String, attachments: [OutgoingAttachment] = []) async throws {
        let token = try await accessToken(for: message)
        switch message.provider {
        case .gmail:
            try await GmailAPI.reply(to: message, cc: cc, bcc: bcc, body: bodyHTML, isHTML: true, attachments: attachments, accessToken: token)
        case .outlook:
            try await GraphAPI.reply(to: message, cc: cc, bcc: bcc, body: bodyHTML, attachments: attachments, accessToken: token)
        }
    }

    /// Sends a threaded reply to the sender plus every original To/Cc recipient.
    func replyAll(to message: Message, cc: String = "", bcc: String = "", bodyHTML: String, attachments: [OutgoingAttachment] = []) async throws {
        guard let account = accounts.first(where: { $0.id == message.accountId }) else { throw SendError.noAccount }
        let token = try await OAuthManager.shared.validAccessToken(for: account)
        switch message.provider {
        case .gmail:
            try await GmailAPI.replyAll(to: message, selfEmail: account.email, cc: cc, bcc: bcc, body: bodyHTML, isHTML: true, attachments: attachments, accessToken: token)
        case .outlook:
            try await GraphAPI.replyAll(to: message, cc: cc, bcc: bcc, body: bodyHTML, attachments: attachments, accessToken: token)
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
