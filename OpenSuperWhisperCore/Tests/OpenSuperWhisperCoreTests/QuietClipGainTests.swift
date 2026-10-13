import AVFoundation
import XCTest
@testable import OpenSuperWhisperCore

/// The lift a clip recorded far too quiet gets before any engine hears it. Recording the
/// MacBook's built-in mic array on all three channels gave speech peaking around -50 dBFS, which
/// Parakeet and Whisper turned into nonsense.
final class QuietClipGainTests: CoreTestCase {
    private static let rate = 16000
    private var tempFiles: [URL] = []

    override func tearDown() {
        tempFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        tempFiles = []
        super.tearDown()
    }

    // MARK: - Through the converter every engine reads with

    /// A take shaped like the built-in mic's: three channels peaking at -50 dBFS, a mean near
    /// -64 dB. It needs more than the cap, so it gets the cap: +36 dB.
    func testBuiltInMicTakeOnThreeChannelsIsLiftedByTheFullGain() async throws {
        let url = try writeWav(channels: 3, Self.speechLike(peakDBFS: -50))
        let samples = try await converted(url)

        XCTAssertEqual(Self.peakDBFS(samples), -50 + QuietClipGain.maximumGainDB, accuracy: 0.5)
    }

    func testThreeChannelClipWithinReachLandsAtTheTargetPeak() async throws {
        let url = try writeWav(channels: 3, Self.speechLike(peakDBFS: -36))
        let samples = try await converted(url)

        XCTAssertEqual(Self.peakDBFS(samples), QuietClipGain.targetPeakDBFS, accuracy: 0.5)
        XCTAssertLessThan(Self.peak(samples), 1)
    }

    func testQuietMonoFileIsLifted() async throws {
        let url = try writeWav(channels: 1, Self.speechLike(peakDBFS: -36))
        XCTAssertTrue(try AudioPCMConverter.staysBelowNormalLevel(url))

        let samples = try await converted(url)

        XCTAssertEqual(Self.peakDBFS(samples), QuietClipGain.targetPeakDBFS, accuracy: 0.5)
    }

    func testNormalMonoFileIsNotScannedPastItsFirstLoudSample() throws {
        let url = try writeWav(channels: 1, Self.speechLike(peakDBFS: -12))
        XCTAssertFalse(try AudioPCMConverter.staysBelowNormalLevel(url))
    }

    func testDigitallySilentThreeChannelFileStaysSilent() async throws {
        let url = try writeWav(channels: 3, [Float](repeating: 0, count: Self.rate))
        let samples = try await converted(url)

        XCTAssertEqual(Self.peak(samples), 0)
    }

    /// Only the samples handed to the engines change: the take kept in history is the take.
    func testTheFileOnDiskKeepsItsLevel() async throws {
        let url = try writeWav(channels: 3, Self.speechLike(peakDBFS: -50))
        _ = try await converted(url)

        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let firstChannel = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0],
                                                     count: Int(buffer.frameLength)))
        XCTAssertEqual(Self.peakDBFS(firstChannel), -50, accuracy: 0.1)
    }

    // MARK: - The decision

    func testNormalClipIsUnchanged() {
        let clip = Self.speechLike(peakDBFS: -12)
        XCTAssertEqual(QuietClipGain.lifted(clip), clip)
    }

    func testLoudClipIsUnchanged() {
        let clip = Self.speechLike(peakDBFS: -0.5)
        XCTAssertEqual(QuietClipGain.lifted(clip), clip)
    }

    /// Just under the threshold is lifted; just over it is not.
    func testThresholdSitsAtMinus30() {
        XCTAssertGreaterThan(QuietClipGain.gain(for: Self.speechLike(peakDBFS: -30.5)), 1)
        XCTAssertEqual(QuietClipGain.gain(for: Self.speechLike(peakDBFS: -29.5)), 1)
    }

    func testDigitalSilenceIsUnchanged() {
        let silence = [Float](repeating: 0, count: Self.rate)
        XCTAssertEqual(QuietClipGain.lifted(silence), silence)
    }

    /// A take where nothing was said, barely above digital silence: lifting it would only
    /// make noise for the engine to transcribe.
    func testNearSilentClipIsUnchanged() {
        let clip = Self.speechLike(peakDBFS: -80)
        XCTAssertEqual(QuietClipGain.lifted(clip), clip)
    }

    /// Room noise alone, quiet but flat: no frame stands out from the floor.
    func testSteadyNoiseIsUnchanged() {
        let noise = Self.noise(count: Self.rate * 2, peakDBFS: -50)
        XCTAssertEqual(QuietClipGain.gain(for: noise), 1)
    }

    func testEmptyClipIsUnchanged() {
        XCTAssertEqual(QuietClipGain.lifted([]), [])
    }

    // MARK: - Helpers

    private func converted(_ url: URL) async throws -> [Float] {
        let samples = try await AudioPCMConverter.convertAudioToPCM(fileURL: url)
        return try XCTUnwrap(samples)
    }

    /// Three syllables of a 220 Hz tone under a Hann envelope, separated by pauses holding a
    /// floor 45 dB down, the shape of a short dictation. The tone's crests reach `peakDBFS`.
    private static func speechLike(peakDBFS: Float) -> [Float] {
        let peak = pow(10, peakDBFS / 20)
        let syllable = rate * 120 / 1000
        let pause = rate * 300 / 1000
        var samples = noise(count: pause, peakDBFS: peakDBFS - 45)
        for _ in 0..<3 {
            samples += (0..<syllable).map { index in
                let envelope = 0.5 - 0.5 * cos(2 * Float.pi * Float(index) / Float(syllable - 1))
                return peak * envelope * sin(2 * Float.pi * 220 * Float(index) / Float(rate))
            }
            samples += noise(count: pause, peakDBFS: peakDBFS - 45)
        }
        return samples
    }

    /// Deterministic white noise, so a failure reproduces.
    private static func noise(count: Int, peakDBFS: Float) -> [Float] {
        let peak = pow(10, peakDBFS / 20)
        var state: UInt32 = 0x2545_F491
        return (0..<count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return peak * (Float(state >> 8) / Float(1 << 23) - 1)
        }
    }

    private static func peak(_ samples: [Float]) -> Float {
        samples.map(abs).max() ?? 0
    }

    private static func peakDBFS(_ samples: [Float]) -> Float {
        20 * log10(peak(samples))
    }

    /// A 16 kHz Float32 WAV, the recorder's format, with `samples` on every channel.
    private func writeWav(channels: Int, _ samples: [Float]) throws -> URL {
        let layout = try XCTUnwrap(AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.rate),
                                   interleaved: false, channelLayout: layout)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format,
                                                    frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channel in 0..<channels {
            samples.withUnsafeBufferPointer {
                buffer.floatChannelData![channel].update(from: $0.baseAddress!, count: samples.count)
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quiet-\(channels)ch-\(UUID().uuidString).wav")
        tempFiles.append(url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
