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
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/calendar.readonly",
        "https://www.googleapis.com/auth/calendar.events",
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
        "https://graph.microsoft.com/Mail.ReadWrite",
        "https://graph.microsoft.com/Mail.Send",
        "https://graph.microsoft.com/Calendars.Read",
        "https://graph.microsoft.com/Calendars.ReadWrite",
        "offline_access",
        "openid",
        "profile",
    ]

    /// Phase 5 backend: manages webhook subscriptions + renewal, upserts
    /// live mail into Supabase for realtime delivery to the app.
    static let backendBaseURL = "https://backend-three-neon-86.vercel.app"

    static let supabaseURL = "https://nmytrkgqefpqpjmmvzfw.supabase.co"

    /// Anon/publishable key — safe client-side by design. RLS locks the
    /// `accounts` table (refresh tokens) to the backend's service role only;
    /// this key can only read `messages`.
    static let supabaseAnonKey =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5teXRya2dxZWZwcXBqbW12emZ3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODMwMTg4NjQsImV4cCI6MjA5ODU5NDg2NH0.r6rXAKD23LDY63K9oWeGqukacrtLeerh5n5TH-DpRjs"
}
