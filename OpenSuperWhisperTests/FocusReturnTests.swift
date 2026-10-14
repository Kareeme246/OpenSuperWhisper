import AppKit
import ApplicationServices
import XCTest

@testable import OpenSuperWhisper

/// Covers putting the focus back in the field a dictation started in (#164): when the app is
/// brought back, when only the field is, when nothing is touched, and what happens to the text
/// when the app cannot be reached. Everything runs against a fake system: nothing is activated,
/// focused or pasted on the machine running the tests, and the clipboard used is a private one.
@MainActor
final class FocusReturnTests: XCTestCase {

    private static let targetPID: pid_t = 4242
    private static let otherPID: pid_t = 777

    /// A stand-in for the workspace and Accessibility, scripted per test.
    private final class FakeSystem: FocusControlling {
        var frontmost: [pid_t?]
        var running = true
        var stillFocused: Bool? = false
        var activates = true
        var focuses = true
        /// Who is in front once an accepted activation has settled.
        var frontmostAfterActivation: pid_t? = FocusReturnTests.targetPID
        private(set) var calls: [String] = []

        init(frontmost: pid_t?) { self.frontmost = [frontmost] }

        func frontmostPID() -> pid_t? { frontmost.last ?? nil }
        func isRunning(_ target: FocusTarget) -> Bool { calls.append("running"); return running }
        func stillFocused(_ target: FocusTarget) -> Bool? { calls.append("stillFocused"); return stillFocused }
        func activate(_ target: FocusTarget) -> Bool {
            calls.append("activate")
            if activates { frontmost.append(frontmostAfterActivation) }
            return activates
        }
        func focus(_ target: FocusTarget) -> Bool { calls.append("focus"); return focuses }
        func settle() async { calls.append("settle") }
    }

    /// An element is only compared and handed back to the fake, never messaged: creating one
    /// asks nothing of the app it names.
    private func target(withField: Bool = true) -> FocusTarget {
        FocusTarget(pid: Self.targetPID, bundleID: "com.example.notes",
                    element: withField ? AXUIElementCreateApplication(Self.targetPID) : nil,
                    selection: nil)
    }

    // MARK: - Another app in front

    func testTheAppAndTheFieldAreBroughtBackBeforeInserting() async {
        let system = FakeSystem(frontmost: Self.otherPID)

        let outcome = await FocusReturn.bringBack(target(), using: system)

        XCTAssertEqual(outcome, .refocused)
        XCTAssertEqual(system.calls, ["running", "activate", "focus", "settle"])
    }

    /// Chrome and Electron often say nothing about their focused element: the app is still
    /// worth bringing back.
    func testAnAppThatDidNotNameItsFieldIsStillBroughtBack() async {
        let system = FakeSystem(frontmost: Self.otherPID)

        let outcome = await FocusReturn.bringBack(target(withField: false), using: system)

        XCTAssertEqual(outcome, .appOnly)
        XCTAssertEqual(system.calls, ["running", "activate", "settle"])
    }

    func testAClosedFieldFallsBackToTheApp() async {
        let system = FakeSystem(frontmost: Self.otherPID)
        system.focuses = false

        let outcome = await FocusReturn.bringBack(target(), using: system)

        XCTAssertEqual(outcome, .appOnly)
    }

    func testAnAppThatQuitIsNotReplacedByWhateverIsInFront() async {
        let system = FakeSystem(frontmost: Self.otherPID)
        system.running = false

        let outcome = await FocusReturn.bringBack(target(), using: system)

        XCTAssertEqual(outcome, .unreachable)
        XCTAssertEqual(system.calls, ["running"])
    }

    func testARefusedActivationLeavesNothingToInsertInto() async {
        let system = FakeSystem(frontmost: Self.otherPID)
        system.activates = false

        let outcome = await FocusReturn.bringBack(target(), using: system)

        XCTAssertEqual(outcome, .unreachable)
        XCTAssertFalse(system.calls.contains("focus"))
    }

    /// An activation the system accepted but never carried out would otherwise paste into the
    /// app the user moved to.
    func testAnActivationThatDidNotHappenIsCaughtBeforeInserting() async {
        let system = FakeSystem(frontmost: Self.otherPID)
        system.frontmostAfterActivation = Self.otherPID

        let outcome = await FocusReturn.bringBack(target(), using: system)

        XCTAssertEqual(outcome, .unreachable)
    }

    // MARK: - Same app in front

    func testNothingIsTouchedWhenTheFocusNeverLeft() async {
        let system = FakeSystem(frontmost: Self.targetPID)
        system.stillFocused = true

        let outcome = await FocusReturn.bringBack(target(), using: system)

        XCTAssertEqual(outcome, .alreadyThere)
        XCTAssertEqual(system.calls, ["running", "stillFocused"])
    }

    /// No answer is no evidence of a move: the app behaves as it did before this feature.
    func testAnAppThatCannotSayWhereTheFocusIsIsLeftAlone() async {
        let system = FakeSystem(frontmost: Self.targetPID)
        system.stillFocused = nil

        let outcome = await FocusReturn.bringBack(target(), using: system)

        XCTAssertEqual(outcome, .alreadyThere)
        XCTAssertFalse(system.calls.contains("focus"))
    }

    func testAnotherFieldOfTheSameAppGivesTheFocusBack() async {
        let system = FakeSystem(frontmost: Self.targetPID)

        let outcome = await FocusReturn.bringBack(target(), using: system)

        XCTAssertEqual(outcome, .refocused)
        XCTAssertEqual(system.calls, ["running", "stillFocused", "focus", "settle"])
    }

    func testTheSameAppWithoutANamedFieldIsLeftAlone() async {
        let system = FakeSystem(frontmost: Self.targetPID)

        let outcome = await FocusReturn.bringBack(target(withField: false), using: system)

        XCTAssertEqual(outcome, .alreadyThere)
        XCTAssertFalse(system.calls.contains("activate"))
    }

    // MARK: - Delivery

    private final class DeliveryLog {
        var broughtBack = 0
        var held: [Bool] = []
        var inserted = 0
    }

    private func deliver(_ outcome: FocusReturn.Outcome, target: FocusTarget? = nil,
                         returningFocus: Bool = true, warn: Bool = true, keepOnClipboard: Bool = false,
                         insertFindsNoField: Bool = false,
                         log: DeliveryLog) async -> DictationPipeline.Delivery {
        await DictationPipeline.deliver(
            to: target ?? self.target(), returningFocus: returningFocus, warn: warn,
            keepOnClipboard: keepOnClipboard,
            bringBack: { _ in log.broughtBack += 1; return outcome },
            hold: { log.held.append($0) },
            insert: { log.inserted += 1; return insertFindsNoField })
    }

    func testAReturnedFocusIsFollowedByTheUsualInsertion() async {
        let log = DeliveryLog()

        let delivery = await deliver(.refocused, log: log)

        XCTAssertEqual(delivery, .inserted)
        XCTAssertEqual(log.broughtBack, 1)
        XCTAssertEqual(log.inserted, 1)
        XCTAssertEqual(log.held, [])
    }

    func testTheUsualInsertionStillReportsAMissingField() async {
        let log = DeliveryLog()

        let delivery = await deliver(.appOnly, insertFindsNoField: true, log: log)

        XCTAssertEqual(delivery, .onClipboardAnnounced)
    }

    func testWithTheSettingOffTheFocusIsNotTouched() async {
        let log = DeliveryLog()

        let delivery = await deliver(.unreachable, returningFocus: false, log: log)

        XCTAssertEqual(delivery, .inserted)
        XCTAssertEqual(log.broughtBack, 0)
        XCTAssertEqual(log.inserted, 1)
    }

    func testAnUnreachableAppGetsTheClipboardAndTheNotice() async {
        let log = DeliveryLog()

        let delivery = await deliver(.unreachable, log: log)

        XCTAssertEqual(delivery, .onClipboardAnnounced)
        XCTAssertEqual(log.inserted, 0, "never inserted into whatever is in front instead")
        XCTAssertEqual(log.held, [true])
    }

    /// Unannounced, the clipboard is not replaced: the paste-last shortcut has the text.
    func testAnUnreachableAppWithTheWarningOffKeepsTheClipboard() async {
        let log = DeliveryLog()

        let delivery = await deliver(.unreachable, warn: false, log: log)

        XCTAssertEqual(delivery, .held)
        XCTAssertEqual(log.inserted, 0)
        XCTAssertEqual(log.held, [false])
    }

    func testAnUnreachableAppStillLeavesItOnTheClipboardWhenThatIsTheSetting() async {
        let log = DeliveryLog()

        let delivery = await deliver(.unreachable, warn: false, keepOnClipboard: true, log: log)

        XCTAssertEqual(delivery, .held)
        XCTAssertEqual(log.held, [true])
    }

    // MARK: - Holding the text

    private var pasteboard: NSPasteboard!

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

    func testHeldTextReachesThePasteLastShortcut() {
        TranscriptInserter.holdUndelivered("dictation", onClipboard: false, pasteboard: pasteboard)

        XCTAssertEqual(TranscriptInserter.unlandedPaste, "dictation")
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testHeldTextGoesOnTheClipboardWhenAsked() {
        TranscriptInserter.holdUndelivered("dictation", onClipboard: true, pasteboard: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "dictation")
        XCTAssertEqual(TranscriptInserter.unlandedPaste, "dictation")
    }
}
