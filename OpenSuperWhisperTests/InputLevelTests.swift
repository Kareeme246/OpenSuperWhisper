import XCTest

@testable import OpenSuperWhisper

/// The input level bar's scale, colours and motion. The zones have to put speech from a working
/// microphone in green and the faulty built-in MacBook microphone (25 to 30 dB down) in red.
final class InputLevelTests: XCTestCase {

    // MARK: - Scale

    func testTheBarFillsLinearlyInDecibelsBetweenItsEnds() {
        XCTAssertEqual(InputLevel.fraction(dBFS: InputLevel.emptyDBFS), 0)
        XCTAssertEqual(InputLevel.fraction(dBFS: InputLevel.fullDBFS), 1)
        let middle = (InputLevel.emptyDBFS + InputLevel.fullDBFS) / 2
        XCTAssertEqual(InputLevel.fraction(dBFS: middle), 0.5, accuracy: 0.0001)
    }

    func testLevelsPastEitherEndStayOnTheBar() {
        XCTAssertEqual(InputLevel.fraction(dBFS: InputLevel.silenceDBFS), 0)
        XCTAssertEqual(InputLevel.fraction(dBFS: 0), 1)
        XCTAssertEqual(InputLevel.fraction(dBFS: -.infinity), 0)
        XCTAssertEqual(InputLevel.fraction(dBFS: .nan), 0)
    }

    func testZonesFollowTheThresholds() {
        XCTAssertEqual(InputLevel.zone(dBFS: InputLevel.silenceDBFS), .tooQuiet)
        XCTAssertEqual(InputLevel.zone(dBFS: InputLevel.lowFloorDBFS - 0.1), .tooQuiet)
        XCTAssertEqual(InputLevel.zone(dBFS: InputLevel.lowFloorDBFS), .low)
        XCTAssertEqual(InputLevel.zone(dBFS: InputLevel.goodFloorDBFS - 0.1), .low)
        XCTAssertEqual(InputLevel.zone(dBFS: InputLevel.goodFloorDBFS), .good)
        XCTAssertEqual(InputLevel.zone(dBFS: 0), .good)
    }

    /// Speech at a normal distance (-30 to -18 dBFS RMS) is green; the same speech through the
    /// faulty built-in microphone, 25 to 30 dB lower, is red.
    func testSpeechIsGreenAndTheFaultyMicrophoneIsRed() {
        XCTAssertEqual(InputLevel.zone(dBFS: -30), .good)
        XCTAssertEqual(InputLevel.zone(dBFS: -18), .good)
        XCTAssertEqual(InputLevel.zone(dBFS: -30 - 25), .tooQuiet)
    }

    func testTheZonesSitInOrderInsideTheBar() {
        XCTAssertLessThan(InputLevel.emptyDBFS, InputLevel.lowFloorDBFS)
        XCTAssertLessThan(InputLevel.lowFloorDBFS, InputLevel.goodFloorDBFS)
        XCTAssertLessThan(InputLevel.goodFloorDBFS, InputLevel.fullDBFS)
    }

    // MARK: - RMS

    func testAFullScaleSquareWaveIsZeroDecibels() {
        let square: [Float] = (0..<256).map { $0.isMultiple(of: 2) ? 1 : -1 }
        XCTAssertEqual(InputLevel.rmsDBFS(ofChannels: [square]), 0, accuracy: 0.001)
    }

    func testRMSNotPeak() {
        // One full-scale sample among 99 zeros: peak 0 dBFS, power 1/100.
        var click = [Float](repeating: 0, count: 100)
        click[0] = 1
        XCTAssertEqual(InputLevel.rmsDBFS(ofChannels: [click]), -20, accuracy: 0.001)
    }

    func testChannelsArePowerAveraged() {
        let live = [Float](repeating: 0.5, count: 64)
        let silent = [Float](repeating: 0, count: 64)
        let one = InputLevel.rmsDBFS(ofChannels: [live])
        XCTAssertEqual(InputLevel.rmsDBFS(ofChannels: [live, silent]), one - 10 * log10(2), accuracy: 0.001)
        XCTAssertEqual(InputLevel.rmsDBFS(ofChannels: [live, live]), one, accuracy: 0.001)
    }

    func testSilenceAndEmptyBuffersHaveAFiniteFloor() {
        XCTAssertEqual(InputLevel.rmsDBFS(ofChannels: [[Float](repeating: 0, count: 64)]), InputLevel.silenceDBFS)
        XCTAssertEqual(InputLevel.rmsDBFS(ofChannels: [[]]), InputLevel.silenceDBFS)
        XCTAssertEqual(InputLevel.rmsDBFS(ofChannels: []), InputLevel.silenceDBFS)
        XCTAssertEqual(InputLevel.dbfs(power: .nan), InputLevel.silenceDBFS)
    }

    // MARK: - Smoothing

    private func feed(_ smoother: inout InputLevelSmoother, _ dBFS: Float, for seconds: TimeInterval,
                      step: TimeInterval = 0.01) {
        for _ in 0..<Int((seconds / step).rounded()) {
            smoother.feed(rmsDBFS: dBFS, duration: step)
        }
    }

    func testTheBarRisesAlmostAtOnce() {
        var smoother = InputLevelSmoother()
        feed(&smoother, -20, for: InputLevelSmoother.attackTime)
        XCTAssertEqual(smoother.levelDBFS, -20, accuracy: 0.01)
    }

    func testTheBarFallsOverTheReleaseTimeRatherThanAtOnce() {
        var smoother = InputLevelSmoother()
        feed(&smoother, InputLevel.fullDBFS, for: 0.1)
        feed(&smoother, InputLevel.silenceDBFS, for: InputLevelSmoother.releaseTime / 2)
        let halfway = (InputLevel.emptyDBFS + InputLevel.fullDBFS) / 2
        XCTAssertEqual(smoother.levelDBFS, halfway, accuracy: 0.5)
        feed(&smoother, InputLevel.silenceDBFS, for: InputLevelSmoother.releaseTime / 2)
        XCTAssertEqual(smoother.levelDBFS, InputLevel.emptyDBFS, accuracy: 0.01)
    }

    /// Big buffers or small, the same audio moves the bar the same way.
    func testBufferSizeDoesNotChangeTheMotion() {
        var small = InputLevelSmoother()
        var large = InputLevelSmoother()
        feed(&small, -20, for: 0.2, step: 0.005)
        feed(&large, -20, for: 0.2, step: 0.04)
        feed(&small, -55, for: 0.12, step: 0.005)
        feed(&large, -55, for: 0.12, step: 0.04)
        XCTAssertEqual(small.levelDBFS, large.levelDBFS, accuracy: 0.01)
    }

    func testThePeakHoldsThenFalls() {
        var smoother = InputLevelSmoother()
        feed(&smoother, -20, for: 0.1)
        feed(&smoother, InputLevel.silenceDBFS, for: InputLevelSmoother.peakHoldTime - 0.05)
        XCTAssertEqual(smoother.peakDBFS, -20, accuracy: 0.01, "still held")
        XCTAssertEqual(smoother.levelDBFS, InputLevel.emptyDBFS, accuracy: 0.01, "while the bar has dropped")
        feed(&smoother, InputLevel.silenceDBFS, for: 0.15)
        XCTAssertLessThan(smoother.peakDBFS, -20, "falling once the hold is over")
        feed(&smoother, InputLevel.silenceDBFS, for: InputLevelSmoother.peakReleaseTime)
        XCTAssertEqual(smoother.peakDBFS, InputLevel.emptyDBFS, accuracy: 0.01)
    }

    func testANewHighResetsTheHold() {
        var smoother = InputLevelSmoother()
        feed(&smoother, -40, for: 0.1)
        feed(&smoother, InputLevel.silenceDBFS, for: 0.5)
        feed(&smoother, -25, for: 0.1)
        XCTAssertEqual(smoother.peakDBFS, -25, accuracy: 0.01)
        feed(&smoother, InputLevel.silenceDBFS, for: InputLevelSmoother.peakHoldTime - 0.05)
        XCTAssertEqual(smoother.peakDBFS, -25, accuracy: 0.01)
    }

    func testThePeakNeverSitsBelowTheBar() {
        var smoother = InputLevelSmoother()
        for step in 0..<400 {
            smoother.feed(rmsDBFS: step.isMultiple(of: 37) ? -15 : -45, duration: 0.01)
            XCTAssertGreaterThanOrEqual(smoother.peakDBFS, smoother.levelDBFS)
        }
    }

    // MARK: - Publishing

    func testReadingsAreThrottled() {
        var processor = InputLevelProcessor()
        var published = 0
        // Two seconds of 5 ms buffers, at a steady level so the verdict changes only once.
        for _ in 0..<400 where processor.consume(rmsDBFS: -25, duration: 0.005) != nil {
            published += 1
        }
        let ceiling = 2 / InputLevelProcessor.publishInterval
        XCTAssertLessThanOrEqual(Double(published), ceiling + 2)
        XCTAssertGreaterThanOrEqual(Double(published), ceiling * 0.8)
    }

    /// The warning appears on the buffer that crosses the listening window, not on the next
    /// throttled reading.
    func testAVerdictChangeIsPublishedWithoutWaiting() {
        var processor = InputLevelProcessor()
        var watch = QuietInputWatch()
        for buffer in 0..<Int(2 * QuietInput.listeningWindow / 0.01) {
            watch.observe(rmsDBFS: -70, duration: 0.01)
            let reading = processor.consume(rmsDBFS: -70, duration: 0.01)
            if watch.verdict == .tooQuiet {
                XCTAssertEqual(reading?.verdict, .tooQuiet, "published on buffer \(buffer)")
                return
            }
            XCTAssertNotEqual(reading?.verdict, .tooQuiet)
        }
        XCTFail("the window never passed")
    }
}
