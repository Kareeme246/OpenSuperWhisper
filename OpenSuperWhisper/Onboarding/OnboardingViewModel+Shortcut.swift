import Foundation
import OpenSuperWhisperCore

extension OnboardingViewModel {
    /// What starts a dictation once this step is left: the card's trigger, or the combination
    /// while the Custom card has nothing recorded yet.
    var effectiveTrigger: RecordingTrigger? {
        switch selectedShortcut {
        case .keyCombination: return combination
        case .rightOption: return .modifier(.rightOption)
        case .custom: return customTrigger ?? combination
        }
    }

    /// Same rule as Settings → Dictation: a lone modifier, or a chord of them, needs it.
    var needsInputMonitoring: Bool {
        effectiveTrigger?.needsInputMonitoring ?? false
    }

    /// The choice as the step shows it. What Custom recorded only counts while its card is
    /// picked, the way `applyShortcut` writes it.
    var pendingChoice: OnboardingShortcutChoice {
        OnboardingShortcutChoice(option: selectedShortcut,
                                 custom: selectedShortcut == .custom ? customTrigger : nil)
    }

    /// Called as the step changes. Step 1 can only be left forward, and every step after it
    /// (the first try above all) names and listens to what it applied.
    func stepDidChange(from previous: OnboardingStep) {
        if previous == .shortcut { applyShortcutChoice() }
    }

    /// Called when onboarding goes away, finished, put off or with its window closed, so a
    /// card picked without leaving step 1 still counts.
    func onboardingWillClose() {
        applyShortcutChoice()
    }

    /// Applies the card on screen if it differs from what the app listens to. Applying re-arms
    /// the key monitors on the main thread, so it happens once per change, never per click.
    func applyShortcutChoice() {
        let choice = pendingChoice
        guard choice != appliedChoice else { return }
        applyShortcut()
        appliedChoice = choice
    }

    /// Writes the choice to the trigger list the app listens to, plus the old single-slot key
    /// that older builds and the one-time repair read. Like the editor in Settings, a key that
    /// was the stop-and-submit binding stops being one: the router checks submit first, so the
    /// chosen shortcut would otherwise never start a dictation.
    private func applyShortcut() {
        let prefs = AppPreferences.shared
        prefs.modifierOnlyHotkey = (selectedShortcut == .rightOption ? ModifierKey.rightOption : .none).rawValue
        let custom = selectedShortcut == .custom ? customTrigger : nil
        prefs.recordingTriggers = OnboardingTriggerPlan.triggers(
            for: selectedShortcut, custom: custom,
            current: RecordingTriggerSet.load(from: prefs.recordingTriggers),
            hold: RecordingTriggerSet.load(from: prefs.holdRecordingTriggers),
            combination: combination, previousCustom: appliedCustom).json
        appliedCustom = custom
        if let effectiveTrigger { prefs.releaseSubmitBinding(claimedBy: effectiveTrigger) }
        NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
    }
}

/// A card and, for Custom, what it recorded: what onboarding compares to decide whether
/// leaving step 1 has anything to apply.
struct OnboardingShortcutChoice: Equatable {
    let option: OnboardingShortcutOption
    let custom: RecordingTrigger?
}
