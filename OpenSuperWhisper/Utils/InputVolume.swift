import AppKit
import CoreAudio
import Foundation
import OpenSuperWhisperCore

// The microphone's own input volume, next to its level, so a microphone macOS turns down can be
// turned back up where its level shows it is too quiet.
//
// Prompted by a built-in MacBook microphone sitting at 38 % in Sound settings: the level bar said
// it was too quiet, and the only fix lived three panes away in System Settings. This is the same
// setting, read and written through CoreAudio, so the two always agree.

/// Where a microphone's volume is changed when the app cannot change it.
enum SoundSettings {
    /// The Sound pane on its Input tab. `input` is one of the deep-link anchors the Sound settings
    /// extension declares (it also indexes "Sound input" for search under that name).
    static let inputURL = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input")!

    static func openInput() {
        NSWorkspace.shared.open(inputURL)
    }
}

/// A listener on one CoreAudio property, kept until it is cancelled.
protocol InputVolumeObservation {
    @MainActor func cancel()
}

/// The CoreAudio calls the volume needs. The real one talks to the HAL; tests use a stand-in, so no
/// test ever changes a volume on the machine running it.
protocol InputVolumeBackend: AnyObject {
    /// The device with this CoreAudio UID, or the system input when it is nil or not connected.
    func device(forUID uid: String?) -> AudioObjectID?
    func inputChannelCount(of device: AudioObjectID) -> Int
    func hasVolume(_ device: AudioObjectID, element: AudioObjectPropertyElement) -> Bool
    func isVolumeSettable(_ device: AudioObjectID, element: AudioObjectPropertyElement) -> Bool
    func volume(_ device: AudioObjectID, element: AudioObjectPropertyElement) -> Float?
    @discardableResult
    func setVolume(_ scalar: Float, _ device: AudioObjectID, element: AudioObjectPropertyElement) -> Bool
    /// Calls `onChange` on the main actor whenever that element's volume changes, whoever changed it.
    @MainActor
    func observeVolume(_ device: AudioObjectID, element: AudioObjectPropertyElement,
                       onChange: @escaping @MainActor () -> Void) -> InputVolumeObservation
    /// Calls `onChange` on the main actor when devices come and go, the system input changes, or
    /// `device` switches data source: any of these can leave a resolved control pointing at an
    /// object or element that is no longer the one Sound settings shows.
    @MainActor
    func observeTopology(of device: AudioObjectID?,
                         onChange: @escaping @MainActor () -> Void) -> [InputVolumeObservation]
}

/// Which of a device's elements carry its input volume.
///
/// Some devices have one volume on the main element (0); others only one per channel (1…n), the
/// MacBook's built-in microphone among them; many USB microphones have none at all. What is read
/// is also what is written and watched, so the slider never shows one control while moving another.
struct InputVolumeControl: Equatable {
    let device: AudioObjectID
    /// Read, watched and, when settable, written.
    let elements: [AudioObjectPropertyElement]
    /// False when macOS lets nobody change this volume.
    let isSettable: Bool

    /// The main element when it is there and settable, else the settable channels. A channel that
    /// cannot be written is left out of a settable control: counted in, it would hold the mean
    /// below what was just set, and the thumb would jump back after every drag. Read-only volumes
    /// are still shown, main element first.
    static func resolve(device: AudioObjectID, backend: InputVolumeBackend) -> InputVolumeControl? {
        let main = kAudioObjectPropertyElementMain
        let hasMain = backend.hasVolume(device, element: main)
        if hasMain, backend.isVolumeSettable(device, element: main) {
            return InputVolumeControl(device: device, elements: [main], isSettable: true)
        }
        let channelCount = backend.inputChannelCount(of: device)
        let channels = channelCount > 0
            ? (1...AudioObjectPropertyElement(channelCount)).filter { backend.hasVolume(device, element: $0) }
            : []
        let writable = channels.filter { backend.isVolumeSettable(device, element: $0) }
        if !writable.isEmpty {
            return InputVolumeControl(device: device, elements: writable, isSettable: true)
        }
        if hasMain {
            return InputVolumeControl(device: device, elements: [main], isSettable: false)
        }
        return channels.isEmpty ? nil : InputVolumeControl(device: device, elements: channels, isSettable: false)
    }

    /// The mean of the elements read. Channels that disagree come out in between, and moving the
    /// slider brings them all to the same value, as Sound settings does.
    func read(from backend: InputVolumeBackend) -> Float? {
        let values = elements.compactMap { backend.volume(device, element: $0) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float(values.count)
    }

    func write(_ scalar: Float, to backend: InputVolumeBackend) {
        guard isSettable else { return }
        for element in elements {
            backend.setVolume(scalar, device, element: element)
        }
    }
}

/// What the quiet warning offers besides its advice.
enum QuietInputRemedy: Equatable {
    case none
    /// The volume is settable and well below the top: one click turns it all the way up.
    case setToMaximum
    /// macOS keeps this volume to itself, or there is none to read: the user can still check it.
    case openSoundSettings

    /// Below this, the volume is low enough to be worth raising before anything else.
    static let maximumOfferBelow: Float = 0.9

    init(verdict: QuietInput.Verdict, volume: Float?, isSettable: Bool) {
        guard verdict == .tooQuiet else { self = .none; return }
        if isSettable, let volume {
            self = volume < Self.maximumOfferBelow ? .setToMaximum : .none
        } else {
            self = .openSoundSettings
        }
    }
}

/// The input volume of the microphone the pickers show, kept in step with Sound settings.
///
/// Only property reads and listeners: nothing here opens the microphone or lights its indicator.
/// Several views can show it at once, so like the level it is held by tokens, and its listeners
/// go as soon as the last view showing it does.
@MainActor
final class InputVolumeModel: ObservableObject {
    static let shared = InputVolumeModel(
        // The hosted tests render the real pickers; they may read a volume but never change one.
        backend: CoreAudioInputVolume(allowsWrites: !DefaultsStore.isRunningTests))

    /// 0…1, or nil when the device has no input volume CoreAudio can read.
    @Published private(set) var volume: Float?
    @Published private(set) var isSettable = false

    struct Token: Hashable {
        fileprivate let id = UUID()
    }

    private let backend: InputVolumeBackend
    /// How often a drag writes to the device. Each write goes through the HAL and notifies every
    /// app listening, so the slider's dozens of changes a second are coalesced.
    private let writeInterval: Duration
    private var holders = Set<UUID>()
    private var deviceUID: String?
    private(set) var control: InputVolumeControl?
    private var observations: [InputVolumeObservation] = []
    private var pendingScalar: Float?
    /// True from a write until the interval after it ends. Our own writes echo back through the
    /// listeners meanwhile, and would pull the thumb back under the user's pointer.
    private(set) var isWriting = false
    /// Bumped on every detach, so a write scheduled for one device never lands on the next.
    private var generation = 0

    #if DEBUG
    /// Set once something has been staged: the probes draw staged volumes and must never read, let
    /// alone write, a real device behind them.
    private var isStaged = false

    func stage(volume: Float?, isSettable: Bool) {
        isStaged = true
        // A drag on a real device before the probe staged anything is not the probe's to finish.
        pendingScalar = nil
        detach()
        self.volume = volume
        self.isSettable = isSettable
    }
    #endif

    init(backend: InputVolumeBackend, writeInterval: Duration = .milliseconds(50)) {
        self.backend = backend
        self.writeInterval = writeInterval
    }

    var isObserving: Bool { !observations.isEmpty }

    /// Starts following the volume of the microphone with this UID, for as long as the token is held.
    func begin(deviceUID: String?) -> Token {
        let token = Token()
        let wasIdle = holders.isEmpty
        holders.insert(token.id)
        if wasIdle || self.deviceUID != deviceUID {
            self.deviceUID = deviceUID
            attach()
        }
        return token
    }

    /// The picker's microphone changed while a view is showing it.
    func retarget(_ token: Token, deviceUID: String?) {
        guard holders.contains(token.id), self.deviceUID != deviceUID else { return }
        self.deviceUID = deviceUID
        attach()
    }

    func end(_ token: Token) {
        guard holders.remove(token.id) != nil, holders.isEmpty else { return }
        detach()
    }

    /// Moves the device's volume to `scalar` (0…1). The slider shows it at once; the device gets it
    /// at most once per write interval, and always gets the last value, even when the view goes or
    /// the microphone changes before the interval is up.
    func set(_ scalar: Float) {
        guard isSettable else { return }
        let clamped = min(max(scalar, 0), 1)
        volume = clamped
        #if DEBUG
        if isStaged { return }
        #endif
        pendingScalar = clamped
        if !isWriting { writePending() }
    }

    func setToMaximum() {
        set(1)
    }

    private func attach() {
        detach()
        #if DEBUG
        if isStaged { return }
        #endif
        let device = backend.device(forUID: deviceUID)
        // Watched even when there is no volume to show, so a microphone plugged in or switched to
        // afterwards brings the slider in.
        observations = backend.observeTopology(of: device) { [weak self] in self?.topologyChanged() }
        guard let device, let control = InputVolumeControl.resolve(device: device, backend: backend) else {
            volume = nil
            isSettable = false
            return
        }
        self.control = control
        observations += control.elements.map { element in
            backend.observeVolume(device, element: element) { [weak self] in self?.volumeChangedElsewhere() }
        }
        refresh()
    }

    /// Writes what is left of a drag to the device it was meant for, before the model lets go of it.
    private func detach() {
        if let scalar = pendingScalar, let control { control.write(scalar, to: backend) }
        observations.forEach { $0.cancel() }
        observations = []
        control = nil
        pendingScalar = nil
        isWriting = false
        generation &+= 1
    }

    /// The same UID can come back as another object (after coreaudiod restarts, or on wake), and
    /// a data source change can move the volume to other elements: resolve the control again.
    private func topologyChanged() {
        guard !holders.isEmpty else { return }
        attach()
    }

    private func volumeChangedElsewhere() {
        guard !isWriting else { return }
        refresh()
    }

    private func refresh() {
        volume = control?.read(from: backend)
        isSettable = volume != nil && control?.isSettable == true
    }

    private func writePending() {
        guard let scalar = pendingScalar, let control else {
            isWriting = false
            // What the device settled on, which may be a step of its own, and anything another
            // app changed while our writes were echoing.
            refresh()
            return
        }
        pendingScalar = nil
        isWriting = true
        control.write(scalar, to: backend)
        let generation = self.generation
        Task { @MainActor [weak self, writeInterval] in
            try? await Task.sleep(for: writeInterval)
            guard let self, self.generation == generation else { return }
            self.writePending()
        }
    }
}
