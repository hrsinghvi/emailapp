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

    private static func threadContext(_ messages: [Message], limit: Int = 12) -> String {
        messages.suffix(limit).map { message in
            "From: \(message.senderName) <\(message.senderEmail)>\nDate: \(message.receivedAt)\nSubject: \(message.subject)\n\(message.body)"
        }.joined(separator: "\n\n---\n\n")
    }

    /// 3b/3e — answers a free-form question about the open thread.
    static func askAboutEmail(question: String, thread: [Message], onToken: @escaping @MainActor (String) -> Void) async throws {
        let system = "You are an email assistant. Answer briefly and only using the provided email content."
        let prompt = "Email thread:\n\(threadContext(thread))\n\nQuestion: \(question)"
        try await OllamaService.generateStreaming(prompt: prompt, system: system, maxTokens: 400, onToken: onToken)
    }

    /// 3c — one-shot summary of a 3+ message thread.
    static func summarizeThread(_ messages: [Message]) async throws -> String {
        let system = "You are an email assistant. Summarize the thread in 3-5 short bullet points, noting any open questions or action items."
        let prompt = "Email thread:\n\(threadContext(messages))"
        return try await OllamaService.generate(prompt: prompt, system: system, maxTokens: 350)
    }

    /// 3d — drafts a reply/new email body from a natural-language prompt,
    /// optionally with quoted thread context and a few past sent messages
    /// to the same recipient for tone matching.
    static func draftEmail(instructions: String, quotedThread: [Message], pastSentToRecipient: [Message]) async throws -> String {
        let system = "You are an email assistant. Write only the email body, no subject line, no greeting placeholders unless natural. Match the tone of past sent messages if provided."
        var prompt = "Instructions: \(instructions)"
        if !quotedThread.isEmpty {
            prompt += "\n\nThread being replied to:\n\(threadContext(quotedThread, limit: 4))"
        }
        if !pastSentToRecipient.isEmpty {
            prompt += "\n\nPast messages I've sent this recipient (for tone):\n\(threadContext(pastSentToRecipient, limit: 3))"
        }
        return try await OllamaService.generate(prompt: prompt, system: system, maxTokens: 400)
    }

    /// 3g — short ghost-text continuation of what's currently being typed.
    static func completeSentence(subject: String, precedingText: String) async throws -> String {
        let system = "Continue the user's email naturally. Reply with ONLY the next few words that continue their sentence, nothing else. Stop after a short phrase."
        let prompt = "Subject: \(subject)\n\nText so far: \(precedingText)"
        let result = try await OllamaService.generate(prompt: prompt, system: system, maxTokens: 20)
        return result.components(separatedBy: .newlines).first ?? result
    }
}
