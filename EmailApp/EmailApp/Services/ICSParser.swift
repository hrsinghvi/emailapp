import Foundation

/// Minimal RFC 5545 VEVENT parser — just the fields the "Add to Calendar"
/// card needs (SUMMARY/DTSTART/DTEND/LOCATION/DESCRIPTION/UID), not a full
/// ICS implementation. Handles both floating dates (DTSTART:20260704T090000)
/// and UTC (...Z) and all-day (VALUE=DATE:20260704) forms, which covers
/// what Google/Outlook/Apple actually send in a meeting invite.
struct ParsedICSEvent {
    let uid: String?
    let title: String
    let description: String
    let location: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
}

enum ICSParser {
    static func parse(_ text: String) -> ParsedICSEvent? {
        // Unfold RFC 5545 line continuations (a line starting with a space
        // is a continuation of the previous line) before splitting.
        let unfolded = text
            .replacingOccurrences(of: "\r\n ", with: "")
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")

        guard let veventRange = unfolded.range(of: "BEGIN:VEVENT") else { return nil }
        let endRange = unfolded.range(of: "END:VEVENT", range: veventRange.upperBound..<unfolded.endIndex)
        let block = String(unfolded[veventRange.upperBound..<(endRange?.lowerBound ?? unfolded.endIndex)])

        var fields: [String: String] = [:]
        for line in block.split(separator: "\n") {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let keyPart = line[line.startIndex..<colonIndex]
            let value = String(line[line.index(after: colonIndex)...])
            // Strip parameters (DTSTART;TZID=America/Chicago -> DTSTART)
            let key = keyPart.split(separator: ";").first.map(String.init) ?? String(keyPart)
            fields[key] = unescape(value)
        }

        guard let dtStartRaw = fields["DTSTART"], let start = parseDate(dtStartRaw) else { return nil }
        let isAllDay = dtStartRaw.count == 8
        let end = fields["DTEND"].flatMap(parseDate) ?? start.addingTimeInterval(3600)

        return ParsedICSEvent(
            uid: fields["UID"],
            title: fields["SUMMARY"] ?? "(No title)",
            description: fields["DESCRIPTION"] ?? "",
            location: fields["LOCATION"] ?? "",
            startDate: start,
            endDate: end,
            isAllDay: isAllDay
        )
    }

    private static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func parseDate(_ raw: String) -> Date? {
        if raw.count == 8 {
            // All-day: VALUE=DATE, YYYYMMDD.
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd"
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter.date(from: raw)
        }
        let formatter = DateFormatter()
        formatter.timeZone = raw.hasSuffix("Z") ? TimeZone(identifier: "UTC") : TimeZone.current
        formatter.dateFormat = raw.hasSuffix("Z") ? "yyyyMMdd'T'HHmmss'Z'" : "yyyyMMdd'T'HHmmss"
        return formatter.date(from: raw)
    }
}
