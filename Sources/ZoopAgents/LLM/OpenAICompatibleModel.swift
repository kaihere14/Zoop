import Foundation
import ZoopShared

/// Sends HTTP requests. Tests replace it with a fake.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ModelError.invalidResponse("not an HTTP response") }
        return (data, http)
    }
}

/// Where and how to reach a model.
public struct ModelEndpoint: Sendable, Equatable {
    public var provider: String
    public var baseURL: URL
    public var apiKey: String?
    public var model: String
    public var extraHeaders: [String: String]
    /// Remove JSON Schema keywords some providers reject (`additionalProperties`, `default`).
    public var simplifiesSchemas: Bool

    public init(provider: String, baseURL: URL, apiKey: String?, model: String,
                extraHeaders: [String: String] = [:], simplifiesSchemas: Bool = false) {
        self.provider = provider
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.extraHeaders = extraHeaders
        self.simplifiesSchemas = simplifiesSchemas
    }
}

/// A model reached through the OpenAI Chat Completions format, which most providers accept:
/// Google Gemini, OpenRouter, Groq, OpenAI, DeepSeek, Mistral, Ollama and LM Studio.
public struct OpenAICompatibleModel: ChatModel {
    public let endpoint: ModelEndpoint
    let transport: any HTTPTransport
    let maxRetries: Int
    let retryDelay: Duration
    let timeout: TimeInterval

    public init(endpoint: ModelEndpoint, transport: any HTTPTransport = URLSessionTransport(),
                maxRetries: Int = 3, retryDelay: Duration = .seconds(2), timeout: TimeInterval = 180) {
        self.endpoint = endpoint
        self.transport = transport
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
        self.timeout = timeout
    }

    public var name: String { "\(endpoint.provider)/\(endpoint.model)" }

    public func complete(_ request: ModelRequest) async throws -> ModelResponse {
        let body = Data(Self.body(for: request, endpoint: endpoint).jsonText.utf8)
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let (data, http): (Data, HTTPURLResponse)
            do {
                (data, http) = try await transport.send(urlRequest(body))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                guard attempt < maxRetries else { throw ModelError.unavailable(error.localizedDescription) }
                attempt += 1
                try await Task.sleep(for: retryDelay * (1 << (attempt - 1)))
                continue
            }
            let detail = Self.errorDetail(data, status: http.statusCode)
            switch http.statusCode {
            case 200..<300:
                return try Self.response(from: data)
            case 401, 403:
                throw ModelError.authentication(detail)
            case 429, 500..<600:
                guard attempt < maxRetries else {
                    throw http.statusCode == 429 ? ModelError.rateLimited(detail) : ModelError.unavailable(detail)
                }
                attempt += 1
                let header = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                let delay = header.map { Duration.seconds(min($0, 60)) } ?? retryDelay * (1 << (attempt - 1))
                try await Task.sleep(for: delay)
            default:
                throw ModelError.badRequest(detail)
            }
        }
    }

    private func urlRequest(_ body: Data) -> URLRequest {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("chat/completions"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = endpoint.apiKey, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        for (name, value) in endpoint.extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// Model names the provider offers (`GET /models`), sorted.
    public static func listModels(_ endpoint: ModelEndpoint, transport: any HTTPTransport = URLSessionTransport()) async throws -> [String] {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("models"), timeoutInterval: 30)
        if let key = endpoint.apiKey, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        for (name, value) in endpoint.extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
        let (data, http) = try await transport.send(request)
        let detail = errorDetail(data, status: http.statusCode)
        guard (200..<300).contains(http.statusCode) else {
            throw [401, 403].contains(http.statusCode) ? ModelError.authentication(detail) : ModelError.badRequest(detail)
        }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data), case .array(let items)? = json["data"] else {
            throw ModelError.invalidResponse("no model list in response")
        }
        return items.compactMap { $0["id"]?.stringValue }.sorted()
    }

    // MARK: - Encoding

    static func body(for request: ModelRequest, endpoint: ModelEndpoint) -> JSONValue {
        var messages: [JSONValue] = [["role": "system", "content": .string(request.system)]]
        messages += request.messages.map(encode)
        var body: [String: JSONValue] = ["model": .string(endpoint.model), "messages": .array(messages)]
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                let schema = endpoint.simplifiesSchemas ? simplify(tool.inputSchema) : tool.inputSchema
                return ["type": "function", "function": ["name": .string(tool.name), "description": .string(tool.description),
                                                         "parameters": schema]]
            })
            body["tool_choice"] = "auto"
        }
        if let max = request.maxOutputTokens { body["max_tokens"] = .number(Double(max)) }
        return .object(body)
    }

    static func encode(_ message: ModelMessage) -> JSONValue {
        switch message.role {
        case .assistant:
            if let echo = message.providerEcho { return echo }
            var object: [String: JSONValue] = ["role": "assistant", "content": message.text.isEmpty ? .null : .string(message.text)]
            if !message.toolCalls.isEmpty {
                object["tool_calls"] = .array(message.toolCalls.map {
                    ["id": .string($0.id), "type": "function", "function": ["name": .string($0.name), "arguments": .string($0.arguments)]]
                })
            }
            return .object(object)
        case .tool:
            return ["role": "tool", "tool_call_id": .string(message.toolCallID ?? ""), "content": .string(message.text)]
        case .user:
            let hasImage = message.content.contains { if case .image = $0 { true } else { false } }
            guard hasImage else { return ["role": "user", "content": .string(message.text)] }
            return ["role": "user", "content": .array(message.content.map { part in
                switch part {
                case .text(let text): return ["type": "text", "text": .string(text)]
                case .image(let data, let mediaType):
                    return ["type": "image_url", "image_url": ["url": .string("data:\(mediaType);base64,\(data.base64EncodedString())")]]
                }
            })]
        }
    }

    /// Drops schema keywords that some OpenAI-compatible endpoints reject.
    static func simplify(_ schema: JSONValue) -> JSONValue {
        switch schema {
        case .object(let object):
            var result: [String: JSONValue] = [:]
            for (key, value) in object where key != "additionalProperties" && key != "default" {
                result[key] = key == "properties" ? value.objectValue.map { .object($0.mapValues(simplify)) } ?? value : simplify(value)
            }
            return .object(result)
        case .array(let items): return .array(items.map(simplify))
        default: return schema
        }
    }

    // MARK: - Decoding

    static func response(from data: Data) throws -> ModelResponse {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw ModelError.invalidResponse("response is not JSON")
        }
        if let error = json["error"], error != .null {
            throw ModelError.badRequest(error["message"]?.stringValue ?? error.jsonText)
        }
        guard case .array(let choices)? = json["choices"], let choice = choices.first, let message = choice["message"] else {
            throw ModelError.invalidResponse("no choices in response: \(String(json.jsonText.prefix(300)))")
        }
        var calls: [ModelToolCall] = []
        if case .array(let raw)? = message["tool_calls"] {
            for (index, call) in raw.enumerated() {
                guard let function = call["function"], let name = function["name"]?.stringValue else { continue }
                let arguments: String
                switch function["arguments"] {
                case .string(let text)?: arguments = text
                case .some(let value) where value != .null: arguments = value.jsonText
                default: arguments = "{}"
                }
                let id = call["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "call_\(index)"
                calls.append(ModelToolCall(id: id, name: name, arguments: arguments))
            }
        }
        // Echo the provider's message back with the ids we use, so replies match. Keep only
        // fields that are safe to resend: tool-call objects stay whole (Gemini attaches
        // reasoning signatures there), and OpenRouter's `reasoning_details` keeps reasoning
        // continuity. Other response-only fields (annotations, refusal, …) are dropped
        // because some providers reject them in requests.
        var echo = (message.objectValue ?? [:]).filter { ["content", "tool_calls", "reasoning_details"].contains($0.key) }
        echo["role"] = "assistant"
        if echo["content"] == nil { echo["content"] = .null }
        if !calls.isEmpty, case .array(var raw)? = echo["tool_calls"] {
            for index in raw.indices where index < calls.count {
                if var call = raw[index].objectValue {
                    call["id"] = .string(calls[index].id)
                    call["type"] = "function"
                    raw[index] = .object(call)
                }
            }
            echo["tool_calls"] = .array(raw)
        }
        let text = message["content"]?.stringValue ?? ""
        let stop: ModelResponse.StopReason = switch choice["finish_reason"]?.stringValue {
        case "tool_calls"?, "function_call"?: .toolCalls
        case "length"?: .maxTokens
        case "stop"?, nil: calls.isEmpty ? .endTurn : .toolCalls
        case let other?: calls.isEmpty ? .other(other) : .toolCalls
        }
        let usage = json["usage"].flatMap { usage -> ModelUsage? in
            guard let input = usage["prompt_tokens"]?.numberValue, let output = usage["completion_tokens"]?.numberValue else { return nil }
            return ModelUsage(inputTokens: Int(input), outputTokens: Int(output))
        }
        return ModelResponse(message: ModelMessage(role: .assistant, content: text.isEmpty ? [] : [.text(text)],
                                                   toolCalls: calls, providerEcho: .object(echo)),
                             stopReason: stop, usage: usage)
    }

    static func errorDetail(_ data: Data, status: Int) -> String {
        if let json = try? JSONDecoder().decode(JSONValue.self, from: data) {
            if let message = json["error"]?["message"]?.stringValue { return "HTTP \(status): \(message)" }
            if case .array(let items) = json, let message = items.first?["error"]?["message"]?.stringValue {
                return "HTTP \(status): \(message)"
            }
        }
        return "HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))"
    }
}
