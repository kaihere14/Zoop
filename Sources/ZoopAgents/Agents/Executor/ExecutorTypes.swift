import Foundation
import ZoopShared

/// Runs session tools. `SessionToolbox` is the real one; tests use fakes.
public protocol ToolRunning: Sendable {
    func call(_ name: String, argumentsJSON: String) async -> ToolResult
}

extension SessionToolbox: ToolRunning {}

/// Answers the executor's `ask_user` questions. The UI shows them; the CLI reads stdin.
public protocol UserPrompting: Sendable {
    /// Returns the person's answer, or `nil` when there is none (dismissed or cancelled).
    func ask(_ question: String) async -> String?
}

/// What the executor works on: the person's request and the approved plan.
public struct ExecutorTask: Sendable, Equatable {
    public var request: String
    public var plan: [String]

    public init(request: String, plan: [String] = []) {
        self.request = request
        self.plan = plan
    }
}

public struct ExecutorLimits: Sendable {
    /// Model calls per task. Each call may request several tools.
    public var maxSteps: Int
    /// Replies without a tool call that are answered with a reminder before giving up.
    public var maxNudges: Int
    /// Screenshots kept as images in the conversation; older ones become a short note.
    public var keptScreenshots: Int
    public var maxOutputTokens: Int?

    public init(maxSteps: Int = 50, maxNudges: Int = 2, keptScreenshots: Int = 1, maxOutputTokens: Int? = nil) {
        self.maxSteps = maxSteps
        self.maxNudges = maxNudges
        self.keptScreenshots = keptScreenshots
        self.maxOutputTokens = maxOutputTokens
    }
}

public struct AgentOutcome: Sendable, Equatable {
    public enum Status: String, Sendable { case completed, failed, cancelled }

    public var status: Status
    public var summary: String
    /// Markdown report for research or comparison tasks.
    public var report: String?
    public var steps: Int
    public var usage: ModelUsage

    public init(status: Status, summary: String, report: String? = nil, steps: Int, usage: ModelUsage) {
        self.status = status
        self.summary = summary
        self.report = report
        self.steps = steps
        self.usage = usage
    }
}

/// Everything the executor does, in order. The UI renders these as live progress.
public enum AgentEvent: Sendable {
    case started(model: String)
    /// A model call is about to start (1-based).
    case step(Int)
    /// Text the model wrote alongside its tool calls (its reasoning in plain words).
    case thought(String)
    case toolStarted(name: String, arguments: String)
    case toolFinished(name: String, result: ToolResult)
    case progress(note: String, step: Int?, percent: Int?)
    case question(String)
    case answer(String)
    /// Total tokens used so far.
    case usage(ModelUsage)
    case finished(AgentOutcome)
}
