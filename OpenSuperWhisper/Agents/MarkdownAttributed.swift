import AppKit
import SwiftUI

extension NSAttributedString.Key {
    /// What a character copies as when that differs from what it shows: a list marker's tab
    /// stops, the newline that ends a table cell, the blank line between two blocks.
    static let markdownCopy = NSAttributedString.Key("OSWMarkdownCopy")
}

/// Turns an agent's parsed reply into one attributed string, so the whole reply is one text the
/// user can select across, rather than a stack of views each holding a piece of it.
struct MarkdownAttributed {
    /// Designed size of the prose; the other sizes are set relative to it, as before.
    var fontSize: CGFloat = 14
    /// The text size setting, applied to every font.
    var scale: CGFloat = 1
    var prose: MarkdownProse = .primary

    static let blockGap: CGFloat = 10
    static let itemGap: CGFloat = 5
    static let boxPadding: CGFloat = 12

    func build(_ blocks: [MarkdownBlock]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        // A closing rule has nothing after it to separate from.
        var shown = blocks
        while shown.last == .rule { shown.removeLast() }
        append(shown, to: out, in: [], spacingAfter: 0, copyEnd: "")
        if out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }

    /// The text a selection copies: what it shows, with the substitutions it carries.
    static func plainText(_ text: NSAttributedString, in range: NSRange) -> String {
        var out = ""
        let source = text.string as NSString
        text.enumerateAttribute(.markdownCopy, in: range) { value, run, _ in
            if let copy = value as? String {
                // One substitution per character: two empty table cells side by side form one run.
                out += String(repeating: copy, count: run.length)
            } else {
                out += source.substring(with: run)
            }
        }
        return out
    }

    // MARK: Blocks

    private func append(_ blocks: [MarkdownBlock], to out: NSMutableAttributedString,
                        in containers: [NSTextBlock], spacingAfter: CGFloat, copyEnd: String) {
        for (index, block) in blocks.enumerated() {
            let isLast = index == blocks.count - 1
            append(block, to: out, in: containers,
                   spacingAfter: isLast ? spacingAfter : Self.blockGap,
                   copyEnd: isLast ? copyEnd : "\n\n")
        }
    }

    private func append(_ block: MarkdownBlock, to out: NSMutableAttributedString,
                        in containers: [NSTextBlock], spacingAfter: CGFloat, copyEnd: String) {
        let start = out.length
        switch block {
        case .heading(let level, let text):
            let style = paragraphStyle(containers, after: spacingAfter)
            style.paragraphSpacingBefore = level <= 2 ? 4 : 0
            let size = fontSize + CGFloat(max(0, 4 - level)) * 1.5
            out.append(inline(text, font: font(size, .semibold), color: MarkdownPalette.bright))
            endParagraph(out, from: start, style: style, copy: copyEnd)
        case .paragraph(let text):
            let style = paragraphStyle(containers, after: spacingAfter)
            style.lineSpacing = 3
            out.append(inline(text, font: font(fontSize + prose.sizeOffset), color: prose.color))
            endParagraph(out, from: start, style: style, copy: copyEnd)
        case .bullet(let items):
            appendList(items.map { ("•", $0) }, copyMarker: "-", to: out, in: containers,
                       spacingAfter: spacingAfter, copyEnd: copyEnd)
        case .numbered(let items):
            appendList(items.enumerated().map { ("\($0.offset + 1).", $0.element) }, copyMarker: nil,
                       to: out, in: containers, spacingAfter: spacingAfter, copyEnd: copyEnd)
        case .code(_, let text):
            appendCode(text, to: out, in: containers, spacingAfter: spacingAfter, copyEnd: copyEnd)
        case .quote(let inner):
            let quote = MarkdownQuoteBlock()
            quote.setWidth(spacingAfter, type: .absoluteValueType, for: .margin, edge: .maxY)
            append(inner, to: out, in: containers + [quote], spacingAfter: 0, copyEnd: copyEnd)
        case .table(let header, let rows):
            appendTable(header: header, rows: rows, to: out, in: containers,
                        spacingAfter: spacingAfter, copyEnd: copyEnd)
        case .rule:
            let rule = MarkdownRuleBlock()
            rule.setWidth(2, type: .absoluteValueType, for: .margin, edge: .minY)
            rule.setWidth(spacingAfter + 2, type: .absoluteValueType, for: .margin, edge: .maxY)
            let style = paragraphStyle(containers + [rule], after: 0)
            style.minimumLineHeight = 1
            style.maximumLineHeight = 1
            out.append(NSAttributedString(string: "", attributes: [.font: font(1)]))
            endParagraph(out, from: start, style: style, copy: "---" + copyEnd, font: font(1))
        }
    }

    private func appendList(_ items: [(marker: String, text: String)], copyMarker: String?,
                            to out: NSMutableAttributedString, in containers: [NSTextBlock],
                            spacingAfter: CGFloat, copyEnd: String) {
        let markerFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize * scale, weight: .medium)
        let widest = items.map { ($0.marker as NSString).size(withAttributes: [.font: markerFont]).width }.max() ?? 0
        let markerEdge = max(14, ceil(widest))
        let textStart = markerEdge + 8
        for (index, item) in items.enumerated() {
            let isLast = index == items.count - 1
            let start = out.length
            let style = paragraphStyle(containers, after: isLast ? spacingAfter : Self.itemGap)
            style.lineSpacing = 3
            style.tabStops = [NSTextTab(textAlignment: .right, location: markerEdge),
                              NSTextTab(textAlignment: .left, location: textStart)]
            style.headIndent = textStart
            let marker: [NSAttributedString.Key: Any] = [.font: markerFont, .foregroundColor: MarkdownPalette.hint]
            out.append(NSAttributedString(string: "\t", attributes: marker.merging([.markdownCopy: ""]) { $1 }))
            var markerText = marker
            markerText[.markdownCopy] = copyMarker
            out.append(NSAttributedString(string: item.marker, attributes: markerText))
            out.append(NSAttributedString(string: "\t", attributes: marker.merging([.markdownCopy: " "]) { $1 }))
            out.append(inline(item.text, font: font(fontSize + prose.sizeOffset), color: prose.color))
            endParagraph(out, from: start, style: style, copy: isLast ? copyEnd : nil)
        }
    }

    private func appendCode(_ code: String, to out: NSMutableAttributedString, in containers: [NSTextBlock],
                            spacingAfter: CGFloat, copyEnd: String) {
        let box = codeBox(spacingAfter: spacingAfter)
        let mono = NSFont.monospacedSystemFont(ofSize: (fontSize - 1.5) * scale, weight: .regular)
        let lines = code.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let start = out.length
            let style = paragraphStyle(containers + [box], after: 0)
            out.append(NSAttributedString(string: line, attributes: [.font: mono, .foregroundColor: MarkdownPalette.bright]))
            endParagraph(out, from: start, style: style, copy: index == lines.count - 1 ? copyEnd : nil, font: mono)
        }
    }

    private func appendTable(header: [String], rows: [[String]], to out: NSMutableAttributedString,
                             in containers: [NSTextBlock], spacingAfter: CGFloat, copyEnd: String) {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        guard columns > 0 else { return }
        // The fill and the spacing belong to a box around the table: TextKit lays the paragraph
        // after a table over the table's own bottom padding and margin.
        let box = codeBox(spacingAfter: spacingAfter)
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        let all = [header] + rows
        for (row, cells) in all.enumerated() {
            let isHeader = row == 0
            let cellFont = isHeader
                ? font(fontSize - 1, .semibold)
                : NSFont.monospacedDigitSystemFont(ofSize: (fontSize - 1) * scale, weight: .regular)
            for column in 0..<columns {
                let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1,
                                            startingColumn: column, columnSpan: 1)
                if column < columns - 1 { cell.setWidth(18, type: .absoluteValueType, for: .padding, edge: .maxX) }
                if isHeader {
                    cell.setWidth(7, type: .absoluteValueType, for: .padding, edge: .maxY)
                    cell.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                    cell.setBorderColor(MarkdownPalette.border, for: .maxY)
                } else {
                    cell.setWidth(7, type: .absoluteValueType, for: .padding, edge: .minY)
                }
                let text = column < cells.count ? cells[column] : ""
                let start = out.length
                out.append(inline(text, font: cellFont, color: isHeader ? MarkdownPalette.bright : MarkdownPalette.text))
                let lastCell = column == columns - 1
                let copy = !lastCell ? "\t" : (row == all.count - 1 ? copyEnd : nil)
                endParagraph(out, from: start, style: paragraphStyle(containers + [box, cell], after: 0), copy: copy, font: cellFont)
            }
        }
    }

    private func codeBox(spacingAfter: CGFloat) -> MarkdownBoxBlock {
        let box = MarkdownBoxBlock()
        box.setValue(100, type: .percentageValueType, for: .width)
        box.setWidth(Self.boxPadding, type: .absoluteValueType, for: .padding)
        box.setWidth(spacingAfter, type: .absoluteValueType, for: .margin, edge: .maxY)
        return box
    }

    // MARK: Paragraphs and runs

    private func paragraphStyle(_ containers: [NSTextBlock], after spacing: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.textBlocks = containers
        style.paragraphSpacing = spacing
        return style
    }

    /// Ends the paragraph begun at `start`: its style covers the whole of it, and the newline
    /// copies as `copy` when given.
    private func endParagraph(_ out: NSMutableAttributedString, from start: Int, style: NSParagraphStyle,
                              copy: String?, font newlineFont: NSFont? = nil) {
        var newline: [NSAttributedString.Key: Any] = [.font: newlineFont ?? font(fontSize)]
        if let copy { newline[.markdownCopy] = copy }
        out.append(NSAttributedString(string: "\n", attributes: newline))
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: out.length - start))
    }

    private func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size * scale, weight: weight)
    }

    /// Bold, italic, code spans and links inside a block, from Foundation's inline Markdown.
    func inline(_ text: String, font base: NSFont, color: NSColor) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = base
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if intent.contains(.code) {
                font = .monospacedSystemFont(ofSize: base.pointSize, weight: .regular)
                attributes[.backgroundColor] = MarkdownPalette.fill
                attributes[.foregroundColor] = MarkdownPalette.bright
            }
            if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            attributes[.font] = font
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return out
    }
}

/// How plain paragraphs read: the reply itself, or the quieter explanation under a permission.
enum MarkdownProse: Equatable {
    case primary, secondary

    var color: NSColor { self == .primary ? MarkdownPalette.text : MarkdownPalette.hint }
    var sizeOffset: CGFloat { self == .primary ? 0 : -1 }
}

/// The theme's tokens as AppKit colours. They stay dynamic, so one attributed string draws
/// right in light and dark.
enum MarkdownPalette {
    static let text = NSColor(STheme.text)
    static let bright = NSColor(STheme.textBright)
    static let hint = NSColor(STheme.hint)
    static let fill = NSColor(STheme.fill)
    static let border = NSColor(STheme.border)
    static let accent = NSColor(STheme.accent)
    static let selection = NSColor(STheme.textSelection)
}

/// The rounded fill behind a code block or a table. NSTextBlock only draws square backgrounds.
final class MarkdownBoxBlock: NSTextBlock {
    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?,
                                 characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        let box = frameRect.inset(top: width(for: .margin, edge: .minY), bottom: width(for: .margin, edge: .maxY))
        MarkdownPalette.fill.setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
    }
}

/// The accent bar beside a quote.
final class MarkdownQuoteBlock: NSTextBlock {
    static let barWidth: CGFloat = 3

    override init() {
        super.init()
        setWidth(Self.barWidth + 10, type: .absoluteValueType, for: .padding, edge: .minX)
        setValue(100, type: .percentageValueType, for: .width)
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?,
                                 characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        let box = frameRect.inset(top: width(for: .margin, edge: .minY), bottom: width(for: .margin, edge: .maxY))
        let bar = NSRect(x: box.minX, y: box.minY, width: Self.barWidth, height: box.height)
        MarkdownPalette.accent.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

/// A horizontal rule: a one-point line across the column.
final class MarkdownRuleBlock: NSTextBlock {
    override init() {
        super.init()
        setValue(100, type: .percentageValueType, for: .width)
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?,
                                 characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        let box = frameRect.inset(top: width(for: .margin, edge: .minY), bottom: width(for: .margin, edge: .maxY))
        MarkdownPalette.border.setFill()
        NSRect(x: box.minX, y: box.midY - 0.5, width: box.width, height: 1).fill()
    }
}

private extension NSRect {
    /// Text views are flipped: the top margin is at minY.
    func inset(top: CGFloat, bottom: CGFloat) -> NSRect {
        NSRect(x: minX, y: minY + top, width: width, height: max(0, height - top - bottom))
    }
}
