import CoreAudio
import Foundation

/// Who needs the spectrum analyzer's microphone tap right now, and what its engine should do
/// about it.
///
/// Two kinds of client share one tap: the dictation in progress, whose bubble draws the spectrum,
/// and any open microphone picker showing the input level. Each releases only its own claim, so
/// a picker closing can never take the meter away from a dictation, and a dictation ending can
/// never leave a picker frozen. Pure, so those rules are pinned by tests rather than by a live
/// microphone.
struct SpectrumClaims: Equatable {
    /// A dictation is running and its bubble shows the spectrum.
    private(set) var take = false
    private(set) var monitors: Set<UUID> = []
    /// The device the pickers show, which is the one the next dictation will record from. Nil
    /// means it could not be resolved, and the engine follows the system input.
    private(set) var monitorDevice: AudioDeviceID?

    var wantsEngine: Bool { take || isMonitoring }
    var isMonitoring: Bool { !monitors.isEmpty }

    mutating func beginTake() { take = true }
    mutating func endTake() { take = false }

    mutating func beginMonitoring(_ id: UUID, device: AudioDeviceID?) {
        monitors.insert(id)
        monitorDevice = device
    }

    /// A released or unknown monitor cannot move the device under the ones still open.
    mutating func retarget(_ id: UUID, device: AudioDeviceID?) {
        guard monitors.contains(id) else { return }
        monitorDevice = device
    }

    mutating func endMonitoring(_ id: UUID) {
        monitors.remove(id)
    }

    enum Action: Equatable {
        case none
        case start(device: AudioDeviceID?)
        case restart(device: AudioDeviceID?)
        case stop
    }

    /// What the engine should do, given whether it runs and which device it was opened on.
    func action(running: Bool, runningDevice: AudioDeviceID?) -> Action {
        guard wantsEngine else { return running ? .stop : .none }
        // A take on its own follows the system input, which the recorder has just pointed at the
        // device it records: the arrangement that has always fed the bubble.
        let device = isMonitoring ? monitorDevice : nil
        guard running else { return .start(device: device) }
        // Never reopened mid-dictation to change device: a fresh claim on the input while the
        // recorder holds it is the one the recorder can least afford (#107 follow-up). The pickers
        // catch up once the take ends.
        if !take, isMonitoring, runningDevice != monitorDevice { return .restart(device: device) }
        return .none
    }
}
