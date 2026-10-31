import Foundation
import ZoopShared

struct CompanionPersistence {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zoop", isDirectory: true)
    }

    func load() throws -> CompanionSnapshot {
        let file = directory.appendingPathComponent("companion-state.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return .init() }
        var snapshot = try JSONDecoder().decode(CompanionSnapshot.self, from: Data(contentsOf: file))
        snapshot.messages = Array(snapshot.messages.suffix(120))
        snapshot.tasks = Array(snapshot.tasks.suffix(40))
        snapshot.prepareForRestore()
        return snapshot
    }

    func save(_ snapshot: CompanionSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        let file = directory.appendingPathComponent("companion-state.json")
        let backup = directory.appendingPathComponent("companion-state.pre-live.json")
        if FileManager.default.fileExists(atPath: file.path), !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: file, to: backup)
        }
        try data.write(to: file, options: .atomic)
    }
}
