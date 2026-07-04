import SwiftUI

private struct FieldHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 36
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Simple wrapping flow layout — chips wrap to a new line instead of
/// overflowing or forcing horizontal scroll, like Mail.app's To field.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A To/Cc/Bcc field: existing recipients render as removable chips, typing
/// searches the contacts index and shows a dropdown below the field —
/// arrow keys + Return (or a click) select a suggestion, comma or Return
/// commits whatever's typed as a raw chip when there's no selection.
struct RecipientChipField: View {
    let placeholder: String
    @Binding var emails: [String]
    var isDisabled: Bool = false

    @State private var draftText = ""
    @State private var suggestions: [Contact] = []
    @State private var highlightedIndex = 0
    @State private var fieldHeight: CGFloat = 36
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(emails, id: \.self) { email in
                chip(email)
            }
            TextField(emails.isEmpty ? placeholder : "", text: $draftText)
                .textFieldStyle(.plain)
                .font(.appSubheadline)
                .frame(minWidth: 100)
                .focused($isFieldFocused)
                .disabled(isDisabled)
                .onSubmit { commitDraftOrSelectHighlighted() }
                .onChange(of: draftText) { _, newValue in handleTextChange(newValue) }
                .onKeyPress(.downArrow) {
                    guard !suggestions.isEmpty else { return .ignored }
                    highlightedIndex = (highlightedIndex + 1) % suggestions.count
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard !suggestions.isEmpty else { return .ignored }
                    highlightedIndex = (highlightedIndex - 1 + suggestions.count) % suggestions.count
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard !suggestions.isEmpty else { return .ignored }
                    suggestions = []
                    return .handled
                }
                .onKeyPress(.delete) {
                    guard draftText.isEmpty, !emails.isEmpty else { return .ignored }
                    emails.removeLast()
                    return .handled
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.18)))
        .opacity(isDisabled ? 0.6 : 1)
        // The FlowLayout only lays out chips + the inline text field at
        // their own natural size, leaving empty space in the rest of the
        // box with nothing to receive a click — this makes a tap anywhere
        // in the box (not just directly on the field) focus it instead.
        .contentShape(Rectangle())
        .onTapGesture { if !isDisabled { isFieldFocused = true } }
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: FieldHeightPreferenceKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(FieldHeightPreferenceKey.self) { fieldHeight = $0 }
        // A floating overlay instead of a sibling in the VStack — the
        // dropdown appears on top of Subject/the editor below it instead
        // of pushing them down the way inline content would.
        .overlay(alignment: .topLeading) {
            if !suggestions.isEmpty {
                dropdown
                    .offset(y: fieldHeight + 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: suggestions.isEmpty)
    }

    private func chip(_ email: String) -> some View {
        HStack(spacing: 5) {
            Text(email)
                .font(.appCaption)
                .lineLimit(1)
            if !isDisabled {
                Button {
                    emails.removeAll { $0 == email }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.appHover))
        .fixedSize()
    }

    private var dropdown: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, contact in
                HStack(spacing: 10) {
                    Circle()
                        .fill(contact.avatarColor)
                        .frame(width: 26, height: 26)
                        .overlay(
                            Text(contact.initials)
                                .font(.appCaption2.weight(.semibold))
                                .foregroundStyle(.white)
                        )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(contact.displayName)
                            .font(.appSubheadline.weight(.medium))
                            .lineLimit(1)
                        Text(contact.email)
                            .font(.appCaption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(index == highlightedIndex ? Color.appHover : .clear)
                )
                .contentShape(Rectangle())
                .onTapGesture { selectContact(contact) }
            }
        }
        .padding(4)
        .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.appBorder))
    }

    private func handleTextChange(_ newValue: String) {
        if newValue.hasSuffix(",") {
            draftText = String(newValue.dropLast())
            commitRawEmail()
            return
        }
        // Synchronous, in-memory — no debounce needed, there's no network
        // round-trip to wait out anymore.
        suggestions = ContactsIndexService.search(prefix: newValue)
        highlightedIndex = 0
    }

    private func commitDraftOrSelectHighlighted() {
        if !suggestions.isEmpty, suggestions.indices.contains(highlightedIndex) {
            selectContact(suggestions[highlightedIndex])
        } else {
            commitRawEmail()
        }
    }

    private func commitRawEmail() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        draftText = ""
        suggestions = []
        guard !trimmed.isEmpty else { return }
        guard !emails.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        emails.append(trimmed)
    }

    private func selectContact(_ contact: Contact) {
        draftText = ""
        suggestions = []
        guard !emails.contains(where: { $0.caseInsensitiveCompare(contact.email) == .orderedSame }) else { return }
        emails.append(contact.email)
    }
}
