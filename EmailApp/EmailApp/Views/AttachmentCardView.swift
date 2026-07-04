import SwiftUI

/// Shared thumbnail-card look for both outgoing (Compose, removable) and
/// incoming (reading pane, click-to-save) attachments.
struct AttachmentCardView: View {
    let filename: String
    let sizeMB: Double
    var thumbnail: NSImage? = nil
    var systemIconName: String = "doc"
    var onRemove: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: systemIconName)
                            .font(.custom("DM Sans", size: 27))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 84, height: 60)
                .clipped()
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.appHover))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if let onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.black.opacity(0.65))
                            .font(.custom("DM Sans", size: 16))
                    }
                    .buttonStyle(.plain)
                    .padding(3)
                }
            }
            VStack(spacing: 1) {
                Text(filename)
                    .font(.appCaption2.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(String(format: "%.1f MB", max(sizeMB, 0.01)))
                    .font(.appCaption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 92)
        .padding(8)
        .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: 10))
    }
}

enum AttachmentIcon {
    static func systemName(forMimeType mimeType: String) -> String {
        if mimeType.hasPrefix("image/") { return "photo" }
        if mimeType == "application/pdf" { return "doc.richtext" }
        if mimeType.hasPrefix("video/") { return "film" }
        if mimeType.hasPrefix("audio/") { return "waveform" }
        if mimeType.contains("zip") || mimeType.contains("compressed") { return "doc.zipper" }
        if mimeType.contains("word") || mimeType.contains("text") { return "doc.text" }
        if mimeType.contains("sheet") || mimeType.contains("excel") { return "tablecells" }
        return "doc"
    }
}
