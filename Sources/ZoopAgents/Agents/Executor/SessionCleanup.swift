import Foundation
import ZoopShared

/// Quits apps in the agent session. `HelperConnection` is the real one; tests use a fake.
public protocol SessionCleaning: Sendable {
    func quitApps(keeping: [String]) async throws -> QuitAppsReport
}

extension HelperConnection: SessionCleaning {}

/// After a successful task, quit every app in the agent session (except Finder) so the
/// next task starts from a clean desktop. Failed and cancelled tasks keep their apps open,
/// so the person can see what happened and resume.
public enum SessionCleanup {
    /// Returns `outcome` with a note about the cleanup added to its summary. Cleanup never
    /// changes the task's status: a task that succeeded still succeeded.
    public static func afterTask(_ outcome: AgentOutcome, using cleaner: (any SessionCleaning)?) async -> AgentOutcome {
        guard outcome.status == .completed, let cleaner else { return outcome }
        var result = outcome
        let note: String
        do {
            note = describe(try await cleaner.quitApps(keeping: []))
        } catch {
            note = "Could not close the agent session's apps: \(error)."
        }
        if !note.isEmpty { result.summary += (result.summary.isEmpty ? "" : "\n\n") + note }
        return result
    }

    static func describe(_ report: QuitAppsReport) -> String {
        var lines: [String] = []
        if !report.quit.isEmpty { lines.append("Closed \(names(report.quit)).") }
        if !report.stillOpen.isEmpty {
            lines.append("Still open: \(names(report.stillOpen)). It may be asking whether to save changes; nothing was discarded.")
        }
        return lines.joined(separator: " ")
    }

    private static func names(_ apps: [AppInfo]) -> String {
        apps.map(\.name).joined(separator: ", ")
    }
}
