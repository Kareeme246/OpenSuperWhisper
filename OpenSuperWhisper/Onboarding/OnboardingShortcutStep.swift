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
            // One choice for the three cards, so their titles stay on the same line or column.
            ViewThatFits(in: .horizontal) {
                // Fixed vertically so the three cards share the tallest one's height.
                HStack(alignment: .top, spacing: 14) {
                    cards(idealWidth: Self.cardIdealWidth * textScale, layout: .keysAbove)
                }
                .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 10) { cards(idealWidth: nil, layout: .keysBeside) }
                VStack(alignment: .leading, spacing: 10) { cards(idealWidth: nil, layout: .keysAbove) }
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

    @ViewBuilder private func cards(idealWidth: CGFloat?, layout: ShortcutCardLayout) -> some View {
        ShortcutChoiceCard(
            keys: .keys(RecordingTrigger.modifier(.rightOption).namedKeys(locale: locale)),
            title: "The right Option key",
            detail: "Simple. Needs a macOS permission.",
            selected: viewModel.selectedShortcut == .rightOption,
            layout: layout
        ) { viewModel.selectedShortcut = .rightOption }
        .frame(idealWidth: idealWidth)
        ShortcutChoiceCard(
            keys: .keys(OnboardingShortcutLabel.combinationKeys(viewModel.combination, layout: layoutInfo,
                                                                locale: locale)),
            title: "A key combination",
            detail: "No extra permission.",
            selected: viewModel.selectedShortcut == .keyCombination,
            layout: layout
        ) { viewModel.selectedShortcut = .keyCombination }
        .frame(idealWidth: idealWidth)
        customCard(layout: layout)
            .frame(idealWidth: idealWidth)
    }

    private func customCard(layout: ShortcutCardLayout) -> some View {
        let recorded = viewModel.customTrigger
        return ShortcutChoiceCard(
            keys: recorded.map { .keys($0.namedKeys(locale: locale)) } ?? .placeholder("Custom"),
            title: "Your own shortcut",
            detail: customDetail(recorded),
            selected: viewModel.selectedShortcut == .custom,
            layout: layout
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
    /// The combination the second card offers, else the default one in the user's keyboard layout.
    @MainActor static func combinationCaps(_ combination: RecordingTrigger?, layout: KeyboardLayoutInfo?,
                                           locale: Locale) -> [String] {
        if let combination { return caps(for: combination, locale: locale) }
        return defaultCombinationCaps(layout: layout)
    }

    /// ⌥ and key code 50: left of 1 on an ANSI keyboard, beside left Shift on an ISO one.
    static func defaultCombinationCaps(layout: KeyboardLayoutInfo?) -> [String] {
        ["⌥", layout?.labels[50] ?? "`"]
    }

    /// One cap per key. A modifier on its own is one cap with its side spelled out, the way
    /// Home names it, rather than the Settings field's longer "Right ⌥ Option".
    @MainActor static func caps(for trigger: RecordingTrigger, locale: Locale) -> [String] {
        if case .modifier(let key) = trigger { return [HomeTriggerSummary.label(for: key, locale: locale)] }
        return trigger.caps
    }

    /// The second card's keys, each with its name, so "⌥" reads as Option at a glance.
    @MainActor static func combinationKeys(_ combination: RecordingTrigger?, layout: KeyboardLayoutInfo?,
                                           locale: Locale) -> [NamedKey] {
        if let combination { return combination.namedKeys(locale: locale) }
        let caps = defaultCombinationCaps(layout: layout)
        return [KeyNames.modifier(symbol: caps[0], locale: locale), KeyNames.key(cap: caps[1], locale: locale)]
    }
}

/// Where a card puts its keys. Stacked cards set them beside the text, so the three stay
/// short, until the window or the text size leaves no room; then every card puts them above.
enum ShortcutCardLayout {
    case keysAbove, keysBeside
}

/// What a card shows above its title: the shortcut's keys, or a word while there is none yet.
enum ShortcutCardKeys {
    case keys([NamedKey])
    case placeholder(LocalizedStringKey)
}

private struct ShortcutChoiceCard<Accessory: View>: View {
    let keys: ShortcutCardKeys
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let selected: Bool
    var layout = ShortcutCardLayout.keysAbove
    let action: () -> Void
    @ViewBuilder var accessory: () -> Accessory
    @Environment(\.textScaleFactor) private var textScale

    /// Three hero caps and their names; a longer shortcut wraps inside it.
    private static var keysColumnWidth: CGFloat { 172 }
    private static var explanationIdealWidth: CGFloat { 180 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The card's text is the button; the accessory (the recorder) has controls of its
            // own, which a Button around it would swallow.
            Button(action: action) {
                Group {
                    switch layout {
                    case .keysBeside:
                        HStack(alignment: .top, spacing: 16) {
                            // The same column on every card, so the three titles start level.
                            keysLabel.frame(width: Self.keysColumnWidth * textScale, alignment: .leading)
                            // Judged on two lines, not on its one-line width, when the step
                            // decides whether this layout fits.
                            explanation.frame(idealWidth: Self.explanationIdealWidth * textScale,
                                              maxWidth: .infinity, alignment: .leading)
                        }
                    case .keysAbove:
                        VStack(alignment: .leading, spacing: 14) {
                            keysLabel
                            explanation
                        }
                    }
                }
                // Clear of the check mark; the keys run closer to it than the text, so three
                // caps still share a line on a card a third of the window wide.
                .padding(.trailing, 16)
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

    @ViewBuilder private var keysLabel: some View {
        switch keys {
        case .keys(let named):
            NamedKeyRow(keys: named)
        case .placeholder(let word):
            // An empty cap where the recorded keys will go, so the three titles stay level.
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "plus")
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundColor(STheme.hint)
                    .frame(width: 40 * textScale, height: 40 * textScale)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(STheme.border, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                    .padding(.bottom, 2)
                    .accessibilityHidden(true)
                Text(word)
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundColor(STheme.hint)
            }
        }
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
        .padding(.trailing, 6)
    }
}

extension ShortcutChoiceCard where Accessory == EmptyView {
    init(keys: ShortcutCardKeys, title: LocalizedStringKey, detail: LocalizedStringKey, selected: Bool,
         layout: ShortcutCardLayout, action: @escaping () -> Void) {
        self.init(keys: keys, title: title, detail: detail, selected: selected, layout: layout,
                  action: action, accessory: { EmptyView() })
    }
}

/// A shortcut drawn key by key, each cap with its name under it. Wraps to a second line rather
/// than squeezing the caps when the card is narrow or the text large; the caps of a line share
/// its top, so they stay level whatever their names' length.
private struct NamedKeyRow: View {
    let keys: [NamedKey]

    var body: some View {
        // Wide enough apart that each name reads as its own key's, not as one phrase.
        FlowLayout(spacing: 14, lineSpacing: 12) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                // Leading, like the card's text: the first cap lines up with the title.
                VStack(alignment: .leading, spacing: 6) {
                    SKeyCap(key.cap, symbol: key.symbol, style: .hero)
                    Text(verbatim: key.name)
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundColor(STheme.hint)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: keys.map(\.name).joined(separator: ", ")))
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
