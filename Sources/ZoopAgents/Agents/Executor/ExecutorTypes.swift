import Foundation
import ZoopShared

/// Runs session tools. `SessionToolbox` is the real one; tests use fakes.
public protocol ToolRunning: Sendable {
    func call(_ name: String, argumentsJSON: String) async -> ToolResult
}

extension SessionToolbox: ToolRunning {}

/// What a question needs: a yes/no approval of a specific action, or information only the person has.
/// The app shows confirmations with Allow and Deny buttons and information requests with a reply field.
public enum QuestionKind: String, Sendable {
    case confirm, info
}

/// How an approved plan runs. `ask` stops for each risky step; `auto` treats every action the plan
/// lists as pre-approved, and asks only before risky actions the plan did not list.
public enum ApprovalMode: String, Sendable, Codable, CaseIterable {
    case ask, auto
}

/// Answers the executor's `ask_user` questions. The UI shows them; the CLI reads stdin.
public protocol UserPrompting: Sendable {
    /// Returns the person's answer, or `nil` when there is none (dismissed or cancelled).
    func ask(_ question: String) async -> String?
    func ask(_ question: String, kind: QuestionKind) async -> String?
    func choosePermission(_ prompt: PermissionPrompt) async -> String?
}

extension UserPrompting {
    public func ask(_ question: String, kind: QuestionKind) async -> String? { await ask(question) }
    public func choosePermission(_ prompt: PermissionPrompt) async -> String? {
        let choices = prompt.choices.enumerated().map { "\($0.offset + 1). \($0.element.title)" }.joined(separator: "\n")
        let heading = prompt.kind == .appDialog ? "Dialog in \(prompt.ownerName)" : "System permission request (\(prompt.ownerName))"
        guard let reply = await ask("\(heading):\n\(prompt.message)\n\(choices)\nChoose the exact label or number; cancel to stop.", kind: .info) else { return nil }
        if let number = Int(reply.trimmingCharacters(in: .whitespacesAndNewlines)), prompt.choices.indices.contains(number - 1) { return prompt.choices[number - 1].id }
        return prompt.choices.first { $0.title == reply }?.id
    }
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
    /// Failed actions allowed before the executor must stop and report. Each retry must use a
    /// different method; a successful action resets the count.
    public var maxFailedAttempts: Int

    public init(maxSteps: Int = 50, maxNudges: Int = 2, keptScreenshots: Int = 1, maxOutputTokens: Int? = nil,
                maxFailedAttempts: Int = 3) {
        self.maxFailedAttempts = maxFailedAttempts
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
