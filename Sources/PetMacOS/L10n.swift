import Foundation

/// Localization plumbing. The app ships two ways — SPM (`swift build`, used
/// for dev) and an xcodegen-built .app bundle (release) — and each looks for
/// `Localizable.xcstrings` in a different bundle: SPM packages resources into
/// `Bundle.module`, while a regular app target's resources land in
/// `Bundle.main`. `SWIFT_PACKAGE` is defined by the Swift compiler only when
/// building as a package, so it reliably tells the two builds apart.
enum L10n {
    /// UserDefaults key for the user's language choice in Settings:
    /// "en"/"vi" force that language, absent/other means follow the system.
    static let overrideKey = "app.language.override"

    /// Read once at first use — the language applies from launch, and
    /// Settings asks for a relaunch when it changes.
    static let override: String? = {
        let value = UserDefaults.standard.string(forKey: overrideKey)
        return (value == "en" || value == "vi") ? value : nil
    }()

    private static var baseBundle: Bundle {
        #if SWIFT_PACKAGE
        .module
        #else
        .main
        #endif
    }

    /// The bundle `tr()` resolves strings against: the chosen language's
    /// `.lproj` sub-bundle when the user picked one, else the base bundle
    /// (system language).
    static let bundle: Bundle = {
        guard let code = override,
              let path = baseBundle.path(forResource: code, ofType: "lproj"),
              let localized = Bundle(path: path) else {
            return baseBundle
        }
        return localized
    }()
}

/// Looks up `key` (the English source string) in `Localizable.xcstrings`,
/// returning the localized value for the user's current language (falling
/// back to English). Route every user-facing string literal through this
/// instead of using bare string literals, since SwiftUI's `Text("...")`
/// literal initializer only ever looks in `Bundle.main` and would silently
/// miss translations under `Bundle.module` in the SPM build.
func tr(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: L10n.bundle)
}
