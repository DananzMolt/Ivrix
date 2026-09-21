import Foundation

/// Ivrix: Hebrew keyboard layouts put HEBREW PUNCTUATION GERESH (U+05F3) and
/// GERSHAYIM (U+05F4) on the apostrophe and quote keys, so a shell command typed
/// with a Hebrew layout active arrives as `echo ״hi״` instead of `echo "hi"` and
/// the shell never sees a quote at all.
///
/// When enabled (the default) those two scalars are rewritten to ASCII `'` and
/// `"` on the way into the terminal. Turn it off from Settings → Terminal to type
/// Hebrew acronyms such as צה״ל, which need the real gershayim.
enum HebrewAsciiQuotes {
    /// Settings path and `UserDefaults` key. Mirrors
    /// `SettingCatalog.terminal.hebrewAsciiQuotes`.
    static let settingsKey = "terminal.hebrewAsciiQuotes"
    static let defaultEnabled = true

    private static let geresh: Unicode.Scalar = "\u{05F3}"
    private static let gershayim: Unicode.Scalar = "\u{05F4}"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: settingsKey) != nil else { return defaultEnabled }
        return defaults.bool(forKey: settingsKey)
    }

    /// Rewrites geresh/gershayim to ASCII `'`/`"`.
    ///
    /// This runs on the keystroke path, so it early-returns on the scan before
    /// touching `UserDefaults`: ordinary typing pays one pass over a one-scalar
    /// string and nothing else.
    static func normalized(_ text: String, defaults: UserDefaults = .standard) -> String {
        guard text.unicodeScalars.contains(where: { $0 == geresh || $0 == gershayim }) else {
            return text
        }
        guard isEnabled(defaults: defaults) else { return text }

        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case geresh: scalars.append("'")
            case gershayim: scalars.append("\"")
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}
