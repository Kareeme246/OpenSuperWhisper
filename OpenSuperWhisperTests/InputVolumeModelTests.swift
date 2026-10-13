import CoreAudio
import XCTest

@testable import OpenSuperWhisper

/// The input volume beside the pickers. Devices put it on the main element, on each channel, or
/// nowhere; whichever it is, the slider must read and write the same control as Sound settings,
/// follow changes made there, and drop its listeners with the last view showing it.
///
/// Everything here goes through a stand-in backend: no test changes a volume on this Mac.
@MainActor
final class InputVolumeModelTests: XCTestCase {

    private final class FakeBackend: InputVolumeBackend {
        struct Control {
            var volume: Float
            var settable: Bool
        }

        final class Observation: InputVolumeObservation {
            let device: AudioObjectID
            let element: AudioObjectPropertyElement
            let onChange: @MainActor () -> Void
            weak var backend: FakeBackend?

            init(device: AudioObjectID, element: AudioObjectPropertyElement,
                 onChange: @escaping @MainActor () -> Void, backend: FakeBackend) {
                self.device = device
                self.element = element
                self.onChange = onChange
                self.backend = backend
            }

            func cancel() {
                backend?.observations.removeAll { $0 === self }
            }
        }

        var uids: [String: AudioObjectID] = [:]
        var systemInput: AudioObjectID?
        var channelCounts: [AudioObjectID: Int] = [:]
        var controls: [AudioObjectID: [AudioObjectPropertyElement: Control]] = [:]
        private(set) var writes: [(device: AudioObjectID, element: AudioObjectPropertyElement, scalar: Float)] = []
        fileprivate(set) var observations: [Observation] = []
        private(set) var lookups = 0

        var watched: [AudioObjectID: [AudioObjectPropertyElement]] {
            Dictionary(grouping: observations, by: \.device).mapValues { $0.map(\.element).sorted() }
        }

        func device(forUID uid: String?) -> AudioObjectID? {
            lookups += 1
            if let uid, let device = uids[uid] { return device }
            return systemInput
        }

        func inputChannelCount(of device: AudioObjectID) -> Int { channelCounts[device] ?? 0 }

        func hasVolume(_ device: AudioObjectID, element: AudioObjectPropertyElement) -> Bool {
            controls[device]?[element] != nil
        }

        func isVolumeSettable(_ device: AudioObjectID, element: AudioObjectPropertyElement) -> Bool {
            controls[device]?[element]?.settable ?? false
        }

        func volume(_ device: AudioObjectID, element: AudioObjectPropertyElement) -> Float? {
            controls[device]?[element]?.volume
        }

        func setVolume(_ scalar: Float, _ device: AudioObjectID, element: AudioObjectPropertyElement) -> Bool {
            guard controls[device]?[element]?.settable == true else { return false }
            writes.append((device, element, scalar))
            controls[device]?[element]?.volume = scalar
            return true
        }

        func observeVolume(_ device: AudioObjectID, element: AudioObjectPropertyElement,
                           onChange: @escaping @MainActor () -> Void) -> InputVolumeObservation {
            let observation = Observation(device: device, element: element, onChange: onChange, backend: self)
            observations.append(observation)
            return observation
        }

        /// Sound settings, or another app, moving the volume.
        @MainActor
        func changeElsewhere(_ device: AudioObjectID, element: AudioObjectPropertyElement, to scalar: Float) {
            controls[device]?[element]?.volume = scalar
            for observation in observations where observation.device == device && observation.element == element {
                observation.onChange()
            }
        }
    }

    private static let main = kAudioObjectPropertyElementMain
    private static let builtIn: AudioObjectID = 71
    private static let usb: AudioObjectID = 84

    private var backend: FakeBackend!
    private var model: InputVolumeModel!

    override func setUp() {
        super.setUp()
        backend = FakeBackend()
        backend.uids = ["built-in": Self.builtIn, "usb": Self.usb]
        backend.systemInput = Self.builtIn
        // The MacBook's microphone: three channels, a settable volume on each, none on the main element.
        backend.channelCounts[Self.builtIn] = 3
        backend.controls[Self.builtIn] = [
            1: .init(volume: 0.38, settable: true),
            2: .init(volume: 0.38, settable: true),
            3: .init(volume: 0.38, settable: true),
        ]
        backend.channelCounts[Self.usb] = 1
        model = InputVolumeModel(backend: backend, writeInterval: .milliseconds(20))
    }

    private func waitForWrites() async throws {
        try await Task.sleep(for: .milliseconds(120))
    }

    // MARK: - Which control

    func testAPerChannelVolumeIsReadAsTheChannelsMean() {
        backend.controls[Self.builtIn]?[2]?.volume = 0.5
        _ = model.begin(deviceUID: "built-in")
        XCTAssertEqual(model.volume ?? -1, (0.38 + 0.5 + 0.38) / 3, accuracy: 0.0001)
        XCTAssertTrue(model.isSettable)
        XCTAssertEqual(backend.watched[Self.builtIn], [1, 2, 3])
    }

    func testAMainVolumeWinsOverTheChannels() {
        backend.controls[Self.usb] = [Self.main: .init(volume: 0.7, settable: true),
                                      1: .init(volume: 0.2, settable: true)]
        _ = model.begin(deviceUID: "usb")
        XCTAssertEqual(model.volume, 0.7)
        XCTAssertEqual(backend.watched[Self.usb], [Self.main])

        model.set(0.9)
        XCTAssertEqual(backend.writes.map(\.element), [Self.main], "the channel is left alone")
    }

    func testSettingWritesEverySettableChannel() {
        backend.controls[Self.builtIn]?[3]?.settable = false
        _ = model.begin(deviceUID: "built-in")
        model.set(0.8)
        XCTAssertEqual(backend.writes.map(\.element), [1, 2])
        XCTAssertTrue(backend.writes.allSatisfy { $0.device == Self.builtIn && $0.scalar == 0.8 })
        XCTAssertEqual(model.volume, 0.8)
    }

    func testAMicrophoneWithoutAVolumeOffersNothingToMove() {
        _ = model.begin(deviceUID: "usb")
        XCTAssertNil(model.volume)
        XCTAssertFalse(model.isSettable)
        XCTAssertTrue(backend.observations.isEmpty)

        model.set(1)
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertNil(model.volume)
    }

    func testAVolumeMacOSKeepsToItselfIsShownButNotWritten() {
        backend.controls[Self.usb] = [Self.main: .init(volume: 0.6, settable: false)]
        _ = model.begin(deviceUID: "usb")
        XCTAssertEqual(model.volume, 0.6)
        XCTAssertFalse(model.isSettable)
        model.set(1)
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testNoMicrophoneFollowsTheSystemInput() {
        _ = model.begin(deviceUID: nil)
        XCTAssertEqual(model.volume ?? -1, 0.38, accuracy: 0.0001)
        XCTAssertEqual(backend.watched.keys.sorted(), [Self.builtIn])
    }

    // MARK: - Following the device

    func testAChangeMadeInSoundSettingsMovesTheSlider() {
        _ = model.begin(deviceUID: "built-in")
        for channel: AudioObjectPropertyElement in 1...3 {
            backend.changeElsewhere(Self.builtIn, element: channel, to: 0.9)
        }
        XCTAssertEqual(model.volume ?? -1, 0.9, accuracy: 0.0001)
    }

    func testPickingAnotherMicrophoneMovesTheListeners() {
        backend.controls[Self.usb] = [Self.main: .init(volume: 0.7, settable: true)]
        let token = model.begin(deviceUID: "built-in")
        model.retarget(token, deviceUID: "usb")
        XCTAssertEqual(backend.watched, [Self.usb: [Self.main]])
        XCTAssertEqual(model.volume, 0.7)

        backend.changeElsewhere(Self.builtIn, element: 1, to: 0.1)
        XCTAssertEqual(model.volume, 0.7, "the microphone left behind no longer moves the slider")
    }

    func testTheLastViewToGoRemovesTheListeners() {
        let popover = model.begin(deviceUID: "built-in")
        let settings = model.begin(deviceUID: "built-in")
        XCTAssertEqual(backend.observations.count, 3, "one set of listeners for both views")

        model.end(popover)
        XCTAssertTrue(model.isObserving, "still shown in Settings")
        model.end(settings)
        XCTAssertFalse(model.isObserving)
        XCTAssertTrue(backend.observations.isEmpty)
    }

    func testAReleasedTokenCannotSwitchTheMicrophone() {
        let popover = model.begin(deviceUID: "built-in")
        _ = model.begin(deviceUID: "built-in")
        model.end(popover)
        model.retarget(popover, deviceUID: "usb")
        XCTAssertEqual(backend.watched.keys.sorted(), [Self.builtIn])
    }

    // MARK: - Dragging

    func testADragWritesAtOnceThenOnlyItsLastValue() async throws {
        backend.controls[Self.usb] = [Self.main: .init(volume: 0.2, settable: true)]
        _ = model.begin(deviceUID: "usb")

        model.set(0.5)
        model.set(0.6)
        model.set(0.7)
        XCTAssertEqual(backend.writes.map(\.scalar), [0.5], "the first change goes through straight away")
        XCTAssertEqual(model.volume, 0.7, "the slider follows the pointer meanwhile")

        try await waitForWrites()
        XCTAssertEqual(backend.writes.map(\.scalar), [0.5, 0.7])
        XCTAssertEqual(model.volume, 0.7)
    }

    func testOurOwnEchoesDoNotPullTheThumbBack() async throws {
        backend.controls[Self.usb] = [Self.main: .init(volume: 0.2, settable: true)]
        _ = model.begin(deviceUID: "usb")
        model.set(0.5)
        model.set(0.8)
        // The HAL notifying the first write while the pointer has already moved on.
        backend.changeElsewhere(Self.usb, element: Self.main, to: 0.5)
        XCTAssertEqual(model.volume, 0.8)

        try await waitForWrites()
        XCTAssertEqual(model.volume, 0.8, "settles on what the device holds once the drag is written")
    }

    func testAWriteScheduledForOneMicrophoneNeverLandsOnTheNext() async throws {
        backend.controls[Self.usb] = [Self.main: .init(volume: 0.2, settable: true)]
        let token = model.begin(deviceUID: "built-in")
        model.set(0.5)
        model.set(0.6)
        model.retarget(token, deviceUID: "usb")
        try await waitForWrites()
        XCTAssertFalse(backend.writes.contains { $0.device == Self.usb })
        XCTAssertEqual(model.volume, 0.2)
    }

    func testSetToMaximumTurnsItAllTheWayUp() {
        _ = model.begin(deviceUID: "built-in")
        model.setToMaximum()
        XCTAssertEqual(backend.writes.map(\.scalar), [1, 1, 1])
        XCTAssertEqual(model.volume, 1)
    }

    // MARK: - What the quiet warning offers

    func testSetToMaximumIsOfferedForALowSettableVolume() {
        XCTAssertEqual(QuietInputRemedy(verdict: .tooQuiet, volume: 0.38, isSettable: true), .setToMaximum)
        XCTAssertEqual(QuietInputRemedy(verdict: .tooQuiet, volume: 0.89, isSettable: true), .setToMaximum)
    }

    func testNothingIsOfferedWhenTheVolumeIsAlreadyHigh() {
        XCTAssertEqual(QuietInputRemedy(verdict: .tooQuiet, volume: 0.9, isSettable: true), .none)
        XCTAssertEqual(QuietInputRemedy(verdict: .tooQuiet, volume: 1, isSettable: true), .none)
    }

    func testSoundSettingsIsOfferedWhenTheAppCannotChangeIt() {
        XCTAssertEqual(QuietInputRemedy(verdict: .tooQuiet, volume: 0.2, isSettable: false), .openSoundSettings)
        XCTAssertEqual(QuietInputRemedy(verdict: .tooQuiet, volume: nil, isSettable: false), .openSoundSettings)
    }

    func testNothingIsOfferedUnlessTheLevelIsTooQuiet() {
        for verdict in [QuietInput.Verdict.listening, .normal] {
            XCTAssertEqual(QuietInputRemedy(verdict: verdict, volume: 0.1, isSettable: true), .none)
            XCTAssertEqual(QuietInputRemedy(verdict: verdict, volume: nil, isSettable: false), .none)
        }
    }

    func testTheSoundSettingsLinkOpensTheInputTab() {
        XCTAssertEqual(SoundSettings.inputURL.absoluteString,
                       "x-apple.systempreferences:com.apple.Sound-Settings.extension?input")
    }

    #if DEBUG
    func testStagedVolumesNeverTouchADevice() {
        model.stage(volume: 0.38, isSettable: true)
        let token = model.begin(deviceUID: "built-in")
        model.set(0.9)
        model.retarget(token, deviceUID: "usb")
        model.end(token)
        XCTAssertEqual(backend.lookups, 0)
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertTrue(backend.observations.isEmpty)
        XCTAssertEqual(model.volume, 0.9, "the slider still moves in the probe")
    }
    #endif
}
