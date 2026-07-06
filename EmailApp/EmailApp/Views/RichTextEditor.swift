import AppKit
import SwiftUI

/// NSTextView-backed rich text editor. A WKWebView `contentEditable` +
/// `execCommand` approach was the other option, but `execCommand` is
/// deprecated across all engines with no replacement for several of the
/// commands this needs (lists, indent) — TextKit natively supports every
/// formatting operation the toolbar exposes, and round-trips to HTML via
/// `NSAttributedString`'s built-in reader/writer for storage and sending.
struct RichTextEditor: NSViewRepresentable {
    @Binding var attributedText: NSAttributedString
    let controller: RichTextEditorController

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.font = .systemFont(ofSize: 14)
        // `.textColor` is a dynamic color that resolves off the view's own
        // NSAppearance — this app is forced dark-only via SwiftUI's
        // `.preferredColorScheme`, which the hosted NSTextView doesn't
        // inherit, so it was resolving to black. Force dark appearance
        // directly instead of relying on a dynamic color.
        textView.appearance = NSAppearance(named: .darkAqua)
        textView.textColor = .white
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.typingAttributes = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.white]
        textView.textStorage?.setAttributedString(attributedText)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        controller.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        controller.textView = textView
        // Only push external changes in (e.g. loading a draft) — don't
        // stomp on the user's live typing/cursor position every re-render.
        // Also skipped while a ghost suggestion (3g) is showing — it lives
        // directly in `textStorage` without ever reaching `attributedText`
        // (see RichTextEditorController.insertGhost's doc comment), so
        // comparing the two here always "differs" while a ghost is up; if
        // this stomped it back to `attributedText` mid-display, `ghostRange`
        // would still point at the now-deleted characters and the next
        // clearGhost()/acceptGhost() would mutate out of bounds.
        if !context.coordinator.isEditingInternally, !controller.hasGhost, textView.attributedString() != attributedText {
            textView.textStorage?.setAttributedString(attributedText)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        var isEditingInternally = false

        init(_ parent: RichTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            isEditingInternally = true
            parent.attributedText = textView.attributedString()
            isEditingInternally = false
        }

        /// Tab / Right-arrow accept a showing ghost suggestion (3g) instead
        /// of their normal effect — these are commands, not text, so they
        /// never reach `shouldChangeTextIn` below.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard parent.controller.hasGhost else { return false }
            if commandSelector == #selector(NSResponder.insertTab(_:)) || commandSelector == #selector(NSResponder.moveRight(_:)) {
                return parent.controller.acceptGhost()
            }
            return false
        }

        /// Live markdown-shortcut conversion: on space or return, checks the
        /// text just typed for a markdown pattern and replaces it with the
        /// equivalent formatting — same trigger convention as Notion/Slack.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            // Any real keystroke clears a showing ghost first (3g) — the
            // user's typed character should land in a clean document, not
            // interleaved with unaccepted suggestion text. Tab/Right-arrow
            // never reach here (they're commands, handled in
            // doCommandBy above), so this only fires for genuine edits.
            parent.controller.clearGhost()
            defer { parent.controller.scheduleGhostSuggestion() }

            guard let trigger = replacementString, trigger == " " || trigger == "\n" else { return true }
            guard let storage = textView.textStorage else { return true }
            let full = storage.string as NSString
            let paragraphRange = full.paragraphRange(for: NSRange(location: range.location, length: 0))
            let lineText = full.substring(with: NSRange(location: paragraphRange.location, length: range.location - paragraphRange.location))

            if trigger == " ", applyBlockPattern(lineText, lineStart: paragraphRange.location, cursor: range.location, textView: textView) {
                return false
            }
            _ = applyInlinePattern(lineText, lineStart: paragraphRange.location, textView: textView)
            return true
        }

        // MARK: - Block patterns (heading / list / blockquote)

        private func applyBlockPattern(_ lineText: String, lineStart: Int, cursor: Int, textView: NSTextView) -> Bool {
            guard let storage = textView.textStorage else { return false }
            let markerRange = NSRange(location: lineStart, length: cursor - lineStart)

            func consume(_ replacement: String, attributesAfter: [NSAttributedString.Key: Any]? = nil) {
                storage.beginEditing()
                storage.replaceCharacters(in: markerRange, with: replacement)
                storage.endEditing()
                textView.didChangeText()
                let cursorLoc = lineStart + (replacement as NSString).length
                textView.setSelectedRange(NSRange(location: cursorLoc, length: 0))
                if let attributesAfter { textView.typingAttributes = attributesAfter }
            }

            if let level = headingLevel(lineText) {
                let size: CGFloat = level == 1 ? 22 : (level == 2 ? 18 : 15)
                consume("", attributesAfter: [.font: NSFont.boldSystemFont(ofSize: size), .foregroundColor: NSColor.textColor])
                return true
            }
            if lineText == "-" || lineText == "*" {
                consume("•\t")
                applyHangingIndent(textView, over: NSRange(location: lineStart, length: 2))
                return true
            }
            if isNumberedMarker(lineText) {
                consume("\(lineText)\t")
                applyHangingIndent(textView, over: NSRange(location: lineStart, length: (lineText as NSString).length + 1))
                return true
            }
            if lineText == ">" {
                consume("", attributesAfter: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor])
                let style = NSMutableParagraphStyle()
                style.headIndent = 16
                style.firstLineHeadIndent = 16
                textView.typingAttributes[.paragraphStyle] = style
                return true
            }
            return false
        }

        private func headingLevel(_ s: String) -> Int? {
            switch s {
            case "#": return 1
            case "##": return 2
            case "###": return 3
            default: return nil
            }
        }

        private func isNumberedMarker(_ s: String) -> Bool {
            guard s.hasSuffix("."), s.count > 1 else { return false }
            return Int(s.dropLast()) != nil
        }

        private func applyHangingIndent(_ textView: NSTextView, over range: NSRange) {
            guard let storage = textView.textStorage else { return }
            let paragraphRange = (storage.string as NSString).paragraphRange(for: range)
            let style = NSMutableParagraphStyle()
            style.headIndent = 20
            storage.addAttribute(.paragraphStyle, value: style, range: paragraphRange)
        }

        // MARK: - Inline patterns (bold / italic / link)

        private func applyInlinePattern(_ lineText: String, lineStart: Int, textView: NSTextView) -> Bool {
            guard let storage = textView.textStorage else { return false }

            if let m = match(lineText, pattern: "\\*\\*([^*]+)\\*\\*$") {
                replaceInline(storage, textView: textView, lineStart: lineStart, match: m) { attrs in
                    let base = (attrs[.font] as? NSFont) ?? .systemFont(ofSize: 14)
                    attrs[.font] = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
                }
                return true
            }
            if let m = match(lineText, pattern: "(?<!\\*)\\*([^*]+)\\*$") {
                replaceInline(storage, textView: textView, lineStart: lineStart, match: m) { attrs in
                    let base = (attrs[.font] as? NSFont) ?? .systemFont(ofSize: 14)
                    attrs[.font] = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
                }
                return true
            }
            if let m = match(lineText, pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)$"), m.groups.count > 1 {
                let url = m.groups[1]
                replaceInline(storage, textView: textView, lineStart: lineStart, match: m, groupIndex: 0) { attrs in
                    attrs[.link] = url
                    attrs[.foregroundColor] = NSColor.linkColor
                }
                return true
            }
            return false
        }

        private struct RegexMatch { let fullRange: NSRange; let groups: [String] }

        private func match(_ text: String, pattern: String) -> RegexMatch? {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            let ns = text as NSString
            guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
            var groups: [String] = []
            for i in 1..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            return RegexMatch(fullRange: m.range, groups: groups)
        }

        private func replaceInline(
            _ storage: NSTextStorage, textView: NSTextView, lineStart: Int, match: RegexMatch,
            groupIndex: Int = 0, attributes: (inout [NSAttributedString.Key: Any]) -> Void
        ) {
            let displayText = groupIndex < match.groups.count ? match.groups[groupIndex] : ""
            let absoluteRange = NSRange(location: lineStart + match.fullRange.location, length: match.fullRange.length)
            var attrs = textView.typingAttributes
            attributes(&attrs)
            let replacement = NSAttributedString(string: displayText, attributes: attrs)
            storage.beginEditing()
            storage.replaceCharacters(in: absoluteRange, with: replacement)
            storage.endEditing()
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: absoluteRange.location + displayText.count, length: 0))
        }
    }
}
