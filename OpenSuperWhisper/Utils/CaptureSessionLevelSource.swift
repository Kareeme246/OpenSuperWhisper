import AVFoundation
import CoreMedia
import Foundation

/// Input levels read through an `AVCaptureSession` of their own.
///
/// A capture session rather than an `AVAudioEngine` tap: the engine's input node follows the
/// system input, and pointing it at another device underneath a tap left the tap's format out of
/// step with the device, so the bar stayed flat. A capture device input opens exactly the device
/// it is given, in that device's own format, and runs beside the recorder like any other app
/// using the microphone.
final class CaptureSessionLevelSource: NSObject, InputLevelSource {
    /// Configuration and start/stop, which block for a moment and must stay off the main thread.
    private let sessionQueue = DispatchQueue(label: "OpenSuperWhisper.InputLevel.session")
    /// Sample buffers, and everything they update.
    private let bufferQueue = DispatchQueue(label: "OpenSuperWhisper.InputLevel.buffers")

    /// Only touched on `sessionQueue`.
    private var session: AVCaptureSession?
    private var runtimeErrorObserver: NSObjectProtocol?
    /// Only touched on `bufferQueue`.
    private var processor = InputLevelProcessor()
    private var deliver: ((InputLevelReading) -> Void)?

    func start(deviceUID: String?, onReading: @escaping (InputLevelReading) -> Void) {
        sessionQueue.async { [self] in
            tearDown()
            guard let device = Self.device(uid: deviceUID) else {
                Diag.mark("input level: no microphone to open")
                return
            }
            guard let session = makeSession(for: device) else { return }
            bufferQueue.sync {
                processor = InputLevelProcessor()
                deliver = onReading
            }
            self.session = session
            runtimeErrorObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
            ) { note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                Diag.mark("input level: capture stopped: \(error?.localizedDescription ?? "unknown error")")
            }
            session.startRunning()
            Diag.mark("input level: listening to \(device.localizedName), running=\(session.isRunning)")
        }
    }

    func stop() {
        sessionQueue.async { [self] in tearDown() }
    }

    /// The device the next dictation records from, or the system input when it is gone.
    private static func device(uid: String?) -> AVCaptureDevice? {
        if let uid, let device = AVCaptureDevice(uniqueID: uid), device.isConnected, !device.isSuspended {
            return device
        }
        return AVCaptureDevice.default(for: .audio)
    }

    private func makeSession(for device: AVCaptureDevice) -> AVCaptureSession? {
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            guard session.canAddInput(input), session.canAddOutput(output) else {
                Diag.mark("input level: the session refused \(device.localizedName)")
                return nil
            }
            session.addInput(input)
            session.addOutput(output)
        } catch {
            Diag.mark("input level: couldn't open \(device.localizedName): \(error.localizedDescription)")
            return nil
        }
        requestFloatSamples(from: output)
        output.setSampleBufferDelegate(self, queue: bufferQueue)
        return session
    }

    /// Float samples whatever the device delivers; rate and channel count stay the device's, so
    /// nothing is resampled for a meter. A device that refuses keeps its own format, which
    /// `level(of:)` reads too.
    private func requestFloatSamples(from output: AVCaptureAudioDataOutput) {
        do {
            try ObjCExceptionError.catching {
                output.audioSettings = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: true,
                    AVLinearPCMIsBigEndianKey: false,
                ]
            }
        } catch {
            Diag.mark("input level: float samples refused, reading the device's own format: \(error)")
        }
    }

    private func tearDown() {
        guard let session else { return }
        if let runtimeErrorObserver { NotificationCenter.default.removeObserver(runtimeErrorObserver) }
        runtimeErrorObserver = nil
        session.stopRunning()
        for output in session.outputs {
            (output as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
            session.removeOutput(output)
        }
        session.inputs.forEach(session.removeInput)
        self.session = nil
        bufferQueue.sync { deliver = nil }
    }
}

extension CaptureSessionLevelSource: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let deliver, let (rms, duration) = Self.level(of: sampleBuffer) else { return }
        if let reading = processor.consume(rmsDBFS: rms, duration: duration) {
            deliver(reading)
        }
    }

    /// RMS level and duration of one buffer, or nil for a format the meter does not read.
    private static func level(of sampleBuffer: CMSampleBuffer) -> (Float, TimeInterval)? {
        guard let description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              description.mSampleRate > 0, sampleBuffer.numSamples > 0,
              let sampleFormat = SampleFormat(description)
        else { return nil }
        let duration = TimeInterval(sampleBuffer.numSamples) / description.mSampleRate
        let rms = try? sampleBuffer.withAudioBufferList { buffers, _ in
            InputLevel.rmsDBFS(ofChannels: buffers.compactMap { buffer -> [Float]? in
                guard let data = buffer.mData else { return nil }
                return sampleFormat.floats(from: data, byteCount: Int(buffer.mDataByteSize))
            })
        }
        guard let rms else { return nil }
        return (rms, duration)
    }

    /// The two linear PCM formats a microphone delivers in practice.
    private enum SampleFormat {
        case float32
        case int16

        init?(_ description: AudioStreamBasicDescription) {
            guard description.mFormatID == kAudioFormatLinearPCM,
                  description.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else { return nil }
            let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
            switch (isFloat, description.mBitsPerChannel) {
            case (true, 32): self = .float32
            case (false, 16): self = .int16
            default: return nil
            }
        }

        func floats(from data: UnsafeMutableRawPointer, byteCount: Int) -> [Float] {
            switch self {
            case .float32:
                let count = byteCount / MemoryLayout<Float>.size
                return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
            case .int16:
                let count = byteCount / MemoryLayout<Int16>.size
                let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: count)
                return samples.map { Float($0) / Float(Int16.max) }
            }
        }
    }
}
