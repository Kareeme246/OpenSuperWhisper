import Carbon
import XCTest

@testable import OpenSuperWhisper

/// Which key the synthetic ⌘V presses (#161). Layouts are read from the installed list rather
/// than selected, so the user's input source is never switched; a layout missing from this
/// machine skips its test.
final class PasteKeyCodeTests: XCTestCase {

    private let kVK_ANSI_V: CGKeyCode = 0x09
    private let kVK_ANSI_Period: CGKeyCode = 0x2F
    private let kVK_ANSI_Comma: CGKeyCode = 0x2B
    private let kVK_ANSI_C: CGKeyCode = 0x08

    private var keyboardType: UInt32 { UInt32(LMGetKbdType()) }

    private func installedLayoutData(_ id: String) throws -> CFData {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue()
                as? [TISInputSource],
              let source = sources.first
        else { throw XCTSkip("\(id) is not installed on this machine") }
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            throw XCTSkip("\(id) has no Unicode layout data")
        }
        return Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue()
    }

    private func pasteKey(_ id: String) throws -> CGKeyCode {
        KeyboardLayoutProvider.pasteKeyCode(layoutData: try installedLayoutData(id),
                                            keyboardType: keyboardType)
    }

    func testUSPastesWithTheANSIVKey() throws {
        XCTAssertEqual(try pasteKey("com.apple.keylayout.US"), kVK_ANSI_V)
    }

    /// The reported case: 0x09 is K on Dvorak, and V is where US has the period.
    func testDvorakPastesWithTheKeyThatTypesV() throws {
        XCTAssertEqual(try pasteKey("com.apple.keylayout.Dvorak"), kVK_ANSI_Period)
    }

    func testOneHandedDvorakFindsItsOwnVKey() throws {
        XCTAssertEqual(try pasteKey("com.apple.keylayout.Dvorak-Right"), kVK_ANSI_Comma)
    }

    /// Colemak leaves the Z X C V row where QWERTY has it, so it keeps the key it always had.
    func testColemakKeepsTheANSIVKey() throws {
        XCTAssertEqual(try pasteKey("com.apple.keylayout.Colemak"), kVK_ANSI_V)
    }

    func testTurkishFPastesWithTheKeyThatTypesV() throws {
        XCTAssertEqual(try pasteKey("com.apple.keylayout.Turkish"), kVK_ANSI_C)
    }

    func testAZERTYKeepsTheANSIVKey() throws {
        XCTAssertEqual(try pasteKey("com.apple.keylayout.French"), kVK_ANSI_V)
    }

    /// This layout types Dvorak but switches to QWERTY while ⌘ is held. Looking the letter up
    /// without ⌘ would find the Dvorak position and press ⌘. there.
    func testDvorakQWERTYCommandUsesTheQWERTYPositionWithCommandHeld() throws {
        let data = try installedLayoutData("com.apple.keylayout.DVORAK-QWERTYCMD")
        XCTAssertEqual(KeyboardLayoutProvider.pasteKeyCode(layoutData: data,
                                                           keyboardType: keyboardType),
                       kVK_ANSI_V)
    }

    /// Russian types Cyrillic bare and Latin with ⌘, so the shortcut still finds V in place.
    func testRussianPastesWithTheANSIVKey() throws {
        XCTAssertEqual(try pasteKey("com.apple.keylayout.Russian"), kVK_ANSI_V)
    }

    func testGreekPastesWithTheANSIVKey() throws {
        XCTAssertEqual(try pasteKey("com.apple.keylayout.Greek"), kVK_ANSI_V)
    }

    /// Turkmen has no key that types a plain "v", not even with ⌘. Pasting must not give up.
    func testALayoutWithoutVFallsBackToTheANSIKey() throws {
        let data = try installedLayoutData("com.apple.keylayout.Turkmen")
        XCTAssertNil(KeyboardLayoutProvider.commandKeyCode(producing: "v", layoutData: data,
                                                           keyboardType: keyboardType))
        XCTAssertEqual(KeyboardLayoutProvider.pasteKeyCode(layoutData: data,
                                                           keyboardType: keyboardType),
                       kVK_ANSI_V)
    }

    /// Layouts without Unicode layout data (old resource-based ones) still paste.
    func testMissingLayoutDataFallsBackToTheANSIKey() {
        XCTAssertEqual(KeyboardLayoutProvider.pasteKeyCode(layoutData: nil,
                                                           keyboardType: keyboardType),
                       kVK_ANSI_V)
    }

    /// Read-only: whatever the current layout is, the cached answer is the direct one.
    func testTheCurrentLayoutResolvesToTheSameKeyAsTheDirectLookup() {
        let direct = KeyboardLayoutProvider.pasteKeyCode(
            layoutData: KeyboardLayoutProvider.currentLayoutData(), keyboardType: keyboardType)
        XCTAssertEqual(KeyboardLayoutProvider.shared.pasteKeyCode(), direct)
    }

    // MARK: - Cache

    func testTheKeyIsResolvedOnceUntilTheInputSourceChanges() {
        var resolutions = 0
        let cache = PasteKeyCodeCache(changeNotification: uniqueNotification()) {
            resolutions += 1
            return 0x09
        }

        _ = cache.keyCode
        _ = cache.keyCode

        XCTAssertEqual(resolutions, 1)
    }

    func testAnInputSourceChangeResolvesTheKeyAgain() {
        let name = uniqueNotification()
        var current: CGKeyCode = 0x09
        let cache = PasteKeyCodeCache(changeNotification: name) { current }
        XCTAssertEqual(cache.keyCode, 0x09)

        current = 0x2F
        XCTAssertEqual(cache.keyCode, 0x09, "nothing changed yet, so the cached key stands")

        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: nil, deliverImmediately: true)
        let refreshed = expectation(for: NSPredicate { _, _ in cache.keyCode == 0x2F },
                                    evaluatedWith: nil)
        wait(for: [refreshed], timeout: 5)
    }

    /// A name no other process listens for, so the test never pokes a real observer.
    private func uniqueNotification() -> Notification.Name {
        Notification.Name("com.opensuperwhisper.tests.input-source-changed.\(UUID().uuidString)")
    }
}
