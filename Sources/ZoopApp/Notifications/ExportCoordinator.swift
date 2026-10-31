import AppKit
import UniformTypeIdentifiers
import ZoopAgents
import ZoopShared

@MainActor
final class ExportCoordinator {
    let directory: URL
    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Zoop/exports", isDirectory: true)) {
        self.directory = directory
    }

    func write(_ task: CompanionTask) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Only a generated basename is used; a request can never supply a filesystem path.
        let basename = URL(fileURLWithPath: task.fileName).lastPathComponent
        let destination = directory.appendingPathComponent(basename)
        try Self.report(for: task).write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    func saveAs(_ task: CompanionTask, completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = task.fileName
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                do {
                    try Self.report(for: task).write(to: url, atomically: true, encoding: .utf8)
                    completion(nil)
                } catch { completion(error) }
            }
        }
    }

    static func report(for task: CompanionTask) -> String {
        if let report = task.reportMarkdown { return report }
        if let summary = task.resultSummary { return "# \(task.title)\n\n\(summary)\n" }
        return "# \(task.title)\n\nNo completed result is available.\n"
    }

    func revealExports() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }
}
