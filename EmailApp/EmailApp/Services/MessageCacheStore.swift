import Foundation
import SQLite3

/// Persists every fetched message to disk so previously-synchronized mail
/// stays fully readable across a relaunch with no network at all.
///
/// Backed by SQLite instead of a single JSON blob — the old version
/// re-encoded and rewrote the *entire* mailbox to one file on every save,
/// and decoded the entire file on every launch. Both costs grew without
/// bound as the mailbox grew, which is exactly what made launches slow
/// after a few thousand messages. SQLite gives incremental per-row writes
/// (`INSERT OR REPLACE`, not a full-file rewrite) and a bounded `load()` —
/// only the most recent N messages are decoded into memory at launch
/// regardless of how much mail has ever been synced.
nonisolated enum MessageCacheStore {
    private static let recentLoadLimit = 1500

    private static let dbURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("EmailApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("messages.sqlite")
    }()

    private static let db: OpaquePointer? = {
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
        return handle
    }()

    /// Loads only the most recent `recentLoadLimit` messages — bounded
    /// regardless of total mailbox size, so launch time doesn't grow
    /// forever the longer this app is used.
    static func load() -> [Message] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        sqlite3_prepare_v2(
            db, "SELECT json FROM messages ORDER BY received_at DESC LIMIT ?;", -1, &statement, nil)
        sqlite3_bind_int(statement, 1, Int32(recentLoadLimit))

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
    /// Every call site passes the *whole* in-memory array (a single star
    /// toggle re-upserts 1000+ unchanged rows too) — harmless for
    /// correctness, but real work, so it runs off the main thread. The UI
    /// already updated optimistically before this is called; nothing is
    /// waiting on it to finish.
    static func save(_ messages: [Message]) {
        guard !messages.isEmpty else { return }
        Task.detached(priority: .utility) {
            guard let db else { return }
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
    }

    static func clear() {
        guard let db else { return }
        sqlite3_exec(db, "DELETE FROM messages;", nil, nil, nil)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
