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

    @MainActor
    static func pasteInPieces(_ pieces: [String], standalone: String,
                              keepOnClipboard: Bool) async -> Insertion {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return await pasteInPieces(
            pieces, standalone: standalone, keepOnClipboard: keepOnClipboard,
            retryShortcut: KeyboardShortcuts.getShortcut(for: .pasteLastTranscription)?.description,
            warnWhenMissed: AppPreferences.shared.notifyWhenNoPasteTarget,
            stillInFront: { NSWorkspace.shared.frontmostApplication?.processIdentifier == front },
            paste: { Diag.measure("TextInserter.paste") { TextInserter.paste() } })
    }

    /// Pastes each piece once the one before has been read, with the system passed in so tests
    /// can run it on a private pasteboard without posting a keystroke.
    ///
    /// Each piece borrows the clipboard as a single paste does (#162), and takes the borrow over
    /// from the piece before it: the user's clipboard is saved once, before the first, and comes
    /// back once, after the last has landed. A piece is only put on the clipboard after the one
    /// before was read, or the terminal would read the wrong one.
    ///
    /// It stops when a piece is not taken, when a newer transcription starts going somewhere,
    /// and when another app comes to the front: a ⌘V meant for the terminal is never sent to
    /// it. What was not pasted is held as a missed paste is, for the paste-last shortcut.
    ///
    /// - Parameters:
    ///   - standalone: what the clipboard keeps once the paste is over, as for a single paste.
    ///   - stillInFront: whether the app the first piece went to is still the one in front.
    /// - Returns: `.done` once the last piece has been read, which is when Return may follow.
    @MainActor
    static func pasteInPieces(_ pieces: [String], standalone: String, keepOnClipboard: Bool,
                              retryShortcut: String?, warnWhenMissed: Bool,
                              on pasteboard: NSPasteboard = .general,
                              timing: ClipboardUtil.PasteTiming = .current,
                              gap: TimeInterval = AgentPromptPaste.pieceGap,
                              stillInFront: () -> Bool,
                              paste: () -> Void) async -> Insertion {
        let afterMissing = afterMissedPaste(keepOnClipboard: keepOnClipboard,
                                            pasteLastBound: retryShortcut != nil,
                                            warnWhenMissed: warnWhenMissed)
        let insertion = insertionCount
        let retryKeys = afterMissing == .previousContents ? retryShortcut ?? "⌘V" : "⌘V"

        for index in pieces.indices {
            // Nothing in the field yet: the text to keep is the whole one, as a single paste
            // keeps it. Past the first piece, only the rest is still to be pasted.
            let rest = index == pieces.startIndex ? standalone : pieces[index...].joined()
            if index > pieces.startIndex {
                try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
                guard insertion == insertionCount else { return .cutShort }
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
                paste: paste,
                missed: { reportMissedPaste(rest, insertion: insertion, retryKeys: retryKeys,
                                            warn: warnWhenMissed) })
            guard read else { return .cutShort }
        }
        return .done
    }

    /// Room for the next piece to take the borrow over before this one settles: were it to
    /// settle first, the clipboard would come back between two pieces, once per piece, and
    /// clipboard histories would record each return.
    static func pieceTiming(_ timing: ClipboardUtil.PasteTiming,
                            gap: TimeInterval) -> ClipboardUtil.PasteTiming {
        ClipboardUtil.PasteTiming(hold: timing.hold, settle: timing.settle + gap + pieceSettleMargin,
                                  deadline: timing.deadline)
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
