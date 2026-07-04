import os

/// Thin os.Logger wrapper so errors persist to the unified log (visible in
/// Console.app or `log show --predicate 'subsystem == "com.emailapp"'`)
/// instead of vanishing with a closed Xcode console or a dismissed alert.
/// Actual crash reports (uncaught signals/exceptions) need no code at all —
/// macOS already writes those to ~/Library/Logs/DiagnosticReports for every
/// app.
enum AppLog {
    static let sync = Logger(subsystem: "com.emailapp", category: "sync")
    static let send = Logger(subsystem: "com.emailapp", category: "send")
    static let offline = Logger(subsystem: "com.emailapp", category: "offline")
    static let auth = Logger(subsystem: "com.emailapp", category: "auth")
}
