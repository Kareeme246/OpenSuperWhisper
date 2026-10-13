import CoreAudio
import XCTest

@testable import OpenSuperWhisper

/// The microphone pickers and the dictation bubble share one spectrum tap. Each must only ever
/// release its own hold on it: a picker closing mid-dictation would otherwise flatten the bubble,
/// and a dictation ending would freeze the picker. And the microphone must close as soon as the
/// last of them lets go, because it lights macOS's indicator for as long as it is open.
final class SpectrumClaimsTests: XCTestCase {

    private let builtIn: AudioDeviceID = 81
    private let usb: AudioDeviceID = 94

    func testNothingClaimedNeverOpensTheMicrophone() {
        let claims = SpectrumClaims()
        XCTAssertFalse(claims.wantsEngine)
        XCTAssertEqual(claims.action(running: false, runningDevice: nil), .none)
    }

    func testAPickerOpensTheDeviceItShows() {
        var claims = SpectrumClaims()
        claims.beginMonitoring(UUID(), device: usb)
        XCTAssertEqual(claims.action(running: false, runningDevice: nil), .start(device: usb))
    }

    func testClosingThePickerClosesTheMicrophone() {
        var claims = SpectrumClaims()
        let picker = UUID()
        claims.beginMonitoring(picker, device: usb)
        claims.endMonitoring(picker)
        XCTAssertFalse(claims.wantsEngine)
        XCTAssertEqual(claims.action(running: true, runningDevice: usb), .stop)
    }

    func testATakeOnItsOwnFollowsTheSystemInputAsBefore() {
        var claims = SpectrumClaims()
        claims.beginTake()
        XCTAssertEqual(claims.action(running: false, runningDevice: nil), .start(device: nil))
        claims.endTake()
        XCTAssertEqual(claims.action(running: true, runningDevice: nil), .stop)
    }

    func testClosingThePickerDuringATakeKeepsTheBubbleMeter() {
        var claims = SpectrumClaims()
        let picker = UUID()
        claims.beginMonitoring(picker, device: builtIn)
        claims.beginTake()
        claims.endMonitoring(picker)
        XCTAssertTrue(claims.wantsEngine)
        XCTAssertEqual(claims.action(running: true, runningDevice: builtIn), .none)
    }

    func testTheTakeEndingKeepsAnOpenPickerLive() {
        var claims = SpectrumClaims()
        claims.beginMonitoring(UUID(), device: builtIn)
        claims.beginTake()
        claims.endTake()
        XCTAssertEqual(claims.action(running: true, runningDevice: builtIn), .none)
    }

    func testOnePickerClosingLeavesTheOtherListening() {
        var claims = SpectrumClaims()
        let home = UUID()
        let settings = UUID()
        claims.beginMonitoring(home, device: builtIn)
        claims.beginMonitoring(settings, device: builtIn)
        claims.endMonitoring(home)
        XCTAssertEqual(claims.action(running: true, runningDevice: builtIn), .none)
        claims.endMonitoring(settings)
        XCTAssertEqual(claims.action(running: true, runningDevice: builtIn), .stop)
    }

    func testReleasingTwiceOrReleasingAStrangerChangesNothing() {
        var claims = SpectrumClaims()
        let picker = UUID()
        claims.beginMonitoring(picker, device: builtIn)
        claims.endMonitoring(UUID())
        XCTAssertTrue(claims.isMonitoring)

        claims.beginTake()
        claims.endMonitoring(picker)
        claims.endMonitoring(picker)
        XCTAssertTrue(claims.wantsEngine, "the take's hold survives a picker releasing twice")
    }

    func testPickingAnotherMicrophoneReopensOnIt() {
        var claims = SpectrumClaims()
        let picker = UUID()
        claims.beginMonitoring(picker, device: builtIn)
        claims.retarget(picker, device: usb)
        XCTAssertEqual(claims.action(running: true, runningDevice: builtIn), .restart(device: usb))
    }

    func testPickingAnotherMicrophoneMidTakeWaitsForTheTakeToEnd() {
        var claims = SpectrumClaims()
        let picker = UUID()
        claims.beginMonitoring(picker, device: builtIn)
        claims.beginTake()
        claims.retarget(picker, device: usb)
        XCTAssertEqual(claims.action(running: true, runningDevice: builtIn), .none)
        claims.endTake()
        XCTAssertEqual(claims.action(running: true, runningDevice: builtIn), .restart(device: usb))
    }

    func testAPickerOpenedDuringATakeTakesOverOnceItEnds() {
        var claims = SpectrumClaims()
        claims.beginTake()
        claims.beginMonitoring(UUID(), device: usb)
        XCTAssertEqual(claims.action(running: true, runningDevice: nil), .none)
        claims.endTake()
        XCTAssertEqual(claims.action(running: true, runningDevice: nil), .restart(device: usb))
    }

    func testAReleasedPickerCannotMoveTheDevice() {
        var claims = SpectrumClaims()
        let open = UUID()
        let closed = UUID()
        claims.beginMonitoring(closed, device: builtIn)
        claims.endMonitoring(closed)
        claims.beginMonitoring(open, device: builtIn)
        claims.retarget(closed, device: usb)
        XCTAssertEqual(claims.monitorDevice, builtIn)
    }
}
