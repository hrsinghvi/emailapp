import Foundation

/// Serializes provider API calls and retries 429s with backoff. Firing
/// several archive/delete/restore calls at once (e.g. drag-dropping 3 emails
/// to Trash, each kicking off its own concurrent Task) can trip Gmail/Graph's
/// per-mailbox concurrency limit — this queues them instead of letting every
/// caller race the same throttle independently.
actor RequestThrottle {
    static let gmail = RequestThrottle(maxConcurrent: 4)
    static let graph = RequestThrottle(maxConcurrent: 3)

    private let maxConcurrent: Int
    private var active = 0

    init(maxConcurrent: Int) { self.maxConcurrent = maxConcurrent }

    func run<T>(isThrottled: (Error) -> Bool, _ body: @Sendable () async throws -> T) async throws -> T {
        while active >= maxConcurrent {
            try await Task.sleep(for: .milliseconds(50))
        }
        active += 1
        defer { active -= 1 }

        var attempt = 0
        while true {
            do {
                return try await body()
            } catch {
                guard isThrottled(error), attempt < 3 else { throw error }
                attempt += 1
                try await Task.sleep(for: .milliseconds(400 * attempt))
            }
        }
    }
}
