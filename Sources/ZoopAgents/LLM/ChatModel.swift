import Foundation
import ZoopShared

// Provider-neutral model interface. Agents only see these types; adapters (for example the
// OpenAI-compatible one) translate them to a provider's wire format. Switching provider or
// model is a configuration change, not a code change.

/// A model that can hold a conversation and call tools.
public protocol ChatModel: Sendable {
    /// Human-readable identity for logs, such as "gemini/gemini-flash".
    var name: String { get }
    func complete(_ request: ModelRequest) async throws -> ModelResponse
}

/// One piece of message content.
public enum ModelContent: Sendable, Equatable {
    case text(String)
    case image(data: Data, mediaType: String)
}

/// A tool call the model asked for. `arguments` is JSON text, exactly as the model wrote it.
public struct ModelToolCall: Sendable, Equatable {
    public var id: String
    public var name: String
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ModelMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant, tool }

    public var role: Role
    public var content: [ModelContent]
    /// Tool calls requested by an assistant message.
    public var toolCalls: [ModelToolCall]
    /// For a tool message: the call it answers.
    public var toolCallID: String?
    /// The provider's original assistant message. Adapters send it back unchanged, so
    /// provider-specific fields (such as reasoning signatures) survive the round trip.
    public var providerEcho: JSONValue?

    public init(role: Role, content: [ModelContent], toolCalls: [ModelToolCall] = [], toolCallID: String? = nil,
                providerEcho: JSONValue? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.providerEcho = providerEcho
    }

    public static func user(_ text: String) -> ModelMessage { ModelMessage(role: .user, content: [.text(text)]) }
    public static func toolResult(id: String, _ text: String) -> ModelMessage {
        ModelMessage(role: .tool, content: [.text(text)], toolCallID: id)
    }

    /// All text parts joined, for logging and display.
    public var text: String {
        content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
    }
}

/// A tool the model may call: name, description and JSON Schema for its arguments.
public struct ModelTool: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    public init(_ definition: ToolDefinition) {
        self.init(name: definition.name.rawValue, description: definition.modelDescription, inputSchema: definition.inputSchema)
    }
}

public struct ModelRequest: Sendable {
    public var system: String
    public var messages: [ModelMessage]
    public var tools: [ModelTool]
    /// Upper bound on generated tokens. `nil` uses the provider's default.
    public var maxOutputTokens: Int?

    public init(system: String, messages: [ModelMessage], tools: [ModelTool] = [], maxOutputTokens: Int? = nil) {
        self.system = system
        self.messages = messages
        self.tools = tools
        self.maxOutputTokens = maxOutputTokens
    }
}

public struct ModelUsage: Sendable, Equatable {
    /// All input tokens of the request, including those read from or written to a prompt cache.
    public var inputTokens: Int
    public var outputTokens: Int
    /// Part of `inputTokens` served from the provider's prompt cache (billed at a discount).
    public var cacheReadTokens: Int
    /// Part of `inputTokens` written to the prompt cache (billed at a small premium).
    public var cacheWriteTokens: Int

    public init(inputTokens: Int, outputTokens: Int, cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }
}

public struct ModelResponse: Sendable {
    public enum StopReason: Sendable, Equatable {
        case endTurn, toolCalls, maxTokens
        case other(String)
    }

    /// The assistant message, including any tool calls.
    public var message: ModelMessage
    public var stopReason: StopReason
    public var usage: ModelUsage?

    public init(message: ModelMessage, stopReason: StopReason, usage: ModelUsage? = nil) {
        self.message = message
        self.stopReason = stopReason
        self.usage = usage
    }
}

/// Why a model call failed. Retries for rate limits and server errors happen inside the
/// adapter; these are what remain.
public enum ModelError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Missing or rejected API key, or no access to the model.
    case authentication(String)
    /// The request was rejected (bad model name, unsupported feature, invalid schema).
    case badRequest(String)
    /// Still rate limited after the retries.
    case rateLimited(String)
    /// Provider error or network failure after the retries.
    case unavailable(String)
    /// The response could not be understood.
    case invalidResponse(String)
    /// The configuration is incomplete (no model, no key, unknown provider).
    case configuration(String)

    public var description: String {
        switch self {
        case .authentication(let detail): "authentication failed: \(detail)"
        case .badRequest(let detail): "request rejected: \(detail)"
        case .rateLimited(let detail): "rate limited: \(detail)"
        case .unavailable(let detail): "provider unavailable: \(detail)"
        case .invalidResponse(let detail): "invalid response: \(detail)"
        case .configuration(let detail): "configuration error: \(detail)"
        }
    }
}
