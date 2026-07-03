import Foundation

// Public by nature: the client ID ships inside the redirect URL scheme.
// This is a NATIVE OAuth client (Authorization Code + PKCE, NO client secret).
enum Config {
    static let googleClientID =
        "1049176105925-tasmcnkpj3m8sr6r81rff57knq3euut1.apps.googleusercontent.com"

    /// Reversed client-id custom scheme (Google's installed-app convention).
    /// Also what ASWebAuthenticationSession uses as callbackURLScheme.
    static let googleRedirectScheme =
        "com.googleusercontent.apps.1049176105925-tasmcnkpj3m8sr6r81rff57knq3euut1"

    static var googleRedirectURI: String { "\(googleRedirectScheme):/oauth2redirect" }

    static let googleScopes = [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/gmail.labels",
    ]
}
