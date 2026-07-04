import Foundation

struct EventAttendee: Codable, Hashable {
    let name: String
    let email: String
    var responseStatus: String = "needsAction"
}

struct CalendarEvent: Identifiable, Hashable, Codable {
    let id: UUID
    let accountId: UUID
    let provider: Provider
    /// Raw provider-side id (Google eventId / Graph event id) — needed for
    /// update/delete calls, since `id` above is a derived stable UUID for
    /// SwiftUI identity.
    let providerId: String
    var title: String
    var eventDescription: String
    var location: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var recurrenceRule: String?
    var attendees: [EventAttendee] = []
    /// Link to open the event in Google Calendar / Outlook Calendar on the
    /// web — surfaced for the inline "linked event" card in a mail thread.
    var htmlLink: String?
    var status: String = "confirmed"

    /// Multi-day/all-day spans render as one block per day in month view.
    var spansMultipleDays: Bool {
        !Calendar.current.isDate(startDate, inSameDayAs: endDate)
    }

    var durationMinutes: Int {
        max(15, Int(endDate.timeIntervalSince(startDate) / 60))
    }
}

/// What Create/Edit Event actually sends — a plain value the two provider
/// API clients each translate into their own wire format, so the
/// create/update call sites don't need to know which provider they're
/// talking to beyond picking which client to call.
struct CalendarEventDraft {
    var title: String
    var description: String
    var location: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var attendeeEmails: [String] = []

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    func toGoogleBody() -> GoogleEventBody {
        GoogleEventBody(
            summary: title,
            description: description,
            location: location,
            start: isAllDay
                ? .init(date: Self.dateOnlyFormatter.string(from: startDate), dateTime: nil)
                : .init(date: nil, dateTime: Self.isoFormatter.string(from: startDate)),
            end: isAllDay
                ? .init(date: Self.dateOnlyFormatter.string(from: endDate), dateTime: nil)
                : .init(date: nil, dateTime: Self.isoFormatter.string(from: endDate)),
            attendees: attendeeEmails.map { GoogleEventBody.Attendee(email: $0) }
        )
    }

    func toGraphBody() -> GraphEventBody {
        GraphEventBody(
            subject: title,
            body: .init(contentType: "text", content: description),
            location: .init(displayName: location),
            start: .init(dateTime: Self.isoFormatter.string(from: startDate), timeZone: "UTC"),
            end: .init(dateTime: Self.isoFormatter.string(from: endDate), timeZone: "UTC"),
            isAllDay: isAllDay,
            attendees: attendeeEmails.map {
                GraphEventBody.Attendee(emailAddress: .init(address: $0, name: $0), type: "required")
            }
        )
    }
}

struct GoogleEventBody: Encodable {
    struct EventDateTime: Encodable {
        let date: String?
        let dateTime: String?
    }
    struct Attendee: Encodable {
        let email: String
    }
    let summary: String
    let description: String
    let location: String
    let start: EventDateTime
    let end: EventDateTime
    let attendees: [Attendee]
}

struct GraphEventBody: Encodable {
    struct Body: Encodable { let contentType: String; let content: String }
    struct Location: Encodable { let displayName: String }
    struct DateTimeZone: Encodable { let dateTime: String; let timeZone: String }
    struct EmailAddress: Encodable { let address: String; let name: String }
    struct Attendee: Encodable { let emailAddress: EmailAddress; let type: String }

    let subject: String
    let body: Body
    let location: Location
    let start: DateTimeZone
    let end: DateTimeZone
    let isAllDay: Bool
    let attendees: [Attendee]
}
