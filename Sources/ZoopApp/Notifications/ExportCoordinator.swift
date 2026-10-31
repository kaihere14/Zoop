import AppKit
import UniformTypeIdentifiers
import ZoopAgents
import ZoopShared

@MainActor
final class ExportCoordinator {
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Zoop/exports", isDirectory: true)

    func write(_ task: CompanionTask) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Only a generated basename is used; a request can never supply a filesystem path.
        let basename = URL(fileURLWithPath: task.fileName).lastPathComponent
        let destination = directory.appendingPathComponent(basename)
        try DemoResearch.report(for: task).write(to: destination, atomically: true, encoding: .utf8)
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
                    try DemoResearch.report(for: task).write(to: url, atomically: true, encoding: .utf8)
                    completion(nil)
                } catch { completion(error) }
            }
        }
    }

    func revealExports() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }
}
