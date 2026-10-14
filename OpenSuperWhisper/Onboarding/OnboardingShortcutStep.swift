import SwiftUI
import KeyboardShortcuts
import OpenSuperWhisperCore

/// Step 1: how dictation starts. The key combination stays the default because it needs no
/// permission; right ⌥ is simpler to press but macOS has to let the app watch modifier keys.
/// Custom records any key, combination or mouse button with the same recorder as Settings.
struct OnboardingShortcutStep: View {
    @ObservedObject var viewModel: OnboardingViewModel
    let layoutInfo: KeyboardLayoutInfo?
    @Environment(\.textScaleFactor) private var textScale
    @Environment(\.locale) private var locale

    /// Below this width per card, at the designed text size, the three cards stack instead.
    private static let cardIdealWidth: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ViewThatFits(in: .horizontal) {
                // Fixed vertically so the three cards share the tallest one's height.
                HStack(alignment: .top, spacing: 14) { cards(idealWidth: Self.cardIdealWidth * textScale) }
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 10) { cards(idealWidth: nil, stacked: true) }
            }

            OnboardingCallout {
                Text("Hold to talk, release to finish. A short tap works too: tap to start, tap again to stop.")
                permissionNote
            }

            if let layoutInfo, viewModel.selectedShortcut != .custom {
                // Fixed widths, so it shrinks in a narrow window instead of running past it.
                ViewThatFits(in: .horizontal) {
                    OnboardingKeyboardView(selectedShortcut: viewModel.selectedShortcut,
                                           layoutInfo: layoutInfo, width: 480)
                    OnboardingKeyboardView(selectedShortcut: viewModel.selectedShortcut,
                                           layoutInfo: layoutInfo, width: 360)
                }
            }

            Text("You can change it, or add more shortcuts, in Settings later.")
                .scaledFont(size: 13)
                .foregroundColor(STheme.hint)
        }
    }

    /// Stacked, each card sets its keys beside its text, so the three stay short.
    @ViewBuilder private func cards(idealWidth: CGFloat?, stacked: Bool = false) -> some View {
        ShortcutChoiceCard(
            keys: Text(verbatim: OnboardingShortcutLabel.rightOption(locale: locale)),
            title: "The right Option key",
            detail: "Simple. Needs a macOS permission.",
            selected: viewModel.selectedShortcut == .rightOption,
            stacked: stacked
        ) { viewModel.selectedShortcut = .rightOption }
        .frame(idealWidth: idealWidth)
        ShortcutChoiceCard(
            keys: Text(verbatim: OnboardingShortcutLabel.combination(viewModel.combination, layout: layoutInfo, locale: locale)),
            title: "A key combination",
            detail: "No extra permission.",
            selected: viewModel.selectedShortcut == .keyCombination,
            stacked: stacked
        ) { viewModel.selectedShortcut = .keyCombination }
        .frame(idealWidth: idealWidth)
        customCard(stacked: stacked)
            .frame(idealWidth: idealWidth)
    }

    private func customCard(stacked: Bool) -> some View {
        let recorded = viewModel.customTrigger
        return ShortcutChoiceCard(
            keys: recorded.map { Text(verbatim: OnboardingShortcutLabel.caps(for: $0, locale: locale).joined(separator: " ")) }
                ?? Text("Custom"),
            title: "Your own shortcut",
            detail: customDetail(recorded),
            selected: viewModel.selectedShortcut == .custom,
            stacked: stacked
        ) {
            viewModel.selectedShortcut = .custom
        } accessory: {
            TriggerRecorderField(name: .toggleRecord,
                                 mouseButton: .constant(.none),
                                 modifierKey: .constant(.none),
                                 style: .chips,
                                 capture: $viewModel.customTrigger)
                // Arming the recorder is choosing this card, before anything is pressed.
                .simultaneousGesture(TapGesture().onEnded { viewModel.selectedShortcut = .custom })
        }
    }

    private func customDetail(_ recorded: RecordingTrigger?) -> LocalizedStringKey {
        guard let recorded else { return "Any key, combination or mouse button." }
        return recorded.needsInputMonitoring ? "Needs a macOS permission." : "No extra permission."
    }

    @ViewBuilder private var permissionNote: some View {
        switch viewModel.selectedShortcut {
        case .custom where viewModel.customTrigger == nil:
            Text("Click the field on the card, then press the key or combination you want. A spare mouse button works too.")
        case _ where viewModel.needsInputMonitoring:
            Text("macOS will ask for Input Monitoring so the app can notice this key in other apps. Only modifier keys are watched, never what you type.")
        case .custom:
            Text("This shortcut needs no extra permission.")
        default:
            Text("Key combinations need no extra permission.")
        }
    }
}

/// How the shortcut choices are spelled on screen.
enum OnboardingShortcutLabel {
    /// "⌥ right", as Home writes it.
    @MainActor static func rightOption(locale: Locale) -> String {
        HomeTriggerSummary.label(for: .rightOption, locale: locale)
    }

    /// The combination the second card offers, else the default one (⌥ and the key left of 1)
    /// in the user's keyboard layout.
    @MainActor static func combination(_ combination: RecordingTrigger?, layout: KeyboardLayoutInfo?,
                                       locale: Locale) -> String {
        combinationCaps(combination, layout: layout, locale: locale).joined(separator: " ")
    }

    @MainActor static func combinationCaps(_ combination: RecordingTrigger?, layout: KeyboardLayoutInfo?,
                                           locale: Locale) -> [String] {
        if let combination { return caps(for: combination, locale: locale) }
        return ["⌥", layout?.labels[50] ?? "`"]
    }

    /// One cap per key. A modifier on its own is one cap with its side spelled out, the way
    /// Home names it, rather than the Settings field's longer "Right ⌥ Option".
    @MainActor static func caps(for trigger: RecordingTrigger, locale: Locale) -> [String] {
        if case .modifier(let key) = trigger { return [HomeTriggerSummary.label(for: key, locale: locale)] }
        return trigger.caps
    }
}

private struct ShortcutChoiceCard<Accessory: View>: View {
    let keys: Text
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let selected: Bool
    var stacked = false
    let action: () -> Void
    @ViewBuilder var accessory: () -> Accessory
    @Environment(\.textScaleFactor) private var textScale

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The card's text is the button; the accessory (the recorder) has controls of its
            // own, which a Button around it would swallow.
            Button(action: action) {
                Group {
                    if stacked {
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            keysLabel.frame(minWidth: 120 * textScale, alignment: .leading)
                            explanation
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 14) {
                            keysLabel
                            explanation
                        }
                    }
                }
                .padding(.trailing, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            accessory()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(selected ? STheme.accentTint : STheme.cardBg))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(selected ? STheme.accent : STheme.border, lineWidth: selected ? 2 : 1))
        .overlay(alignment: .topTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .scaledFont(size: 18)
                    .foregroundColor(STheme.accent)
                    .padding(16)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: action)
    }

    private var keysLabel: some View {
        keys
            .scaledFont(size: 24, weight: .bold)
            .foregroundColor(STheme.textBright)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundColor(STheme.textBright)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .scaledFont(size: 13)
                .foregroundColor(STheme.hint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension ShortcutChoiceCard where Accessory == EmptyView {
    init(keys: Text, title: LocalizedStringKey, detail: LocalizedStringKey, selected: Bool,
         stacked: Bool, action: @escaping () -> Void) {
        self.init(keys: keys, title: title, detail: detail, selected: selected, stacked: stacked,
                  action: action, accessory: { EmptyView() })
    }
}

/// A note set off by an accent bar on its left, for what a choice implies.
struct OnboardingCallout<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .scaledFont(size: 14)
            .foregroundColor(STheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16).padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(STheme.fill)
            .overlay(alignment: .leading) {
                Rectangle().fill(STheme.accent).frame(width: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
