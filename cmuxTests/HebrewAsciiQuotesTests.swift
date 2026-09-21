import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Ivrix: the Hebrew layout puts geresh/gershayim on the quote keys, so a shell
/// command typed in Hebrew never reaches the shell with a real quote.
@Suite
struct HebrewAsciiQuotesTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "cmux-hebrew-ascii-quotes-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suiteName)), suiteName)
    }

    @Test
    func gershayimBecomesAsciiDoubleQuoteByDefault() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(HebrewAsciiQuotes.normalized("\u{05F4}", defaults: defaults) == "\"")
    }

    @Test
    func gereshBecomesAsciiApostropheByDefault() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(HebrewAsciiQuotes.normalized("\u{05F3}", defaults: defaults) == "'")
    }

    @Test
    func rewritesEveryOccurrenceAndKeepsSurroundingText() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let typed = "echo \u{05F4}\u{05E9}\u{05DC}\u{05D5}\u{05DD}\u{05F4}"
        let expected = "echo \"\u{05E9}\u{05DC}\u{05D5}\u{05DD}\""

        #expect(HebrewAsciiQuotes.normalized(typed, defaults: defaults) == expected)
    }

    @Test(arguments: ["ls -la", "\u{05E9}\u{05DC}\u{05D5}\u{05DD}", "\"already ascii\"", ""])
    func leavesTextWithoutHebrewQuotePunctuationUntouched(_ text: String) throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(HebrewAsciiQuotes.normalized(text, defaults: defaults) == text)
    }

    /// Turning the setting off is what makes Hebrew acronyms (צה״ל) typeable.
    @Test
    func disabledSettingSendsHebrewPunctuationAsTyped() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: HebrewAsciiQuotes.settingsKey)

        let acronym = "\u{05E6}\u{05D4}\u{05F4}\u{05DC}"
        #expect(HebrewAsciiQuotes.normalized(acronym, defaults: defaults) == acronym)
    }

    @Test
    func explicitlyEnabledSettingRewrites() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: HebrewAsciiQuotes.settingsKey)

        #expect(HebrewAsciiQuotes.normalized("\u{05F4}", defaults: defaults) == "\"")
    }
}

/// The titlebar control, the toolbar segmented control, the View menu item, and
/// the `toggleTextDirection` shortcut all flip direction through one path.
@Suite
struct TerminalTextDirectionToggleTests {
    @Test
    func toggleFlipsLtrToRtlAndBack() throws {
        let suiteName = "cmux-text-direction-toggle-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let center = NotificationCenter()

        #expect(TerminalTextDirectionSettings.direction(defaults: defaults) == .ltr)

        #expect(
            TerminalTextDirectionSettings.toggleDirection(defaults: defaults, notificationCenter: center) == .rtl
        )
        #expect(TerminalTextDirectionSettings.direction(defaults: defaults) == .rtl)
        #expect(TerminalTextDirectionSettings.ghosttyConfigContents(defaults: defaults) == "bidi-direction = rtl")

        #expect(
            TerminalTextDirectionSettings.toggleDirection(defaults: defaults, notificationCenter: center) == .ltr
        )
        #expect(TerminalTextDirectionSettings.direction(defaults: defaults) == .ltr)
    }

    @Test
    func toggleNotifiesSoLiveSurfacesReload() throws {
        let suiteName = "cmux-text-direction-notify-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let center = NotificationCenter()
        nonisolated(unsafe) var notifications = 0
        let token = center.addObserver(
            forName: TerminalTextDirectionSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in notifications += 1 }
        defer { center.removeObserver(token) }

        TerminalTextDirectionSettings.toggleDirection(defaults: defaults, notificationCenter: center)

        #expect(notifications == 1)
    }
}
