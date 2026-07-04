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
        .padding(.bottom, 16)
    }
}

private struct PendingSendBanner: View {
    @Bindable var vm: InboxViewModel
    let pending: InboxViewModel.PendingSend
    @State private var remaining: Int = 0

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Sending… (\(remaining)s)")
                .font(.appSubheadline)
            Button("Undo") { vm.undoSend(pending.id) }
                .buttonStyle(.plain)
                .font(.appSubheadline.weight(.semibold))
                .foregroundStyle(Color.appAccent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.appSurfaceRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.appBorder))
        .onAppear { remaining = max(0, Int(pending.scheduledAt.timeIntervalSinceNow.rounded(.up))) }
        .task {
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                remaining = max(0, remaining - 1)
            }
        }
    }
}
