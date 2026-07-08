import SwiftUI

/// "Sending… [Undo]" pill(s) for the 8-second Undo Send window, docked
/// inline in the top bar (same row/height as the search bar, same width as
/// the sidebar's Compose button) instead of floating over the app.
struct PendingSendBannerStack: View {
    @Bindable var vm: InboxViewModel
    let height: CGFloat
    let width: CGFloat

    var body: some View {
        VStack(spacing: 8) {
            ForEach(vm.pendingSends) { pending in
                PendingSendBanner(vm: vm, pending: pending, height: height, width: width)
            }
        }
    }
}

private struct PendingSendBanner: View {
    @Bindable var vm: InboxViewModel
    let pending: InboxViewModel.PendingSend
    let height: CGFloat
    let width: CGFloat
    @State private var remaining: Int = 0

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Sending… (\(remaining)s)")
                .font(.appSubheadline)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Undo") { vm.undoSend(pending.id) }
                .buttonStyle(.pointerPlain)
                .font(.appSubheadline.weight(.semibold))
                .foregroundStyle(Color.appAccent)
        }
        .padding(.horizontal, 16)
        .frame(width: width, height: height)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 22))
        .onAppear { remaining = max(0, Int(pending.scheduledAt.timeIntervalSinceNow.rounded(.up))) }
        .task {
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                remaining = max(0, remaining - 1)
            }
        }
    }
}
