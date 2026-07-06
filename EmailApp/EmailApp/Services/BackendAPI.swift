import Foundation

/// Talks to the Phase 5 Vercel backend, which owns webhook subscriptions
/// (Gmail Pub/Sub watch, Graph change notifications) independently of this
/// app being open.
enum BackendAPI {
    enum BackendError: LocalizedError {
        case requestFailed(Int, String)

        var errorDescription: String? {
            switch self {
            case .requestFailed(let code, let body): return "Backend request failed (\(code)): \(body)"
            }
        }
    }

    /// Registers an account's refresh token with the backend and kicks off
    /// its push subscription. Called right after interactive sign-in.
    static func registerAccount(
        provider: Provider, email: String, refreshToken: String
    ) async throws {
        var req = URLRequest(url: URL(string: "\(Config.backendBaseURL)/api/accounts/register")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode([
            "provider": provider.rawValue,
            "email": email,
            "refreshToken": refreshToken,
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw BackendError.requestFailed(code, String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// One row of the payload `indexForSearch` sends — mirrors the backend's
    /// `messages` table columns closely enough for full-text search, not a
    /// full message mirror (no htmlBody/attachments; search only needs
    /// subject/sender/snippet, which is exactly what search_vector indexes).
    /// Deliberately no accountId: this app's local Account.id has no
    /// relationship to Supabase's DB-generated accounts.id (see backend's
    /// backfill.ts doc comment) — the backend resolves the real account
    /// from (provider, accountEmail) itself.
    struct SearchIndexEntry: Encodable {
        let accountEmail: String
        let provider: String
        let providerMessageId: String
        let threadId: String?
        let messageIdHeader: String?
        let referencesHeader: String?
        let senderName: String
        let senderEmail: String
        let subject: String
        let snippet: String
        let body: String
        let receivedAt: Date
        let isRead: Bool
        let folder: String
        let hasAttachments: Bool
    }

    /// Bulk-upserts message metadata into Postgres for full-text search —
    /// called by the one-time search-index backfill migration and, on an
    /// ongoing basis, whenever a regular sync merges in genuinely new mail
    /// (see InboxViewModel.merge), so the index never goes stale for mail
    /// synced after the initial backfill. Fire-and-forget from the caller's
    /// perspective is fine here — a failed index update just means that
    /// batch of mail is temporarily unsearchable via full-text search until
    /// the next successful call, not a data-loss risk (the local cache,
    /// which is what actually renders messages, is untouched either way).
    static func indexForSearch(_ entries: [SearchIndexEntry]) async throws {
        guard !entries.isEmpty else { return }
        var req = URLRequest(url: URL(string: "\(Config.backendBaseURL)/api/messages/backfill")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        req.httpBody = try encoder.encode(["messages": entries])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw BackendError.requestFailed(code, String(data: data, encoding: .utf8) ?? "")
        }
    }

    struct SearchResult: Decodable {
        let id: UUID
        let rank: Double
    }

    enum SearchMode: String, Encodable {
        case keyword, semantic, hybrid
    }

    struct PendingEmbeddingItem: Decodable {
        let id: UUID
        let subject: String?
        let snippet: String?
        let sender_name: String?
        let body: String?
    }

    /// Rows still missing an embedding, for the local Ollama backfill loop
    /// (InboxViewModel) to embed and write back via `storeEmbeddings`. Only
    /// takes resolved accountIds — same read-path tradeoff as
    /// searchMessages (see that method's doc comment): a stale cached id
    /// just means this round finds nothing, not a correctness issue.
    static func fetchPendingEmbeddings(accountIds: [UUID], limit: Int = 100) async throws -> [PendingEmbeddingItem] {
        struct Request: Encodable { let action = "pending"; let accountIds: [String]; let limit: Int }
        var req = URLRequest(url: URL(string: "\(Config.backendBaseURL)/api/messages/embeddings")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Request(accountIds: accountIds.map(\.uuidString), limit: limit))
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw BackendError.requestFailed(code, String(data: data, encoding: .utf8) ?? "")
        }
        struct Response: Decodable { let items: [PendingEmbeddingItem] }
        return try JSONDecoder().decode(Response.self, from: data).items
    }

    /// Batch-writes vectors computed locally by OllamaService back onto
    /// their message rows — ids here are always ones `fetchPendingEmbeddings`
    /// just returned, so this never needs account resolution at all.
    /// Returns the actual updated-row count (from the RPC's `get
    /// diagnostics row_count`, not just `items.count`) so a caller can
    /// detect a silent id/cast mismatch and stop retrying instead of
    /// re-fetching the same "pending" rows forever.
    @discardableResult
    static func storeEmbeddings(_ items: [(id: UUID, embedding: [Double])]) async throws -> Int {
        guard !items.isEmpty else { return 0 }
        struct Item: Encodable { let id: String; let embedding: [Double] }
        struct Request: Encodable { let action = "store"; let items: [Item] }
        var req = URLRequest(url: URL(string: "\(Config.backendBaseURL)/api/messages/embeddings")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Request(items: items.map { Item(id: $0.id.uuidString, embedding: $0.embedding) }))
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw BackendError.requestFailed(code, String(data: data, encoding: .utf8) ?? "")
        }
        struct Response: Decodable { let stored: Int }
        return try JSONDecoder().decode(Response.self, from: data).stored
    }

    struct AccountRef: Encodable { let provider: String; let email: String }

    struct ResolvedAccount: Decodable { let provider: String; let email: String; let id: UUID }

    /// Resolves (provider, email) pairs to their real Supabase accounts.id
    /// — call once per session (InboxViewModel caches the result) so every
    /// search after the first skips this lookup. See resolve.ts's doc
    /// comment: this was most of what made search feel slow, since it used
    /// to happen on every single keystroke-triggered search instead of once.
    static func resolveAccountIds(_ accounts: [AccountRef]) async throws -> [ResolvedAccount] {
        guard !accounts.isEmpty else { return [] }
        struct Request: Encodable { let accounts: [AccountRef] }
        var req = URLRequest(url: URL(string: "\(Config.backendBaseURL)/api/accounts/resolve")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Request(accounts: accounts))
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw BackendError.requestFailed(code, String(data: data, encoding: .utf8) ?? "")
        }
        struct Response: Decodable { let accounts: [ResolvedAccount] }
        return try JSONDecoder().decode(Response.self, from: data).accounts
    }

    /// Real Postgres full-text search (tsvector/tsquery + ts_rank) — never
    /// falls back to local substring matching. Returns ranked ids only;
    /// InboxViewModel maps them back onto its already-cached Message
    /// objects for display, using the returned order. Prefers pre-resolved
    /// accountIds (fast path, no server-side lookup); falls back to
    /// resolving (provider, email) pairs if none are cached yet.
    static func searchMessages(
        query: String, accountIds: [UUID] = [], accounts: [AccountRef] = [], limit: Int = 200,
        embedding: [Double]? = nil, mode: SearchMode = .keyword
    ) async throws -> [SearchResult] {
        struct Request: Encodable {
            let query: String
            let accountIds: [String]?
            let accounts: [AccountRef]?
            let limit: Int
            let embedding: [Double]?
            let mode: SearchMode
        }
        var req = URLRequest(url: URL(string: "\(Config.backendBaseURL)/api/messages/search")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let idStrings = accountIds.map(\.uuidString)
        req.httpBody = try JSONEncoder().encode(Request(
            query: query,
            accountIds: idStrings.isEmpty ? nil : idStrings,
            accounts: idStrings.isEmpty ? accounts : nil,
            limit: limit,
            embedding: embedding,
            mode: mode
        ))
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw BackendError.requestFailed(code, String(data: data, encoding: .utf8) ?? "")
        }
        struct Response: Decodable { let results: [SearchResult] }
        return try JSONDecoder().decode(Response.self, from: data).results
    }
}
