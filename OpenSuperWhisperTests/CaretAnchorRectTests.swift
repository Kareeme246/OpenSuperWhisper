import XCTest
@testable import OpenSuperWhisper

/// "Cursor" mode anchors the bubble to whatever the focused text element reports about its caret.
/// Chrome answers with an empty rect nowhere near the field (#143), so since #144 such a caret is
/// discarded for the field. Terminal.app answers the same way, and its field is the whole window,
/// which put the bubble at the window's corner (#155). These replay what each app reports, see
/// `CaretGeometryFixtures`, and pin down where the bubble goes.
final class CaretAnchorRectTests: XCTestCase {

    private func choose(_ element: RecordedTextElement) -> CaretAnchor.Choice? {
        CaretAnchor.choose(selection: element.selection, in: element)
    }

    // MARK: Chrome stays on the field (#144)

    func testChromeFieldsAnchorToTheFieldWhenNeitherCaretNorCharacterHasHeight() {
        for element in [CaretGeometryFixtures.chromeOmnibox(), CaretGeometryFixtures.chromeInput(),
                        CaretGeometryFixtures.chromeTextarea(), CaretGeometryFixtures.chromeContentEditable()] {
            let choice = choose(element)
            XCTAssertEqual(choice?.source, .field, element.name)
            XCTAssertEqual(choice?.rect, element.frame, element.name)
        }
    }

    // MARK: A real caret is used as reported

    /// TextEdit reports its caret above the text view's own frame. It is still the right place,
    /// and an app with a real caret is asked nothing more.
    func testTextEditCaretIsUsedWithASingleQuestion() {
        let textEdit = CaretGeometryFixtures.textEdit()
        let choice = choose(textEdit)
        XCTAssertEqual(choice, .init(rect: CGRect(x: 2966.35, y: 88, width: 0, height: 14), source: .caret))
        XCTAssertEqual(textEdit.asked, ["bounds(3+0)"])
    }

    // MARK: Terminals (#155)

    /// The character before the caret is on the prompt line; the bubble anchors where it ends,
    /// which is where the caret is.
    func testTerminalAnchorsToTheEndOfTheCharacterBeforeTheCaret() {
        let terminal = CaretGeometryFixtures.terminal()
        let choice = choose(terminal)
        XCTAssertEqual(choice, .init(rect: CGRect(x: 254, y: 523, width: 0, height: 15), source: .characterBefore))
        XCTAssertEqual(terminal.asked, ["bounds(5231+0)", "frame", "bounds(5230+1)"])
    }

    /// Ghostty places nothing, and its caret sits at offset 0 when nothing is selected: there is
    /// no character before it to ask about, and the first character of the scrollback is not
    /// asked about either.
    func testGhosttyFallsBackToItsSurfaceWithoutAskingAboutOtherCharacters() {
        let ghostty = CaretGeometryFixtures.ghostty()
        let choice = choose(ghostty)
        XCTAssertEqual(choice, .init(rect: CGRect(x: 0, y: 66, width: 1512, height: 916), source: .field))
        XCTAssertEqual(ghostty.asked, ["bounds(0+0)", "frame"])
    }

    // MARK: Edge cases

    /// Chrome's text-marker query answers with the entire editor (#143). A "character" that
    /// covers its field is the field, and its trailing edge would sit past the field's far side.
    func testCharacterCoveringTheFieldIsNotUsed() {
        let field = CGRect(x: 4061, y: 517, width: 402, height: 82)
        let element = RecordedTextElement("whole-editor character",
                                          selection: CFRange(location: 8, length: 0),
                                          bounds: ["8+0": .zero, "7+1": field.insetBy(dx: -1, dy: -1)],
                                          frame: field)
        XCTAssertEqual(choose(element), .init(rect: field, source: .field))
    }

    func testCharacterBeforeIsUsedWhenTheFieldFrameIsUnknown() {
        let element = RecordedTextElement("no frame",
                                          selection: CFRange(location: 2, length: 0),
                                          bounds: ["1+1": CGRect(x: 300, y: 400, width: 8, height: 18)],
                                          frame: nil)
        XCTAssertEqual(choose(element), .init(rect: CGRect(x: 308, y: 400, width: 0, height: 18), source: .characterBefore))
    }

    func testCaretIsUsedWhenTheElementFrameIsUnknown() {
        let caret = CGRect(x: 300, y: 400, width: 0, height: 18)
        let element = RecordedTextElement("caret only", selection: CFRange(location: 1, length: 0),
                                          bounds: ["1+0": caret], frame: nil)
        XCTAssertEqual(choose(element), .init(rect: caret, source: .caret))
    }

    func testNothingUsableGivesNothing() {
        let empty = RecordedTextElement("empty answers", selection: CFRange(location: 4, length: 0),
                                        bounds: ["4+0": .zero, "3+1": .zero], frame: .zero)
        XCTAssertNil(choose(empty))
        let refused = RecordedTextElement("refused", selection: CFRange(location: 4, length: 0),
                                          bounds: [:], frame: nil)
        XCTAssertNil(choose(refused))
    }
}
