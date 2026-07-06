import Foundation

/// Thin wrapper over `OllamaService` with email-context prompt builders.
/// Nothing here ever calls a paid API — see the plan's hard constraint 1.
/// All UI copy that surfaces this reads "Ask AI" / "qwen2.5 · local", never
/// "Claude", since Claude access only exists via the user's Pro plan + MCP.
enum AIService {
    /// Cached the same 30s window as `OllamaService.isAvailable` (it just
    /// forwards) — one place every AI affordance can check before showing
    /// a "not running" state.
    static func isAvailable() async -> Bool {
        await OllamaService.isAvailable()
    }

    /// qwen2.5:7b has no clock and no way to know "today" on its own — every
    /// system prompt gets the real current date/time computed fresh at call
    /// time (not cached/scheduled), so "yesterday"/"next week"/etc. in a
    /// user's instructions resolve against the actual date, not whatever the
    /// model's training data implies "now" is.
    private static var dateContext: String {
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMMM d, yyyy"
        let tf = DateFormatter()
        tf.dateFormat = "h:mm a"
        let now = Date()
        return "Today's date is \(df.string(from: now)), current time \(tf.string(from: now)). Resolve any relative dates the user mentions (\"today\", \"yesterday\", \"tomorrow\", \"last week\") against this."
    }

    /// Applied to every prompt that generates prose from scratch (not the
    /// short mechanical ones like ghost-text) — without this, qwen2.5:7b
    /// answers confidently wrong rather than admitting it doesn't know,
    /// which is worse than no answer for factual email content.
    private static let noHallucination =
        "If you don't know something, or weren't given enough information to answer accurately, say so plainly instead of guessing or inventing facts, names, or numbers."

    private static var groundedSystemPrefix: String { "\(dateContext) \(noHallucination)" }

    private static func threadContext(_ messages: [Message], limit: Int = 12) -> String {
        messages.suffix(limit).map { message in
            "From: \(message.senderName) <\(message.senderEmail)>\nDate: \(message.receivedAt)\nSubject: \(message.subject)\n\(message.body)"
        }.joined(separator: "\n\n---\n\n")
    }

    /// 3b/3e — answers a free-form question about the open thread.
    static func askAboutEmail(question: String, thread: [Message], onToken: @escaping @MainActor (String) -> Void) async throws {
        let system = "\(groundedSystemPrefix) You are an email assistant. Answer briefly and only using the provided email content."
        let prompt = "Email thread:\n\(threadContext(thread))\n\nQuestion: \(question)"
        try await OllamaService.generateStreaming(prompt: prompt, system: system, maxTokens: 400, onToken: onToken)
    }

    /// 3c — one-shot summary of a 3+ message thread.
    static func summarizeThread(_ messages: [Message]) async throws -> String {
        let system = "\(groundedSystemPrefix) You are an email assistant. Summarize the thread in 3-5 short bullet points, noting any open questions or action items."
        let prompt = "Email thread:\n\(threadContext(messages))"
        return try await OllamaService.generate(prompt: prompt, system: system, maxTokens: 350)
    }

    /// Lets the model decide for itself whether a draft request needs
    /// grounding in real-world facts (scores, news, prices, schedules) and,
    /// if so, what to search for — rather than blindly searching the raw
    /// instructions text (often a bad query: "write a thank you note to
    /// Sarah" produces junk results). Returns nil when no search is needed.
    private static func decideSearchQuery(for instructions: String) async -> String? {
        let system = "\(dateContext) Decide whether writing this email requires current or real-world facts you might not know reliably (news, scores, prices, schedules, dates). If yes, reply with ONLY a short web search query (3-8 words, no punctuation). If no search is needed, reply with exactly: NONE"
        let prompt = "Email request: \(instructions)"
        guard let result = try? await OllamaService.generate(prompt: prompt, system: system, maxTokens: 20) else { return nil }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.uppercased().contains("NONE") else { return nil }
        return trimmed
    }

    /// 3d — drafts a reply/new email body from a natural-language prompt,
    /// optionally with quoted thread context and a few past sent messages
    /// to the same recipient for tone matching. First asks the model
    /// whether it needs to search for anything, then grounds the actual
    /// draft with those results — qwen2.5:7b's training data is frozen at
    /// some past date, so current-events-shaped requests ("who won X
    /// yesterday") are wrong more often than not without this.
    static func draftEmail(instructions: String, quotedThread: [Message], pastSentToRecipient: [Message]) async throws -> String {
        var system = "\(groundedSystemPrefix) You are an email assistant. Write only the email body, no subject line, no greeting placeholders unless natural. Match the tone of past sent messages if provided."
        var prompt = "Instructions: \(instructions)"

        if let query = await decideSearchQuery(for: instructions) {
            let searchResults = await WebSearchService.search(query)
            if !searchResults.isEmpty {
                system += " Web search results are provided below — trust them over your own knowledge for facts, dates, and current events, since your training data may be outdated. If the results don't actually answer what's needed, say you're not sure rather than guessing."
                let block = searchResults.map { "- \($0.title): \($0.snippet)" }.joined(separator: "\n")
                prompt += "\n\nWeb search results for \"\(query)\":\n\(block)"
            }
        }
        if !quotedThread.isEmpty {
            prompt += "\n\nThread being replied to:\n\(threadContext(quotedThread, limit: 4))"
        }
        if !pastSentToRecipient.isEmpty {
            prompt += "\n\nPast messages I've sent this recipient (for tone):\n\(threadContext(pastSentToRecipient, limit: 3))"
        }
        return try await OllamaService.generate(prompt: prompt, system: system, maxTokens: 400)
    }

    enum RewriteStyle: String, CaseIterable {
        case polish, formalize, friendly, shorten

        var icon: String {
            switch self {
            case .polish: return "wand.and.stars"
            case .formalize: return "briefcase"
            case .friendly: return "hand.wave"
            case .shorten: return "arrow.down.right.and.arrow.up.left"
            }
        }
        var label: String {
            switch self {
            case .polish: return "Polish"
            case .formalize: return "Formalize"
            case .friendly: return "Friendly"
            case .shorten: return "Shorten"
            }
        }
        var instruction: String {
            switch self {
            case .polish: return "Polish this email for clarity and flow without changing its meaning or facts."
            case .formalize: return "Rewrite this email in a more formal, professional tone."
            case .friendly: return "Rewrite this email in a warmer, more casual and friendly tone."
            case .shorten: return "Shorten this email to only its essential points, keeping the same meaning."
            }
        }
    }

    /// One-tap quick edits on the current draft body (Gmail "Help me write"
    /// style refine icons) — rewrites the whole body, doesn't append.
    static func rewrite(text: String, style: RewriteStyle) async throws -> String {
        let system = "\(groundedSystemPrefix) You are an email editing assistant. Output ONLY the rewritten email body — no preamble, no explanation, no quotes around it."
        let prompt = "\(style.instruction)\n\nEmail body:\n\(text)"
        return try await OllamaService.generate(prompt: prompt, system: system, maxTokens: 500)
    }

    /// 3g — short ghost-text continuation of what's currently being typed.
    static func completeSentence(subject: String, precedingText: String) async throws -> String {
        let system = "Continue the user's email naturally. Reply with ONLY the next few words that continue their sentence, nothing else. Stop after a short phrase."
        let prompt = "Subject: \(subject)\n\nText so far: \(precedingText)"
        let result = try await OllamaService.generate(prompt: prompt, system: system, maxTokens: 20)
        return result.components(separatedBy: .newlines).first ?? result
    }
}
