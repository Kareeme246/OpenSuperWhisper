import XCTest

@testable import OpenSuperWhisper
@testable import OpenSuperWhisperCore

/// Covers reading the field around the caret for #163: splitting a value at the UTF-16 range
/// Accessibility reports, the window fetched instead of the whole value, and the step that
/// decides whether and how a dictation is fitted. The field is always a fake: nothing here reads
/// another app.
@MainActor
final class TextAroundCaretTests: XCTestCase {

    private let prefs = AppPreferences.shared
    private var savedDictionaryEnabled = false
    private var savedEntries: [CustomDictionaryEntry] = []
    private var savedAddSpace = true

    override func setUp() {
        super.setUp()
        savedDictionaryEnabled = prefs.customDictionaryEnabled
        savedEntries = prefs.customDictionaryEntries
        savedAddSpace = prefs.addSpaceAfterSentence
        prefs.addSpaceAfterSentence = true
        prefs.customDictionaryEnabled = false
    }

    override func tearDown() {
        prefs.customDictionaryEnabled = savedDictionaryEnabled
        prefs.customDictionaryEntries = savedEntries
        prefs.addSpaceAfterSentence = savedAddSpace
        super.tearDown()
    }

    // MARK: - Splitting a value

    func testSplitsAtTheCaret() {
        XCTAssertEqual(TextAroundCaret(value: "Hello world", selection: NSRange(location: 5, length: 0)),
                       TextAroundCaret(before: "Hello", selected: "", after: " world"))
    }

    func testSplitsAroundASelection() {
        XCTAssertEqual(TextAroundCaret(value: "Meet on Monday at noon", selection: NSRange(location: 8, length: 6)),
                       TextAroundCaret(before: "Meet on ", selected: "Monday", after: " at noon"))
    }

    func testCountsUTF16LikeAccessibility() {
        let value = "😀 hi there"
        let caret = ("😀 hi" as NSString).length
        XCTAssertEqual(caret, 5)
        XCTAssertEqual(TextAroundCaret(value: value, selection: NSRange(location: caret, length: 0)),
                       TextAroundCaret(before: "😀 hi", selected: "", after: " there"))
    }

    func testCaretAtEitherEnd() {
        XCTAssertEqual(TextAroundCaret(value: "abc", selection: NSRange(location: 0, length: 0)),
                       TextAroundCaret(before: "", selected: "", after: "abc"))
        XCTAssertEqual(TextAroundCaret(value: "abc", selection: NSRange(location: 3, length: 0)),
                       TextAroundCaret(before: "abc", selected: "", after: ""))
    }

    func testRangeOutsideTheValueIsUnreadable() {
        XCTAssertNil(TextAroundCaret(value: "abc", selection: NSRange(location: 4, length: 0)))
        XCTAssertNil(TextAroundCaret(value: "abc", selection: NSRange(location: 2, length: 2)))
        XCTAssertNil(TextAroundCaret(value: "abc", selection: NSRange(location: NSNotFound, length: 0)))
    }

    func testLongFieldKeepsOnlyAWindowAroundTheCaret() {
        let value = String(repeating: "a", count: 5_000) + String(repeating: "b", count: 5_000)
        let field = TextAroundCaret(value: value, selection: NSRange(location: 5_000, length: 0))
        XCTAssertEqual(field?.before, String(repeating: "a", count: TextAroundCaret.contextLength))
        XCTAssertEqual(field?.after, String(repeating: "b", count: TextAroundCaret.lookaheadLength))
    }

    func testWindowEdgesNeverTearAnEmoji() {
        // The emoji's two UTF-16 units sit at 0 and 1; the window starts at 1, inside it.
        let leading = "😀" + String(repeating: "a", count: TextAroundCaret.contextLength - 1)
        let caret = (leading as NSString).length
        XCTAssertEqual(TextAroundCaret(value: leading, selection: NSRange(location: caret, length: 0))?.before,
                       String(repeating: "a", count: TextAroundCaret.contextLength - 1))

        // The window ends at 1 + lookahead, which falls between the emoji's two units.
        let trailing = "x" + String(repeating: "a", count: TextAroundCaret.lookaheadLength - 1) + "😀b"
        XCTAssertEqual(TextAroundCaret(value: trailing, selection: NSRange(location: 1, length: 0))?.after,
                       String(repeating: "a", count: TextAroundCaret.lookaheadLength - 1))
    }

    // MARK: - Fetching only a window

    func testWindowCoversTheContextAndAMarginAroundTheSelection() {
        let margin = TextAroundCaret.edgeMargin
        XCTAssertEqual(TextAroundCaret.window(around: NSRange(location: 5_000, length: 10), length: 10_000),
                       NSRange(location: 5_000 - TextAroundCaret.contextLength - margin,
                               length: TextAroundCaret.contextLength + 10 + TextAroundCaret.lookaheadLength + 2 * margin))
    }

    func testWindowStopsAtTheEndsOfTheField() {
        XCTAssertEqual(TextAroundCaret.window(around: NSRange(location: 3, length: 0), length: 10),
                       NSRange(location: 0, length: 10))
    }

    func testWindowOfASelectionOutsideTheFieldIsNil() {
        XCTAssertNil(TextAroundCaret.window(around: NSRange(location: 11, length: 0), length: 10))
        XCTAssertNil(TextAroundCaret.window(around: NSRange(location: 8, length: 3), length: 10))
        XCTAssertNil(TextAroundCaret.window(around: NSRange(location: NSNotFound, length: 0), length: 10))
    }

    /// Reading only the window must give what reading the whole value gives, emoji at the cut
    /// edges included.
    func testAWindowSplitsLikeTheWholeValue() {
        let context = TextAroundCaret.contextLength, lookahead = TextAroundCaret.lookaheadLength
        let values: [(String, NSRange)] = [
            ("Hello world", NSRange(location: 5, length: 0)),
            (String(repeating: "a", count: 5_000) + String(repeating: "b", count: 5_000),
             NSRange(location: 5_000, length: 3)),
            ("xxx😀" + String(repeating: "a", count: context - 1),
             NSRange(location: 5 + context - 1, length: 0)),
            ("xxx" + String(repeating: "a", count: lookahead - 1) + "😀b" + String(repeating: "c", count: 50),
             NSRange(location: 3, length: 0)),
            ("👨‍👩‍👧‍👦" + String(repeating: "a", count: context) + "👨‍👩‍👧‍👦",
             NSRange(location: ("👨‍👩‍👧‍👦" as NSString).length + context, length: 0)),
        ]
        for (value, selection) in values {
            let text = value as NSString
            let window = TextAroundCaret.window(around: selection, length: text.length)!
            XCTAssertEqual(TextAroundCaret(window: text.substring(with: window), at: window.location, selection: selection),
                           TextAroundCaret(value: value, selection: selection))
        }
    }

    // MARK: - Preparing the text

    func testSettingOffNeverReadsTheField() {
        var reads = 0
        let text = TranscriptInserter.prepared("Tomorrow at noon.", fitToField: false, language: "en",
                                               readField: { reads += 1; return TextAroundCaret(before: "Meet ") })
        XCTAssertEqual(text, .init("Tomorrow at noon. "))
        XCTAssertEqual(reads, 0)
    }

    func testUnreadableFieldGetsTheTextAsBefore() {
        XCTAssertEqual(TranscriptInserter.prepared("Tomorrow at noon.", fitToField: true, language: "en",
                                                   readField: { nil }),
                       .init("Tomorrow at noon. "))
    }

    func testReadableFieldGetsTheTextFitted() {
        let field = TextAroundCaret(before: "The review is", after: " if that suits you.")
        XCTAssertEqual(TranscriptInserter.prepared("Tomorrow at noon.", fitToField: true, language: "en",
                                                   readField: { field }),
                       .init(fitted: " tomorrow at noon", standalone: "Tomorrow at noon. "))
    }

    func testGermanKeepsItsCapitalsButStillLosesThePeriod() {
        let field = TextAroundCaret(before: "Ich habe den", after: " schon verschoben.")
        XCTAssertEqual(TranscriptInserter.prepared("Termin morgen.", fitToField: true, language: "de",
                                                   readField: { field }).fitted,
                       " Termin morgen")
    }

    func testAutoDetectGuessesTheLanguageFromTheFieldAndTheDictation() {
        let german = TextAroundCaret(before: "Wir haben gestern lange darüber gesprochen, und ich habe den ")
        XCTAssertEqual(TranscriptInserter.prepared("Termin auf morgen verschoben.", fitToField: true,
                                                   language: "auto", readField: { german }).fitted,
                       "Termin auf morgen verschoben.")
        let english = TextAroundCaret(before: "We talked about it for a long time yesterday, and I moved the ")
        XCTAssertEqual(TranscriptInserter.prepared("Meeting to tomorrow.", fitToField: true,
                                                   language: nil, readField: { english }).fitted,
                       "meeting to tomorrow.")
    }

    func testFittingKeepsTheRunOnSentenceFix() {
        let field = TextAroundCaret(before: "Done. ")
        XCTAssertEqual(TranscriptInserter.prepared("It works.Using it now.", fitToField: true, language: "en",
                                                   readField: { field }).fitted,
                       "It works. Using it now.")
    }

    func testDictionaryTermsAreProperNounsOnlyWhileTheDictionaryIsOn() {
        prefs.customDictionaryEntries = [CustomDictionaryEntry(original: "cooper netties", replacement: "Kubernetes")]
        let field = TextAroundCaret(before: "Then ")

        prefs.customDictionaryEnabled = true
        XCTAssertEqual(TranscriptInserter.prepared("Kubernetes restarted.", fitToField: true, language: "en",
                                                   readField: { field }).fitted,
                       "Kubernetes restarted.")

        prefs.customDictionaryEnabled = false
        XCTAssertEqual(TranscriptInserter.prepared("Kubernetes restarted.", fitToField: true, language: "en",
                                                   readField: { field }).fitted,
                       "kubernetes restarted.")
    }
}
