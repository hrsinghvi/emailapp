import SwiftUI

/// macOS Mail-style swipe: drag reveals a small icon badge at the edge
/// being swiped away — sized to exactly how far you've dragged (capped),
/// not a full-width bar — and crossing the threshold commits the action.
/// A single `DragGesture` per row is naturally exclusive — a trackpad only
/// drives one drag stream at a time, so there's no need for extra
/// bookkeeping to keep "only one swipe active" true.
struct SwipeableRow<Content: View>: View {
    let onSwipeRight: () -> Void
    let onSwipeLeft: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var dragOffset: CGFloat = 0
    private let threshold: CGFloat = 72
    private let badgeWidth: CGFloat = 64

    var body: some View {
        SwipeGestureHost(
            onHorizontalDelta: { dragOffset = $0 },
            onGestureEnd: commitOrSnapBack
        ) {
            ZStack {
                reveal
                content()
                    .offset(x: dragOffset)
                    .gesture(
                        DragGesture(minimumDistance: 12)
                            .onChanged { value in
                                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                                dragOffset = value.translation.width
                            }
                            .onEnded { _ in commitOrSnapBack() }
                    )
            }
        }
    }

    private func commitOrSnapBack() {
        if dragOffset > threshold {
            onSwipeRight()
        } else if dragOffset < -threshold {
            onSwipeLeft()
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragOffset = 0 }
    }

    @ViewBuilder
    private var reveal: some View {
        if dragOffset > 0 {
            HStack(spacing: 0) {
                badge(icon: "archivebox.fill", color: .green, width: min(dragOffset, badgeWidth))
                Spacer(minLength: 0)
            }
        } else if dragOffset < 0 {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                badge(icon: "envelope.badge.fill", color: .blue, width: min(-dragOffset, badgeWidth))
            }
        }
    }

    private func badge(icon: String, color: Color, width: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.85))
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .opacity(width > 28 ? 1 : 0)
        }
        .frame(width: max(0, width))
        .frame(maxHeight: .infinity)
        .clipped()
    }
}
