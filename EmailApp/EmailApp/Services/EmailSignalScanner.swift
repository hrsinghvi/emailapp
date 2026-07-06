import Foundation

/// Pure regex/heuristic scan, no LLM — feeds the auto summary card (3h).
/// Runs once per message open; if nothing matches, no card is ever shown.
enum EmailSignalScanner {
    struct Signal: Identifiable {
        let id = UUID()
        let text: String
    }

    private static let commitmentWords = ["deadline", "due", "by end of", "expires", "expiring", "no later than", "before"]
    private static let datePattern = try! NSRegularExpression(
        pattern: #"\b(\d{1,2}[/-]\d{1,2}([/-]\d{2,4})?|\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(st|nd|rd|th)?)\b"#,
        options: .caseInsensitive
    )
    private static let confirmationPattern = try! NSRegularExpression(
        pattern: #"\b(confirmation|booking|order|reservation|reference|invoice)\s*(#|number|no\.?)?\s*[:#]?\s*([A-Z0-9]{5,})\b"#,
        options: .caseInsensitive
    )

    static func scan(_ message: Message, isBcc: Bool, senderSignal: SenderReputationService.Signal) -> [Signal] {
        var signals: [Signal] = []
        let text = message.body
        let lower = text.lowercased()

        // Deadline/date near a commitment word — cheap proximity check
        // (same sentence-ish window) rather than a full NLP pass.
        if commitmentWords.contains(where: { lower.contains($0) }) {
            let ns = text as NSString
            if let match = datePattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                signals.append(Signal(text: "Deadline mentioned: \(ns.substring(with: match.range))"))
            } else {
                signals.append(Signal(text: "Mentions a deadline"))
            }
        }

        let ns = text as NSString
        if let match = confirmationPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            signals.append(Signal(text: "Contains a reference: \(ns.substring(with: match.range))"))
        }

        if isBcc {
            signals.append(Signal(text: "You were bcc'd"))
        }

        if senderSignal.isFirstContact {
            signals.append(Signal(text: "First message from this sender"))
        }

        return signals
    }
}
