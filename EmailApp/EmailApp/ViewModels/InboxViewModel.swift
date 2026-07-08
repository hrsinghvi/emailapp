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

        /// Shared between `ComposeView`'s own header and the minimized-bar
        /// title in the compose stack — both need it, and only one of them
        /// has a `ComposeView` instance around to read it off of.
        var title: String {
            switch self {
            case .new: return "New Message"
            case .reply: return "Reply"
            case .replyAll: return "Reply All"
            case .forward: return "Forward"
            case .draft(let draft):
                switch draft.origin {
                case .new: return "New Message"
                case .reply: return "Reply"
                case .replyAll: return "Reply All"
                case .forward: return "Forward"
                }
            }
        }
    }

    /// One open compose window — Gmail-style, up to `maxComposeSessions` at
    /// once, each independently minimizable. `isMinimized` lives here (not
    /// as `ComposeView`'s own `@State`) so the compose stack can lay
    /// minimized/open sessions out together while every session's actual
    /// form state (recipients, body, attachments, AI draft history, ...)
    /// stays alive in its own `ComposeView` instance the whole time — nothing
    /// about minimizing ever unmounts that view.
    struct ComposeSession: Identifiable {
        let id = UUID()
        var context: ComposeContext
        var isMinimized = false
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
        /// The account this is actually sending from — chosen (mandatorily)
        /// via ComposeView's From-picker, not inferred after the fact.
        let fromAccountEmail: String
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
                id: draftId ?? UUID(), accountEmail: fromAccountEmail, to: to, cc: cc, bcc: bcc, subject: subject,
                bodyHTML: bodyHTML,
                attachments: attachments.map { DraftAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) },
                origin: origin, lastModified: Date()
            )
        }

        var asQueuedSend: QueuedSend {
            QueuedSend(
                origin: origin, fromAccountEmail: fromAccountEmail, to: to, cc: cc, bcc: bcc, subject: subject, bodyHTML: bodyHTML,
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
    /// Drives `AskAIPanel` — shared by DetailToolbar's "Ask AI" pill (3b)
    /// and ThreadRow's right-click "Ask about this email" (3e), so opening
    /// from either entry point is the same flag.
    var isAskAIPanelPresented: Bool = false
    /// Drives `SummarizePanel` — same full-width slot above the subject
    /// line as `AskAIPanel`, mutually exclusive with it.
    var isSummarizePanelPresented: Bool = false
    /// Which message inside the open thread is expanded and "focused" for
    /// keyboard actions (reply/forward/archive/toggle-read).
    var expandedMessageIds: Set<UUID> = []
    var focusedMessageId: UUID?

    var selectedFolder: String = "inbox" { didSet { listPageIndex = 0; recomputeFilteredThreads() } }
    var providerFilter: Provider? { didSet { listPageIndex = 0; recomputeFilteredThreads() } }
    /// Gmail-style category tab — only meaningful (and only shown) for the
    /// inbox; other folders show every category mixed together.
    var categoryFilter: MessageCategory = .primary { didSet { listPageIndex = 0; recomputeFilteredThreads() } }
    var searchText: String = "" {
        didSet {
            listPageIndex = 0
            searchTask?.cancel()
            guard !searchFreeText.isEmpty else {
                searchResultIds = nil
                recomputeFilteredThreads()
                return
            }
            // Debounced — a real network round trip per keystroke would
            // both hammer the backend and race itself; 300ms is enough to
            // skip past normal typing speed without feeling laggy once
            // you pause.
            searchTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                await self?.performFullTextSearch()
            }
        }
    }
    private var searchTask: Task<Void, Never>?
    /// Ranked message ids from the last completed Postgres full-text
    /// search, best match first — nil when no free-text query is active
    /// (operator-only searches like `has:attachment` alone never touch
    /// this). Never populated by local substring matching, by design: on
    /// a request failure this is set to `[]` (no matches) rather than
    /// falling back to `.contains()`.
    private(set) var searchResultIds: [UUID]? {
        didSet { searchResultIdSet = searchResultIds.map(Set.init) }
    }
    /// Mirrors searchResultIds — membership checks in filteredMessages run
    /// per-message on every recompute, so this avoids an O(n) array scan
    /// per message against a list that can run into the hundreds.
    private var searchResultIdSet: Set<UUID>?
    private(set) var isSearching = false
    /// Open compose windows, newest first (the compose stack renders this
    /// order left-to-right, so a freshly opened one appears to the left of
    /// whatever was already open — see `openCompose`).
    var composeSessions: [ComposeSession] = []
    private static let maxComposeSessions = 3
    /// Set true when `openCompose` is refused for already being at the cap
    /// — `ContentView` shows this as an alert, then resets it.
    var composeLimitAlertShown = false
    /// Settings is an in-window dimmed modal (Claude-desktop style), not a
    /// separate NSWindow — this is the only state it needs.
    var isSettingsPresented = false
    var errorMessage: String?

    /// Opens a new compose window (Compose, Reply, Reply All, Forward, or
    /// reopening a draft) — never replaces an already-open one, up to
    /// `maxComposeSessions` at a time. `force` bypasses the cap for Undo
    /// Send reopening a just-cancelled send: that's the user recovering
    /// content they already committed to, not a fresh compose action, so
    /// losing it silently to the cap would be worse than briefly exceeding it.
    @discardableResult
    func openCompose(_ context: ComposeContext, force: Bool = false) -> Bool {
        guard force || composeSessions.count < Self.maxComposeSessions else {
            composeLimitAlertShown = true
            return false
        }
        composeSessions.insert(ComposeSession(context: context), at: 0)
        return true
    }

    func closeCompose(_ id: UUID) {
        composeSessions.removeAll { $0.id == id }
    }

    /// Escape's behavior depends on how many compose windows are open.
    /// With exactly one: a first press minimizes it, a second closes it
    /// (autosaving as a draft if there's content, same as clicking the X —
    /// `ComposeView.onDisappear` already does that unconditionally on
    /// removal). With more than one, Escape only ever minimizes — the
    /// rightmost (oldest) still-open session first, then the next one to
    /// its left on each subsequent press, since `openCompose` inserts new
    /// sessions at the front (leftmost) — and never closes anything, so a
    /// stray Escape can't discard work when several are open at once. Once
    /// every session is minimized, further presses do nothing.
    func handleComposeEscape() {
        guard composeSessions.count > 1 else {
            guard let only = composeSessions.first else { return }
            if only.isMinimized {
                closeCompose(only.id)
            } else {
                composeSessions[0].isMinimized = true
            }
            return
        }
        guard let index = composeSessions.lastIndex(where: { !$0.isMinimized }) else { return }
        composeSessions[index].isMinimized = true
    }
    /// Bumped to request the search field take keyboard focus (Cmd+K).
    var searchFocusTrigger = 0
    /// Bumped to request the search field give up keyboard focus — the
    /// mirror image of searchFocusTrigger, used by the app-level Escape
    /// handler (see ContentView) so it can close the dropdown even though
    /// the FocusState driving it is private to TopBar.
    var searchBlurTrigger = 0
    /// Mirrors TopBar's private isDropdownOpen state — lets the app-level
    /// Escape handler know whether there's actually a dropdown to close,
    /// independent of whether any text has been typed yet (clicking the
    /// search bar opens the dropdown with an empty query, and Escape should
    /// still close it in that case).
    var isSearchDropdownOpen = false

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

    // MARK: - Sidebar "new mail" indicators

    /// Per-sidebar-destination "last clicked into" timestamps, backing the
    /// colored new-mail badges below — deliberately distinct from an unread
    /// count (which clears the moment a message is *read*): this only
    /// resets when the user actually clicks into that Inbox/Gmail/Outlook/
    /// category row, so mail that arrives while they're reading something
    /// else still counts as "new" until they go back and look.
    private var sidebarLastVisited: [String: Date] = [:]
    /// Baseline for a destination the user hasn't explicitly clicked into
    /// yet this session — "new" then means "since launch" rather than
    /// showing every message that ever existed as unread.
    private let sidebarVisitBaseline = Date()

    func markSidebarVisited(_ key: String) {
        sidebarLastVisited[key] = Date()
    }

    /// Shared by the sidebar's category rows and the Cmd+2..5 shortcuts.
    func selectCategory(_ category: MessageCategory) {
        selectedFolder = "inbox"
        categoryFilter = category
        providerFilter = nil
        markSidebarVisited("category-\(category.rawValue)")
    }

    private func newMailCount(sidebarKey key: String, matching predicate: (Message) -> Bool) -> Int {
        let since = sidebarLastVisited[key] ?? sidebarVisitBaseline
        return messages.filter { predicate($0) && $0.receivedAt > since }.count
    }

    /// Inbox / Gmail / Outlook new-mail badge.
    func newMailCount(forFolder key: String) -> Int {
        switch key {
        case "inbox": return newMailCount(sidebarKey: "inbox") { $0.folder == "inbox" }
        case "gmail": return newMailCount(sidebarKey: "gmail") { $0.folder == "inbox" && $0.provider == .gmail }
        case "outlook": return newMailCount(sidebarKey: "outlook") { $0.folder == "inbox" && $0.provider == .outlook }
        default: return 0
        }
    }

    /// Promotions/Social/Updates/Forums new-mail badge.
    func newMailCount(for category: MessageCategory) -> Int {
        newMailCount(sidebarKey: "category-\(category.rawValue)") { $0.folder == "inbox" && $0.category == category }
    }

    init() {
        accounts = []
        messages = []
        resolvedAccountIds = AppSettings.shared.cachedAccountIds.compactMapValues(UUID.init)
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
        draftId: UUID?, origin: DraftOrigin, fromAccountEmail: String, to: String, cc: String, bcc: String,
        subject: String, bodyHTML: String, attachments: [OutgoingAttachment]
    ) {
        // A pending send is its own state, not simultaneously a draft — drop
        // it from the drafts list now. The file itself stays on disk until
        // the real send succeeds, so a crash mid-countdown doesn't lose it.
        if let draftId { drafts.removeAll { $0.id == draftId } }

        let delay = AppSettings.shared.undoSendDelay
        var pending = PendingSend(
            draftId: draftId, origin: origin, fromAccountEmail: fromAccountEmail, to: to, cc: cc, bcc: bcc, subject: subject,
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
        openCompose(.draft(pending.asDraft), force: true)
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
                origin: pending.origin, fromAccountEmail: pending.fromAccountEmail, to: pending.to, cc: pending.cc, bcc: pending.bcc,
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
        origin: DraftOrigin, fromAccountEmail: String, to: String, cc: String, bcc: String, subject: String, bodyHTML rawBodyHTML: String,
        attachments: [OutgoingAttachment]
    ) async throws {
        // The compose editor stores/restores its body as white (its own
        // background is forced dark) — recolored to black here, the single
        // choke point every send path (immediate, offline-queued, undo's
        // resend) routes through, right before it actually leaves the app.
        // Undoing a send reopens `pending.bodyHTML`, which was never
        // touched by this, so the reopened draft stays white instead of
        // coming back black.
        let bodyHTML = (NSAttributedString(html: rawBodyHTML) ?? NSAttributedString(string: rawBodyHTML)).htmlStringForSending()
        func plainSend() async throws {
            try await sendFrom(accountEmail: fromAccountEmail, to: to, cc: cc, bcc: bcc, subject: subject, bodyHTML: bodyHTML, attachments: attachments)
        }
        switch origin {
        case .new, .forward:
            try await plainSend()
        case .reply(let messageId):
            // Reply/reply-all stay pinned to whichever account actually
            // owns the original message, regardless of `fromAccountEmail`
            // — Gmail/Graph threading is mailbox-specific (the thread only
            // exists in that one account's mailbox), so ComposeView's
            // From-picker only ever offers that same account for these two
            // origins in the first place; this is just enforcing it here too.
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
                origin: payload.origin, fromAccountEmail: payload.fromAccountEmail, to: payload.to, cc: payload.cc, bcc: payload.bcc,
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
        let threads = grouped.map { key, messages in
            MessageThread(id: key, messages: messages.sorted { $0.receivedAt < $1.receivedAt })
        }
        let sorted: [MessageThread]
        if !searchFreeText.isEmpty, let ids = searchResultIds {
            // Relevance order, not date order — ts_rank already sorted
            // `ids` best-match-first; a thread's rank is its best-ranked
            // message's position in that list.
            let rankOf = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
            sorted = threads.sorted { a, b in
                let aRank = a.messages.compactMap { rankOf[$0.id] }.min() ?? Int.max
                let bRank = b.messages.compactMap { rankOf[$0.id] }.min() ?? Int.max
                return aRank < bRank
            }
        } else {
            sorted = threads.sorted { $0.latest.receivedAt > $1.latest.receivedAt }
        }
        // Was a plain assignment — MessageListView's row .transition() only
        // ever plays inside an animated context, and nothing here provided
        // one, so search results (and any other filter change) just
        // snapped into place instantly instead of animating in.
        withAnimation(.easeOut(duration: 0.22)) {
            filteredThreads = sorted
        }
    }

    /// Cached across launches (see AppSettings.cachedAccountIds) so search
    /// skips the (provider, email) -> accounts.id lookup entirely on every
    /// keystroke-triggered search, from the very first search of a session —
    /// that repeated lookup, not the actual ts_rank query (~2ms even across
    /// full history), was most of why search felt slow. Keyed by
    /// "provider:email". Seeded from disk in init(), refreshed whenever a
    /// resolution succeeds.
    private var resolvedAccountIds: [String: UUID]
    private var isResolvingAccountIds = false

    /// Resolves whichever connected accounts aren't already cached. Called
    /// once at startup (fire-and-forget from restoreSession) AND retried
    /// from performFullTextSearch whenever a search finds the cache
    /// incomplete — a transient failure at launch (flaky wifi right as the
    /// app opens) used to strand every later search on the slow path for
    /// the rest of the session, since nothing ever asked again.
    private func performAccountIdResolutionIfNeeded() async {
        let missing = accounts.filter { resolvedAccountIds["\($0.provider.rawValue):\($0.email.lowercased())"] == nil }
        guard !missing.isEmpty, !isResolvingAccountIds else { return }
        isResolvingAccountIds = true
        defer { isResolvingAccountIds = false }
        do {
            let refs = missing.map { BackendAPI.AccountRef(provider: $0.provider.rawValue, email: $0.email) }
            let resolved = try await BackendAPI.resolveAccountIds(refs)
            for account in resolved {
                resolvedAccountIds["\(account.provider):\(account.email.lowercased())"] = account.id
            }
            AppSettings.shared.cachedAccountIds = resolvedAccountIds.mapValues(\.uuidString)
        } catch {
            AppLog.sync.error("account id resolution failed: \(error.localizedDescription)")
        }
    }

    /// Real Postgres full-text search (tsvector/tsquery + ts_rank against
    /// the GIN-indexed search_vector column) — never local substring
    /// matching. A failure surfaces as "no matches" (searchResultIds = []),
    /// not a silent fallback to `.contains()`.
    /// Keyword vs. semantic vs. hybrid — per the plan's routing heuristic.
    /// Operator-shaped or very short queries (`from:amazon`, 1-2 words)
    /// almost always mean "find this specific thing", where exact
    /// full-text matching wins; longer/question-shaped queries are where
    /// semantic search actually helps ("invoice from Acme last quarter").
    /// Ollama down => always keyword (today's behavior, no embedding
    /// available to send).
    private func searchMode(for query: String, ollamaAvailable: Bool) -> BackendAPI.SearchMode {
        guard ollamaAvailable else { return .keyword }
        let lower = query.lowercased()
        let hasOperator = lower.contains(":") || query.contains("\"")
        let wordCount = query.split(separator: " ").count
        if hasOperator || wordCount <= 2 { return .keyword }
        let isQuestionShaped = lower.hasSuffix("?") || ["who", "what", "when", "where", "why", "how"].contains { lower.hasPrefix($0 + " ") }
        if wordCount >= 4 || isQuestionShaped { return .semantic }
        return .hybrid
    }

    private func performFullTextSearch() async {
        let query = searchFreeText
        guard !query.isEmpty, !accounts.isEmpty else { return }
        isSearching = true
        if accounts.contains(where: { resolvedAccountIds["\($0.provider.rawValue):\($0.email.lowercased())"] == nil }) {
            await performAccountIdResolutionIfNeeded()
        }
        do {
            let cachedIds = accounts.compactMap { resolvedAccountIds["\($0.provider.rawValue):\($0.email.lowercased())"] }
            let ollamaAvailable = await OllamaService.isAvailable()
            let mode = searchMode(for: query, ollamaAvailable: ollamaAvailable)
            let embedding: [Double]? = mode == .keyword ? nil : try? await OllamaService.embed([query], kind: .query).first

            let results: [BackendAPI.SearchResult]
            if cachedIds.count == accounts.count {
                results = try await BackendAPI.searchMessages(query: query, accountIds: cachedIds, embedding: embedding, mode: embedding == nil ? .keyword : mode)
            } else {
                let refs = accounts.map { BackendAPI.AccountRef(provider: $0.provider.rawValue, email: $0.email) }
                results = try await BackendAPI.searchMessages(query: query, accounts: refs, embedding: embedding, mode: embedding == nil ? .keyword : mode)
            }
            guard query == searchFreeText else { return } // superseded by a newer keystroke
            searchResultIds = results.map(\.id)
            // Recorded here (once a search actually completes), not only on
            // Enter — the debounced search this backs runs whether or not
            // the user ever explicitly submits, so tying "recent searches"
            // solely to .onSubmit missed most real searches.
            RecentSearchesStore.record(query)
        } catch {
            guard query == searchFreeText else { return }
            AppLog.sync.error("full-text search failed: \(error.localizedDescription)")
            searchResultIds = []
        }
        isSearching = false
        recomputeFilteredThreads()
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
        // A search should look through all of your mail, not just whatever
        // sidebar folder/category happens to be open — same as Gmail's own
        // search box. Trash stays excluded by default, same as "All Mail".
        let isSearching = !searchFreeText.isEmpty
        return messages
            .filter { message in
                if isSearching { return message.folder != "trash" }
                switch selectedFolder {
                case "all": return message.folder != "trash"
                case "starred": return message.isStarred
                case "important": return message.isImportant
                default: return message.folder == selectedFolder
                }
            }
            .filter { providerFilter == nil || $0.provider == providerFilter }
            .filter { isSearching || selectedFolder != "inbox" || $0.category == categoryFilter }
            .filter { message in
                if searchHasAttachment, message.attachments.isEmpty { return false }
                if searchFromMe, !accounts.contains(where: { $0.email.caseInsensitiveCompare(message.senderEmail) == .orderedSame }) { return false }
                if searchNewerThan7Days, message.receivedAt < sevenDaysAgo { return false }
                guard !searchFreeText.isEmpty else { return true }
                // Real Postgres full-text search (tsvector/tsquery +
                // ts_rank), never local substring matching — see
                // performFullTextSearch. nil means the debounced search
                // hasn't resolved yet; show nothing until it does rather
                // than a misleading "no results" flash or a `.contains()`
                // fallback.
                guard let ids = searchResultIdSet else { return false }
                return ids.contains(message.id)
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

    /// Words from the active free-text search — MessageListView highlights
    /// every occurrence of each one in the sender/subject/snippet, the same
    /// way Gmail bolds what matched. Empty (no highlighting) when there's no
    /// active search, so results shown before a search never get highlighted.
    var searchHighlightTerms: [String] {
        guard searchResultIdSet != nil else { return [] }
        return searchFreeText.split(separator: " ").map(String.init).filter { !$0.isEmpty }
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
            guard !isNotFoundError(error) else {
                AppLog.sync.error("setRead 404 for \(message.id), keeping optimistic update: \(error.localizedDescription)")
                return
            }
            // Re-lookup rather than reuse `index` — the array can shift
            // (removals/merges elsewhere) across the `await` above.
            if let idx = messages.firstIndex(where: { $0.id == message.id }) {
                messages[idx].isRead = previous
                MessageCacheStore.save(messages)
            }
            AppLog.sync.error("setRead failed for \(message.id): \(error.localizedDescription)")
            errorMessage = "Couldn't update read status: \(error.localizedDescription)"
        }
    }

    // MARK: - Archive

    func archiveFocused() {
        guard let message = focusedMessage else { return }
        archive(message)
    }

    /// Gmail/Graph message ids can go stale across folder moves — a queued
    /// or rapid-fire archive/delete/restore for the same message can 404
    /// ("ErrorItemNotFound"/"Not Found") even though the move already
    /// happened server-side under the hood. Treating that as fatal and
    /// rolling the optimistic local change back is worse than just trusting
    /// it went through — that's what made Restore look like it "did
    /// nothing" instead of just not showing a scary alert.
    private func isNotFoundError(_ error: Error) -> Bool {
        if case GmailAPI.GmailError.requestFailed(404, _) = error { return true }
        if case GraphAPI.GraphError.requestFailed(404, _) = error { return true }
        return false
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
                guard !isNotFoundError(error) else {
                    AppLog.sync.error("archive 404 for \(message.id), keeping optimistic move: \(error.localizedDescription)")
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
                guard !isNotFoundError(error) else {
                    AppLog.sync.error("unarchive 404 for \(message.id), keeping optimistic move: \(error.localizedDescription)")
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

    /// Gmail's "Mark unread from here" — marks the given message and every
    /// later one in the same thread unread, leaving anything before it as-is.
    func markUnreadFromHere(_ message: Message, in thread: MessageThread) {
        guard let index = thread.messages.firstIndex(where: { $0.id == message.id }) else { return }
        for later in thread.messages[index...] { markUnread(later) }
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

    /// Cmd-Z within 20s of a delete restores it — see `undoLastDelete`.
    /// Only the single most recent delete is ever eligible, not a full
    /// history: pressing Cmd-Z is meant to walk back the action you just
    /// took, not something from several deletes ago.
    private var lastDeletion: (message: Message, deletedAt: Date)?

    /// Optimistic: message disappears from the current view immediately,
    /// rolled back to its prior folder if the provider call fails.
    func delete(_ message: Message) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let previousFolder = messages[index].folder
        lastDeletion = (message, Date())
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
                guard !isNotFoundError(error) else {
                    AppLog.sync.error("delete 404 for \(message.id), keeping optimistic move: \(error.localizedDescription)")
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

    /// Cmd-Z, handled at the app-content level (see ContentView) — only
    /// reachable when no text field/editor has focus, so it never fights
    /// native text-undo while composing. A no-op past the 20s window: the
    /// entry is dropped either way so a later Cmd-Z can't reach further
    /// back to an even-older delete.
    func undoLastDelete() {
        guard let lastDeletion else { return }
        self.lastDeletion = nil
        guard Date().timeIntervalSince(lastDeletion.deletedAt) <= 20 else { return }
        restore(lastDeletion.message)
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
                guard !isNotFoundError(error) else {
                    AppLog.sync.error("restore 404 for \(message.id), keeping optimistic move: \(error.localizedDescription)")
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

    /// Backs the bulk toolbar's single Mark Read/Unread button — true only
    /// when every selected message is already unread, matching Gmail's own
    /// convention: a mixed selection (or an all-read one) defaults to "Mark
    /// Unread" so the same click always marks the whole selection unread
    /// consistently, and the button only flips to "Mark Read" once that's
    /// actually true of the whole selection.
    var selectedMessagesAllUnread: Bool {
        !selectedMessages.isEmpty && selectedMessages.allSatisfy { !$0.isRead }
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
            // A plain click on a row that's already part of a multi-selection
            // just opens/previews it, keeping the rest checked — matches
            // Finder/Mail: clicking one of several selected items doesn't
            // collapse the selection until you release without dragging.
            // This also keeps the whole set intact for `beginDrag(for:)` when
            // the same mouse-down turns into a drag instead of a tap.
            if !selectedThreadKeys.contains(thread.id) {
                selectedThreadKeys.removeAll()
            }
            select(thread)
            // So a later Shift-click has an anchor to range from — without
            // this, Shift-click after a plain click silently did nothing.
            lastClickedThreadKey = thread.id
        }
    }

    /// Called once, right as a row starts being dragged. Selects just this
    /// row if it wasn't already part of the current selection, then returns
    /// every selected thread's key as a single comma-joined payload string
    /// for the sidebar drop targets to decode.
    func beginDrag(for thread: MessageThread) -> String {
        if !selectedThreadKeys.contains(thread.id) {
            selectedThreadKeys = [thread.id]
        }
        return selectedThreadKeys.joined(separator: ",")
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

    // MARK: - Drag & drop moves

    /// Snapshot of the fields a drag-drop move can touch, taken right before
    /// the move so an Undo can put each message back exactly where it was.
    private struct MessageSnapshot {
        let id: UUID
        let folder: String
        let providerCategory: MessageCategory?
        let isStarred: Bool
        let isImportant: Bool

        init(_ message: Message) {
            id = message.id
            folder = message.folder
            providerCategory = message.providerCategory
            isStarred = message.isStarred
            isImportant = message.isImportant
        }
    }

    /// A "Moved to X — Undo" banner shown above the sidebar footer.
    struct MoveToast: Identifiable, Equatable {
        let id = UUID()
        let text: String
        static func == (lhs: MoveToast, rhs: MoveToast) -> Bool { lhs.id == rhs.id }
    }

    var moveToast: MoveToast?
    private var pendingUndo: (() -> Void)?
    private var moveToastDismissTask: Task<Void, Never>?

    /// Called when a dragged thread selection is dropped on a sidebar row.
    /// `target` is that row's folder id ("inbox", "promotions", "starred",
    /// "important", "archive", "trash", "all", ...).
    func handleDrop(threadKeys: Set<String>, onto target: String) {
        guard target != "all" else { return }
        let targets = messages.filter { threadKeys.contains($0.threadKey) }
        guard !targets.isEmpty else { return }
        let snapshots = targets.map(MessageSnapshot.init)

        switch target {
        case "starred":
            for message in targets where !message.isStarred { toggleStarred(message) }
        case "important":
            for message in targets where !message.isImportant { toggleImportant(message) }
        case "archive":
            for message in targets { archive(message) }
        case "trash":
            for message in targets { delete(message) }
        case "inbox", "promotions", "social", "updates", "forums":
            let category = MessageCategory(rawValue: target) ?? .primary
            for message in targets {
                if message.folder == "trash" { restore(message) }
                else if message.folder != "inbox" { unarchive(message) }
                setCategory(message, to: category)
            }
        default:
            return
        }
        selectedThreadKeys.removeAll()

        // Dropping an already-starred email onto Starred (etc.) genuinely
        // changes nothing — don't show a "moved, Undo" toast for a no-op.
        let anyChanged = snapshots.contains { snapshot in
            guard let current = messages.first(where: { $0.id == snapshot.id }) else { return false }
            return current.folder != snapshot.folder
                || current.providerCategory != snapshot.providerCategory
                || current.isStarred != snapshot.isStarred
                || current.isImportant != snapshot.isImportant
        }
        guard anyChanged else { return }
        showMoveToast(count: targets.count, target: target, snapshots: snapshots)
    }

    /// Local-only, like `providerCategory`'s other writers — dragging into a
    /// tab is a manual override, not a real Gmail label change.
    private func setCategory(_ message: Message, to category: MessageCategory?) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].providerCategory = category
        MessageCacheStore.save(messages)
    }

    private func toastLabel(count: Int, target: String) -> String {
        let noun = count == 1 ? "Conversation" : "\(count) conversations"
        switch target {
        case "starred": return "\(noun) starred"
        case "important": return "\(noun) marked important"
        case "archive": return "\(noun) archived"
        case "trash": return "\(noun) moved to Trash"
        case "inbox": return "\(noun) moved to Inbox"
        case "promotions": return "\(noun) moved to \"Promotions\""
        case "social": return "\(noun) moved to \"Social\""
        case "updates": return "\(noun) moved to \"Updates\""
        case "forums": return "\(noun) moved to \"Forums\""
        default: return "\(noun) updated"
        }
    }

    private func showMoveToast(count: Int, target: String, snapshots: [MessageSnapshot]) {
        let toast = MoveToast(text: toastLabel(count: count, target: target))
        moveToast = toast
        pendingUndo = { [weak self] in
            guard let self else { return }
            for snapshot in snapshots { self.restoreSnapshot(snapshot) }
        }
        moveToastDismissTask?.cancel()
        moveToastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(7.5))
            guard !Task.isCancelled, let self, self.moveToast?.id == toast.id else { return }
            self.moveToast = nil
        }
    }

    /// Reverts one message to exactly the folder/category/star/important
    /// state it had before the move that produced the current toast — reuses
    /// the same archive/delete/restore/unarchive paths as the forward move,
    /// so an Undo stays in sync with Gmail/Outlook instead of just editing
    /// the local cache.
    private func restoreSnapshot(_ snapshot: MessageSnapshot) {
        guard let message = messages.first(where: { $0.id == snapshot.id }) else { return }
        if message.folder != snapshot.folder {
            switch snapshot.folder {
            case "archive": archive(message)
            case "trash": delete(message)
            default:
                if message.folder == "trash" { restore(message) }
                else if message.folder != "inbox" { unarchive(message) }
            }
        }
        if message.isStarred != snapshot.isStarred { toggleStarred(message) }
        if message.isImportant != snapshot.isImportant { toggleImportant(message) }
        setCategory(message, to: snapshot.providerCategory)
    }

    func undoMove() {
        pendingUndo?()
        dismissMoveToast()
    }

    func dismissMoveToast() {
        moveToastDismissTask?.cancel()
        moveToastDismissTask = nil
        pendingUndo = nil
        moveToast = nil
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

    /// Saves a brand-new message as a draft (never sends) — mirrors `sendFrom`.
    /// Only reachable via approving a queued MCP `save_draft` action.
    func saveDraftFrom(accountEmail: String?, to: String, subject: String, bodyHTML: String) async throws {
        let account = accountEmail.flatMap { email in accounts.first { $0.email == email } } ?? accounts.first
        guard let account else { throw SendError.noAccount }
        let token = try await OAuthManager.shared.validAccessToken(for: account)
        switch account.provider {
        case .gmail:
            try await GmailAPI.createDraft(to: to, subject: subject, body: bodyHTML, isHTML: true, accessToken: token)
        case .outlook:
            try await GraphAPI.createDraft(to: to, subject: subject, body: bodyHTML, isHTML: true, accessToken: token)
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
        // loadAll(), not the capped load() — at this mailbox's actual size
        // (a few thousand messages) decoding everything is still well
        // under a second, and capping it made folders like "All Mail" show
        // a fraction of the real count (1,317 shown vs. 4,500+ actually
        // synced), which read as data loss rather than a deliberate speed
        // tradeoff.
        if messages.isEmpty {
            messages = await MessageCacheStore.loadAll()
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
        // Fire-and-forget, deliberately not awaited here — resolving
        // account ids doesn't need to block the rest of session restore,
        // it just needs to finish before the user's first search (which is
        // realistically always more than a network round trip away from
        // app launch). See performFullTextSearch for why this matters.
        Task {
            await performAccountIdResolutionIfNeeded()
            await performEmbeddingBackfillIfNeeded()
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
        await performOutlookImmutableIdMigrationIfNeeded()
        await performStarredImportantMigrationIfNeeded()
        await performSearchIndexBackfillIfNeeded()
    }

    /// Runs once ever (per install): pulls a much deeper history than the
    /// regular sync does — 2000 latest from Gmail, everything from Outlook
    /// (fine for a small/new account). Ordinary syncs stay at the smaller
    /// default so they don't re-fetch thousands of already-known messages
    /// on every refresh; this just backfills what was missing the first time.
    private func performOneTimeHistoryBackfillIfNeeded() async {
        guard !AppSettings.shared.hasBackfilledMailHistory else { return }
        guard NetworkMonitor.shared.isOnline else { return }
        var allSucceeded = true
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
                allSucceeded = false
                AppLog.sync.error("History backfill failed for \(account.email): \(error.localizedDescription)")
            }
        }
        // Only mark done once every account actually backfilled — setting
        // this unconditionally up front meant a failure on first launch
        // (flaky wifi, expired token) permanently skipped the backfill for
        // that install, since the flag never gets a second chance to flip.
        if allSucceeded { AppSettings.shared.hasBackfilledMailHistory = true }
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
        var allSucceeded = true

        for account in accounts where account.provider == .gmail {
            guard let token = try? await OAuthManager.shared.validAccessToken(for: account) else {
                allSucceeded = false
                continue
            }
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
        // Only mark done once every Gmail account's categories actually got
        // patched — see the history-backfill flag's comment for why setting
        // this unconditionally before the work runs is wrong.
        if allSucceeded { AppSettings.shared.hasBackfilledCategories = true }
    }

    /// Runs once ever: now that the local cache scales to any mailbox size
    /// (SQLite, bounded launch-time load — see MessageCacheStore), pulls up
    /// to 2000 Gmail messages for each of Primary/Social/Updates/Forums
    /// individually (whichever is smaller — a category with only 500
    /// messages just gets all 500). Promotions is deliberately left alone.
    private func performOneTimeCategoryMailBackfillIfNeeded() async {
        guard !AppSettings.shared.hasBackfilledCategoryMail else { return }
        guard NetworkMonitor.shared.isOnline else { return }
        var allSucceeded = true

        let categoriesToBackfill: [MessageCategory] = [.primary, .social, .updates, .forums]
        for account in accounts where account.provider == .gmail {
            guard let token = try? await OAuthManager.shared.validAccessToken(for: account) else {
                allSucceeded = false
                continue
            }
            for category in categoriesToBackfill {
                do {
                    let fetched = try await GmailAPI.fetchInboxByCategory(
                        category, for: account, accessToken: token, limit: 2000)
                    merge(account: account, fetched: fetched)
                } catch {
                    allSucceeded = false
                    AppLog.sync.error("Category mail backfill (\(category.rawValue)) failed: \(error.localizedDescription)")
                }
            }
        }
        // Only mark done once every account/category actually backfilled —
        // see the history-backfill flag's comment for why.
        if allSucceeded { AppSettings.shared.hasBackfilledCategoryMail = true }
    }

    /// One-time repair for Outlook messages synced before Graph requests
    /// carried `Prefer: IdType="ImmutableId"` (see GraphAPI's doc comment on
    /// that header) — their cached ids are the old folder-tied format, which
    /// goes stale the moment the message is archived/trashed/restored,
    /// turning every later action on it into a 404 "ErrorItemNotFound".
    /// Removing and re-fetching them is the only way to swap in stable ids,
    /// since the id itself is what has to change, not just an id it's
    /// paired with. Gmail is untouched — its ids were never folder-tied.
    private func performOutlookImmutableIdMigrationIfNeeded() async {
        guard !AppSettings.shared.hasMigratedOutlookImmutableIds else { return }
        guard NetworkMonitor.shared.isOnline else { return }
        var allSucceeded = true

        for account in accounts where account.provider == .outlook {
            guard let token = try? await OAuthManager.shared.validAccessToken(for: account) else {
                allSucceeded = false
                continue
            }
            do {
                // All four folders this app ever assigns locally — a message
                // sitting in Archive or Deleted Items has an id that's
                // unresolvable any other way (see fetchArchived's doc
                // comment), so those two have to be listed directly rather
                // than reached by id.
                async let inboxTask = GraphAPI.fetchInbox(for: account, accessToken: token, limit: 10000)
                async let sentTask = GraphAPI.fetchSent(for: account, accessToken: token, limit: 10000)
                async let archiveTask = GraphAPI.fetchArchived(for: account, accessToken: token, limit: 10000)
                async let deletedTask = GraphAPI.fetchDeleted(for: account, accessToken: token, limit: 10000)
                let (inbox, sent, archived, deleted) = try await (inboxTask, sentTask, archiveTask, deletedTask)
                // Only drop the stale cached copies once the refetch has
                // actually succeeded — removing first and fetching after
                // meant any message that only existed in Archive/Deleted
                // Items was gone for good if the fetch then failed partway
                // through (regular syncs never re-populate those folders).
                messages.removeAll { $0.accountId == account.id && $0.provider == .outlook }
                merge(account: account, fetched: inbox + sent + archived + deleted)
            } catch {
                allSucceeded = false
                AppLog.sync.error("Outlook immutable-id migration failed for \(account.email): \(error.localizedDescription)")
            }
        }
        // Only mark done once every Outlook account migrated successfully —
        // otherwise this silently never retries and stays permanently stale.
        if allSucceeded { AppSettings.shared.hasMigratedOutlookImmutableIds = true }
    }

    /// One-time import of each provider's real starred/important state for
    /// every already-cached message. isStarred/isImportant used to be set
    /// from nothing on every fetch — mail synced before this existed shows
    /// as neither, regardless of its real Gmail STARRED/IMPORTANT label or
    /// Outlook flagged/high-importance state, until this runs once. Going
    /// forward this isn't needed at all — both providers' fetch code now
    /// reads the real state directly off every regular fetch.
    private func performStarredImportantMigrationIfNeeded() async {
        guard !AppSettings.shared.hasMigratedStarredImportant else { return }
        guard NetworkMonitor.shared.isOnline else { return }
        var allSucceeded = true

        for account in accounts where account.provider == .gmail {
            guard let token = try? await OAuthManager.shared.validAccessToken(for: account) else {
                allSucceeded = false
                continue
            }
            do {
                async let starredTask = GmailAPI.fetchMessageIds(label: "STARRED", accessToken: token, limit: 50000)
                async let importantTask = GmailAPI.fetchMessageIds(label: "IMPORTANT", accessToken: token, limit: 50000)
                let (starred, important) = try await (starredTask, importantTask)
                for index in messages.indices where messages[index].accountId == account.id && messages[index].provider == .gmail {
                    messages[index].isStarred = starred.contains(messages[index].providerId)
                    messages[index].isImportant = important.contains(messages[index].providerId)
                }
            } catch {
                allSucceeded = false
                AppLog.sync.error("Starred/important migration failed for \(account.email): \(error.localizedDescription)")
            }
        }

        // Outlook doesn't offer a cheap "list ids matching this filter and
        // patch in place" path the way Gmail's labelIds do here — flag/
        // importance only come back on a full message fetch, so the only
        // way to backfill already-cached Outlook mail is the same
        // remove-and-refetch-every-folder approach the immutable-id
        // migration above uses (independent of whether that one already
        // ran — it may have, on a build before flag/importance were part
        // of its $select, which wouldn't have carried this data either).
        for account in accounts where account.provider == .outlook {
            guard let token = try? await OAuthManager.shared.validAccessToken(for: account) else {
                allSucceeded = false
                continue
            }
            do {
                async let inboxTask = GraphAPI.fetchInbox(for: account, accessToken: token, limit: 10000)
                async let sentTask = GraphAPI.fetchSent(for: account, accessToken: token, limit: 10000)
                async let archiveTask = GraphAPI.fetchArchived(for: account, accessToken: token, limit: 10000)
                async let deletedTask = GraphAPI.fetchDeleted(for: account, accessToken: token, limit: 10000)
                let (inbox, sent, archived, deleted) = try await (inboxTask, sentTask, archiveTask, deletedTask)
                // Same ordering fix as the immutable-id migration above —
                // only drop the stale cached copies once the refetch has
                // actually succeeded, so a mid-fetch failure can't
                // permanently lose Archive/Deleted-only mail.
                messages.removeAll { $0.accountId == account.id && $0.provider == .outlook }
                merge(account: account, fetched: inbox + sent + archived + deleted)
            } catch {
                allSucceeded = false
                AppLog.sync.error("Starred/important migration (Outlook) failed for \(account.email): \(error.localizedDescription)")
            }
        }

        MessageCacheStore.save(messages)
        // Only mark done once every account actually migrated — see the
        // history-backfill flag's comment for why.
        if allSucceeded { AppSettings.shared.hasMigratedStarredImportant = true }
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
        await healNeedsFullSyncMessages()
    }

    /// Directly refetches any message still waiting on a realtime-webhook
    /// placeholder's full sync (`needsFullSync`) by id, rather than relying
    /// on it happening to fall within `fetchAndMerge`'s windowed "most
    /// recent N inbox/sent" fetch — which can permanently miss it if
    /// enough other mail arrives first (the exact bug behind a message's
    /// "to" field silently staying empty, and the reading pane then
    /// falling back to showing the sender's own address for it).
    private func healNeedsFullSyncMessages() async {
        let pending = messages.filter { $0.needsFullSync }
        guard !pending.isEmpty else { return }
        for pendingMessage in pending {
            guard let account = accounts.first(where: { $0.id == pendingMessage.accountId }),
                  let token = try? await OAuthManager.shared.validAccessToken(for: account)
            else { continue }
            do {
                var fetched: Message
                switch pendingMessage.provider {
                case .gmail:
                    fetched = try await GmailAPI.fetchMessage(
                        id: pendingMessage.providerId, account: account, accessToken: token, folder: pendingMessage.folder)
                case .outlook:
                    fetched = try await GraphAPI.fetchMessage(
                        id: pendingMessage.providerId, account: account, accessToken: token, folder: pendingMessage.folder)
                }
                guard let index = messages.firstIndex(where: { $0.id == pendingMessage.id }) else { continue }
                fetched.isStarred = messages[index].isStarred
                fetched.isImportant = messages[index].isImportant
                messages[index] = fetched
            } catch {
                AppLog.sync.error("needsFullSync heal failed for \(pendingMessage.id): \(error.localizedDescription)")
            }
        }
        MessageCacheStore.save(messages)
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

        case "save_draft":
            guard let to = args["to"]?.arrayValue?.compactMap(\.stringValue), !to.isEmpty,
                  let subject = args["subject"]?.stringValue, let body = args["body"]?.stringValue,
                  let account = args["account"]?.stringValue else {
                throw MCPActionError.missingArgs
            }
            try await saveDraftFrom(accountEmail: account, to: to.joined(separator: ", "), subject: subject, bodyHTML: body)

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
        // Gmail/Outlook autosave a draft as its own realtime-inserted row
        // while you're still typing it — same shape as real inbound mail,
        // but sent "from" your own address. Excluding self-sent rows is
        // what actually distinguishes "you got a new email" from "you're
        // still composing one," since a draft's folder can still read
        // "inbox" server-side.
        let isSelfSent = accounts.contains { $0.email.caseInsensitiveCompare(message.senderEmail) == .orderedSame }
        if settings.notificationsEnabled, !settings.mutedAccountEmails.contains(row.accountEmail), !isSelfSent {
            NotificationService.notifyNewMail(message)
        }
        // Fire-and-forget: keeps semantic search current for mail that
        // arrives after the one-time backfill finishes, same reasoning as
        // indexForSearch in merge() below. A failure just leaves this one
        // message embeddingless until the next backfill pass catches it.
        Task { await embedAndStore(message) }
        // Heals this placeholder's To/Cc/body shortly after it arrives,
        // instead of waiting on the next periodic/manual sync (which can be
        // many minutes away, or — since fetchAndMerge only looks at the most
        // recent N inbox/sent messages — might never catch it at all).
        Task {
            try? await Task.sleep(for: .seconds(5))
            await healNeedsFullSyncMessages()
        }
    }

    /// Composes the same text (subject + sender + body, truncated) for both
    /// the backfill loop and this realtime path — nomic-embed-text's
    /// retrieval quality depends on document embeddings being produced
    /// consistently, not just present.
    private func embedText(subject: String, senderName: String, body: String) -> String {
        [subject, senderName, body].joined(separator: "\n").prefix(2000).description
    }

    private func embedAndStore(_ message: Message) async {
        guard await OllamaService.isAvailable() else { return }
        do {
            let text = embedText(subject: message.subject, senderName: message.senderName, body: message.body)
            guard let vector = try await OllamaService.embed([text], kind: .document).first else { return }
            try await BackendAPI.storeEmbeddings([(id: message.id, embedding: vector)])
        } catch {
            AppLog.sync.error("realtime embed failed: \(error.localizedDescription)")
        }
    }

    /// Backfills embeddings for every already-synced message missing one —
    /// pending/store loop against embeddings.ts, chunked at 100/request.
    /// Runs once per launch (not gated behind a permanent done-flag) so a
    /// message that slipped through (Ollama was down last launch, a
    /// realtime-embed call failed) gets caught on the next one; once
    /// nothing's pending it's a single fast no-op request.
    /// Count of messages still missing an embedding, for the Settings >
    /// Advanced backfill status row. `fetchPendingEmbeddings` has no
    /// offset/cursor and embeddings.ts clamps `limit` server-side to 500,
    /// so this is one capped fetch, not true pagination — good enough for
    /// a status row (exact count only matters near zero). Hitting the cap
    /// is reported to the caller so the row can show "500+" instead of a
    /// number that understates the real backlog.
    func pendingEmbeddingCount() async -> (count: Int, isCapped: Bool) {
        let cachedIds = accounts.compactMap { resolvedAccountIds["\($0.provider.rawValue):\($0.email.lowercased())"] }
        guard !cachedIds.isEmpty else { return (0, false) }
        let cap = 500
        let items = (try? await BackendAPI.fetchPendingEmbeddings(accountIds: cachedIds, limit: cap)) ?? []
        return (items.count, items.count >= cap)
    }

    private func performEmbeddingBackfillIfNeeded() async {
        guard await OllamaService.isAvailable() else { return }
        let cachedIds = accounts.compactMap { resolvedAccountIds["\($0.provider.rawValue):\($0.email.lowercased())"] }
        guard !cachedIds.isEmpty else { return }
        while true {
            let items: [BackendAPI.PendingEmbeddingItem]
            do {
                items = try await BackendAPI.fetchPendingEmbeddings(accountIds: cachedIds, limit: 100)
            } catch {
                AppLog.sync.error("embedding backfill fetch failed: \(error.localizedDescription)")
                return
            }
            guard !items.isEmpty else { return }
            do {
                let texts = items.map { embedText(subject: $0.subject ?? "", senderName: $0.sender_name ?? "", body: $0.body ?? "") }
                let vectors = try await OllamaService.embed(texts, kind: .document)
                let pairs = zip(items, vectors).map { (id: $0.id, embedding: $1) }
                let stored = try await BackendAPI.storeEmbeddings(pairs)
                // A 200 response that updated zero rows means an id/cast
                // mismatch server-side, not "nothing to do" — looping again
                // would just re-fetch the same rows forever.
                guard stored > 0 else {
                    AppLog.sync.error("embedding backfill: store_embeddings updated 0 of \(pairs.count) rows, stopping")
                    return
                }
            } catch {
                AppLog.sync.error("embedding backfill store failed: \(error.localizedDescription)")
                return
            }
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
        // Keeps the Postgres search index current for mail synced after the
        // one-time backfill — without this, full-text search would only
        // ever cover whatever existed at backfill time. Best-effort: a
        // failure here doesn't affect mail display at all, only how soon
        // this particular batch becomes searchable.
        guard !newMessages.isEmpty else { return }
        Task {
            do { try await BackendAPI.indexForSearch(newMessages.map { searchIndexEntry(for: $0) }) }
            catch { AppLog.sync.error("search index update failed: \(error.localizedDescription)") }
        }
    }

    private func searchIndexEntry(for message: Message) -> BackendAPI.SearchIndexEntry {
        BackendAPI.SearchIndexEntry(
            accountEmail: accounts.first(where: { $0.id == message.accountId })?.email ?? "",
            provider: message.provider.rawValue,
            providerMessageId: message.providerId,
            threadId: message.threadId,
            messageIdHeader: message.messageIdHeader,
            referencesHeader: message.references,
            senderName: message.senderName,
            senderEmail: message.senderEmail,
            subject: message.subject,
            snippet: message.snippet,
            body: message.body,
            receivedAt: message.receivedAt,
            isRead: message.isRead,
            folder: message.folder,
            hasAttachments: !message.attachments.isEmpty
        )
    }

    /// One-time bulk-index of every already-synced message for full-text
    /// search — everything fetched normally (regular sync, backfills)
    /// never touched Supabase's messages table at all before this existed,
    /// only the realtime-webhook path did. Chunked to keep each request a
    /// reasonable size against a serverless function's payload/time limits.
    private func performSearchIndexBackfillIfNeeded() async {
        guard !AppSettings.shared.hasBackfilledSearchIndex else { return }
        guard NetworkMonitor.shared.isOnline else { return }
        guard !messages.isEmpty else { return }
        var allSucceeded = true

        let entries = messages.map { searchIndexEntry(for: $0) }
        let chunkSize = 300
        var index = 0
        while index < entries.count {
            let chunk = Array(entries[index..<min(index + chunkSize, entries.count)])
            do {
                try await BackendAPI.indexForSearch(chunk)
            } catch {
                allSucceeded = false
                AppLog.sync.error("search index backfill chunk failed: \(error.localizedDescription)")
            }
            index += chunkSize
        }
        // Only mark done once every chunk actually indexed — see the
        // history-backfill flag's comment for why.
        if allSucceeded { AppSettings.shared.hasBackfilledSearchIndex = true }
    }
}
