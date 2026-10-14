import AppKit
import ApplicationServices

/// The field a dictation started in, kept so its text can go back there once transcribed (#164).
///
/// Transcription runs after the recording stops, and with a long clip or a slow model the user
/// has often clicked somewhere else by the time the text is ready. Held in memory with the one
/// dictation it belongs to, never written anywhere.
struct FocusTarget {
    let pid: pid_t
    /// Checked along with the pid, which the system hands to another process once the app quits.
    let bundleID: String?
    /// The focused element when the dictation started. nil when the app would not say, which is
    /// what Chrome and Electron answer while their accessibility tree is off: the app alone is
    /// then all there is to go back to.
    let element: AXUIElement?
    /// Where the caret was in that element. Put back after refocusing, because a text field
    /// that regains the focus selects all of its text, and the paste would replace it.
    let selection: AXValue?

    /// The focused element of `app` right now, with its caret.
    static func capture(_ app: NSRunningApplication) -> FocusTarget {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, FocusUtils.axMessagingTimeout)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success, let focused else {
            return FocusTarget(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                               element: nil, selection: nil)
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, FocusUtils.axMessagingTimeout)

        var range: CFTypeRef?
        let hasRange = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                                     &range) == .success
        return FocusTarget(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                           element: element, selection: hasRange ? range.map { $0 as! AXValue } : nil)
    }
}

/// What putting the focus back needs from the system, behind a seam so the decision can be
/// tested without activating or focusing anything on the machine running the tests.
@MainActor
protocol FocusControlling {
    func frontmostPID() -> pid_t?
    /// The app is still the one that was captured, not a new process that inherited its pid.
    func isRunning(_ target: FocusTarget) -> Bool
    /// Whether the captured element still has the focus in its app. nil when the app would not
    /// say, which is no evidence that the user moved.
    func stillFocused(_ target: FocusTarget) -> Bool?
    /// Brings the app in front. false when the system refused.
    func activate(_ target: FocusTarget) -> Bool
    /// Raises the element's window, focuses the element and puts its caret back. false when the
    /// element is gone or would not take the focus.
    func focus(_ target: FocusTarget) -> Bool
    /// Gives the app a moment to act on the focus change before anything is typed into it.
    func settle() async
}

/// Puts the focus back where a dictation started before its text is inserted (#164).
enum FocusReturn {

    enum Outcome: Equatable {
        /// The focus never left, or there is nothing more precise to go back to.
        case alreadyThere
        /// The field has the focus again.
        case refocused
        /// The field is gone, so only the app is back: the text goes wherever it puts the focus.
        case appOnly
        /// The app quit or would not come back. Inserting now would put the text into whatever
        /// is in front, which is exactly the wrong place.
        case unreachable
    }

    @MainActor
    static func bringBack(_ target: FocusTarget,
                          using system: FocusControlling = LiveFocusControl()) async -> Outcome {
        guard system.isRunning(target) else { return .unreachable }

        if system.frontmostPID() == target.pid {
            // Another field of the same app, or the same one: only a definite "moved" is acted
            // on, so an app that cannot answer behaves as it did before this feature.
            guard target.element != nil, system.stillFocused(target) == false else { return .alreadyThere }
            let outcome: Outcome = system.focus(target) ? .refocused : .appOnly
            await system.settle()
            return outcome
        }

        guard system.activate(target) else { return .unreachable }
        let outcome: Outcome = target.element != nil && system.focus(target) ? .refocused : .appOnly
        await system.settle()
        // An activation the system accepted and then did not carry out leaves someone else in
        // front, and the text would land there.
        return system.frontmostPID() == target.pid ? outcome : .unreachable
    }
}

/// The real system, through Accessibility and the workspace.
@MainActor
struct LiveFocusControl: FocusControlling {

    /// Long enough for an activated app to bring its window forward and hand the field the
    /// focus, short enough not to be noticed on top of the transcription itself.
    static let settleDelay: Duration = .milliseconds(200)

    nonisolated init() {}

    func frontmostPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func isRunning(_ target: FocusTarget) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated else {
            return false
        }
        return app.bundleIdentifier == target.bundleID
    }

    func stillFocused(_ target: FocusTarget) -> Bool? {
        guard let element = target.element else { return nil }
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, FocusUtils.axMessagingTimeout)
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let focused else {
            // Nothing focused at all is an answer: the user clicked off the field.
            return FocusUtils.reportsNothingFocused(err) ? false : nil
        }
        return CFEqual(focused, element)
    }

    /// Through Accessibility first: since macOS 14 activation is cooperative, and an app that is
    /// not active itself (which OpenSuperWhisper is not, while it transcribes in the background)
    /// has nothing to yield. The workspace request is the fallback when the app refuses the
    /// accessibility one.
    func activate(_ target: FocusTarget) -> Bool {
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, FocusUtils.axMessagingTimeout)
        if AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success {
            return true
        }
        return NSRunningApplication(processIdentifier: target.pid)?.activate(options: []) ?? false
    }

    func focus(_ target: FocusTarget) -> Bool {
        guard let element = target.element else { return false }
        AXUIElementSetMessagingTimeout(element, FocusUtils.axMessagingTimeout)
        raiseWindow(of: element)
        guard AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString,
                                           kCFBooleanTrue) == .success else { return false }
        if let selection = target.selection {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, selection)
        }
        return true
    }

    func settle() async {
        try? await Task.sleep(for: Self.settleDelay)
    }

    /// The field may sit in another window of the app than the one in front now, and focusing
    /// an element does not bring its window forward.
    private func raiseWindow(of element: AXUIElement) {
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString,
                                            &windowRef) == .success, let windowRef else { return }
        let window = windowRef as! AXUIElement
        AXUIElementSetMessagingTimeout(window, FocusUtils.axMessagingTimeout)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
}
