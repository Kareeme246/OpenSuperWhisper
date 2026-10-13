import CoreAudio
import Foundation

/// Input volumes read and written through the HAL, as Sound settings does.
///
/// `kAudioDevicePropertyVolumeScalar` rather than the decibel property: the scalar is what Sound
/// settings' slider moves, and it maps a device's own dB range (−12…+12 dB on the built-in
/// microphone) onto 0…1 the same way on every device.
final class CoreAudioInputVolume: InputVolumeBackend {
    /// Off in the hosted tests, which render the real pickers on the machine running them.
    private let allowsWrites: Bool

    init(allowsWrites: Bool) {
        self.allowsWrites = allowsWrites
    }

    func device(forUID uid: String?) -> AudioObjectID? {
        let microphones = MicrophoneService.shared
        // An unknown UID translates without error into kAudioObjectUnknown.
        if let uid, let device = microphones.getCoreAudioDeviceID(forUID: uid), device != kAudioObjectUnknown {
            return device
        }
        guard let device = microphones.getCurrentSystemDefaultInputDevice(), device != kAudioObjectUnknown
        else { return nil }
        return device
    }

    func inputChannelCount(of device: AudioObjectID) -> Int {
        MicrophoneService.shared.getInputChannelCount(for: device)
    }

    func hasVolume(_ device: AudioObjectID, element: AudioObjectPropertyElement) -> Bool {
        var address = Self.volumeAddress(element)
        return AudioObjectHasProperty(device, &address)
    }

    func isVolumeSettable(_ device: AudioObjectID, element: AudioObjectPropertyElement) -> Bool {
        var address = Self.volumeAddress(element)
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    func volume(_ device: AudioObjectID, element: AudioObjectPropertyElement) -> Float? {
        var address = Self.volumeAddress(element)
        var scalar: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &scalar) == noErr else { return nil }
        return scalar
    }

    @discardableResult
    func setVolume(_ scalar: Float, _ device: AudioObjectID, element: AudioObjectPropertyElement) -> Bool {
        guard allowsWrites else {
            Diag.mark("input volume: write refused under test")
            return false
        }
        var address = Self.volumeAddress(element)
        var value = Float32(min(max(scalar, 0), 1))
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        if status != noErr { Diag.mark("input volume: write to element \(element) failed (\(status))") }
        return status == noErr
    }

    func observeVolume(_ device: AudioObjectID, element: AudioObjectPropertyElement,
                       onChange: @escaping @MainActor () -> Void) -> InputVolumeObservation {
        // Delivered on the main queue, so the block is already on the main actor.
        let block: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { onChange() } }
        var address = Self.volumeAddress(element)
        let status = AudioObjectAddPropertyListenerBlock(device, &address, .main, block)
        if status != noErr { Diag.mark("input volume: can't watch element \(element) (\(status))") }
        return Listener(device: device, address: address, block: block, isRegistered: status == noErr)
    }

    private static func volumeAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioDevicePropertyScopeInput,
                                   mElement: element)
    }

    /// Removal needs the very block and queue that were registered.
    private final class Listener: InputVolumeObservation {
        private let device: AudioObjectID
        private var address: AudioObjectPropertyAddress
        private let block: AudioObjectPropertyListenerBlock
        private var isRegistered: Bool

        init(device: AudioObjectID, address: AudioObjectPropertyAddress,
             block: @escaping AudioObjectPropertyListenerBlock, isRegistered: Bool) {
            self.device = device
            self.address = address
            self.block = block
            self.isRegistered = isRegistered
        }

        func cancel() {
            guard isRegistered else { return }
            isRegistered = false
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, block)
        }
    }
}
