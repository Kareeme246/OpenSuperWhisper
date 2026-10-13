import AppKit
import SwiftUI

// The live level of the microphone a picker shows, so a microphone that barely hears the user is
// obvious before a dictation rather than after a run of bad transcriptions.
//
// Opening the input lights macOS's microphone indicator, so it is only held while the picker is
// on screen and the app is frontmost.

/// A capsule that fills from the left with the input level, red when it barely moves, orange
/// when it is usable, green when it hears the user well, with a thin tick at its recent highest.
struct InputLevelBar: View {
    let reading: InputLevelReading
    var height: CGFloat = 8

    /// How far the colours blend into each other on either side of a zone's edge.
    private static let zoneBlend = 0.03
    private static let tickWidth: CGFloat = 2
    /// How far the peak tick stands out above and below the bar.
    private static let tickOverhang: CGFloat = 3
    /// One reading's time, so the bar glides between readings instead of stepping.
    private static let glide = Animation.linear(duration: InputLevelProcessor.publishInterval)

    /// The gradient spans the whole track, so a colour always sits at the same level whatever
    /// the fill: the further the bar reaches, the greener its tip.
    private static var gradient: Gradient {
        let low = InputLevel.fraction(dBFS: InputLevel.lowFloorDBFS)
        let good = InputLevel.fraction(dBFS: InputLevel.goodFloorDBFS)
        return Gradient(stops: [
            .init(color: STheme.levelQuiet, location: 0),
            .init(color: STheme.levelQuiet, location: low - zoneBlend),
            .init(color: STheme.levelLow, location: low + zoneBlend),
            .init(color: STheme.levelLow, location: good - zoneBlend),
            .init(color: STheme.levelGood, location: good + zoneBlend),
            .init(color: STheme.levelGood, location: 1),
        ])
    }

    private static func color(for zone: InputLevel.Zone) -> Color {
        switch zone {
        case .tooQuiet: return STheme.levelQuiet
        case .low: return STheme.levelLow
        case .good: return STheme.levelGood
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fill = CGFloat(InputLevel.fraction(dBFS: reading.levelDBFS))
            let peak = CGFloat(InputLevel.fraction(dBFS: reading.peakDBFS))
            ZStack(alignment: .leading) {
                Capsule().fill(STheme.fill)
                    .frame(height: height)
                LinearGradient(gradient: Self.gradient, startPoint: .leading, endPoint: .trailing)
                    .frame(width: width, height: height)
                    .frame(width: width * fill, alignment: .leading)
                    .clipShape(Capsule())
                if peak > 0 {
                    Capsule()
                        .fill(Self.color(for: InputLevel.zone(dBFS: reading.peakDBFS)))
                        .frame(width: Self.tickWidth, height: height + 2 * Self.tickOverhang)
                        .offset(x: min(max(width * peak - Self.tickWidth / 2, 0), width - Self.tickWidth))
                }
            }
            .frame(height: proxy.size.height)
            .animation(Self.glide, value: reading)
        }
        .frame(height: height + 2 * Self.tickOverhang)
    }
}

/// The bar, labelled for VoiceOver by zone so it is not read out dozens of times a second.
struct MicrophoneLevelMeter: View {
    let reading: InputLevelReading

    /// Read from the peak tick, which holds still between words where the bar drops.
    private var zoneDescription: Text {
        switch InputLevel.zone(dBFS: reading.peakDBFS) {
        case .tooQuiet: return Text("Too quiet")
        case .low: return Text("Low")
        case .good: return Text("Good")
        }
    }

    var body: some View {
        InputLevelBar(reading: reading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Input level"))
            .accessibilityValue(zoneDescription)
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

/// Top of the Home microphone popover: the level and the input volume of the microphone that is
/// checked below it.
struct MicrophoneLevelSection: View {
    let microphone: MicrophoneService.AudioDevice?
    @ObservedObject private var monitor = InputLevelMonitor.shared
    @ObservedObject private var volume = InputVolumeModel.shared

    private var remedy: QuietInputRemedy {
        QuietInputRemedy(verdict: monitor.reading.verdict, volume: volume.volume, isSettable: volume.isSettable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Input level")
                .scaledFont(size: 11, weight: .semibold)
                .foregroundColor(STheme.hint)
            MicrophoneLevelMeter(reading: monitor.reading)
            MicrophoneLevelCaption(verdict: monitor.reading.verdict)
            QuietInputRemedyLink(remedy: remedy, model: volume)
            MicrophoneVolumeSection(model: volume, remedy: remedy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .monitorsInputLevel(of: microphone)
        .followsInputVolume(of: microphone)
    }
}

/// Settings › Dictation, under the Microphone row: the level, the input volume, and the warning
/// when the level stays too quiet.
struct MicrophoneLevelRow: View {
    let microphone: MicrophoneService.AudioDevice?
    @ObservedObject private var monitor = InputLevelMonitor.shared
    @ObservedObject private var volume = InputVolumeModel.shared

    private static let barWidth: CGFloat = 200

    var body: some View {
        SettingRow("Input level", hint: "Speak to test your microphone.", indented: true) {
            MicrophoneLevelMeter(reading: monitor.reading)
                .frame(width: Self.barWidth)
        }
        .monitorsInputLevel(of: microphone)
        MicrophoneVolumeRow(model: volume)
            .followsInputVolume(of: microphone)
        if monitor.reading.verdict == .tooQuiet {
            quietWarning
        }
    }

    /// Sound settings is already one row up when the volume cannot be set here, so the warning
    /// only adds the one-click fix.
    private var quietWarning: some View {
        let remedy = QuietInputRemedy(verdict: .tooQuiet, volume: volume.volume, isSettable: volume.isSettable)
        return HStack(spacing: 16) {
            MicrophoneLevelCaption(verdict: .tooQuiet)
                .layoutPriority(1)
            Spacer(minLength: 0)
            if remedy == .setToMaximum {
                Button("Set to maximum", action: volume.setToMaximum)
                    .buttonStyle(.sSecondary)
            }
        }
        .padding(.leading, 34)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(STheme.warnBg)
        .overlay(alignment: .top) { Rectangle().fill(STheme.border).frame(height: 1) }
    }
}

extension View {
    /// Keeps the input level of `microphone` live while this view is on screen and the app is
    /// frontmost, and follows the user to another microphone.
    func monitorsInputLevel(of microphone: MicrophoneService.AudioDevice?) -> some View {
        modifier(InputLevelMonitoring(microphone: microphone))
    }
}

private struct InputLevelMonitoring: ViewModifier {
    let microphone: MicrophoneService.AudioDevice?
    @State private var token: InputLevelMonitor.Token?
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
                if let token { InputLevelMonitor.shared.retarget(token, deviceUID: microphone?.id) }
            }
    }

    private func update() {
        let wanted = isOnScreen && appIsActive && windowIsVisible
        if wanted, token == nil {
            token = InputLevelMonitor.shared.begin(deviceUID: microphone?.id)
        } else if !wanted, let held = token {
            InputLevelMonitor.shared.end(held)
            token = nil
        }
    }
}
