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

    /// Set by ComposeView to the signed-in-as account's display name — so
    /// ghost-text completion knows who's actually writing instead of Ollama
    /// guessing a random name to sign off with.
    var senderNameProvider: () -> String = { "" }

    /// Makes the body the key text view — used for reply/reply-all/forward,
    /// where the recipient is already fixed and typing the reply is the
    /// obvious next action, so the cursor should already be there.
    func focus() {
        guard let textView, let window = textView.window else { return }
        window.makeFirstResponder(textView)
    }

    // MARK: - Ghost-text autocomplete (3g)

    /// The ghost suggestion's range in `textStorage`, when one is showing —
    /// always exactly 1 character long (see `insertGhost`). Never reflected
    /// to `attributedText`/autosave/send — see `insertGhost` and
    /// `acceptGhost`'s doc comments for why.
    private var ghostRange: NSRange?
    /// The real suggestion text `acceptGhost()` substitutes in for the
    /// single placeholder character at `ghostRange` when accepted.
    private var ghostText: String?
    /// The body's real typing font/color at the moment the ghost was
    /// inserted, captured so `acceptGhost()` can reuse it exactly. Reading
    /// `currentTypingFont()` fresh at accept time instead used to produce a
    /// visibly different font: once the caret sits next to the ghost's
    /// attachment character, AppKit's automatic typing-attribute
    /// inheritance can pick up the attachment's own (dimmed) attributes,
    /// so the accepted text came out in whatever that attachment happened
    /// to carry rather than the surrounding body text's actual font.
    private var ghostFont: NSFont?
    private var ghostRealColor: NSColor?
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
        defer { ghostRange = nil; ghostText = nil; ghostFont = nil; ghostRealColor = nil }
        guard let range = ghostRange, let storage = textView?.textStorage, NSMaxRange(range) <= storage.length else { return }
        storage.beginEditing()
        storage.deleteCharacters(in: range)
        storage.endEditing()
    }

    /// Clears any showing ghost the same way `clearGhost()` does, but
    /// returns `range` re-expressed against storage as it will be *after*
    /// that removal — needed when the caller (a Cmd+A-then-type replace,
    /// say) already captured `range` before the ghost's 1-character
    /// removal shifts everything after it, which would otherwise apply the
    /// caller's edit at the wrong offset or short by one character.
    func clearGhostAdjusting(_ range: NSRange) -> NSRange {
        guard let ghost = ghostRange else { return range }
        defer { clearGhost() }
        if ghost.location < range.location {
            return NSRange(location: range.location - ghost.length, length: range.length)
        }
        if ghost.location >= range.location, NSMaxRange(ghost) <= NSMaxRange(range) {
            return NSRange(location: range.location, length: range.length - ghost.length)
        }
        return range
    }

    /// Debounced entry point — called after every real (non-ghost) text
    /// change. Cancels any in-flight request, waits out the pause, then
    /// only proceeds if nothing else changed the caret/ghost state in the
    /// meantime.
    func scheduleGhostSuggestion() {
        completionTask?.cancel()
        guard AppSettings.shared.aiFeaturesEnabled, AppSettings.shared.autocompleteEnabled, let tv = textView else { return }
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
                suggestion = try await AIService.completeSentence(subject: self.subjectProvider(), precedingText: preceding, senderName: self.senderNameProvider())
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

    /// Rendered as a single `NSTextAttachment` glyph (one placeholder
    /// character, U+FFFC) instead of the suggestion's real characters — a
    /// real multi-character insert let the caret land *inside* the
    /// suggestion (click, arrow keys, selection), making it look and behave
    /// like ordinary editable text instead of a suggestion you either
    /// accept whole or dismiss whole. An attachment can only be placed
    /// before or after as a single unit. Inserted WITHOUT `didChangeText()`
    /// — layout still redraws regardless, but skipping the delegate
    /// notification is what keeps this out of `textDidChange` ->
    /// `attributedText` -> autosave/send. Only `acceptGhost()` (which
    /// substitutes real text in for the placeholder and *does* call
    /// `didChangeText()`) turns it into real content.
    private func insertGhost(_ text: String, at location: Int) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let font = currentTypingFont()
        let realColor = (tv.typingAttributes[.foregroundColor] as? NSColor) ?? .white
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: realColor.withAlphaComponent(0.4)]
        let size = (text as NSString).size(withAttributes: attrs)
        guard size.width > 0, size.height > 0 else { return }
        let image = NSImage(size: size)
        image.lockFocus()
        (text as NSString).draw(at: .zero, withAttributes: attrs)
        image.unlockFocus()

        let attachment = NSTextAttachment()
        attachment.image = image
        // Baseline-align the rendered image with surrounding text instead
        // of the attachment's default vertical centering, which sits high.
        attachment.bounds = CGRect(x: 0, y: font.descender, width: size.width, height: size.height)

        storage.beginEditing()
        storage.insert(NSAttributedString(attachment: attachment), at: location)
        storage.endEditing()
        ghostRange = NSRange(location: location, length: 1)
        ghostText = text
        ghostFont = font
        ghostRealColor = realColor
        tv.setSelectedRange(NSRange(location: location, length: 0))
    }

    /// Tab / Right-arrow when a ghost is showing: substitutes the
    /// placeholder attachment for the suggestion's real, normally-colored
    /// text (caret moved past it, delegate notified so it actually
    /// saves/sends from here on). Returns false when there's nothing to
    /// accept, so the caller falls back to the key's normal behavior (real
    /// tab / real caret move).
    @discardableResult
    func acceptGhost() -> Bool {
        guard let range = ghostRange, let text = ghostText, let tv = textView, let storage = tv.textStorage,
              NSMaxRange(range) <= storage.length
        else {
            ghostRange = nil
            ghostText = nil
            ghostFont = nil
            ghostRealColor = nil
            return false
        }
        let real = NSAttributedString(string: text, attributes: [.font: ghostFont ?? currentTypingFont(), .foregroundColor: ghostRealColor ?? .white])
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: real)
        storage.endEditing()
        ghostRange = nil
        ghostText = nil
        ghostFont = nil
        ghostRealColor = nil
        tv.setSelectedRange(NSRange(location: range.location + real.length, length: 0))
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

    // MARK: - Inline image selection & resize (3g)

    /// The attachment character range currently showing resize chrome, if
    /// any — always exactly 1 character (an attachment is always a single
    /// placeholder glyph), same convention as `ghostRange`.
    private var selectedImageRange: NSRange?
    private weak var imageOverlay: ImageResizeOverlay?
    private var resizeStartWidth: CGFloat = 0

    /// Called by `ComposeTextView.mouseDown` when the click landed on an
    /// inline image glyph — selects that one character (so keyboard delete
    /// removes the whole image, matching how a click-selected image behaves
    /// in every rich text editor) and shows the resize/preset chrome.
    func selectImage(at range: NSRange) {
        guard let tv = textView, let storage = tv.textStorage,
              NSMaxRange(range) <= storage.length,
              let attachment = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment,
              let image = attachment.image
        else {
            deselectImage()
            return
        }
        selectedImageRange = range
        tv.setSelectedRange(range)
        showOverlay(for: range, attachment: attachment, image: image)
    }

    func deselectImage() {
        selectedImageRange = nil
        imageOverlay?.removeFromSuperview()
        imageOverlay = nil
    }

    private func showOverlay(for range: NSRange, attachment: NSTextAttachment, image: NSImage) {
        imageOverlay?.removeFromSuperview()
        guard let tv = textView, let layoutManager = tv.layoutManager, let container = tv.textContainer else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        rect.origin.x += tv.textContainerOrigin.x
        rect.origin.y += tv.textContainerOrigin.y

        let overlay = ImageResizeOverlay(frame: rect)
        resizeStartWidth = attachment.bounds.width
        overlay.onDrag = { [weak self] deltaX in
            self?.resizeImage(range: range, attachment: attachment, image: image, deltaX: deltaX)
        }
        overlay.onDragEnd = { [weak self] in self?.textView?.didChangeText() }
        overlay.onPreset = { [weak self] preset in self?.applyPreset(preset, range: range, attachment: attachment, image: image) }
        overlay.onRemove = { [weak self] in self?.removeImage(range: range) }
        tv.addSubview(overlay)
        imageOverlay = overlay
    }

    private func maxImageWidth() -> CGFloat {
        guard let container = textView?.textContainer else { return 360 }
        return max(container.size.width - 16, 40)
    }

    private func resizeImage(range: NSRange, attachment: NSTextAttachment, image: NSImage, deltaX: CGFloat) {
        guard let tv = textView else { return }
        let width = min(max(resizeStartWidth + deltaX, 40), maxImageWidth())
        let aspect = image.size.height / max(image.size.width, 1)
        attachment.bounds = CGRect(x: 0, y: 0, width: width, height: width * aspect)
        relayoutAttachment(range: range)
        repositionOverlay(for: range)
        _ = tv
    }

    private func applyPreset(_ preset: ImageResizeOverlay.ImagePreset, range: NSRange, attachment: NSTextAttachment, image: NSImage) {
        let maxWidth = maxImageWidth()
        let width: CGFloat
        switch preset {
        case .small: width = min(160, maxWidth)
        case .bestFit: width = min(360, maxWidth)
        case .original: width = min(image.size.width, maxWidth)
        }
        let aspect = image.size.height / max(image.size.width, 1)
        attachment.bounds = CGRect(x: 0, y: 0, width: width, height: width * aspect)
        resizeStartWidth = width
        relayoutAttachment(range: range)
        textView?.didChangeText()
        repositionOverlay(for: range)
    }

    private func relayoutAttachment(range: NSRange) {
        guard let layoutManager = textView?.layoutManager else { return }
        layoutManager.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        textView?.needsDisplay = true
    }

    private func repositionOverlay(for range: NSRange) {
        guard let tv = textView, let layoutManager = tv.layoutManager, let container = tv.textContainer, let overlay = imageOverlay else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        rect.origin.x += tv.textContainerOrigin.x
        rect.origin.y += tv.textContainerOrigin.y
        overlay.frame = rect
    }

    private func removeImage(range: NSRange) {
        guard let tv = textView, let storage = tv.textStorage, NSMaxRange(range) <= storage.length else { return }
        storage.beginEditing()
        storage.deleteCharacters(in: range)
        storage.endEditing()
        tv.didChangeText()
        deselectImage()
    }
}
