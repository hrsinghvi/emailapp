import Foundation

/// Talks to the Phase 5 Vercel backend, which owns webhook subscriptions
/// (Gmail Pub/Sub watch, Graph change notifications) independently of this
/// app being open.
enum BackendAPI {
    enum BackendError: LocalizedError {
        case requestFailed(Int, String)

        var errorDescription: String? {
            switch self {
            case .requestFailed(let code, let body): return "Backend request failed (\(code)): \(body)"
            }
        }
    }

    /// Registers an account's refresh token with the backend and kicks off
    /// its push subscription. Called right after interactive sign-in.
    static func registerAccount(
        provider: Provider, email: String, refreshToken: String
    ) async throws {
        var req = URLRequest(url: URL(string: "\(Config.backendBaseURL)/api/accounts/register")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode([
            "provider": provider.rawValue,
            "email": email,
            "refreshToken": refreshToken,
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw BackendError.requestFailed(code, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
