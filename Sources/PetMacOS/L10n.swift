import Foundation

/// Localization plumbing. The app ships two ways — SPM (`swift build`, used
/// for dev) and an xcodegen-built .app bundle (release) — and each looks for
/// `Localizable.xcstrings` in a different bundle: SPM packages resources into
/// `Bundle.module`, while a regular app target's resources land in
/// `Bundle.main`. `SWIFT_PACKAGE` is defined by the Swift compiler only when
/// building as a package, so it reliably tells the two builds apart.
enum L10n {
    static var bundle: Bundle {
        #if SWIFT_PACKAGE
        .module
        #else
        .main
        #endif
    }
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
