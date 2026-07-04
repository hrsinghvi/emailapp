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

            Group {
                if vm.selectedThread != nil {
                    ReadingPaneView(vm: vm)
                } else {
                    VStack(spacing: 10) {
                        TopBar(vm: vm)
                        ListToolbar(vm: vm)
                        if vm.selectedFolder == "drafts" {
                            DraftsListView(vm: vm)
                        } else {
                            MessageListView(vm: vm)
                        }
                    }
                }
            }
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
        .focusable()
        .focusEffectDisabled()
        .focused($isContentFocused)
        .onAppear { isContentFocused = true }
        .onKeyPress(.upArrow) { vm.selectAdjacent(-1); return .handled }
        .onKeyPress(.downArrow) { vm.selectAdjacent(1); return .handled }
        .onKeyPress(.return) { vm.openSelected(); return .handled }
        .onKeyPress(.delete) { vm.archiveFocused(); return .handled }
        .onKeyPress(.deleteForward) { vm.archiveFocused(); return .handled }
        .task { await vm.restoreSession() }
        .task { await vm.startRealtimeUpdates() }
        .overlay(alignment: .bottom) { PendingSendBannerStack(vm: vm) }
        .overlay(alignment: .bottomTrailing) {
            if let context = vm.composeContext {
                ComposeView(vm: vm, context: context, onClose: { vm.composeContext = nil })
                    .padding(20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
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

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search mail", text: $vm.searchText)
                    .textFieldStyle(.plain)
                    .font(.custom("DM Sans", size: 14))
                    .focused($isSearchFocused)
                    .onChange(of: vm.searchFocusTrigger) { _, _ in isSearchFocused = true }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 22))

            ConnectivityIndicator(vm: vm)
        }
    }
}

/// Gmail-style slim toolbar above the tabs — the checkbox is always
/// visible (not gated behind an active selection like `BulkActionBar`),
/// and refresh re-runs the same fetch `restoreSession()` does at launch.
private struct ListToolbar: View {
    @Bindable var vm: InboxViewModel
    @State private var isRefreshing = false

    var body: some View {
        HStack(spacing: 22) {
            Button {
                vm.toggleSelectAll()
            } label: {
                Image(systemName: allSelected ? "checkmark.square.fill" : "square")
                    .font(.custom("DM Sans", size: 15))
                    .foregroundStyle(allSelected ? Color.appAccent : .secondary)
            }
            .buttonStyle(.plain)

            Button {
                guard !isRefreshing else { return }
                isRefreshing = true
                Task {
                    await vm.refreshAll()
                    isRefreshing = false
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.custom("DM Sans", size: 15))
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    .animation(isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: isRefreshing)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            if range.total > 0 {
                Text("\(range.start + 1)–\(range.end) of \(range.total)")
                    .font(.appCaption)
                    .foregroundStyle(.secondary)

                Button { vm.goToPreviousPage() } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(vm.listPageIndex > 0 ? .secondary : Color.secondary.opacity(0.3))
                .disabled(vm.listPageIndex == 0)

                Button { vm.goToNextPage() } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .foregroundStyle(range.end < range.total ? .secondary : Color.secondary.opacity(0.3))
                .disabled(range.end >= range.total)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
    }

    private var range: (start: Int, end: Int, total: Int) { vm.listPageRange }

    private var allSelected: Bool {
        !vm.filteredThreads.isEmpty && Set(vm.filteredThreads.map(\.id)) == vm.selectedThreadKeys
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
