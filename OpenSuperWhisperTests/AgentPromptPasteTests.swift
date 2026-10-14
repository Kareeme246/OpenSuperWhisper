import AppKit
import XCTest

@testable import OpenSuperWhisper

/// Covers pasting a long dictation into Claude Code or Codex in pieces (#165): which windows get
/// it, where the text is cut, and the pieces going out one after another on a borrowed clipboard
/// that comes back once. The paste runs on a private pasteboard and posts no keystroke; reading
/// that pasteboard stands in for the terminal taking the ⌘V. The warning stays off so no notice
/// window is opened.
@MainActor
final class AgentPromptPasteTests: XCTestCase {

    private typealias Paste = AgentPromptPaste

    // MARK: - Where

    func testATerminalRunningAnAgentIsAnAgentPrompt() {
        XCTAssertTrue(Paste.isAgentPrompt(bundleID: "com.mitchellh.ghostty", windowTitle: "\u{2733} Fix the paste"),
                      "Claude Code waiting, titled with its topic")
        XCTAssertTrue(Paste.isAgentPrompt(bundleID: "com.googlecode.iterm2", windowTitle: "\u{25D0} Fix the paste"),
                      "Claude Code working")
        XCTAssertTrue(Paste.isAgentPrompt(bundleID: "com.apple.Terminal", windowTitle: "OSW — codex — 120×40"))
        XCTAssertTrue(Paste.isAgentPrompt(bundleID: "com.apple.Terminal", windowTitle: "Claude Code"))
    }

    func testAShellOrAnotherAppIsNot() {
        XCTAssertFalse(Paste.isAgentPrompt(bundleID: "com.apple.Terminal", windowTitle: "maxim — -zsh — 80×24"))
        XCTAssertFalse(Paste.isAgentPrompt(bundleID: "com.apple.Terminal", windowTitle: nil))
        XCTAssertFalse(Paste.isAgentPrompt(bundleID: "com.apple.Notes", windowTitle: "\u{2733} claude"),
                       "only terminals: the agents' title marks mean nothing elsewhere")
        XCTAssertFalse(Paste.isAgentPrompt(bundleID: "com.microsoft.VSCode", windowTitle: "claude.md"))
        XCTAssertFalse(Paste.isAgentPrompt(bundleID: nil, windowTitle: "claude"))
    }

    func testATabSwitchShowsInTheTitleButClaudesWorkingMarkDoesNot() {
        XCTAssertTrue(Paste.isSameTab("\u{25D0} Fix the paste", as: "\u{25D1} Fix the paste"))
        XCTAssertTrue(Paste.isSameTab("\u{25D0} Fix the paste", as: "\u{2733} Fix the paste"),
                      "the agent finishing its turn is still the same tab")
        XCTAssertTrue(Paste.isSameTab(nil, as: nil))
        XCTAssertFalse(Paste.isSameTab("\u{2733} Fix the paste", as: "maxim — -zsh — 80×24"))
        XCTAssertFalse(Paste.isSameTab("\u{2733} Fix the paste", as: nil))
    }

    // MARK: - Pieces

    private let small = AgentPromptPaste.Budget(maxLength: 20, maxLineBreaks: 2)

    private func assertPieces(_ text: String, budget: AgentPromptPaste.Budget,
                              file: StaticString = #filePath, line: UInt = #line) -> [String] {
        let pieces = Paste.pieces(of: text, budget: budget)
        XCTAssertEqual(pieces.joined(), text, "the pieces must put the text back exactly", file: file, line: line)
        return pieces
    }

    func testATextThatFitsGoesWhole() {
        XCTAssertEqual(Paste.pieces(of: "Rename the method."), ["Rename the method."])
        XCTAssertEqual(Paste.pieces(of: ""), [])
        let fits = String(repeating: "word ", count: 120)
        XCTAssertEqual(Paste.pieces(of: fits), [fits], "600 characters is within the budget")
    }

    func testLinesStayTogetherAndPiecesEndWithALine() {
        let text = "one\ntwo\nthree\nfour\nfive"
        let pieces = assertPieces(text, budget: small)

        XCTAssertEqual(pieces, ["one\ntwo\n", "three\nfour\nfive"])
    }

    func testNoPieceHoldsMoreLineBreaksThanTheAgentsLet() {
        let text = (1...9).map { "- item \($0)" }.joined(separator: "\n")
        let pieces = assertPieces(text, budget: .agentPrompt)

        XCTAssertEqual(pieces.count, 4)
        for piece in pieces {
            XCTAssertLessThanOrEqual(Paste.lineBreaks(in: Substring(piece)), 2, piece)
        }
    }

    func testBlankLinesInARowAreSharedOut() {
        let pieces = assertPieces("x\n\n\n\n\n\ny", budget: small)

        XCTAssertEqual(pieces, ["x\n\n", "\n\n", "\n\ny"])
    }

    /// Blank lines holding a space or a tab, as dictation post-processing can leave them.
    func testBlankLinesWithSpacesInThemAreSharedOutToo() {
        let pieces = assertPieces("a\n \n \n \nb", budget: small)

        XCTAssertEqual(pieces.count, 2, "\(pieces)")
        for piece in pieces {
            XCTAssertLessThanOrEqual(Paste.lineBreaks(in: Substring(piece)), 2, piece)
        }
    }

    func testALongLineIsCutBetweenWordsNeverInOne() {
        let text = "the quick brown fox jumps over the lazy dog again and again"
        let pieces = assertPieces(text, budget: small)

        XCTAssertGreaterThan(pieces.count, 1)
        for piece in pieces {
            XCTAssertLessThanOrEqual(Paste.length(of: Substring(piece)), small.maxLength, piece)
            XCTAssertFalse(piece.first?.isWhitespace ?? true, "\(piece) starts mid-gap")
        }
        for piece in pieces.dropLast() {
            XCTAssertTrue(piece.last?.isWhitespace ?? false, "\(piece) ends inside a word")
        }
    }

    func testAWholeDictationIsCutWithinTheRealBudget() {
        let sentence = "Then add a test that pastes the long prompt and checks the clipboard comes back. "
        let text = String(repeating: sentence, count: 20)
        let pieces = assertPieces(text, budget: .agentPrompt)

        XCTAssertEqual(pieces.count, 3)
        for piece in pieces {
            XCTAssertLessThanOrEqual(Paste.length(of: Substring(piece)), 600)
        }
        for (piece, next) in zip(pieces, pieces.dropFirst()) {
            XCTAssertEqual(piece.last, " ", "a cut lands between two words")
            XCTAssertFalse(next.first?.isWhitespace ?? true)
        }
    }

    func testACodeSpanIsNeverCut() {
        let text = "run `git log --oneline --graph --all` then look"
        let pieces = assertPieces(text, budget: small)

        XCTAssertTrue(pieces.contains { $0.contains("`git log --oneline --graph --all` ") }, "\(pieces)")
    }

    func testAFencedBlockIsNeverCut() {
        let text = "Like this:\n```\nlet a = 1\nlet b = 2\nlet c = 3\n```\nthen stop"
        let pieces = assertPieces(text, budget: small)

        XCTAssertTrue(pieces.contains { $0.contains("```\nlet a = 1\nlet b = 2\nlet c = 3\n```") }, "\(pieces)")
    }

    func testAStrayBacktickHoldsNothingTogether() {
        let text = "the ` key sits left of one and the quick brown fox jumps"
        let pieces = assertPieces(text, budget: small)

        for piece in pieces {
            XCTAssertLessThanOrEqual(Paste.length(of: Substring(piece)), small.maxLength, piece)
        }
    }

    func testAWordLongerThanAPieceGoesAloneAndWhole() {
        let url = "https://example.com/a/very/long/path"
        let pieces = assertPieces("see \(url) now", budget: small)

        XCTAssertEqual(pieces, ["see ", "\(url) ", "now"])
    }

    func testTheLeadingSpaceOfAFittedDictationStaysOnTheFirstPiece() {
        let pieces = assertPieces(" and then the quick brown fox jumps over", budget: small)

        XCTAssertTrue(pieces[0].hasPrefix(" and"))
    }

    func testLengthsAndBreaksAreCountedAsTheAgentsCountThem() {
        XCTAssertEqual(Paste.length(of: "a\tb"), 6, "Claude Code makes a tab four spaces")
        XCTAssertEqual(Paste.length(of: "é😀"), 3, "UTF-16 units, never fewer than Codex's characters")
        XCTAssertEqual(Paste.lineBreaks(in: "a\r\nb\nc\rd"), 3)
    }

    // MARK: - Sending

    private var pasteboard: NSPasteboard!
    private let timing = ClipboardUtil.PasteTiming(hold: 0.05, settle: 0.05, deadline: 0.15)
    private let gap: TimeInterval = 0.02

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenSuperWhisperTests." + UUID().uuidString))
        ClipboardUtil.copyToClipboard("original", to: pasteboard)
        TranscriptInserter.noteNewerTranscription()
    }

    override func tearDown() {
        TranscriptInserter.noteNewerTranscription()
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    private final class Terminal {
        var read: [String?] = []
        var pastes = 0
        /// The pasteboard's change count at each ⌘V.
        var changes: [Int] = []
    }

    private func send(_ pieces: [String], keepOnClipboard: Bool = false, warnWhenMissed: Bool = false,
                      readsUpTo: Int = .max, inFrontFor: Int = .max, wantedFor: Int = .max,
                      terminal: Terminal) async -> TranscriptInserter.Insertion {
        let board = pasteboard!
        return await TranscriptInserter.pasteInPieces(
            pieces, standalone: pieces.joined(), keepOnClipboard: keepOnClipboard,
            retryShortcut: nil, warnWhenMissed: warnWhenMissed, on: board, timing: timing, gap: gap,
            wanted: { terminal.pastes < wantedFor },
            stillInFront: { terminal.pastes < inFrontFor },
            paste: {
                terminal.pastes += 1
                terminal.changes.append(board.changeCount)
                if terminal.pastes <= readsUpTo { terminal.read.append(board.string(forType: .string)) }
            })
    }

    /// Long enough for the last borrow to settle. A paste that stopped after a piece was read
    /// leaves that piece's borrow to settle on its own, later (`pieceTiming`).
    private func settle(afterAStop: Bool = false) async {
        let seconds = afterAStop ? timing.settle + gap + TranscriptInserter.pieceSettleMargin + 0.3 : 0.4
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testThePiecesGoOutInOrderAndTheClipboardComesBackOnce() async {
        let terminal = Terminal()

        let insertion = await send(["one\ntwo\n", "three\nfour\n", "five"], terminal: terminal)
        XCTAssertEqual(insertion, .done)
        XCTAssertEqual(terminal.read, ["one\ntwo\n", "three\nfour\n", "five"])
        // A restore between two pieces would be one more write than the piece's own.
        let steps = zip(terminal.changes.dropFirst(), terminal.changes).map { $0 - $1 }
        XCTAssertEqual(Set(steps).count, 1, "the clipboard came back between two pieces: \(steps)")

        await settle()
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        XCTAssertNil(TranscriptInserter.unlandedPaste)
    }

    func testKeepingItOnTheClipboardLeavesTheWholeDictation() async {
        let terminal = Terminal()

        _ = await send(["one ", "two ", "three"], keepOnClipboard: true, terminal: terminal)
        await settle()

        XCTAssertEqual(pasteboard.string(forType: .string), "one two three")
    }

    /// The terminal stops taking pastes: Return must not follow, and the rest is kept for the
    /// paste-last shortcut while the clipboard comes back.
    func testAPieceNobodyTakesStopsThePasteAndKeepsTheRest() async {
        let terminal = Terminal()

        let insertion = await send(["one ", "two ", "three"], readsUpTo: 1, terminal: terminal)
        await settle()

        XCTAssertEqual(insertion, .cutShort)
        XCTAssertEqual(terminal.pastes, 2, "nothing more is pasted after a miss")
        XCTAssertEqual(TranscriptInserter.unlandedPaste, "two three")
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    /// Another app came to the front between two pieces: no ⌘V goes to it.
    func testAnotherAppInFrontGetsNoPiece() async {
        let terminal = Terminal()

        let insertion = await send(["one ", "two ", "three"], inFrontFor: 1, terminal: terminal)
        await settle(afterAStop: true)

        XCTAssertEqual(insertion, .cutShort)
        XCTAssertEqual(terminal.pastes, 1)
        XCTAssertEqual(TranscriptInserter.unlandedPaste, "two three")
        XCTAssertEqual(pasteboard.string(forType: .string), "original",
                       "unannounced, the user's clipboard is not traded for the rest")
    }

    /// With the warning on, the rest goes on the clipboard and the user is told to paste it,
    /// as they are for any paste that found no field.
    func testAnotherAppInFrontWithTheWarningOnLeavesTheRestOnTheClipboard() async {
        let terminal = Terminal()

        let insertion = await send(["one ", "two ", "three"], warnWhenMissed: true, inFrontFor: 1,
                                   terminal: terminal)
        await settle(afterAStop: true)

        XCTAssertEqual(insertion, .onClipboard)
        XCTAssertEqual(terminal.pastes, 1)
        XCTAssertEqual(TranscriptInserter.unlandedPaste, "two three")
        XCTAssertEqual(pasteboard.string(forType: .string), "two three")
    }

    /// "Copy to clipboard" on: dictations stay there anyway, so the rest does, unannounced.
    func testAnotherAppInFrontWhileKeepingItOnTheClipboardLeavesTheRestThere() async {
        let terminal = Terminal()

        let insertion = await send(["one ", "two ", "three"], keepOnClipboard: true, inFrontFor: 1,
                                   terminal: terminal)
        await settle(afterAStop: true)

        XCTAssertEqual(insertion, .cutShort)
        XCTAssertEqual(terminal.pastes, 1)
        XCTAssertEqual(TranscriptInserter.unlandedPaste, "two three")
        XCTAssertEqual(pasteboard.string(forType: .string), "two three")
    }

    /// The dictation was thrown away while it went in: nothing more is pasted, and nothing is
    /// kept for the paste-last shortcut either.
    func testADiscardedDictationStopsThePiecesAndKeepsNothing() async {
        let terminal = Terminal()

        let insertion = await send(["one ", "two ", "three"], wantedFor: 1, terminal: terminal)
        await settle(afterAStop: true)

        XCTAssertEqual(insertion, .cutShort)
        XCTAssertEqual(terminal.pastes, 1)
        XCTAssertNil(TranscriptInserter.unlandedPaste)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    /// The paste-last shortcut keeps out of the way of a paste in pieces only while it lasts.
    func testThePasteIsKnownToBeGoingInWhileItLasts() async {
        let board = pasteboard!
        var flags: [Bool] = []

        _ = await TranscriptInserter.pasteInPieces(
            ["one ", "two"], standalone: "one two", keepOnClipboard: false,
            retryShortcut: nil, warnWhenMissed: false, on: board, timing: timing, gap: gap,
            stillInFront: { true },
            paste: {
                flags.append(TranscriptInserter.pastingInPieces)
                _ = board.string(forType: .string)
            })

        XCTAssertEqual(flags, [true, true])
        XCTAssertFalse(TranscriptInserter.pastingInPieces)
        await settle()
    }

    /// A newer transcription took over while the pieces were going out: it is now the one that
    /// counts, and the older paste stops.
    func testANewerTranscriptionStopsThePieces() async {
        let terminal = Terminal()
        let board = pasteboard!

        let insertion = await TranscriptInserter.pasteInPieces(
            ["one ", "two ", "three"], standalone: "one two three", keepOnClipboard: false,
            retryShortcut: nil, warnWhenMissed: false, on: board, timing: timing, gap: gap,
            stillInFront: { true },
            paste: {
                terminal.pastes += 1
                _ = board.string(forType: .string)
                TranscriptInserter.noteNewerTranscription()
            })

        XCTAssertEqual(insertion, .cutShort)
        XCTAssertEqual(terminal.pastes, 1)
        await settle(afterAStop: true)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testAPieceWaitsLongEnoughForTheNextToTakeOver() {
        let piece = TranscriptInserter.pieceTiming(timing, gap: 0.25)

        XCTAssertGreaterThan(piece.settle, 0.25 + timing.settle)
        XCTAssertGreaterThan(piece.hold, timing.hold, "the next piece may wait out the hold")
        XCTAssertEqual(piece.deadline, timing.deadline, "a piece nobody takes is still caught as soon")
    }

    /// An app that reads a paste twice must find the same piece both times: the next waits out
    /// the hold after the ⌘V, and the gap after the read.
    func testTheNextPieceWaitsOutTheHold() {
        let pause = TranscriptInserter.pauseBeforeNextPiece

        XCTAssertEqual(pause(0.25, 0.5, 0.05), 0.45, accuracy: 1e-9, "read at once: the hold is longer")
        XCTAssertEqual(pause(0.25, 0.5, 0.4), 0.25, accuracy: 1e-9, "read late: the gap is longer")
        XCTAssertEqual(pause(0.25, 0.5, 2), 0.25, accuracy: 1e-9)
    }

    // MARK: - Setting

    func testOnlyTheSettingAndAnAgentsWindowCutTheText() {
        let prefs = AppPreferences.shared
        let saved = prefs.pasteAgentPromptsInPieces
        defer { prefs.pasteAgentPromptsInPieces = saved }
        let long = String(repeating: "word ", count: 200)

        prefs.pasteAgentPromptsInPieces = false
        XCTAssertEqual(TranscriptInserter.agentPromptPieces(of: long, into: "com.mitchellh.ghostty",
                                                            windowTitle: "\u{2733} topic"), [long])
        prefs.pasteAgentPromptsInPieces = true
        XCTAssertEqual(TranscriptInserter.agentPromptPieces(of: long, into: "com.mitchellh.ghostty",
                                                            windowTitle: "~/code — zsh"), [long])
        XCTAssertGreaterThan(TranscriptInserter.agentPromptPieces(of: long, into: "com.mitchellh.ghostty",
                                                                  windowTitle: "\u{2733} topic").count, 1)
    }
}
