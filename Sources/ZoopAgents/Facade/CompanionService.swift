import Foundation
import ZoopShared

public struct CompanionReply: Sendable {
    public let text: String
    public let plan: TaskPlan?
    public init(text: String, plan: TaskPlan? = nil) { self.text = text; self.plan = plan }
}

/// The notch owns one conversation and at most one executing task.
public protocol CompanionService: Sendable {
    func respond(to messages: [CompanionMessage], pendingPlan: TaskPlan?) async throws -> CompanionReply
    func execute(_ plan: TaskPlan, mode: ApprovalMode, prompter: any UserPrompting,
                 onEvent: @escaping @Sendable (AgentEvent) -> Void) async -> AgentOutcome
    /// One frame for the live preview: the browser page while the browser is in use,
    /// otherwise the agent session's screen. Nil when there is nothing to show.
    func previewFrame() async -> Data?
}

extension CompanionService {
    public func previewFrame() async -> Data? { nil }
}

/// Models are resolved lazily: normal chatting needs only the chat model. Planning and
/// execution resolve their own configured models only when that stage is reached.
public struct LiveCompanionService: CompanionService {
    /// Read again for every request, so keys and providers changed in Settings apply without a restart.
    private let configuration: @Sendable () -> ModelConfiguration
    private let tools: any ToolRunning
    private let permissions: (any PermissionHandling)?
    /// Quits the session's apps after a successful task. Nil when tools are injected
    /// without one (tests), so nothing is quit.
    private let cleaner: (any SessionCleaning)?
    private let chatModel: (any ChatModel)?
    private let plannerModel: (any ChatModel)?
    private let executorModel: (any ChatModel)?
    /// Playwright-driven Chrome for websites. Nil when Node.js is missing or tools are injected (tests).
    public let browser: BrowserSession?
    /// Separate from the agent's connection, so preview captures never wait behind actions.
    private let previewConnection: HelperConnection?

    public init(configuration: ModelConfiguration? = nil,
                tools: (any ToolRunning)? = nil, cleaner: (any SessionCleaning)? = nil,
                chatModel: (any ChatModel)? = nil, plannerModel: (any ChatModel)? = nil,
                executorModel: (any ChatModel)? = nil) {
        if let configuration { self.configuration = { configuration } } else { self.configuration = { ModelConfiguration() } }
        if let tools {
            self.tools = tools; self.permissions = nil; self.cleaner = cleaner
            self.browser = nil; self.previewConnection = nil
        } else {
            let connection = HelperConnection(configuration: .init(clientName: "Zoop"))
            let browser = BrowserSession.npx() == nil ? nil : BrowserSession()
            let session = SessionToolbox(connection: connection)
            self.tools = browser.map { BrowserToolRunner(tools: session, browser: $0) } ?? session
            self.permissions = connection
            self.cleaner = cleaner ?? connection
            self.browser = browser
            self.previewConnection = HelperConnection(configuration: .init(clientName: "Zoop preview"))
        }
        self.chatModel = chatModel; self.plannerModel = plannerModel; self.executorModel = executorModel
    }

    public func respond(to messages: [CompanionMessage], pendingPlan: TaskPlan?) async throws -> CompanionReply {
        let label = "chat: " + String((messages.last { $0.role == .user }?.text ?? "").prefix(80))
        return try await ModelTrace.$context.withValue(TraceContext(label: label)) {
            try await reply(to: messages, pendingPlan: pendingPlan)
        }
    }

    private func reply(to messages: [CompanionMessage], pendingPlan: TaskPlan?) async throws -> CompanionReply {
        let chat = try chatModel ?? configuration().model(for: .chat)
        let reply = try await ChatAgent(model: chat).reply(to: messages, pendingPlan: pendingPlan)
        guard let request = reply.planningRequest else { return CompanionReply(text: reply.text) }
        let planner = try plannerModel ?? configuration().model(for: .planner)
        let proposed = try await PlannerAgent(model: planner, tools: tools, browserAvailable: browser != nil).plan(request)
        return CompanionReply(text: reply.text.isEmpty ? "Here’s the proposed plan. Review it, then choose Execute the plan." : reply.text,
                              plan: proposed.plan)
    }

    public func previewFrame() async -> Data? {
        if let browser, await browser.isActive, let frame = await browser.previewFrame() { return frame }
        return try? await previewConnection?.capture(CaptureOptions(maxPixelWidth: 1280, showsCursor: false)).png
    }

    public func execute(_ plan: TaskPlan, mode: ApprovalMode, prompter: any UserPrompting,
                        onEvent: @escaping @Sendable (AgentEvent) -> Void) async -> AgentOutcome {
        await ModelTrace.$context.withValue(TraceContext(label: "task: " + String(plan.title.prefix(80)))) {
            await run(plan, mode: mode, prompter: prompter, onEvent: onEvent)
        }
    }

    private func run(_ plan: TaskPlan, mode: ApprovalMode, prompter: any UserPrompting,
                     onEvent: @escaping @Sendable (AgentEvent) -> Void) async -> AgentOutcome {
        do {
            let model = try executorModel ?? configuration().model(for: .executor)
            let executionTools: any ToolRunning
            if let permissions {
                executionTools = PermissionToolRunner(tools: tools, permissions: permissions, prompter: prompter, onEvent: onEvent)
            } else { executionTools = tools }
            let outcome = await PlanRunner(model: model, tools: executionTools, prompter: prompter)
                .run(plan, approved: true, mode: mode, onEvent: onEvent)
            return await SessionCleanup.afterTask(outcome, using: cleaner)
        } catch {
            return AgentOutcome(status: .failed, summary: String(describing: error), steps: 0,
                                usage: ModelUsage(inputTokens: 0, outputTokens: 0))
        }
    }
}
