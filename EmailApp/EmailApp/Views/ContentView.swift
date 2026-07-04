import SwiftUI

struct ContentView: View {
    @Bindable var vm: InboxViewModel
    @FocusState private var isContentFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            SidebarView(vm: vm)
                .frame(width: 240)

            Group {
                if vm.selectedThread != nil {
                    ReadingPaneView(vm: vm)
                } else {
                    VStack(spacing: 10) {
                        TopBar(vm: vm)
                        ListToolbar(vm: vm)
                        if vm.selectedFolder == "inbox" {
                            CategoryTabBar(vm: vm)
                        }
                        if vm.selectedFolder == "drafts" {
                            DraftsListView(vm: vm)
                        } else {
                            MessageListView(vm: vm)
                        }
                    }
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 34)
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
                    .font(.system(size: 14))
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
                    .font(.system(size: 16))
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
                    .font(.system(size: 15))
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    .animation(isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: isRefreshing)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
    }

    private var allSelected: Bool {
        !vm.filteredThreads.isEmpty && Set(vm.filteredThreads.map(\.id)) == vm.selectedThreadKeys
    }
}

/// Gmail-style category tabs — icon + label, active tab gets an accent
/// underline. Classification is a sender/subject heuristic
/// (`MessageCategory.classify`), not real ML.
private struct CategoryTabBar: View {
    @Bindable var vm: InboxViewModel

    var body: some View {
        HStack(spacing: 64) {
            ForEach(MessageCategory.allCases, id: \.self) { category in
                Button {
                    vm.categoryFilter = category
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: category.icon)
                            .font(.system(size: 16))
                        Text(category.label)
                            .font(.system(size: 15, weight: vm.categoryFilter == category ? .semibold : .regular))
                    }
                    .foregroundStyle(vm.categoryFilter == category ? .primary : .secondary)
                    .padding(.vertical, 14)
                    .overlay(alignment: .bottom) {
                        if vm.categoryFilter == category {
                            Rectangle().fill(Color.appAccent).frame(height: 2)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .overlay(alignment: .bottom) { Divider().overlay(Color.appBorder) }
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
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.orange.opacity(0.15)))
        } else if !vm.offlineQueue.isEmpty {
            Label("Syncing \(vm.offlineQueue.count)…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption.weight(.medium))
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
