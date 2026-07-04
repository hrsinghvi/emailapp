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
@MainActor
enum ContactsIndexService {
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
        } catch {
            AppLog.sync.error("Contacts index upsert failed: \(error.localizedDescription)")
        }
    }

    /// Matches against name or email, most-contacted first — backs the
    /// compose recipient autocomplete dropdown.
    static func search(prefix: String, limit: Int = 6) async -> [Contact] {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let escaped = trimmed.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        do {
            let response = try await SupabaseService.client
                .from("contacts")
                .select()
                .or("name.ilike.%\(escaped)%,email.ilike.%\(escaped)%")
                .order("frequency", ascending: false)
                .limit(limit)
                .execute()
            return try JSONDecoder().decode([Contact].self, from: response.data)
        } catch {
            AppLog.sync.error("Contacts search failed: \(error.localizedDescription)")
            return []
        }
    }
}
