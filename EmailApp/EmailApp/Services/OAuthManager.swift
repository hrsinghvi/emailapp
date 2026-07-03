import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

/// Real Google OAuth via ASWebAuthenticationSession + PKCE (no client secret).
/// MainActor: the auth session must be presented from the main thread.
@MainActor
final class OAuthManager: NSObject {
    static let shared = OAuthManager()

    /// ASWebAuthenticationSession doesn't retain itself — without a strong
    /// reference here, ARC can deallocate it mid-flow before the completion
    /// handler fires, silently dropping the callback.
    private var authSession: ASWebAuthenticationSession?

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

    /// Per-provider OAuth endpoints/params. Both are native/public clients
    /// (PKCE, no client secret) — only the URLs and IDs differ.
    private struct ProviderConfig {
        let authorizeURL: String
        let tokenURL: String
        let clientID: String
        let redirectURI: String
        let redirectScheme: String
        let scopes: [String]
        let extraAuthParams: [String: String]
    }

    private func providerConfig(for provider: Provider) -> ProviderConfig {
        switch provider {
        case .gmail:
            return ProviderConfig(
                authorizeURL: "https://accounts.google.com/o/oauth2/v2/auth",
                tokenURL: "https://oauth2.googleapis.com/token",
                clientID: Config.googleClientID,
                redirectURI: Config.googleRedirectURI,
                redirectScheme: Config.googleRedirectScheme,
                scopes: Config.googleScopes,
                extraAuthParams: ["access_type": "offline", "prompt": "consent"]
            )
        case .outlook:
            return ProviderConfig(
                authorizeURL: Config.azureAuthorizeURL,
                tokenURL: Config.azureTokenURL,
                clientID: Config.azureClientID,
                redirectURI: Config.azureRedirectURI,
                redirectScheme: Config.azureRedirectScheme,
                scopes: Config.azureScopes,
                extraAuthParams: ["prompt": "select_account"]
            )
        }
    }

    /// Separate Keychain accounts per provider so Gmail and Outlook tokens
    /// for the same-looking address never collide or overwrite each other.
    private func keychainAccount(provider: Provider, email: String) -> String {
        "\(provider.rawValue):\(email)"
    }

    // MARK: - Public API

    /// Runs the interactive consent flow, stores tokens in the Keychain,
    /// and returns an Account built from the authenticated Gmail address.
    func signInWithGoogle() async throws -> Account {
        try await signIn(provider: .gmail) { try await GmailAPI.getProfile(accessToken: $0) }
    }

    /// Runs the interactive consent flow, stores tokens in the Keychain,
    /// and returns an Account built from the authenticated Outlook address.
    func signInWithMicrosoft() async throws -> Account {
        try await signIn(provider: .outlook) { try await GraphAPI.getProfile(accessToken: $0) }
    }

    private func signIn(
        provider: Provider, fetchEmail: (String) async throws -> String
    ) async throws -> Account {
        let config = providerConfig(for: provider)
        let verifier = Self.makeCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let code = try await authorize(config: config, challenge: challenge)
        let tokens = try await exchangeCode(code, verifier: verifier, config: config)
        let email = try await fetchEmail(tokens.accessToken)
        try KeychainService.save(tokens, account: keychainAccount(provider: provider, email: email))
        return Account(id: UUID(), provider: provider, email: email, displayName: email)
    }

    /// Returns a non-expired access token, refreshing (and re-saving) if needed.
    func validAccessToken(for account: Account) async throws -> String {
        let key = keychainAccount(provider: account.provider, email: account.email)
        guard var tokens = try KeychainService.load(account: key) else {
            throw OAuthError.notAuthenticated
        }
        if tokens.isExpired {
            tokens = try await refresh(tokens, provider: account.provider, keychainKey: key)
        }
        return tokens.accessToken
    }

    // MARK: - Authorization (ASWebAuthenticationSession)

    private func authorize(config: ProviderConfig, challenge: String) async throws -> String {
        var comps = URLComponents(string: config.authorizeURL)!
        comps.queryItems = [
            .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: config.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ] + config.extraAuthParams.map { .init(name: $0.key, value: $0.value) }
        guard let url = comps.url else { throw OAuthError.invalidAuthURL }

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: config.redirectScheme
            ) { [weak self] callbackURL, error in
                self?.authSession = nil
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
            authSession = session
            if !session.start() {
                authSession = nil
                continuation.resume(throwing: OAuthError.sessionFailed("Could not start the auth session."))
            }
        }
    }

    // MARK: - Token exchange / refresh

    private func exchangeCode(
        _ code: String, verifier: String, config: ProviderConfig
    ) async throws -> OAuthTokens {
        let resp = try await postToken(config.tokenURL, [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": config.clientID,
            "redirect_uri": config.redirectURI,
            "code_verifier": verifier,
        ])
        guard let refresh = resp.refresh_token else { throw OAuthError.noRefreshToken }
        return OAuthTokens(
            accessToken: resp.access_token,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(TimeInterval(resp.expires_in))
        )
    }

    private func refresh(
        _ tokens: OAuthTokens, provider: Provider, keychainKey: String
    ) async throws -> OAuthTokens {
        let config = providerConfig(for: provider)
        let resp = try await postToken(config.tokenURL, [
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
            "client_id": config.clientID,
        ])
        // A refresh response usually omits refresh_token; keep the existing one.
        let updated = OAuthTokens(
            accessToken: resp.access_token,
            refreshToken: resp.refresh_token ?? tokens.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(resp.expires_in))
        )
        try KeychainService.save(updated, account: keychainKey)
        return updated
    }

    private func postToken(_ tokenURL: String, _ params: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: tokenURL)!)
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
