import Foundation
import Supabase

/// Minimal JSON value box for the `jsonb` `args` column on
/// `mcp_pending_actions` — the shape differs per tool (send_email vs
/// archive_email), so a fixed Codable struct per row doesn't work.
enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let b = try? container.decode(Bool.self) { self = .bool(b); return }
        if let n = try? container.decode(Double.self) { self = .number(n); return }
        if let s = try? container.decode(String.self) { self = .string(s); return }
        if let a = try? container.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? container.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .object(let o): try container.encode(o)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
}

struct PendingAction: Decodable, Identifiable, Equatable {
    let id: UUID
    let tool: String
    let args: [String: JSONValue]
    let status: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, tool, args, status
        case createdAt = "created_at"
    }

    static func == (lhs: PendingAction, rhs: PendingAction) -> Bool { lhs.id == rhs.id }
}

struct MCPCallLogEntry: Decodable, Identifiable {
    let id: UUID
    let tool: String
    let result: String
    let detail: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, tool, result, detail
        case createdAt = "created_at"
    }
}

struct RemoteMCPSettings: Decodable {
    var mcpBearerToken: String
    var mcpRequireConfirmation: Bool
    var mcpEnabledTools: [String]

    enum CodingKeys: String, CodingKey {
        case mcpBearerToken = "mcp_bearer_token"
        case mcpRequireConfirmation = "mcp_require_confirmation"
        case mcpEnabledTools = "mcp_enabled_tools"
    }
}

/// Every known MCP tool — used to render the enable/disable checklist even
/// for tools currently disabled (so they're not just missing from the list).
enum MCPToolCatalog {
    static let all = [
        "get_recent_emails", "get_email_body", "search_emails", "send_email", "reply_email", "archive_email", "mark_read",
        "get_thread", "list_accounts", "search_by_sender", "summarize_thread", "extract_dates_deadlines",
        "get_unread_count", "save_draft", "get_message_metadata", "check_sender_reputation", "get_reply_context",
    ]
    static let writeTools: Set<String> = ["send_email", "reply_email", "archive_email", "mark_read", "save_draft"]
}

/// Reads/writes the `app_settings`, `mcp_pending_actions`, and
/// `mcp_call_log` tables directly via the anon Supabase client — same
/// trust model the rest of the app already uses (single-user, no auth
/// layer). This is the one source of truth the backend's MCP endpoint
/// also reads, so changes here take effect on the very next tool call,
/// no redeploy.
@MainActor
enum MCPSettingsService {
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func fetchSettings() async throws -> RemoteMCPSettings {
        let response = try await SupabaseService.client
            .from("app_settings")
            .select()
            .eq("id", value: true)
            .single()
            .execute()
        return try decoder.decode(RemoteMCPSettings.self, from: response.data)
    }

    static func setToolEnabled(_ tool: String, enabled: Bool, currentTools: [String]) async throws -> [String] {
        var tools = Set(currentTools)
        if enabled { tools.insert(tool) } else { tools.remove(tool) }
        let updated = Array(tools)
        try await SupabaseService.client
            .from("app_settings")
            .update(["mcp_enabled_tools": updated])
            .eq("id", value: true)
            .execute()
        return updated
    }

    static func setRequireConfirmation(_ value: Bool) async throws {
        try await SupabaseService.client
            .from("app_settings")
            .update(["mcp_require_confirmation": value])
            .eq("id", value: true)
            .execute()
    }

    /// Rotates the bearer token server-side — the old one stops working the
    /// instant this write commits, since `api/mcp.ts` checks this column on
    /// every request rather than a static env var.
    static func regenerateToken() async throws -> String {
        let newToken = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        try await SupabaseService.client
            .from("app_settings")
            .update(["mcp_bearer_token": newToken])
            .eq("id", value: true)
            .execute()
        return newToken
    }

    static func fetchPendingActions() async throws -> [PendingAction] {
        let response = try await SupabaseService.client
            .from("mcp_pending_actions")
            .select()
            .eq("status", value: "pending")
            .order("created_at", ascending: false)
            .execute()
        return try decoder.decode([PendingAction].self, from: response.data)
    }

    static func fetchCallLog(limit: Int = 50) async throws -> [MCPCallLogEntry] {
        let response = try await SupabaseService.client
            .from("mcp_call_log")
            .select()
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
        return try decoder.decode([MCPCallLogEntry].self, from: response.data)
    }

    /// Marks the pending row resolved and logs the outcome. `tool` comes
    /// from the caller's already-fetched `PendingAction` — no extra
    /// round-trip needed to know what it was for.
    static func resolvePendingAction(_ id: UUID, tool: String, approved: Bool) async throws {
        try await SupabaseService.client
            .from("mcp_pending_actions")
            .update(["status": approved ? "approved" : "rejected"])
            .eq("id", value: id.uuidString)
            .execute()
        try await SupabaseService.client
            .from("mcp_call_log")
            .insert(["tool": tool, "result": approved ? "approved" : "rejected"])
            .execute()
    }

    /// Streams every new pending action as it's inserted (a write tool call
    /// arriving while confirmation is required). Runs until cancelled.
    static func subscribeToPendingActions(onInsert: @escaping (PendingAction) -> Void) async {
        let channel = SupabaseService.client.channel("pending-actions-inserts")
        let insertions = channel.postgresChange(InsertAction.self, schema: "public", table: "mcp_pending_actions")
        try? await channel.subscribeWithError()
        for await insertion in insertions {
            guard let row = try? insertion.decodeRecord(as: PendingAction.self, decoder: decoder) else { continue }
            onInsert(row)
        }
    }
}
