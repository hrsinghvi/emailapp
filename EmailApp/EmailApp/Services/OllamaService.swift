import Foundation

/// Talks to a local Ollama instance (localhost:11434) — the app's only
/// generation/embedding source, per the no-Anthropic-API-key constraint.
/// Never reachable from the Vercel backend, so every embedding call
/// happens here, in-app (see embeddings.ts's doc comment).
enum OllamaService {
    private static let baseURL = "http://localhost:11434"

    enum OllamaError: LocalizedError {
        case requestFailed(Int, String)
        case unavailable

        var errorDescription: String? {
            switch self {
            case .requestFailed(let code, let body): return "Ollama request failed (\(code)): \(body)"
            case .unavailable: return "Ollama is not running"
            }
        }
    }

    /// nomic-embed-text expects a `search_document:`/`search_query:` prefix
    /// on its inputs for good retrieval quality — without it, embeddings
    /// still come back but similarity ranking degrades. Backfill/realtime
    /// indexing use `.document`; search queries use `.query`. Keeping this
    /// one enum is what keeps the two paths from silently drifting apart.
    enum EmbedKind: String {
        case document = "search_document"
        case query = "search_query"
    }

    /// Batched embedding via /api/embed (not the older /api/embeddings,
    /// which only takes one string at a time). Returns one 768-dim vector
    /// per input, same order.
    static func embed(_ texts: [String], kind: EmbedKind) async throws -> [[Double]] {
        guard !texts.isEmpty else { return [] }
        struct Request: Encodable { let model: String; let input: [String] }
        struct Response: Decodable { let embeddings: [[Double]] }

        var req = URLRequest(url: URL(string: "\(baseURL)/api/embed")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Request(
            model: "nomic-embed-text",
            input: texts.map { "\(kind.rawValue): \($0)" }
        ))
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw OllamaError.requestFailed(code, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(Response.self, from: data).embeddings
    }

    /// Non-streaming single-shot generation via qwen2.5:7b — used wherever
    /// the caller just wants the final text (Phase 3's AIService builds on
    /// this; nothing in Phase 1 calls it yet).
    static func generate(prompt: String, system: String? = nil, maxTokens: Int = 512, temperature: Double = 0.7) async throws -> String {
        struct Options: Encodable { let num_predict: Int; let temperature: Double }
        struct Request: Encodable {
            let model: String
            let prompt: String
            let system: String?
            let stream: Bool
            let options: Options
        }
        struct Response: Decodable { let response: String }

        var req = URLRequest(url: URL(string: "\(baseURL)/api/generate")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Request(
            model: "qwen2.5:7b", prompt: prompt, system: system, stream: false, options: Options(num_predict: maxTokens, temperature: temperature)
        ))
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw OllamaError.requestFailed(code, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(Response.self, from: data).response
    }

    /// Streaming variant — Ollama's /api/generate with stream:true returns
    /// newline-delimited JSON objects, one per token chunk, terminated by
    /// one with "done":true. `onToken` is called on the main actor as each
    /// chunk arrives so callers can update UI directly.
    static func generateStreaming(
        prompt: String, system: String? = nil, maxTokens: Int = 512, temperature: Double = 0.7, onToken: @escaping @MainActor (String) -> Void
    ) async throws {
        struct Options: Encodable { let num_predict: Int; let temperature: Double }
        struct Request: Encodable {
            let model: String
            let prompt: String
            let system: String?
            let stream: Bool
            let options: Options
        }
        struct Chunk: Decodable { let response: String; let done: Bool }

        var req = URLRequest(url: URL(string: "\(baseURL)/api/generate")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Request(
            model: "qwen2.5:7b", prompt: prompt, system: system, stream: true, options: Options(num_predict: maxTokens, temperature: temperature)
        ))
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw OllamaError.requestFailed(code, "")
        }
        for try await line in bytes.lines {
            guard let lineData = line.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(Chunk.self, from: lineData)
            else { continue }
            await onToken(chunk.response)
            if chunk.done { break }
        }
    }

    /// Cached ~30s — callers (backfill loop, AI UI availability checks)
    /// hit this often; no need to round-trip to localhost every time.
    private static var cachedAvailability: (value: Bool, checkedAt: Date)?

    static func isAvailable() async -> Bool {
        if let cached = cachedAvailability, Date().timeIntervalSince(cached.checkedAt) < 30 {
            return cached.value
        }
        let available: Bool
        do {
            var req = URLRequest(url: URL(string: "\(baseURL)/api/tags")!)
            req.timeoutInterval = 3
            let (_, response) = try await URLSession.shared.data(for: req)
            available = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            available = false
        }
        cachedAvailability = (available, Date())
        return available
    }

    /// Model names from /api/tags, for the Settings status row — best
    /// effort, empty on any failure (caller already shows availability
    /// separately via `isAvailable`).
    static func listModels() async -> [String] {
        struct TagsResponse: Decodable { struct Model: Decodable { let name: String }; let models: [Model] }
        do {
            var req = URLRequest(url: URL(string: "\(baseURL)/api/tags")!)
            req.timeoutInterval = 3
            let (data, _) = try await URLSession.shared.data(for: req)
            return try JSONDecoder().decode(TagsResponse.self, from: data).models.map(\.name)
        } catch {
            return []
        }
    }
}
