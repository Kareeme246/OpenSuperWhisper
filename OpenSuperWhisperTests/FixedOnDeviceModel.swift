import Foundation

@testable import OpenSuperWhisperCore

/// Apple's on-device model pinned to one availability, for tests whose outcome would otherwise
/// depend on whether the Mac running them has Apple Intelligence. Never asked to generate.
struct FixedOnDeviceModel: OnDeviceLanguageModel {
    let availability: AppleIntelligenceAvailability
    var supportedLanguages: Set<String> = ["en", "fr"]
    var contextSize: Int { 4096 }

    func supportsLanguage(_ code: String) -> Bool { supportedLanguages.contains(code) }
    func tokenCount(of text: String) async -> Int { text.count }

    func respond(instructions: String, prompt: String) async throws -> String {
        throw URLError(.unsupportedURL)
    }
}
