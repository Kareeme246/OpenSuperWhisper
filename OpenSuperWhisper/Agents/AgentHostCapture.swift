import AppKit
import Darwin

/// Where the agent runs, read by the hook: the app to bring back to the front, and for Warp the
/// link to the exact pane. Only the hook can see this (it inherits the terminal's environment and
/// sits in its process tree), so it is captured when the request is written; by the time the
/// user clicks, the panel only has the request file.
///
/// Nothing else from the environment is kept: request files sit on disk, and an environment can
/// hold tokens.
enum AgentHostCapture {
    struct Host: Equatable {
        var focusURL: URL?
        var bundleID: String?
        var pid: Int32?
    }

    /// Warp's link schemes, one per build: stable, Preview, and the open-source one.
    static let focusSchemes: Set<String> = ["warp", "warppreview", "warposs"]
    static let focusHost = "session"
    /// A pane's session id is a UUID written as 32 hex digits, without dashes.
    static let sessionIDLength = 32
    static let warpBundlePrefix = "dev.warp."
    /// The chain from the hook to its terminal is a handful of processes (the agent, a shell or
    /// two, the terminal's own helper); the limit only guards against a cycle.
    static let maxProcessDepth = 64

    static func capture(environment: [String: String], from pid: Int32 = getppid(),
                        processes: ProcessTable = LiveProcessTable()) -> Host {
        let app = hostApp(above: pid, in: processes)
        // The walk can break before reaching an app: a tmux, zellij or screen server is a daemon
        // whose parent is launchd. The bundle id LaunchServices gave the terminal's shell is
        // still in the environment then, without a pid; when both are there, the walk wins,
        // since an editor started from a terminal inherits the terminal's.
        let bundleID = app?.bundleID ?? environment["__CFBundleIdentifier"].flatMap { $0.isEmpty ? nil : $0 }
        // The link, though, only from a walk that reached Warp itself: a broken chain means a
        // server in between, started from some pane whose link every later session inherits.
        let inWarpPane = isWarpPane(environment: environment, walkedToBundleID: app?.bundleID)
        return Host(focusURL: inWarpPane ? focusURL(environment["WARP_FOCUS_URL"]) : nil,
                    bundleID: bundleID, pid: app?.pid)
    }

    /// `warp://session/<32 hex>` and nothing else: no other host, no further path, no query,
    /// no user or port. The panel opens this URL, and a request file can be written by anyone,
    /// so it must not be a way to fire Warp's other link actions. Rebuilt from its parts so
    /// what gets opened is exactly what was checked.
    static func focusURL(_ text: String?) -> URL? {
        guard let text, let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), focusSchemes.contains(scheme),
              components.host?.lowercased() == focusHost,
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil else { return nil }
        let path = components.path
        guard path.hasPrefix("/") else { return nil }
        let id = path.dropFirst()
        guard id.count == sessionIDLength, id.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return URL(string: "\(scheme)://\(focusHost)/\(id)")
    }

    /// Warp's link is only good for a shell Warp itself started. Everything launched from that
    /// shell inherits the variable: an editor opened with `code .` (whose terminal would then
    /// send the user to Warp instead of the editor), a tmux or zellij server (whose panes all
    /// carry the link of whichever pane started the server).
    static func isWarpPane(environment: [String: String], walkedToBundleID: String?) -> Bool {
        if isInEditor(environment: environment) || isInMultiplexer(environment: environment) { return false }
        if let program = environment["TERM_PROGRAM"], program != "WarpTerminal" { return false }
        return walkedToBundleID?.hasPrefix(warpBundlePrefix) == true
    }

    /// VS Code and its forks (Cursor, Windsurf) set TERM_PROGRAM and their own VSCODE_ variables
    /// in their integrated terminal.
    static func isInEditor(environment: [String: String]) -> Bool {
        environment["TERM_PROGRAM"] == "vscode" || environment.keys.contains { $0.hasPrefix("VSCODE_") }
    }

    /// GNU screen's `STY` too: unlike tmux it leaves TERM_PROGRAM as Warp set it.
    static func isInMultiplexer(environment: [String: String]) -> Bool {
        environment["TMUX"] != nil || environment["ZELLIJ"] != nil || environment["STY"] != nil
    }

    /// The first app up the process tree from `pid`. Shells, the agent and helpers are passed
    /// over: Warp's shells hang off its terminal server, a second copy of its binary that is
    /// not the app the user switches to.
    static func hostApp(above pid: Int32, in processes: ProcessTable) -> (pid: Int32, bundleID: String)? {
        var current = pid
        for _ in 0..<maxProcessDepth {
            guard current > 1 else { return nil }
            if let bundleID = processes.appBundleID(of: current) { return (current, bundleID) }
            guard let parent = processes.parent(of: current), parent != current else { return nil }
            current = parent
        }
        return nil
    }
}

/// The process tree, as the hook walks it.
protocol ProcessTable {
    func parent(of pid: Int32) -> Int32?
    /// The bundle id of `pid` when it is an app with a Dock icon, nil for anything else.
    func appBundleID(of pid: Int32) -> String?
}

struct LiveProcessTable: ProcessTable {
    func parent(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(bitPattern: info.pbi_ppid)
    }

    func appBundleID(of pid: Int32) -> String? {
        guard let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular else { return nil }
        return app.bundleIdentifier
    }
}
