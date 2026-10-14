import ApplicationServices
import CoreGraphics

/// The geometry questions the caret anchor asks the focused text element, one at a time.
///
/// A protocol so the decision can run against geometry recorded from real apps instead of a
/// live Accessibility target. Rects are in AX (Quartz, top-left origin) coordinates.
protocol TextElementGeometry {
    /// What the element answers to `AXBoundsForRange` for `range`, or nil when it refuses.
    func bounds(of range: CFRange) -> CGRect?
    /// The element's own frame, or nil when it does not report one.
    var frame: CGRect? { get }
}

/// Where the bubble anchors in "cursor" mode, chosen from what the focused text element reports.
enum CaretAnchor {

    /// Which of the element's answers the anchor came from, for the diagnostic log.
    enum Source: String {
        case caret
        case characterBefore
        case field
    }

    struct Choice: Equatable {
        let rect: CGRect
        let source: Source
    }

    /// Picks the anchor for `selection`, asking `element` only what it needs to.
    ///
    /// In order:
    /// 1. The caret itself, when it has height. A successful bounds query is not a believable one:
    ///    Chrome answers with an empty rect at a corner of the primary display (#143). Where a
    ///    caret with height sits is not second-guessed: TextEdit reports a valid one above its
    ///    text view's own frame.
    /// 2. The trailing edge of the character just before the caret. Terminal.app answers the caret
    ///    query with an empty rect at a meaningless position, but places the character before it
    ///    on the prompt line (#155). Since #144 that terminal fell straight through to its text
    ///    area, which is the whole window, and the bubble sat at the window's corner.
    /// 3. The field itself, which Chrome reports correctly where its caret and characters are
    ///    both empty (#144).
    ///
    /// An app with a believable caret is asked one question. nil when nothing usable comes back,
    /// leaving the caller to fall back to the mouse.
    static func choose(selection: CFRange, in element: TextElementGeometry) -> Choice? {
        if let caret = element.bounds(of: selection), caret.height > 0 {
            return Choice(rect: caret, source: .caret)
        }
        let field = element.frame.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        if let edge = trailingEdgeOfCharacter(before: selection, in: element, field: field) {
            return Choice(rect: edge, source: .characterBefore)
        }
        return field.map { Choice(rect: $0, source: .field) }
    }

    /// A zero-width caret where the character before the selection ends, or nil when there is no
    /// such character or its bounds are no more believable than the caret's.
    ///
    /// Only the character before: at the start of the text there is nothing to measure, and the
    /// character after is no substitute, because Ghostty reports its caret at offset 0 whenever
    /// nothing is selected, and the first character of its scrollback is nowhere near the prompt. A "character" covering the
    /// whole field is the field: Chrome answers the sibling text-marker query with the entire
    /// editor (#143), and its trailing edge would put the bubble past the field's far side.
    private static func trailingEdgeOfCharacter(before selection: CFRange,
                                                in element: TextElementGeometry,
                                                field: CGRect?) -> CGRect? {
        guard selection.location > 0,
              let character = element.bounds(of: CFRange(location: selection.location - 1, length: 1)),
              character.height > 0 else { return nil }
        if let field, character.contains(field) { return nil }
        return CGRect(x: character.maxX, y: character.minY, width: 0, height: character.height)
    }
}

/// The live element behind `TextElementGeometry`. Every answer goes to the diagnostic log, rects
/// and offsets only, never text, so an app that misplaces the bubble can be turned into a test
/// fixture from `log show`.
struct AXTextElementGeometry: TextElementGeometry {
    let element: AXUIElement

    func bounds(of range: CFRange) -> CGRect? {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return nil }
        var answer: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(element,
                                                               kAXBoundsForRangeParameterizedAttribute as CFString,
                                                               value,
                                                               &answer)
        let rect = error == .success ? answer.flatMap(Self.rect(of:)) : nil
        Diag.mark("caret geometry: bounds(\(range.location)+\(range.length)) = \(Self.describe(rect)) (AXError \(error.rawValue))")
        return rect
    }

    var frame: CGRect? {
        let rect = Self.frame(of: element)
        Diag.mark("caret geometry: frame = \(Self.describe(rect))")
        return rect
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }

        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func rect(of value: CFTypeRef) -> CGRect? {
        let value = value as! AXValue
        var rect = CGRect.zero
        guard AXValueGetType(value) == .cgRect, AXValueGetValue(value, .cgRect, &rect) else { return nil }
        return rect
    }

    private static func describe(_ rect: CGRect?) -> String {
        guard let rect else { return "none" }
        return "(\(rect.minX), \(rect.minY)) \(rect.width) × \(rect.height)"
    }
}
