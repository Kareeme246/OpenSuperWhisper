import Foundation
import KeyboardShortcuts

/// One key of a shortcut: what its cap shows, and the name written under it so the cap needs
/// no guessing ("⌥" is Option, "<" is the less-than key).
struct NamedKey: Equatable {
    /// A glyph, a letter, "F5", "Esc", or a mouse button's number.
    let cap: String
    /// SF Symbol drawn before `cap`, for a mouse button.
    var symbol: String? = nil
    let name: String
}

extension RecordingTrigger {
    /// One named key per cap, in the order the caps are drawn.
    @MainActor func namedKeys(locale: Locale) -> [NamedKey] {
        switch self {
        case .none:
            return []
        case .keyCombo(let shortcut):
            let modifiers = Self.modifierBadges.filter { shortcut.modifiers.contains($0.flag) }
                .map { KeyNames.modifier(symbol: $0.symbol, locale: locale) }
            guard let key = caps.last, caps.count > modifiers.count else { return modifiers }
            if shortcut.key == .space {
                return modifiers + [NamedKey(cap: key, name: KeyNames.localized("Space bar", locale))]
            }
            return modifiers + [KeyNames.key(cap: key, locale: locale)]
        case .modifier(let key):
            return [KeyNames.modifier(key, locale: locale)]
        case .mouse(let button):
            return [KeyNames.mouseButton(button, locale: locale)]
        case .chord(let chord):
            return chord.symbols.map { KeyNames.modifier(symbol: $0, locale: locale) }
        }
    }
}

/// The names under the caps. Sided modifiers and mouse buttons reuse the names Settings
/// already translates ("Right ⌥ Option", "Button 4 (Back)"); the rest is named here.
enum KeyNames {
    static func localized(_ resource: LocalizedStringResource, _ locale: Locale) -> String {
        var resource = resource
        resource.locale = locale
        return String(localized: resource)
    }

    /// "Right ⌥ Option" read as "Right Option": Settings' name for the key, glyph removed.
    static func modifier(_ key: ModifierKey, locale: Locale) -> NamedKey {
        if key == .fn { return NamedKey(cap: key.shortSymbol, name: localized("Function", locale)) }
        let full = localized(LocalizedStringResource(String.LocalizationValue(key.displayName)), locale)
        return NamedKey(cap: key.shortSymbol, name: withoutGlyph(key.shortSymbol, in: full))
    }

    /// A modifier with no side, as a combination or a chord holds it.
    static func modifier(symbol: String, locale: Locale) -> NamedKey {
        let name: LocalizedStringResource
        switch symbol {
        case "⌃": name = "Control"
        case "⌥": name = "Option"
        case "⇧": name = "Shift"
        case "⌘": name = "Command"
        default: return NamedKey(cap: symbol, name: symbol)
        }
        return NamedKey(cap: symbol, name: localized(name, locale))
    }

    /// The button's number on the cap, beside a mouse; the full name under it.
    static func mouseButton(_ button: MouseButton, locale: Locale) -> NamedKey {
        let number = String(button.shortSymbol.filter(\.isNumber))
        let name = localized(LocalizedStringResource(String.LocalizationValue(button.displayName)), locale)
        return NamedKey(cap: number, symbol: "computermouse", name: name)
    }

    /// The non-modifier key of a combination, from the cap KeyboardShortcuts or the keyboard
    /// layout draws for it.
    static func key(cap: String, locale: Locale) -> NamedKey {
        if cap == "⎋" { return NamedKey(cap: "Esc", name: localized("Escape", locale)) }
        if cap.hasSuffix("\u{20E3}") {
            let digit = String(cap.dropLast())
            return NamedKey(cap: digit, name: localized("Keypad \(digit)", locale))
        }
        if let name = specialName(cap) { return NamedKey(cap: cap, name: localized(name, locale)) }
        if cap.count > 1, cap.first == "F", Int(cap.dropFirst()) != nil {
            return NamedKey(cap: cap, name: localized("Function key", locale))
        }
        if let name = symbolName(cap) { return NamedKey(cap: cap, name: localized(name, locale)) }
        return NamedKey(cap: cap, name: localized("\(cap) key", locale))
    }

    /// Keys macOS draws as a glyph.
    private static func specialName(_ cap: String) -> LocalizedStringResource? {
        switch cap {
        case "↩": return "Return"
        case "⌫": return "Delete"
        case "⌦": return "Forward Delete"
        case "⇥": return "Tab"
        case "↖": return "Home key"
        case "↘": return "End"
        case "⇞": return "Page Up"
        case "⇟": return "Page Down"
        case "←": return "Left Arrow"
        case "→": return "Right Arrow"
        case "↑": return "Up Arrow"
        case "↓": return "Down Arrow"
        default: return nil
        }
    }

    /// Punctuation a layout can put on a key, named the way the character viewer does.
    private static func symbolName(_ cap: String) -> LocalizedStringResource? {
        switch cap {
        case "<": return "Less-than"
        case ">": return "Greater-than"
        case "`": return "Grave accent"
        case "§": return "Section sign"
        case "@": return "At sign"
        case "-": return "Minus"
        case "=": return "Equals"
        case ",": return "Comma"
        case ".": return "Period"
        case "/": return "Slash"
        case "\\": return "Backslash"
        case ";": return "Semicolon"
        case "'": return "Apostrophe"
        case "[": return "Left bracket"
        case "]": return "Right bracket"
        case "^": return "Circumflex"
        case "²": return "Superscript two"
        default: return nil
        }
    }

    /// "⌥ Option droite" → "Option droite", whitespace tidied wherever the glyph sat.
    static func withoutGlyph(_ glyph: String, in name: String) -> String {
        name.replacingOccurrences(of: glyph, with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
