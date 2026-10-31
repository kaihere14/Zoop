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
        try data.write(to: directory.appendingPathComponent("companion-state.json"), options: .atomic)
    }
}
