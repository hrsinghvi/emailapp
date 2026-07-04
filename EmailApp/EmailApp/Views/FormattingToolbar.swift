import SwiftUI

/// The Gmail-style compose toolbar. Primary row stays visible (bold,
/// italic, underline, strikethrough, alignment, lists); font family/size,
/// text color, indent/outdent, blockquote, link and image live under
/// "More" to keep the primary row uncluttered.
struct FormattingToolbar: View {
    let controller: RichTextEditorController
    let onInsertLink: () -> Void
    let onInsertImage: () -> Void
    let onAttachFile: () -> Void

    @State private var textColor: Color = .primary

    private static let fontFamilies = ["System", "Helvetica Neue", "Times New Roman", "Courier New", "Georgia", "Arial"]
    private static let fontSizes: [CGFloat] = [10, 12, 14, 16, 18, 24, 32]

    var body: some View {
        HStack(spacing: 4) {
            toolButton("bold") { controller.toggleBold() }
            toolButton("italic") { controller.toggleItalic() }
            toolButton("underline") { controller.toggleUnderline() }
            toolButton("strikethrough") { controller.toggleStrikethrough() }

            Divider().frame(height: 16)

            toolButton("list.bullet") { controller.toggleBulletList() }
            toolButton("list.number") { controller.toggleNumberedList() }

            Divider().frame(height: 16)

            toolButton("text.alignleft") { controller.setAlignment(.left) }
            toolButton("text.aligncenter") { controller.setAlignment(.center) }
            toolButton("text.alignright") { controller.setAlignment(.right) }
            toolButton("text.justify") { controller.setAlignment(.justified) }

            Spacer()

            Menu {
                Menu("Font") {
                    ForEach(Self.fontFamilies, id: \.self) { family in
                        Button(family) { controller.setFontFamily(family == "System" ? ".AppleSystemUIFont" : family) }
                    }
                }
                Menu("Size") {
                    ForEach(Self.fontSizes, id: \.self) { size in
                        Button("\(Int(size)) pt") { controller.setFontSize(size) }
                    }
                }
                ColorPicker("Text Color", selection: $textColor)
                    .onChange(of: textColor) { _, newValue in controller.setTextColor(NSColor(newValue)) }
                Divider()
                Button("Indent") { controller.indent() }
                Button("Outdent") { controller.outdent() }
                Button("Blockquote") { controller.toggleBlockquote() }
                Divider()
                Button("Insert Link…") { onInsertLink() }
                Button("Insert Image…") { onInsertImage() }
                Button("Attach File…") { onAttachFile() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 8))
    }

    private func toolButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.custom("Inter", size: 10))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.pointerPlain)
        .foregroundStyle(.secondary)
    }
}
