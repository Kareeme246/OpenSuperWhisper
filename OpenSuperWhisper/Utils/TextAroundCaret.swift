import AppKit
import ApplicationServices

/// What the focused field holds on either side of the caret, read just before a dictation is
/// inserted so the text can be fitted to it (#163). Held for that one insertion, never stored.
struct TextAroundCaret: Equatable {
    /// The end of the text before the selection, up to `contextLength`.
    let before: String
    /// What the insertion will replace: empty for a plain caret.
    let selected: String
    /// The start of the text after the selection, up to `lookaheadLength`.
    let after: String

    /// Enough to see the sentence the caret is in, and the capitalised words around it. The
    /// field can be a whole document, and nothing further away says anything about the caret.
    static let contextLength = 2_000
    static let lookaheadLength = 400

    init(before: String, selected: String = "", after: String = "") {
        self.before = before
        self.selected = selected
        self.after = after
    }

    /// Splits a field's value at the selection Accessibility reports, which counts UTF-16 units.
    /// nil when the range does not fit the value: an app whose two answers disagree is not one
    /// whose caret can be trusted.
    init?(value: String, selection: NSRange) {
        let text = value as NSString
        guard selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
              NSMaxRange(selection) <= text.length else { return nil }

        // The far ends of the window are aligned on whole characters, so an emoji at the edge
        // is dropped rather than torn in half. The near ends are the caret, already a boundary.
        var start = max(0, selection.location - Self.contextLength)
        if start > 0 {
            let straddling = text.rangeOfComposedCharacterSequence(at: start)
            if straddling.location < start { start = min(straddling.upperBound, selection.location) }
        }
        var end = min(text.length, NSMaxRange(selection) + Self.lookaheadLength)
        if end < text.length { end = max(text.rangeOfComposedCharacterSequence(at: end).location, NSMaxRange(selection)) }

        self.init(before: text.substring(with: NSRange(location: start, length: selection.location - start)),
                  selected: text.substring(with: selection),
                  after: text.substring(with: NSRange(location: NSMaxRange(selection),
                                                      length: end - NSMaxRange(selection))))
    }

    /// The focused field of the app in front, or nil when it will not give both its text and
    /// its selection. Electron apps often keep `AXValue` to themselves, and a browser page with
    /// no field focused has none: the dictation then goes in exactly as it did before.
    ///
    /// Our own windows are never asked: the request would be answered by this main thread,
    /// which is busy asking it.
    @MainActor
    static func focused() -> TextAroundCaret? {
        guard AXIsProcessTrusted(),
              let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }

        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, FocusUtils.axMessagingTimeout)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success, let focused else { return nil }

        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, FocusUtils.axMessagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String else { return nil }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                            &rangeRef) == .success, let rangeRef,
              CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }
        return TextAroundCaret(value: text, selection: NSRange(location: range.location, length: range.length))
    }
}
