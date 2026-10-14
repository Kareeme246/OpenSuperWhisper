import Foundation

/// Fits a dictation to the text around the caret of the field it goes into (#163).
///
/// The engine writes every dictation as a sentence of its own, capital first and period last.
/// Dictated into the middle of a sentence that gives "the review is Tomorrow at noon." with a
/// capital and a period to delete by hand, and dictated right after a word it glues the two
/// together. Pure, so every case is tested without a field.
enum CaretTextMatcher {

    /// - Parameters:
    ///   - text: the dictation after post-processing. Spaces at its ends are recomputed from
    ///     the field, which replaces the unconditional one `addSpaceAfterSentence` leaves.
    ///   - properNouns: words and phrases whose capital is part of the spelling, here the
    ///     dictionary's terms. Words capitalised mid-sentence in the field or in the dictation
    ///     itself are added: the engine capitalises every first word, so case alone cannot tell
    ///     "Paris" from "Tomorrow", but the rest of the text can.
    static func fit(_ text: String, into field: TextAroundCaret, properNouns: Set<String> = []) -> String {
        let core = trimmingHorizontalSpace(text)
        guard !core.isEmpty else { return text }

        // A selection's own edge spaces stay where they were: double-clicking a word selects
        // the space after it in many apps, and the replacement should not eat it.
        let selected = field.selected
        let leading = String(selected.prefix(while: isHorizontalSpace))
        let trailing = selected.allSatisfy(isHorizontalSpace)
            ? "" : String(selected.reversed().prefix(while: isHorizontalSpace).reversed())
        let before = field.before + leading
        let after = trailing + field.after

        let nouns = properNouns
            .union(capitalisedWords(in: field.before))
            .union(capitalisedWords(in: field.after))
            .union(capitalisedWords(in: core))
        var fitted = matchingCase(core, before: before, replacing: selected, properNouns: nouns)
        if continuesSentence(after) { fitted = droppingFinalMark(fitted) }
        if needsLeadingSpace(before: before, dictation: fitted) { fitted = " " + fitted }
        if needsTrailingSpace(dictation: fitted, after: after) { fitted += " " }
        return leading + fitted + trailing
    }

    // MARK: - Case

    /// The first letter as the place calls for: the case of the first letter of a selection
    /// being replaced, else lowercase when the caret is inside a sentence.
    static func matchingCase(_ core: String, before: String, replacing selected: String,
                             properNouns: Set<String>) -> String {
        if let replaced = selected.first(where: { !isHorizontalSpace($0) }), replaced.isLetter {
            return replaced.isUppercase ? capitalisingFirst(core)
                                        : lowercasingFirst(core, properNouns: properNouns)
        }
        return endsSentence(before) ? core : lowercasingFirst(core, properNouns: properNouns)
    }

    /// Whether what comes next starts a sentence. The start of the field and a line break count:
    /// a new line or a new message is written as one. Quotes and brackets are looked through,
    /// so `He said "` is mid-sentence and `It ended." ` is not.
    static func endsSentence(_ before: String) -> Bool {
        for character in before.reversed() {
            if character.isNewline { return true }
            if isHorizontalSpace(character) || quotesAndBrackets.contains(character) { continue }
            return sentenceEnds.contains(character)
        }
        return true
    }

    /// Lowercases a word capitalised only for starting the dictation. Left alone: "I" and its
    /// contractions, words with a capital elsewhere (acronyms, "GitHub", "McDonald"), and proper
    /// nouns.
    static func lowercasingFirst(_ core: String, properNouns: Set<String>) -> String {
        let word = core.prefix(while: \.isLetter)
        guard let first = word.first, first.isUppercase,
              !word.dropFirst().contains(where: \.isUppercase),
              word != "I",
              !properNouns.contains(where: { startsWith(core, $0) }) else { return core }
        return first.lowercased() + String(core.dropFirst())
    }

    static func capitalisingFirst(_ core: String) -> String {
        guard let first = core.first, first.isLowercase else { return core }
        let upper = first.uppercased()
        // "ß" would become "SS": one letter turned into two is not a capital, it is a rewrite.
        return upper.count == 1 ? upper + String(core.dropFirst()) : core
    }

    /// Words starting with a capital where no sentence starts, which is what a proper noun
    /// looks like. The first word of the text is not counted: where it starts is unknown.
    static func capitalisedWords(in text: String) -> Set<String> {
        var words = Set<String>()
        var word = ""
        var atSentenceStart = true
        func endWord() {
            guard let first = word.first else { return }
            if !atSentenceStart, first.isUppercase { words.insert(word) }
            atSentenceStart = false
            word = ""
        }
        for character in text {
            if character.isLetter { word.append(character); continue }
            endWord()
            if character.isNewline || sentenceEnds.contains(character) {
                atSentenceStart = true
            } else if character.isNumber {
                atSentenceStart = false
            }
        }
        endWord()
        return words
    }

    // MARK: - Final mark

    /// Whether the text after the caret carries on the sentence the dictation would end: it
    /// starts with a lowercase word, or with punctuation that a period would only double.
    static func continuesSentence(_ after: String) -> Bool {
        guard let next = after.first(where: { !isHorizontalSpace($0) }), !next.isNewline else { return false }
        return next.isLowercase || continuingPunctuation.contains(next)
    }

    /// Drops one final `.`, `!` or `?`, and the space French puts before the last two. Left
    /// alone: an ellipsis or doubled marks, which were meant, and a period closing an
    /// abbreviation ("a.m.", "e.g."), which is part of the word.
    static func droppingFinalMark(_ core: String) -> String {
        guard let mark = core.last, droppableMarks.contains(mark) else { return core }
        let word = trimmingHorizontalSpace(String(core.dropLast()))
        guard let last = word.last, last.isLetter || last.isNumber else { return core }
        if mark == ".", let lastWord = word.split(whereSeparator: \.isWhitespace).last,
           lastWord.contains(".") || lastWord.count == 1 {
            return core
        }
        return word
    }

    // MARK: - Spaces

    /// A space before the dictation, unless the caret follows a space, an opening bracket or
    /// quote, or a mark a word is typed straight after, or the dictation starts with punctuation
    /// that hangs on the word before it.
    static func needsLeadingSpace(before: String, dictation: String) -> Bool {
        guard mayPutSpace(after: before, before: dictation), let next = dictation.first else { return false }
        let isStraightQuote = next == "\"" || next == "'"
        return !hangsOnPreviousWord.contains(next)
            && !(isStraightQuote && !opens(at: dictation.startIndex, in: dictation))
    }

    /// A space after the dictation only when a word, or a mark opening one, follows: at the end
    /// of the field or before punctuation it would be a stray character to delete.
    static func needsTrailingSpace(dictation: String, after: String) -> Bool {
        guard mayPutSpace(after: dictation, before: after), let next = after.first else { return false }
        return next.isLetter || next.isNumber || opens(at: after.startIndex, in: after)
    }

    /// Never next to an existing space, inside a script written without spaces, after an
    /// opening mark, or after a mark a word is typed straight after.
    private static func mayPutSpace(after left: String, before right: String) -> Bool {
        guard let last = left.last, let next = right.first else { return false }
        return !last.isWhitespace && !next.isWhitespace
            && !isSpaceless(last) && !isSpaceless(next)
            && !gluesToNext.contains(last)
            && !opens(at: left.index(before: left.endIndex), in: left)
    }

    /// Whether the mark at `index` opens something. A straight quote opens when it follows a
    /// space, a bracket or nothing and leads into a word; anywhere else it closes, and an
    /// apostrophe after a letter is part of the word ("students'").
    static func opens(at index: String.Index, in text: String) -> Bool {
        let character = text[index]
        if openingMarks.contains(character) { return true }
        guard character == "\"" || character == "'" else { return false }
        let previous = index == text.startIndex ? nil : text[text.index(before: index)]
        let following = text.index(after: index) == text.endIndex ? nil : text[text.index(after: index)]
        let afterBreak = previous.map { $0.isWhitespace || openingMarks.contains($0) } ?? true
        let intoWord = following.map { $0.isLetter || $0.isNumber } ?? true
        return afterBreak && intoWord
    }

    // MARK: - Characters

    static let sentenceEnds: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    static let droppableMarks: Set<Character> = [".", "!", "?"]
    static let continuingPunctuation: Set<Character> = [",", ";", ":", ".", "!", "?", "…"]
    static let openingMarks: Set<Character> = ["(", "[", "{", "“", "‘", "«", "‹", "„", "‚", "¿", "¡"]
    static let quotesAndBrackets: Set<Character> = openingMarks.union([
        ")", "]", "}", "”", "’", "»", "›", "\"", "'",
    ])
    static let hangsOnPreviousWord: Set<Character> = [
        ",", ".", ";", ":", "!", "?", "…", "%", ")", "]", "}", "”", "’", "»", "›",
    ]
    /// Marks a word is typed straight after: a mention, a tag, a path, a hyphenated word.
    static let gluesToNext: Set<Character> = ["@", "#", "/", "\\", "-", "_"]

    static func isHorizontalSpace(_ character: Character) -> Bool {
        character.isWhitespace && !character.isNewline
    }

    static func trimmingHorizontalSpace(_ text: String) -> String {
        let start = text.firstIndex(where: { !isHorizontalSpace($0) }) ?? text.endIndex
        let end = text.lastIndex(where: { !isHorizontalSpace($0) }).map(text.index(after:)) ?? start
        return start < end ? String(text[start..<end]) : ""
    }

    /// Chinese, Japanese and Thai put no space between words, nor around their punctuation.
    static func isSpaceless(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        return (0x0E00...0x0E7F).contains(scalar)   // Thai
            || (0x3000...0x30FF).contains(scalar)   // CJK punctuation, Hiragana, Katakana
            || (0x3400...0x4DBF).contains(scalar)   // CJK Extension A
            || (0x4E00...0x9FFF).contains(scalar)   // CJK Unified Ideographs
            || (0xFF00...0xFFEF).contains(scalar)   // Fullwidth forms
    }

    private static func startsWith(_ core: String, _ phrase: String) -> Bool {
        guard !phrase.isEmpty, core.hasPrefix(phrase) else { return false }
        return core.dropFirst(phrase.count).first.map { !$0.isLetter } ?? true
    }
}
