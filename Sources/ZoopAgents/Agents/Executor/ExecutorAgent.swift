import Foundation
import ZoopShared

/// Free-form observe/act/check execution. PlanRunner shares the same conversation engine
/// for decision points and repairs, while executing known actions directly in Swift.
public struct ExecutorAgent: Sendable {
    private let session: AgentSession

    public init(model: any ChatModel, tools: any ToolRunning, prompter: any UserPrompting, limits: ExecutorLimits = ExecutorLimits()) {
        session = AgentSession(model: model, tools: tools, prompter: prompter, limits: limits)
    }

    public func run(_ task: ExecutorTask, onEvent: @Sendable (AgentEvent) -> Void = { _ in }) async -> AgentOutcome {
        await session.run(task, onEvent: onEvent).outcome
    }

    static func render(_ history: [ModelMessage], keepingImages: Int) -> [ModelMessage] {
        AgentSession.render(history, keepingImages: keepingImages)
    }
}
