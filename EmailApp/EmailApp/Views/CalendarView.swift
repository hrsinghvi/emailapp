import SwiftUI

struct CalendarView: View {
    @Bindable var calendarVM: CalendarViewModel
    let accounts: [Account]

    var body: some View {
        VStack(spacing: 10) {
            header
            Group {
                switch calendarVM.viewMode {
                case .month: MonthGridView(calendarVM: calendarVM, accounts: accounts)
                case .week: TimeGridView(calendarVM: calendarVM, accounts: accounts, dayCount: 7)
                case .day: TimeGridView(calendarVM: calendarVM, accounts: accounts, dayCount: 1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 12))
        }
        .task(id: calendarVM.viewMode) { await calendarVM.loadEvents(accounts: accounts) }
        .task(id: calendarVM.selectedDate) { await calendarVM.loadEvents(accounts: accounts) }
        .task(id: accounts.map(\.id)) { await calendarVM.loadEvents(accounts: accounts) }
        .sheet(item: $calendarVM.eventComposeContext) { context in
            EventComposeView(calendarVM: calendarVM, accounts: accounts, context: context)
        }
        .alert(
            "Error",
            isPresented: Binding(get: { calendarVM.errorMessage != nil }, set: { if !$0 { calendarVM.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(calendarVM.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text(headerTitle)
                .font(.appTitle2.weight(.semibold))

            HStack(spacing: 2) {
                Button { calendarVM.goToPrevious() } label: {
                    Image(systemName: "chevron.left").iconButtonHitArea()
                }
                .buttonStyle(.pointerPlain)
                Button { calendarVM.goToNext() } label: {
                    Image(systemName: "chevron.right").iconButtonHitArea()
                }
                .buttonStyle(.pointerPlain)
            }
            .foregroundStyle(.secondary)

            Button("Today") { calendarVM.goToToday() }
                .buttonStyle(.pointerPlain)
                .font(.appCaption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.appHover))

            Spacer()

            Picker("", selection: $calendarVM.viewMode) {
                ForEach(CalendarViewMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .labelsHidden()

            Button {
                let start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: calendarVM.selectedDate) ?? calendarVM.selectedDate
                calendarVM.eventComposeContext = .new(start: start, end: start.addingTimeInterval(3600))
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("New Event")
                }
                .font(.appCaption.weight(.semibold))
                .foregroundStyle(Color.appBackground)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.white.opacity(0.92)))
            }
            .buttonStyle(.pointerPlain)
            .disabled(accounts.isEmpty)
        }
    }

    private var headerTitle: String {
        let formatter = DateFormatter()
        switch calendarVM.viewMode {
        case .month:
            formatter.dateFormat = "MMMM yyyy"
        case .week:
            formatter.dateFormat = "MMM d, yyyy"
        case .day:
            formatter.dateFormat = "EEEE, MMM d"
        }
        return formatter.string(from: calendarVM.selectedDate)
    }
}

// MARK: - Month grid

private struct MonthGridView: View {
    @Bindable var calendarVM: CalendarViewModel
    let accounts: [Account]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    private let weekdaySymbols = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.appCaption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
            Divider().overlay(Color.appBorder)
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(calendarVM.visibleDays, id: \.self) { day in
                    MonthDayCell(calendarVM: calendarVM, accounts: accounts, day: day)
                        .frame(minHeight: 100)
                        .overlay(Rectangle().stroke(Color.appBorder, lineWidth: 0.5))
                }
            }
        }
    }
}

private struct MonthDayCell: View {
    @Bindable var calendarVM: CalendarViewModel
    let accounts: [Account]
    let day: Date
    @State private var isDropTargeted = false

    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private var isCurrentMonth: Bool {
        Calendar.current.isDate(day, equalTo: calendarVM.selectedDate, toGranularity: .month)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.appCaption.weight(isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Color.appAccent : (isCurrentMonth ? Color.primary : Color.secondary.opacity(0.4)))
                .padding(.horizontal, 6)
                .padding(.top, 4)

            ForEach(calendarVM.events(on: day).prefix(3)) { event in
                EventChip(event: event)
                    .onTapGesture { calendarVM.eventComposeContext = .edit(event) }
                    .onDrag { NSItemProvider(object: event.id.uuidString as NSString) }
            }
            if calendarVM.events(on: day).count > 3 {
                Text("+\(calendarVM.events(on: day).count - 3) more")
                    .font(.appCaption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(isDropTargeted ? Color.appHover : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            let start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
            calendarVM.eventComposeContext = .new(start: start, end: start.addingTimeInterval(3600))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let idString = items.first, let eventId = UUID(uuidString: idString),
                  let event = calendarVM.events.first(where: { $0.id == eventId }) else { return false }
            let calendar = Calendar.current
            let time = calendar.dateComponents([.hour, .minute], from: event.startDate)
            let newStart = calendar.date(
                bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day
            ) ?? day
            Task { await calendarVM.rescheduleEvent(event, newStart: newStart, accounts: accounts) }
            return true
        } isTargeted: { isDropTargeted = $0 }
    }
}

private struct EventChip: View {
    let event: CalendarEvent

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(event.provider.color).frame(width: 5, height: 5)
            Text(event.title)
                .font(.appCaption2)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appHover, in: RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, 4)
        .pointerOnHover()
    }
}

// MARK: - Week / Day time grid

private struct TimeGridView: View {
    @Bindable var calendarVM: CalendarViewModel
    let accounts: [Account]
    let dayCount: Int

    private let hourHeight: CGFloat = 56

    private var days: [Date] {
        let calendar = Calendar.current
        let start = dayCount == 1 ? calendar.startOfDay(for: calendarVM.selectedDate) : calendarVM.visibleRange.start
        return (0..<dayCount).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 0) {
                // Hour labels gutter
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(hourLabel(hour))
                            .font(.appCaption2)
                            .foregroundStyle(.secondary)
                            .frame(height: hourHeight, alignment: .top)
                            .frame(width: 48, alignment: .trailing)
                            .padding(.trailing, 6)
                    }
                }

                ForEach(days, id: \.self) { day in
                    DayColumn(calendarVM: calendarVM, accounts: accounts, day: day, hourHeight: hourHeight)
                        .frame(maxWidth: .infinity)
                        .overlay(Rectangle().stroke(Color.appBorder, lineWidth: 0.5))
                }
            }
            .padding(.top, 8)
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h a"
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return formatter.string(from: date)
    }
}

private struct DayColumn: View {
    @Bindable var calendarVM: CalendarViewModel
    let accounts: [Account]
    let day: Date
    let hourHeight: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { _ in
                    Divider().overlay(Color.appBorder.opacity(0.5))
                        .frame(height: hourHeight)
                }
            }
            .onTapGesture(count: 2) { }

            ForEach(calendarVM.events(on: day)) { event in
                TimeGridEventBlock(calendarVM: calendarVM, accounts: accounts, event: event, day: day, hourHeight: hourHeight)
            }
        }
        .frame(height: hourHeight * 24)
    }
}

private struct TimeGridEventBlock: View {
    @Bindable var calendarVM: CalendarViewModel
    let accounts: [Account]
    let event: CalendarEvent
    let day: Date
    let hourHeight: CGFloat

    @State private var dragOffset: CGFloat = 0
    @State private var resizeOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var isResizing = false

    private var minutesFromMidnight: CGFloat {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.hour, .minute], from: event.startDate)
        return CGFloat((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
    }

    private var topOffset: CGFloat { minutesFromMidnight / 60 * hourHeight + dragOffset }
    private var blockHeight: CGFloat {
        max(18, CGFloat(event.durationMinutes) / 60 * hourHeight + resizeOffset)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(event.title)
                .font(.appCaption.weight(.medium))
                .lineLimit(1)
            if blockHeight > 32 {
                Text(event.startDate, format: .dateTime.hour().minute())
                    .font(.appCaption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: blockHeight, alignment: .top)
        .background(event.provider.color.opacity(isDragging ? 0.5 : 0.28), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(event.provider.color.opacity(0.6)))
        .overlay(alignment: .bottom) {
            // Resize handle — drag the bottom edge to change duration.
            Rectangle()
                .fill(Color.clear)
                .frame(height: 6)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.resizeUpDown.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            isResizing = true
                            resizeOffset = value.translation.height
                        }
                        .onEnded { value in
                            isResizing = false
                            let deltaMinutes = Int(value.translation.height / hourHeight * 60 / 15) * 15
                            let newEnd = event.endDate.addingTimeInterval(TimeInterval(deltaMinutes * 60))
                            resizeOffset = 0
                            Task { await calendarVM.resizeEvent(event, newEnd: newEnd, accounts: accounts) }
                        }
                )
        }
        .offset(y: topOffset)
        .padding(.horizontal, 2)
        .pointerOnHover()
        .onTapGesture { calendarVM.eventComposeContext = .edit(event) }
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    isDragging = true
                    dragOffset = value.translation.height
                }
                .onEnded { value in
                    isDragging = false
                    let deltaMinutes = Int(value.translation.height / hourHeight * 60 / 15) * 15
                    let newStart = event.startDate.addingTimeInterval(TimeInterval(deltaMinutes * 60))
                    dragOffset = 0
                    Task { await calendarVM.rescheduleEvent(event, newStart: newStart, accounts: accounts) }
                }
        )
    }
}
