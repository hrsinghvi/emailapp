import AppKit

/// Mediates between SwiftUI toolbar buttons and the underlying `NSTextView`
/// (there's no SwiftUI-native rich text control, so `RichTextEditor` wraps
/// one and hands out this controller for the toolbar to drive). All
/// character-level actions fall back to `typingAttributes` when nothing is
/// selected, matching every rich text editor's behavior (toggle bold, then
/// type — the next characters come out bold).
@MainActor
final class RichTextEditorController {
    weak var textView: NSTextView?

    /// Set by ComposeView so ghost-text completion has the subject as
    /// context — the controller doesn't otherwise know it.
    var subjectProvider: () -> String = { "" }

    // MARK: - Ghost-text autocomplete (3g)

    /// The ghost suggestion's range in `textStorage`, when one is showing.
    /// Never reflected to `attributedText`/autosave/send — see `insertGhost`
    /// and `acceptGhost`'s doc comments for why.
    private var ghostRange: NSRange?
    private var completionTask: Task<Void, Never>?

    var hasGhost: Bool { ghostRange != nil }

    /// Removes any showing ghost text directly from storage WITHOUT calling
    /// `didChangeText()` — the insert never notified the delegate either
    /// (see `insertGhost`), so removing it the same way keeps the round
    /// trip invisible to `NSTextViewDelegate.textDidChange`, which is what
    /// `attributedText`/autosave/send all read from. If this ever called
    /// `didChangeText()`, a ghost that was inserted-then-removed on the
    /// same keystroke would still emit a spurious empty edit notification.
    func clearGhost() {
        guard let range = ghostRange, let storage = textView?.textStorage, NSMaxRange(range) <= storage.length else {
            ghostRange = nil
            return
        }
        storage.beginEditing()
        storage.deleteCharacters(in: range)
        storage.endEditing()
        ghostRange = nil
    }

    /// Debounced entry point — called after every real (non-ghost) text
    /// change. Cancels any in-flight request, waits out the pause, then
    /// only proceeds if nothing else changed the caret/ghost state in the
    /// meantime.
    func scheduleGhostSuggestion() {
        completionTask?.cancel()
        guard AppSettings.shared.autocompleteEnabled, let tv = textView else { return }
        completionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            guard await AIService.isAvailable() else { return }
            guard let tv = self.textView, let storage = tv.textStorage else { return }
            let caret = tv.selectedRange()
            guard caret.length == 0 else { return }
            let full = storage.string as NSString
            let start = max(0, caret.location - 500)
            let preceding = full.substring(with: NSRange(location: start, length: caret.location - start))
            guard !preceding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let suggestion: String
            do {
                suggestion = try await AIService.completeSentence(subject: self.subjectProvider(), precedingText: preceding)
            } catch {
                return
            }
            guard !Task.isCancelled, !suggestion.isEmpty else { return }
            // Caret may have moved while we were awaiting the network call
            // (more typing, a click) — stale suggestions for a stale
            // position are worse than no suggestion.
            guard tv.selectedRange() == caret, self.ghostRange == nil else { return }
            self.insertGhost(suggestion, at: caret.location)
        }
    }

    /// Inserted directly into storage, deliberately WITHOUT `didChangeText()`
    /// — layout still redraws the gray text (NSTextView redraws on any
    /// storage edit regardless), but skipping the delegate notification is
    /// what keeps this suggestion out of `textDidChange` -> `attributedText`
    /// -> autosave/send. The suggestion only ever becomes real content via
    /// `acceptGhost()`, which explicitly re-colors it and *does* call
    /// `didChangeText()`.
    private func insertGhost(_ text: String, at location: Int) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let attributed = NSAttributedString(string: text, attributes: [
            .font: currentTypingFont(),
            .foregroundColor: NSColor.white.withAlphaComponent(0.4),
        ])
        storage.beginEditing()
        storage.insert(attributed, at: location)
        storage.endEditing()
        ghostRange = NSRange(location: location, length: (text as NSString).length)
        tv.setSelectedRange(NSRange(location: location, length: 0))
    }

    /// Tab / Right-arrow when a ghost is showing: turns it into real typed
    /// content (white, caret moved past it, delegate notified so it
    /// actually saves/sends from here on). Returns false when there's
    /// nothing to accept, so the caller falls back to the key's normal
    /// behavior (real tab / real caret move).
    @discardableResult
    func acceptGhost() -> Bool {
        guard let range = ghostRange, let tv = textView, let storage = tv.textStorage, NSMaxRange(range) <= storage.length else {
            ghostRange = nil
            return false
        }
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.white, range: range)
        storage.endEditing()
        ghostRange = nil
        tv.setSelectedRange(NSRange(location: range.location + range.length, length: 0))
        tv.didChangeText()
        return true
    }

    private func withStorage(_ body: (NSTextStorage, NSRange) -> Void) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        guard range.length > 0 else { return }
        storage.beginEditing()
        body(storage, range)
        storage.endEditing()
        tv.didChangeText()
    }

    private func currentTypingFont() -> NSFont {
        (textView?.typingAttributes[.font] as? NSFont) ?? .systemFont(ofSize: 14)
    }

    // MARK: - Character traits

    func toggleBold() { toggleFontTrait(.boldFontMask, off: .unboldFontMask) }
    func toggleItalic() { toggleFontTrait(.italicFontMask, off: .unitalicFontMask) }

    private func toggleFontTrait(_ trait: NSFontTraitMask, off: NSFontTraitMask) {
        guard let tv = textView else { return }
        let manager = NSFontManager.shared
        if tv.selectedRange().length > 0 {
            withStorage { storage, range in
                storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
                    let font = (value as? NSFont) ?? .systemFont(ofSize: 14)
                    let has = manager.traits(of: font).contains(trait)
                    storage.addAttribute(.font, value: manager.convert(font, toHaveTrait: has ? off : trait), range: subrange)
                }
            }
        } else {
            let font = currentTypingFont()
            let has = manager.traits(of: font).contains(trait)
            tv.typingAttributes[.font] = manager.convert(font, toHaveTrait: has ? off : trait)
        }
    }

    func toggleUnderline() { toggleIntAttribute(.underlineStyle) }
    func toggleStrikethrough() { toggleIntAttribute(.strikethroughStyle) }

    private func toggleIntAttribute(_ key: NSAttributedString.Key) {
        guard let tv = textView else { return }
        if tv.selectedRange().length > 0 {
            withStorage { storage, range in
                let has = (storage.attribute(key, at: range.location, effectiveRange: nil) as? Int ?? 0) != 0
                storage.addAttribute(key, value: has ? 0 : NSUnderlineStyle.single.rawValue, range: range)
            }
        } else {
            let has = (tv.typingAttributes[key] as? Int ?? 0) != 0
            tv.typingAttributes[key] = has ? 0 : NSUnderlineStyle.single.rawValue
        }
    }

    func setTextColor(_ color: NSColor) {
        guard let tv = textView else { return }
        if tv.selectedRange().length > 0 {
            withStorage { storage, range in storage.addAttribute(.foregroundColor, value: color, range: range) }
        } else {
            tv.typingAttributes[.foregroundColor] = color
        }
    }

    func setFontFamily(_ name: String) {
        guard let tv = textView else { return }
        let apply: (NSFont) -> NSFont = { old in NSFontManager.shared.convert(NSFont(name: name, size: old.pointSize) ?? old, toHaveTrait: NSFontManager.shared.traits(of: old)) }
        if tv.selectedRange().length > 0 {
            withStorage { storage, range in
                storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
                    let font = (value as? NSFont) ?? .systemFont(ofSize: 14)
                    storage.addAttribute(.font, value: apply(font), range: subrange)
                }
            }
        } else {
            tv.typingAttributes[.font] = apply(currentTypingFont())
        }
    }

    func setFontSize(_ size: CGFloat) {
        guard let tv = textView else { return }
        if tv.selectedRange().length > 0 {
            withStorage { storage, range in
                storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
                    let font = (value as? NSFont) ?? .systemFont(ofSize: 14)
                    storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toSize: size), range: subrange)
                }
            }
        } else {
            tv.typingAttributes[.font] = NSFontManager.shared.convert(currentTypingFont(), toSize: size)
        }
    }

    // MARK: - Paragraph-level

    private func paragraphRanges(_ tv: NSTextView) -> [NSRange] {
        let ns = tv.string as NSString
        let selected = tv.selectedRange()
        let full = ns.paragraphRange(for: selected.length > 0 ? selected : NSRange(location: selected.location, length: 0))
        var ranges: [NSRange] = []
        ns.enumerateSubstrings(in: full, options: .byParagraphs) { _, range, _, _ in ranges.append(range) }
        return ranges.isEmpty ? [full] : ranges
    }

    func setAlignment(_ alignment: NSTextAlignment) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        storage.beginEditing()
        for range in paragraphRanges(tv) {
            let style = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.alignment = alignment
            storage.addAttribute(.paragraphStyle, value: style, range: range)
        }
        storage.endEditing()
        tv.didChangeText()
    }

    func indent() { adjustIndent(by: 24) }
    func outdent() { adjustIndent(by: -24) }

    private func adjustIndent(by delta: CGFloat) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        storage.beginEditing()
        for range in paragraphRanges(tv) {
            let style = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.headIndent = max(0, style.headIndent + delta)
            style.firstLineHeadIndent = max(0, style.firstLineHeadIndent + delta)
            storage.addAttribute(.paragraphStyle, value: style, range: range)
        }
        storage.endEditing()
        tv.didChangeText()
    }

    func toggleBulletList() { togglePrefixedList(marker: "•\t") }
    func toggleNumberedList() { togglePrefixedList(marker: nil) }

    /// Text-prefix lists (not TextKit's `NSTextList`) — simpler to get right
    /// and visually identical to what a toolbar list button produces in
    /// every mainstream rich text editor.
    private func togglePrefixedList(marker: String?) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let ranges = paragraphRanges(tv)
        storage.beginEditing()
        var offset = 0
        for (index, originalRange) in ranges.enumerated() {
            var range = originalRange
            range.location += offset
            let line = (storage.string as NSString).substring(with: range)
            let prefix = marker ?? "\(index + 1).\t"
            if line.hasPrefix(prefix) || (marker == nil && line.range(of: "^\\d+\\.\\t", options: .regularExpression) != nil) {
                let stripLength = marker?.count ?? (line as NSString).range(of: "^\\d+\\.\\t", options: .regularExpression).length
                storage.replaceCharacters(in: NSRange(location: range.location, length: stripLength), with: "")
                offset -= stripLength
            } else {
                storage.replaceCharacters(in: NSRange(location: range.location, length: 0), with: prefix)
                let style = NSMutableParagraphStyle()
                style.headIndent = 20
                storage.addAttribute(.paragraphStyle, value: style, range: NSRange(location: range.location, length: prefix.count + range.length))
                offset += prefix.count
            }
        }
        storage.endEditing()
        tv.didChangeText()
    }

    func toggleBlockquote() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        storage.beginEditing()
        for range in paragraphRanges(tv) {
            let existing = storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
            let isQuoted = existing == .secondaryLabelColor
            let style = NSMutableParagraphStyle()
            style.headIndent = isQuoted ? 0 : 16
            style.firstLineHeadIndent = isQuoted ? 0 : 16
            storage.addAttribute(.paragraphStyle, value: style, range: range)
            storage.addAttribute(.foregroundColor, value: isQuoted ? NSColor.textColor : NSColor.secondaryLabelColor, range: range)
        }
        storage.endEditing()
        tv.didChangeText()
    }

    // MARK: - Insertions

    func insertLink(text: String, url: String) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        let attributed = NSMutableAttributedString(string: text, attributes: tv.typingAttributes)
        attributed.addAttribute(.link, value: url, range: NSRange(location: 0, length: text.count))
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: attributed)
        storage.endEditing()
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: range.location + text.count, length: 0))
    }

    func insertImage(_ image: NSImage) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let attachment = NSTextAttachment()
        attachment.image = image
        let maxWidth: CGFloat = 360
        let scale = min(1, maxWidth / max(image.size.width, 1))
        attachment.bounds = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
        let attributed = NSAttributedString(attachment: attachment)
        let range = tv.selectedRange()
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: attributed)
        storage.endEditing()
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: range.location + 1, length: 0))
    }
}
