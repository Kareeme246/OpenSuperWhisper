import XCTest

@testable import OpenSuperWhisper

/// When the microphone picker says a microphone is too quiet. A built-in MacBook microphone
/// recorded 25 to 30 dB low and the only symptom was poor transcriptions; the warning has to catch
/// that, without nagging someone who simply has not spoken yet.
final class QuietInputTests: XCTestCase {

    func testNothingIsSaidBeforeTheUserHasHadTimeToSpeak() {
        XCTAssertEqual(QuietInput.verdict(loudestDBFS: -70, listenedFor: 1), .listening)
        XCTAssertEqual(QuietInput.verdict(loudestDBFS: -70, listenedFor: QuietInput.listeningWindow - 0.01), .listening)
    }

    func testAMicrophoneThatNeverReachesSpeechLevelIsTooQuiet() {
        XCTAssertEqual(QuietInput.verdict(loudestDBFS: -50, listenedFor: QuietInput.listeningWindow), .tooQuiet)
        XCTAssertEqual(QuietInput.verdict(loudestDBFS: QuietInput.silenceDBFS, listenedFor: 10), .tooQuiet)
    }

    func testSpeechLevelIsNormalStraightAway() {
        XCTAssertEqual(QuietInput.verdict(loudestDBFS: -20, listenedFor: 0.2), .normal)
        XCTAssertEqual(QuietInput.verdict(loudestDBFS: QuietInput.thresholdDBFS, listenedFor: 10), .normal)
    }

    func testOnlyNormalCountsAsNotQuietForVoiceOver() {
        XCTAssertTrue(QuietInput.Verdict.listening.isQuiet)
        XCTAssertTrue(QuietInput.Verdict.tooQuiet.isQuiet)
        XCTAssertFalse(QuietInput.Verdict.normal.isQuiet)
    }

    func testAPauseAfterSpeakingDoesNotBringTheWarningBack() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var watch = QuietInputWatch(startedAt: start)
        watch.observe(peakDBFS: -18)
        watch.observe(peakDBFS: -75)
        XCTAssertEqual(watch.verdict(at: start.addingTimeInterval(30)), .normal)
    }

    func testTheWatchWarnsOnceTheWindowPassesInNearSilence() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var watch = QuietInputWatch(startedAt: start)
        watch.observe(peakDBFS: -58)
        watch.observe(peakDBFS: -52)
        XCTAssertEqual(watch.verdict(at: start.addingTimeInterval(1)), .listening)
        XCTAssertEqual(watch.verdict(at: start.addingTimeInterval(QuietInput.listeningWindow)), .tooQuiet)
    }

    func testPeakOfABufferInDecibels() {
        let samples: [Float] = [0, 0.25, -0.5, 0.1]
        let peak = samples.withUnsafeBufferPointer { QuietInput.peakDBFS(of: $0) }
        XCTAssertEqual(peak, 20 * log10(0.5), accuracy: 0.001)
    }

    func testSilenceAndEmptyBuffersHaveAFiniteFloor() {
        let zeros = [Float](repeating: 0, count: 64)
        XCTAssertEqual(zeros.withUnsafeBufferPointer { QuietInput.peakDBFS(of: $0) }, QuietInput.silenceDBFS)
        XCTAssertEqual([Float]().withUnsafeBufferPointer { QuietInput.peakDBFS(of: $0) }, QuietInput.silenceDBFS)
        XCTAssertEqual(QuietInput.dbfs(amplitude: .nan), QuietInput.silenceDBFS)
    }
}
