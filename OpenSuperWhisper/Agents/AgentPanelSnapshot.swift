#if DEBUG
import AppKit
import SwiftUI
import OpenSuperWhisperCore

/// Made-up waiting agents for `UISnapshotProbe`, so the panel can be drawn off-screen. The
/// requests are written to the agents folder, which under the probe's test isolation is a
/// throwaway one, and their hook is the probe itself, so the inbox takes them as live.
@MainActor
enum AgentPanelSnapshot {
    static func make(draft: String? = nil, showing kind: AgentRequest.Kind = .stop, focused: Bool = false,
                     selecting: Bool = false, liveText: (confirmed: String, volatile: String)? = nil,
                     textScale: Double = TextScale.default) -> AnyView {
        AgentPanelController.shared.isSnapshotting = true
        // Set every time: the screens share one run, and a large-text screen would otherwise
        // carry its size into the ones drawn after it.
        AppPreferences.shared.textScale = textScale
        stageLiveText(liveText)
        // From the prose, through the list and the code block, into the table.
        MarkdownTextView.snapshotSelection = selecting ? ("instead of", "150 ms") : nil
        let requests = seed(stopMessage: selecting ? richMessage : stopMessage)
        AgentInbox.shared.reload()
        AgentInbox.shared.selectedID = requests.first { $0.kind == kind }?.id
        if let draft, let first = requests.first { AgentInbox.shared.drafts[first.id] = draft }
        AgentInbox.shared.stageDictation(for: liveText == nil ? nil : AgentInbox.shared.current?.id)
        return AnyView(
            ZStack(alignment: .topTrailing) {
                Color(nsColor: .underPageBackgroundColor)
                AgentPanelRoot(showsFocus: focused)
                    .fixedSize()
            }
        )
    }

    /// A reply being dictated, with live text on: Parakeet streams, and the caption is staged
    /// the way the indicator probe stages the bubble's.
    /// Put back once the live screens are drawn, so the screens after them keep the probe's engine.
    private static var engineBeforeLiveText: String?

    private static func stageLiveText(_ text: (confirmed: String, volatile: String)?) {
        let prefs = AppPreferences.shared
        prefs.liveTranscriptionEnabled = text != nil
        if text != nil {
            if engineBeforeLiveText == nil { engineBeforeLiveText = prefs.selectedEngine }
            prefs.selectedEngine = "fluidaudio"
        } else if let engine = engineBeforeLiveText {
            prefs.selectedEngine = engine
            engineBeforeLiveText = nil
        }
        StreamingTranscriptionController.shared.stageCaption(confirmed: text?.confirmed ?? "",
                                                             volatile: text?.volatile ?? "")
    }

    /// Three lines' worth at the default size, so the first one has scrolled away.
    static let liveConfirmed = "Yes, open the PR, but before that rename the setting to restore delay "
        + "and add a line about it in the release notes so people know where to find it"
    static let liveVolatile = "and then ask Beverley"

    private static let stopMessage = """
        Done. The previous clipboard now comes back after **0.5 s** instead of 1 s, and the delay is a setting.

        - `ClipboardUtil.borrowForPaste` restores after `clipboardRestoreDelayMs`
        - New slider in **Settings › Output** (150 to 2000 ms)
        - 4 new tests, all 312 passing

        Want me to open the PR?
        """

    /// Every kind of block, for the selection screen.
    private static let richMessage = """
        ## Clipboard restore

        Done. The previous clipboard now comes back after **0.5 s** instead of 1 s.

        - `ClipboardUtil.borrowForPaste` restores after `clipboardRestoreDelayMs`
        - New slider in **Settings › Output**

        ```swift
        let delay = prefs.clipboardRestoreDelayMs
        try await Task.sleep(for: .milliseconds(delay))
        ```

        | Delay | Paste OK |
        |---|---:|
        | 150 ms | 97 % |
        | 500 ms | 100 % |

        > Older builds keep the 1 s delay.

        ---

        Want me to open the PR?
        """

    private static func seed(stopMessage: String) -> [AgentRequest] {
        guard let directory = AgentBridge.requestsDirectory else { return [] }
        try? FileManager.default.removeItem(at: directory)
        let now = Date()
        let requests = [
            request(kind: .stop, title: "Faster clipboard restore", age: 40, message: stopMessage, now: now),
            {
                var permission = request(kind: .permission, title: "Release notes", age: 25,
                                         message: "Push the branch so the PR can be opened.", now: now)
                permission.tool = "Bash"
                permission.toolDetail = "git push -u origin feat/clipboard-delay"
                return permission
            }(),
            {
                var question = request(kind: .question, title: "Settings search", age: 10, message: "", now: now)
                question.questions = [AgentQuestion(
                    question: "Should the search also match **French** keywords?", header: "Search",
                    options: [.init(label: "Yes, both languages", description: "Adds the French synonyms to every row."),
                              .init(label: "English only")])]
                return question
            }(),
        ]
        for request in requests {
            try? AgentBridge.write(request, to: directory.appendingPathComponent("\(request.id).json"))
        }
        return requests
    }

    private static func request(kind: AgentRequest.Kind, title: String, age: TimeInterval,
                                message: String, now: Date) -> AgentRequest {
        let created = now.addingTimeInterval(-age)
        return AgentRequest(id: UUID().uuidString, kind: kind, agent: "Claude Code", sessionID: "snapshot",
                            title: title, cwd: "/Users/demo/code/OpenSuperWhisper", message: message,
                            createdAt: created, expiresAt: created.addingTimeInterval(600),
                            hookPID: getpid())
    }
}
#endif
