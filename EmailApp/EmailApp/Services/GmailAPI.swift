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
        try await fetchMessages(labelId: "INBOX", folder: "inbox", for: account, accessToken: accessToken, limit: limit)
    }

    /// Fetches SENT messages so the Sent folder in the sidebar has content.
    nonisolated static func fetchSent(
        for account: Account, accessToken: String, limit: Int = 25
    ) async throws -> [Message] {
        try await fetchMessages(labelId: "SENT", folder: "sent", for: account, accessToken: accessToken, limit: limit)
    }

    private nonisolated static func fetchMessages(
        labelId: String, folder: String, for account: Account, accessToken: String, limit: Int
    ) async throws -> [Message] {
        let ids = try await listMessageIds(labelId: labelId, accessToken: accessToken, limit: limit)

        return try await withThrowingTaskGroup(of: Message?.self) { group in
            var iterator = ids.makeIterator()
            let maxConcurrent = 8

            func addNext() {
                guard let id = iterator.next() else { return }
                group.addTask {
                    try await fetchMessage(id: id, account: account, accessToken: accessToken, folder: folder)
                }
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

    /// Gmail caps a single list call at 500 results — loops pageToken to
    /// gather more than that (e.g. a 2000-message backfill).
    private nonisolated static func listMessageIds(
        labelId: String, accessToken: String, limit: Int
    ) async throws -> [String] {
        struct ListResponse: Decodable {
            struct Ref: Decodable { let id: String }
            let messages: [Ref]?
            let nextPageToken: String?
        }
        var ids: [String] = []
        var pageToken: String?
        repeat {
            let remaining = limit - ids.count
            guard remaining > 0 else { break }
            var url = "\(base)/messages?labelIds=\(labelId)&maxResults=\(min(remaining, 500))"
            if let pageToken { url += "&pageToken=\(pageToken)" }
            let listData = try await get(url, accessToken: accessToken)
            let response = try JSONDecoder().decode(ListResponse.self, from: listData)
            ids.append(contentsOf: (response.messages ?? []).map(\.id))
            pageToken = response.nextPageToken
        } while pageToken != nil && ids.count < limit
        return ids
    }

    // MARK: - Mutations

    private nonisolated static func modifyLabels(
        id: String, accessToken: String, add: [String] = [], remove: [String] = []
    ) async throws {
        struct Body: Encodable { let addLabelIds: [String]; let removeLabelIds: [String] }
        _ = try await post(
            "\(base)/messages/\(id)/modify", accessToken: accessToken,
            json: Body(addLabelIds: add, removeLabelIds: remove))
    }

    nonisolated static func setRead(id: String, accessToken: String, read: Bool) async throws {
        if read {
            try await modifyLabels(id: id, accessToken: accessToken, remove: ["UNREAD"])
        } else {
            try await modifyLabels(id: id, accessToken: accessToken, add: ["UNREAD"])
        }
    }

    /// Gmail has no "archive" label — archiving just removes INBOX.
    nonisolated static func setArchived(id: String, accessToken: String) async throws {
        try await modifyLabels(id: id, accessToken: accessToken, remove: ["INBOX"])
    }

    /// Moves to Gmail's Trash (recoverable for 30 days) — not a permanent delete.
    nonisolated static func trash(id: String, accessToken: String) async throws {
        _ = try await post("\(base)/messages/\(id)/trash", accessToken: accessToken, json: EmptyEncodable())
    }

    /// Sends a brand-new, unthreaded message.
    nonisolated static func send(
        to: String, cc: String = "", bcc: String = "", subject: String, body: String, isHTML: Bool = false,
        attachments: [OutgoingAttachment] = [], accessToken: String
    ) async throws {
        let raw = buildRawMessage(to: to, cc: cc, bcc: bcc, subject: subject, body: body, isHTML: isHTML, attachments: attachments)
        try await sendRaw(raw, threadId: nil, accessToken: accessToken)
    }

    /// Replies to just the original sender, in-thread.
    nonisolated static func reply(
        to message: Message, cc: String = "", bcc: String = "", body: String, isHTML: Bool = false,
        attachments: [OutgoingAttachment] = [], accessToken: String
    ) async throws {
        try await sendThreadedReply(
            to: message, recipients: [message.senderEmail], cc: cc, bcc: bcc, body: body, isHTML: isHTML,
            attachments: attachments, accessToken: accessToken
        )
    }

    /// Replies to the sender plus every original To/Cc recipient (minus the
    /// account replying), in-thread.
    nonisolated static func replyAll(
        to message: Message, selfEmail: String, cc: String = "", bcc: String = "", body: String, isHTML: Bool = false,
        attachments: [OutgoingAttachment] = [], accessToken: String
    ) async throws {
        var seen = Set<String>()
        let recipients = ([message.senderEmail] + message.toRecipients + message.ccRecipients)
            .filter { seen.insert($0.lowercased()).inserted }
            .filter { $0.lowercased() != selfEmail.lowercased() }
        try await sendThreadedReply(
            to: message, recipients: recipients, cc: cc, bcc: bcc, body: body, isHTML: isHTML,
            attachments: attachments, accessToken: accessToken
        )
    }

    private nonisolated static func sendThreadedReply(
        to message: Message, recipients: [String], cc: String, bcc: String, body: String, isHTML: Bool,
        attachments: [OutgoingAttachment], accessToken: String
    ) async throws {
        var subject = message.subject
        if !subject.lowercased().hasPrefix("re:") { subject = "Re: \(subject)" }
        let references = [message.references, message.messageIdHeader]
            .compactMap { $0 }.joined(separator: " ")
        let raw = buildRawMessage(
            to: recipients.joined(separator: ", "), cc: cc, bcc: bcc, subject: subject, body: body, isHTML: isHTML,
            inReplyTo: message.messageIdHeader,
            references: references.isEmpty ? nil : references,
            attachments: attachments
        )
        try await sendRaw(raw, threadId: message.threadId, accessToken: accessToken)
    }

    private nonisolated static func buildRawMessage(
        to: String, cc: String = "", bcc: String = "", subject: String, body: String, isHTML: Bool = false,
        inReplyTo: String? = nil, references: String? = nil,
        attachments: [OutgoingAttachment] = []
    ) -> String {
        let bodyContentType = isHTML ? "text/html" : "text/plain"
        func recipientHeaders() -> String {
            var h = "To: \(to)\r\n"
            if !cc.isEmpty { h += "Cc: \(cc)\r\n" }
            if !bcc.isEmpty { h += "Bcc: \(bcc)\r\n" }
            return h
        }
        guard !attachments.isEmpty else {
            var headers = recipientHeaders() + "Subject: \(subject)\r\nContent-Type: \(bodyContentType); charset=UTF-8\r\n"
            if let inReplyTo { headers += "In-Reply-To: \(inReplyTo)\r\n" }
            if let references { headers += "References: \(references)\r\n" }
            return Data((headers + "\r\n" + body).utf8).base64URLEncoded()
        }

        let boundary = "boundary-\(UUID().uuidString)"
        var headers = recipientHeaders() + "Subject: \(subject)\r\nMIME-Version: 1.0\r\n"
        headers += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n"
        if let inReplyTo { headers += "In-Reply-To: \(inReplyTo)\r\n" }
        if let references { headers += "References: \(references)\r\n" }

        var mime = "--\(boundary)\r\nContent-Type: \(bodyContentType); charset=UTF-8\r\n\r\n\(body)\r\n"
        for attachment in attachments {
            let encoded = attachment.data.base64EncodedString(
                options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]
            )
            mime += "--\(boundary)\r\n"
            mime += "Content-Type: \(attachment.mimeType); name=\"\(attachment.filename)\"\r\n"
            mime += "Content-Disposition: attachment; filename=\"\(attachment.filename)\"\r\n"
            mime += "Content-Transfer-Encoding: base64\r\n\r\n\(encoded)\r\n"
        }
        mime += "--\(boundary)--"

        return Data((headers + "\r\n" + mime).utf8).base64URLEncoded()
    }

    private nonisolated static func sendRaw(_ raw: String, threadId: String?, accessToken: String) async throws {
        struct Body: Encodable { let raw: String; let threadId: String? }
        _ = try await post(
            "\(base)/messages/send", accessToken: accessToken, json: Body(raw: raw, threadId: threadId))
    }

    // MARK: - Attachments

    /// Fetches the raw bytes of a single attachment on demand (never pulled
    /// in bulk with the message list).
    nonisolated static func fetchAttachmentData(
        messageId: String, attachmentId: String, accessToken: String
    ) async throws -> Data {
        struct AttachmentBody: Decodable { let data: String }
        let data = try await get(
            "\(base)/messages/\(messageId)/attachments/\(attachmentId)", accessToken: accessToken)
        let decoded = try JSONDecoder().decode(AttachmentBody.self, from: data)
        guard let raw = RawMessage.decodeBase64URLData(decoded.data) else {
            throw GmailError.requestFailed(-1, "bad attachment data")
        }
        return raw
    }

    // MARK: - Single message

    private nonisolated static func fetchMessage(
        id: String, account: Account, accessToken: String, folder: String
    ) async throws -> Message {
        let data = try await get("\(base)/messages/\(id)?format=full", accessToken: accessToken)
        return try JSONDecoder().decode(RawMessage.self, from: data).toMessage(account: account, folder: folder)
    }

    /// Labels only (no body/headers) — much cheaper than a full fetch, for
    /// re-categorizing mail that was already synced before this app started
    /// reading Gmail's real category label instead of guessing one.
    nonisolated static func fetchCategory(id: String, accessToken: String) async throws -> MessageCategory? {
        struct LabelsOnly: Decodable { let labelIds: [String]? }
        let data = try await get("\(base)/messages/\(id)?format=minimal", accessToken: accessToken)
        let labelIds = try JSONDecoder().decode(LabelsOnly.self, from: data).labelIds
        return RawMessage.category(fromLabels: labelIds)
    }

    private nonisolated struct RawMessage: Decodable {
        let id: String
        let threadId: String?
        let snippet: String?
        let internalDate: String?
        let labelIds: [String]?
        let payload: Payload?

        struct Payload: Decodable {
            let mimeType: String?
            let filename: String?
            let headers: [Header]?
            let body: Body?
            let parts: [Payload]?
        }
        struct Header: Decodable { let name: String; let value: String }
        struct Body: Decodable { let data: String?; let attachmentId: String?; let size: Int? }

        func toMessage(account: Account, folder: String) -> Message {
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
                providerId: id,
                threadId: threadId,
                messageIdHeader: header("Message-ID").isEmpty ? nil : header("Message-ID"),
                references: header("References").isEmpty ? nil : header("References"),
                senderName: name,
                senderEmail: email,
                subject: header("Subject"),
                snippet: (snippet ?? "").decodingHTMLEntities(),
                body: Self.extractBody(payload) ?? (snippet ?? ""),
                htmlBody: Self.extractRawHTML(payload),
                receivedAt: date,
                isRead: !(labelIds?.contains("UNREAD") ?? false),
                folder: folder,
                toRecipients: Self.parseAddressList(header("To")),
                ccRecipients: Self.parseAddressList(header("Cc")),
                attachments: Self.extractAttachments(payload),
                providerCategory: Self.category(fromLabels: labelIds)
            )
        }

        /// Gmail's own inbox-tab classification, straight from the
        /// message's labels — matches what the Gmail web/app UI shows
        /// exactly, instead of this app re-guessing via a local heuristic.
        fileprivate static func category(fromLabels labelIds: [String]?) -> MessageCategory? {
            guard let labelIds else { return nil }
            if labelIds.contains("CATEGORY_PERSONAL") { return .primary }
            if labelIds.contains("CATEGORY_SOCIAL") { return .social }
            if labelIds.contains("CATEGORY_PROMOTIONS") { return .promotions }
            if labelIds.contains("CATEGORY_UPDATES") { return .updates }
            if labelIds.contains("CATEGORY_FORUMS") { return .forums }
            return nil
        }

        /// Walks the MIME tree for the raw (unstripped) text/html part, if any
        /// — preferred for reading-pane display over the plain-text `body`.
        static func extractRawHTML(_ payload: Payload?) -> String? {
            guard let payload else { return nil }
            if payload.mimeType == "text/html", let d = payload.body?.data, let s = decodeBase64URL(d) {
                return s
            }
            if let parts = payload.parts {
                for p in parts where p.mimeType == "text/html" {
                    if let d = p.body?.data, let s = decodeBase64URL(d) { return s }
                }
                for p in parts {
                    if let s = extractRawHTML(p) { return s }
                }
            }
            return nil
        }

        static func parseAddressList(_ raw: String) -> [String] {
            guard !raw.isEmpty else { return [] }
            return raw.split(separator: ",").map { parseFrom(String($0)).email }
        }

        /// Walks the MIME part tree collecting parts that carry a filename +
        /// attachmentId — the primary text/plain or text/html body parts have
        /// neither, so they're naturally excluded.
        static func extractAttachments(_ payload: Payload?) -> [Attachment] {
            guard let payload else { return [] }
            var results: [Attachment] = []
            if let filename = payload.filename, !filename.isEmpty, let attachmentId = payload.body?.attachmentId {
                results.append(
                    Attachment(
                        id: attachmentId, filename: filename,
                        mimeType: payload.mimeType ?? "application/octet-stream",
                        sizeBytes: payload.body?.size ?? 0
                    )
                )
            }
            for part in payload.parts ?? [] {
                results.append(contentsOf: extractAttachments(part))
            }
            return results
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
            guard let data = decodeBase64URLData(s) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        static func decodeBase64URLData(_ s: String) -> Data? {
            var b64 = s.replacingOccurrences(of: "-", with: "+")
                       .replacingOccurrences(of: "_", with: "/")
            while b64.count % 4 != 0 { b64 += "=" }
            return Data(base64Encoded: b64)
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

    private nonisolated static func post<T: Encodable>(
        _ urlString: String, accessToken: String, json: T
    ) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw GmailError.requestFailed(-1, "bad url: \(urlString)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(json)
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

private nonisolated struct EmptyEncodable: Encodable {}

private nonisolated extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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
