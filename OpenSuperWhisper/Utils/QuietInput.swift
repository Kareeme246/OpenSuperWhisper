import Accelerate
import Foundation

/// Whether the microphone a picker is showing hears the user well enough to transcribe them.
///
/// Prompted by a built-in MacBook microphone that recorded 25 to 30 dB below normal: nothing
/// looked wrong anywhere, and the only symptom was transcriptions that kept getting worse. A level
/// check next to the picker turns that into something visible within seconds.
enum QuietInput {
    /// Normal speech at arm's length from a working microphone peaks somewhere between -25 and
    /// -6 dBFS, and the faulty built-in mic peaked well under -45. Room noise alone sits below it
    /// too, which is why the verdict only lands after the user has had time to speak.
    static let thresholdDBFS: Float = -45
    /// Long enough to say a few words after opening the picker.
    static let listeningWindow: TimeInterval = 3
    /// Digital silence, so a buffer of zeros still has a finite level.
    static let silenceDBFS: Float = -120

    enum Verdict: Equatable {
        /// Nothing loud enough heard yet, but the user has not had time to speak.
        case listening
        /// Something reached a speaking level since the microphone opened.
        case normal
        /// The window passed and nothing came close to speech.
        case tooQuiet

        /// For VoiceOver, which should not hear the level change dozens of times a second.
        var isQuiet: Bool { self != .normal }
    }

    static func verdict(loudestDBFS: Float, listenedFor elapsed: TimeInterval) -> Verdict {
        if loudestDBFS >= thresholdDBFS { return .normal }
        return elapsed >= listeningWindow ? .tooQuiet : .listening
    }

    /// Sample peak of one buffer, in dBFS.
    static func peakDBFS(of samples: UnsafeBufferPointer<Float>) -> Float {
        guard let base = samples.baseAddress, !samples.isEmpty else { return silenceDBFS }
        var peak: Float = 0
        vDSP_maxmgv(base, 1, &peak, vDSP_Length(samples.count))
        return dbfs(amplitude: peak)
    }

    static func dbfs(amplitude: Float) -> Float {
        guard amplitude.isFinite, amplitude > 0 else { return silenceDBFS }
        return max(20 * log10(amplitude), silenceDBFS)
    }
}

/// The loudest moment heard since a picker started listening to one microphone.
///
/// The loudest moment rather than a rolling level: a pause between sentences says nothing about
/// the microphone, so once it has heard the user properly the warning stays away.
struct QuietInputWatch: Equatable {
    let startedAt: Date
    private(set) var loudestDBFS: Float = QuietInput.silenceDBFS

    init(startedAt: Date) {
        self.startedAt = startedAt
    }

    mutating func observe(peakDBFS: Float) {
        loudestDBFS = max(loudestDBFS, peakDBFS)
    }

    func verdict(at now: Date) -> QuietInput.Verdict {
        QuietInput.verdict(loudestDBFS: loudestDBFS, listenedFor: now.timeIntervalSince(startedAt))
    }
}
