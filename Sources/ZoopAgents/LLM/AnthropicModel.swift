import Foundation
import ZoopShared

/// Claude through Anthropic's Messages API (`POST /v1/messages`), called over raw HTTP because
/// there is no official Anthropic SDK for Swift.
///
/// Differences from the OpenAI format that matter here:
/// - Tool results are `tool_result` blocks inside a user message, so consecutive tool and user
///   messages are merged into one user message (tool results first, then text and screenshots).
/// - The tool definitions and system prompt are identical on every call of an agent, so they carry
///   a prompt-cache marker: later calls read them from the cache at 0.1× the input price. A second,
///   automatic marker caches the conversation up to its newest message.
/// - Thinking is turned off. Zoop prunes old screenshots and tool output from earlier turns, and on
///   Claude Haiku 5.5 a thinking block becomes invalid (400) once anything before it changes.
public struct AnthropicModel: ChatModel {
    public static let apiVersion = "2026-10-21"
    public let endpoint: ModelEndpoint
    let transport: any HTTPTransport
    let maxRetries: Int
    let retryDelay: Duration
    let timeout: TimeInterval
    let defaultMaxTokens: Int

    public init(endpoint: ModelEndpoint, transport: any HTTPTransport = URLSessionTransport(),
                maxRetries: Int = 3, retryDelay: Duration = .seconds(2), timeout: TimeInterval = 180,
                defaultMaxTokens: Int = 16_000) {
        self.endpoint = endpoint
        self.transport = transport
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
        self.timeout = timeout
        self.defaultMaxTokens = defaultMaxTokens
    }

    public var name: String { "\(endpoint.provider)/\(endpoint.model)" }

    public func complete(_ request: ModelRequest) async throws -> ModelResponse {
        let body = Data(Self.body(for: request, model: endpoint.model, maxTokens: request.maxOutputTokens ?? defaultMaxTokens).jsonText.utf8)
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let (data, http): (Data, HTTPURLResponse)
            do {
                (data, http) = try await transport.send(Self.urlRequest(endpoint, path: "messages", body: body, timeout: timeout))
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
            let detail = OpenAICompatibleModel.errorDetail(data, status: http.statusCode)
            switch http.statusCode {
            case 200..<300:
                return try Self.response(from: data)
            case 401, 403:
                throw ModelError.authentication(detail)
            case 429, 500..<600:  // 529 is "overloaded"
                guard attempt < maxRetries else {
                    throw http.statusCode == 429 ? ModelError.rateLimited(detail) : ModelError.unavailable(detail)
                }
                attempt += 1
                let header = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
                let delay = header.map { Duration.seconds(min($0, 60)) } ?? retryDelay * (1 << (attempt - 1))
                try await Task.sleep(for: delay)
            default:
                throw ModelError.badRequest(detail)
            }
        }
    }

    static func urlRequest(_ endpoint: ModelEndpoint, path: String, body: Data?, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        if let key = endpoint.apiKey, !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
        for (name, value) in endpoint.extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// Model IDs the key can use (`GET /v1/models`, first page), sorted.
    public static func listModels(_ endpoint: ModelEndpoint, transport: any HTTPTransport = URLSessionTransport()) async throws -> [String] {
        var url = URLComponents(url: endpoint.baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)
        url?.queryItems = [URLQueryItem(name: "limit", value: "1000")]
        var request = urlRequest(endpoint, path: "models", body: nil, timeout: 30)
        if let full = url?.url { request.url = full }
        let (data, http) = try await transport.send(request)
        let detail = OpenAICompatibleModel.errorDetail(data, status: http.statusCode)
        guard (200..<300).contains(http.statusCode) else {
            throw [401, 403].contains(http.statusCode) ? ModelError.authentication(detail) : ModelError.badRequest(detail)
        }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data), case .array(let items)? = json["data"] else {
            throw ModelError.invalidResponse("no model list in response")
        }
        return items.compactMap { $0["id"]?.stringValue }.sorted()
    }

    // MARK: - Encoding

    static let cacheMarker: JSONValue = ["type": "ephemeral"]

    static func body(for request: ModelRequest, model: String, maxTokens: Int) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(maxTokens)),
            "messages": .array(encode(request.messages)),
            "thinking": ["type": "disabled"],
            // Caches the conversation up to its newest block; see the type comment.
            "cache_control": cacheMarker,
        ]
        if !request.system.isEmpty {
            // Tools render before the system prompt, so this one marker caches both.
            body["system"] = [["type": "text", "text": .string(request.system), "cache_control": cacheMarker]]
        }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map {
                ["name": .string($0.name), "description": .string($0.description), "input_schema": $0.inputSchema]
            })
        }
        return .object(body)
    }

    /// Converts the provider-neutral history: assistant turns keep Claude's own content blocks when
    /// we have them, and tool results plus following user content are merged into one user turn.
    static func encode(_ messages: [ModelMessage]) -> [JSONValue] {
        var result: [(role: String, blocks: [JSONValue])] = []
        func append(_ role: String, _ blocks: [JSONValue]) {
            guard !blocks.isEmpty else { return }
            if let last = result.last, last.role == role { result[result.count - 1].blocks += blocks }
            else { result.append((role, blocks)) }
        }
        for message in messages {
            switch message.role {
            case .assistant:
                if case .array(let echoed)? = message.providerEcho?["anthropic_content"] { append("assistant", echoed); continue }
                var blocks = textAndImages(message.content)
                for call in message.toolCalls {
                    let input = (try? JSONValue.parse(call.arguments)).flatMap { $0.objectValue == nil ? nil : $0 } ?? .object([:])
                    blocks.append(["type": "tool_use", "id": .string(call.id), "name": .string(call.name), "input": input])
                }
                append("assistant", blocks)
            case .tool:
                append("user", [["type": "tool_result", "tool_use_id": .string(message.toolCallID ?? ""),
                                  "content": .string(message.text.isEmpty ? "(no output)" : message.text)]])
            case .user:
                append("user", textAndImages(message.content))
            }
        }
        return result.map { ["role": .string($0.role), "content": .array($0.blocks)] }
    }

    static func textAndImages(_ content: [ModelContent]) -> [JSONValue] {
        content.compactMap { part in
            switch part {
            case .text(let text):
                return text.isEmpty ? nil : ["type": "text", "text": .string(text)]
            case .image(let data, let mediaType):
                return ["type": "image", "source": ["type": "base64", "media_type": .string(mediaType),
                                                    "data": .string(data.base64EncodedString())]]
            }
        }
    }

    // MARK: - Decoding

    static func response(from data: Data) throws -> ModelResponse {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw ModelError.invalidResponse("response is not JSON")
        }
        guard case .array(let blocks)? = json["content"] else {
            throw ModelError.invalidResponse("no content in response: \(String(json.jsonText.prefix(300)))")
        }
        let stopReason = json["stop_reason"]?.stringValue
        if stopReason == "refusal" {
            let explanation = json["stop_details"]?["explanation"]?.stringValue ?? "no explanation given"
            throw ModelError.badRequest("Claude declined this request: \(explanation)")
        }
        // Content blocks are read by type, never by position.
        var texts: [String] = []
        var calls: [ModelToolCall] = []
        for block in blocks {
            switch block["type"]?.stringValue {
            case "text"?: if let text = block["text"]?.stringValue { texts.append(text) }
            case "tool_use"?:
                guard let id = block["id"]?.stringValue, let name = block["name"]?.stringValue else { continue }
                calls.append(ModelToolCall(id: id, name: name, arguments: (block["input"] ?? .object([:])).jsonText))
            default: break
            }
        }
        let stop: ModelResponse.StopReason = switch stopReason {
        case "tool_use"?: .toolCalls
        case "max_tokens"?: .maxTokens
        case "end_turn"?, "stop_sequence"?, nil: calls.isEmpty ? .endTurn : .toolCalls
        case let other?: calls.isEmpty ? .other(other) : .toolCalls
        }
        let usage = json["usage"].flatMap { usage -> ModelUsage? in
            guard let input = usage["input_tokens"]?.numberValue, let output = usage["output_tokens"]?.numberValue else { return nil }
            let read = Int(usage["cache_read_input_tokens"]?.numberValue ?? 0)
            let write = Int(usage["cache_creation_input_tokens"]?.numberValue ?? 0)
            // `input_tokens` counts only uncached input; the total includes cache reads and writes.
            return ModelUsage(inputTokens: Int(input) + read + write, outputTokens: Int(output),
                              cacheReadTokens: read, cacheWriteTokens: write)
        }
        let text = texts.joined(separator: "\n")
        return ModelResponse(message: ModelMessage(role: .assistant, content: text.isEmpty ? [] : [.text(text)], toolCalls: calls,
                                                   providerEcho: ["anthropic_content": .array(blocks)]),
                             stopReason: stop, usage: usage)
    }
}
