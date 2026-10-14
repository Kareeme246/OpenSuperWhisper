import AppKit
import XCTest

@testable import OpenSuperWhisper

/// Covers what the insertion does around a borrowed paste (#162): which way the clipboard is
/// settled for each setting, the missed text kept for the paste-last shortcut, and that a newer
/// transcription always wins over it. The paste runs on a private pasteboard and posts no
/// keystroke; reading that pasteboard stands in for the app in front taking the ⌘V. The warning
/// stays off so no notice window is opened.
@MainActor
final class MissedPasteWiringTests: XCTestCase {

    private var pasteboard: NSPasteboard!
    private let timing = ClipboardUtil.PasteTiming(hold: 0.05, settle: 0.05, deadline: 0.15)

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

    /// - Returns: what the app in front read, nil when it read nothing.
    @discardableResult
    private func paste(_ text: String = "transcription", rich: RichPasteText? = nil,
                       standalone: String? = nil, keepOnClipboard: Bool = false,
                       retryShortcut: String? = nil, takenByTheApp: Bool) -> String? {
        var read: String?
        TranscriptInserter.pasteThroughClipboard(text, rich: rich, standalone: standalone,
                                                 keepOnClipboard: keepOnClipboard,
                                                 retryShortcut: retryShortcut, warnWhenMissed: false,
                                                 on: pasteboard, timing: timing,
                                                 paste: { if takenByTheApp { read = readLikeTheTargetApp() } })
        return read
    }

    private func readLikeTheTargetApp() -> String? {
        pasteboard.string(forType: .string)
    }

    private func waitFor(_ seconds: TimeInterval) {
        let elapsed = expectation(description: "\(seconds) s elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { elapsed.fulfill() }
        wait(for: [elapsed], timeout: seconds + 2)
    }

    // MARK: - Landed

    func testALandedPasteGivesTheClipboardBackAndKeepsNothing() {
        paste(takenByTheApp: true)
        waitFor(0.4)

        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        XCTAssertNil(TranscriptInserter.unlandedPaste)
    }

    func testKeepingItOnTheClipboardLeavesTheTranscriptionAfterALanding() {
        paste(keepOnClipboard: true, takenByTheApp: true)
        waitFor(0.4)

        XCTAssertEqual(pasteboard.string(forType: .string), "transcription")
    }

    // MARK: - Missed

    /// Unannounced, a miss must not cost the user their clipboard: the words are kept for the
    /// paste-last shortcut instead.
    func testAMissedPasteIsKeptForTheShortcutAndTheClipboardComesBack() {
        paste(takenByTheApp: false)
        waitFor(0.4)

        XCTAssertEqual(TranscriptInserter.unlandedPaste, "transcription")
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testAMissedPasteWithAShortcutBoundStillGivesTheClipboardBack() {
        paste(retryShortcut: "⌃⌘V", takenByTheApp: false)
        waitFor(0.4)

        XCTAssertEqual(TranscriptInserter.unlandedPaste, "transcription")
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    /// A transcription that went somewhere after the paste, say an answer to an agent, is the
    /// last dictation now; the older miss must not be what the shortcut pastes.
    func testANewerTranscriptionWinsOverAnOlderMiss() {
        paste(takenByTheApp: false)
        TranscriptInserter.noteNewerTranscription()
        waitFor(0.4)

        XCTAssertNil(TranscriptInserter.unlandedPaste)
    }

    /// A busy app that reads after the deadline gets what the clipboard was settled to, and the
    /// miss already reported stays the only report.
    func testAReadAfterTheDeadlineChangesNothing() {
        paste(takenByTheApp: false)
        waitFor(0.3)

        XCTAssertEqual(readLikeTheTargetApp(), "original")
        waitFor(0.3)
        XCTAssertEqual(TranscriptInserter.unlandedPaste, "transcription")
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    // MARK: - Fitted to the field (#163)

    /// The paste carries the text fitted to the field, but the clipboard keeps the sentence: a
    /// lowercase start and a dropped period belong to that one place.
    func testTheFieldGetsTheFittedTextAndTheClipboardKeepsTheSentence() {
        let read = paste(" tomorrow", standalone: "Tomorrow.", keepOnClipboard: true, takenByTheApp: true)
        waitFor(0.4)

        XCTAssertEqual(read, " tomorrow")
        XCTAssertEqual(pasteboard.string(forType: .string), "Tomorrow.")
    }

    func testAMissedFittedPasteHoldsTheSentence() {
        paste(" tomorrow", standalone: "Tomorrow.", keepOnClipboard: true, takenByTheApp: false)
        waitFor(0.4)

        XCTAssertEqual(TranscriptInserter.unlandedPaste, "Tomorrow.")
        XCTAssertEqual(pasteboard.string(forType: .string), "Tomorrow.")
    }

    // MARK: - A list pasted as bullets (#166)

    /// A missed list paste is held and kept as the plain sentence: the paste-last shortcut makes
    /// the rich forms again for whichever app it pastes into, and nothing rich outlives the paste.
    func testAMissedRichPasteKeepsOnlyThePlainSentence() throws {
        let fitted = " we need:\n- bread\n- chips"
        let sentence = "We need:\n- bread\n- chips"
        let rich = try XCTUnwrap(RichListPaste.richText(for: fitted, into: "com.apple.Notes"))

        paste(fitted, rich: rich, standalone: sentence, keepOnClipboard: true, takenByTheApp: false)
        waitFor(0.4)

        XCTAssertEqual(TranscriptInserter.unlandedPaste, sentence)
        XCTAssertEqual(pasteboard.string(forType: .string), sentence)
        let types = pasteboard.types ?? []
        XCTAssertFalse(types.contains(.html), "\(types)")
        XCTAssertFalse(types.contains(.rtf), "\(types)")
    }

    func testAMissedRichPasteGivesTheClipboardBack() throws {
        let rich = try XCTUnwrap(RichListPaste.richText(for: "- bread\n- chips", into: "com.apple.Notes"))

        paste("- bread\n- chips", rich: rich, takenByTheApp: false)
        waitFor(0.4)

        XCTAssertEqual(TranscriptInserter.unlandedPaste, "- bread\n- chips")
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        XCTAssertFalse((pasteboard.types ?? []).contains(.html))
    }

    // MARK: - Paste last

    func testPasteLastReachesTheMissedPasteFirst() async throws {
        paste(takenByTheApp: false)
        try await Task.sleep(nanoseconds: 400_000_000)

        var inserted: [String] = []
        await PasteLastTranscript.run(insertingWith: { inserted.append($0) })

        XCTAssertEqual(inserted, ["transcription"])
    }
}
