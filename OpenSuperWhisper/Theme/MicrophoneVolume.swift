import SwiftUI

// The input volume beside the level: a slider when macOS lets the app change it, a way to Sound
// settings when it does not. Both pickers show the same microphone as their level bar.

/// The volume as a percentage slider, writing to the device as it moves.
struct InputVolumeSlider: View {
    @ObservedObject var model: InputVolumeModel
    /// Nil fills the popover's width; Settings keeps its rows' fixed track.
    var trackWidth: CGFloat? = 180

    private var percent: Binding<Double> {
        Binding(
            get: { Double(model.volume ?? 0) * 100 },
            set: { model.set(Float($0 / 100)) })
    }

    var body: some View {
        SSlider(value: percent, range: 0...100, step: 1,
                valueLabel: "\(Int((model.volume ?? 0) * 100 + 0.5)) %",
                trackWidth: trackWidth, accessibilityLabel: "Input volume")
    }
}

/// Opens Sound settings on its Input tab, drawn as a link.
struct SoundSettingsLink: View {
    var size: CGFloat = 12

    var body: some View {
        Button(action: SoundSettings.openInput) {
            HStack(spacing: 4) {
                Text("Open Sound settings")
                Image(systemName: "arrow.up.right")
                    .accessibilityHidden(true)
            }
            .scaledFont(size: size, weight: .semibold)
            .foregroundColor(STheme.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// What the quiet warning offers, drawn as a link under it in the popover.
struct QuietInputRemedyLink: View {
    let remedy: QuietInputRemedy
    @ObservedObject var model: InputVolumeModel

    var body: some View {
        switch remedy {
        case .none:
            EmptyView()
        case .openSoundSettings:
            SoundSettingsLink()
        case .setToMaximum:
            Button(action: model.setToMaximum) {
                Text("Set to maximum")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundColor(STheme.accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
    }
}

/// The popover's volume, under its level: the slider, or the way to Sound settings unless the
/// quiet warning above already offers it.
struct MicrophoneVolumeSection: View {
    @ObservedObject var model: InputVolumeModel
    let remedy: QuietInputRemedy

    var body: some View {
        if model.isSettable {
            VStack(alignment: .leading, spacing: 6) {
                Text("Input volume")
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundColor(STheme.hint)
                    .accessibilityHidden(true)
                InputVolumeSlider(model: model, trackWidth: nil)
                Text("The same setting as in System Settings › Sound.")
                    .scaledFont(size: 12)
                    .foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        } else if remedy != .openSoundSettings {
            SoundSettingsLink()
        }
    }
}

/// Settings › Dictation, under the Input level row.
struct MicrophoneVolumeRow: View {
    @ObservedObject var model: InputVolumeModel

    var body: some View {
        if model.isSettable {
            SettingRow("Input volume", hint: "The same setting as in System Settings › Sound.", indented: true) {
                InputVolumeSlider(model: model)
            }
        } else {
            SettingRow("Input volume",
                       hint: "macOS doesn't let apps change this microphone's volume. Check it in Sound settings.",
                       indented: true) {
                SoundSettingsLink(size: 13)
            }
        }
    }
}

extension View {
    /// Keeps the input volume of `microphone` in step with the device while this view is on
    /// screen, and follows the user to another microphone. Reading it never opens the microphone,
    /// so unlike the level it carries on while the app is in the background, where the user is
    /// likely changing it in Sound settings.
    func followsInputVolume(of microphone: MicrophoneService.AudioDevice?) -> some View {
        modifier(InputVolumeFollowing(microphone: microphone))
    }
}

private struct InputVolumeFollowing: ViewModifier {
    let microphone: MicrophoneService.AudioDevice?
    @State private var token: InputVolumeModel.Token?

    func body(content: Content) -> some View {
        content
            .onAppear {
                if token == nil { token = InputVolumeModel.shared.begin(deviceUID: microphone?.id) }
            }
            .onDisappear {
                if let token { InputVolumeModel.shared.end(token) }
                token = nil
            }
            .onChange(of: microphone?.id) { _, _ in
                if let token { InputVolumeModel.shared.retarget(token, deviceUID: microphone?.id) }
            }
    }
}
