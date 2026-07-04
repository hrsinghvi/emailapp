import SwiftUI

struct EventComposeView: View {
    @Bindable var calendarVM: CalendarViewModel
    let accounts: [Account]
    let context: CalendarViewModel.EventComposeContext
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var location = ""
    @State private var description = ""
    @State private var startDate = Date()
    @State private var endDate = Date().addingTimeInterval(3600)
    @State private var isAllDay = false
    @State private var attendeesText = ""
    @State private var selectedAccountId: UUID?
    @State private var existingEvent: CalendarEvent?
    @State private var showDeleteConfirm = false

    private var isEditing: Bool { existingEvent != nil }
    private var selectedAccount: Account? { accounts.first { $0.id == selectedAccountId } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(isEditing ? "Edit Event" : "New Event")
                    .font(.appHeadline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark").iconButtonHitArea()
                }
                .buttonStyle(.pointerPlain)
                .foregroundStyle(.secondary)
            }

            field("Title", text: $title)

            if accounts.count > 1 {
                Picker("Calendar", selection: $selectedAccountId) {
                    ForEach(accounts) { account in
                        Text(account.email).tag(Optional(account.id))
                    }
                }
                .pickerStyle(.menu)
                .disabled(isEditing)
            }

            Toggle("All day", isOn: $isAllDay)
                .toggleStyle(.switch)
                .font(.appSubheadline)

            HStack(spacing: 10) {
                DatePicker(
                    "Starts", selection: $startDate,
                    displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                )
                .onChange(of: startDate) { _, newValue in
                    if endDate <= newValue { endDate = newValue.addingTimeInterval(3600) }
                }
                DatePicker(
                    "Ends", selection: $endDate,
                    displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                )
            }
            .font(.appSubheadline)
            .datePickerStyle(.field)

            field("Location", text: $location)
            field("Attendees (comma-separated emails)", text: $attendeesText)

            VStack(alignment: .leading, spacing: 4) {
                Text("Description").font(.appCaption).foregroundStyle(.secondary)
                TextEditor(text: $description)
                    .font(.appSubheadline)
                    .frame(height: 100)
                    .padding(6)
                    .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.18)))
            }

            HStack {
                if isEditing {
                    Button("Delete", role: .destructive) { showDeleteConfirm = true }
                        .buttonStyle(.pointerPlain)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.pointerPlain)
                    .foregroundStyle(.secondary)
                Button(isEditing ? "Save" : "Create") { save() }
                    .buttonStyle(.pointerPlain)
                    .font(.appSubheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.appAccent.opacity(0.9)))
                    .disabled(title.isEmpty || selectedAccount == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.appBorder))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
        .onAppear(perform: prefill)
        .alert("Delete this event?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { delete() }
        } message: {
            Text("This deletes it from the real calendar, not just this app.")
        }
    }

    private func prefill() {
        switch context {
        case .new(let start, let end):
            startDate = start
            endDate = end
            selectedAccountId = accounts.first?.id
        case .edit(let event):
            existingEvent = event
            title = event.title
            location = event.location
            description = event.eventDescription
            startDate = event.startDate
            endDate = event.endDate
            isAllDay = event.isAllDay
            attendeesText = event.attendees.map(\.email).joined(separator: ", ")
            selectedAccountId = event.accountId
        }
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.appSubheadline)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.18)))
    }

    private func save() {
        guard let account = selectedAccount else { return }
        let attendeeEmails = attendeesText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let draft = CalendarEventDraft(
            title: title, description: description, location: location,
            startDate: startDate, endDate: max(endDate, startDate.addingTimeInterval(900)),
            isAllDay: isAllDay, attendeeEmails: attendeeEmails
        )
        Task {
            if let existingEvent {
                await calendarVM.updateEvent(existingEvent, draft: draft, account: account)
            } else {
                await calendarVM.createEvent(draft, account: account)
            }
        }
        dismiss()
    }

    private func delete() {
        guard let existingEvent, let account = accounts.first(where: { $0.id == existingEvent.accountId }) else { return }
        Task { await calendarVM.deleteEvent(existingEvent, account: account) }
        dismiss()
    }
}
