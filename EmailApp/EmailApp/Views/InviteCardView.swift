import AppKit
import SwiftUI

/// Detects a meeting invite (an .ics / text/calendar attachment — how
/// Google Calendar, Outlook, and Apple Calendar all actually attach
/// invites to the notification email) and renders either an "Add to
/// Calendar" action or, if the event's already on the calendar, a small
/// linked card instead — matching the "detect existing calendar events
/// referenced in email threads" ask.
struct InviteCardView: View {
    let vm: InboxViewModel
    let calendarVM: CalendarViewModel
    let message: Message

    @State private var parsedInvite: ParsedICSEvent?
    @State private var isLoading = false
    @State private var isAdding = false

    private var icsAttachment: Attachment? {
        message.attachments.first {
            $0.mimeType.localizedCaseInsensitiveContains("calendar") || $0.filename.lowercased().hasSuffix(".ics")
        }
    }

    /// An event already on the calendar with the same title starting
    /// within a minute of the invite — treated as "this is that event".
    private var existingEvent: CalendarEvent? {
        guard let invite = parsedInvite else { return nil }
        return calendarVM.events.first {
            $0.title == invite.title && abs($0.startDate.timeIntervalSince(invite.startDate)) < 60
        }
    }

    var body: some View {
        Group {
            if let invite = parsedInvite {
                card(for: invite)
            } else if isLoading {
                EmptyView()
            }
        }
        .task(id: icsAttachment?.id) {
            guard let icsAttachment, parsedInvite == nil else { return }
            isLoading = true
            defer { isLoading = false }
            guard let data = try? await vm.attachmentData(icsAttachment, on: message),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            else { return }
            parsedInvite = ICSParser.parse(text)
        }
    }

    private func card(for invite: ParsedICSEvent) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar")
                .font(.appHeadline)
                .foregroundStyle(Color.appAccent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(invite.title)
                    .font(.appSubheadline.weight(.medium))
                    .lineLimit(1)
                Text(dateRangeText(invite))
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                if !invite.location.isEmpty {
                    Text(invite.location)
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let existingEvent {
                Button {
                    if let link = existingEvent.htmlLink, let url = URL(string: link) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("On your calendar")
                    }
                    .font(.appCaption.weight(.medium))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.pointerPlain)
            } else {
                Button {
                    addToCalendar(invite)
                } label: {
                    HStack(spacing: 6) {
                        if isAdding { ProgressView().controlSize(.small) }
                        Text(isAdding ? "Adding…" : "Add to Calendar")
                    }
                    .font(.appCaption.weight(.semibold))
                    .foregroundStyle(Color.appBackground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.white.opacity(0.92)))
                }
                .buttonStyle(.pointerPlain)
                .disabled(isAdding)
            }
        }
        .padding(12)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.12)))
    }

    private func dateRangeText(_ invite: ParsedICSEvent) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = invite.isAllDay ? "EEE, MMM d" : "EEE, MMM d · h:mm a"
        let start = formatter.string(from: invite.startDate)
        guard !invite.isAllDay else { return start }
        let endFormatter = DateFormatter()
        endFormatter.dateFormat = "h:mm a"
        return "\(start) – \(endFormatter.string(from: invite.endDate))"
    }

    private func addToCalendar(_ invite: ParsedICSEvent) {
        guard let account = vm.accounts.first(where: { $0.id == message.accountId }) ?? vm.accounts.first else { return }
        isAdding = true
        let draft = CalendarEventDraft(
            title: invite.title, description: invite.description, location: invite.location,
            startDate: invite.startDate, endDate: invite.endDate, isAllDay: invite.isAllDay
        )
        Task {
            await calendarVM.createEvent(draft, account: account)
            isAdding = false
        }
    }
}
