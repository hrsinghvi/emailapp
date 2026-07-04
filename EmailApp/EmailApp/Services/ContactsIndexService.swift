import Foundation
import Supabase
import SwiftUI
import os

struct Contact: Decodable, Identifiable, Hashable {
    let email: String
    let name: String
    let frequency: Int

    var id: String { email }

    /// Falls back to a humanized local-part when there's no known name yet
    /// (a recipient we've only ever seen as a bare email address).
    var displayName: String {
        guard !name.isEmpty else {
            let localPart = email.split(separator: "@").first.map(String.init) ?? email
            return localPart
                .split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
        return name
    }

    var initials: String {
        let source = displayName
        let parts = source.split(separator: " ").prefix(2).compactMap { $0.first }
        if !parts.isEmpty { return parts.map { String($0).uppercased() }.joined() }
        return String(email.prefix(1)).uppercased()
    }

    /// Deterministic per-email hue so the same contact always gets the same
    /// avatar color across the app, without needing a stored color column.
    var avatarColor: Color {
        let hash = email.unicodeScalars.reduce(UInt32(5381)) { ($0 << 5) &+ $0 &+ UInt32($1.value) }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.75)
    }
}

private struct ContactEntry: Encodable {
    let email: String
    let name: String
}

private struct UpsertContactsParams: Encodable {
    let entries: [ContactEntry]
}

/// Local contacts index built entirely from mail the app has already
/// synced — every sender and every To/Cc recipient seen across both
/// accounts, deduped by email, ranked by how often each has appeared.
/// Updated incrementally (one small upsert per batch of newly-synced
/// messages), never a full rebuild.
///
/// `search` is a synchronous filter over an in-memory cache rather than a
/// network round-trip per keystroke — the first version hit Supabase on
/// every character typed, which is exactly the 1-2s-per-keystroke lag this
/// was rewritten to fix. The cache is small (one row per person you've ever
/// emailed) and refreshed after every write, so it's never far from the
/// server's copy.
@MainActor
enum ContactsIndexService {
    private static var cache: [Contact] = []

    /// Call once at launch so the cache is warm before the user ever opens
    /// Compose.
    static func warmCache() async {
        await refreshCache()
    }

    private static func refreshCache() async {
        do {
            let response = try await SupabaseService.client
                .from("contacts")
                .select()
                .order("frequency", ascending: false)
                .execute()
            cache = try JSONDecoder().decode([Contact].self, from: response.data)
        } catch {
            AppLog.sync.error("Contacts cache refresh failed: \(error.localizedDescription)")
        }
    }

    /// Extracts participants from newly-synced messages and folds them into
    /// the index. Call with only the messages that are actually new (the
    /// caller already knows which ones those are from its own dedup pass)
    /// — calling this with the same message twice double-counts it.
    static func recordContacts(from messages: [Message]) async {
        guard !messages.isEmpty else { return }
        var entries: [ContactEntry] = []
        for message in messages {
            entries.append(ContactEntry(email: message.senderEmail, name: message.senderName))
            for recipient in message.toRecipients { entries.append(ContactEntry(email: recipient, name: "")) }
            for recipient in message.ccRecipients { entries.append(ContactEntry(email: recipient, name: "")) }
        }
        guard !entries.isEmpty else { return }
        do {
            try await SupabaseService.client
                .rpc("upsert_contacts", params: UpsertContactsParams(entries: entries))
                .execute()
            await refreshCache()
        } catch {
            AppLog.sync.error("Contacts index upsert failed: \(error.localizedDescription)")
        }
    }

    /// Matches against name or email, most-contacted first — backs the
    /// compose recipient autocomplete dropdown. Synchronous: no network
    /// wait, so it's safe to call on every keystroke.
    static func search(prefix: String, limit: Int = 6) -> [Contact] {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        return Array(
            cache.filter { $0.name.lowercased().contains(trimmed) || $0.email.lowercased().contains(trimmed) }
                .prefix(limit)
        )
    }
}
