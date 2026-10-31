import AppKit
import ApplicationServices
import ZoopShared

enum Apps {
    /// Never quit by quitAll: the agent session needs Finder for its desktop.
    static let alwaysKept: Set<String> = ["com.apple.finder"]

    /// Politely asks every regular app (one with a Dock icon) to quit, then waits up to
    /// `wait` for them to go. No force quit: an app asking to save changes stays open and
    /// is reported in `stillOpen`.
    @MainActor static func quitAll(keeping kept: Set<String>, wait: Duration = .seconds(8)) async -> QuitAppsReport {
        let own = ProcessInfo.processInfo.processIdentifier
        let ownBundle = Bundle.main.bundleIdentifier
        let targets = NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular, !app.isTerminated, app.processIdentifier != own else { return false }
            let id = app.bundleIdentifier ?? ""
            return id != ownBundle && !alwaysKept.contains(id) && !kept.contains(id)
        }
        for app in targets { app.terminate() }
        let deadline = ContinuousClock.now + wait
        while targets.contains(where: { !$0.isTerminated }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        func info(_ app: NSRunningApplication) -> AppInfo {
            AppInfo(bundleID: app.bundleIdentifier ?? "", name: app.localizedName ?? app.bundleIdentifier ?? "app",
                    pid: Int(app.processIdentifier), isActive: app.isActive)
        }
        return QuitAppsReport(quit: targets.filter(\.isTerminated).map(info),
                              stillOpen: targets.filter { !$0.isTerminated }.map(info))
    }

    @MainActor static func open(_ bundleID: String) async throws -> AppInfo {
        // Do not reopen an already focused app: doing so can dismiss the menu or sheet
        // that a named click is about to use.
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           app.isFinishedLaunching, !app.isTerminated, !app.isHidden,
           AXElement.focusedApp()?.pid == app.processIdentifier {
            return AppInfo(bundleID: bundleID, name: app.localizedName ?? bundleID,
                           pid: Int(app.processIdentifier), isActive: app.isActive)
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw HelperFailure(.notFound, "no installed app with bundle id \(bundleID)")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        let deadline = ContinuousClock.now + .seconds(10)
        while !app.isFinishedLaunching, !app.isTerminated, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard app.isFinishedLaunching, !app.isTerminated else {
            throw HelperFailure(.internalError, "\(bundleID) did not finish launching")
        }
        // Activation is local to this helper's login session. Also ask AX for the app's
        // key/main window: background apps do not always get one from NSWorkspace alone.
        if AXIsProcessTrusted() {
            let element = AXElement(AXUIElementCreateApplication(app.processIdentifier))
            _ = element.set(kAXFrontmostAttribute, kCFBooleanTrue)
            if let window = element.element(kAXFocusedWindowAttribute) ?? element.element(kAXMainWindowAttribute)
                ?? element.attribute(kAXWindowsAttribute).flatMap({ ($0 as? [AXUIElement])?.first }).map(AXElement.init) {
                _ = window.set(kAXMainAttribute, kCFBooleanTrue)
                if window.actions.contains(kAXRaiseAction) { _ = window.perform(kAXRaiseAction) }
            }
        }
        return AppInfo(bundleID: bundleID, name: app.localizedName ?? bundleID,
                       pid: Int(app.processIdentifier), isActive: app.isActive)
    }
}
