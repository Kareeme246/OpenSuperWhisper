import Accelerate
import Foundation

/// One linear gain for a clip recorded far too quiet, applied to the samples the engines get and
/// never to the file on disk.
///
/// Parakeet and Whisper turn speech peaking around -50 dBFS into nonsense, where Apple Speech
/// copes: that is what the MacBook's built-in mic array gave when all three of its raw channels
/// were recorded. A clip that is merely quiet, silent, or only room noise is left as it is.
enum QuietClipGain {
    /// A clip peaking at or above this is at a normal level.
    static let quietPeakDBFS: Float = -30
    /// Where a lifted clip's peak lands, with headroom so the gain can never clip.
    static let targetPeakDBFS: Float = -3
    /// The most a clip is lifted. Beyond it the noise floor comes up with the speech.
    static let maximumGainDB: Float = 36
    /// Below this peak a clip holds nothing to lift: digital silence or as good as.
    static let minimumPeakDBFS: Float = -75
    /// How far the loudest frame must stand above the clip's floor to count as signal. A take of
    /// room noise alone is flat, and lifting it 36 dB hands whisper hiss to hallucinate on.
    static let minimumDynamicRangeDB: Float = 15
    /// 20 ms at the engines' 16 kHz.
    static let frameLength = 320
    /// The frame, in loudness order, taken as the floor: the quiet between words.
    static let floorPercentile = 0.1

    static let quietPeakAmplitude = amplitude(dB: quietPeakDBFS)

    /// The samples with the gain applied, or unchanged when the clip does not need it.
    static func lifted(_ samples: [Float]) -> [Float] {
        let gain = gain(for: samples)
        guard gain > 1 else { return samples }
        return vDSP.multiply(gain, samples)
    }

    /// 1 when the clip is left alone.
    static func gain(for samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 1 }
        let peak = vDSP.maximumMagnitude(samples)
        guard peak >= amplitude(dB: minimumPeakDBFS), peak < quietPeakAmplitude,
              carriesSignal(samples) else { return 1 }
        return min(amplitude(dB: targetPeakDBFS) / peak, amplitude(dB: maximumGainDB))
    }

    private static func carriesSignal(_ samples: [Float]) -> Bool {
        let frames = frameLevels(samples).sorted()
        let floor = frames[Int(Double(frames.count - 1) * floorPercentile)]
        guard let loudest = frames.last, floor > 0 else { return true }
        return 20 * log10(loudest / floor) >= minimumDynamicRangeDB
    }

    private static func frameLevels(_ samples: [Float]) -> [Float] {
        stride(from: 0, to: samples.count, by: frameLength).map { start in
            vDSP.rootMeanSquare(samples[start..<min(start + frameLength, samples.count)])
        }
    }

    private static func amplitude(dB: Float) -> Float {
        pow(10, dB / 20)
    }
}
