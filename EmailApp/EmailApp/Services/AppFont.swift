import SwiftUI
import CoreText
import os

/// Registers the bundled DM Sans variable font with CoreText so
/// `Font.custom("DM Sans", size:)` resolves — plain SwiftUI `.font()`
/// calls can't pick up a font that isn't registered with the system.
enum AppFontRegistration {
    static func registerOnce() {
        guard let url = Bundle.main.url(forResource: "DMSans-Variable", withExtension: "ttf") else {
            AppLog.sync.error("DMSans-Variable.ttf not found in bundle — falling back to system font")
            return
        }
        var error: Unmanaged<CFError>?
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
    }
}

/// DM Sans equivalents of the system text styles used throughout the app,
/// one point size larger than their default (subheadline 15->16, etc).
/// `.weight()` still chains onto these normally.
extension Font {
    static let appLargeTitle = Font.custom("DM Sans", size: 35)
    static let appTitle2 = Font.custom("DM Sans", size: 23)
    static let appHeadline = Font.custom("DM Sans", size: 18).weight(.semibold)
    static let appBody = Font.custom("DM Sans", size: 18)
    static let appSubheadline = Font.custom("DM Sans", size: 16)
    static let appCaption = Font.custom("DM Sans", size: 13)
    static let appCaption2 = Font.custom("DM Sans", size: 12)
}
