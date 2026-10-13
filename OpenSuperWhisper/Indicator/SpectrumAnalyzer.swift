import Accelerate
import AVFoundation
import Combine
import CoreAudio
import Foundation
import OpenSuperWhisperCore

/// Live spectrum of the microphone, driving the indicator's visualiser and the input level shown
/// next to the microphone pickers.
///
/// Runs its own `AVAudioEngine` tap alongside `AVAudioRecorder`, the same arrangement the
/// Parakeet live transcription already uses: reading the mic in two places is fine, and it
/// keeps analysis away from the file the recorder is writing.
@MainActor
final class SpectrumAnalyzer: ObservableObject {
    static let shared = SpectrumAnalyzer()

    /// Per-band levels, 0...1, oldest-to-highest frequency. All zeros while stopped.
    @Published private(set) var bands: [Float] = Array(repeating: 0, count: SpectrumBands.count)
    /// How well the device an open picker shows hears the user. Only meaningful while monitoring.
    @Published private(set) var inputVerdict: QuietInput.Verdict = .listening

    /// One open picker's hold on the tap. Releasing it releases that picker only.
    struct MonitorToken: Hashable {
        fileprivate let id = UUID()
    }

    #if DEBUG
    /// Set once something has been staged: the probes draw staged levels and must never open the
    /// microphone behind them.
    private var isStaged = false

    /// Stages levels without a microphone, for the probes' screenshots and GIFs.
    func stageBands(_ levels: [Float], verdict: QuietInput.Verdict = .listening) {
        isStaged = true
        bands = levels
        inputVerdict = verdict
    }
    #endif

    private var claims = SpectrumClaims()
    /// A fresh engine per start, so pinning it to a device never leaks into the next one.
    private var engine: AVAudioEngine?
    private var engineDevice: AudioDeviceID?
    private var configurationObserver: NSObjectProtocol?
    /// Bumped on every stop, so buffers still in flight from a torn-down tap are dropped instead
    /// of repainting the meter after it was cleared.
    private var generation = 0
    private var quietWatch = QuietInputWatch(startedAt: Date())

    private let fftSize = 1024
    private let log2n: vDSP_Length
    private var fftSetup: FFTSetup?
    private var window: [Float]
    /// Ring of the newest samples, so a short tap buffer still produces a full transform.
    private var sampleBuffer: [Float] = []

    private init() {
        log2n = vDSP_Length(log2(Float(fftSize)))
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    /// Whether a second microphone tap is worth opening at all.
    ///
    /// It only feeds the visualiser, so with no visualiser on the bubble it is a second claim on
    /// the input device for nothing. That claim is not free: it lands immediately after
    /// `AVAudioRecorder.record()` has taken the device, which is exactly when a route or format
    /// reconfiguration is in flight (#107 follow-up).
    nonisolated static func shouldRun(layout: IndicatorLayout) -> Bool {
        layout.contains(.waveform)
    }

    // MARK: - Claims

    /// The recorder's claim, for the length of one take.
    func beginTake() {
        guard Self.shouldRun(layout: IndicatorLayout.load(from: AppPreferences.shared.indicatorLayout))
        else { return }
        claims.beginTake()
        reconcile()
    }

    func endTake() {
        claims.endTake()
        reconcile()
    }

    /// Starts showing the level of `device`, for as long as the returned token is held.
    func beginMonitoring(device: AudioDeviceID?) -> MonitorToken {
        let token = MonitorToken()
        claims.beginMonitoring(token.id, device: device)
        restartQuietWatch()
        reconcile()
        return token
    }

    /// The user picked another microphone while the picker is open.
    func retarget(_ token: MonitorToken, device: AudioDeviceID?) {
        guard claims.monitors.contains(token.id), claims.monitorDevice != device else { return }
        claims.retarget(token.id, device: device)
        restartQuietWatch()
        reconcile()
    }

    func endMonitoring(_ token: MonitorToken) {
        claims.endMonitoring(token.id)
        reconcile()
    }

    private func restartQuietWatch() {
        quietWatch = QuietInputWatch(startedAt: Date())
        inputVerdict = .listening
    }

    private func reconcile() {
        switch claims.action(running: engine != nil, runningDevice: engineDevice) {
        case .none:
            break
        case .start(let device):
            startEngine(device: device)
        case .restart(let device):
            stopEngine()
            startEngine(device: device)
        case .stop:
            stopEngine()
        }
    }

    // MARK: - Engine

    /// A picker on its own never asks for microphone access: that prompt belongs to onboarding
    /// and to the first dictation, not to opening a menu.
    private var mayOpenInput: Bool {
        #if DEBUG
        if isStaged { return false }
        #endif
        // Under test the hosted app renders the real pickers; they must not open a real microphone.
        if DefaultsStore.isRunningTests { return false }
        return claims.take || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private func startEngine(device: AudioDeviceID?) {
        guard engine == nil, fftSetup != nil, mayOpenInput else { return }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let device, !Self.pin(input, to: device) {
            Diag.mark("spectrum: couldn't pin the input to device \(device); following the system input")
        }
        let generation = self.generation

        // `format: nil` rather than a format read a moment ago, and this is the fix rather than a
        // tidy-up. This runs right after `AVAudioRecorder.record()` grabs the device, so the
        // device is often mid-reconfiguration: a format snapshotted here is stale by the time the
        // engine starts, and AVAudioEngine then refuses the tap with a format mismatch. Reported
        // on 0.12.3 as "Failed to create tap due to format mismatch" for 1ch/48kHz/Float32,
        // followed by CoreAudio failing to start the input at all, over and over. Passing nil
        // makes the engine use the bus's own format at the moment the tap is created, so there is
        // no snapshot left to go stale.
        //
        // `format: nil` narrows the window but does not close it: a device caught mid-change can
        // still make `installTap` raise, and an NSException here is far worse than no visualiser
        // (see `OSWCatchException`). So it is caught and the bubble simply stays flat.
        do {
            try ObjCExceptionError.catching {
                input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
                    guard let self, let channel = buffer.floatChannelData?[0] else { return }
                    let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
                    let incoming = Array(samples)
                    let peak = QuietInput.peakDBFS(of: samples)
                    // The buffer knows its own sample rate; nothing read up front can be trusted to
                    // still describe it. Sent along so the band edges are derived from the audio that
                    // arrived.
                    let sampleRate = Float(buffer.format.sampleRate)
                    Task { @MainActor in
                        guard self.generation == generation else { return }
                        self.consume(incoming, sampleRate: sampleRate, peakDBFS: peak)
                    }
                }
            }
        } catch {
            Diag.mark("spectrum.installTap raised \(error.localizedDescription); visualiser off for now")
            return
        }

        do {
            try ObjCExceptionError.catching { engine.prepare() }
            // A device pinned after the input node exists can still disagree on format at start,
            // which AVAudioEngine reports as an Objective-C exception rather than a Swift error.
            var startError: Error?
            try ObjCExceptionError.catching {
                do { try engine.start() } catch { startError = error }
            }
            if let startError { throw startError }
        } catch {
            input.removeTap(onBus: 0)
            print("SpectrumAnalyzer: couldn't start the audio engine: \(error)")
            return
        }
        self.engine = engine
        engineDevice = device
        restartQuietWatch()
        observeConfigurationChanges(of: engine)
    }

    private func stopEngine() {
        guard let engine else { return }
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        engineDevice = nil
        generation &+= 1
        sampleBuffer.removeAll(keepingCapacity: true)
        cachedRanges = nil
        bands = Array(repeating: 0, count: SpectrumBands.count)
        inputVerdict = .listening
    }

    /// A device unplugged or reconfigured underneath stops the engine on its own. A picker reopens
    /// it on whatever is there now; a take is left flat until it ends, for the reason `action`
    /// gives.
    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.engine === engine else { return }
                Diag.mark("spectrum: input reconfigured underneath the tap")
                self.stopEngine()
                if !self.claims.take { self.reconcile() }
            }
        }
    }

    /// Points the engine's input at one device instead of the system input. Done before the engine
    /// starts: the picker shows the microphone the next dictation will record, even when it is not
    /// (yet) the one macOS uses by default.
    private static func pin(_ input: AVAudioInputNode, to device: AudioDeviceID) -> Bool {
        guard let unit = input.audioUnit else { return false }
        var deviceID = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &deviceID,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        return status == noErr
    }

    /// Band edges for one sample rate, kept so they are not recomputed for every buffer. Keyed by
    /// the rate rather than computed once at start, because the device can change rate underneath
    /// a running tap.
    private var cachedRanges: (sampleRate: Float, ranges: [Range<Int>])?

    private func binRanges(for sampleRate: Float) -> [Range<Int>] {
        if let cachedRanges, cachedRanges.sampleRate == sampleRate { return cachedRanges.ranges }
        let ranges = SpectrumBands.binRanges(sampleRate: sampleRate, fftSize: fftSize)
        cachedRanges = (sampleRate, ranges)
        return ranges
    }

    private func consume(_ samples: [Float], sampleRate: Float, peakDBFS: Float) {
        if claims.isMonitoring {
            quietWatch.observe(peakDBFS: peakDBFS)
            let verdict = quietWatch.verdict(at: Date())
            if verdict != inputVerdict { inputVerdict = verdict }
        }
        guard sampleRate > 0 else { return }
        let ranges = binRanges(for: sampleRate)
        sampleBuffer.append(contentsOf: samples)
        guard sampleBuffer.count >= fftSize else { return }
        // Keep only the newest window; older audio has already been drawn.
        sampleBuffer.removeFirst(sampleBuffer.count - fftSize)

        let magnitudes = transform(sampleBuffer)
        guard !magnitudes.isEmpty else { return }

        bands = ranges.enumerated().map { index, range in
            let slice = magnitudes[range.clamped(to: 0..<magnitudes.count)]
            guard !slice.isEmpty else { return 0 }
            let peak = slice.max() ?? 0
            let target = SpectrumBands.normalize(magnitude: peak)
            let previous = index < bands.count ? bands[index] : 0
            return SpectrumBands.smooth(previous: previous, next: target)
        }
    }

    /// Windowed real FFT of one frame, returning bin magnitudes.
    private func transform(_ frame: [Float]) -> [Float] {
        guard let fftSetup, frame.count == fftSize else { return [] }
        let half = fftSize / 2

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { realPtr in
            imaginary.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { windowPtr in
                    windowPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        // vDSP's real FFT returns twice the true amplitude, and the window removed energy.
        var scale = Float(1) / Float(fftSize)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(half))
        return magnitudes
    }
}
