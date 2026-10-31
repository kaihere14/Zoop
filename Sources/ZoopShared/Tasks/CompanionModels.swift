import Foundation

public enum CompanionMood: String, Sendable {
    case idle, sleeping, thinking, cooking, done
}

public enum TaskPhase: String, Codable, CaseIterable, Sendable {
    case pending, dispatching, running, paused, complete, cancelled

    public var isLive: Bool { self == .running || self == .paused }
    public var isTerminal: Bool { self == .complete || self == .cancelled }
}

public enum ResearchKind: String, Codable, Sendable {
    case keyboards, getaway, tools
}

public enum TaskAction: Sendable {
    case approve, arrive, pause, resume, stop
}

public struct CompanionTask: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let request: String
    public let title: String
    public let domain: String
    public let fileName: String
    public let steps: [String]
    public let kind: ResearchKind
    public private(set) var phase: TaskPhase
    public private(set) var progress: Int

    public init(id: UUID = UUID(), request: String, title: String, domain: String,
                fileName: String, steps: [String], kind: ResearchKind,
                phase: TaskPhase = .pending, progress: Int = 0) {
        self.id = id
        self.request = request
        self.title = title
        self.domain = domain
        self.fileName = fileName
        self.steps = steps
        self.kind = kind
        self.phase = phase
        self.progress = min(100, max(0, progress))
    }

    /// Execution can only follow an explicitly approved plan.
    @discardableResult
    public mutating func apply(_ action: TaskAction) -> Bool {
        switch (phase, action) {
        case (.pending, .approve): phase = .dispatching
        case (.dispatching, .arrive): phase = .running
        case (.running, .pause): phase = .paused
        case (.paused, .resume): phase = .running
        case (.pending, .stop), (.dispatching, .stop), (.running, .stop), (.paused, .stop): phase = .cancelled
        default: return false
        }
        return true
    }

    public mutating func advance(by amount: Int) {
        guard phase == .running, amount > 0 else { return }
        progress = min(100, progress + amount)
        if progress == 100 { phase = .complete }
    }

    public mutating func prepareForRestore() {
        if phase == .running || phase == .dispatching { phase = .paused }
    }
}

public struct CompanionMessage: Identifiable, Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public let id: UUID
    public let role: Role
    public let text: String
    public let taskID: UUID?

    public init(id: UUID = UUID(), role: Role, text: String, taskID: UUID? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.taskID = taskID
    }
}

public struct CompanionSnapshot: Codable, Sendable {
    public var messages: [CompanionMessage]
    public var tasks: [CompanionTask]
    public var soundEnabled: Bool

    public init(messages: [CompanionMessage] = [], tasks: [CompanionTask] = [], soundEnabled: Bool = true) {
        self.messages = messages
        self.tasks = tasks
        self.soundEnabled = soundEnabled
    }

    public mutating func prepareForRestore() {
        for index in tasks.indices { tasks[index].prepareForRestore() }
    }
}

public struct ComparisonRow: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let detail: String
    public let metric: String
    public let price: String

    public init(name: String, detail: String, metric: String, price: String) {
        self.name = name; self.detail = detail; self.metric = metric; self.price = price
    }
}
