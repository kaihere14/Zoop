import Foundation
import ZoopShared

public struct ChatReply: Sendable {
    public let text: String
    public let planningRequest: String?
}

/// Normal conversation has no session tools. Only a concrete task is handed to the planner.
public struct ChatAgent: Sendable {
    let model: any ChatModel
    /// Only the newest messages are sent each turn. Every request resends the whole window, so a
    /// long chat would otherwise cost more tokens on every reply. `/clear` empties it completely.
    static let historyLimit = 12
    public init(model: any ChatModel) { self.model = model }

    public func reply(to messages: [CompanionMessage], pendingPlan: TaskPlan? = nil) async throws -> ChatReply {
        let system = """
        You are Zoop, a friendly macOS companion with your own agent desktop: a separate macOS
        session where you can open apps such as Safari, browse the web, research, and write
        reports. You do this through planning: when the person asks for anything that needs apps,
        the web, files or research, call plan_task with a self-contained request that includes the
        relevant details from the conversation. Never tell the person you cannot open apps or
        browse; call plan_task instead.
        For plain conversation or questions you can answer from your own knowledge, reply normally
        without tools, and ask for missing details when a task is unclear.
        For revisions, call plan_task again with the changed requirements included.
        plan_task only proposes a plan. Nothing runs until the person clicks Execute the plan, so
        do not claim work is done, and if asked to run a pending plan, point to that button.
        \(pendingPlan.map { "Current pending plan (context only): \($0.title). Request: \($0.request)" } ?? "No pending plan.")
        """
        let tool = ModelTool(name: "plan_task", description: "Hand a concrete task to the planner. This only proposes work; it does not execute it.",
            inputSchema: ["type": "object", "additionalProperties": false, "required": ["request"],
                          "properties": ["request": ["type": "string", "description": "Complete task request with relevant constraints."]]])
        var history = messages.suffix(Self.historyLimit).map {
            ModelMessage(role: $0.role == .user ? .user : .assistant, content: [.text($0.text)])
        }
        for _ in 0..<3 {
            try Task.checkCancellation()
            let response = try await model.complete(ModelRequest(system: system, messages: history, tools: [tool]))
            try Task.checkCancellation()
            if response.message.toolCalls.isEmpty {
                guard !response.message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ModelError.invalidResponse("The chat model returned an empty reply.")
                }
                return ChatReply(text: response.message.text, planningRequest: nil)
            }
            history.append(response.message)
            if response.message.toolCalls.count == 1, let call = response.message.toolCalls.first,
               call.name == "plan_task", let value = try? JSONValue.parse(call.arguments),
               let request = value["request"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !request.isEmpty {
                return ChatReply(text: response.message.text, planningRequest: request)
            }
            for call in response.message.toolCalls {
                history.append(.toolResult(id: call.id, AgentSession.invalid("Call only plan_task with a nonempty request, or reply normally without tools.")))
            }
        }
        throw ModelError.invalidResponse("The chat model did not provide a valid reply or planning request.")
    }
}
