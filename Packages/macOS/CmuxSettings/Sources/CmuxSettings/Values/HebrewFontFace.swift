import Foundation

/// Hebrew fallback face used by the terminal (Ivrix).
///
/// Every option is the same source family put through
/// `scripts/make-hebrew-font.py`: subset to Hebrew and normalised to a uniform
/// 0.600em advance matching the Latin cell. Switching therefore changes
/// letterforms only, never the terminal grid.
public enum HebrewFontFace: String, CaseIterable, Sendable, SettingCodable {
    case noto
    case miriam
    case alef
    case heebo
    case assistant
    case plex
    case rubik
    case varela
    case frankRuhl
    case david
    case secular
    case cousine

    public static let defaultFace: HebrewFontFace = .noto

    /// Settings path and `UserDefaults` key for the selected face.
    public static let settingsPath = "terminal.hebrewFont"

    /// Bundled family name, as written into the font's name table.
    public var familyName: String {
        switch self {
        case .noto: return "Ivrix He Noto"
        case .miriam: return "Ivrix He Miriam"
        case .alef: return "Ivrix He Alef"
        case .heebo: return "Ivrix He Heebo"
        case .assistant: return "Ivrix He Assistant"
        case .plex: return "Ivrix He Plex"
        case .rubik: return "Ivrix He Rubik"
        case .varela: return "Ivrix He Varela"
        case .frankRuhl: return "Ivrix He FrankRuhl"
        case .david: return "Ivrix He David"
        case .secular: return "Ivrix He Secular"
        case .cousine: return "Ivrix He Cousine"
        }
    }

    /// Upstream face name. Proper nouns, so these are not localized.
    public var displayName: String {
        switch self {
        case .noto: return "Noto Sans Hebrew"
        case .miriam: return "Miriam Libre"
        case .alef: return "Alef"
        case .heebo: return "Heebo"
        case .assistant: return "Assistant"
        case .plex: return "IBM Plex Sans Hebrew"
        case .rubik: return "Rubik"
        case .varela: return "Varela Round"
        case .frankRuhl: return "Frank Ruhl Libre"
        case .david: return "David Libre"
        case .secular: return "Secular One"
        case .cousine: return "Cousine"
        }
    }
}
