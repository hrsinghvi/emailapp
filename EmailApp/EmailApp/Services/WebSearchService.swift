import Foundation

/// Grounds local Ollama drafts in current facts instead of stale training
/// data, via Tavily's search API (tavily.com — free tier, built for feeding
/// LLM context rather than raw HTML results). Requires the user's own API
/// key, entered in Settings and stored in Keychain — never left blank/no-op
/// silently forever, `SettingsView` surfaces whether a key is configured.
/// Best-effort only: any failure (no key, offline, bad response) just
/// yields no results and the caller falls back to the model's own
/// knowledge — this replaced an earlier DuckDuckGo HTML-scraping approach
/// that was unreliable enough to produce confidently wrong answers (see
/// commit history), which is worse than admitting "I don't know."
enum WebSearchService {
    struct Result { let title: String; let snippet: String; let url: String }

    static let keychainAccount = "ai-web-search-tavily-key"

    static func hasAPIKey() -> Bool {
        (try? KeychainService.loadString(account: keychainAccount))?.isEmpty == false
    }

    static func search(_ query: String, limit: Int = 4) async -> [Result] {
        guard let apiKey = (try? KeychainService.loadString(account: keychainAccount)) ?? nil, !apiKey.isEmpty else { return [] }

        var request = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "api_key": apiKey,
            "query": query,
            "max_results": max(limit, 6),
            "search_depth": "advanced",
            // Grounding queries here are always about current events (scores,
            // news, prices, schedules — see AIService.decideSearchQuery's
            // gate), so biasing toward recent/news results is strictly
            // better than Tavily's general-purpose default ranking.
            "topic": "news",
            "days": 3,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return [] }
        request.httpBody = payload

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
            let decoded = try JSONDecoder().decode(TavilyResponse.self, from: data)
            return decoded.results.prefix(limit).map { Result(title: $0.title, snippet: $0.content, url: $0.url) }
        } catch {
            return []
        }
    }

    private struct TavilyResponse: Decodable {
        struct Item: Decodable { let title: String; let content: String; let url: String }
        let results: [Item]
    }
}
