import AppKit

/// The panel's way back to the terminal an agent runs in: Warp's own link to the pane when the
/// hook found one, else the app brought to the front. The request stays waiting either way, so
/// the user can answer from the terminal or come back to the panel.
enum AgentHostJump {
    struct Target: Equatable {
        var focusURL: URL?
        var bundleID: String?
        var pid: Int32?
    }

    /// nil when the hook knew nothing of its host (an older hook, or no app up its process
    /// tree): the panel then has no button for it.
    static func target(for request: AgentRequest) -> Target? {
        // Checked again here: the request file is not to be trusted with what gets opened.
        let url = AgentHostCapture.focusURL(request.focusURL)
        guard url != nil || request.hostBundleID != nil || request.hostPID != nil else { return nil }
        return Target(focusURL: url, bundleID: request.hostBundleID, pid: request.hostPID)
    }

    /// Returns false when there is nowhere to go.
    @MainActor @discardableResult
    static func open(_ request: AgentRequest, with opener: AgentHostOpening = WorkspaceHostOpener()) -> Bool {
        guard let target = target(for: request) else { return false }
        // The app first, even with a link: Warp only logs a warning for a pane that has since
        // closed, and the user should still land in the terminal.
        if target.bundleID != nil || target.pid != nil {
            opener.activate(pid: target.pid, bundleID: target.bundleID)
        }
        if let url = target.focusURL { opener.open(url) }
        return true
    }
}

/// What the jump does to the rest of the Mac, behind a protocol so tests never raise a real app.
@MainActor
protocol AgentHostOpening {
    @discardableResult func activate(pid: Int32?, bundleID: String?) -> Bool
    func open(_ url: URL)
}

@MainActor
struct WorkspaceHostOpener: AgentHostOpening {
    /// Nonisolated so it can be `open`'s default argument.
    nonisolated init() {}

    /// The app with this pid when it is still the same app (a pid can be reused once it
    /// quits), else any running copy of the bundle.
    static func runningApp(pid: Int32?, bundleID: String?) -> NSRunningApplication? {
        if let pid, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
           bundleID == nil || app.bundleIdentifier == bundleID {
            return app
        }
        guard let bundleID else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
    }

    /// What the button's tooltip calls the host ("Open in Warp").
    static func appName(of target: AgentHostJump.Target) -> String? {
        if let app = runningApp(pid: target.pid, bundleID: target.bundleID), let name = app.localizedName {
            return name
        }
        let url = target.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            ?? target.focusURL.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
        return url.map { $0.deletingPathExtension().lastPathComponent }
    }

    /// The panel never activates OpenSuperWhisper, so the click leaves it inactive, and since
    /// macOS 14 activation is cooperative: an app may be refused when it raises another while
    /// not active itself. Yielding first hands our activation to the host; if the system still
    /// turns the request down, LaunchServices brings a running app forward the way the Dock or
    /// `open -a` would.
    @discardableResult
    func activate(pid: Int32?, bundleID: String?) -> Bool {
        guard let app = Self.runningApp(pid: pid, bundleID: bundleID) else { return false }
        NSApp.yieldActivation(to: app)
        if app.activate(from: .current, options: []) { return true }
        guard let url = app.bundleURL else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return true
    }

    /// Warp raises the window, picks the tab and focuses the pane itself; the yield lets it
    /// come forward while OpenSuperWhisper is not the active app.
    func open(_ url: URL) {
        if let handler = NSWorkspace.shared.urlForApplication(toOpen: url),
           let bundleID = Bundle(url: handler)?.bundleIdentifier {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundleID)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(url, configuration: configuration)
    }
}
