import AppKit
import XCTest
@testable import OpenSuperWhisper

/// The agent's reply as one selectable text, and what a copy of it pastes. Selection used to stop
/// at the edge of each block, so the whole reply could never be copied at once.
final class MarkdownAttributedTests: XCTestCase {

    private func build(_ markdown: String, scale: CGFloat = 1) -> NSAttributedString {
        MarkdownAttributed(fontSize: 14, scale: scale).build(MarkdownBlock.parse(markdown))
    }

    private func copied(_ markdown: String) -> String {
        let text = build(markdown)
        return MarkdownAttributed.plainText(text, in: NSRange(location: 0, length: text.length))
    }

    private func blocks(at substring: String, in text: NSAttributedString) -> [NSTextBlock] {
        let location = (text.string as NSString).range(of: substring).location
        XCTAssertNotEqual(location, NSNotFound, "\(substring) is not in the text")
        let style = text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
        return style?.textBlocks ?? []
    }

    // MARK: What a copy pastes

    func testBulletsCopyAsDashesWithoutTheLayoutTabs() {
        XCTAssertEqual(copied("- `a.swift`\n- **b** too"), "- a.swift\n- b too")
    }

    func testNumbersCopyAsTheyRead() {
        XCTAssertEqual(copied("1. Build\n2. Test"), "1. Build\n2. Test")
    }

    func testCodeCopiesAsIsWithItsLineBreaksAndIndentation() {
        XCTAssertEqual(copied("```swift\nif ok {\n    run()\n}\n```"), "if ok {\n    run()\n}")
    }

    func testTableRowsCopyTabSeparated() {
        XCTAssertEqual(copied("| Model | WER |\n|---|---:|\n| Ultra | 5.7 |\n| v3 | 6.1 |"),
                       "Model\tWER\nUltra\t5.7\nv3\t6.1")
    }

    /// Two empty cells side by side end in two newlines of the same kind: each still copies as
    /// its own tab, or the columns of the pasted row would shift.
    func testEmptyCellsKeepTheirColumns() {
        XCTAssertEqual(copied("| A | B | C | D |\n|---|---|---|---|\n|  |  | x |  |"),
                       "A\tB\tC\tD\n\t\tx\t")
    }

    func testBlocksAreSeparatedByABlankLine() {
        let markdown = """
        ## Done

        I changed **two** files:
        - `a.swift`

        ```
        let x = 1
        ```

        > Careful.

        ---

        Ship it?
        """
        XCTAssertEqual(copied(markdown),
                       "Done\n\nI changed two files:\n\n- a.swift\n\nlet x = 1\n\nCareful.\n\n---\n\nShip it?")
    }

    func testAPartialSelectionCopiesOnlyWhatItCovers() {
        let text = build("Intro line.\n\n| A | B |\n|---|---|\n| 1 | 2 |")
        let start = (text.string as NSString).range(of: "line").location
        let end = NSMaxRange((text.string as NSString).range(of: "1"))
        XCTAssertEqual(MarkdownAttributed.plainText(text, in: NSRange(location: start, length: end - start)),
                       "line.\n\nA\tB\n1")
    }

    // MARK: Structure

    /// A trailing newline would leave an empty line at the bottom of the panel.
    func testTheTextDoesNotEndWithANewline() {
        XCTAssertFalse(build("One.\n\n```\ncode\n```").string.hasSuffix("\n"))
        XCTAssertFalse(build("Text.\n\n---").string.hasSuffix("\n"))
    }

    func testEveryLineOfACodeBlockSharesOneBox() {
        let text = build("```\nfirst\nsecond\n```")
        let first = blocks(at: "first", in: text)
        let second = blocks(at: "second", in: text)
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(first.first is MarkdownBoxBlock)
        XCTAssertTrue(first.first === second.first)
    }

    func testTableCellsSitInTheirRowAndColumnInsideABox() {
        let text = build("| A | B |\n|---|---|\n| 1 | 2 |")
        let cell = blocks(at: "2", in: text)
        XCTAssertTrue(cell.first is MarkdownBoxBlock)
        let tableCell = cell.last as? NSTextTableBlock
        XCTAssertEqual(tableCell?.startingRow, 1)
        XCTAssertEqual(tableCell?.startingColumn, 1)
        XCTAssertEqual(tableCell?.table.numberOfColumns, 2)
    }

    func testQuotedBlocksSitInsideTheQuote() {
        let text = build("> Note\n>\n> ```\n> code\n> ```")
        XCTAssertTrue(blocks(at: "Note", in: text).first is MarkdownQuoteBlock)
        let code = blocks(at: "code", in: text)
        XCTAssertTrue(code.first is MarkdownQuoteBlock)
        XCTAssertTrue(code.last is MarkdownBoxBlock)
    }

    func testInlineStylesBecomeFontsAndTheCodeChip() {
        let text = build("Plain **bold** *italic* `code` [link](https://example.com)")
        func attribute(_ key: NSAttributedString.Key, at word: String) -> Any? {
            text.attribute(key, at: (text.string as NSString).range(of: word).location, effectiveRange: nil)
        }
        let bold = attribute(.font, at: "bold") as? NSFont
        let italic = attribute(.font, at: "italic") as? NSFont
        let code = attribute(.font, at: "code") as? NSFont
        XCTAssertTrue(bold?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        XCTAssertTrue(italic?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        XCTAssertTrue(code?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        XCTAssertNotNil(attribute(.backgroundColor, at: "code"))
        XCTAssertNil(attribute(.backgroundColor, at: "Plain"))
        XCTAssertEqual(attribute(.link, at: "link") as? URL, URL(string: "https://example.com"))
    }

    /// The text size setting reaches the AppKit text as it reached the SwiftUI one.
    func testFontsFollowTheTextSize() {
        let text = build("Hello", scale: 1.5)
        XCTAssertEqual((text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 21)
    }

    func testHeadingsAreLargerThanProse() {
        let text = build("# Title\n\nBody")
        let heading = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let body = text.attribute(.font, at: (text.string as NSString).range(of: "Body").location,
                                  effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(heading?.pointSize ?? 0, body?.pointSize ?? 0)
    }

    func testALiteralPermissionMessageKeepsItsMarkdownCharacters() {
        let message = "Run swiftlint on src/**/*.swift and _build_ (see [docs])"
        let literal = MarkdownView.literal(message)
        XCTAssertEqual(String(MarkdownView.inline(literal).characters), message)
    }
}
