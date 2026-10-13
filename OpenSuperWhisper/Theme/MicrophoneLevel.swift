import AppKit
import CoreAudio
import SwiftUI

// The live level of the microphone a picker shows, so a microphone that barely hears the user is
// obvious before a dictation rather than after a run of bad transcriptions.
//
// Opening the input lights macOS's microphone indicator, so it is only held while the picker is
// on screen and the app is frontmost.

/// The bubble's spectrum, drawn larger and labelled for VoiceOver.
struct MicrophoneLevelMeter: View {
    let bands: [Float]
    let verdict: QuietInput.Verdict

    private static let meterHeight: CGFloat = 18

    var body: some View {
        InputLevelMeter(bands: bands, height: Self.meterHeight)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(STheme.fill))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(verdict == .tooQuiet ? STheme.warnBorder : Color.clear, lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Input level"))
            .accessibilityValue(verdict.isQuiet ? Text("Quiet") : Text("Normal"))
    }
}

/// What to do with the level: speak, or, when nothing came close to speech, move or switch.
struct MicrophoneLevelCaption: View {
    let verdict: QuietInput.Verdict

    var body: some View {
        Group {
            if verdict == .tooQuiet {
                Label {
                    Text("Very quiet. Move closer or pick another microphone.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundColor(STheme.warn)
            } else {
                Text("Speak to test your microphone.")
                    .foregroundColor(STheme.hint)
            }
        }
        .scaledFont(size: 12)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Top of the Home microphone popover: the level of the microphone that is checked below it.
struct MicrophoneLevelSection: View {
    let microphone: MicrophoneService.AudioDevice?
    @ObservedObject private var analyzer = SpectrumAnalyzer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Input level")
                .scaledFont(size: 11, weight: .semibold)
                .foregroundColor(STheme.hint)
            HStack(alignment: .center, spacing: 10) {
                MicrophoneLevelMeter(bands: analyzer.bands, verdict: analyzer.inputVerdict)
                MicrophoneLevelCaption(verdict: analyzer.inputVerdict)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .monitorsInputLevel(of: microphone)
    }
}

/// Settings › Dictation, under the Microphone row.
struct MicrophoneLevelRow: View {
    let microphone: MicrophoneService.AudioDevice?
    @ObservedObject private var analyzer = SpectrumAnalyzer.shared

    var body: some View {
        SettingRow("Input level", hint: "Speak to test your microphone.", indented: true) {
            MicrophoneLevelMeter(bands: analyzer.bands, verdict: analyzer.inputVerdict)
        }
        .monitorsInputLevel(of: microphone)
        if analyzer.inputVerdict == .tooQuiet {
            MicrophoneLevelCaption(verdict: .tooQuiet)
                .padding(.leading, 34)
                .padding(.trailing, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(STheme.warnBg)
                .overlay(alignment: .top) { Rectangle().fill(STheme.border).frame(height: 1) }
        }
    }
}

extension View {
    /// Keeps the spectrum analyzer listening to `microphone` while this view is on screen and the
    /// app is frontmost, and follows the user to another microphone.
    func monitorsInputLevel(of microphone: MicrophoneService.AudioDevice?) -> some View {
        modifier(InputLevelMonitoring(microphone: microphone))
    }
}

private struct InputLevelMonitoring: ViewModifier {
    let microphone: MicrophoneService.AudioDevice?
    @State private var token: SpectrumAnalyzer.MonitorToken?
    @State private var isOnScreen = false
    /// A Settings pane left open behind another app would otherwise keep the microphone (and
    /// its menu bar indicator) on with nobody looking.
    @State private var appIsActive = NSApplication.shared.isActive
    /// A minimised window fires no onDisappear, and the app often stays active.
    @State private var windowIsVisible = true

    func body(content: Content) -> some View {
        content
            .onAppear {
                isOnScreen = true
                update()
            }
            .onDisappear {
                isOnScreen = false
                update()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                appIsActive = true
                update()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                appIsActive = false
                update()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
                guard let window = note.object as? NSWindow, window === NSApp.mainWindow || window.isKeyWindow else { return }
                windowIsVisible = window.occlusionState.contains(.visible) && !window.isMiniaturized
                update()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { _ in
                windowIsVisible = false
                update()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { _ in
                windowIsVisible = true
                update()
            }
            .onChange(of: microphone?.id) { _, _ in
                if let token { SpectrumAnalyzer.shared.retarget(token, device: deviceID) }
            }
    }

    private var deviceID: AudioDeviceID? {
        microphone.flatMap { MicrophoneService.shared.getCoreAudioDeviceID(for: $0) }
    }

    private func update() {
        let wanted = isOnScreen && appIsActive && windowIsVisible
        if wanted, token == nil {
            token = SpectrumAnalyzer.shared.beginMonitoring(device: deviceID)
        } else if !wanted, let held = token {
            SpectrumAnalyzer.shared.endMonitoring(held)
            token = nil
        }
    }
}
