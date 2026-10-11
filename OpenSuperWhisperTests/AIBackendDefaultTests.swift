import XCTest

@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// Which cleanup engine `AppPreferences.aiBackend` reports (#158). Someone who never picked one
/// gets Apple Intelligence wherever it can run for their dictation language, and Ollama, the old
/// default, elsewhere; anyone who picked one keeps it. The default is resolved on read and never
/// written, so the stored key stays absent until the user chooses.
final class AIBackendDefaultTests: XCTestCase {

    private var scratch: ScratchPreferences!
    private let prefs = AppPreferences.shared
    private let defaults = DefaultsStore.current

    override func setUp() {
        super.setUp()
        scratch = ScratchPreferences()
    }

    override func tearDown() {
        scratch.restore()
        super.tearDown()
    }

    private func appleIntelligence(_ availability: AppleIntelligenceAvailability,
                                   languages: Set<String> = ["en", "fr"]) {
        AppleIntelligence.replaceModelForTesting(
            FixedOnDeviceModel(availability: availability, supportedLanguages: languages))
    }

    func testNeverChosenGetsAppleIntelligenceWhereItRuns() throws {
        appleIntelligence(.available)

        XCTAssertEqual(prefs.aiBackend, "apple")
        XCTAssertTrue(LLMPostProcessor.currentBackend() is AppleIntelligenceBackend)
        XCTAssertNil(defaults.object(forKey: "aiBackend"), "reading the default writes nothing")
    }

    func testNeverChosenKeepsOllamaWhereAppleIntelligenceCantRun() {
        for availability in [AppleIntelligenceAvailability.unsupportedMac, .turnedOff, .modelNotReady] {
            appleIntelligence(availability)
            XCTAssertEqual(prefs.aiBackend, "ollama", "\(availability)")
            XCTAssertTrue(LLMPostProcessor.currentBackend() is OllamaBackend, "\(availability)")
        }
        XCTAssertNil(defaults.object(forKey: "aiBackend"))
    }

    /// Ollama included: someone who picked the old default on purpose isn't moved off it.
    func testAnExplicitChoiceIsKept() {
        appleIntelligence(.available)
        for backend in ["builtin", "ollama", "remote"] {
            prefs.aiBackend = backend
            XCTAssertEqual(prefs.aiBackend, backend)
            XCTAssertEqual(defaults.string(forKey: "aiBackend"), backend)
        }
    }

    /// Chosen while it ran, kept once it stops: dictations then fall back to the raw text and the
    /// settings say why, rather than silently switching engines.
    func testChoosingAppleIntelligenceSticksWhenItBecomesUnavailable() {
        appleIntelligence(.available)
        prefs.aiBackend = "apple"
        appleIntelligence(.turnedOff)

        XCTAssertEqual(prefs.aiBackend, "apple")
        XCTAssertFalse(LLMPostProcessor.currentBackend().isReady)
    }

    func testTheDictationLanguageDecidesTheDefault() {
        appleIntelligence(.available, languages: ["en", "fr"])

        prefs.whisperLanguage = "cy"
        XCTAssertEqual(prefs.appleIntelligenceAvailability, .unsupportedLanguage("cy"))
        XCTAssertEqual(prefs.aiBackend, "ollama")

        prefs.translateToEnglish = true
        XCTAssertEqual(prefs.appleIntelligenceAvailability, .available, "cleanup then runs on English")
        XCTAssertEqual(prefs.aiBackend, "apple")

        prefs.translateToEnglish = false
        prefs.whisperLanguage = "auto"
        XCTAssertEqual(prefs.aiBackend, "apple", "auto-detect can't be checked before transcribing")
    }

    /// Settings shows the resolved engine without storing it: opening the pane is not a choice.
    @MainActor
    func testSettingsShowTheDefaultWithoutStoringIt() {
        appleIntelligence(.available)

        let viewModel = SettingsViewModel()

        XCTAssertEqual(viewModel.aiBackend, "apple")
        XCTAssertNil(defaults.object(forKey: "aiBackend"))
    }

    /// Switching to a language Apple Intelligence doesn't cover moves the unchosen engine along,
    /// still without storing it.
    @MainActor
    func testSettingsFollowTheLanguageForAnUnchosenEngine() {
        appleIntelligence(.available, languages: ["en", "fr"])
        let viewModel = SettingsViewModel()

        viewModel.selectedLanguage = "cy"
        XCTAssertEqual(viewModel.aiBackend, "ollama")
        viewModel.translateToEnglish = true
        XCTAssertEqual(viewModel.aiBackend, "apple")
        XCTAssertNil(defaults.object(forKey: "aiBackend"))

        viewModel.aiBackend = "remote"
        viewModel.translateToEnglish = false
        XCTAssertEqual(viewModel.aiBackend, "remote", "a choice doesn't follow the language")
        XCTAssertEqual(defaults.string(forKey: "aiBackend"), "remote")
    }
}
