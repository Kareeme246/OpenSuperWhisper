import XCTest

@testable import OpenSuperWhisper

/// Who keeps the level capture open. Opening it lights the microphone indicator in the menu bar,
/// so it has to close the moment the last view showing the level goes, and never open where the
/// user has not granted access.
@MainActor
final class InputLevelMonitorTests: XCTestCase {

    private final class FakeSource: InputLevelSource {
        private(set) var starts: [String?] = []
        private(set) var stops = 0
        var onReading: ((InputLevelReading) -> Void)?

        func start(deviceUID: String?, onReading: @escaping (InputLevelReading) -> Void) {
            starts.append(deviceUID)
            self.onReading = onReading
        }

        func stop() { stops += 1 }
    }

    private var source: FakeSource!
    private var allowed = true
    private var monitor: InputLevelMonitor!

    override func setUp() {
        super.setUp()
        source = FakeSource()
        allowed = true
        monitor = InputLevelMonitor(source: source, mayOpenInput: { [unowned self] in allowed })
    }

    /// Lets the readings hopped onto the main actor land.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testTheFirstViewOpensTheCaptureAndTheLastOneClosesIt() {
        let popover = monitor.begin(deviceUID: "usb")
        let settings = monitor.begin(deviceUID: "usb")
        XCTAssertEqual(source.starts, ["usb"], "one capture for both views")
        XCTAssertTrue(monitor.isRunning)

        monitor.end(popover)
        XCTAssertEqual(source.stops, 0, "still shown in Settings")
        monitor.end(settings)
        XCTAssertEqual(source.stops, 1)
        XCTAssertFalse(monitor.isRunning)
    }

    func testACaptureThatDeliversNothingEndsUpTooQuiet() async throws {
        _ = monitor.begin(deviceUID: "built-in")
        XCTAssertEqual(monitor.reading.verdict, .listening)
        try await Task.sleep(for: .seconds(QuietInput.listeningWindow + 0.5))
        XCTAssertEqual(monitor.reading.verdict, .tooQuiet)
    }

    func testACaptureThatDeliversKeepsItsOwnVerdict() async throws {
        _ = monitor.begin(deviceUID: "built-in")
        source.onReading?(InputLevelReading(levelDBFS: -30, peakDBFS: -25, verdict: .normal))
        await settle()
        try await Task.sleep(for: .seconds(QuietInput.listeningWindow + 0.5))
        XCTAssertEqual(monitor.reading.verdict, .normal)
    }

    func testEndingTheSameTokenTwiceDoesNotReleaseAnotherView() {
        let popover = monitor.begin(deviceUID: nil)
        _ = monitor.begin(deviceUID: nil)
        monitor.end(popover)
        monitor.end(popover)
        XCTAssertTrue(monitor.isRunning)
        XCTAssertEqual(source.stops, 0)
    }

    func testPickingAnotherMicrophoneSwitchesTheCapture() {
        let token = monitor.begin(deviceUID: "built-in")
        monitor.retarget(token, deviceUID: "usb")
        XCTAssertEqual(source.starts, ["built-in", "usb"])
        XCTAssertEqual(source.stops, 1)

        monitor.retarget(token, deviceUID: "usb")
        XCTAssertEqual(source.starts.count, 2, "the same microphone again is not a switch")
    }

    func testAReleasedTokenCannotSwitchTheMicrophone() {
        let popover = monitor.begin(deviceUID: "built-in")
        _ = monitor.begin(deviceUID: "built-in")
        monitor.end(popover)
        monitor.retarget(popover, deviceUID: "usb")
        XCTAssertEqual(source.starts, ["built-in"])
    }

    func testAViewShowingAnotherMicrophoneSwitchesTheSharedCapture() {
        _ = monitor.begin(deviceUID: "built-in")
        _ = monitor.begin(deviceUID: "usb")
        XCTAssertEqual(source.starts, ["built-in", "usb"])
    }

    func testNothingOpensWithoutAccess() {
        allowed = false
        let token = monitor.begin(deviceUID: "usb")
        monitor.retarget(token, deviceUID: "built-in")
        monitor.end(token)
        XCTAssertTrue(source.starts.isEmpty)
        XCTAssertEqual(source.stops, 0)
        XCTAssertFalse(monitor.isRunning)
    }

    func testReadingsArrivePublishedOnTheMainActor() async {
        _ = monitor.begin(deviceUID: nil)
        let loud = InputLevelReading(levelDBFS: -20, peakDBFS: -18, verdict: .normal)
        source.onReading?(loud)
        await settle()
        XCTAssertEqual(monitor.reading, loud)
    }

    /// A reading still on its way from a capture that was closed must not repaint the cleared bar.
    func testReadingsFromAClosedCaptureAreDropped() async {
        let token = monitor.begin(deviceUID: nil)
        let late = source.onReading
        monitor.end(token)
        late?(InputLevelReading(levelDBFS: -20, peakDBFS: -18, verdict: .normal))
        await settle()
        XCTAssertEqual(monitor.reading, .silent)
    }

    func testSwitchingMicrophonesStartsFromSilence() async {
        let token = monitor.begin(deviceUID: "built-in")
        source.onReading?(InputLevelReading(levelDBFS: -20, peakDBFS: -18, verdict: .normal))
        await settle()
        XCTAssertNotEqual(monitor.reading, .silent)
        monitor.retarget(token, deviceUID: "usb")
        XCTAssertEqual(monitor.reading, .silent, "the new microphone has not been heard yet")
    }

    #if DEBUG
    func testStagedLevelsNeverOpenTheMicrophone() {
        let staged = InputLevelReading(levelDBFS: -40, peakDBFS: -36, verdict: .normal)
        monitor.stage(staged)
        let token = monitor.begin(deviceUID: "usb")
        monitor.end(token)
        XCTAssertTrue(source.starts.isEmpty)
        XCTAssertEqual(monitor.reading, staged)
    }
    #endif
}
