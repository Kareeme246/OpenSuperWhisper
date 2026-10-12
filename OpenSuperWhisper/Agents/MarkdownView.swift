import AppKit
import SwiftUI

/// An agent's Markdown reply as one read-only text view. It was a stack of SwiftUI `Text`s, and
/// a selection could not leave the one it started in: a few lines could be copied, never the
/// whole reply, and selected code showed no highlight at all on its fill.
struct MarkdownView: NSViewRepresentable {
    let blocks: [MarkdownBlock]
    var fontSize: CGFloat = 14
    var prose: MarkdownProse = .primary

    init(markdown: String, fontSize: CGFloat = 14) {
        self.blocks = MarkdownBlock.parse(markdown)
        self.fontSize = fontSize
    }

    init(blocks: [MarkdownBlock], fontSize: CGFloat = 14, prose: MarkdownProse = .primary) {
        self.blocks = blocks
        self.fontSize = fontSize
        self.prose = prose
    }

    func makeNSView(context: Context) -> MarkdownTextView {
        MarkdownTextView()
    }

    func updateNSView(_ view: MarkdownTextView, context: Context) {
        let content = MarkdownTextView.Content(blocks: blocks, fontSize: fontSize,
                                               scale: CGFloat(context.environment.textScaleFactor), prose: prose)
        view.show(content)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? AgentPanelController.width
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }

    /// Inline styling for a single line drawn by SwiftUI, with code spans set on a light fill.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var styled = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        for run in styled.runs where run.inlinePresentationIntent?.contains(.code) == true {
            styled[run.range].backgroundColor = STheme.fill
            styled[run.range].foregroundColor = STheme.textBright
        }
        return styled
    }
}

/// Read-only and selectable, sized by SwiftUI to its text. It lives in a non-activating panel,
/// so it asks for the panel to become key on a click (⌘A and ⌘C need that) and takes the first
/// click instead of spending it on focus.
final class MarkdownTextView: NSTextView {
    struct Content: Equatable {
        var blocks: [MarkdownBlock]
        var fontSize: CGFloat
        var scale: CGFloat
        var prose: MarkdownProse
    }

    private var content: Content?

    init() {
        let storage = NSTextStorage()
        let layout = MarkdownLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: AgentPanelController.width,
                                                     height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        usesFontPanel = false
        selectedTextAttributes = [.backgroundColor: MarkdownPalette.selection]
        linkTextAttributes = [.foregroundColor: MarkdownPalette.accent, .cursor: NSCursor.pointingHand]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    /// Replaces the text only when it changed: SwiftUI updates the view on every redraw of the
    /// panel (the age label ticks, the draft is typed), and each replacement drops the selection.
    func show(_ new: Content) {
        guard new != content else { return }
        content = new
        let builder = MarkdownAttributed(fontSize: new.fontSize, scale: new.scale, prose: new.prose)
        textStorage?.setAttributedString(builder.build(new.blocks))
        invalidateIntrinsicContentSize()
        #if DEBUG
        applySnapshotSelection()
        #endif
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard let container = textContainer, let layout = layoutManager else { return 0 }
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textContainer?.size = NSSize(width: newSize.width, height: .greatestFiniteMagnitude)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }

    /// The app may have no Edit menu to route ⌘A and ⌘C here, so the view answers them itself.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "a": selectAll(nil); return true
        case "c": copy(nil); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    /// Copies (and drags) plain text that reads well elsewhere: list markers, table cells split
    /// by tabs, blank lines between blocks, rather than the attributed text's layout tabs.
    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let storage = textStorage else { return false }
        let text = selectedRanges.map(\.rangeValue)
            .filter { $0.length > 0 }
            .map { MarkdownAttributed.plainText(storage, in: $0) }
            .joined(separator: "\n")
        return pboard.setString(text, forType: .string)
    }

    #if DEBUG
    /// Set by the snapshot probe: the next text shown is selected from the first of these
    /// strings through the end of the second, to draw the highlight off-screen.
    static var snapshotSelection: (from: String, through: String)?

    private func applySnapshotSelection() {
        guard let wanted = Self.snapshotSelection else { return }
        let text = string as NSString
        let start = text.range(of: wanted.from)
        let end = text.range(of: wanted.through)
        guard start.location != NSNotFound, end.location != NSNotFound else { return }
        setSelectedRange(NSRange(location: start.location, length: NSMaxRange(end) - start.location))
    }
    #endif
}

/// Draws a selection in the theme's colour whether or not the panel has focus. The system's
/// grey for an unfocused selection is close to the code fill, so selected code looked unselected.
final class MarkdownLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        let fill = Self.isSystemSelection(color) ? MarkdownPalette.selection : color
        fill.setFill()
        super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: fill)
    }

    /// AppKit picks among several system colours for a selection, depending on focus; the code
    /// chip and the table rule come through here too, in theme colours.
    private static let systemSelectionColors: [NSColor] = [
        .selectedTextBackgroundColor, .unemphasizedSelectedTextBackgroundColor,
        .selectedContentBackgroundColor, .unemphasizedSelectedContentBackgroundColor,
        .secondarySelectedControlColor,
    ]

    private static func isSystemSelection(_ color: NSColor) -> Bool {
        systemSelectionColors.contains(color)
    }
}
