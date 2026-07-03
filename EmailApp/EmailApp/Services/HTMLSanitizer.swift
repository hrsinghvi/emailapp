import Foundation

/// Strips executable/hijack-vector content from untrusted HTML email while
/// preserving everything visual (`<style>`, layout, images, links, tables).
/// This is defense-in-depth — `HTMLBodyView` also disables JS execution at
/// the WKWebView engine level, so nothing here can actually run even if a
/// pattern slips through.
enum HTMLSanitizer {
    static func sanitize(_ html: String) -> String {
        var result = html
        let patterns: [String] = [
            "<script[^>]*>[\\s\\S]*?</script>",
            "<iframe[^>]*>[\\s\\S]*?</iframe>",
            "<object[^>]*>[\\s\\S]*?</object>",
            "<embed[^>]*/?>",
            "<meta[^>]+http-equiv\\s*=\\s*[\"']refresh[\"'][^>]*>",
            "<base[^>]*>",
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        // Inline event handlers: onclick="...", onerror='...', etc.
        result = result.replacingOccurrences(
            of: "\\s+on\\w+\\s*=\\s*\"[^\"]*\"", with: "", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(
            of: "\\s+on\\w+\\s*=\\s*'[^']*'", with: "", options: [.regularExpression, .caseInsensitive])
        // javascript: URIs in href/src.
        result = result.replacingOccurrences(
            of: "(href|src)\\s*=\\s*\"javascript:[^\"]*\"", with: "$1=\"#\"",
            options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(
            of: "(href|src)\\s*=\\s*'javascript:[^']*'", with: "$1='#'",
            options: [.regularExpression, .caseInsensitive])
        return result
    }
}
