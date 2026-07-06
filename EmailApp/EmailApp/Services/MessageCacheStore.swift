import Foundation
import SQLite3

/// All actual SQLite work, serialized through actor isolation. `save()` used
/// to spawn an independent `Task.detached` per call with no coordination
/// between them — with a dozen call sites (star, read, archive, merge,
/// backfills, ...) firing in quick succession, two of those detached tasks
/// could genuinely run on different threads at the same moment, both
/// executing BEGIN/COMMIT against the same raw sqlite3 connection
/// concurrently. SQLite connections aren't safe for that; it corrupted the
/// connection's internal page-cache bookkeeping and crashed the app
/// (SIGABRT deep in libsqlite3's commit path — a heap corruption from two
/// threads freeing the same buffer). An actor's mailbox means only one of
/// these ever actually touches `db` at a time, no matter how many calls
/// come in back to back.
private actor MessageCacheStorage {
    static let shared = MessageCacheStorage()

    private let db: OpaquePointer?

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("EmailApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("messages.sqlite")

        var handle: OpaquePointer?
        sqlite3_open(dbURL.path, &handle)
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(
            handle,
            """
            CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY,
                received_at REAL NOT NULL,
                json TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_messages_received_at ON messages(received_at DESC);
            """,
            nil, nil, nil
        )
        db = handle
    }

    /// Every message ever cached — this mailbox's actual size (a few
    /// thousand) decodes in well under a second, so there's no longer a
    /// real speed tradeoff to capping it. It used to be capped at 1500,
    /// which made folders like "All Mail" show a fraction of the real
    /// count and read as data loss rather than a deliberate tradeoff.
    func loadAll() -> [Message] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        sqlite3_prepare_v2(db, "SELECT json FROM messages ORDER BY received_at DESC;", -1, &statement, nil)

        let decoder = JSONDecoder()
        var results: [Message] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(statement, 0) else { continue }
            let data = Data(String(cString: cString).utf8)
            if let message = try? decoder.decode(Message.self, from: data) {
                results.append(message)
            }
        }
        return results
    }

    /// Upserts each message as its own row in one transaction — cheap
    /// regardless of total mailbox size, unlike rewriting one giant file.
    func save(_ messages: [Message]) {
        guard let db, !messages.isEmpty else { return }
        let encoder = JSONEncoder()
        sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)
        var statement: OpaquePointer?
        sqlite3_prepare_v2(
            db, "INSERT OR REPLACE INTO messages (id, received_at, json) VALUES (?, ?, ?);", -1, &statement, nil)
        for message in messages {
            guard let json = try? encoder.encode(message), let jsonString = String(data: json, encoding: .utf8) else { continue }
            sqlite3_reset(statement)
            sqlite3_bind_text(statement, 1, message.id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(statement, 2, message.receivedAt.timeIntervalSince1970)
            sqlite3_bind_text(statement, 3, jsonString, -1, SQLITE_TRANSIENT)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    func clear() {
        guard let db else { return }
        sqlite3_exec(db, "DELETE FROM messages;", nil, nil, nil)
    }
}

/// Persists every fetched message to disk so previously-synchronized mail
/// stays fully readable across a relaunch with no network at all. See
/// `MessageCacheStorage` above for why this is actor-isolated underneath.
enum MessageCacheStore {
    static func loadAll() async -> [Message] {
        await MessageCacheStorage.shared.loadAll()
    }

    /// Fire-and-forget from every call site (star/read/archive toggles,
    /// merge, etc. aren't `async` themselves) — the actor serializes the
    /// real work, so overlapping calls queue instead of racing.
    static func save(_ messages: [Message]) {
        Task { await MessageCacheStorage.shared.save(messages) }
    }

    static func clear() {
        Task { await MessageCacheStorage.shared.clear() }
    }
}

private nonisolated let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
