import Foundation
import ZoopShared

/// Grounded, read-only planning. State-changing tools are never dispatched, even if the
/// model tries to call them or sends them alongside submit_plan.
public struct PlannerAgent: Sendable {
    let model: any ChatModel
    let tools: any ToolRunning
    let maxCalls: Int
    /// The executor will have the browser_* tools, so web steps are planned for them.
    let browserAvailable: Bool

    public init(model: any ChatModel, tools: any ToolRunning, maxCalls: Int = 8, browserAvailable: Bool = false) {
        self.model = model; self.tools = tools; self.maxCalls = maxCalls; self.browserAvailable = browserAvailable
    }

    public func plan(_ request: String, onEvent: @Sendable (AgentEvent) -> Void = { _ in }) async throws -> PlannedTask {
        guard !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, maxCalls > 0 else {
            throw PlanError.invalid("A nonempty task and a positive planner call limit are required.")
        }
        var history: [ModelMessage] = [.user("Task to plan: \(request)")]
        var usage = ModelUsage(inputTokens: 0, outputTokens: 0)
        onEvent(.started(model: model.name))
        try Task.checkCancellation()
        onEvent(.toolStarted(name: "screenshot", arguments: "{}"))
        let shot = await tools.call("screenshot", argumentsJSON: "{}")
        onEvent(.toolFinished(name: "screenshot", result: shot))
        try Task.checkCancellation()
        guard !shot.isError, let image = shot.image else { throw PlanError.failed("Cannot observe the session: \(shot.text)") }
        history.append(.user("Initial read-only screenshot: \(shot.text)"))
        history.append(Self.imageMessage(image, caption: "Initial agent-session screenshot"))
        // Planning observes; it has nothing to wait for.
        let readOnly = SessionTools.catalog.filter { $0.isReadOnly && $0.name != .wait }
        let allowed = Set(readOnly.map { $0.name.rawValue })
        var observedApps = Set<String>()
        // Planning runs without starting a browser; the executor attaches the browser tools.
        let system = PlannerPrompt.system + (browserAvailable ? "\n" + PlannerPrompt.browserNote : "")
        for callNumber in 1...maxCalls {
            try Task.checkCancellation()
            onEvent(.step(callNumber))
            // Only observations sent in a prior request can ground this model response.
            let groundedApps = observedApps
            let response = try await model.complete(ModelRequest(system: system,
                messages: AgentSession.render(history, keepingImages: 1), tools: readOnly.map(ModelTool.init) + [PlannerPrompt.submit]))
            try Task.checkCancellation()
            if let used = response.usage {
                usage.inputTokens += used.inputTokens; usage.outputTokens += used.outputTokens
                onEvent(.usage(usage))
            }
            history.append(response.message)
            if !response.message.text.isEmpty { onEvent(.thought(response.message.text)) }
            if response.message.toolCalls.isEmpty {
                history.append(.user("Inspect running apps with list_elements, then call submit_plan. No actions are allowed before approval."))
                continue
            }
            var proposed: TaskPlan?
            var images: [ModelMessage] = []
            for call in response.message.toolCalls {
                try Task.checkCancellation()
                if call.name == "submit_plan" {
                    do {
                        let plan = try TaskPlan.parse(JSONValue.parse(call.arguments), request: request)
                        let apps = Self.namedClickApps(plan)
                        guard apps.isSubset(of: groundedApps) else {
                            throw PlanError.invalid("Before planning named clicks, call list_elements for: \(apps.subtracting(groundedApps).sorted().joined(separator: ", ")). If the app is not running, plan open_app followed by a decide step.")
                        }
                        proposed = plan
                        history.append(.toolResult(id: call.id, #"{"ok":true}"#))
                    } catch { history.append(.toolResult(id: call.id, AgentSession.invalid(String(describing: error)))) }
                } else if allowed.contains(call.name) {
                    onEvent(.toolStarted(name: call.name, arguments: call.arguments))
                    let result = await tools.call(call.name, argumentsJSON: call.arguments)
                    onEvent(.toolFinished(name: call.name, result: result))
                    history.append(.toolResult(id: call.id, result.text))
                    if let image = result.image { images.append(Self.imageMessage(image, caption: "Observation from \(call.name)")) }
                    if call.name == "list_elements", !result.isError,
                       let app = AgentSession.arguments(call)?["bundle_id"]?.stringValue { observedApps.insert(app) }
                } else {
                    history.append(.toolResult(id: call.id, AgentSession.invalid("Planning is read-only. Propose that action in submit_plan; do not execute it.")))
                }
            }
            history.append(contentsOf: images)
            if let plan = proposed { return PlannedTask(plan: plan, modelCalls: callNumber, usage: usage) }
        }
        throw PlanError.failed("Planner did not submit a valid grounded plan within \(maxCalls) model calls.")
    }

    static func imageMessage(_ image: ToolImage, caption: String) -> ModelMessage {
        let jpeg = ImageCompression.jpeg(fromPNG: image.data)
        return ModelMessage(role: .user, content: [.text(caption), .image(data: jpeg ?? image.data, mediaType: jpeg == nil ? image.mediaType : "image/jpeg")])
    }

    private static func namedClickApps(_ plan: TaskPlan) -> Set<String> {
        var apps = Set<String>()
        func visit(_ tool: SessionToolName?, _ arguments: JSONValue) {
            if tool == .click, let app = arguments["bundle_id"]?.stringValue { apps.insert(app) }
            if tool == .batch, case .array(let actions)? = arguments["actions"] {
                for action in actions { visit(action["tool"]?.stringValue.flatMap(SessionToolName.init(rawValue:)), action) }
            }
        }
        for step in plan.steps { visit(step.tool, step.arguments) }
        return apps
    }
}
