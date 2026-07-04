import CryptoKit
import Foundation

/// Direct Microsoft Graph calendar calls — same shape as GraphAPI. Every
/// request sends `Prefer: outlook.timezone="UTC"`, which makes Graph
/// normalize every date/time field in its response to UTC instead of
/// whatever timezone the event was created in — without that, parsing
/// Graph's dateTime+timeZone pair correctly would need a full Windows
/// timezone-name table, which isn't worth the complexity here.
enum GraphCalendarAPI {
    enum CalendarError: LocalizedError {
        case unauthorized
        case requestFailed(Int, String)

        var errorDescription: String? {
            switch self {
            case .unauthorized: return "Microsoft Graph rejected the access token (401)."
            case .requestFailed(let code, let body): return "Graph Calendar request failed (\(code)): \(body)"
            }
        }
    }

    private static let base = "https://graph.microsoft.com/v1.0/me"

    /// Uses calendarView (not /events) so recurring events are already
    /// expanded into individual occurrences within the range, matching
    /// Google's singleEvents=true.
    nonisolated static func listEvents(
        for account: Account, accessToken: String, from: Date, to: Date
    ) async throws -> [CalendarEvent] {
        let formatter = ISO8601DateFormatter()
        var events: [CalendarEvent] = []
        var nextURL: String? = {
            var comps = URLComponents(string: "\(base)/calendarView")!
            comps.queryItems = [
                .init(name: "startDateTime", value: formatter.string(from: from)),
                .init(name: "endDateTime", value: formatter.string(from: to)),
                .init(name: "$top", value: "250"),
                .init(name: "$select", value: "id,subject,body,location,start,end,isAllDay,attendees,webLink,isCancelled,recurrence"),
            ]
            return comps.url!.absoluteString
        }()

        while let url = nextURL {
            struct ListResponse: Decodable {
                let value: [RawEvent]
                let nextLink: String?
                enum CodingKeys: String, CodingKey {
                    case value
                    case nextLink = "@odata.nextLink"
                }
            }
            let data = try await get(url, accessToken: accessToken)
            let response = try JSONDecoder().decode(ListResponse.self, from: data)
            events.append(contentsOf: response.value.compactMap { $0.toEvent(account: account) })
            nextURL = response.nextLink
        }
        return events
    }

    nonisolated static func createEvent(
        _ draft: CalendarEventDraft, for account: Account, accessToken: String
    ) async throws -> CalendarEvent {
        let raw = try await post("\(base)/events", accessToken: accessToken, json: draft.toGraphBody())
        let decoded = try JSONDecoder().decode(RawEvent.self, from: raw)
        guard let event = decoded.toEvent(account: account) else {
            throw CalendarError.requestFailed(-1, "created event missing start/end")
        }
        return event
    }

    nonisolated static func updateEvent(
        providerId: String, draft: CalendarEventDraft, for account: Account, accessToken: String
    ) async throws -> CalendarEvent {
        let raw = try await patch("\(base)/events/\(providerId)", accessToken: accessToken, json: draft.toGraphBody())
        let decoded = try JSONDecoder().decode(RawEvent.self, from: raw)
        guard let event = decoded.toEvent(account: account) else {
            throw CalendarError.requestFailed(-1, "updated event missing start/end")
        }
        return event
    }

    nonisolated static func deleteEvent(providerId: String, accessToken: String) async throws {
        try await delete("\(base)/events/\(providerId)", accessToken: accessToken)
    }

    // MARK: - Decoding

    private nonisolated struct RawEvent: Decodable {
        struct BodyContent: Decodable { let content: String? }
        struct Location: Decodable { let displayName: String? }
        struct DateTimeZone: Decodable { let dateTime: String?; let timeZone: String? }
        struct EmailAddress: Decodable { let address: String; let name: String? }
        struct AttendeeStatus: Decodable { let response: String? }
        struct Attendee: Decodable { let emailAddress: EmailAddress; let status: AttendeeStatus? }

        let id: String
        let subject: String?
        let body: BodyContent?
        let location: Location?
        let start: DateTimeZone?
        let end: DateTimeZone?
        let isAllDay: Bool?
        let attendees: [Attendee]?
        let webLink: String?
        let isCancelled: Bool?
        let recurrence: RecurrencePattern?

        struct RecurrencePattern: Decodable {}

        func toEvent(account: Account) -> CalendarEvent? {
            guard let startRaw = start?.dateTime, let endRaw = end?.dateTime else { return nil }
            // Prefer: outlook.timezone="UTC" means these are always UTC —
            // Graph just omits the "Z" suffix, so append it before parsing.
            guard let startDate = parseUTC(startRaw), let endDate = parseUTC(endRaw) else { return nil }
            return CalendarEvent(
                id: UUID(stableFrom: "\(account.id.uuidString):\(id)"),
                accountId: account.id,
                provider: .outlook,
                providerId: id,
                title: subject ?? "(No title)",
                eventDescription: (body?.content ?? "").strippingHTML(),
                location: location?.displayName ?? "",
                startDate: startDate,
                endDate: endDate,
                isAllDay: isAllDay ?? false,
                // Graph's recurrence is a structured object, not an RRULE
                // string — recording presence only, not the full pattern.
                recurrenceRule: recurrence != nil ? "RECURRING" : nil,
                attendees: (attendees ?? []).map {
                    EventAttendee(
                        name: $0.emailAddress.name ?? $0.emailAddress.address,
                        email: $0.emailAddress.address,
                        responseStatus: $0.status?.response ?? "none"
                    )
                },
                htmlLink: webLink,
                status: (isCancelled ?? false) ? "cancelled" : "confirmed"
            )
        }
    }

    // MARK: - Networking

    private nonisolated static func get(_ urlString: String, accessToken: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw CalendarError.requestFailed(-1, "bad url: \(urlString)") }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("outlook.timezone=\"UTC\"", forHTTPHeaderField: "Prefer")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw CalendarError.requestFailed(-1, "no HTTP response") }
        if http.statusCode == 401 { throw CalendarError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw CalendarError.requestFailed(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private nonisolated static func send<T: Encodable>(
        _ urlString: String, method: String, accessToken: String, json: T
    ) async throws -> Data {
        guard let url = URL(string: urlString) else { throw CalendarError.requestFailed(-1, "bad url: \(urlString)") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("outlook.timezone=\"UTC\"", forHTTPHeaderField: "Prefer")
        req.httpBody = try JSONEncoder().encode(json)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw CalendarError.requestFailed(-1, "no HTTP response") }
        if http.statusCode == 401 { throw CalendarError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw CalendarError.requestFailed(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private nonisolated static func post<T: Encodable>(_ urlString: String, accessToken: String, json: T) async throws -> Data {
        try await send(urlString, method: "POST", accessToken: accessToken, json: json)
    }

    private nonisolated static func patch<T: Encodable>(_ urlString: String, accessToken: String, json: T) async throws -> Data {
        try await send(urlString, method: "PATCH", accessToken: accessToken, json: json)
    }

    private nonisolated static func delete(_ urlString: String, accessToken: String) async throws {
        guard let url = URL(string: urlString) else { throw CalendarError.requestFailed(-1, "bad url: \(urlString)") }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw CalendarError.requestFailed(-1, "no HTTP response") }
        if http.statusCode == 401 { throw CalendarError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw CalendarError.requestFailed(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}

private nonisolated func parseUTC(_ graphDateTime: String) -> Date? {
    let withZ = graphDateTime.hasSuffix("Z") ? graphDateTime : "\(graphDateTime)Z"
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: withZ) ?? ISO8601DateFormatter().date(from: withZ)
}

private nonisolated extension UUID {
    init(stableFrom string: String) {
        let bytes = Array(SHA256.hash(data: Data(string.utf8)).prefix(16))
        let raw = bytes.withUnsafeBytes { $0.load(as: uuid_t.self) }
        self = UUID(uuid: raw)
    }
}

private nonisolated extension String {
    func strippingHTML() -> String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
