import Foundation

/// Readable steps with expandable tool details. A value is only executable after whole-plan
/// validation; approval belongs to the caller (CLI now, native approval card later).
public struct TaskPlan: Codable, Sendable, Equatable {
    public var request: String
    public var title: String
    public var steps: [PlanStep]

    public init(request: String, title: String, steps: [PlanStep]) {
        self.request = request; self.title = title; self.steps = steps
    }

    public func validate() throws {
        guard !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...20).contains(steps.count) else { throw PlanError.invalid("A plan needs a request, title and 1–20 steps.") }
        for step in steps {
            guard !step.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PlanError.invalid("Every step needs a summary.") }
            switch step.kind {
            case .decide:
                guard step.tool == nil, step.arguments == .object([:]), !step.goal.isEmpty else {
                    throw PlanError.invalid("A decide step needs a goal and no tool arguments.")
                }
            case .action:
                guard let tool = step.tool, !SessionTools.definition(for: tool).isReadOnly else {
                    throw PlanError.invalid("Action steps need a session action tool; observations belong in decide steps.")
                }
                try Self.validateAction(tool, arguments: step.arguments)
            }
        }
        guard steps.last?.kind == .decide else { throw PlanError.invalid("End with a decide step to verify the result and finish_task.") }
    }

    private static func validateAction(_ tool: SessionToolName, arguments: JSONValue) throws {
        try SessionToolbox.validateCall(tool, arguments: arguments)
        guard let fields = arguments.objectValue else { throw PlanError.invalid("Tool arguments must be an object.") }
        guard fields["x"] == nil || fields["x"] == .null,
              fields["y"] == nil || fields["y"] == .null else {
            throw PlanError.invalid("Plans use named targets, never stored coordinates. Use a decide step to locate a target at execution time.")
        }
        if tool == .click {
            guard fields["bundle_id"]?.stringValue?.isEmpty == false, fields["element"]?.stringValue?.isEmpty == false else {
                throw PlanError.invalid("Planned clicks need bundle_id and element.")
            }
        }
        if tool == .batch, case .array(let actions)? = fields["actions"] {
            for action in actions {
                guard var fields = action.objectValue,
                      let tool = fields.removeValue(forKey: "tool")?.stringValue.flatMap(SessionToolName.init(rawValue:)) else {
                    throw PlanError.invalid("Every batch item needs a known tool.")
                }
                try validateAction(tool, arguments: .object(fields.filter { $0.value != .null }))
            }
        }
    }

    /// Parses flattened submit_plan steps; tool argument schemas remain provider-compatible.
    public static func parse(_ value: JSONValue, request: String) throws -> TaskPlan {
        guard let title = value["title"]?.stringValue, case .array(let rows)? = value["steps"] else {
            throw PlanError.invalid("submit_plan needs title and steps.")
        }
        let metadata: Set<String> = ["summary", "kind", "goal", "confirm", "tool"]
        let steps = try rows.map { row -> PlanStep in
            guard let fields = row.objectValue, let summary = fields["summary"]?.stringValue,
                  let kind = fields["kind"]?.stringValue.flatMap(PlanStep.Kind.init(rawValue:)),
                  let confirm = fields["confirm"]?.boolValue else { throw PlanError.invalid("Each step needs summary, kind and confirm.") }
            let rawTool = fields["tool"]?.stringValue
            let tool = rawTool.flatMap(SessionToolName.init(rawValue:))
            if rawTool != nil && tool == nil { throw PlanError.invalid("Unknown planned tool: \(rawTool!).") }
            return PlanStep(summary: summary, kind: kind, goal: fields["goal"]?.stringValue ?? "", tool: tool,
                            arguments: .object(fields.filter { !metadata.contains($0.key) && $0.value != .null }),
                            requiresConfirmation: confirm)
        }
        let plan = TaskPlan(request: request, title: title, steps: steps)
        try plan.validate()
        return plan
    }
}

public struct PlanStep: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case action, decide }
    public var summary: String
    public var kind: Kind
    public var goal: String
    public var tool: SessionToolName?
    public var arguments: JSONValue
    public var requiresConfirmation: Bool

    public init(summary: String, kind: Kind, goal: String = "", tool: SessionToolName? = nil,
                arguments: JSONValue = .object([:]), requiresConfirmation: Bool = false) {
        self.summary = summary; self.kind = kind; self.goal = goal; self.tool = tool
        self.arguments = arguments; self.requiresConfirmation = requiresConfirmation
    }
}

public enum PlanError: Error, Sendable, CustomStringConvertible {
    case invalid(String)
    case failed(String)
    public var description: String {
        switch self { case .invalid(let text), .failed(let text): text }
    }
}

