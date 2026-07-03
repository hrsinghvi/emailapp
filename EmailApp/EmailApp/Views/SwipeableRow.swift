import SwiftUI

/// macOS Mail-style swipe: drag reveals the action's icon/color
/// progressively, crossing the threshold commits it, releasing early
/// snaps back. A single `DragGesture` per row is naturally exclusive — a
/// trackpad only drives one drag stream at a time, so there's no need for
/// extra bookkeeping to keep "only one swipe active" true.
struct SwipeableRow<Content: View>: View {
    let onSwipeRight: () -> Void
    let onSwipeLeft: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var dragOffset: CGFloat = 0
    @GestureState private var isDragging = false
    private let threshold: CGFloat = 72

    var body: some View {
        ZStack {
            reveal
            content()
                .offset(x: dragOffset)
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .updating($isDragging) { _, state, _ in state = true }
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            dragOffset = value.translation.width
                        }
                        .onEnded { value in
                            if dragOffset > threshold {
                                onSwipeRight()
                            } else if dragOffset < -threshold {
                                onSwipeLeft()
                            }
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragOffset = 0 }
                        }
                )
        }
    }

    @ViewBuilder
    private var reveal: some View {
        if dragOffset != 0 {
            HStack {
                if dragOffset > 0 {
                    Label("Archive", systemImage: "archivebox.fill")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .padding(.leading, 20)
                        .opacity(min(1, dragOffset / threshold))
                    Spacer()
                } else {
                    Spacer()
                    Label("Mark Unread", systemImage: "envelope.badge.fill")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .padding(.trailing, 20)
                        .opacity(min(1, -dragOffset / threshold))
                }
            }
            .background(dragOffset > 0 ? Color.green.opacity(0.85) : Color.blue.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}
