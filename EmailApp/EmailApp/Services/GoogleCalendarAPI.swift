import CryptoKit
import Foundation

/// Direct Google Calendar REST (v3) calls — same shape as GmailAPI: calls
/// go straight from this app to Google using the OAuth token already
/// obtained for Mail (calendar.readonly + calendar.events are just
/// additional scopes on the same client), not proxied through the backend.
/// The backend's role for Calendar is the same as it is for Mail: push
/// notifications + upserting into Supabase for cross-device realtime, not
/// the read/write path the app itself uses.
enum GoogleCalendarAPI {
    enum CalendarError: LocalizedError {
        case unauthorized
        case requestFailed(Int, String)

        var errorDescription: String? {
            switch self {
            case .unauthorized: return "Google rejected the access token (401)."
            case .requestFailed(let code, let body): return "Google Calendar request failed (\(code)): \(body)"
            }
        }
    }

    private static let base = "https://www.googleapis.com/calendar/v3/calendars/primary/events"

    /// Lists events overlapping [from, to), paginating through Google's
    /// nextPageToken until exhausted.
    nonisolated static func listEvents(
        for account: Account, accessToken: String, from: Date, to: Date
    ) async throws -> [CalendarEvent] {
        let formatter = ISO8601DateFormatter()
        var events: [CalendarEvent] = []
        var pageToken: String?
        repeat {
            var comps = URLComponents(string: base)!
            comps.queryItems = [
                .init(name: "timeMin", value: formatter.string(from: from)),
                .init(name: "timeMax", value: formatter.string(from: to)),
                .init(name: "singleEvents", value: "true"),
                .init(name: "orderBy", value: "startTime"),
                .init(name: "maxResults", value: "250"),
            ] + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            let data = try await get(comps.url!.absoluteString, accessToken: accessToken)
            let response = try JSONDecoder().decode(ListResponse.self, from: data)
            events.append(contentsOf: response.items.compactMap { $0.toEvent(account: account) })
            pageToken = response.nextPageToken
        } while pageToken != nil
        return events
    }

    nonisolated static func createEvent(
        _ draft: CalendarEventDraft, for account: Account, accessToken: String
    ) async throws -> CalendarEvent {
        let raw = try await post(base, accessToken: accessToken, json: draft.toGoogleBody())
        let decoded = try JSONDecoder().decode(RawEvent.self, from: raw)
        guard let event = decoded.toEvent(account: account) else {
            throw CalendarError.requestFailed(-1, "created event missing start/end")
        }
        return event
    }

    nonisolated static func updateEvent(
        providerId: String, draft: CalendarEventDraft, for account: Account, accessToken: String
    ) async throws -> CalendarEvent {
        let raw = try await patch("\(base)/\(providerId)", accessToken: accessToken, json: draft.toGoogleBody())
        let decoded = try JSONDecoder().decode(RawEvent.self, from: raw)
        guard let event = decoded.toEvent(account: account) else {
            throw CalendarError.requestFailed(-1, "updated event missing start/end")
        }
        return event
    }

    nonisolated static func deleteEvent(providerId: String, accessToken: String) async throws {
        try await delete("\(base)/\(providerId)", accessToken: accessToken)
    }

    // MARK: - Decoding

    private nonisolated struct ListResponse: Decodable {
        let items: [RawEvent]
        let nextPageToken: String?
    }

    private nonisolated struct RawEvent: Decodable {
        struct EventDateTime: Decodable {
            let date: String?
            let dateTime: String?
        }
        struct Attendee: Decodable {
            let displayName: String?
            let email: String
            let responseStatus: String?
        }
        let id: String
        let summary: String?
        let description: String?
        let location: String?
        let start: EventDateTime?
        let end: EventDateTime?
        let recurrence: [String]?
        let attendees: [Attendee]?
        let htmlLink: String?
        let status: String?

        func toEvent(account: Account) -> CalendarEvent? {
            guard let start, let end else { return nil }
            let isAllDay = start.date != nil
            guard let startDate = Self.parse(start), let endDate = Self.parse(end) else { return nil }
            return CalendarEvent(
                id: UUID(stableFrom: "\(account.id.uuidString):\(id)"),
                accountId: account.id,
                provider: .gmail,
                providerId: id,
                title: summary ?? "(No title)",
                eventDescription: description ?? "",
                location: location ?? "",
                startDate: startDate,
                endDate: endDate,
                isAllDay: isAllDay,
                recurrenceRule: recurrence?.first,
                attendees: (attendees ?? []).map {
                    EventAttendee(name: $0.displayName ?? $0.email, email: $0.email, responseStatus: $0.responseStatus ?? "needsAction")
                },
                htmlLink: htmlLink,
                status: status ?? "confirmed"
            )
        }

        private static func parse(_ dt: EventDateTime) -> Date? {
            if let dateTime = dt.dateTime {
                return parseFlexibleISODate(dateTime)
            }
            if let date = dt.date {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                formatter.timeZone = TimeZone(identifier: "UTC")
                return formatter.date(from: date)
            }
            return nil
        }
    }

    // MARK: - Networking

    private nonisolated static func get(_ urlString: String, accessToken: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw CalendarError.requestFailed(-1, "bad url: \(urlString)") }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
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
        // Google returns 204 with empty body on successful delete, and 410
        // if it was already deleted server-side — both are fine.
        guard (200..<300).contains(http.statusCode) || http.statusCode == 410 else {
            throw CalendarError.requestFailed(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}

private nonisolated extension UUID {
    init(stableFrom string: String) {
        let bytes = Array(SHA256.hash(data: Data(string.utf8)).prefix(16))
        let raw = bytes.withUnsafeBytes { $0.load(as: uuid_t.self) }
        self = UUID(uuid: raw)
    }
}

/// Google emits fractional-second timestamps sometimes, not always.
private nonisolated func parseFlexibleISODate(_ string: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
}
