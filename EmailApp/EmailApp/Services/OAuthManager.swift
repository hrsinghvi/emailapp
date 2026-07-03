import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

/// Real Google OAuth via ASWebAuthenticationSession + PKCE (no client secret).
/// MainActor: the auth session must be presented from the main thread.
@MainActor
final class OAuthManager: NSObject {
    static let shared = OAuthManager()

    enum OAuthError: LocalizedError {
        case invalidAuthURL
        case sessionFailed(String)
        case noAuthCode
        case tokenRequestFailed(String)
        case noRefreshToken
        case notAuthenticated

        var errorDescription: String? {
            switch self {
            case .invalidAuthURL: return "Could not build the Google authorization URL."
            case .sessionFailed(let m): return "Sign-in was cancelled or failed: \(m)"
            case .noAuthCode: return "Google did not return an authorization code."
            case .tokenRequestFailed(let m): return "Token request failed: \(m)"
            case .noRefreshToken: return "Google did not return a refresh token."
            case .notAuthenticated: return "This account is not signed in."
            }
        }
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
    }

    // MARK: - Public API

    /// Runs the interactive consent flow, stores tokens in the Keychain,
    /// and returns an Account built from the authenticated Gmail address.
    func signInWithGoogle() async throws -> Account {
        let verifier = Self.makeCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let code = try await authorize(challenge: challenge)
        let tokens = try await exchangeCode(code, verifier: verifier)
        let email = try await GmailAPI.getProfile(accessToken: tokens.accessToken)
        try KeychainService.save(tokens, account: email)
        return Account(id: UUID(), provider: .gmail, email: email, displayName: email)
    }

    /// Returns a non-expired access token, refreshing (and re-saving) if needed.
    func validAccessToken(for account: Account) async throws -> String {
        guard var tokens = try KeychainService.load(account: account.email) else {
            throw OAuthError.notAuthenticated
        }
        if tokens.isExpired {
            tokens = try await refresh(tokens, account: account.email)
        }
        return tokens.accessToken
    }

    // MARK: - Authorization (ASWebAuthenticationSession)

    private func authorize(challenge: String) async throws -> String {
        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: Config.googleClientID),
            .init(name: "redirect_uri", value: Config.googleRedirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Config.googleScopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        guard let url = comps.url else { throw OAuthError.invalidAuthURL }

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: Config.googleRedirectScheme
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: OAuthError.sessionFailed(error.localizedDescription))
                    return
                }
                guard let callbackURL,
                      let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems,
                      let code = items.first(where: { $0.name == "code" })?.value
                else {
                    continuation.resume(throwing: OAuthError.noAuthCode)
                    return
                }
                continuation.resume(returning: code)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                continuation.resume(throwing: OAuthError.sessionFailed("Could not start the auth session."))
            }
        }
    }

    // MARK: - Token exchange / refresh

    private func exchangeCode(_ code: String, verifier: String) async throws -> OAuthTokens {
        let resp = try await postToken([
            "grant_type": "authorization_code",
            "code": code,
            "client_id": Config.googleClientID,
            "redirect_uri": Config.googleRedirectURI,
            "code_verifier": verifier,
        ])
        guard let refresh = resp.refresh_token else { throw OAuthError.noRefreshToken }
        return OAuthTokens(
            accessToken: resp.access_token,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(TimeInterval(resp.expires_in))
        )
    }

    private func refresh(_ tokens: OAuthTokens, account: String) async throws -> OAuthTokens {
        let resp = try await postToken([
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
            "client_id": Config.googleClientID,
        ])
        // A refresh response usually omits refresh_token; keep the existing one.
        let updated = OAuthTokens(
            accessToken: resp.access_token,
            refreshToken: resp.refresh_token ?? tokens.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(resp.expires_in))
        )
        try KeychainService.save(updated, account: account)
        return updated
    }

    private func postToken(_ params: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncode(params)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OAuthError.tokenRequestFailed(String(data: data, encoding: .utf8) ?? "unknown")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // MARK: - PKCE helpers

    private static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32) // 32 bytes -> 43-char base64url
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }

    private static func formEncode(_ params: [String: String]) -> Data {
        // Manual encoding: percentEncodedQuery leaves "+" intact, which a form
        // body would read as a space. Encode everything but unreserved chars.
        let unreserved = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return params.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&").data(using: .utf8) ?? Data()
    }
}

extension OAuthManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first
            ?? ASPresentationAnchor()
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
