import AppKit

/// Round-trips the compose editor's rich text through HTML — the format
/// drafts are stored in and messages are sent as. Uses Foundation's built-in
/// HTML reader/writer rather than a hand-rolled serializer.
extension NSAttributedString {
    convenience init?(html: String) {
        guard let data = html.data(using: .utf8) else { return nil }
        guard let loaded = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ) else { return nil }
        self.init(attributedString: loaded)
    }

    func htmlString() -> String {
        guard length > 0 else { return "" }
        guard let data = try? data(
            from: NSRange(location: 0, length: length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
        ) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// The compose editor is forced to a dark background, so its only
    /// supported text color is white — but most recipients' inboxes (Gmail
    /// included) render on a white background, where white text would be
    /// invisible. Sending uses this instead of `htmlString()` to flip every
    /// character to black right before it leaves the app; the draft/local
    /// copy stays white for editing.
    func htmlStringForSending() -> String {
        let recolored = NSMutableAttributedString(attributedString: self)
        recolored.addAttribute(.foregroundColor, value: NSColor.black, range: NSRange(location: 0, length: recolored.length))
        return recolored.htmlString()
    }
}
