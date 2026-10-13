import Foundation

/// Whether the microphone a picker is showing hears the user well enough to transcribe them.
///
/// Prompted by a built-in MacBook microphone that recorded 25 to 30 dB below normal: nothing
/// looked wrong anywhere, and the only symptom was transcriptions that kept getting worse. A level
/// check next to the picker turns that into something visible within seconds.
enum QuietInput {
    /// The start of the bar's orange zone. Room noise alone stays under it, and the faulty
    /// built-in microphone did too while being spoken into, which is why the verdict only lands
    /// after the user has had time to speak.
    static let thresholdDBFS: Float = InputLevel.lowFloorDBFS
    /// Long enough to say a few words after opening the picker.
    static let listeningWindow: TimeInterval = 3
    /// How long the RMS level has to stay at the threshold to count as heard. A syllable lasts
    /// longer; a click, a key press or a knock on the desk is over well before.
    static let sustainWindow: TimeInterval = 0.15

    enum Verdict: Equatable {
        /// Nothing loud enough heard yet, but the user has not had time to speak.
        case listening
        /// Something held a speaking level since the microphone opened.
        case normal
        /// The window passed and nothing came close to speech.
        case tooQuiet
    }
}

/// What one microphone has been heard doing since a picker started listening to it.
///
/// Remembers that speech was heard rather than following the level: a pause between sentences
/// says nothing about the microphone, so once it has heard the user properly the warning stays
/// away. Counts audio time, not the clock, like the bar's smoothing.
struct QuietInputWatch: Equatable {
    private(set) var listened: TimeInterval = 0
    private(set) var heardSpeech = false
    private var sustained: TimeInterval = 0

    /// One buffer's RMS level, heard over `duration` seconds.
    mutating func observe(rmsDBFS: Float, duration: TimeInterval) {
        listened += duration
        guard rmsDBFS >= QuietInput.thresholdDBFS else {
            sustained = 0
            return
        }
        sustained += duration
        if sustained >= QuietInput.sustainWindow { heardSpeech = true }
    }

    var verdict: QuietInput.Verdict {
        if heardSpeech { return .normal }
        return listened >= QuietInput.listeningWindow ? .tooQuiet : .listening
    }
}
