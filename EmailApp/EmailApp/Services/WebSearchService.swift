import Foundation

/// Free, keyless web search so local Ollama drafts can ground themselves in
/// current facts instead of stale training data — scrapes DuckDuckGo's
/// no-JS "lite" HTML result page (no API key, no rate-limit signup).
/// Best-effort only: any failure (offline, markup change) just yields no
/// results and the caller falls back to the model's own knowledge.
enum WebSearchService {
    struct Result { let title: String; let snippet: String }

    static func search(_ query: String, limit: Int = 4) async -> [Result] {
        var comps = URLComponents(string: "https://lite.duckduckgo.com/lite/")!
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps.url else { return [] }

        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        // DDG's lite endpoint 403s requests with no browser-like UA.
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15) Threadwell/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8)
            else { return [] }
            return parse(html, limit: limit)
        } catch {
            return []
        }
    }

    private static func parse(_ html: String, limit: Int) -> [Result] {
        let titles = matches(in: html, pattern: #"class="result-link"[^>]*>([\s\S]*?)</a>"#)
        let snippets = matches(in: html, pattern: #"class="result-snippet">([\s\S]*?)</td>"#)
        var results: [Result] = []
        for i in 0..<min(titles.count, snippets.count) {
            let title = decodeEntities(stripTags(titles[i]))
            let snippet = decodeEntities(stripTags(snippets[i]))
            if !title.isEmpty { results.append(Result(title: title, snippet: snippet)) }
            if results.count >= limit { break }
        }
        return results
    }

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            match.range(at: 1).location != NSNotFound ? ns.substring(with: match.range(at: 1)) : nil
        }
    }

    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
