import Foundation

/// What a message from the Feedback card is about.
enum FeedbackKind: String, CaseIterable {
    case bug, idea
}

/// One message from the Feedback card, as the user left it.
struct FeedbackSubmission: Equatable {
    var kind: FeedbackKind
    var message: String
    var email: String
    /// The app details line, or nil when the user switched it off.
    var details: String?

    /// Sent as the API's free-text `context`, the one field it keeps besides the message and
    /// the email: where the message came from, what it is about, and the details if allowed.
    var context: String {
        (["app", kind.rawValue] + [details].compactMap { $0 }).joined(separator: " · ")
    }
}

/// Posts a feedback message to the same endpoint as the form on opensuperwhisper.com. The API is
/// public and takes no credentials. The transport is injectable so tests never reach it: every
/// request lands in the owner's inbox.
struct FeedbackSender {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    static let endpoint = URL(string: "https://git.my-monkey.fr/api/feedback")!
    static let product = "opensuperwhisper"
    static let timeout: TimeInterval = 15

    var transport: Transport = { try await URLSession.shared.data(for: $0) }

    func send(_ submission: FeedbackSubmission) async throws {
        let (_, response) = try await transport(try Self.request(for: submission))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    static func request(for submission: FeedbackSubmission) throws -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let email = submission.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        request.httpBody = try encoder.encode(Body(
            message: submission.message.trimmingCharacters(in: .whitespacesAndNewlines),
            email: email.isEmpty ? nil : email,
            product: product,
            context: submission.context))
        return request
    }

    /// The website's shape. `email` is left out rather than sent empty, as the site does.
    private struct Body: Encodable {
        let message: String
        let email: String?
        let product: String
        let context: String
    }
}

/// The one line of context the Feedback card offers to send, shown to the user word for word:
/// "OpenSuperWhisper 0.14.0 (63) · macOS 26.2 · Apple Silicon · Parakeet Ultra".
enum FeedbackAppDetails {
    static func line(version: String, build: String, os: OperatingSystemVersion,
                     appleSilicon: Bool, model: String?) -> String {
        let osVersion = os.patchVersion == 0
            ? "\(os.majorVersion).\(os.minorVersion)"
            : "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return [
            "OpenSuperWhisper \(version) (\(build))",
            "macOS \(osVersion)",
            appleSilicon ? "Apple Silicon" : "Intel",
            model,
        ].compactMap { $0 }.joined(separator: " · ")
    }

    @MainActor
    static func current() -> String {
        let info = Bundle.main.infoDictionary
        #if arch(arm64)
        let appleSilicon = true
        #else
        let appleSilicon = false
        #endif
        return line(version: info?["CFBundleShortVersionString"] as? String ?? "0.0.0",
                    build: info?["CFBundleVersion"] as? String ?? "0",
                    os: ProcessInfo.processInfo.operatingSystemVersion,
                    appleSilicon: appleSilicon,
                    model: ModelSelectionStore.shared.active?.friendlyName)
    }
}
