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

    /// Writes the choice to the trigger list the app listens to, plus the old single-slot key
    /// that older builds and the one-time repair read. Like the editor in Settings, a key that
    /// was the stop-and-submit binding stops being one: the router checks submit first, so the
    /// chosen shortcut would otherwise never start a dictation.
    func applyShortcut() {
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
