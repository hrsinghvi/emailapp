import SwiftUI

struct ContentView: View {
    @State private var vm = InboxViewModel()

    var body: some View {
        HStack(spacing: 12) {
            SidebarView(vm: vm)
                .frame(width: 240)

            VStack(spacing: 12) {
                TopBar(vm: vm)
                MessageListView(vm: vm)
            }
            .frame(minWidth: 320, idealWidth: 400)

            ReadingPaneView(vm: vm)
                .frame(minWidth: 380)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
        .background(
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                Color(hex: "#191919").opacity(0.35)
                WindowConfigurator()
            }
            .ignoresSafeArea()
        )
        .task { await vm.restoreSession() }
        .task { await vm.startRealtimeUpdates() }
        .sheet(item: $vm.composeContext) { context in
            ComposeView(vm: vm, context: context)
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

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $vm.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

            FilterChip(title: "All", tint: .white, isActive: vm.providerFilter == nil) {
                vm.providerFilter = nil
            }
            FilterChip(title: "Gmail", tint: Provider.gmail.color, isActive: vm.providerFilter == .gmail) {
                vm.providerFilter = .gmail
            }
            FilterChip(title: "Outlook", tint: Provider.outlook.color, isActive: vm.providerFilter == .outlook) {
                vm.providerFilter = .outlook
            }
        }
    }
}

private struct FilterChip: View {
    let title: String
    let tint: Color
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(isActive ? tint : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isActive ? tint.opacity(0.18) : Color.white.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView()
        .frame(width: 1100, height: 700)
        .preferredColorScheme(.dark)
}
