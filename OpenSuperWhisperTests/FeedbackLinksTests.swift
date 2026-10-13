import SwiftUI
import XCTest

@testable import OpenSuperWhisper

/// The feedback links are offered twice, in Help & what's new and in the sidebar's Feedback
/// menu. They live in one list so the two cannot drift; these pin the list and that both places
/// draw from it.
final class FeedbackLinksTests: XCTestCase {

    func testTheThreeLinksPointWhereTheySay() {
        XCTAssertEqual(FeedbackLink.all.map(\.url.absoluteString), [
            "https://github.com/my-monkeys/OpenSuperWhisper/issues/new",
            "https://opensuperwhisper.com/#feedback",
            "https://github.com/my-monkeys/OpenSuperWhisper/releases",
        ])
    }

    func testEachLinkHasItsOwnIdentity() {
        XCTAssertEqual(Set(FeedbackLink.all.map(\.id)).count, FeedbackLink.all.count)
        XCTAssertEqual(FeedbackLink.all.map(\.symbol), ["ladybug", "bubble.left.and.bubble.right", "testtube.2"])
    }

    func testTheTitlesAreTheCatalogKeys() {
        XCTAssertEqual(FeedbackLink.all.map(\.title), [
            LocalizedStringKey("Report a bug"),
            LocalizedStringKey("Send feedback or an idea"),
            LocalizedStringKey("Try a beta build"),
        ])
    }

    /// A second hand-written copy is how the two lists would drift: both have to read the shared one.
    func testHelpAndTheSidebarMenuShareTheList() throws {
        let shell = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("OpenSuperWhisper/Shell")
        for file in ["HelpOverlay.swift", "FeedbackMenu.swift"] {
            let source = try String(contentsOf: shell.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(source.contains("FeedbackLink.all"), "\(file) does not draw from the shared list")
            XCTAssertFalse(source.contains("issues/new"), "\(file) keeps its own copy of a feedback link")
        }
        let sidebar = try String(contentsOf: shell.appendingPathComponent("AppSidebar.swift"), encoding: .utf8)
        XCTAssertTrue(sidebar.contains("FeedbackMenu"), "the sidebar no longer opens the Feedback menu")
    }
}
