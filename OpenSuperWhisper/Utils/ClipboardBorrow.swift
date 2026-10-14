import Cocoa

// MARK: - Borrow-and-restore (paste mode — #44, #162)

extension ClipboardUtil {

    /// Whether the app in front took the text: it asked the pasteboard for it, or nobody did.
    enum PasteOutcome: Equatable {
        case landed
        case missed
    }

    /// What the clipboard holds once the paste is over.
    enum Afterwards: Equatable {
        /// What was there before the paste ("Copy to clipboard" off, #44).
        case previousContents
        /// The transcription, as an ordinary copy that clipboard histories record ("Copy to
        /// clipboard" on).
        case transcription
        /// The transcription, still marked so histories skip it: left for a manual ⌘V when the
        /// paste missed and there is no other way back to the text.
        case transientTranscription
    }

    /// When the borrowed clipboard is given back.
    struct PasteTiming {
        /// The least time the transcription stays on the clipboard after the ⌘V is posted, from
        /// Settings. Some apps read the pasteboard twice per paste, so the read alone doesn't
        /// prove the second one is done.
        var hold: TimeInterval
        /// How long after the app reads the text the clipboard comes back, for a read that comes
        /// in after `hold` has already run out.
        var settle: TimeInterval
        /// No read by then and the paste most likely went nowhere.
        var deadline: TimeInterval

        static let settleAfterRead: TimeInterval = 0.2
        /// "A second or so": a busy Electron window under post-transcription load reads well
        /// inside it, and a paste with no taker shouldn't keep the user waiting much longer.
        static let missedPasteDeadline: TimeInterval = 1.5

        static var current: PasteTiming {
            let hold = borrowRestoreDelay
            return PasteTiming(hold: hold, settle: settleAfterRead,
                               deadline: max(hold, missedPasteDeadline))
        }
    }

    /// How long the borrowed pasteboard keeps the transcription at least, set in Settings ›
    /// Output (`clipboardRestoreDelayMs`, 0.5 s by default). The restore now waits for the app to
    /// read the text as well, so this is a floor rather than the whole wait.
    static var borrowRestoreDelay: TimeInterval {
        let range = AppPreferences.clipboardRestoreDelayRange
        let ms = min(max(AppPreferences.shared.clipboardRestoreDelayMs, range.lowerBound), range.upperBound)
        return TimeInterval(ms) / 1000
    }

    /// Puts `text` on the pasteboard for one ⌘V (`paste`) and settles the clipboard once the paste
    /// is over. A transcription left there afterwards is `keeping`, by default the pasted text:
    /// one fitted to the field it went into is not the one to paste anywhere else (#163).
    ///
    /// The text is offered lazily: the pasteboard only gets it when someone asks for it, and that
    /// request is the paste landing. So the clipboard comes back a short while after the app in
    /// front actually read the text, not a fixed time after the keystroke, which a busy app could
    /// lose (#162). When nobody asks before the deadline, `outcome` reports `.missed` and the
    /// clipboard ends up as `afterMissing` says. With `rich`, the same item also offers the text
    /// as RTF and HTML (#166), just as lazily: a read of any of them is the landing, and the
    /// plain string stays on it for every app that reads nothing else.
    ///
    /// Clipboard managers poll the pasteboard too, and their read would look like the paste. The
    /// transient markers keep the ones that honour nspasteboard.org (Raycast, Maccy, Paste) to a
    /// look at the types, which asks for nothing; the item is also kept off Universal Clipboard,
    /// which would otherwise fetch it for the user's other devices.
    ///
    /// Newer content wins: if anything else writes to the pasteboard meanwhile (a user copy), the
    /// clipboard is left alone. Overlapping borrows — a dictation insert followed within the delay
    /// by the paste-last shortcut — coalesce onto the first borrow's snapshot, and only the last
    /// one reports an outcome: an earlier paste whose text was replaced before anyone read it
    /// can't be told apart from one still on its way.
    static func borrowForPaste(_ text: String,
                               rich: RichPasteText? = nil,
                               keeping kept: String? = nil,
                               on pasteboard: NSPasteboard = .general,
                               afterLanding: Afterwards = .previousContents,
                               afterMissing: Afterwards = .previousContents,
                               timing: PasteTiming = .current,
                               paste: () -> Void,
                               outcome: @escaping (PasteOutcome) -> Void = { _ in }) {
        let saved: Snapshot?
        if let pending = pendingBorrows.removeValue(forKey: pasteboard.name) {
            pending.cancel()
            // Never a fresh snapshot here, even when the earlier borrow kept none ("Copy to
            // clipboard" switched off in between): reading the pasteboard would fire that borrow's
            // provider and save its transcription as the "previous contents". Without a snapshot
            // a restore leaves the clipboard empty, which at least isn't dictated text.
            saved = pending.saved
        } else if afterLanding == .previousContents || afterMissing == .previousContents {
            saved = snapshot(of: pasteboard)
        } else {
            saved = nil
        }

        let watcher = PasteReadWatcher(text: text, rich: rich)
        let borrow = Borrow(pasteboard: pasteboard, text: kept ?? text, saved: saved,
                            changeCount: offerLazily(watcher, on: pasteboard),
                            afterLanding: afterLanding, afterMissing: afterMissing,
                            timing: timing, outcome: outcome)
        watcher.onRead = { [weak borrow] in borrow?.noteRead() }
        pendingBorrows[pasteboard.name] = borrow
        paste()
        borrow.start()
    }

    /// Borrows still waiting for their paste, keyed by pasteboard name. A borrow that lands while
    /// another is pending must NOT snapshot — the pasteboard holds the previous borrow's
    /// transcription, and restoring that later would overwrite the user's contents with dictated
    /// text, the very thing "Copy to clipboard" off exists to prevent. Main-thread only, like every
    /// caller, the timers and the read notices, which the watcher brings over to it.
    private static var pendingBorrows: [NSPasteboard.Name: Borrow] = [:]

    /// Writes one item whose text is supplied on request, with the transient markers set
    /// up front. Returns the change count the write produced.
    ///
    /// With rich text the UTF-16 plain text is offered as well: left out, the system derives it
    /// from the RTF, which drops the "- " and "1. " the plain lines keep, and an app reading that
    /// type would get bare lines.
    private static func offerLazily(_ watcher: PasteReadWatcher, on pasteboard: NSPasteboard) -> Int {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        let types: [NSPasteboard.PasteboardType] = watcher.rich == nil
            ? [.string] : [.rtf, .html, utf16PlainText, .string]
        item.setDataProvider(watcher, forTypes: types)
        for type in transientTypes { item.setData(Data(), forType: type) }
        pasteboard.writeObjects([item])
        return pasteboard.changeCount
    }

    /// The plain text as older and Carbon-era apps read it.
    static let utf16PlainText = NSPasteboard.PasteboardType("public.utf16-external-plain-text")

    /// One borrow, from the write to the moment the clipboard is settled.
    private final class Borrow {
        let saved: Snapshot?
        private let pasteboard: NSPasteboard
        /// What the clipboard keeps when it is left with the transcription.
        private let text: String
        private let changeCount: Int
        private let afterLanding: Afterwards
        private let afterMissing: Afterwards
        private let timing: PasteTiming
        private let outcome: (PasteOutcome) -> Void
        private var postedAt: DispatchTime?
        private var readAt: DispatchTime?
        private var timer: DispatchWorkItem?
        /// Taken over by a newer borrow, which reports for both.
        private var isCancelled = false

        init(pasteboard: NSPasteboard, text: String, saved: Snapshot?, changeCount: Int,
             afterLanding: Afterwards, afterMissing: Afterwards, timing: PasteTiming,
             outcome: @escaping (PasteOutcome) -> Void) {
            self.pasteboard = pasteboard
            self.text = text
            self.saved = saved
            self.changeCount = changeCount
            self.afterLanding = afterLanding
            self.afterMissing = afterMissing
            self.timing = timing
            self.outcome = outcome
        }

        /// The ⌘V has been posted. A read can already have happened, from inside `paste` itself.
        func start() {
            let now = DispatchTime.now()
            postedAt = now
            if readAt != nil {
                scheduleLanding()
            } else {
                schedule(.missed, at: now + timing.deadline)
            }
        }

        func noteRead() {
            guard readAt == nil, !isCancelled else { return }
            readAt = .now()
            if postedAt != nil { scheduleLanding() }
        }

        func cancel() {
            isCancelled = true
            timer?.cancel()
            timer = nil
        }

        private func scheduleLanding() {
            guard let postedAt, let readAt else { return }
            schedule(.landed, at: max(postedAt + timing.hold, readAt + timing.settle))
        }

        private func schedule(_ result: PasteOutcome, at deadline: DispatchTime) {
            timer?.cancel()
            let item = DispatchWorkItem { [self] in finish(result) }
            timer = item
            DispatchQueue.main.asyncAfter(deadline: deadline, execute: item)
        }

        private func finish(_ result: PasteOutcome) {
            timer = nil
            if ClipboardUtil.pendingBorrows[pasteboard.name] === self {
                ClipboardUtil.pendingBorrows[pasteboard.name] = nil
            }
            if pasteboard.changeCount == changeCount {
                settle(result == .landed ? afterLanding : afterMissing)
            }
            outcome(result)
        }

        private func settle(_ afterwards: Afterwards) {
            switch afterwards {
            case .previousContents:
                ClipboardUtil.restore(saved ?? Snapshot(items: []), to: pasteboard)
            case .transcription:
                ClipboardUtil.copyToClipboard(text, to: pasteboard)
            case .transientTranscription:
                ClipboardUtil.copyTransient(text, to: pasteboard)
            }
        }
    }
}

/// Supplies the borrowed text the moment someone asks the pasteboard for it, and says so.
/// Another process's read is served on the main thread, from the run loop, but a read from inside
/// this process runs the provider on the reader's own thread (the SDK marks it nonisolated). The
/// borrow's state and timers are main-thread only, so the news is carried over there.
private final class PasteReadWatcher: NSObject, NSPasteboardItemDataProvider {
    let text: String
    let rich: RichPasteText?
    /// Set once, before the text is offered, and only read afterwards.
    var onRead: (() -> Void)?

    init(text: String, rich: RichPasteText?) {
        self.text = text
        self.rich = rich
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        switch (type, rich) {
        case (.html, let rich?): item.setData(rich.html, forType: type)
        case (.rtf, let rich?): item.setData(rich.rtf, forType: type)
        case (ClipboardUtil.utf16PlainText, _): item.setData(text.data(using: .utf16) ?? Data(), forType: type)
        default: item.setString(text, forType: type)
        }
        guard let onRead else { return }
        if Thread.isMainThread {
            onRead()
        } else {
            DispatchQueue.main.async(execute: onRead)
        }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}
}
