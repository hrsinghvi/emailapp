import CryptoKit
import Foundation

/// Direct Gmail REST (v1) calls. `nonisolated` so message fetches run
/// concurrently off the main actor.
enum GmailAPI {
    enum GmailError: LocalizedError {
        case unauthorized
        case requestFailed(Int, String)

        var errorDescription: String? {
            switch self {
            case .unauthorized: return "Gmail rejected the access token (401)."
            case .requestFailed(let code, let body): return "Gmail request failed (\(code)): \(body)"
            }
        }
    }

    private static let base = "https://gmail.googleapis.com/gmail/v1/users/me"

    /// The authenticated user's email address.
    nonisolated static func getProfile(accessToken: String) async throws -> String {
        struct Profile: Decodable { let emailAddress: String }
        let data = try await get("\(base)/profile", accessToken: accessToken)
        return try JSONDecoder().decode(Profile.self, from: data).emailAddress
    }

    /// Fetches INBOX messages, decoding each concurrently (capped at 5 in flight).
    nonisolated static func fetchInbox(
        for account: Account, accessToken: String, limit: Int = 25
    ) async throws -> [Message] {
        struct ListResponse: Decodable {
            struct Ref: Decodable { let id: String }
            let messages: [Ref]?
        }
        let listData = try await get(
            "\(base)/messages?labelIds=INBOX&maxResults=\(limit)", accessToken: accessToken)
        let ids = (try JSONDecoder().decode(ListResponse.self, from: listData).messages ?? []).map(\.id)

        return try await withThrowingTaskGroup(of: Message?.self) { group in
            var iterator = ids.makeIterator()
            let maxConcurrent = 5

            func addNext() {
                guard let id = iterator.next() else { return }
                group.addTask { try await fetchMessage(id: id, account: account, accessToken: accessToken) }
            }
            for _ in 0..<min(maxConcurrent, ids.count) { addNext() }

            var results: [Message] = []
            while let msg = try await group.next() {
                if let msg { results.append(msg) }
                addNext()
            }
            return results.sorted { $0.receivedAt > $1.receivedAt }
        }
    }

    // MARK: - Single message

    private nonisolated static func fetchMessage(
        id: String, account: Account, accessToken: String
    ) async throws -> Message {
        let data = try await get("\(base)/messages/\(id)?format=full", accessToken: accessToken)
        return try JSONDecoder().decode(RawMessage.self, from: data).toMessage(account: account)
    }

    private nonisolated struct RawMessage: Decodable {
        let id: String
        let snippet: String?
        let internalDate: String?
        let labelIds: [String]?
        let payload: Payload?

        struct Payload: Decodable {
            let mimeType: String?
            let headers: [Header]?
            let body: Body?
            let parts: [Payload]?
        }
        struct Header: Decodable { let name: String; let value: String }
        struct Body: Decodable { let data: String? }

        func toMessage(account: Account) -> Message {
            let headers = payload?.headers ?? []
            func header(_ name: String) -> String {
                headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
            }
            let (name, email) = Self.parseFrom(header("From"))
            let date: Date = {
                if let ms = internalDate, let millis = Double(ms) {
                    return Date(timeIntervalSince1970: millis / 1000)
                }
                return Date()
            }()
            return Message(
                id: UUID(stableFrom: id),
                accountId: account.id,
                provider: .gmail,
                senderName: name,
                senderEmail: email,
                subject: header("Subject"),
                snippet: (snippet ?? "").decodingHTMLEntities(),
                // ponytail: full body when parseable, else the snippet. Good enough
                // for reading-pane display; richer HTML rendering can come later.
                body: Self.extractBody(payload) ?? (snippet ?? ""),
                receivedAt: date,
                isRead: !(labelIds?.contains("UNREAD") ?? false),
                isArchived: false,
                categoryId: nil,
                folder: "inbox"
            )
        }

        /// Prefers text/plain anywhere in the MIME tree; falls back to stripped text/html.
        static func extractBody(_ payload: Payload?) -> String? {
            guard let payload else { return nil }
            if payload.mimeType == "text/plain",
               let d = payload.body?.data, let s = decodeBase64URL(d) { return s }
            if let parts = payload.parts {
                for p in parts where p.mimeType == "text/plain" {
                    if let d = p.body?.data, let s = decodeBase64URL(d) { return s }
                }
                for p in parts { if let s = extractBody(p) { return s } }
            }
            if payload.mimeType == "text/html",
               let d = payload.body?.data, let html = decodeBase64URL(d) {
                return html.strippingHTML()
            }
            return nil
        }

        static func decodeBase64URL(_ s: String) -> String? {
            var b64 = s.replacingOccurrences(of: "-", with: "+")
                       .replacingOccurrences(of: "_", with: "/")
            while b64.count % 4 != 0 { b64 += "=" }
            guard let data = Data(base64Encoded: b64) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        static func parseFrom(_ raw: String) -> (name: String, email: String) {
            if let open = raw.firstIndex(of: "<"), let close = raw.firstIndex(of: ">"), open < close {
                let email = String(raw[raw.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                let name = String(raw[..<open])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return (name.isEmpty ? email : name, email)
            }
            let email = raw.trimmingCharacters(in: .whitespaces)
            return (email, email)
        }
    }

    // MARK: - Networking

    private nonisolated static func get(_ urlString: String, accessToken: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw GmailError.requestFailed(-1, "bad url: \(urlString)")
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GmailError.requestFailed(-1, "no HTTP response")
        }
        if http.statusCode == 401 { throw GmailError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw GmailError.requestFailed(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}

private nonisolated extension UUID {
    /// Deterministic UUID from a Gmail message id so re-fetches don't duplicate.
    init(stableFrom string: String) {
        let bytes = Array(SHA256.hash(data: Data(string.utf8)).prefix(16))
        let raw = bytes.withUnsafeBytes { $0.load(as: uuid_t.self) }
        self = UUID(uuid: raw)
    }
}

private nonisolated extension String {
    // ponytail: regex tag-strip, not a real HTML parser. Fine for plain-text
    // display fallback; swap for AttributedString if rich rendering is needed.
    func strippingHTML() -> String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .decodingHTMLEntities()
            .replacingOccurrences(of: "\n[ \\t]*\n[ \\t\\n]*", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func decodingHTMLEntities() -> String {
        var s = self
        for (entity, char) in [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "),
        ] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s
    }
}
