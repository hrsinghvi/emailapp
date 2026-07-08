import SwiftUI

/// Floating "Sending… [Undo]" banners for the 8-second Undo Send window.
/// One per pending send, stacked if somehow more than one is in flight.
struct PendingSendBannerStack: View {
    @Bindable var vm: InboxViewModel

    var body: some View {
        VStack(spacing: 8) {
            ForEach(vm.pendingSends) { pending in
                PendingSendBanner(vm: vm, pending: pending)
            }
        }
        .padding(.top, 44)
        .padding(.trailing, 16)
    }
}

private struct PendingSendBanner: View {
    @Bindable var vm: InboxViewModel
    let pending: InboxViewModel.PendingSend
    @State private var remaining: Int = 0

    var body: some View {
        HStack(spacing: 14) {
            ProgressView()
                .controlSize(.regular)
            Text("Sending… (\(remaining)s)")
                .font(.appTitle2)
            Button("Undo") { vm.undoSend(pending.id) }
                .buttonStyle(.pointerPlain)
                .font(.appTitle2.weight(.semibold))
                .foregroundStyle(Color.appAccent)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Color.appSurfaceRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.appBorder))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .onAppear { remaining = max(0, Int(pending.scheduledAt.timeIntervalSinceNow.rounded(.up))) }
        .task {
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                remaining = max(0, remaining - 1)
            }
        }
    }
}
