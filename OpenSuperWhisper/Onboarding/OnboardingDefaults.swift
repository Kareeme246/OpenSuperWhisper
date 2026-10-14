import Foundation
import OpenSuperWhisperCore

// The calls onboarding makes on its own, kept pure so their order of precedence is pinned by
// tests rather than by whatever this Mac happens to have installed.

/// What Apple's built-in speech model offers for the spoken language on this Mac.
enum AppleSpeechOffer: Equatable {
    /// Older macOS or SDK, or a language the system model does not speak.
    case unavailable
    /// The language's assets are already on this Mac.
    case installed
    /// The language is supported but its assets are not here yet. macOS fetches them itself,
    /// the first time the language is used; the app downloads nothing.
    case systemDownload
}

/// The model the model step preselects.
enum OnboardingModelDefault {
    /// A model the app already has comes first: a reinstall keeps the one it downloaded before.
    /// Then Apple's, whenever the system offers it, since there is nothing for the app to
    /// download. Then the first model that speaks the language, Parakeet Ultra wherever it can.
    static func pick(from models: [OnboardingUnifiedModel], language: String,
                     appleSpeech: AppleSpeechOffer) -> OnboardingUnifiedModel? {
        if let downloaded = models.first(where: { $0.isDownloaded && !$0.isAppleSpeech }) {
            return downloaded
        }
        if appleSpeech != .unavailable, let apple = models.first(where: \.isAppleSpeech) {
            return apple
        }
        return models.first { OnboardingViewModel.isDefaultCandidate($0, language: language) }
    }
}

/// The spoken language the model step starts on.
enum OnboardingLanguageDefault {
    /// The user's first preferred language, then the language the app is shown in, the first
    /// of them the engines can transcribe. English otherwise, as before.
    ///
    /// The app's language counts only when the user asked for it. On a Mac in Japanese the app,
    /// which has no Japanese translation, falls back to English: taking that as the user's
    /// language would dictate Japanese as English. A per-app language choice needs no special
    /// case, since macOS already puts it first in `preferredLanguages` inside the process.
    static func pick(appLanguage: String?, preferredLanguages: [String], available: [String]) -> String {
        let requested = Set(preferredLanguages.map(code))
        let appCandidate = appLanguage.flatMap { requested.contains(code($0)) ? $0 : nil }
        let candidates = Array(preferredLanguages.prefix(1)) + [appCandidate].compactMap { $0 }
        for identifier in candidates {
            let languageCode = code(identifier)
            if languageCode != "auto", available.contains(languageCode) { return languageCode }
        }
        return "en"
    }

    private static func code(_ identifier: String) -> String {
        Locale.Language(identifier: identifier).languageCode?.identifier
            ?? String(identifier.prefix(2)).lowercased()
    }
}

/// What each shortcut card does to the regular trigger list.
enum OnboardingTriggerPlan {
    /// Starts by undoing what an earlier card added (Right ⌥, a recorded trigger) and putting
    /// the card's combination back, so moving between cards never piles triggers up. Right ⌥
    /// then joins the combination, as it always did. A recorded trigger replaces it: Home and
    /// the first-try step name the first trigger, and should name the one the user chose.
    ///
    /// A key already in the hold-only list stays there: the two lists never share a key.
    static func triggers(for choice: OnboardingShortcutOption, custom: RecordingTrigger?,
                         current: RecordingTriggerSet, hold: RecordingTriggerSet,
                         combination: RecordingTrigger?,
                         previousCustom: RecordingTrigger?) -> RecordingTriggerSet {
        var set = current
        set.remove(.modifier(.rightOption))
        if let previousCustom, previousCustom != combination { set.remove(previousCustom) }
        if let combination, !set.triggers.contains(combination) {
            set.triggers.insert(combination, at: 0)
        }
        switch choice {
        case .keyCombination:
            break
        case .rightOption:
            if !hold.triggers.contains(.modifier(.rightOption)) { set.add(.modifier(.rightOption)) }
        case .custom:
            // Held already, it works from there; the combination stays so the list isn't empty.
            guard let custom, !hold.triggers.contains(custom) else { break }
            if let combination, combination != custom { set.remove(combination) }
            set.add(custom)
        }
        return set
    }
}
