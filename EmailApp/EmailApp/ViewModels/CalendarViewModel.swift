import Foundation
import Observation

enum CalendarViewMode: String, CaseIterable {
    case month, week, day

    var label: String {
        switch self {
        case .month: return "Month"
        case .week: return "Week"
        case .day: return "Day"
        }
    }
}

@Observable
final class CalendarViewModel {
    var events: [CalendarEvent] = []
    var selectedDate = Date()
    var viewMode: CalendarViewMode = .month
    var isLoading = false
    var errorMessage: String?
    var eventComposeContext: EventComposeContext?

    enum EventComposeContext: Identifiable {
        case new(start: Date, end: Date)
        case edit(CalendarEvent)

        var id: String {
            switch self {
            case .new(let start, _): return "new-\(start.timeIntervalSince1970)"
            case .edit(let event): return "edit-\(event.id)"
            }
        }
    }

    /// The [start, end) window actually visible for the current
    /// viewMode/selectedDate — month view pads to full weeks so the grid
    /// has no partial row.
    var visibleRange: (start: Date, end: Date) {
        let calendar = Calendar.current
        switch viewMode {
        case .day:
            let start = calendar.startOfDay(for: selectedDate)
            return (start, calendar.date(byAdding: .day, value: 1, to: start)!)
        case .week:
            let start = calendar.dateInterval(of: .weekOfYear, for: selectedDate)?.start ?? selectedDate
            return (start, calendar.date(byAdding: .day, value: 7, to: start)!)
        case .month:
            let monthInterval = calendar.dateInterval(of: .month, for: selectedDate)!
            let firstWeekday = calendar.dateInterval(of: .weekOfYear, for: monthInterval.start)!.start
            let lastDayInterval = calendar.dateInterval(of: .weekOfYear, for: calendar.date(byAdding: .second, value: -1, to: monthInterval.end)!)!
            return (firstWeekday, lastDayInterval.end)
        }
    }

    /// Days shown in the month grid (or the single week for week view, or
    /// just today for day view) — always full weeks, Sunday-first.
    var visibleDays: [Date] {
        let calendar = Calendar.current
        var days: [Date] = []
        var cursor = visibleRange.start
        while cursor < visibleRange.end {
            days.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        return days
    }

    func events(on day: Date) -> [CalendarEvent] {
        let calendar = Calendar.current
        return events.filter { calendar.isDate($0.startDate, inSameDayAs: day) || ($0.spansMultipleDays && $0.startDate <= day && day < $0.endDate) }
            .sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Load

    func loadEvents(accounts: [Account]) async {
        guard !accounts.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        let range = visibleRange
        var all: [CalendarEvent] = []
        for account in accounts {
            guard let token = try? await OAuthManager.shared.validAccessToken(for: account) else { continue }
            do {
                let fetched: [CalendarEvent]
                switch account.provider {
                case .gmail:
                    fetched = try await GoogleCalendarAPI.listEvents(for: account, accessToken: token, from: range.start, to: range.end)
                case .outlook:
                    fetched = try await GraphCalendarAPI.listEvents(for: account, accessToken: token, from: range.start, to: range.end)
                }
                all.append(contentsOf: fetched)
            } catch {
                errorMessage = "Couldn't load \(account.email)'s calendar: \(error.localizedDescription)"
            }
        }
        events = all.sorted { $0.startDate < $1.startDate }
    }

    // MARK: - Create / Update / Delete — always a real provider write, never local-only

    func createEvent(_ draft: CalendarEventDraft, account: Account) async {
        guard let token = try? await OAuthManager.shared.validAccessToken(for: account) else {
            errorMessage = "Couldn't get an access token for \(account.email)."
            return
        }
        do {
            let created: CalendarEvent
            switch account.provider {
            case .gmail: created = try await GoogleCalendarAPI.createEvent(draft, for: account, accessToken: token)
            case .outlook: created = try await GraphCalendarAPI.createEvent(draft, for: account, accessToken: token)
            }
            events.append(created)
            events.sort { $0.startDate < $1.startDate }
        } catch {
            errorMessage = "Couldn't create event: \(error.localizedDescription)"
        }
    }

    /// Optimistic — the block moves/resizes immediately in the UI, rolled
    /// back if the provider write fails.
    func updateEvent(_ event: CalendarEvent, draft: CalendarEventDraft, account: Account) async {
        guard let index = events.firstIndex(where: { $0.id == event.id }) else { return }
        let previous = events[index]
        events[index].title = draft.title
        events[index].eventDescription = draft.description
        events[index].location = draft.location
        events[index].startDate = draft.startDate
        events[index].endDate = draft.endDate
        events[index].isAllDay = draft.isAllDay

        guard let token = try? await OAuthManager.shared.validAccessToken(for: account) else {
            events[index] = previous
            errorMessage = "Couldn't get an access token for \(account.email)."
            return
        }
        do {
            let updated: CalendarEvent
            switch account.provider {
            case .gmail: updated = try await GoogleCalendarAPI.updateEvent(providerId: event.providerId, draft: draft, for: account, accessToken: token)
            case .outlook: updated = try await GraphCalendarAPI.updateEvent(providerId: event.providerId, draft: draft, for: account, accessToken: token)
            }
            if let idx = events.firstIndex(where: { $0.id == event.id }) { events[idx] = updated }
        } catch {
            if let idx = events.firstIndex(where: { $0.id == event.id }) { events[idx] = previous }
            errorMessage = "Couldn't update event: \(error.localizedDescription)"
        }
    }

    func deleteEvent(_ event: CalendarEvent, account: Account) async {
        guard let index = events.firstIndex(where: { $0.id == event.id }) else { return }
        let removed = events.remove(at: index)

        guard let token = try? await OAuthManager.shared.validAccessToken(for: account) else {
            events.insert(removed, at: index)
            errorMessage = "Couldn't get an access token for \(account.email)."
            return
        }
        do {
            switch account.provider {
            case .gmail: try await GoogleCalendarAPI.deleteEvent(providerId: event.providerId, accessToken: token)
            case .outlook: try await GraphCalendarAPI.deleteEvent(providerId: event.providerId, accessToken: token)
            }
        } catch {
            events.insert(removed, at: min(index, events.count))
            errorMessage = "Couldn't delete event: \(error.localizedDescription)"
        }
    }

    /// Drag-to-reschedule: keeps the same duration, moves both start/end.
    func rescheduleEvent(_ event: CalendarEvent, newStart: Date, accounts: [Account]) async {
        guard let account = accounts.first(where: { $0.id == event.accountId }) else { return }
        let duration = event.endDate.timeIntervalSince(event.startDate)
        let draft = CalendarEventDraft(
            title: event.title, description: event.eventDescription, location: event.location,
            startDate: newStart, endDate: newStart.addingTimeInterval(duration), isAllDay: event.isAllDay,
            attendeeEmails: event.attendees.map(\.email)
        )
        await updateEvent(event, draft: draft, account: account)
    }

    /// Resize: keeps start fixed, changes only the end (duration).
    func resizeEvent(_ event: CalendarEvent, newEnd: Date, accounts: [Account]) async {
        guard let account = accounts.first(where: { $0.id == event.accountId }) else { return }
        guard newEnd > event.startDate else { return }
        let draft = CalendarEventDraft(
            title: event.title, description: event.eventDescription, location: event.location,
            startDate: event.startDate, endDate: newEnd, isAllDay: event.isAllDay,
            attendeeEmails: event.attendees.map(\.email)
        )
        await updateEvent(event, draft: draft, account: account)
    }

    // MARK: - Navigation

    func goToToday() { selectedDate = Date() }

    func goToPrevious() {
        selectedDate = shift(selectedDate, by: -1)
    }

    func goToNext() {
        selectedDate = shift(selectedDate, by: 1)
    }

    private func shift(_ date: Date, by amount: Int) -> Date {
        let calendar = Calendar.current
        switch viewMode {
        case .day: return calendar.date(byAdding: .day, value: amount, to: date)!
        case .week: return calendar.date(byAdding: .weekOfYear, value: amount, to: date)!
        case .month: return calendar.date(byAdding: .month, value: amount, to: date)!
        }
    }
}
