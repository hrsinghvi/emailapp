import SwiftUI
import CoreText
import os

/// Registers the bundled Inter variable font with CoreText so
/// `Font.custom("Inter", size:)` resolves — plain SwiftUI `.font()`
/// calls can't pick up a font that isn't registered with the system.
enum AppFontRegistration {
    static func registerOnce() {
        guard let url = Bundle.main.url(forResource: "Inter-Variable", withExtension: "ttf") else {
            AppLog.sync.error("Inter-Variable.ttf not found in bundle — falling back to system font")
            return
        }
        var error: Unmanaged<CFError>?
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
    }
}

/// Inter equivalents of the system text styles used throughout the app,
/// matching their default system point sizes (subheadline 15, etc).
/// `.weight()` still chains onto these normally.
extension Font {
    static let appLargeTitle = Font.custom("Inter", size: 32)
    static let appTitle2 = Font.custom("Inter", size: 20)
    static let appHeadline = Font.custom("Inter", size: 15).weight(.semibold)
    static let appBody = Font.custom("Inter", size: 15)
    static let appSubheadline = Font.custom("Inter", size: 13)
    static let appCaption = Font.custom("Inter", size: 10)
    static let appCaption2 = Font.custom("Inter", size: 9)
}
