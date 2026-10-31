import Foundation

/// One argument of a tool.
public struct ToolParameter: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case string, number, integer, boolean
    }

    public var name: String
    public var kind: Kind
    public var description: String
    public var required: Bool
    /// Allowed values for a string parameter.
    public var allowed: [String]?
    public var minimum: Double?
    public var maximum: Double?
    /// Documented default when the argument is omitted.
    public var defaultValue: JSONValue?

    public init(_ name: String, _ kind: Kind, _ description: String, required: Bool = true,
                allowed: [String]? = nil, minimum: Double? = nil, maximum: Double? = nil,
                defaultValue: JSONValue? = nil) {
        self.name = name
        self.kind = kind
        self.description = description
        self.required = required
        self.allowed = allowed
        self.minimum = minimum
        self.maximum = maximum
        self.defaultValue = defaultValue
    }

    var schema: JSONValue {
        var object: [String: JSONValue] = ["type": .string(kind.rawValue), "description": .string(description)]
        if let allowed { object["enum"] = .array(allowed.map(JSONValue.string)) }
        if let minimum { object["minimum"] = .number(minimum) }
        if let maximum { object["maximum"] = .number(maximum) }
        if let defaultValue { object["default"] = defaultValue }
        return .object(object)
    }
}

/// Everything an agent needs to know about one tool: what it does, when to use it, its
/// arguments, what it returns and how to react when it fails.
public struct ToolDefinition: Sendable, Equatable {
    public var name: SessionToolName
    /// One line, for indexes and compact prompts.
    public var summary: String
    /// When and how to use the tool.
    public var usage: String
    public var parameters: [ToolParameter]
    /// What a successful result contains.
    public var returns: String
    /// How to react to this tool's typical failures.
    public var failures: [String]
    /// Read-only tools never change the agent session and are safe to repeat.
    public var isReadOnly: Bool

    /// JSON Schema for the arguments, in the shape LLM tool-calling APIs expect.
    public var inputSchema: JSONValue {
        .object([
            "type": "object",
            "properties": .object(Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, $0.schema) })),
            "required": .array(parameters.filter(\.required).map { .string($0.name) }),
            "additionalProperties": false,
        ])
    }

    /// The description to send to a model: usage, result and failure handling in one text.
    public var modelDescription: String {
        var text = "\(summary) \(usage)\nReturns: \(returns)"
        if !failures.isEmpty { text += "\nIf it fails: " + failures.joined(separator: " ") }
        return text
    }

    /// Provider-neutral tool declaration: `name`, `description`, `input_schema`.
    public var declaration: JSONValue {
        ["name": .string(name.rawValue), "description": .string(modelDescription), "input_schema": inputSchema]
    }

    /// Checks arguments against the parameter list before anything reaches the helper.
    /// Rejects unknown names too: a misspelled optional argument would otherwise be ignored.
    func validate(_ arguments: JSONValue) throws(ToolCallError) -> ToolArguments {
        let values: [String: JSONValue]
        switch arguments {
        case .object(let object): values = object
        case .null: values = [:]
        default: throw .invalidArguments("arguments must be a JSON object")
        }
        let known = Set(parameters.map(\.name))
        if let unknown = values.keys.sorted().first(where: { !known.contains($0) }) {
            throw .invalidArguments("unknown argument '\(unknown)'; expected \(parameters.map(\.name).joined(separator: ", "))")
        }
        for parameter in parameters {
            guard let value = values[parameter.name], value != .null else {
                if parameter.required { throw .invalidArguments("missing required argument '\(parameter.name)'") }
                continue
            }
            try parameter.check(value)
        }
        return ToolArguments(values: values)
    }
}

extension ToolParameter {
    func check(_ value: JSONValue) throws(ToolCallError) {
        switch kind {
        case .string:
            guard let string = value.stringValue else { throw .invalidArguments("'\(name)' must be a string") }
            if let allowed, !allowed.contains(string) {
                throw .invalidArguments("'\(name)' must be one of \(allowed.joined(separator: ", "))")
            }
        case .boolean:
            guard value.boolValue != nil else { throw .invalidArguments("'\(name)' must be true or false") }
        case .number, .integer:
            guard let number = value.numberValue, number.isFinite else { throw .invalidArguments("'\(name)' must be a number") }
            if kind == .integer, number.rounded() != number { throw .invalidArguments("'\(name)' must be a whole number") }
            if let minimum, number < minimum { throw .invalidArguments("'\(name)' must be at least \(JSONValue.number(minimum).jsonText)") }
            if let maximum, number > maximum { throw .invalidArguments("'\(name)' must be at most \(JSONValue.number(maximum).jsonText)") }
        }
    }
}

/// Arguments that passed validation. Getters fall back to defaults for omitted optionals.
struct ToolArguments {
    let values: [String: JSONValue]

    func string(_ name: String) -> String? { values[name]?.stringValue }
    func number(_ name: String) -> Double? { values[name]?.numberValue }
    func bool(_ name: String, default fallback: Bool) -> Bool { values[name]?.boolValue ?? fallback }
    func has(_ name: String) -> Bool { values[name].map { $0 != .null } ?? false }
}

/// A failed tool call. The toolbox turns it into a structured error result for the model.
public enum ToolCallError: Error, Sendable, Equatable {
    case unknownTool(String)
    case invalidArguments(String)
}
