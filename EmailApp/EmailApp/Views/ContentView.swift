import SwiftUI

struct ContentView: View {
    @Bindable var vm: InboxViewModel
    @Bindable var calendarVM: CalendarViewModel
    @FocusState private var isContentFocused: Bool
    @State private var isCalendarMode = false

    var body: some View {
        HStack(spacing: 12) {
            // Extends flush to the window's top and bottom edges (behind
            // the traffic lights, all the way to the bottom corners)
            // instead of respecting the same insets as the rest of the
            // content — its own internal padding pushes the nav items
            // clear of the traffic lights instead.
            SidebarView(vm: vm, isCalendarMode: $isCalendarMode)
                .frame(width: 240)
                .frame(maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: [.top, .bottom])

            // TopBar (and the Mail/Calendar switch inside it) stays mounted
            // in both modes — it used to live only in the Mail branch, so
            // the moment you switched to Calendar the switch itself
            // disappeared with no way back, which is what read as "the
            // Calendar button doesn't work" (it did switch, there was just
            // nothing left on screen that could switch back).
            VStack(spacing: 10) {
                TopBar(vm: vm, isCalendarMode: $isCalendarMode)
                    // Without this, the search dropdown (an overlay
                    // attached inside TopBar) painted *behind* the toolbar
                    // row below it — VStack siblings paint in document
                    // order by default, and zIndex set only inside TopBar's
                    // own subtree doesn't affect ordering against a later
                    // sibling. This forces TopBar's overlay above it.
                    .zIndex(1)

                if isCalendarMode {
                    CalendarView(calendarVM: calendarVM, accounts: vm.accounts)
                        .transition(.opacity)
                } else {
                    Group {
                        if let thread = vm.selectedThread {
                            DetailToolbar(vm: vm, thread: thread)
                        } else {
                            ListToolbar(vm: vm)
                        }
                    }
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.18), value: vm.selectedThread?.id)

                    Group {
                        if vm.selectedThread != nil {
                            ReadingPaneView(vm: vm, calendarVM: calendarVM)
                                .transition(.opacity.combined(with: .move(edge: .trailing)))
                        } else if vm.selectedFolder == "drafts" {
                            DraftsListView(vm: vm)
                                .transition(.opacity)
                        } else {
                            MessageListView(vm: vm)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.22), value: vm.selectedThread?.id)
                }
            }
            .animation(.easeOut(duration: 0.18), value: isCalendarMode)
            .frame(minWidth: 320, maxWidth: .infinity)
            .padding(.top, 34)
            .padding(.bottom, 12)
        }
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
        .background(
            ZStack {
                Color.appBackground
                WindowConfigurator()
            }
            .ignoresSafeArea()
        )
        // The empty strip behind the traffic lights, above TopBar/Sidebar's
        // own content — double-click to zoom, click-drag to move, same as
        // a normal titlebar. Doesn't interfere with the traffic light
        // buttons themselves; those are window chrome, always hit-tested
        // before the content view underneath them.
        .overlay(alignment: .top) {
            // Order matters: .ignoresSafeArea() FIRST pins this to the true
            // top of the window (behind the traffic lights) instead of
            // being inset below them; .frame(height: 34) AFTER that then
            // hard-caps it back down. Doing it the other way around (frame
            // then ignoresSafeArea) let the safe-area expansion override
            // the cap and grow this view's hit-testable bounds down over
            // the search bar, which is what made the search field
            // permanently unclickable a few turns ago.
            TitleBarDragZoneView()
                .ignoresSafeArea()
                .frame(height: 34)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isContentFocused)
        .onAppear { isContentFocused = true }
        .onKeyPress(.upArrow) { vm.selectAdjacent(-1); return .handled }
        .onKeyPress(.downArrow) { vm.selectAdjacent(1); return .handled }
        .onKeyPress(.return) { vm.openSelected(); return .handled }
        .onKeyPress(.delete) { vm.archiveFocused(); return .handled }
        .onKeyPress(.deleteForward) { vm.archiveFocused(); return .handled }
        .onKeyPress(.escape) {
            // Whatever's currently on top dismisses first — Settings, then
            // compose. Escape is the universal "close whatever just popped
            // up" key throughout the app.
            if vm.isSettingsPresented {
                vm.isSettingsPresented = false
                return .handled
            }
            if vm.composeContext != nil {
                vm.composeContext = nil
                return .handled
            }
            return .ignored
        }
        .task { await vm.restoreSession() }
        .task { await vm.startRealtimeUpdates() }
        .task { await vm.startMCPApprovalUpdates() }
        .task { await ContactsIndexService.warmCache() }
        // Warmed eagerly (not just when Calendar is opened) so the reading
        // pane's "already on your calendar" invite detection works the
        // first time a meeting-invite email is opened, not only after the
        // user has visited the Calendar tab at least once this session.
        .task(id: vm.accounts.map(\.id)) { await calendarVM.loadEvents(accounts: vm.accounts) }
        .overlay(alignment: .bottom) { PendingSendBannerStack(vm: vm) }
        .overlay(alignment: .bottomTrailing) {
            if let context = vm.composeContext {
                ComposeView(vm: vm, context: context, onClose: { vm.composeContext = nil })
                    .padding(20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 1), value: vm.composeContext?.id)
        .overlay {
            if vm.isSettingsPresented {
                ZStack {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                        .onTapGesture { vm.isSettingsPresented = false }
                        .transition(.opacity)
                    SettingsView(vm: vm, onClose: { vm.isSettingsPresented = false })
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: vm.isSettingsPresented)
        .alert(
            "Error",
            isPresented: Binding(get: { vm.errorMessage != nil }, set: { if !$0 { vm.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }
}

/// A two-sided switch (like a segmented iOS-style toggle) in the empty
/// space next to the search bar — replaces the old sidebar "Calendar" nav
/// item as the way to get to Calendar.
private struct MailCalendarSwitch: View {
    @Binding var isCalendarMode: Bool
    let height: CGFloat
    @Namespace private var namespace

    private var segmentHeight: CGFloat { height - 6 }

    var body: some View {
        HStack(spacing: 2) {
            segment(label: "Mail", icon: "envelope", isSelected: !isCalendarMode) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { isCalendarMode = false }
            }
            segment(label: "Calendar", icon: "calendar", isSelected: isCalendarMode) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { isCalendarMode = true }
            }
        }
        .padding(3)
        .frame(height: height)
        .background(Color.appSurface, in: Capsule())
    }

    private func segment(label: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(label)
            }
            .font(.appCaption.weight(.medium))
            .foregroundStyle(isSelected ? Color.appBackground : .secondary)
            .padding(.horizontal, 20)
            .frame(height: segmentHeight)
            .background {
                // A single highlight capsule that slides between the two
                // segments via matchedGeometryEffect, instead of each
                // segment independently popping its own background in and
                // out — that's what reads as a real sliding switch rather
                // than a cross-fade.
                if isSelected {
                    Capsule().fill(Color.white.opacity(0.92))
                        .matchedGeometryEffect(id: "highlight", in: namespace)
                }
            }
        }
        .buttonStyle(.pointerPlain)
    }
}

private struct TopBar: View {
    @Bindable var vm: InboxViewModel
    @Binding var isCalendarMode: Bool
    @FocusState private var isSearchFocused: Bool
    @State private var recentSearches: [String] = RecentSearchesStore.load()

    private let quickFilters: [(label: String, token: String)] = [
        ("Has attachment", "has:attachment"),
        ("Last 7 days", "newer_than:7d"),
        ("From me", "from:me"),
    ]

    private let searchBarHeight: CGFloat = 52

    var body: some View {
        GeometryReader { sectionGeo in
            let searchBarWidth = sectionGeo.size.width * 0.5

            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search mail", text: $vm.searchText)
                        .textFieldStyle(.plain)
                        .font(.appSubheadline)
                        .focused($isSearchFocused)
                        .onChange(of: vm.searchFocusTrigger) { _, _ in isSearchFocused = true }
                        .onSubmit { commitSearch(vm.searchText) }
                    if !vm.searchText.isEmpty {
                        Button { vm.searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").iconButtonHitArea(2)
                        }
                        .buttonStyle(.pointerPlain)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .frame(width: searchBarWidth, height: searchBarHeight)
                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 22))
                .overlay(alignment: .topLeading) {
                    if isSearchFocused {
                        searchDropdown(width: searchBarWidth)
                            .offset(y: searchBarHeight + 4)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                Spacer()

                MailCalendarSwitch(isCalendarMode: $isCalendarMode, height: searchBarHeight)

                ConnectivityIndicator(vm: vm)
            }
        }
        .frame(height: searchBarHeight)
        .animation(.easeOut(duration: 0.16), value: isSearchFocused)
    }

    private var filteredRecents: [String] {
        guard !vm.searchText.isEmpty else { return recentSearches }
        return recentSearches.filter { $0.localizedCaseInsensitiveContains(vm.searchText) }
    }

    private func searchDropdown(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 6) {
                ForEach(quickFilters, id: \.token) { filter in
                    Button {
                        applyQuickFilter(filter.token)
                    } label: {
                        Text(filter.label)
                            .font(.appCaption.weight(.medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.appHover))
                    }
                    .buttonStyle(.pointerPlain)
                    .fixedSize()
                }
            }

            if !filteredRecents.isEmpty {
                Divider().overlay(Color.appBorder)
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(filteredRecents, id: \.self) { query in
                        RecentSearchRow(query: query) {
                            commitSearch(query)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(width: width, alignment: .leading)
        .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.appBorder))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }

    private func applyQuickFilter(_ token: String) {
        guard !vm.searchText.localizedCaseInsensitiveContains(token) else { return }
        vm.searchText = vm.searchText.isEmpty ? token : vm.searchText + " " + token
    }

    private func commitSearch(_ query: String) {
        vm.searchText = query
        RecentSearchesStore.record(query)
        recentSearches = RecentSearchesStore.load()
        isSearchFocused = false
    }
}

private struct RecentSearchRow: View {
    let query: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                Text(query)
                    .font(.appSubheadline)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(isHovering ? Color.appHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pointerPlain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// Gmail-style slim toolbar above the list. With nothing selected it shows
/// select-all/refresh on the left and pagination on the right; the moment
/// something's selected, the right side morphs into bulk actions instead —
/// no separate row pushing the list down, same as Gmail.
private struct ListToolbar: View {
    @Bindable var vm: InboxViewModel
    @State private var isRefreshing = false

    var body: some View {
        HStack(spacing: 22) {
            // Checkbox goes first so its X position matches the row
            // checkbox directly below it. Deliberately NOT using
            // iconButtonHitArea() here — its padding shifted the glyph
            // relative to the row checkbox, which has no such padding.
            // Same frame-based sizing as the row checkbox instead, so
            // both go through an identical layout, guaranteeing alignment
            // instead of guessing a compensating offset.
            Button {
                vm.toggleSelectAll()
            } label: {
                Image(systemName: allSelected ? "checkmark.square.fill" : "square")
                    .font(.custom("Inter", size: 13))
                    .foregroundStyle(allSelected ? Color.appAccent : .secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pointerPlain)

            if vm.selectedThreadKeys.isEmpty {
                Button {
                    guard !isRefreshing else { return }
                    isRefreshing = true
                    Task {
                        await vm.refreshAll()
                        isRefreshing = false
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.custom("Inter", size: 13))
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                        .animation(isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                        .iconButtonHitArea()
                }
                .buttonStyle(.pointerPlain)
                .foregroundStyle(.secondary)
            } else {
                Text("\(vm.selectedThreadKeys.count) selected")
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if vm.selectedThreadKeys.isEmpty {
                if range.total > 0 {
                    Text("\(range.start + 1)–\(range.end) of \(range.total)")
                        .font(.appCaption)
                        .foregroundStyle(.secondary)

                    Button { vm.goToPreviousPage() } label: {
                        Image(systemName: "chevron.left").iconButtonHitArea()
                    }
                    .buttonStyle(.pointerPlain)
                    .foregroundStyle(vm.listPageIndex > 0 ? .secondary : Color.secondary.opacity(0.3))
                    .disabled(vm.listPageIndex == 0)

                    Button { vm.goToNextPage() } label: {
                        Image(systemName: "chevron.right").iconButtonHitArea()
                    }
                    .buttonStyle(.pointerPlain)
                    .foregroundStyle(range.end < range.total ? .secondary : Color.secondary.opacity(0.3))
                    .disabled(range.end >= range.total)
                }
            } else {
                bulkButton("Archive", icon: "archivebox") { vm.bulkArchive() }
                bulkButton("Delete", icon: "trash") { vm.bulkDelete() }
                bulkButton("Mark Read", icon: "envelope.open") { vm.bulkMarkRead(true) }
                bulkButton("Mark Unread", icon: "envelope.badge") { vm.bulkMarkRead(false) }

                Button { vm.selectedThreadKeys.removeAll() } label: {
                    Image(systemName: "xmark").iconButtonHitArea()
                }
                .buttonStyle(.pointerPlain)
                .foregroundStyle(.secondary)
            }
        }
        // Matches MessageListView's row checkbox X position exactly:
        // rowHorizontalPadding(16) + leadingInset(3) + row spacing(10).
        .padding(.leading, 29)
        .padding(.trailing, 6)
        .padding(.vertical, 10)
        .animation(.easeOut(duration: 0.18), value: vm.selectedThreadKeys.isEmpty)
    }

    private var range: (start: Int, end: Int, total: Int) { vm.listPageRange }

    private var allSelected: Bool {
        !vm.filteredThreads.isEmpty && Set(vm.filteredThreads.map(\.id)) == vm.selectedThreadKeys
    }

    private func bulkButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.appCaption.weight(.medium))
        }
        .buttonStyle(.pointerPlain)
        .foregroundStyle(.secondary)
    }
}

/// Replaces `ListToolbar` in the same row the moment a thread opens —
/// Gmail-style: back, archive, trash, mark unread. Acts on the whole open
/// conversation, same as swiping a collapsed row in the list.
private struct DetailToolbar: View {
    @Bindable var vm: InboxViewModel
    let thread: MessageThread

    var body: some View {
        HStack(spacing: 18) {
            Button { vm.selectedThreadKey = nil } label: {
                Image(systemName: "chevron.left").iconButtonHitArea()
            }
            .buttonStyle(.pointerPlain)
            .foregroundStyle(.secondary)

            Divider().frame(height: 16).overlay(Color.appBorder)

            Button { vm.archiveThread(thread) } label: {
                Image(systemName: "archivebox").iconButtonHitArea()
            }
            .buttonStyle(.pointerPlain)
            .foregroundStyle(.secondary)

            Button { vm.deleteThread(thread) } label: {
                Image(systemName: "trash").iconButtonHitArea()
            }
            .buttonStyle(.pointerPlain)
            .foregroundStyle(.secondary)

            Divider().frame(height: 16).overlay(Color.appBorder)

            Button { vm.markThreadUnread(thread) } label: {
                Image(systemName: "envelope.badge").iconButtonHitArea()
            }
            .buttonStyle(.pointerPlain)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
    }
}

/// Makes offline mode legible instead of the UI just silently doing
/// nothing — shows either "Offline" or, once back online, how many queued
/// actions are still catching up.
private struct ConnectivityIndicator: View {
    let vm: InboxViewModel
    var network = NetworkMonitor.shared

    var body: some View {
        if !network.isOnline {
            Label("Offline", systemImage: "wifi.slash")
                .font(.appCaption.weight(.medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.orange.opacity(0.15)))
        } else if !vm.offlineQueue.isEmpty {
            Label("Syncing \(vm.offlineQueue.count)…", systemImage: "arrow.triangle.2.circlepath")
                .font(.appCaption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.appHover))
        }
    }
}

#Preview {
    ContentView(vm: InboxViewModel(), calendarVM: CalendarViewModel())
        .frame(width: 1100, height: 700)
        .preferredColorScheme(.dark)
}
