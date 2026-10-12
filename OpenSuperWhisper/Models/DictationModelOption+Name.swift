import Foundation
import OpenSuperWhisperCore

extension DictationModelOption {
    /// The name people know the model by. A Parakeet option's own display name is its version
    /// alone ("v3"), which read as a bare number on Home and in the readiness card.
    var friendlyName: String {
        switch engine {
        case "fluidaudio":
            return SettingsFluidAudioModels.availableModels.first { $0.version == identifier }?.name
                ?? "Parakeet \(identifier)"
        case "whisper":
            let file = URL(fileURLWithPath: identifier).lastPathComponent
            return SettingsDownloadableModels.availableModels.first { $0.filename == file }.map { "Whisper \($0.name)" }
                ?? displayName
        default:
            return displayName
        }
    }
}
