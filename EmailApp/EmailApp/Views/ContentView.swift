import SwiftUI

struct ContentView: View {
    @Bindable var vm: InboxViewModel
    @FocusState private var isContentFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Extends flush to the window's top and bottom edges (behind
            // the traffic lights, all the way to the bottom corners)
            // instead of respecting the same insets as the rest of the
            // content — its own internal padding pushes the nav items
            // clear of the traffic lights instead.
            SidebarView(vm: vm)
                .frame(width: 240)
                .frame(maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: [.top, .bottom])

            // Only the toolbar row + body swap when a thread opens — the
            // search bar stays put instead of the whole pane being
            // replaced, matching Gmail rather than a full-screen takeover.
            VStack(spacing: 10) {
                TopBar(vm: vm)
                    // Without this, the search dropdown (an overlay
                    // attached inside TopBar) painted *behind* the toolbar
                    // row below it — VStack siblings paint in document
                    // order by default, and zIndex set only inside TopBar's
                    // own subtree doesn't affect ordering against a later
                    // sibling. This forces TopBar's overlay above it.
                    .zIndex(1)

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
                        ReadingPaneView(vm: vm)
                            .transition(.opacity)
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
            .frame(minWidth: 320, maxWidth: .infinity)
            .padding(.top, 34)
            .padding(.bottom, 12)
        }
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
        .background(
            // .ignoresSafeArea() applied ONCE here, to the whole ZStack —
            // everything inside (Color fill, the drag zone) then just uses
            // plain alignment/frame within that already-correct coordinate
            // space. Previously the drag-zone view had .ignoresSafeArea()
            // and .frame() applied directly to itself in a specific order,
            // which was fragile (get the order wrong and its hit-testable
            // bounds silently grow past the intended 34pt). This structure
            // can't have that problem — there's no safe-area math happening
            // on the drag zone itself at all.
            ZStack(alignment: .top) {
                Color.appBackground
                WindowConfigurator()
                // Only the empty 34pt strip above TopBar — real
                // click-drag-to-move and double-click-to-zoom, both from
                // one NSView's mouseDown (see TitleBarDragZoneView). Not
                // NSWindow.isMovableByWindowBackground (drags from
                // anywhere) and not a separate SwiftUI double-click gesture
                // (the two independently kept conflicting with each other).
                TitleBarDragZoneView()
                    .frame(height: 34)
            }
            .ignoresSafeArea()
        )
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
            if !vm.selectedThreadKeys.isEmpty {
                vm.selectedThreadKeys.removeAll()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(KeyEquivalent("z"), phases: .down) { (press: KeyPress) -> KeyPress.Result in
            guard press.modifiers.contains(.command) else { return .ignored }
            // Only reached at all when no text field/editor has focus —
            // AppKit's responder chain hands Cmd-Z to a focused NSTextView's
            // own native undo first, so this never fights typing undo in
            // Compose (see the shift+cmd+z guard below for why redo is
            // deliberately NOT handled here: same reasoning, no app-level
            // redo action exists to conflict with, so it's left alone
            // entirely rather than intercepted and ignored).
            guard !press.modifiers.contains(.shift) else { return .ignored }
            vm.undoLastDelete()
            return .handled
        }
        .task { await vm.restoreSession() }
        .task { await vm.startRealtimeUpdates() }
        .task { await vm.startMCPApprovalUpdates() }
        .task { await ContactsIndexService.warmCache() }
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

private struct TopBar: View {
    @Bindable var vm: InboxViewModel
    @FocusState private var isSearchFocused: Bool
    @State private var recentSearches: [String] = RecentSearchesStore.load()
    @State private var searchBarFrame: CGRect = .zero
    @State private var dropdownFrame: CGRect = .zero
    @State private var clickMonitor: Any?

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
                        .onKeyPress(.escape) {
                            isSearchFocused = false
                            return .handled
                        }
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
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { searchBarFrame = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { _, new in searchBarFrame = new }
                })
                .overlay(alignment: .topLeading) {
                    if isSearchFocused {
                        searchDropdown(width: searchBarWidth)
                            .offset(y: searchBarHeight + 4)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                            .background(GeometryReader { geo in
                                Color.clear
                                    .onAppear { dropdownFrame = geo.frame(in: .global) }
                                    .onChange(of: geo.frame(in: .global)) { _, new in dropdownFrame = new }
                            })
                    }
                }

                Spacer()

                ConnectivityIndicator(vm: vm)
            }
        }
        .frame(height: searchBarHeight)
        .animation(.easeOut(duration: 0.16), value: isSearchFocused)
        .onChange(of: isSearchFocused) { _, focused in
            if !focused {
                dropdownFrame = .zero
            } else {
                // Re-read from disk on every reopen — a search can get
                // recorded from the debounced full-text search in
                // InboxViewModel (see performFullTextSearch), not only via
                // this view's own commitSearch, so this instance's
                // `recentSearches` can otherwise go stale between opens.
                recentSearches = RecentSearchesStore.load()
            }
        }
        .onAppear { installClickMonitorIfNeeded() }
        .onDisappear {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
        }
    }

    /// SwiftUI's automatic "resign focus when something else is clicked"
    /// doesn't reliably fire in this app — there are several
    /// NSViewRepresentable-hosted views elsewhere (the HTML reading pane,
    /// the compose rich text editor) that can grab AppKit's real first
    /// responder without SwiftUI's FocusState ever finding out, which is
    /// exactly what caused both reported symptoms: the dropdown staying
    /// open after clicking elsewhere, and — worse — isSearchFocused getting
    /// stuck at `true` internally so a later click back on the search field
    /// was a no-op (SwiftUI saw "already focused", so no new focus request
    /// ever went to AppKit) until switching apps forced a full responder-
    /// chain reset. Explicitly resigning on every click outside the search
    /// bar/dropdown — rather than hoping the implicit behavior kicks in —
    /// fixes both: the dropdown reliably closes, and every subsequent click
    /// on the search field is a genuine false->true transition SwiftUI
    /// actually acts on. The monitor never consumes the event (always
    /// returns it unmodified), so a click on some other button still
    /// performs that button's own action too.
    private func installClickMonitorIfNeeded() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            if isSearchFocused, let window = event.window {
                let windowHeight = window.contentView?.frame.height ?? 0
                // NSEvent.locationInWindow is bottom-left origin; SwiftUI's
                // .global coordinate space (captured above) is top-left.
                let point = CGPoint(x: event.locationInWindow.x, y: windowHeight - event.locationInWindow.y)
                if !searchBarFrame.contains(point) && !dropdownFrame.contains(point) {
                    isSearchFocused = false
                }
            }
            return event
        }
    }

    private var filteredRecents: [String] {
        let matches = vm.searchText.isEmpty
            ? recentSearches
            : recentSearches.filter { $0.localizedCaseInsensitiveContains(vm.searchText) }
        return Array(matches.prefix(6))
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
                    .font(.appSubheadline)
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
                // Archiving/trashing something already in that same folder
                // doesn't make sense — show the inverse (un-)action instead,
                // same reasoning as DetailToolbar below.
                if vm.selectedFolder == "trash" {
                    bulkButton("Restore", icon: "tray.and.arrow.up") { vm.bulkRestore() }
                } else if vm.selectedFolder == "archive" {
                    bulkButton("Unarchive", icon: "tray.and.arrow.down") { vm.bulkUnarchive() }
                    bulkButton("Delete", icon: "trash") { vm.bulkDelete() }
                } else {
                    bulkButton("Archive", icon: "archivebox") { vm.bulkArchive() }
                    bulkButton("Delete", icon: "trash") { vm.bulkDelete() }
                }
                // One button, not two — its label/action depend on whether
                // the whole selection is already unread (see
                // selectedMessagesAllUnread's doc comment for the exact
                // Gmail-matching rule).
                if vm.selectedMessagesAllUnread {
                    bulkButton("Mark Read", icon: "envelope.open") { vm.bulkMarkRead(true) }
                } else {
                    bulkButton("Mark Unread", icon: "envelope.badge") { vm.bulkMarkRead(false) }
                }

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
            Label(title, systemImage: icon).font(.appSubheadline.weight(.medium))
        }
        .buttonStyle(.pointerPlain)
        .foregroundStyle(.secondary)
    }
}

/// Replaces `ListToolbar` in the same row the moment a thread opens —
/// Gmail-style: back, archive/unarchive, trash/restore, mark read/unread,
/// plus Reply/Reply All/Forward on the right (moved up from a separate pill
/// row under every expanded message — one consistent place per thread
/// instead of one per message). Acts on the whole open conversation, same
/// as swiping a collapsed row in the list.
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

            // Archiving from Archive, or trashing from Trash, is a
            // meaningless action — show the inverse instead so there's
            // always exactly one sensible "move it back" button.
            if vm.selectedFolder == "archive" {
                Button { vm.unarchiveThread(thread) } label: {
                    Image(systemName: "tray.and.arrow.down").iconButtonHitArea()
                }
                .buttonStyle(.pointerPlain)
                .foregroundStyle(.secondary)

                Button { vm.deleteThread(thread) } label: {
                    Image(systemName: "trash").iconButtonHitArea()
                }
                .buttonStyle(.pointerPlain)
                .foregroundStyle(.secondary)
            } else if vm.selectedFolder == "trash" {
                Button { vm.restoreThread(thread) } label: {
                    Image(systemName: "tray.and.arrow.up").iconButtonHitArea()
                }
                .buttonStyle(.pointerPlain)
                .foregroundStyle(.secondary)
            } else {
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
            }

            Divider().frame(height: 16).overlay(Color.appBorder)

            Button { vm.toggleThreadReadStatus(thread) } label: {
                Image(systemName: thread.latest.isRead ? "envelope.badge" : "envelope.open").iconButtonHitArea()
            }
            .buttonStyle(.pointerPlain)
            .foregroundStyle(.secondary)

            Spacer()

            ActionPill(title: "Reply", icon: "arrowshape.turn.up.left", tint: .white) {
                vm.composeContext = .reply(thread.latest)
            }
            ActionPill(title: "Reply All", icon: "arrowshape.turn.up.left.2", tint: .white) {
                vm.composeContext = .replyAll(thread.latest)
            }
            ActionPill(title: "Forward", icon: "arrowshape.turn.up.right", tint: .white) {
                vm.composeContext = .forward(thread.latest)
            }
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
    ContentView(vm: InboxViewModel())
        .frame(width: 1100, height: 700)
        .preferredColorScheme(.dark)
}
