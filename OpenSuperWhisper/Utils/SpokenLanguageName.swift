import SwiftUI
import OpenSuperWhisperCore

/// Spoken-language names in the language the interface is shown in. `LanguageUtil`'s names are
/// English, so the French app offered "French" in the middle of French copy.
enum SpokenLanguageName {
    /// The name in `locale`, falling back to `LanguageUtil`'s for a code the system cannot name.
    /// "auto" is not a language: it goes through the string catalog instead.
    static func text(for code: String, locale: Locale) -> Text {
        if code == "auto" { return Text("Auto-detect") }
        return Text(verbatim: name(for: code, locale: locale))
    }

    /// Alphabetical in `locale`, "auto" kept first: sorted by English names, the list read out
    /// of order once translated.
    static func sorted(_ codes: [String], locale: Locale) -> [String] {
        codes.sorted { lhs, rhs in
            if lhs == "auto" || rhs == "auto" { return lhs == "auto" && rhs != "auto" }
            return name(for: lhs, locale: locale)
                .compare(name(for: rhs, locale: locale), locale: locale) == .orderedAscending
        }
    }

    /// French writes language names in lowercase ("français"); a menu entry starts with a
    /// capital, so only the first letter is raised.
    private static func name(for code: String, locale: Locale) -> String {
        guard let name = locale.localizedString(forLanguageCode: code), !name.isEmpty else {
            return LanguageUtil.languageNames[code] ?? code
        }
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }
}
