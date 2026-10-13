import SwiftUI

/// Where to send a bug, an idea, or try what is coming. Listed once, because two places offer
/// them (Help & what's new, and the sidebar's Feedback menu) and their wording and addresses
/// must not drift apart.
struct FeedbackLink: Identifiable {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let symbol: String
    let url: URL

    var id: URL { url }

    static let repository = URL(string: "https://github.com/my-monkeys/OpenSuperWhisper")!

    static let all: [FeedbackLink] = [
        FeedbackLink(title: "Report a bug",
                     subtitle: "On GitHub. Steps to reproduce, your macOS version and engine, logs if you have them.",
                     symbol: "ladybug",
                     url: repository.appendingPathComponent("issues/new")),
        FeedbackLink(title: "Send feedback or an idea",
                     subtitle: "A quick form on opensuperwhisper.com, no account needed.",
                     symbol: "bubble.left.and.bubble.right",
                     url: URL(string: "https://opensuperwhisper.com/#feedback")!),
        FeedbackLink(title: "Try a beta build",
                     subtitle: "Early features before they ship, on GitHub Releases.",
                     symbol: "testtube.2",
                     url: repository.appendingPathComponent("releases")),
    ]
}
