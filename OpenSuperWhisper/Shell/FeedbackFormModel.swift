import Foundation

/// The Feedback card's draft and where its sending stands. Owned by the main window rather than
/// by the card, so a click outside the card or Esc closes it without losing what was typed.
@MainActor
final class FeedbackFormModel: ObservableObject {
    enum Status: Equatable {
        case editing, sending, sent, failed
    }

    static let minimumMessageLength = 2

    @Published var kind: FeedbackKind = .idea
    @Published var message = ""
    @Published var email = ""
    @Published var includeDetails = true
    @Published private(set) var status: Status = .editing

    private let sender: FeedbackSender
    private let appDetails: @MainActor () -> String

    /// Nonisolated so the main window can create it as the default of its own initializer.
    nonisolated init(sender: FeedbackSender = FeedbackSender(),
                     appDetails: @escaping @MainActor () -> String = FeedbackAppDetails.current) {
        self.sender = sender
        self.appDetails = appDetails
    }

    /// The exact line sent when "Include app details" is on.
    var details: String { appDetails() }

    var canSend: Bool {
        status != .sending
            && message.filter { !$0.isWhitespace }.count >= Self.minimumMessageLength
    }

    var submission: FeedbackSubmission {
        FeedbackSubmission(kind: kind, message: message, email: email,
                           details: includeDetails ? details : nil)
    }

    func send() async {
        guard canSend else { return }
        status = .sending
        do {
            try await sender.send(submission)
            clearDraft()
            status = .sent
        } catch {
            status = .failed
        }
    }

    /// The card closed: a thank-you or an error is not shown again next time. A send still in
    /// flight keeps its status, and lands on the thank-you if it gets through.
    func cardClosed() {
        if status != .sending { status = .editing }
    }

    /// Cancel: the draft is dropped, unlike a click outside the card.
    func discard() {
        clearDraft()
        cardClosed()
    }

    private func clearDraft() {
        kind = .idea
        message = ""
        email = ""
        includeDetails = true
    }

    #if DEBUG
    /// For the snapshot probe, which shows the thank-you without sending anything.
    func stageStatus(_ status: Status) { self.status = status }
    #endif
}
