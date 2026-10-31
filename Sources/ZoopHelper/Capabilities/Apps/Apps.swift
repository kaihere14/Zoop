import AppKit
import ZoopShared

enum Apps {
    @MainActor static func open(_ bundleID: String) async throws -> AppInfo {
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
        return AppInfo(bundleID: bundleID, name: app.localizedName ?? bundleID,
                       pid: Int(app.processIdentifier), isActive: app.isActive)
    }
}
