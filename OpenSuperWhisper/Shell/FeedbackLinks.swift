import SwiftUI

/// The ways to reach us outside the app: an issue on GitHub, or a beta build. Listed once,
/// because two places offer them (Help & what's new, and the Feedback card) and their addresses
/// must not drift apart.
struct FeedbackLink: Identifiable {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let symbol: String
    let url: URL

    var id: URL { url }

    static let repository = URL(string: "https://github.com/my-monkeys/OpenSuperWhisper")!
    static let newIssue = repository.appendingPathComponent("issues/new")
    static let betaBuilds = repository.appendingPathComponent("releases")

    static let all: [FeedbackLink] = [
        FeedbackLink(title: "Open an issue on GitHub",
                     subtitle: "Steps to reproduce, your macOS version and engine, logs if you have them.",
                     symbol: "ladybug",
                     url: newIssue),
        FeedbackLink(title: "Try a beta build",
                     subtitle: "Early features before they ship, on GitHub Releases.",
                     symbol: "testtube.2",
                     url: betaBuilds),
    ]
}
