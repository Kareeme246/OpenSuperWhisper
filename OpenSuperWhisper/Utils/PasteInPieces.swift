import AppKit
import KeyboardShortcuts

/// A long dictation pasted into Claude Code or Codex a few lines at a time, so it shows in the
/// prompt instead of folding into a placeholder (#165). What goes in each piece is decided in
/// `AgentPromptPaste`; this sends them.
extension TranscriptInserter {

    /// The text as it is pasted into this app and window: in pieces only with the setting on, into
    /// an agent's prompt, and when it would fold whole. One piece otherwise, the usual paste.
    @MainActor
    static func agentPromptPieces(of text: String, into bundleID: String?,
                                  windowTitle: String?) -> [String] {
        guard AppPreferences.shared.pasteAgentPromptsInPieces,
              AgentPromptPaste.isAgentPrompt(bundleID: bundleID, windowTitle: windowTitle)
        else { return [text] }
        let pieces = AgentPromptPaste.pieces(of: text)
        if pieces.count > 1 { Diag.mark("agent prompt: pasting in \(pieces.count) pieces") }
        return pieces
    }

    /// - Parameter wanted: `false` once the dictation was thrown away: nothing more of it goes in.
    @MainActor
    static func pasteInPieces(_ pieces: [String], standalone: String, keepOnClipboard: Bool,
                              wanted: () -> Bool) async -> Insertion {
        let target = PasteWindow.inFront()
        return await pasteInPieces(
            pieces, standalone: standalone, keepOnClipboard: keepOnClipboard,
            retryShortcut: KeyboardShortcuts.getShortcut(for: .pasteLastTranscription)?.description,
            warnWhenMissed: AppPreferences.shared.notifyWhenNoPasteTarget,
            wanted: wanted,
            stillInFront: { target.matches(PasteWindow.inFront()) },
            paste: { Diag.measure("TextInserter.paste") { TextInserter.paste() } })
    }

    /// True while a paste in pieces is going out, so the paste-last shortcut can keep out of its
    /// way: it would paste the whole dictation after the half already in (#165).
    @MainActor private(set) static var pastingInPieces = false

    /// Pastes each piece once the one before has been read, with the system passed in so tests
    /// can run it on a private pasteboard without posting a keystroke.
    ///
    /// Each piece borrows the clipboard as a single paste does (#162), and takes the borrow over
    /// from the piece before it: the user's clipboard is saved once, before the first, and comes
    /// back once, after the last has landed. A piece is only put on the clipboard after the one
    /// before was read, or the terminal would read the wrong one.
    ///
    /// It stops when a piece is not taken, when another app, window or tab comes to the front,
    /// when a newer transcription starts going somewhere, and when the dictation is thrown away:
    /// a ⌘V meant for the agent is never sent anywhere else. In the first two cases what was not
    /// pasted is held as a missed paste is, for the paste-last shortcut; in the last two it is
    /// dropped, the newer text being the last dictation now, or nothing being wanted.
    ///
    /// - Parameters:
    ///   - standalone: what the clipboard keeps once the paste is over, as for a single paste.
    ///   - wanted: `false` once the dictation was thrown away.
    ///   - stillInFront: whether the window the first piece went to is still the one in front.
    /// - Returns: `.done` once the last piece has been read, which is when Return may follow.
    @MainActor
    static func pasteInPieces(_ pieces: [String], standalone: String, keepOnClipboard: Bool,
                              retryShortcut: String?, warnWhenMissed: Bool,
                              on pasteboard: NSPasteboard = .general,
                              timing: ClipboardUtil.PasteTiming = .current,
                              gap: TimeInterval = AgentPromptPaste.pieceGap,
                              wanted: () -> Bool = { true },
                              stillInFront: () -> Bool,
                              paste: () -> Void) async -> Insertion {
        let afterMissing = afterMissedPaste(keepOnClipboard: keepOnClipboard,
                                            pasteLastBound: retryShortcut != nil,
                                            warnWhenMissed: warnWhenMissed)
        let insertion = insertionCount
        let retryKeys = afterMissing == .previousContents ? retryShortcut ?? "⌘V" : "⌘V"
        pastingInPieces = true
        defer { pastingInPieces = false }

        var postedAt = DispatchTime.now()
        for index in pieces.indices {
            // Nothing in the field yet: the text to keep is the whole one, as a single paste
            // keeps it. Past the first piece, only the rest is still to be pasted.
            let rest = index == pieces.startIndex ? standalone : pieces[index...].joined()
            if index > pieces.startIndex {
                let pause = pauseBeforeNextPiece(gap: gap, hold: timing.hold,
                                                 sincePosted: seconds(since: postedAt))
                try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
                guard insertion == insertionCount, wanted() else { return .cutShort }
                guard stillInFront() else {
                    holdUndelivered(rest, onClipboard: warnWhenMissed || keepOnClipboard,
                                    pasteboard: pasteboard)
                    return warnWhenMissed ? .onClipboard : .cutShort
                }
            }
            let last = index == pieces.index(before: pieces.endIndex)
            let read = await pastePiece(
                pieces[index], keeping: keepOnClipboard ? standalone : rest, on: pasteboard,
                afterLanding: keepOnClipboard ? .transcription : .previousContents,
                afterMissing: afterMissing,
                timing: last ? timing : pieceTiming(timing, gap: gap),
                paste: {
                    postedAt = .now()
                    paste()
                },
                missed: { reportMissedPaste(rest, insertion: insertion, retryKeys: retryKeys,
                                            warn: warnWhenMissed) })
            guard read else { return .cutShort }
        }
        return .done
    }

    /// The wait between a piece being read and the next going on the clipboard: the gap, and no
    /// less than what is left of the hold after the piece's ⌘V. Some apps read a paste twice
    /// (Hyper, an Electron app, among the terminals); a second read that found the next piece
    /// would paste it twice and lose this one.
    static func pauseBeforeNextPiece(gap: TimeInterval, hold: TimeInterval,
                                     sincePosted: TimeInterval) -> TimeInterval {
        max(gap, hold - sincePosted)
    }

    /// Room for the next piece to take the borrow over before this one settles: were it to
    /// settle first, the clipboard would come back between two pieces, once per piece, and
    /// clipboard histories would record each return. The next piece waits for the gap after the
    /// read, or for the hold after the ⌘V (`pauseBeforeNextPiece`), so both get the margin.
    static func pieceTiming(_ timing: ClipboardUtil.PasteTiming,
                            gap: TimeInterval) -> ClipboardUtil.PasteTiming {
        ClipboardUtil.PasteTiming(hold: timing.hold + pieceSettleMargin,
                                  settle: timing.settle + gap + pieceSettleMargin,
                                  deadline: timing.deadline)
    }

    private static func seconds(since start: DispatchTime) -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    static let pieceSettleMargin: TimeInterval = 1

    /// One piece on the clipboard and its ⌘V. Returns once the app has read it (`true`), or it
    /// missed, or a newer borrow took the clipboard over first (`false`).
    @MainActor
    private static func pastePiece(_ piece: String, keeping kept: String, on pasteboard: NSPasteboard,
                                   afterLanding: ClipboardUtil.Afterwards,
                                   afterMissing: ClipboardUtil.Afterwards,
                                   timing: ClipboardUtil.PasteTiming, paste: () -> Void,
                                   missed: @escaping @MainActor () -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            var waiting = true
            func resume(_ read: Bool) {
                guard waiting else { return }
                waiting = false
                continuation.resume(returning: read)
            }
            ClipboardUtil.borrowForPaste(piece, keeping: kept, on: pasteboard,
                                         afterLanding: afterLanding, afterMissing: afterMissing,
                                         timing: timing, paste: paste,
                                         read: { resume(true) },
                                         outcome: { outcome in
                // Later outcomes of a piece already read are the next piece taking over, or the
                // last one landing: the paste has moved on and there is nothing to resume.
                if outcome == .missed { MainActor.assumeIsolated { missed() } }
                resume(outcome == .landed)
            })
        }
    }
}

/// The window a paste in pieces goes to, read again before each piece after the first (#165).
/// The app in front alone is not enough: a paste in pieces lasts a few seconds, and a switch to
/// another window or tab of the same terminal (⌘`, ⌘1) would send the rest to whatever runs
/// there, a plain shell as likely as not.
private struct PasteWindow {
    let app: pid_t?
    let window: AXUIElement?
    let title: String?

    /// Read over Accessibility from the app in front, bounded like every other such read here.
    @MainActor
    static func inFront() -> PasteWindow {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return PasteWindow(app: nil, window: nil, title: nil)
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, FocusUtils.axMessagingTimeout)
        var windowRef: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString,
                                            &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else {
            return PasteWindow(app: pid, window: nil, title: nil)
        }
        let window = windowRef as! AXUIElement
        AXUIElementSetMessagingTimeout(window, FocusUtils.axMessagingTimeout)
        var titleRef: AnyObject?
        let title = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString,
                                                  &titleRef) == .success ? titleRef as? String : nil
        return PasteWindow(app: pid, window: window, title: title)
    }

    /// Whether `now`, read between two pieces, is still this window. When the window could not
    /// be read before the first piece, only the app is compared, nothing more being known; a
    /// read that fails after that counts as a change, holding the rest back being the safe side.
    func matches(_ now: PasteWindow) -> Bool {
        guard let app, app == now.app else { return false }
        guard let window else { return true }
        guard let nowWindow = now.window else { return false }
        return CFEqual(window, nowWindow) && AgentPromptPaste.isSameTab(title, as: now.title)
    }
}
