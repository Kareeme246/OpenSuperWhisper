import XCTest

@testable import OpenSuperWhisper

/// When the microphone picker says a microphone is too quiet. A built-in MacBook microphone
/// recorded 25 to 30 dB low and the only symptom was poor transcriptions; the warning has to catch
/// that, without nagging someone who simply has not spoken yet, and without a click or a key
/// press passing for speech.
final class QuietInputTests: XCTestCase {

    private func listen(_ watch: inout QuietInputWatch, _ dBFS: Float, for seconds: TimeInterval,
                        step: TimeInterval = 0.01) {
        for _ in 0..<Int((seconds / step).rounded()) {
            watch.observe(rmsDBFS: dBFS, duration: step)
        }
    }

    func testTheWarningMatchesTheBarsOrangeZone() {
        XCTAssertEqual(QuietInput.thresholdDBFS, InputLevel.lowFloorDBFS)
    }

    func testNothingIsSaidBeforeTheUserHasHadTimeToSpeak() {
        var watch = QuietInputWatch()
        listen(&watch, -70, for: QuietInput.listeningWindow - 0.1)
        XCTAssertEqual(watch.verdict, .listening)
    }

    func testAMicrophoneThatNeverReachesOrangeIsTooQuiet() {
        var watch = QuietInputWatch()
        listen(&watch, InputLevel.lowFloorDBFS - 2, for: QuietInput.listeningWindow + 0.01)
        XCTAssertEqual(watch.verdict, .tooQuiet)
    }

    func testSpeechHeldForTheWindowIsNormalStraightAway() {
        var watch = QuietInputWatch()
        listen(&watch, -28, for: QuietInput.sustainWindow + 0.01)
        XCTAssertEqual(watch.verdict, .normal)
    }

    func testAnOrangeLevelIsEnough() {
        var watch = QuietInputWatch()
        listen(&watch, QuietInput.thresholdDBFS, for: QuietInput.sustainWindow + 0.01)
        listen(&watch, -70, for: QuietInput.listeningWindow)
        XCTAssertEqual(watch.verdict, .normal)
    }

    /// A click is loud for one buffer; it must not clear the warning on a microphone that does not
    /// hear the user.
    func testClicksDoNotCountAsSpeech() {
        var watch = QuietInputWatch()
        for _ in 0..<20 {
            listen(&watch, -10, for: 0.02)
            listen(&watch, -62, for: 0.2)
        }
        XCTAssertEqual(watch.verdict, .tooQuiet)
    }

    func testAPauseAfterSpeakingDoesNotBringTheWarningBack() {
        var watch = QuietInputWatch()
        listen(&watch, -22, for: 0.4)
        listen(&watch, -75, for: 30)
        XCTAssertEqual(watch.verdict, .normal)
    }

    func testOnlyAudioTimeCounts() {
        var watch = QuietInputWatch()
        listen(&watch, -70, for: 1)
        XCTAssertEqual(watch.listened, 1, accuracy: 0.0001)
        XCTAssertEqual(watch.verdict, .listening)
    }
}
