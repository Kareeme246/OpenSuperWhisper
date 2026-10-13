import XCTest
@testable import OpenSuperWhisper

/// What the agent panel's reply bar shows of the live transcript while a reply is dictated.
/// The bar has room for two lines at most and must never grow, so only the end of a take is kept.
final class AgentLiveCaptionTests: XCTestCase {

    func testNothingHeardKeepsTheListeningLabel() {
        XCTAssertNil(AgentLiveCaption(confirmed: "", volatile: ""))
        XCTAssertNil(AgentLiveCaption(confirmed: "  ", volatile: "\n"))
    }

    func testConfirmedAndVolatileReadAsOneSentence() throws {
        let caption = try XCTUnwrap(AgentLiveCaption(confirmed: "Yes, open the PR ", volatile: " and ask"))
        XCTAssertEqual(caption.confirmed, "Yes, open the PR")
        XCTAssertEqual(caption.volatile, "and ask")
        XCTAssertEqual(caption.spoken, "Yes, open the PR and ask")
    }

    /// The first words arrive as a volatile tail alone; no leading space before them.
    func testAVolatileTailAloneHasNoSeparator() throws {
        let caption = try XCTUnwrap(AgentLiveCaption(confirmed: "", volatile: "Yes"))
        XCTAssertEqual(caption.separator, "")
        XCTAssertEqual(caption.spoken, "Yes")
    }

    func testAShortTakeIsKeptWhole() throws {
        let caption = try XCTUnwrap(AgentLiveCaption(confirmed: "one two three", volatile: "four", limit: 40))
        XCTAssertEqual(caption.spoken, "one two three four")
    }

    /// A long take keeps its end, starting on a whole word, and the still-changing tail intact.
    func testALongTakeKeepsItsEndFromAWholeWord() throws {
        let caption = try XCTUnwrap(AgentLiveCaption(confirmed: "alpha bravo charlie delta echo",
                                                     volatile: "foxtrot", limit: 20))
        XCTAssertEqual(caption.volatile, "foxtrot")
        XCTAssertEqual(caption.confirmed, "delta echo")
        XCTAssertLessThanOrEqual(caption.spoken.count, 20)
    }

    func testTheTailStartsOnAWholeWord() {
        XCTAssertEqual(AgentLiveCaption.tail(of: "alpha bravo charlie", limit: 10), "charlie")
        // The cut falls right after a space: the word there is whole and stays.
        XCTAssertEqual(AgentLiveCaption.tail(of: "alpha bravo charlie", limit: 13), "bravo charlie")
        XCTAssertEqual(AgentLiveCaption.tail(of: "short", limit: 10), "short")
    }

    /// One word longer than the room is cut rather than dropped, so the bar is never empty.
    func testAWordLongerThanTheLimitIsCut() {
        XCTAssertEqual(AgentLiveCaption.tail(of: "supercalifragilistic", limit: 6), "listic")
    }

    func testTwoLinesFitTheRowAtTheDefaultSize() {
        let line = AgentLiveCaption.lineHeight(pointSize: AgentLiveTranscript.fontSize)
        XCTAssertEqual(AgentLiveCaption.visibleLines(lineHeight: line, room: AgentRecordingControls.size), 2)
        XCTAssertLessThanOrEqual(line * 2, AgentRecordingControls.size)
    }

    /// Large text shows fewer lines instead of making the bar taller, and always at least one.
    func testLargeTextShowsOneLineRatherThanGrowingTheRow() {
        let large = AgentLiveTranscript.fontSize * CGFloat(TextScale.maximum)
        let line = AgentLiveCaption.lineHeight(pointSize: large)
        XCTAssertEqual(AgentLiveCaption.visibleLines(lineHeight: line, room: AgentRecordingControls.size), 1)
        XCTAssertEqual(AgentLiveCaption.visibleLines(lineHeight: 60, room: AgentRecordingControls.size), 1)
    }

    func testNeverMoreThanTwoLines() {
        XCTAssertEqual(AgentLiveCaption.visibleLines(lineHeight: 8, room: 36), 2)
    }
}
