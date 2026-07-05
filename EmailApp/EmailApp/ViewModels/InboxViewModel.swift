import Foundation
import Observation
import SwiftUI
import os

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

        var asQueuedSend: QueuedSend {
            QueuedSend(
                origin: origin, to: to, cc: cc, bcc: bcc, subject: subject, bodyHTML: bodyHTML,
                attachments: attachments.map { DraftAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) }
            )
        }
    }

    var accounts: [Account]
    /// Recomputing `filteredThreads` is O(n) over the whole mailbox
    /// (filter + group + sort, plus `Message.category`'s heuristic re-run
    /// per message) — cheap at dozens of messages, but with 1000+ synced
    /// it's expensive enough that recomputing it on every SwiftUI render
    /// (which a plain computed property does) is what caused the multi-
    /// second jank switching folders. `didSet` here recomputes once per
    /// actual mailbox change instead of once per render.
    var messages: [Message] { didSet { recomputeFilteredThreads() } }

    /// Which thread is open in the reading pane.
    var selectedThreadKey: String?
    /// Which message inside the open thread is expanded and "focused" for
    /// keyboard actions (reply/forward/archive/toggle-read).
    var expandedMessageIds: Set<UUID> = []
    var focusedMessageId: UUID?

    var selectedFolder: String = "inbox" { didSet { listPageIndex = 0; recomputeFilteredThreads() } }
    var providerFilter: Provider? { didSet { listPageIndex = 0; recomputeFilteredThreads() } }
    /// Gmail-style category tab — only meaningful (and only shown) for the
    /// inbox; other folders show every category mixed together.
    var categoryFilter: MessageCategory = .primary { didSet { listPageIndex = 0; recomputeFilteredThreads() } }
    var searchText: String = "" { didSet { listPageIndex = 0; recomputeFilteredThreads() } }
    var composeContext: ComposeContext?
    /// Settings is an in-window dimmed modal (Claude-desktop style), not a
    /// separate NSWindow — this is the only state it needs.
    var isSettingsPresented = false
    var errorMessage: String?
    /// Bumped to request the search field take keyboard focus (Cmd+K).
    var searchFocusTrigger = 0

    /// Gmail-style "1-50 of N" pagination for the message list.
    var listPageIndex: Int = 0
    let listPageSize = 50

    var drafts: [Draft] = []
    var pendingSends: [PendingSend] = []
    var offlineQueue: [QueuedActionEnvelope] = []
    /// Write actions an MCP tool call queued because Settings > MCP >
    /// "require confirmation" is on — surfaced for approve/reject there.
    var pendingMCPActions: [PendingAction] = []

    /// Unread count across every connected account's inbox, regardless of
    /// whatever provider filter/search/folder is currently on screen —
    /// this is what the Dock badge always reflects.
    var totalUnreadCount: Int {
        messages.filter { $0.folder == "inbox" && !$0.isRead }.count
    }

    /// Every sidebar badge counts THREADS, matching exactly what the list
    /// toolbar's own "1-50 of N" reports for that same folder/category —
    /// they used to disagree (badges counted raw messages, sometimes only
    /// unread ones; the toolbar counts threads after grouping by
    /// threadKey), which is what made the two numbers never match.
    private func threadCount(matching predicate: (Message) -> Bool) -> Int {
        Set(messages.filter(predicate).map(\.threadKey)).count
    }

    /// Backs the sidebar's per-category ("Views") badge counts.
    func threadCount(for category: MessageCategory) -> Int {
        threadCount { $0.folder == "inbox" && $0.category == category }
    }

    /// Backs the sidebar's Starred/Sent/Important/Archive/Trash/All Mail
    /// badges.
    func threadCount(forFolder folder: String) -> Int {
        switch folder {
        case "all": return threadCount { $0.folder != "trash" }
        case "starred": return threadCount { $0.isStarred }
        case "important": return threadCount { $0.isImportant }
        default: return threadCount { $0.folder == folder }
        }
    }

    init() {
        accounts = []
        messages = []
        drafts = DraftStore.loadAll()
        offlineQueue = OfflineActionQueueStore.load()
        NetworkMonitor.shared.onBecomeOnline = { [weak self] in
            Task { await self?.replayOfflineQueue() }
        }
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

        let delay = AppSettings.shared.undoSendDelay
        var pending = PendingSend(
            draftId: draftId, origin: origin, to: to, cc: cc, bcc: bcc, subject: subject,
            bodyHTML: bodyHTML, attachments: attachments, scheduledAt: Date().addingTimeInterval(delay)
        )
        let sendId = pending.id
        pending.task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
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

        guard NetworkMonitor.shared.isOnline else {
            pendingSends.removeAll { $0.id == id }
            enqueueOffline(.send(pending.asQueuedSend))
            if let draftId = pending.draftId { deleteDraft(id: draftId) }
            return
        }
        do {
            try await dispatchSend(
                origin: pending.origin, to: pending.to, cc: pending.cc, bcc: pending.bcc,
                subject: pending.subject, bodyHTML: pending.bodyHTML, attachments: pending.attachments
            )
            pendingSends.removeAll { $0.id == id }
            if let draftId = pending.draftId { deleteDraft(id: draftId) }
            let recipients = (pending.to + "," + pending.cc + "," + pending.bcc).split(separator: ",").map(String.init)
            Task { await ContactsIndexService.recordUsage(emails: recipients) }
        } catch {
            pendingSends.removeAll { $0.id == id }
            guard NetworkMonitor.shared.isOnline else {
                enqueueOffline(.send(pending.asQueuedSend))
                if let draftId = pending.draftId { deleteDraft(id: draftId) }
                return
            }
            // Falls back to a resumable draft rather than silently dropping
            // the content the user wrote.
            saveDraft(pending.asDraft)
            AppLog.send.error("send failed for pending \(id): \(error.localizedDescription)")
            errorMessage = "Send failed, saved as a draft: \(error.localizedDescription)"
        }
    }

    private func dispatchSend(
        origin: DraftOrigin, to: String, cc: String, bcc: String, subject: String, bodyHTML: String,
        attachments: [OutgoingAttachment]
    ) async throws {
        func plainSend() async throws {
            try await send(to: to, cc: cc, bcc: bcc, subject: subject, bodyHTML: bodyHTML, attachments: attachments)
        }
        switch origin {
        case .new, .forward:
            try await plainSend()
        case .reply(let messageId):
            guard let message = messages.first(where: { $0.id == messageId }) else { try await plainSend(); return }
            try await reply(to: message, cc: cc, bcc: bcc, bodyHTML: bodyHTML, attachments: attachments)
        case .replyAll(let messageId):
            guard let message = messages.first(where: { $0.id == messageId }) else { try await plainSend(); return }
            try await replyAll(to: message, cc: cc, bcc: bcc, bodyHTML: bodyHTML, attachments: attachments)
        }
    }

    // MARK: - Offline queue

    private func enqueueOffline(_ action: OfflineAction) {
        offlineQueue.append(QueuedActionEnvelope(id: UUID(), action: action, queuedAt: Date()))
        OfflineActionQueueStore.save(offlineQueue)
    }

    /// Replays the queue in the exact order actions were originally
    /// performed, removing each only after it actually succeeds. Stops
    /// (rather than dropping the rest) if connectivity drops again
    /// mid-replay — the remainder waits for the next `onBecomeOnline` fire.
    func replayOfflineQueue() async {
        guard NetworkMonitor.shared.isOnline else { return }
        for envelope in offlineQueue {
            guard NetworkMonitor.shared.isOnline else { return }
            do {
                try await performOfflineAction(envelope.action)
                offlineQueue.removeAll { $0.id == envelope.id }
                OfflineActionQueueStore.save(offlineQueue)
            } catch {
                if NetworkMonitor.shared.isOnline {
                    // A genuine failure, not just still-offline — surface it
                    // and drop it; retrying a permanently-broken action
                    // forever isn't useful.
                    offlineQueue.removeAll { $0.id == envelope.id }
                    OfflineActionQueueStore.save(offlineQueue)
                    AppLog.offline.error("queued action \(envelope.id) failed: \(error.localizedDescription)")
                    errorMessage = "A queued action failed: \(error.localizedDescription)"
                } else {
                    return
                }
            }
        }
    }

    private func performOfflineAction(_ action: OfflineAction) async throws {
        switch action {
        case .archive(let messageId):
            guard let message = messages.first(where: { $0.id == messageId }) else { return }
            let token = try await accessToken(for: message)
            switch message.provider {
            case .gmail: try await GmailAPI.setArchived(id: message.providerId, accessToken: token)
            case .outlook: try await GraphAPI.setArchived(id: message.providerId, accessToken: token)
            }
        case .unarchive(let messageId):
            guard let message = messages.first(where: { $0.id == messageId }) else { return }
            let token = try await accessToken(for: message)
            switch message.provider {
            case .gmail: try await GmailAPI.unarchive(id: message.providerId, accessToken: token)
            case .outlook: try await GraphAPI.moveToInbox(id: message.providerId, accessToken: token)
            }
        case .delete(let messageId):
            guard let message = messages.first(where: { $0.id == messageId }) else { return }
            let token = try await accessToken(for: message)
            switch message.provider {
            case .gmail: try await GmailAPI.trash(id: message.providerId, accessToken: token)
            case .outlook: try await GraphAPI.delete(id: message.providerId, accessToken: token)
            }
        case .restore(let messageId):
            guard let message = messages.first(where: { $0.id == messageId }) else { return }
            let token = try await accessToken(for: message)
            switch message.provider {
            case .gmail: try await GmailAPI.untrash(id: message.providerId, accessToken: token)
            case .outlook: try await GraphAPI.moveToInbox(id: message.providerId, accessToken: token)
            }
        case .markRead(let messageId, let read):
            guard let message = messages.first(where: { $0.id == messageId }) else { return }
            let token = try await accessToken(for: message)
            switch message.provider {
            case .gmail: try await GmailAPI.setRead(id: message.providerId, accessToken: token, read: read)
            case .outlook: try await GraphAPI.setRead(id: message.providerId, accessToken: token, read: read)
            }
        case .send(let payload):
            try await dispatchSend(
                origin: payload.origin, to: payload.to, cc: payload.cc, bcc: payload.bcc,
                subject: payload.subject, bodyHTML: payload.bodyHTML,
                attachments: payload.attachments.compactMap(\.outgoing)
            )
        }
    }

    // MARK: - Thread grouping

    /// Cached — see the doc comment on `messages` for why this can't be a
    /// plain computed property at mailbox sizes past a few hundred.
    private(set) var filteredThreads: [MessageThread] = []

    private func recomputeFilteredThreads() {
        let grouped = Dictionary(grouping: filteredMessages, by: \.threadKey)
        filteredThreads = grouped.map { key, messages in
            MessageThread(id: key, messages: messages.sorted { $0.receivedAt < $1.receivedAt })
        }
        .sorted { $0.latest.receivedAt > $1.latest.receivedAt }
    }

    /// "1-50 of N" — clamped so switching to a shorter filtered set never
    /// leaves the page pointed past the end.
    var listPageRange: (start: Int, end: Int, total: Int) {
        let total = filteredThreads.count
        guard total > 0 else { return (0, 0, 0) }
        let maxPage = (total - 1) / listPageSize
        let page = min(listPageIndex, maxPage)
        let start = page * listPageSize
        let end = min(start + listPageSize, total)
        return (start, end, total)
    }

    var pagedThreads: [MessageThread] {
        let range = listPageRange
        guard range.start < range.end else { return [] }
        return Array(filteredThreads[range.start..<range.end])
    }

    func goToNextPage() {
        let range = listPageRange
        guard range.end < range.total else { return }
        listPageIndex += 1
    }

    func goToPreviousPage() {
        guard listPageIndex > 0 else { return }
        listPageIndex -= 1
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
            .filter { message in
                switch selectedFolder {
                case "all": return message.folder != "trash"
                case "starred": return message.isStarred
                case "important": return message.isImportant
                default: return message.folder == selectedFolder
                }
            }
            .filter { providerFilter == nil || $0.provider == providerFilter }
            .filter { selectedFolder != "inbox" || $0.category == categoryFilter }
            .filter { message in
                if searchHasAttachment, message.attachments.isEmpty { return false }
                if searchFromMe, !accounts.contains(where: { $0.email.caseInsensitiveCompare(message.senderEmail) == .orderedSame }) { return false }
                if searchNewerThan7Days, message.receivedAt < sevenDaysAgo { return false }
                guard !searchFreeText.isEmpty else { return true }
                let q = searchFreeText.lowercased()
                return message.subject.lowercased().contains(q)
                    || message.senderName.lowercased().contains(q)
                    || message.snippet.lowercased().contains(q)
            }
    }

    /// Gmail-style search operators recognized inside `searchText` — set by
    /// the search dropdown's quick-filter chips, but typeable directly too.
    private var searchHasAttachment: Bool { searchText.localizedCaseInsensitiveContains("has:attachment") }
    private var searchFromMe: Bool { searchText.localizedCaseInsensitiveContains("from:me") }
    private var searchNewerThan7Days: Bool { searchText.localizedCaseInsensitiveContains("newer_than:7d") }
    private var sevenDaysAgo: Date { Date().addingTimeInterval(-7 * 24 * 60 * 60) }

    /// `searchText` with every recognized operator token stripped out,
    /// leaving whatever's left for the plain substring match.
    private var searchFreeText: String {
        searchText
            .replacingOccurrences(of: "has:attachment", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "from:me", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "newer_than:7d", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Opens a thread: focuses + expands its most recent message, marks it read.
    func select(_ thread: MessageThread) {
        selectedThreadKey = thread.id
        focusedMessageId = thread.latest.id
        expandedMessageIds = [thread.latest.id]
        markRead(thread.latest)
        prewarmAdjacent(to: thread)
    }

    /// Prewarms the HTML render for whichever threads the user is likely to
    /// open next (the ones right next to the one they just opened), so
    /// arrow-key/click navigation through the inbox feels instant instead
    /// of starting each message's load at click-time.
    private func prewarmAdjacent(to thread: MessageThread) {
        let threads = filteredThreads
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else { return }
        for neighborIndex in [index - 1, index + 1] where threads.indices.contains(neighborIndex) {
            prewarmHTML(for: threads[neighborIndex].latest)
        }
    }

    private func prewarmHTML(for message: Message) {
        guard let html = message.htmlBody else { return }
        HTMLPrewarmCache.shared.prewarm(messageId: message.id, html: html)
    }

    /// Expands/collapses one message within the open thread. Expanding
    /// marks it read and makes it the focus for keyboard actions.
    func toggleExpand(_ message: Message) {
        let isExpanding = !expandedMessageIds.contains(message.id)
        withAnimation(.easeOut(duration: 0.22)) {
            if isExpanding {
                expandedMessageIds.insert(message.id)
                focusedMessageId = message.id
            } else {
                expandedMessageIds.remove(message.id)
            }
        }
        if isExpanding { markRead(message) }
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

    /// Local-only — see the doc comment on `Message.isStarred`.
    func toggleStarred(_ message: Message) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].isStarred.toggle()
        MessageCacheStore.save(messages)
    }

    /// Local-only — see the doc comment on `Message.isImportant`.
    func toggleImportant(_ message: Message) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].isImportant.toggle()
        MessageCacheStore.save(messages)
    }

    /// Optimistic update. Offline: queued and kept as-is (offline actions
    /// never fail immediately). Online but the call still fails: a genuine
    /// error, rolled back and surfaced.
    private func setRead(_ message: Message, read: Bool) async {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let previous = messages[index].isRead
        messages[index].isRead = read
        MessageCacheStore.save(messages)

        guard NetworkMonitor.shared.isOnline else {
            enqueueOffline(.markRead(messageId: message.id, read: read))
            return
        }
        do {
            let token = try await accessToken(for: message)
            switch message.provider {
            case .gmail: try await GmailAPI.setRead(id: message.providerId, accessToken: token, read: read)
            case .outlook: try await GraphAPI.setRead(id: message.providerId, accessToken: token, read: read)
            }
        } catch {
            guard NetworkMonitor.shared.isOnline else {
                enqueueOffline(.markRead(messageId: message.id, read: read))
                return
            }
            messages[index].isRead = previous
            MessageCacheStore.save(messages)
            AppLog.sync.error("setRead failed for \(message.id): \(error.localizedDescription)")
            errorMessage = "Couldn't update read status: \(error.localizedDescription)"
        }
    }

    // MARK: - Archive

    func archiveFocused() {
        guard let message = focusedMessage else { return }
        archive(message)
    }

    /// Optimistic: message disappears from the inbox list immediately.
    /// Offline: queued, kept archived locally. Online but the call still
    /// fails: a genuine error, rolled back and surfaced.
    func archive(_ message: Message) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let previousFolder = messages[index].folder
        withAnimation(.easeOut(duration: 0.2)) {
            messages[index].folder = "archive"
        }
        MessageCacheStore.save(messages)
        if selectedThreadKey == message.threadKey, selectedThread == nil {
            selectedThreadKey = nil
        }

        guard NetworkMonitor.shared.isOnline else {
            enqueueOffline(.archive(messageId: message.id))
            return
        }
        Task {
            do {
                let token = try await accessToken(for: message)
                switch message.provider {
                case .gmail: try await GmailAPI.setArchived(id: message.providerId, accessToken: token)
                case .outlook: try await GraphAPI.setArchived(id: message.providerId, accessToken: token)
                }
            } catch {
                guard NetworkMonitor.shared.isOnline else {
                    enqueueOffline(.archive(messageId: message.id))
                    return
                }
                if let idx = messages.firstIndex(where: { $0.id == message.id }) {
                    messages[idx].folder = previousFolder
                    MessageCacheStore.save(messages)
                }
                AppLog.sync.error("archive failed for \(message.id): \(error.localizedDescription)")
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

    /// Moves an archived message back to Inbox — the inverse of `archive`.
    func unarchive(_ message: Message) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let previousFolder = messages[index].folder
        withAnimation(.easeOut(duration: 0.2)) {
            messages[index].folder = "inbox"
        }
        MessageCacheStore.save(messages)
        if selectedThreadKey == message.threadKey, selectedThread == nil {
            selectedThreadKey = nil
        }

        guard NetworkMonitor.shared.isOnline else {
            enqueueOffline(.unarchive(messageId: message.id))
            return
        }
        Task {
            do {
                let token = try await accessToken(for: message)
                switch message.provider {
                case .gmail: try await GmailAPI.unarchive(id: message.providerId, accessToken: token)
                case .outlook: try await GraphAPI.moveToInbox(id: message.providerId, accessToken: token)
                }
            } catch {
                guard NetworkMonitor.shared.isOnline else {
                    enqueueOffline(.unarchive(messageId: message.id))
                    return
                }
                if let idx = messages.firstIndex(where: { $0.id == message.id }) {
                    messages[idx].folder = previousFolder
                    MessageCacheStore.save(messages)
                }
                AppLog.sync.error("unarchive failed for \(message.id): \(error.localizedDescription)")
                errorMessage = "Couldn't unarchive: \(error.localizedDescription)"
            }
        }
    }

    func unarchiveThread(_ thread: MessageThread) {
        for message in thread.messages { unarchive(message) }
    }

    func markThreadUnread(_ thread: MessageThread) {
        for message in thread.messages { markUnread(message) }
    }

    /// Toggles the whole thread to the opposite of its latest message's
    /// current read state — mirrors the per-message Mark Read/Unread pill
    /// that used to live under each message before it moved into the
    /// thread-level detail toolbar.
    func toggleThreadReadStatus(_ thread: MessageThread) {
        let targetRead = !thread.latest.isRead
        for message in thread.messages { Task { await setRead(message, read: targetRead) } }
    }

    /// Every message in a thread — the detail toolbar's trash icon acts on
    /// the whole open conversation, matching `archiveThread`.
    func deleteThread(_ thread: MessageThread) {
        for message in thread.messages { delete(message) }
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
        withAnimation(.easeOut(duration: 0.2)) {
            messages[index].folder = "trash"
        }
        MessageCacheStore.save(messages)

        guard NetworkMonitor.shared.isOnline else {
            enqueueOffline(.delete(messageId: message.id))
            return
        }
        Task {
            do {
                let token = try await accessToken(for: message)
                switch message.provider {
                case .gmail: try await GmailAPI.trash(id: message.providerId, accessToken: token)
                case .outlook: try await GraphAPI.delete(id: message.providerId, accessToken: token)
                }
            } catch {
                guard NetworkMonitor.shared.isOnline else {
                    enqueueOffline(.delete(messageId: message.id))
                    return
                }
                if let idx = messages.firstIndex(where: { $0.id == message.id }) {
                    messages[idx].folder = previousFolder
                    MessageCacheStore.save(messages)
                }
                AppLog.sync.error("delete failed for \(message.id): \(error.localizedDescription)")
                errorMessage = "Couldn't delete: \(error.localizedDescription)"
            }
        }
    }

    /// Moves a trashed message back to Inbox — the inverse of `delete`.
    func restore(_ message: Message) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let previousFolder = messages[index].folder
        withAnimation(.easeOut(duration: 0.2)) {
            messages[index].folder = "inbox"
        }
        MessageCacheStore.save(messages)
        if selectedThreadKey == message.threadKey, selectedThread == nil {
            selectedThreadKey = nil
        }

        guard NetworkMonitor.shared.isOnline else {
            enqueueOffline(.restore(messageId: message.id))
            return
        }
        Task {
            do {
                let token = try await accessToken(for: message)
                switch message.provider {
                case .gmail: try await GmailAPI.untrash(id: message.providerId, accessToken: token)
                case .outlook: try await GraphAPI.moveToInbox(id: message.providerId, accessToken: token)
                }
            } catch {
                guard NetworkMonitor.shared.isOnline else {
                    enqueueOffline(.restore(messageId: message.id))
                    return
                }
                if let idx = messages.firstIndex(where: { $0.id == message.id }) {
                    messages[idx].folder = previousFolder
                    MessageCacheStore.save(messages)
                }
                AppLog.sync.error("restore failed for \(message.id): \(error.localizedDescription)")
                errorMessage = "Couldn't restore: \(error.localizedDescription)"
            }
        }
    }

    func restoreThread(_ thread: MessageThread) {
        for message in thread.messages { restore(message) }
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

    func bulkUnarchive() {
        for message in selectedMessages { unarchive(message) }
        selectedThreadKeys.removeAll()
    }

    func bulkDelete() {
        for message in selectedMessages { delete(message) }
        selectedThreadKeys.removeAll()
    }

    func bulkRestore() {
        for message in selectedMessages { restore(message) }
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
        try await sendFrom(accountEmail: nil, to: to, cc: cc, bcc: bcc, subject: subject, bodyHTML: bodyHTML, attachments: attachments)
    }

    /// Same as `send`, but for callers that know exactly which connected
    /// account should send it (MCP's `send_email` names one explicitly) —
    /// falls back to the first account if that email isn't connected.
    func sendFrom(
        accountEmail: String?, to: String, cc: String = "", bcc: String = "",
        subject: String, bodyHTML: String, attachments: [OutgoingAttachment] = []
    ) async throws {
        let account = accountEmail.flatMap { email in accounts.first { $0.email == email } } ?? accounts.first
        guard let account else { throw SendError.noAccount }
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

    /// The color indicator for a message — the sending account's
    /// (customizable in Settings) color, not a hardcoded per-provider one.
    func color(for message: Message) -> Color {
        accounts.first(where: { $0.id == message.accountId })?.color ?? message.provider.color
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
            AppLog.sync.error("Gmail load failed: \(error.localizedDescription)")
        }
    }

    /// Interactive Outlook (Microsoft Graph) sign-in + inbox/sent fetch. Merges
    /// live mail into `messages` alongside any Gmail account already loaded.
    func loadOutlook() async {
        do {
            let account = try await OAuthManager.shared.signInWithMicrosoft()
            try await fetchAndMerge(account)
        } catch {
            AppLog.sync.error("Outlook load failed: \(error.localizedDescription)")
        }
    }

    /// Deletes the stored tokens and drops the account's mail from this
    /// session — it won't come back on relaunch, and won't show up again
    /// until reconnected from Settings.
    func disconnectAccount(_ account: Account) {
        OAuthManager.shared.disconnect(account)
        accounts.removeAll { $0.id == account.id }
        messages.removeAll { $0.accountId == account.id }
        MessageCacheStore.save(messages)
    }

    /// Settings > Advanced > "Clear local cache" — drops the on-disk
    /// message cache and prewarmed HTML views, then immediately refetches
    /// so the effect is visible right away rather than only on next
    /// launch. Drafts and the offline write queue are untouched — those
    /// are pending user work, not disposable cache.
    func clearLocalCache() {
        MessageCacheStore.clear()
        HTMLPrewarmCache.shared.clear()
        messages.removeAll()
        Task { await refreshAll() }
    }

    /// Restores any accounts signed in during a prior launch (silent token
    /// refresh, no browser prompt) and loads their mail. Call once at startup.
    func restoreSession() async {
        // Populate from local cache first so previously-synced mail is
        // visible instantly and works fully offline — the in-memory
        // `messages` array alone doesn't survive a relaunch with no network.
        if messages.isEmpty {
            messages = await MessageCacheStore.load()
        }
        // Same fix as the cached-messages line above, for the account list:
        // show accounts as connected the instant we know about them from
        // Keychain (purely local, instant) rather than waiting on
        // restoreAccounts()'s per-account token-refresh + backend-register
        // network round trips — that's what caused the sidebar to show "No
        // account / Connect Gmail" for several seconds with mail already
        // loaded on screen.
        for account in OAuthManager.shared.storedAccountsFromKeychain() {
            if !accounts.contains(where: { $0.email == account.email && $0.provider == account.provider }) {
                accounts.append(account)
            }
        }
        PowerAssertionService.beginSyncIfEnabled()
        defer { PowerAssertionService.endSync() }
        for account in await OAuthManager.shared.restoreAccounts() {
            do {
                try await fetchAndMerge(account)
            } catch {
                AppLog.auth.error("Silent restore failed for \(account.email): \(error.localizedDescription)")
            }
        }
        startSyncTimerIfNeeded()
        await performOneTimeHistoryBackfillIfNeeded()
        await performOneTimeCategoryBackfillIfNeeded()
        await performOneTimeCategoryMailBackfillIfNeeded()
    }

    /// Runs once ever (per install): pulls a much deeper history than the
    /// regular sync does — 2000 latest from Gmail, everything from Outlook
    /// (fine for a small/new account). Ordinary syncs stay at the smaller
    /// default so they don't re-fetch thousands of already-known messages
    /// on every refresh; this just backfills what was missing the first time.
    private func performOneTimeHistoryBackfillIfNeeded() async {
        guard !AppSettings.shared.hasBackfilledMailHistory else { return }
        guard NetworkMonitor.shared.isOnline else { return }
        AppSettings.shared.hasBackfilledMailHistory = true
        for account in accounts {
            do {
                let token = try await OAuthManager.shared.validAccessToken(for: account)
                let fetched: [Message]
                switch account.provider {
                case .gmail:
                    async let inboxTask = GmailAPI.fetchInbox(for: account, accessToken: token, limit: 2000)
                    async let sentTask = GmailAPI.fetchSent(for: account, accessToken: token, limit: 500)
                    let (inbox, sent) = try await (inboxTask, sentTask)
                    fetched = inbox + sent
                case .outlook:
                    async let inboxTask = GraphAPI.fetchInbox(for: account, accessToken: token, limit: 10000)
                    async let sentTask = GraphAPI.fetchSent(for: account, accessToken: token, limit: 10000)
                    let (inbox, sent) = try await (inboxTask, sentTask)
                    fetched = inbox + sent
                }
                merge(account: account, fetched: fetched)
            } catch {
                AppLog.sync.error("History backfill failed for \(account.email): \(error.localizedDescription)")
            }
        }
    }

    /// Runs once ever: Gmail mail synced before this app started reading
    /// Gmail's real CATEGORY_* label was filed by a local sender/subject
    /// heuristic instead, which disagrees with Gmail often enough to be a
    /// real problem (e.g. Indeed job alerts guessed as Primary when Gmail
    /// itself puts them in Updates). Re-fetches just the label — not the
    /// whole message — for every already-synced Gmail message and patches
    /// its category in place, so existing mail lands in the same tab
    /// Gmail's own UI shows it in, not just newly-synced mail going forward.
    private func performOneTimeCategoryBackfillIfNeeded() async {
        guard !AppSettings.shared.hasBackfilledCategories else { return }
        guard NetworkMonitor.shared.isOnline else { return }
        AppSettings.shared.hasBackfilledCategories = true

        for account in accounts where account.provider == .gmail {
            guard let token = try? await OAuthManager.shared.validAccessToken(for: account) else { continue }
            let targets = messages.filter { $0.accountId == account.id && $0.provider == .gmail }
            guard !targets.isEmpty else { continue }

            let results = await withTaskGroup(of: (UUID, MessageCategory?).self) { group -> [UUID: MessageCategory] in
                var iterator = targets.makeIterator()
                let maxConcurrent = 8
                func addNext() {
                    guard let message = iterator.next() else { return }
                    group.addTask {
                        let category = try? await GmailAPI.fetchCategory(id: message.providerId, accessToken: token)
                        return (message.id, category ?? nil)
                    }
                }
                for _ in 0..<min(maxConcurrent, targets.count) { addNext() }
                var resolved: [UUID: MessageCategory] = [:]
                while let (id, category) = await group.next() {
                    if let category { resolved[id] = category }
                    addNext()
                }
                return resolved
            }

            guard !results.isEmpty else { continue }
            // Build the patched array first, then assign once — mutating
            // `messages` per-index in this loop would re-trigger the
            // (O(n)) filteredThreads recompute on every single one of
            // potentially thousands of messages instead of once.
            var updated = messages
            for index in updated.indices {
                if let category = results[updated[index].id] {
                    updated[index].providerCategory = category
                }
            }
            messages = updated
            MessageCacheStore.save(messages)
        }
    }

    /// Runs once ever: now that the local cache scales to any mailbox size
    /// (SQLite, bounded launch-time load — see MessageCacheStore), pulls up
    /// to 2000 Gmail messages for each of Primary/Social/Updates/Forums
    /// individually (whichever is smaller — a category with only 500
    /// messages just gets all 500). Promotions is deliberately left alone.
    private func performOneTimeCategoryMailBackfillIfNeeded() async {
        guard !AppSettings.shared.hasBackfilledCategoryMail else { return }
        guard NetworkMonitor.shared.isOnline else { return }
        AppSettings.shared.hasBackfilledCategoryMail = true

        let categoriesToBackfill: [MessageCategory] = [.primary, .social, .updates, .forums]
        for account in accounts where account.provider == .gmail {
            guard let token = try? await OAuthManager.shared.validAccessToken(for: account) else { continue }
            for category in categoriesToBackfill {
                do {
                    let fetched = try await GmailAPI.fetchInboxByCategory(
                        category, for: account, accessToken: token, limit: 2000)
                    merge(account: account, fetched: fetched)
                } catch {
                    AppLog.sync.error("Category mail backfill (\(category.rawValue)) failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Manual re-fetch for every connected account — backs the toolbar's
    /// refresh button. Realtime updates already push new mail in as it
    /// arrives; this is for "no, check right now."
    func refreshAll() async {
        guard NetworkMonitor.shared.isOnline else { return }
        PowerAssertionService.beginSyncIfEnabled()
        defer { PowerAssertionService.endSync() }
        for account in accounts {
            do {
                try await fetchAndMerge(account)
            } catch {
                AppLog.sync.error("Manual refresh failed for \(account.email): \(error.localizedDescription)")
            }
        }
    }

    private var syncTimerTask: Task<Void, Never>?

    /// Settings > General > sync frequency override — realtime push already
    /// covers new mail as it arrives; this is a periodic belt-and-suspenders
    /// refresh for whatever realtime might miss. 0 disables it.
    private func startSyncTimerIfNeeded() {
        syncTimerTask?.cancel()
        let minutes = AppSettings.shared.syncFrequencyMinutes
        guard minutes > 0 else { return }
        syncTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(minutes * 60))
                guard !Task.isCancelled else { return }
                await self?.refreshAll()
            }
        }
    }

    /// Called when the setting changes while the app is already running, so
    /// a new interval takes effect immediately instead of at next launch.
    func applySyncFrequencyChange() {
        startSyncTimerIfNeeded()
    }

    /// Subscribes to live inserts from the backend so new mail (delivered via
    /// Gmail/Graph webhooks) appears within seconds, without polling. Runs
    /// until cancelled — call from a long-lived `.task {}`.
    func startRealtimeUpdates() async {
        await RealtimeService.subscribeToMessages { [weak self] row in
            Task { @MainActor in self?.handleRealtimeInsert(row) }
        }
    }

    /// Loads any write actions already waiting for approval, then streams
    /// in new ones as MCP tool calls queue them. Call from a long-lived
    /// `.task {}`, same as `startRealtimeUpdates`.
    func startMCPApprovalUpdates() async {
        if let existing = try? await MCPSettingsService.fetchPendingActions() {
            pendingMCPActions = existing
        }
        await MCPSettingsService.subscribeToPendingActions { [weak self] action in
            Task { @MainActor in
                guard let self, !self.pendingMCPActions.contains(action) else { return }
                self.pendingMCPActions.insert(action, at: 0)
            }
        }
    }

    /// Executes the queued write for real using the app's own already-
    /// authenticated Gmail/Graph clients, then marks it resolved.
    func approvePendingMCPAction(_ action: PendingAction) async {
        do {
            try await executeMCPAction(action)
            try await MCPSettingsService.resolvePendingAction(action.id, tool: action.tool, approved: true)
        } catch {
            errorMessage = "Couldn't complete the approved action: \(error.localizedDescription)"
            try? await MCPSettingsService.resolvePendingAction(action.id, tool: action.tool, approved: false)
        }
        pendingMCPActions.removeAll { $0.id == action.id }
    }

    func rejectPendingMCPAction(_ action: PendingAction) async {
        try? await MCPSettingsService.resolvePendingAction(action.id, tool: action.tool, approved: false)
        pendingMCPActions.removeAll { $0.id == action.id }
    }

    private enum MCPActionError: LocalizedError {
        case missingArgs, messageNotFound
        var errorDescription: String? {
            switch self {
            case .missingArgs: return "The queued action is missing required data."
            case .messageNotFound: return "That message is no longer available."
            }
        }
    }

    private func executeMCPAction(_ action: PendingAction) async throws {
        let args = action.args
        switch action.tool {
        case "archive_email":
            guard let idString = args["message_id"]?.stringValue, let message = messages.first(where: { $0.id.uuidString.lowercased() == idString.lowercased() }) else {
                throw MCPActionError.messageNotFound
            }
            archive(message)

        case "mark_read":
            guard let idString = args["message_id"]?.stringValue, let message = messages.first(where: { $0.id.uuidString.lowercased() == idString.lowercased() }) else {
                throw MCPActionError.messageNotFound
            }
            let isRead = args["is_read"]?.boolValue ?? true
            await setRead(message, read: isRead)

        case "send_email":
            guard let to = args["to"]?.arrayValue?.compactMap(\.stringValue), !to.isEmpty,
                  let subject = args["subject"]?.stringValue, let body = args["body"]?.stringValue,
                  let account = args["account"]?.stringValue else {
                throw MCPActionError.missingArgs
            }
            try await sendFrom(accountEmail: account, to: to.joined(separator: ", "), subject: subject, bodyHTML: body)

        case "reply_email":
            guard let idString = args["message_id"]?.stringValue, let message = messages.first(where: { $0.id.uuidString.lowercased() == idString.lowercased() }),
                  let body = args["body"]?.stringValue else {
                throw MCPActionError.missingArgs
            }
            try await reply(to: message, bodyHTML: body)

        default:
            throw MCPActionError.missingArgs
        }
    }

    /// Realtime inserts are the ONLY source of genuinely-new mail — the
    /// initial REST-fetched sync never routes through here, so this is also
    /// the one place it's correct to fire a notification (existing mail
    /// syncing for the first time must never notify).
    private func handleRealtimeInsert(_ row: RealtimeService.MessageRow) {
        guard let provider = Provider(rawValue: row.provider),
              let accountId = accounts.first(where: { $0.provider == provider && $0.email == row.accountEmail })?.id
        else { return } // mail for an account not connected in this session — ignore
        guard !messages.contains(where: { $0.id == row.id }) else { return }
        let message = Message(
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
            folder: row.folder,
            needsFullSync: true
        )
        messages.append(message)
        // Webhook rows don't carry To/Cc (see the Message.htmlBody comment
        // for why) — just the sender, but that's still a real, useful
        // partial update to the index rather than nothing until next sync.
        Task { await ContactsIndexService.recordContacts(from: [message]) }
        let settings = AppSettings.shared
        if settings.notificationsEnabled, !settings.mutedAccountEmails.contains(row.accountEmail) {
            NotificationService.notifyNewMail(message)
        }
    }

    /// Jumps straight to a message regardless of whatever folder/filter/
    /// search is currently active — used when the user clicks a
    /// notification for mail that arrived while looking at something else.
    func openMessage(byId id: UUID) {
        guard let message = messages.first(where: { $0.id == id }) else { return }
        selectedFolder = message.folder
        providerFilter = nil
        categoryFilter = message.category
        searchText = ""
        guard let thread = filteredThreads.first(where: { $0.id == message.threadKey }) else { return }
        select(thread)
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
        let existingIndexByID = Dictionary(uniqueKeysWithValues: messages.enumerated().map { ($1.id, $0) })
        var newMessages: [Message] = []
        for var message in fetched {
            if let index = existingIndexByID[message.id] {
                // Only ever replace a realtime-webhook placeholder (minimal
                // payload — no attachments/htmlBody/category) once the
                // regular full sync has the real data. A message that's
                // already fully synced is left alone so this doesn't clobber
                // local-only state (isStarred/isImportant) with a stale
                // refetch that raced it.
                guard messages[index].needsFullSync else { continue }
                message.isStarred = messages[index].isStarred
                message.isImportant = messages[index].isImportant
                messages[index] = message
            } else {
                newMessages.append(message)
            }
        }
        messages.append(contentsOf: newMessages)
        // Warm the messages actually visible in the inbox right now — by
        // far the most likely to be opened first — so the very first click
        // of the session is already loaded too, not just subsequent ones.
        for thread in filteredThreads.prefix(6) {
            prewarmHTML(for: thread.latest)
        }
        MessageCacheStore.save(messages)
        // Incremental only — record just the messages that are actually
        // new this merge, never the whole re-fetched batch, or refreshing
        // would double-count everyone's frequency on every sync.
        Task { await ContactsIndexService.recordContacts(from: newMessages) }
    }
}
