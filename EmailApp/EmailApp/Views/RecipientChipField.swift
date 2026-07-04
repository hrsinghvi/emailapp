import SwiftUI

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
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 8))
            .opacity(isDisabled ? 0.6 : 1)

            if !suggestions.isEmpty {
                dropdown
            }
        }
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
        scheduleSearch(draftText)
    }

    private func scheduleSearch(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            suggestions = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let results = await ContactsIndexService.search(prefix: trimmed)
            guard !Task.isCancelled else { return }
            suggestions = results
            highlightedIndex = 0
        }
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
