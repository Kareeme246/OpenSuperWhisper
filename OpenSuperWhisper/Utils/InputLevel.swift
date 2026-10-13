import Accelerate
import Foundation

/// The scale of the input level bar next to the microphone pickers: where a level in dBFS lands
/// on the bar, and what it says about the microphone.
///
/// The zones are set from what transcription needs rather than from what a recording meter would
/// show. Speech at a normal distance from a decent microphone measures roughly -30 to -18 dBFS
/// RMS; the faulty built-in MacBook microphone that prompted the meter sat 25 to 30 dB lower, and
/// a quiet room on its own sits below -55.
enum InputLevel {
    /// The bar is empty here and below: room noise, a muted or dead input.
    static let emptyDBFS: Float = -60
    /// The bar is full here and above. Speech rarely holds a higher RMS without clipping peaks.
    static let fullDBFS: Float = -12
    /// Below this, red: what a working microphone hears with nobody speaking into it.
    static let lowFloorDBFS: Float = -50
    /// From here up, green: speech the models transcribe as well as they can.
    static let goodFloorDBFS: Float = -35
    /// Digital silence, so a buffer of zeros still has a finite level.
    static let silenceDBFS: Float = -120

    enum Zone: Equatable {
        case tooQuiet
        case low
        case good
    }

    static func zone(dBFS: Float) -> Zone {
        if dBFS >= goodFloorDBFS { return .good }
        if dBFS >= lowFloorDBFS { return .low }
        return .tooQuiet
    }

    /// How much of the bar a level fills, 0...1, linear in decibels.
    static func fraction(dBFS: Float) -> Double {
        guard dBFS.isFinite else { return 0 }
        let position = (dBFS - emptyDBFS) / (fullDBFS - emptyDBFS)
        return Double(min(max(position, 0), 1))
    }

    /// RMS level, in dBFS, of a buffer's channels: their power averaged, so a stereo microphone
    /// with one silent side reads 3 dB down rather than as loud as its live side.
    static func rmsDBFS(ofChannels channels: [[Float]]) -> Float {
        let powers = channels.filter { !$0.isEmpty }.map { samples -> Float in
            var meanSquare: Float = 0
            vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
            return meanSquare
        }
        guard !powers.isEmpty else { return silenceDBFS }
        return dbfs(power: powers.reduce(0, +) / Float(powers.count))
    }

    static func dbfs(power: Float) -> Float {
        guard power.isFinite, power > 0 else { return silenceDBFS }
        return max(10 * log10(power), silenceDBFS)
    }
}

/// The level the bar draws, eased so it reads as a level rather than as noise: it rises almost at
/// once, falls back over about a third of a second, and keeps a tick at its recent highest.
///
/// Driven by audio time (each buffer's duration) rather than the clock, so it behaves the same
/// whatever size the buffers come in, and can be tested without waiting.
struct InputLevelSmoother: Equatable {
    /// Time for the bar to climb from empty to full.
    static let attackTime: TimeInterval = 0.05
    /// Time for the bar to fall from full to empty.
    static let releaseTime: TimeInterval = 0.3
    /// How long the peak tick stays put before it falls.
    static let peakHoldTime: TimeInterval = 0.8
    /// Time for the peak tick, once it lets go, to fall from full to empty.
    static let peakReleaseTime: TimeInterval = 0.6

    private static var range: Float { InputLevel.fullDBFS - InputLevel.emptyDBFS }

    private(set) var levelDBFS: Float = InputLevel.emptyDBFS
    private(set) var peakDBFS: Float = InputLevel.emptyDBFS
    private var peakAge: TimeInterval = 0

    /// Moves toward `rmsDBFS`, heard over `duration` seconds of audio.
    mutating func feed(rmsDBFS: Float, duration: TimeInterval) {
        // Below the bar's floor everything draws the same, and easing toward -120 would only
        // slow the fall for nothing.
        let target = max(rmsDBFS, InputLevel.emptyDBFS)
        let elapsed = Float(max(duration, 0))
        if target > levelDBFS {
            levelDBFS = min(target, levelDBFS + Self.range * elapsed / Float(Self.attackTime))
        } else {
            levelDBFS = max(target, levelDBFS - Self.range * elapsed / Float(Self.releaseTime))
        }

        if levelDBFS >= peakDBFS {
            peakDBFS = levelDBFS
            peakAge = 0
        } else {
            peakAge += duration
            if peakAge > Self.peakHoldTime {
                let falling = Float(min(peakAge - Self.peakHoldTime, duration))
                peakDBFS = max(levelDBFS, peakDBFS - Self.range * falling / Float(Self.peakReleaseTime))
            }
        }
    }
}
