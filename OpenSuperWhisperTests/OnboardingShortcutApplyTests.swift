import XCTest
import KeyboardShortcuts

@testable import OpenSuperWhisper

/// Applying a shortcut re-arms the app's key monitors on the main thread. Done on every card
/// click, it made step 1 stutter, so the choice is applied when the step is left or onboarding
/// closes, and only when it changed.
@MainActor
final class OnboardingShortcutApplyTests: XCTestCase {

    private let combo = RecordingTrigger.keyCombo(.init(.backtick, modifiers: .option))
    private let recorded = RecordingTrigger.keyCombo(.init(.d, modifiers: [.control, .option]))

    private var savedTriggers = ""
    private var savedModifier = ""
    private var posts = 0
    private var observer: NSObjectProtocol?

    override func setUp() {
        super.setUp()
        let prefs = AppPreferences.shared
        savedTriggers = prefs.recordingTriggers
        savedModifier = prefs.modifierOnlyHotkey
        prefs.recordingTriggers = RecordingTriggerSet(triggers: [combo]).json
        prefs.modifierOnlyHotkey = ModifierKey.none.rawValue
    }

    override func tearDown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        AppPreferences.shared.recordingTriggers = savedTriggers
        AppPreferences.shared.modifierOnlyHotkey = savedModifier
        super.tearDown()
    }

    /// Counts from here on: the view model's init may post once for a fresh install.
    private func makeViewModel() -> OnboardingViewModel {
        let viewModel = OnboardingViewModel(system: .staged())
        observer = NotificationCenter.default.addObserver(forName: .hotkeySettingsChanged, object: nil,
                                                          queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.posts += 1 }
        }
        return viewModel
    }

    private var triggers: [RecordingTrigger] {
        RecordingTriggerSet.load(from: AppPreferences.shared.recordingTriggers).triggers
    }

    func testPickingCardsTouchesNothing() {
        let viewModel = makeViewModel()
        viewModel.selectedShortcut = .rightOption
        viewModel.selectedShortcut = .custom
        viewModel.customTrigger = recorded
        viewModel.selectedShortcut = .keyCombination
        XCTAssertEqual(triggers, [combo])
        XCTAssertEqual(AppPreferences.shared.modifierOnlyHotkey, ModifierKey.none.rawValue)
        XCTAssertEqual(posts, 0)
    }

    func testContinueAppliesTheChoiceOnce() {
        let viewModel = makeViewModel()
        viewModel.selectedShortcut = .keyCombination
        viewModel.selectedShortcut = .rightOption
        viewModel.stepDidChange(from: .shortcut)
        XCTAssertEqual(triggers, [combo, .modifier(.rightOption)])
        XCTAssertEqual(AppPreferences.shared.modifierOnlyHotkey, ModifierKey.rightOption.rawValue)
        XCTAssertEqual(posts, 1)
    }

    /// Leaving the later steps, or coming back through step 1 unchanged, re-arms nothing.
    func testMovingOnWithoutAChangeAppliesNothingMore() {
        let viewModel = makeViewModel()
        viewModel.selectedShortcut = .rightOption
        viewModel.stepDidChange(from: .shortcut)
        viewModel.stepDidChange(from: .model)
        viewModel.stepDidChange(from: .shortcut)
        viewModel.onboardingWillClose()
        XCTAssertEqual(posts, 1)
    }

    func testTheDefaultLeftAloneIsNotRewritten() {
        let viewModel = makeViewModel()
        viewModel.stepDidChange(from: .shortcut)
        XCTAssertEqual(posts, 0)
    }

    func testBackThenAnotherCardAppliesTheNewOneOnContinue() {
        let viewModel = makeViewModel()
        viewModel.selectedShortcut = .rightOption
        viewModel.stepDidChange(from: .shortcut)
        viewModel.stepDidChange(from: .model)
        viewModel.customTrigger = recorded
        XCTAssertEqual(posts, 1, "recording on the card is still only a pick")
        viewModel.stepDidChange(from: .shortcut)
        XCTAssertEqual(triggers, [recorded])
        XCTAssertEqual(AppPreferences.shared.modifierOnlyHotkey, ModifierKey.none.rawValue)
        XCTAssertEqual(posts, 2)
    }

    /// "Finish later" on step 1, or closing the window there, keeps the card picked.
    func testClosingFromStepOneAppliesTheCardPicked() {
        let viewModel = makeViewModel()
        viewModel.selectedShortcut = .rightOption
        viewModel.onboardingWillClose()
        XCTAssertEqual(triggers, [combo, .modifier(.rightOption)])
        XCTAssertEqual(posts, 1)
    }
}
