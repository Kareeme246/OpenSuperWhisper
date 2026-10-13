import SwiftUI

/// Feedback, as a card over the main window: a bug or an idea written here and sent straight to
/// the team, an optional email for an answer, and the one line of app details the user can read
/// before it goes and switch off. GitHub and the betas stay one click away underneath.
struct FeedbackOverlay: View {
    @ObservedObject var model: FeedbackFormModel
    @ObservedObject private var navigation = AppNavigation.shared
    @Environment(\.textScaleFactor) private var textScale

    var body: some View {
        ModalCard(maxWidth: 600, maxHeight: 900, hugsContent: true, onClose: close) {
            VStack(spacing: 0) {
                header
                if model.status == .sent {
                    thanks
                } else {
                    ViewThatFits(in: .vertical) {
                        form
                        ScrollView { form }
                    }
                    footer
                }
            }
        }
    }

    private func close() {
        navigation.feedbackOpen = false
    }

    private func cancel() {
        model.discard()
        navigation.feedbackOpen = false
    }

    // MARK: - Layout

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Send feedback")
                    .scaledFont(size: 22, weight: .bold)
                    .foregroundColor(STheme.textBright)
                Text("Tell us what went wrong or what you'd like. It goes straight to the team.")
                    .scaledFont(size: 13)
                    .foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            CloseButton(action: close)
        }
        .padding(.horizontal, 26).padding(.top, 20).padding(.bottom, 16)
        .overlay(alignment: .bottom) { Rectangle().fill(STheme.border).frame(height: 1) }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            SSegmented(selection: $model.kind, options: [
                (FeedbackKind.bug, "Report a bug"),
                (FeedbackKind.idea, "Share an idea"),
            ])
            SEditor(text: $model.message, height: 104 * textScale, fontSize: 14, monospaced: false,
                    placeholder: model.kind == .bug
                        ? "What happened, and what did you expect?"
                        : "What would make OpenSuperWhisper better for you?")
                .accessibilityLabel(Text("Message"))
            VStack(alignment: .leading, spacing: 6) {
                Text("Email (optional, if you'd like an answer)")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundColor(STheme.textBright)
                // Not an address as the prompt: a localized key turns one into a blue link.
                STextField("Only used to answer you", text: $model.email, width: nil)
            }
            detailsRow
            otherWays
        }
        .padding(.horizontal, 26).padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var detailsRow: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Include app details")
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundColor(STheme.textBright)
                Text(verbatim: model.details)
                    .scaledFont(size: 12)
                    .foregroundColor(model.includeDetails ? STheme.hint : STheme.faint)
                    .strikethrough(!model.includeDetails, color: STheme.faint)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Nothing else is sent: no dictations, audio, logs or settings.")
                    .scaledFont(size: 12)
                    .foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            SSwitch(isOn: $model.includeDetails)
                .accessibilityLabel(Text("Include app details"))
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(STheme.advancedBg))
    }

    /// The ways out of the app this card replaced, for those who would rather use them.
    private var otherWays: some View {
        FlowLayout(spacing: 6) {
            Text("Prefer GitHub?")
                .scaledFont(size: 12)
                .foregroundColor(STheme.hint)
            linkButton("Open an issue", url: FeedbackLink.newIssue)
            Text(verbatim: "·")
                .scaledFont(size: 12)
                .foregroundColor(STheme.faint)
            linkButton("Try a beta build", url: FeedbackLink.betaBuilds)
        }
    }

    private func linkButton(_ title: LocalizedStringKey, url: URL) -> some View {
        Button { NSWorkspace.shared.open(url) } label: {
            Text(title)
                .scaledFont(size: 12, weight: .semibold)
                .foregroundColor(STheme.accent)
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            statusLine
                .layoutPriority(1)
            Spacer(minLength: 0)
            Button("Cancel", action: cancel)
                .buttonStyle(.sSecondary)
            Button("Send") { Task { await model.send() } }
                .buttonStyle(.sPrimary)
                .disabled(!model.canSend)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 26).padding(.vertical, 16)
        .overlay(alignment: .top) { Rectangle().fill(STheme.border).frame(height: 1) }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.status {
        case .sending:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Sending…")
                    .scaledFont(size: 13)
                    .foregroundColor(STheme.hint)
            }
        case .failed:
            Label {
                Text("Couldn't send it. Check your connection and try again.")
                    .scaledFont(size: 13, weight: .medium)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .scaledFont(size: 13)
            }
            .foregroundColor(STheme.warn)
        case .editing, .sent:
            EmptyView()
        }
    }

    private var thanks: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .scaledFont(size: 26)
                    .foregroundColor(STheme.ok)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Thanks! It reached us. 🍌")
                        .scaledFont(size: 18, weight: .bold)
                        .foregroundColor(STheme.textBright)
                    Text("We read every message. If you left an email, the answer will come there.")
                        .scaledFont(size: 13)
                        .foregroundColor(STheme.hint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26).padding(.vertical, 28)
            HStack {
                Spacer(minLength: 0)
                Button("Close", action: close)
                    .buttonStyle(.sPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 26).padding(.vertical, 16)
            .overlay(alignment: .top) { Rectangle().fill(STheme.border).frame(height: 1) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
