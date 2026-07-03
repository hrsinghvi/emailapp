import Foundation

// Public by nature: client IDs ship inside the redirect URL scheme.
// Both are NATIVE OAuth clients (Authorization Code + PKCE, NO client secret).
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

    static let azureClientID = "c2a8a2a4-df34-44d5-b7ec-43b8fb854502"

    /// Custom scheme registered as a "Mobile and desktop applications" platform
    /// redirect URI in the Azure app registration — must match exactly.
    static let azureRedirectScheme = "com.hritviksinghvi.emailapp.outlook"

    static var azureRedirectURI: String { "\(azureRedirectScheme)://oauth2redirect" }

    /// "common" tenant: accepts both personal Microsoft accounts and UIUC's
    /// Azure AD org accounts with the same client.
    static let azureAuthorizeURL = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
    static let azureTokenURL = "https://login.microsoftonline.com/common/oauth2/v2.0/token"

    static let azureScopes = [
        "https://graph.microsoft.com/User.Read",
        "https://graph.microsoft.com/Mail.Read",
        "https://graph.microsoft.com/Mail.Send",
        "offline_access",
        "openid",
        "profile",
    ]
}
