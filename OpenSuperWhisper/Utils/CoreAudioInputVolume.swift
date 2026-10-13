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

    @MainActor
    func observeVolume(_ device: AudioObjectID, element: AudioObjectPropertyElement,
                       onChange: @escaping @MainActor () -> Void) -> InputVolumeObservation {
        Listener(device, Self.volumeAddress(element), onChange: onChange)
    }

    @MainActor
    func observeTopology(of device: AudioObjectID?,
                         onChange: @escaping @MainActor () -> Void) -> [InputVolumeObservation] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var listeners = [
            Listener(system, Self.address(kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal),
                     onChange: onChange),
            Listener(system, Self.address(kAudioHardwarePropertyDefaultInputDevice, scope: kAudioObjectPropertyScopeGlobal),
                     onChange: onChange),
        ]
        // The built-in microphone switching source keeps its ID but may change its volume elements.
        var dataSource = Self.address(kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeInput)
        if let device, AudioObjectHasProperty(device, &dataSource) {
            listeners.append(Listener(device, dataSource, onChange: onChange))
        }
        return listeners
    }

    private static func volumeAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioDevicePropertyScopeInput,
                                   mElement: element)
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// One HAL listener, removed on cancel.
    ///
    /// Registered through the function-pointer API, not `AudioObjectAddPropertyListenerBlock`:
    /// Swift wraps a listener block in a new Objective-C block each time it is passed to C, so
    /// the remove call never matches the block that was added. It still returns noErr, and the
    /// listener keeps firing for the rest of the process.
    ///
    /// The HAL is handed a number rather than a pointer to the listener, and the callback is
    /// looked up by that number on the main actor, so a notification that races the removal
    /// finds nothing instead of a freed object.
    @MainActor
    private final class Listener: InputVolumeObservation {
        private static var callbacks: [UInt: @MainActor () -> Void] = [:]
        private static var lastID: UInt = 0

        private static let proc: AudioObjectPropertyListenerProc = { _, _, _, context in
            let id = UInt(bitPattern: context)
            // Called on a HAL thread.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Listener.callbacks[id]?() }
            }
            return noErr
        }

        private let object: AudioObjectID
        private var address: AudioObjectPropertyAddress
        private let id: UInt
        private var isRegistered: Bool

        init(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, onChange: @escaping @MainActor () -> Void) {
            Self.lastID &+= 1
            self.object = object
            self.address = address
            self.id = Self.lastID
            Self.callbacks[id] = onChange
            let status = AudioObjectAddPropertyListener(object, &self.address, Self.proc, Self.context(id))
            if status != noErr { Diag.mark("input volume: can't watch '\(address.mSelector)' on \(object) (\(status))") }
            isRegistered = status == noErr
            if !isRegistered { Self.callbacks[id] = nil }
        }

        func cancel() {
            guard isRegistered else { return }
            isRegistered = false
            Self.callbacks[id] = nil
            AudioObjectRemovePropertyListener(object, &address, Self.proc, Self.context(id))
        }

        private static func context(_ id: UInt) -> UnsafeMutableRawPointer? {
            UnsafeMutableRawPointer(bitPattern: id)
        }
    }
}
