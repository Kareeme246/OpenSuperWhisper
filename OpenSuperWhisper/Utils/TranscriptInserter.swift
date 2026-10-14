import AppKit
import CoreGraphics
import Foundation
import KeyboardShortcuts

/// The single place that decides *how* a finished transcription reaches the focused app:
/// clipboard stash, paste-vs-type, and the no-editable-target fallback.
///
/// Shared by the automatic insertion at the end of a dictation (`DictationPipeline`) and by any
/// explicit, user-triggered insertion, so the two can't drift apart.
enum TranscriptInserter {

    /// Inserts `text` into the focused app.
    ///
    /// - Parameters:
    ///   - text: Post-processed transcription, ready to insert.
    ///   - honorAutoPastePreference: `true` for automatic insertion after a dictation, where the
    ///     "Auto-paste transcription" preference decides whether anything is inserted at all.
    ///     `false` when the user explicitly asked for this insertion — the request itself is the
    ///     intent, so a clipboard-only workflow still gets text where the cursor is.
    ///   - targetBundleID: the app being dictated into, for the per-app insertion rules. Passed by
    ///     the pipeline from the snapshot taken at record start rather than read here: transcription
    ///     runs in the background, so by the time this executes the frontmost app may be a different
    ///     one, and the rule has to be the one for the app the text is going to.
    /// - Returns: `true` when insertion was skipped because no editable field was focused, so the
    ///   caller can leave the text on the clipboard and notify ⌘V.
    @MainActor
    @discardableResult
    static func insert(_ text: String, honorAutoPastePreference: Bool,
                       targetBundleID: String? = nil) -> Bool {
        let prefs = AppPreferences.shared
        let rule = AppInsertionRule.rule(for: targetBundleID, in: prefs.appInsertionRules)
        noteNewerTranscription()

        let inserting = prefs.autoPasteTranscription || !honorAutoPastePreference
        // A rule for this app wins over the global switch, which is the whole point of having one.
        let pasting = inserting && (rule.map { $0.mode == .paste } ?? prefs.pasteInsteadOfTyping)

        // Optional, independent clipboard stash. A paste leaves the text there itself once the
        // app has taken it; stashing first as well would hand clipboard histories a second copy.
        if prefs.autoCopyToClipboard && !pasting {
            ClipboardUtil.copyToClipboard(text)
        }

        guard inserting else { return false }

        // Logged from here rather than from inside `TextInserter`, because this is where the
        // decision is made: which rule matched, which app it was resolved from, and which of the
        // two mechanisms ran. Logging it one layer down could only report the app in front right
        // now, which is not the one the rule came from once transcription has run in between.
        func log(mechanism: String, chunks: Int, pause: useconds_t,
                 pasteKeyCode: CGKeyCode? = nil) {
            TextInserter.logInsertion(payload: text, mechanism: mechanism,
                                      dictatedInto: targetBundleID, rule: rule,
                                      chunks: chunks, pause: pause, pasteKeyCode: pasteKeyCode)
        }

        if pasting {
            // Paste is universal: ⌘V lands in any text field, including apps the accessibility check
            // can't read (Messages, Electron), and is a harmless no-op otherwise. So no editable-
            // target gate — it only ever produces false negatives (#paste-messages). A ⌘V that
            // nothing takes is caught afterwards instead, when nobody reads the text (#162).
            // One event, so there is nothing to pace and nothing to chunk. Logged all the same:
            // a report has to be able to say which mechanism ran, and a paste that logged
            // nothing looked exactly like an insertion that never happened.
            log(mechanism: "paste", chunks: 1, pause: 0,
                pasteKeyCode: KeyboardLayoutProvider.shared.pasteKeyCode())
            pasteThroughClipboard(text, keepOnClipboard: prefs.autoCopyToClipboard)
            return false
        }

        // Typing mode: synthetic keystrokes go wherever focus is, so only type when we're confident
        // there's an editable target; otherwise stash on the clipboard and notify ⌘V.
        let targetMissing = prefs.notifyWhenNoPasteTarget
            && Diag.measure("focusedElementIsEditable") { FocusUtils.focusedElementIsEditable() } == false
        if targetMissing {
            if !prefs.autoCopyToClipboard {
                ClipboardUtil.copyToClipboard(text)
            }
            return true
        }
        let pace = rule?.typingPaceMilliseconds
        let chunkCount = TextInserter.chunks(of: text).count
        let requested = pace.map(TextInserter.microseconds(fromMilliseconds:))
            ?? TextInserter.chunkPauseMicroseconds
        log(mechanism: "type", chunks: chunkCount,
            pause: TextInserter.chunkPause(forChunkCount: chunkCount, requested: requested))

        Diag.measure("TextInserter.type") {
            TextInserter.type(text, paceMilliseconds: pace)
        }
        return false
    }

    // MARK: - Paste that didn't land (#162)

    /// The last transcription whose paste nobody took, held in memory so the paste-last shortcut
    /// reaches it even with history off. Cleared by the next transcription to go anywhere, which
    /// is newer.
    @MainActor private(set) static var unlandedPaste: String?
    @MainActor private static var insertionCount = 0

    /// A newer transcription has gone somewhere: into the focused app, or back to an agent that
    /// asked for it. From now on that one is "the last dictation", not an older missed paste.
    @MainActor
    static func noteNewerTranscription() {
        insertionCount += 1
        unlandedPaste = nil
    }

    /// Pastes through the clipboard and watches whether the app in front took the text.
    @MainActor
    private static func pasteThroughClipboard(_ text: String, keepOnClipboard: Bool) {
        pasteThroughClipboard(text, keepOnClipboard: keepOnClipboard,
                              retryShortcut: KeyboardShortcuts.getShortcut(for: .pasteLastTranscription)?.description,
                              warnWhenMissed: AppPreferences.shared.notifyWhenNoPasteTarget,
                              paste: { Diag.measure("TextInserter.paste") { TextInserter.paste() } })
    }

    /// The paste itself, with everything it reads from the system passed in so tests can run it
    /// on a private pasteboard without posting a keystroke.
    ///
    /// - Parameters:
    ///   - retryShortcut: the paste-last shortcut, `nil` when none is bound.
    ///   - warnWhenMissed: "Warn when no field is focused". Read once, here, so the clipboard
    ///     decision and the notice can't disagree if the setting changes during the paste.
    @MainActor
    static func pasteThroughClipboard(_ text: String, keepOnClipboard: Bool,
                                      retryShortcut: String?, warnWhenMissed: Bool,
                                      on pasteboard: NSPasteboard = .general,
                                      timing: ClipboardUtil.PasteTiming = .current,
                                      paste: () -> Void) {
        let afterMissing = afterMissedPaste(keepOnClipboard: keepOnClipboard,
                                            pasteLastBound: retryShortcut != nil,
                                            warnWhenMissed: warnWhenMissed)
        let insertion = insertionCount
        let retryKeys = afterMissing == .previousContents ? retryShortcut ?? "⌘V" : "⌘V"
        // With "Copy to clipboard" off the clipboard is only the paste vehicle (#44): the
        // previous contents come back once the paste is done.
        ClipboardUtil.borrowForPaste(text, on: pasteboard,
                                     afterLanding: keepOnClipboard ? .transcription : .previousContents,
                                     afterMissing: afterMissing,
                                     timing: timing,
                                     paste: paste,
                                     outcome: { outcome in
            guard outcome == .missed else { return }
            MainActor.assumeIsolated {
                reportMissedPaste(text, insertion: insertion, retryKeys: retryKeys,
                                  warn: warnWhenMissed)
            }
        })
    }

    /// Where the clipboard is left when a paste missed. The text must stay reachable: through
    /// the paste-last shortcut when one is set (and then the user's clipboard still comes back),
    /// and otherwise on the clipboard for a manual ⌘V, which costs the previous contents but not
    /// the words. That trade is only made when the notice says so: unannounced, the user would
    /// find their clipboard replaced without knowing why — the #44 regression, now triggered by
    /// any slow app that reads after the deadline. History and the shortcut still keep the words.
    static func afterMissedPaste(keepOnClipboard: Bool, pasteLastBound: Bool,
                                 warnWhenMissed: Bool) -> ClipboardUtil.Afterwards {
        if keepOnClipboard { return .transcription }
        return pasteLastBound || !warnWhenMissed ? .previousContents : .transientTranscription
    }

    @MainActor
    private static func reportMissedPaste(_ text: String, insertion: Int, retryKeys: String,
                                          warn: Bool) {
        print("Paste was not taken by the frontmost app within the deadline")
        // A newer insertion has started since: the text the shortcut should reach is that one.
        guard insertion == insertionCount else { return }
        unlandedPaste = text
        guard warn else { return }
        IndicatorWindowManager.shared.flash(.info(missedPasteNotice(retryKeys: retryKeys)))
    }

    static func missedPasteNotice(retryKeys: String) -> String {
        String(localized: "Not pasted — press \(retryKeys) to paste it")
    }
}
