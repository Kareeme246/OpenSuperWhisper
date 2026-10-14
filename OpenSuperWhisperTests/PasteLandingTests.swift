import AppKit
import XCTest

@testable import OpenSuperWhisper

/// Covers telling a paste that landed from one that went nowhere (#162): the text is handed
/// over only when someone reads it, the clipboard comes back after that read rather than after
/// the keystroke, and a paste nobody took is reported. Reading the private pasteboard stands in
/// for the app in front servicing ⌘V; the developer's real clipboard is never touched.
final class PasteLandingTests: XCTestCase {

    private var pasteboard: NSPasteboard!
    private let concealed = ClipboardUtil.concealedType

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenSuperWhisperTests." + UUID().uuidString))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    private func waitFor(_ seconds: TimeInterval) {
        let elapsed = expectation(description: "\(seconds) s elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { elapsed.fulfill() }
        wait(for: [elapsed], timeout: seconds + 2)
    }

    private func readLikeTheTargetApp() -> String? {
        pasteboard.string(forType: .string)
    }

    // MARK: - Landed or missed

    func testReadDuringThePasteCountsAsLanded() {
        ClipboardUtil.copyToClipboard("original", to: pasteboard)
        var outcomes: [ClipboardUtil.PasteOutcome] = []

        ClipboardUtil.borrowForPaste("transcription", on: pasteboard,
                                     timing: .init(hold: 0.05, settle: 0.05, deadline: 0.2),
                                     paste: { XCTAssertEqual(readLikeTheTargetApp(), "transcription") },
                                     outcome: { outcomes.append($0) })
        waitFor(0.4)

        XCTAssertEqual(outcomes, [.landed])
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testNobodyReadingIsReportedAsMissedAndTheClipboardComesBack() {
        ClipboardUtil.copyToClipboard("original", to: pasteboard)
        var outcomes: [ClipboardUtil.PasteOutcome] = []

        ClipboardUtil.borrowForPaste("transcription", on: pasteboard,
                                     timing: .init(hold: 0.05, settle: 0.05, deadline: 0.15),
                                     paste: {}, outcome: { outcomes.append($0) })
        waitFor(0.4)

        XCTAssertEqual(outcomes, [.missed])
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    /// A clipboard manager that honours the markers only looks at the types, and that must not
    /// pass for the paste.
    func testLookingAtTheTypesIsNotALanding() {
        var outcomes: [ClipboardUtil.PasteOutcome] = []

        ClipboardUtil.borrowForPaste("transcription", on: pasteboard,
                                     timing: .init(hold: 0.05, settle: 0.05, deadline: 0.15),
                                     paste: {
            _ = pasteboard.types
            _ = pasteboard.availableType(from: [.string])
        }, outcome: { outcomes.append($0) })
        waitFor(0.4)

        XCTAssertEqual(outcomes, [.missed])
    }

    // MARK: - Restore timing

    /// The race the fixed delay lost: an app that reads after the delay used to get the old
    /// clipboard. The restore now waits for the read.
    func testASlowAppStillGetsTheTranscription() {
        ClipboardUtil.copyToClipboard("original", to: pasteboard)
        var outcomes: [ClipboardUtil.PasteOutcome] = []
        var readBySlowApp: String?

        ClipboardUtil.borrowForPaste("transcription", on: pasteboard,
                                     timing: .init(hold: 0.05, settle: 0.3, deadline: 2),
                                     paste: {}, outcome: { outcomes.append($0) })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            readBySlowApp = self.readLikeTheTargetApp()
        }
        waitFor(0.3)
        XCTAssertEqual(readBySlowApp, "transcription")
        XCTAssertTrue(outcomes.isEmpty, "the clipboard must not come back the instant the app reads")

        waitFor(0.5)
        XCTAssertEqual(outcomes, [.landed])
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    /// The setting stays a floor: a quick read doesn't hand the clipboard back before it.
    func testAQuickReadStillHoldsTheTextForTheSetDelay() {
        ClipboardUtil.copyToClipboard("original", to: pasteboard)

        ClipboardUtil.borrowForPaste("transcription", on: pasteboard,
                                     timing: .init(hold: 0.4, settle: 0.05, deadline: 1),
                                     paste: { _ = readLikeTheTargetApp() })
        waitFor(0.2)
        XCTAssertEqual(pasteboard.string(forType: .string), "transcription")

        waitFor(0.4)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    // MARK: - What the clipboard is left holding

    /// "Copy to clipboard" on: the text stays, as an ordinary copy histories record.
    func testKeptTranscriptionEndsUpAsAnOrdinaryCopy() {
        ClipboardUtil.copyToClipboard("original", to: pasteboard)

        ClipboardUtil.borrowForPaste("transcription", on: pasteboard,
                                     afterLanding: .transcription, afterMissing: .transcription,
                                     timing: .init(hold: 0.05, settle: 0.05, deadline: 0.15),
                                     paste: { _ = readLikeTheTargetApp() })
        waitFor(0.4)

        XCTAssertEqual(pasteboard.string(forType: .string), "transcription")
        for marker in ClipboardUtil.transientTypes {
            XCTAssertFalse(pasteboard.types?.contains(marker) ?? false, "\(marker.rawValue) left on")
        }
    }

    /// A missed paste with no shortcut to reach the text again leaves it for a manual ⌘V, still
    /// out of clipboard histories.
    func testMissedPasteCanLeaveTheTextForAManualPaste() {
        ClipboardUtil.copyToClipboard("original", to: pasteboard)

        ClipboardUtil.borrowForPaste("transcription", on: pasteboard,
                                     afterMissing: .transientTranscription,
                                     timing: .init(hold: 0.05, settle: 0.05, deadline: 0.15),
                                     paste: {})
        waitFor(0.4)

        XCTAssertEqual(pasteboard.string(forType: .string), "transcription")
        for marker in ClipboardUtil.transientTypes {
            XCTAssertTrue(pasteboard.types?.contains(marker) ?? false, "missing \(marker.rawValue)")
        }
    }

    /// A password copied from a password manager is not put back: a fresh copy of it would
    /// outlive the manager's auto-clear.
    func testConcealedContentsAreNotRestored() {
        let item = NSPasteboardItem()
        item.setString("hunter2", forType: .string)
        item.setData(Data(), forType: concealed)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        ClipboardUtil.borrowForPaste("transcription", on: pasteboard,
                                     timing: .init(hold: 0.05, settle: 0.05, deadline: 0.15),
                                     paste: { _ = readLikeTheTargetApp() })
        waitFor(0.4)

        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testConcealedSnapshotKeepsNoData() {
        let item = NSPasteboardItem()
        item.setString("hunter2", forType: .string)
        item.setData(Data(), forType: concealed)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        let snapshot = ClipboardUtil.snapshot(of: pasteboard)

        XCTAssertTrue(snapshot.isConcealed)
        XCTAssertTrue(snapshot.items.isEmpty)
    }

    // MARK: - Overlap

    /// Only the borrow that ends says whether it landed: the earlier one's text was replaced
    /// before it could be told, and it hears only that it was taken over.
    func testASupersededBorrowIsOnlyToldItWasTakenOver() {
        ClipboardUtil.copyToClipboard("original", to: pasteboard)
        var first: [ClipboardUtil.PasteOutcome] = []
        var second: [ClipboardUtil.PasteOutcome] = []
        let timing = ClipboardUtil.PasteTiming(hold: 0.05, settle: 0.05, deadline: 0.15)

        ClipboardUtil.borrowForPaste("A", on: pasteboard, timing: timing,
                                     paste: {}, outcome: { first.append($0) })
        ClipboardUtil.borrowForPaste("B", on: pasteboard, timing: timing,
                                     paste: { _ = readLikeTheTargetApp() },
                                     outcome: { second.append($0) })
        waitFor(0.4)

        XCTAssertEqual(first, [.superseded])
        XCTAssertEqual(second, [.landed])
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    /// "Copy to clipboard" switched off while a paste that kept no snapshot is still pending:
    /// the pasteboard then holds that paste's text, and saving it as the previous contents would
    /// put dictated text back on the clipboard. With nothing saved, the clipboard is left empty.
    func testATakeoverNeverSavesTheEarlierTranscriptionAsThePreviousContents() {
        ClipboardUtil.copyToClipboard("original", to: pasteboard)
        let timing = ClipboardUtil.PasteTiming(hold: 0.05, settle: 0.05, deadline: 0.15)

        ClipboardUtil.borrowForPaste("A", on: pasteboard,
                                     afterLanding: .transcription, afterMissing: .transcription,
                                     timing: timing, paste: {})
        ClipboardUtil.borrowForPaste("B", on: pasteboard, timing: timing,
                                     paste: { _ = readLikeTheTargetApp() })
        waitFor(0.4)

        XCTAssertNil(pasteboard.string(forType: .string), "dictated text came back as the user's own")
    }

    // MARK: - Late and off-main reads

    /// Once a miss is settled the clipboard no longer holds the borrowed item, so a busy app
    /// reading late gets the restored contents and the outcome stays the one already given.
    func testAReadAfterTheDeadlineIsNotASecondOutcome() {
        ClipboardUtil.copyToClipboard("original", to: pasteboard)
        var outcomes: [ClipboardUtil.PasteOutcome] = []

        ClipboardUtil.borrowForPaste("transcription", on: pasteboard,
                                     timing: .init(hold: 0.05, settle: 0.05, deadline: 0.15),
                                     paste: {}, outcome: { outcomes.append($0) })
        waitFor(0.3)
        XCTAssertEqual(readLikeTheTargetApp(), "original")
        waitFor(0.3)

        XCTAssertEqual(outcomes, [.missed])
    }

    /// A read from another thread of this process runs the provider on that thread; the borrow
    /// still hears of it on the main thread, where its timers live.
    func testAReadOffTheMainThreadIsCountedOnTheMainThread() {
        ClipboardUtil.copyToClipboard("original", to: pasteboard)
        var outcomes: [ClipboardUtil.PasteOutcome] = []
        var reportedOnMain: [Bool] = []
        let board = pasteboard!

        ClipboardUtil.borrowForPaste("transcription", on: board,
                                     timing: .init(hold: 0.05, settle: 0.05, deadline: 1),
                                     paste: {
            DispatchQueue.global().async { _ = board.string(forType: .string) }
        }, outcome: {
            outcomes.append($0)
            reportedOnMain.append(Thread.isMainThread)
        })
        waitFor(0.6)

        XCTAssertEqual(outcomes, [.landed])
        XCTAssertEqual(reportedOnMain, [true])
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    // MARK: - Policy

    func testWhereAMissedPasteLeavesTheClipboard() {
        func afterMissing(keep: Bool, bound: Bool, warn: Bool) -> ClipboardUtil.Afterwards {
            TranscriptInserter.afterMissedPaste(keepOnClipboard: keep, pasteLastBound: bound,
                                                warnWhenMissed: warn)
        }
        XCTAssertEqual(afterMissing(keep: true, bound: false, warn: true), .transcription)
        XCTAssertEqual(afterMissing(keep: true, bound: true, warn: true), .transcription)
        XCTAssertEqual(afterMissing(keep: false, bound: true, warn: true), .previousContents)
        XCTAssertEqual(afterMissing(keep: false, bound: false, warn: true), .transientTranscription)
        // Nobody would say the clipboard had been swapped for the words, so it isn't (#44).
        XCTAssertEqual(afterMissing(keep: false, bound: false, warn: false), .previousContents)
        XCTAssertEqual(afterMissing(keep: true, bound: false, warn: false), .transcription)
    }

    func testMissedPasteDeadlineNeverCutsTheSetDelayShort() {
        let prefs = AppPreferences.shared
        let saved = prefs.clipboardRestoreDelayMs
        defer { prefs.clipboardRestoreDelayMs = saved }

        prefs.clipboardRestoreDelayMs = 500
        XCTAssertEqual(ClipboardUtil.PasteTiming.current.deadline,
                       ClipboardUtil.PasteTiming.missedPasteDeadline, accuracy: 0.0001)
        prefs.clipboardRestoreDelayMs = 2000
        XCTAssertEqual(ClipboardUtil.PasteTiming.current.deadline, 2, accuracy: 0.0001)
    }

    func testMissedPasteNoticeNamesTheKeys() {
        XCTAssertTrue(TranscriptInserter.missedPasteNotice(retryKeys: "⌃⌘V").contains("⌃⌘V"))
    }
}
