import XCTest
@testable import OpenSuperWhisper

/// The panel's "Open in terminal": what the hook keeps of where the agent runs, and what a click
/// does with it. The link is opened as is, so what passes for a pane link is pinned; nothing
/// here opens a URL or raises an app.
final class AgentHostTests: XCTestCase {
    private let paneID = "0123456789abcdef0123456789ABCDEF"
    private var paneLink: String { "warp://session/\(paneID)" }

    /// A Warp tab: its shell hangs off the terminal server, a helper, under the app.
    private let warpTree = FakeProcessTable(
        parents: [500: 400, 400: 300, 300: 200, 200: 1],
        apps: [200: "dev.warp.Warp-Stable"])

    private var warpEnvironment: [String: String] {
        ["WARP_FOCUS_URL": paneLink, "TERM_PROGRAM": "WarpTerminal",
         "__CFBundleIdentifier": "dev.warp.Warp-Stable", "HOME": "/Users/me", "API_TOKEN": "secret"]
    }

    // MARK: The link

    func testAPaneLinkFromEachWarpBuildIsKept() {
        for scheme in ["warp", "warppreview", "warposs"] {
            XCTAssertEqual(AgentHostCapture.focusURL("\(scheme)://session/\(paneID)")?.absoluteString,
                           "\(scheme)://session/\(paneID)")
        }
    }

    func testAnythingButAPaneLinkIsDropped() {
        let rejected = [
            "https://session/\(paneID)",  // another scheme
            "file:///session/\(paneID)",
            "warp://action/new_tab?path=/tmp",  // another of Warp's actions
            "warp://shared_session/\(paneID)",
            "warp://session/\(paneID.dropLast())",  // too short
            "warp://session/\(paneID)0",  // too long
            "warp://session/0123456789abcdef0123456789abcdeg",  // not hex
            "warp://session/\(paneID)/extra",
            "warp://session/extra/\(paneID)",
            "warp://session/\(paneID)?command=rm",
            "warp://session/\(paneID)#x",
            "warp://user@session/\(paneID)",
            "warp://session:80/\(paneID)",
            "warp://session",
            "",
            // What URL parsing decodes or tolerates, which a check on the raw text would miss.
            "warp://session/\(paneID)/",
            "warp://session//\(paneID)",
            "warp://session/\(paneID)%2F",
            "warp://session/\(paneID)%3Fa=b",
            "warp://session/\(paneID)?",
            "warp://session/\(paneID)#",
            "warp://@session/\(paneID)",
            "warp://session/\(paneID.dropLast())\u{FF10}",  // a fullwidth zero
            "warp://session./\(paneID)",
        ]
        for link in rejected {
            XCTAssertNil(AgentHostCapture.focusURL(link), link)
        }
        XCTAssertNil(AgentHostCapture.focusURL(nil))
    }

    /// What gets opened is rebuilt from the parts that were checked, never the text as given.
    func testAnAcceptedLinkIsRebuiltInItsPlainForm() {
        let accepted = [
            "WARP://SESSION/\(paneID)",
            "warp://session/%30\(paneID.dropFirst())",
            "warp://sess%69on/\(paneID)",
            "warp://session:/\(paneID)",
        ]
        for link in accepted {
            XCTAssertEqual(AgentHostCapture.focusURL(link)?.absoluteString, paneLink, link)
        }
    }

    // MARK: Capture

    func testAWarpTabGivesItsLinkAndTheAppAboveTheHelpers() {
        let host = AgentHostCapture.capture(environment: warpEnvironment, from: 500, processes: warpTree)
        XCTAssertEqual(host.focusURL?.absoluteString, paneLink)
        XCTAssertEqual(host.bundleID, "dev.warp.Warp-Stable")
        XCTAssertEqual(host.pid, 200)
    }

    func testAnEditorStartedFromWarpGetsNoLink() {
        let editorTree = FakeProcessTable(parents: [500: 400, 400: 300, 300: 1],
                                          apps: [300: "com.microsoft.VSCode"])
        var environment = warpEnvironment
        environment["TERM_PROGRAM"] = "vscode"
        var host = AgentHostCapture.capture(environment: environment, from: 500, processes: editorTree)
        XCTAssertNil(host.focusURL)
        XCTAssertEqual(host.bundleID, "com.microsoft.VSCode", "the editor still comes to the front")
        XCTAssertEqual(host.pid, 300)

        // A fork that leaves TERM_PROGRAM alone still sets its VSCODE_ variables.
        environment["TERM_PROGRAM"] = nil
        environment["VSCODE_GIT_IPC_HANDLE"] = "/tmp/vscode-git.sock"
        host = AgentHostCapture.capture(environment: environment, from: 500, processes: warpTree)
        XCTAssertNil(host.focusURL)
    }

    func testAnotherAppUpTheTreeGetsNoLink() {
        let iTermTree = FakeProcessTable(parents: [500: 400, 400: 1], apps: [400: "com.googlecode.iterm2"])
        var environment = warpEnvironment
        environment["TERM_PROGRAM"] = nil
        let host = AgentHostCapture.capture(environment: environment, from: 500, processes: iTermTree)
        XCTAssertNil(host.focusURL)
        XCTAssertEqual(host.bundleID, "com.googlecode.iterm2")
    }

    /// The multiplexer's server is a daemon: the walk ends at launchd, and only the bundle id
    /// left in the environment says which app to bring forward.
    func testInsideTmuxOrZellijOnlyTheAppIsKept() {
        let detached = FakeProcessTable(parents: [500: 400, 400: 1], apps: [:])
        for (key, value) in [("TMUX", "/tmp/tmux-501/default,123,0"), ("ZELLIJ", "0")] {
            var environment = warpEnvironment
            environment[key] = value
            let host = AgentHostCapture.capture(environment: environment, from: 500, processes: detached)
            XCTAssertNil(host.focusURL, key)
            XCTAssertEqual(host.bundleID, "dev.warp.Warp-Stable", key)
            XCTAssertNil(host.pid, key)
        }
        // tmux attached from Warp also sets its own TERM_PROGRAM.
        var environment = warpEnvironment
        environment["TERM_PROGRAM"] = "tmux"
        XCTAssertNil(AgentHostCapture.capture(environment: environment, from: 500, processes: warpTree).focusURL)
    }

    /// GNU screen, dtach, or an agent left to launchd: the chain breaks before Warp, as with
    /// tmux, but nothing in the environment says so. The link is then the one of the pane that
    /// started it, so only the app is kept.
    func testAWalkThatNeverReachesWarpKeepsOnlyTheApp() {
        let detached = FakeProcessTable(parents: [500: 400, 400: 1], apps: [:])
        let host = AgentHostCapture.capture(environment: warpEnvironment, from: 500, processes: detached)
        XCTAssertNil(host.focusURL)
        XCTAssertEqual(host.bundleID, "dev.warp.Warp-Stable")
        XCTAssertNil(host.pid)

        var environment = warpEnvironment
        environment["STY"] = "1234.ttys001.mac"
        XCTAssertNil(AgentHostCapture.capture(environment: environment, from: 500, processes: warpTree).focusURL)
    }

    func testNothingKnownMeansNoHost() {
        let host = AgentHostCapture.capture(environment: ["HOME": "/Users/me"], from: 500,
                                            processes: FakeProcessTable(parents: [500: 1], apps: [:]))
        XCTAssertEqual(host, AgentHostCapture.Host())
    }

    func testTheWalkStopsAtLaunchdACycleOrADeadEnd() {
        XCTAssertNil(AgentHostCapture.hostApp(above: 1, in: FakeProcessTable(parents: [:], apps: [1: "x"])))
        XCTAssertNil(AgentHostCapture.hostApp(above: 500, in: FakeProcessTable(parents: [500: 400, 400: 500], apps: [:])))
        XCTAssertNil(AgentHostCapture.hostApp(above: 500, in: FakeProcessTable(parents: [500: 500], apps: [:])))
        XCTAssertNil(AgentHostCapture.hostApp(above: 500, in: FakeProcessTable(parents: [:], apps: [:])))
        let found = AgentHostCapture.hostApp(above: 500, in: warpTree)
        XCTAssertEqual(found?.pid, 200)
        XCTAssertEqual(found?.bundleID, "dev.warp.Warp-Stable")
    }

    /// The real process tree, read for this test process.
    func testTheLiveTableReadsThisProcesssParent() {
        XCTAssertEqual(LiveProcessTable().parent(of: getpid()), getppid())
        XCTAssertNil(LiveProcessTable().parent(of: -1))
    }

    /// Written by the real hook path, with this process's own environment: only the three
    /// host fields join the request, never the variables they came from.
    func testTheRequestFileHoldsTheHostAndNothingElseOfTheEnvironment() throws {
        // A whole second: a date with a fraction can come back a hair off through the file.
        var request = try XCTUnwrap(AgentHookCommand.makeStopRequest(
            from: try JSONSerialization.data(withJSONObject: ["session_id": "s", "cwd": "/p"]),
            now: Date(timeIntervalSince1970: 1_000)))
        request.focusURL = paneLink
        request.hostBundleID = "dev.warp.Warp-Stable"
        request.hostPID = 200
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("osw-agent-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try AgentBridge.write(request, to: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let known: Set<String> = ["id", "kind", "agent", "sessionID", "title", "cwd", "message", "createdAt",
                                  "expiresAt", "hookPID", "tool", "toolDetail", "questions", "source",
                                  "focusURL", "hostBundleID", "hostPID"]
        XCTAssertTrue(Set(json.keys).isSubset(of: known), "\(Set(json.keys).subtracting(known))")
        XCTAssertEqual(AgentBridge.read(AgentRequest.self, from: url), request)
    }

    // MARK: Older request files

    func testARequestFromAnOlderHookStillDecodes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("osw-agent-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("""
            {"id":"a","kind":"stop","agent":"Claude Code","sessionID":"s","cwd":"/p","message":"Done.",
             "createdAt":1000,"expiresAt":1600,"hookPID":42}
            """.utf8).write(to: url)
        let request = try XCTUnwrap(AgentBridge.read(AgentRequest.self, from: url))
        XCTAssertNil(request.focusURL)
        XCTAssertNil(request.hostBundleID)
        XCTAssertNil(request.hostPID)
        XCTAssertNil(AgentHostJump.target(for: request), "no button for it")
    }

    // MARK: The click

    private func request(focusURL: String? = nil, bundleID: String? = nil, pid: Int32? = nil) -> AgentRequest {
        var request = AgentRequest(id: "r", kind: .stop, agent: "Claude Code", sessionID: "s", cwd: "/p",
                                   message: "", createdAt: Date(), expiresAt: Date(), hookPID: 1)
        request.focusURL = focusURL
        request.hostBundleID = bundleID
        request.hostPID = pid
        return request
    }

    @MainActor
    func testWithALinkTheAppComesForwardAndThePaneOpens() {
        let opener = FakeOpener()
        XCTAssertTrue(AgentHostJump.open(request(focusURL: paneLink, bundleID: "dev.warp.Warp-Stable", pid: 200),
                                         with: opener))
        XCTAssertEqual(opener.calls, [.activate(pid: 200, bundleID: "dev.warp.Warp-Stable"),
                                      .open(URL(string: paneLink)!)])
    }

    @MainActor
    func testWithoutALinkOnlyTheAppComesForward() {
        let opener = FakeOpener()
        XCTAssertTrue(AgentHostJump.open(request(bundleID: "com.apple.Terminal", pid: 300), with: opener))
        XCTAssertEqual(opener.calls, [.activate(pid: 300, bundleID: "com.apple.Terminal")])

        let byBundle = FakeOpener()
        XCTAssertTrue(AgentHostJump.open(request(bundleID: "com.apple.Terminal"), with: byBundle))
        XCTAssertEqual(byBundle.calls, [.activate(pid: nil, bundleID: "com.apple.Terminal")])
    }

    @MainActor
    func testAForgedLinkIsNotOpened() {
        let opener = FakeOpener()
        XCTAssertTrue(AgentHostJump.open(request(focusURL: "warp://action/new_tab?path=/", bundleID: "dev.warp.Warp-Stable"),
                                         with: opener))
        XCTAssertEqual(opener.calls, [.activate(pid: nil, bundleID: "dev.warp.Warp-Stable")])

        let alone = FakeOpener()
        XCTAssertFalse(AgentHostJump.open(request(focusURL: "https://example.com"), with: alone))
        XCTAssertEqual(alone.calls, [])
    }

    @MainActor
    func testALinkAloneIsOpened() {
        let opener = FakeOpener()
        XCTAssertTrue(AgentHostJump.open(request(focusURL: paneLink), with: opener))
        XCTAssertEqual(opener.calls, [.open(URL(string: paneLink)!)])
    }

    @MainActor
    func testNothingKnownDoesNothing() {
        let opener = FakeOpener()
        XCTAssertFalse(AgentHostJump.open(request(), with: opener))
        XCTAssertEqual(opener.calls, [])
    }
}

private struct FakeProcessTable: ProcessTable {
    let parents: [Int32: Int32]
    let apps: [Int32: String]

    func parent(of pid: Int32) -> Int32? { parents[pid] }
    func appBundleID(of pid: Int32) -> String? { apps[pid] }
}

@MainActor
private final class FakeOpener: AgentHostOpening {
    enum Call: Equatable {
        case activate(pid: Int32?, bundleID: String?)
        case open(URL)
    }

    private(set) var calls: [Call] = []

    func activate(pid: Int32?, bundleID: String?) -> Bool {
        calls.append(.activate(pid: pid, bundleID: bundleID))
        return true
    }

    func open(_ url: URL) { calls.append(.open(url)) }
}
