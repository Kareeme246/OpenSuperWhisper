import XCTest
import KeyboardShortcuts

@testable import OpenSuperWhisper

/// The calls onboarding makes for the user before they touch anything: which model is
/// preselected, which spoken language the picker starts on, what each shortcut card writes.
@MainActor
final class OnboardingDefaultsTests: XCTestCase {

    // MARK: Default model

    private let apple = OnboardingUnifiedModel(name: "Apple Speech", isDownloaded: false, description: "",
                                               type: .appleSpeech)
    private let ultra = OnboardingUnifiedModel(name: "Parakeet Ultra", isDownloaded: false, description: "",
                                               type: .parakeet(version: "ultra"))
    private let whisper = OnboardingUnifiedModel(name: "Whisper", isDownloaded: false, description: "",
                                                 type: .whisper(url: URL(string: "https://example.invalid/m.bin")!,
                                                                size: 1624))

    func testAppleSpeechIsPickedWhenItsLanguageIsInstalled() {
        let pick = OnboardingModelDefault.pick(from: [apple, ultra, whisper], language: "fr",
                                               appleSpeech: .installed)
        XCTAssertEqual(pick?.id, apple.id)
    }

    /// Nothing for the app to download either way: macOS fetches the language itself.
    func testAppleSpeechIsPickedWhenMacOSStillHasToFetchTheLanguage() {
        let pick = OnboardingModelDefault.pick(from: [apple, ultra, whisper], language: "fr",
                                               appleSpeech: .systemDownload)
        XCTAssertEqual(pick?.id, apple.id)
    }

    func testWithoutAppleSpeechUltraIsPickedAsBefore() {
        let pick = OnboardingModelDefault.pick(from: [ultra, whisper], language: "fr", appleSpeech: .unavailable)
        XCTAssertEqual(pick?.id, ultra.id)
    }

    func testWithoutAppleSpeechWhisperCoversWhatUltraDoesNotSpeak() {
        let pick = OnboardingModelDefault.pick(from: [ultra, whisper], language: "ko", appleSpeech: .unavailable)
        XCTAssertEqual(pick?.id, whisper.id)
    }

    /// A reinstall keeps the model it already downloaded, even over Apple's.
    func testADownloadedModelWinsOverAppleSpeech() {
        var downloaded = whisper
        downloaded.isDownloaded = true
        let pick = OnboardingModelDefault.pick(from: [apple, ultra, downloaded], language: "fr",
                                               appleSpeech: .installed)
        XCTAssertEqual(pick?.id, downloaded.id)
    }

    // MARK: The model step, staged

    func testTheStepPreselectsAppleSpeechAndLetsTheUserContinue() async {
        let viewModel = OnboardingViewModel(system: .staged(appleSpeech: .systemDownload, appLanguage: "fr"))
        await viewModel.refreshAppleSpeech()
        XCTAssertEqual(viewModel.unifiedModels.first?.isAppleSpeech, true, "Apple's row comes first")
        XCTAssertEqual(viewModel.selectedModelId, viewModel.appleSpeechRow?.id)
        XCTAssertTrue(viewModel.canContinue, "nothing for the app to download")
        XCTAssertEqual(AppPreferences.shared.selectedEngine, "apple")
        XCTAssertEqual(viewModel.recommendedModel?.name, "Parakeet Ultra", "Ultra stays recommended")
    }

    func testTheStepKeepsADownloadedModelOnAReinstall() async {
        let system = OnboardingSystem.staged(downloaded: { type in
            if case .parakeet("ultra") = type { return true }
            return false
        }, appleSpeech: .installed, appLanguage: "fr")
        let viewModel = OnboardingViewModel(system: system)
        await viewModel.refreshAppleSpeech()
        XCTAssertEqual(viewModel.selectedModelId, viewModel.recommendedModel?.id)
        XCTAssertEqual(AppPreferences.shared.fluidAudioModelVersion, "ultra")
    }

    func testWithoutAppleSpeechTheStepIsUnchanged() async {
        let viewModel = OnboardingViewModel(system: .staged(appleSpeech: .unavailable, appLanguage: "fr"))
        await viewModel.refreshAppleSpeech()
        XCTAssertNil(viewModel.appleSpeechRow)
        XCTAssertEqual(viewModel.selectedModelId, viewModel.recommendedModel?.id)
        XCTAssertFalse(viewModel.canContinue, "Ultra still has to be downloaded")
    }

    /// Picking a model by hand stops the default from following the language picker.
    func testAChoiceSurvivesALanguageChange() async {
        let viewModel = OnboardingViewModel(system: .staged(appleSpeech: .installed, appLanguage: "fr"))
        await viewModel.refreshAppleSpeech()
        viewModel.selectRemote()
        viewModel.selectedLanguage = "de"
        await viewModel.refreshAppleSpeech()
        XCTAssertTrue(viewModel.remoteSelected)
    }

    // MARK: Spoken language

    private let available = ["auto", "de", "en", "fr", "ja", "pt"]

    func testTheAppsLanguageComesFirst() {
        XCTAssertEqual(OnboardingLanguageDefault.pick(appLanguage: "fr", preferredLanguages: ["en-US"],
                                                      available: available), "fr")
    }

    func testTheSystemsLanguageWhenTheAppsIsNotTranscribed() {
        XCTAssertEqual(OnboardingLanguageDefault.pick(appLanguage: "tlh", preferredLanguages: ["de-CH", "fr"],
                                                      available: available), "de")
    }

    func testRegionalAndScriptVariantsMapToTheirLanguage() {
        XCTAssertEqual(OnboardingLanguageDefault.pick(appLanguage: "pt-BR", preferredLanguages: [],
                                                      available: available), "pt")
    }

    func testEnglishWhenNothingMatches() {
        XCTAssertEqual(OnboardingLanguageDefault.pick(appLanguage: nil, preferredLanguages: ["tlh"],
                                                      available: available), "en")
    }

    // MARK: Shortcut cards

    private let combo = RecordingTrigger.keyCombo(.init(.backtick, modifiers: .option))
    private let custom = RecordingTrigger.keyCombo(.init(.d, modifiers: [.control, .option]))

    private func plan(_ choice: OnboardingShortcutOption, custom: RecordingTrigger? = nil,
                      from current: [RecordingTrigger], hold: [RecordingTrigger] = [],
                      previousCustom: RecordingTrigger? = nil) -> [RecordingTrigger] {
        OnboardingTriggerPlan.triggers(for: choice, custom: custom,
                                       current: RecordingTriggerSet(triggers: current),
                                       hold: RecordingTriggerSet(triggers: hold),
                                       combination: combo, previousCustom: previousCustom).triggers
    }

    func testRightOptionJoinsTheCombination() {
        XCTAssertEqual(plan(.rightOption, from: [combo]), [combo, .modifier(.rightOption)])
    }

    func testARecordedTriggerReplacesTheCombination() {
        XCTAssertEqual(plan(.custom, custom: custom, from: [combo, .modifier(.rightOption)]), [custom])
    }

    func testCustomWithNothingRecordedKeepsTheCombination() {
        XCTAssertEqual(plan(.custom, from: [combo]), [combo])
    }

    func testGoingBackToTheCombinationUndoesTheRecordedOne() {
        XCTAssertEqual(plan(.keyCombination, from: [custom], previousCustom: custom), [combo])
    }

    func testRecordingTheCombinationItselfKeepsIt() {
        XCTAssertEqual(plan(.custom, custom: combo, from: [combo]), [combo])
        XCTAssertEqual(plan(.rightOption, from: [combo], previousCustom: combo), [combo, .modifier(.rightOption)])
    }

    /// The two lists never share a key.
    func testAKeyAlreadyHeldStaysInTheHoldList() {
        XCTAssertEqual(plan(.custom, custom: .modifier(.rightCommand), from: [combo],
                            hold: [.modifier(.rightCommand)]), [combo])
    }

    func testOnlyLoneModifiersAndChordsNeedInputMonitoring() {
        XCTAssertTrue(RecordingTrigger.modifier(.rightCommand).needsInputMonitoring)
        XCTAssertTrue(RecordingTrigger.chord(ModifierChord([.command, .option])!).needsInputMonitoring)
        XCTAssertFalse(custom.needsInputMonitoring)
        XCTAssertFalse(RecordingTrigger.mouse(.button4).needsInputMonitoring)
    }
}
