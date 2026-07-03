import CryptoKit
import Foundation

/// Direct Microsoft Graph (v1.0) calls for Outlook mail.
enum GraphAPI {
    enum GraphError: LocalizedError {
        case unauthorized
        case requestFailed(Int, String)

        var errorDescription: String? {
            switch self {
            case .unauthorized: return "Microsoft Graph rejected the access token (401)."
            case .requestFailed(let code, let body): return "Graph request failed (\(code)): \(body)"
            }
        }
    }

    private nonisolated static let base = "https://graph.microsoft.com/v1.0"

    /// Fresh formatters per call — ISO8601DateFormatter isn't Sendable, so it
    /// can't be a shared static under this module's MainActor-by-default isolation.
    private nonisolated static func parseReceivedDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    /// The authenticated user's email address.
    nonisolated static func getProfile(accessToken: String) async throws -> String {
        struct Me: Decodable { let mail: String?; let userPrincipalName: String? }
        let data = try await get("\(base)/me", accessToken: accessToken)
        let me = try JSONDecoder().decode(Me.self, from: data)
        guard let email = me.mail ?? me.userPrincipalName else {
            throw GraphError.requestFailed(-1, "Graph profile had no mail or userPrincipalName")
        }
        return email
    }

    /// Fetches inbox messages, newest first.
    nonisolated static func fetchInbox(
        for account: Account, accessToken: String, limit: Int = 25
    ) async throws -> [Message] {
        try await fetchFolder(wellKnownName: "inbox", folder: "inbox", for: account, accessToken: accessToken, limit: limit)
    }

    /// Fetches Sent Items so the Sent folder in the sidebar has content.
    nonisolated static func fetchSent(
        for account: Account, accessToken: String, limit: Int = 25
    ) async throws -> [Message] {
        try await fetchFolder(wellKnownName: "sentitems", folder: "sent", for: account, accessToken: accessToken, limit: limit)
    }

    private nonisolated static func fetchFolder(
        wellKnownName: String, folder: String, for account: Account, accessToken: String, limit: Int
    ) async throws -> [Message] {
        var comps = URLComponents(string: "\(base)/me/mailFolders/\(wellKnownName)/messages")!
        comps.queryItems = [
            .init(name: "$top", value: String(limit)),
            .init(name: "$orderby", value: "receivedDateTime desc"),
            .init(
                name: "$select",
                value: "id,subject,bodyPreview,body,from,receivedDateTime,isRead,conversationId,"
                    + "toRecipients,ccRecipients,hasAttachments"
            ),
        ]
        struct ListResponse: Decodable { let value: [RawMessage] }
        let data = try await get(comps.url!.absoluteString, accessToken: accessToken)
        let raw = try JSONDecoder().decode(ListResponse.self, from: data).value
        var messages = raw.map { $0.toMessage(account: account, folder: folder) }

        // Attachment bytes aren't in the list response — fetch metadata only
        // (name/type/size) for messages that actually have any, concurrently.
        try await withThrowingTaskGroup(of: (Int, [Attachment]).self) { group in
            for (index, message) in raw.enumerated() where message.hasAttachments == true {
                group.addTask {
                    let attachments = try await fetchAttachments(messageId: message.id, accessToken: accessToken)
                    return (index, attachments)
                }
            }
            while let (index, attachments) = try await group.next() {
                messages[index].attachments = attachments
            }
        }
        return messages
    }

    // MARK: - Mutations

    nonisolated static func setRead(id: String, accessToken: String, read: Bool) async throws {
        struct Body: Encodable { let isRead: Bool }
        _ = try await patch("\(base)/me/messages/\(id)", accessToken: accessToken, json: Body(isRead: read))
    }

    /// Graph has a well-known "archive" mail folder; move the message into it.
    nonisolated static func setArchived(id: String, accessToken: String) async throws {
        struct Body: Encodable { let destinationId: String }
        _ = try await post(
            "\(base)/me/messages/\(id)/move", accessToken: accessToken, json: Body(destinationId: "archive"))
    }

    private nonisolated struct GraphAttachment: Encodable {
        let odataType = "#microsoft.graph.fileAttachment"
        let name: String
        let contentType: String
        let contentBytes: String

        enum CodingKeys: String, CodingKey {
            case odataType = "@odata.type"
            case name, contentType, contentBytes
        }
    }

    private nonisolated static func graphAttachments(_ attachments: [OutgoingAttachment]) -> [GraphAttachment] {
        attachments.map {
            GraphAttachment(name: $0.filename, contentType: $0.mimeType, contentBytes: $0.data.base64EncodedString())
        }
    }

    /// Sends a brand-new message.
    nonisolated static func send(
        to: String, subject: String, body: String,
        attachments: [OutgoingAttachment] = [], accessToken: String
    ) async throws {
        struct Recipient: Encodable { let emailAddress: Addr }
        struct Addr: Encodable { let address: String }
        struct Content: Encodable { let contentType: String; let content: String }
        struct OutMessage: Encodable {
            let subject: String; let body: Content; let toRecipients: [Recipient]
            let attachments: [GraphAttachment]?
        }
        struct SendMailRequest: Encodable { let message: OutMessage; let saveToSentItems: Bool }
        let payload = SendMailRequest(
            message: OutMessage(
                subject: subject,
                body: Content(contentType: "Text", content: body),
                toRecipients: [Recipient(emailAddress: Addr(address: to))],
                attachments: attachments.isEmpty ? nil : graphAttachments(attachments)
            ),
            saveToSentItems: true
        )
        _ = try await post("\(base)/me/sendMail", accessToken: accessToken, json: payload)
    }

    /// Graph's /reply endpoint threads (References/In-Reply-To/conversationId) automatically.
    nonisolated static func reply(
        to message: Message, body: String,
        attachments: [OutgoingAttachment] = [], accessToken: String
    ) async throws {
        try await sendReply(
            endpoint: "reply", message: message, body: body, attachments: attachments, accessToken: accessToken)
    }

    /// Graph's /replyAll endpoint replies to the sender plus every original
    /// To/Cc recipient automatically — no need to reconstruct the list.
    nonisolated static func replyAll(
        to message: Message, body: String,
        attachments: [OutgoingAttachment] = [], accessToken: String
    ) async throws {
        try await sendReply(
            endpoint: "replyAll", message: message, body: body, attachments: attachments, accessToken: accessToken)
    }

    private nonisolated static func sendReply(
        endpoint: String, message: Message, body: String,
        attachments: [OutgoingAttachment], accessToken: String
    ) async throws {
        guard attachments.isEmpty else {
            // Graph's /reply and /replyAll only take a comment string, no
            // attachments param — create the reply draft, attach files to
            // it, then send the draft.
            let createEndpoint = endpoint == "reply" ? "createReply" : "createReplyAll"
            struct CreateReplyBody: Encodable { let comment: String }
            let draftData = try await post(
                "\(base)/me/messages/\(message.providerId)/\(createEndpoint)",
                accessToken: accessToken, json: CreateReplyBody(comment: body)
            )
            struct Draft: Decodable { let id: String }
            let draft = try JSONDecoder().decode(Draft.self, from: draftData)
            for attachment in graphAttachments(attachments) {
                _ = try await post(
                    "\(base)/me/messages/\(draft.id)/attachments", accessToken: accessToken, json: attachment)
            }
            _ = try await post("\(base)/me/messages/\(draft.id)/send", accessToken: accessToken, json: EmptyBody())
            return
        }
        struct Body: Encodable { let comment: String }
        _ = try await post(
            "\(base)/me/messages/\(message.providerId)/\(endpoint)", accessToken: accessToken, json: Body(comment: body))
    }

    private nonisolated struct EmptyBody: Encodable {}

    // MARK: - Attachments

    nonisolated static func fetchAttachments(messageId: String, accessToken: String) async throws -> [Attachment] {
        struct ListResponse: Decodable {
            struct Att: Decodable { let id: String; let name: String; let contentType: String?; let size: Int? }
            let value: [Att]
        }
        let data = try await get(
            "\(base)/me/messages/\(messageId)/attachments?$select=id,name,contentType,size", accessToken: accessToken)
        return try JSONDecoder().decode(ListResponse.self, from: data).value.map {
            Attachment(id: $0.id, filename: $0.name, mimeType: $0.contentType ?? "application/octet-stream", sizeBytes: $0.size ?? 0)
        }
    }

    nonisolated static func fetchAttachmentData(
        messageId: String, attachmentId: String, accessToken: String
    ) async throws -> Data {
        struct FileAttachment: Decodable { let contentBytes: String }
        let data = try await get(
            "\(base)/me/messages/\(messageId)/attachments/\(attachmentId)", accessToken: accessToken)
        let decoded = try JSONDecoder().decode(FileAttachment.self, from: data)
        guard let raw = Data(base64Encoded: decoded.contentBytes) else {
            throw GraphError.requestFailed(-1, "bad attachment data")
        }
        return raw
    }

    // MARK: - Wire model

    private nonisolated struct RawMessage: Decodable {
        struct EmailAddress: Decodable { let name: String?; let address: String? }
        struct Recipient: Decodable { let emailAddress: EmailAddress? }
        struct From: Decodable { let emailAddress: EmailAddress? }
        struct Body: Decodable { let contentType: String?; let content: String? }

        let id: String
        let subject: String?
        let bodyPreview: String?
        let body: Body?
        let from: From?
        let receivedDateTime: String?
        let isRead: Bool?
        let conversationId: String?
        let toRecipients: [Recipient]?
        let ccRecipients: [Recipient]?
        let hasAttachments: Bool?

        func toMessage(account: Account, folder: String) -> Message {
            let senderName = from?.emailAddress?.name ?? from?.emailAddress?.address ?? ""
            let senderEmail = from?.emailAddress?.address ?? ""
            let date = receivedDateTime.flatMap { GraphAPI.parseReceivedDate($0) } ?? Date()
            let plainBody: String = {
                guard let body else { return bodyPreview ?? "" }
                if body.contentType?.lowercased() == "html" {
                    return (body.content ?? "").strippingHTML()
                }
                return body.content ?? bodyPreview ?? ""
            }()
            return Message(
                id: UUID(stableFrom: id),
                accountId: account.id,
                provider: .outlook,
                providerId: id,
                threadId: conversationId,
                messageIdHeader: nil,
                references: nil,
                senderName: senderName.isEmpty ? senderEmail : senderName,
                senderEmail: senderEmail,
                subject: subject ?? "",
                snippet: (bodyPreview ?? "").decodingHTMLEntities(),
                body: plainBody,
                receivedAt: date,
                isRead: isRead ?? true,
                folder: folder,
                toRecipients: (toRecipients ?? []).compactMap { $0.emailAddress?.address },
                ccRecipients: (ccRecipients ?? []).compactMap { $0.emailAddress?.address }
            )
        }
    }

    // MARK: - Networking

    private nonisolated static func get(_ urlString: String, accessToken: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw GraphError.requestFailed(-1, "bad url: \(urlString)")
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GraphError.requestFailed(-1, "no HTTP response")
        }
        if http.statusCode == 401 { throw GraphError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw GraphError.requestFailed(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private nonisolated static func send<T: Encodable>(
        _ urlString: String, method: String, accessToken: String, json: T
    ) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw GraphError.requestFailed(-1, "bad url: \(urlString)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(json)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GraphError.requestFailed(-1, "no HTTP response")
        }
        if http.statusCode == 401 { throw GraphError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw GraphError.requestFailed(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private nonisolated static func post<T: Encodable>(
        _ urlString: String, accessToken: String, json: T
    ) async throws -> Data {
        try await send(urlString, method: "POST", accessToken: accessToken, json: json)
    }

    private nonisolated static func patch<T: Encodable>(
        _ urlString: String, accessToken: String, json: T
    ) async throws -> Data {
        try await send(urlString, method: "PATCH", accessToken: accessToken, json: json)
    }
}

private nonisolated extension UUID {
    /// Deterministic UUID from a Graph message id so re-fetches don't duplicate.
    init(stableFrom string: String) {
        let bytes = Array(SHA256.hash(data: Data(string.utf8)).prefix(16))
        let raw = bytes.withUnsafeBytes { $0.load(as: uuid_t.self) }
        self = UUID(uuid: raw)
    }
}

private nonisolated extension String {
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
