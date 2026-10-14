import Foundation

/// A long dictation into Claude Code or Codex, cut into pieces that each paste short enough to
/// stay on screen (#165).
///
/// Both fold a large paste into a placeholder: Claude Code shows "[Pasted text #1 +N lines]" and
/// Codex "[Pasted Content N chars]". The text is still sent, but it can no longer be read or
/// fixed before Return, which is when it matters. Each ⌘V is a paste of its own to them, so
/// several short ones go in as typed text. Everything here is decided from the text, the app and
/// its window title alone, so it can be tested without a terminal.
enum AgentPromptPaste {

    /// What one piece may hold.
    struct Budget: Equatable {
        /// UTF-16 units, a tab counting as four (see `length(of:)`).
        let maxLength: Int
        let maxLineBreaks: Int

        /// Claude Code (read in 2.1.299) folds a paste longer than 800 characters or holding more
        /// than two line breaks, fewer in a window under twelve rows; Codex folds one longer than
        /// 1,000 characters, whatever its lines. The length keeps a margin under the smaller of
        /// the two, since neither number is a promise and either may move in a release.
        static let agentPrompt = Budget(maxLength: 600, maxLineBreaks: 2)
    }

    /// The pause after the terminal has read one piece before the next ⌘V. The terminal writes
    /// each paste to the agent in order, but the agent redraws its prompt per paste, and a paste
    /// arriving mid-redraw is the #85 kind of trouble. A quarter second is well past a redraw and
    /// still short next to reading the text.
    static let pieceGap: TimeInterval = 0.25

    // MARK: - Where

    /// Terminals the agents run in. Editors with a built-in terminal are left out: their window
    /// title names the file or the project, never the agent, so the case cannot be told apart.
    static let terminalApps: Set<String> = [
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.warp-stable",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
    ]

    static func isTerminal(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return terminalApps.contains(bundleID.lowercased())
    }

    /// Claude Code titles the window with the session's topic rather than its own name, after a
    /// mark that says whether it is waiting (✳) or working (◐ and ◑ in turn). Terminal and
    /// iTerm2 add the running command, which names Codex as well.
    static let titleMarks: [Character] = ["\u{2733}", "\u{25D0}", "\u{25D1}"]
    static let agentCommands = ["claude", "codex"]

    /// A terminal whose window title says Claude Code or Codex is running in it. The title is the
    /// only sign there is, so a shell whose title mentions either name gets pieces too, which
    /// costs it a short pause and nothing else.
    static func isAgentPrompt(bundleID: String?, windowTitle: String?) -> Bool {
        guard isTerminal(bundleID), let title = windowTitle?.trimmingCharacters(in: .whitespaces),
              !title.isEmpty else { return false }
        if let first = title.first, titleMarks.contains(first) { return true }
        let lowered = title.lowercased()
        return agentCommands.contains { lowered.contains($0) }
    }

    // MARK: - Pieces

    /// Claude Code counts the length after turning each tab into four spaces, and in UTF-16
    /// units; Codex counts characters, never more than that.
    static func length(of text: Substring) -> Int {
        text.utf16.count + text.reduce(0) { $1 == "\t" ? $0 + 3 : $0 }
    }

    /// "\r\n" is one Character, and both agents count it as one break.
    static func lineBreaks(in text: Substring) -> Int {
        text.reduce(0) { $1 == "\n" || $1 == "\r" || $1 == "\r\n" ? $0 + 1 : $0 }
    }

    static func fits(_ text: Substring, _ budget: Budget) -> Bool {
        length(of: text) <= budget.maxLength && lineBreaks(in: text) <= budget.maxLineBreaks
    }

    /// The text in pieces that each fit `budget`, or the text alone when it fits whole. Joined
    /// back they are exactly the text.
    ///
    /// Whole lines go together while they fit, so a piece ends where a line does. A line too long
    /// for a piece is cut after the spaces between two words, never inside a word or a code span,
    /// so each piece reads as it will in the prompt. A word or code span longer than a piece on
    /// its own is pasted alone and folds: the text stays whole, which matters more.
    static func pieces(of text: String, budget: Budget = .agentPrompt) -> [String] {
        guard !text.isEmpty else { return [] }
        guard !fits(Substring(text), budget) else { return [text] }

        var pieces: [String] = []
        var current = Substring()
        func add(_ unit: Substring) {
            if current.isEmpty || fits(text[current.startIndex..<unit.endIndex], budget) {
                current = text[(current.isEmpty ? unit.startIndex : current.startIndex)..<unit.endIndex]
            } else {
                pieces.append(String(current))
                current = unit
            }
        }
        for line in lines(of: text) {
            if fits(line.text, budget) {
                add(line.text)
            } else {
                line.words.forEach(add)
            }
        }
        if !current.isEmpty { pieces.append(String(current)) }
        return pieces
    }

    /// One line with its line break, and the words it can be cut into.
    struct Line {
        let text: Substring
        /// Each with the spaces after it; the first also with any before it.
        let words: [Substring]
    }

    /// The text cut at every place a piece may end: after a run of whitespace, before the next
    /// word, or between two line breaks, outside code. A run holding a line break ends a line.
    static func lines(of text: String) -> [Line] {
        let code = codeRanges(in: text)
        var lines: [Line] = []
        var words: [Substring] = []
        var wordStart = text.startIndex
        var sawWord = false
        var runHasBreak = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character.isWhitespace {
                runHasBreak = runHasBreak || character.isNewline
            } else {
                sawWord = true
                runHasBreak = false
            }
            // Between two line breaks counts too: blank lines in a row would otherwise go
            // together, and three breaks fold in Claude Code whatever the length.
            let endsWord = character.isWhitespace && sawWord && next < text.endIndex
                && (!text[next].isWhitespace || (character.isNewline && text[next].isNewline))
                && !code.contains { $0.contains(next) && $0.lowerBound != next }
            if endsWord {
                words.append(text[wordStart..<next])
                wordStart = next
                if runHasBreak {
                    lines.append(Line(text: text[words[0].startIndex..<next], words: words))
                    words = []
                }
            }
            index = next
        }
        words.append(text[wordStart..<text.endIndex])
        lines.append(Line(text: text[words[0].startIndex..<text.endIndex], words: words))
        return lines
    }

    /// Code spans and fenced blocks, as ranges a cut must not fall inside. Only a span that
    /// closes counts: a stray backtick in dictated prose must not hold the rest of the text
    /// together.
    static func codeRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "`" else {
                index = text.index(after: index)
                continue
            }
            let fence = isLineStart(index, in: text) && text[index...].hasPrefix("```")
            let close = fence ? closingFence(after: index, in: text) : closingSpan(at: index, in: text)
            guard let close else {
                index = text.index(index, offsetBy: fence ? 3 : run(at: index, in: text).count)
                continue
            }
            ranges.append(index..<close)
            index = close
        }
        return ranges
    }

    private static func isLineStart(_ index: String.Index, in text: String) -> Bool {
        index == text.startIndex || text[text.index(before: index)].isNewline
    }

    private static func run(at index: String.Index, in text: String) -> Substring {
        text[index...].prefix(while: { $0 == "`" })
    }

    /// The end of the line closing a fenced block opened at `start`.
    private static func closingFence(after start: String.Index, in text: String) -> String.Index? {
        guard let opening = text[start...].firstIndex(where: \.isNewline) else { return nil }
        var lineStart = text.index(after: opening)
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(where: \.isNewline) ?? text.endIndex
            if text[lineStart..<lineEnd].hasPrefix("```") { return lineEnd }
            guard lineEnd < text.endIndex else { return nil }
            lineStart = text.index(after: lineEnd)
        }
        return nil
    }

    /// Past the run of as many backticks that closes the span opened at `start`, on its line.
    private static func closingSpan(at start: String.Index, in text: String) -> String.Index? {
        let opening = run(at: start, in: text)
        var index = opening.endIndex
        while index < text.endIndex, !text[index].isNewline {
            guard text[index] == "`" else {
                index = text.index(after: index)
                continue
            }
            let closing = run(at: index, in: text)
            if closing.count == opening.count { return closing.endIndex }
            index = closing.endIndex
        }
        return nil
    }
}
