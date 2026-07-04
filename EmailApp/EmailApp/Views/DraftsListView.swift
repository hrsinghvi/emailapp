import SwiftUI

/// Drafts aren't provider messages — they're local unsent compose sessions
/// — so they get their own list rather than living in `MessageListView`.
struct DraftsListView: View {
    @Bindable var vm: InboxViewModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(vm.drafts) { draft in
                    DraftRow(draft: draft)
                        .contentShape(Rectangle())
                        .onTapGesture { vm.composeContext = .draft(draft) }
                        .contextMenu {
                            Button("Delete Draft", role: .destructive) { vm.deleteDraft(id: draft.id) }
                        }
                }
                if vm.drafts.isEmpty {
                    Text("No drafts")
                        .font(.appSubheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                }
            }
            .padding(8)
        }
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct DraftRow: View {
    let draft: Draft

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(0.25))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(draft.to.isEmpty ? "No recipient" : draft.to)
                        .font(.appSubheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Text(draft.lastModified, format: .relative(presentation: .numeric))
                        .font(.appCaption2)
                        .foregroundStyle(.secondary)
                }
                Text(draft.subject.isEmpty ? "(No subject)" : draft.subject)
                    .font(.appSubheadline)
                    .lineLimit(1)
                Text(draft.snippet)
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.clear))
    }
}
