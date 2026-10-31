import Foundation
import Testing
@testable import ZoopAgents
import ZoopShared

/// Records requests and replays canned HTTP responses.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(Int, String, [String: String])]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [(Int, String, [String: String])]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body, headers) = lock.withLock {
            requests.append(request)
            return replies.isEmpty ? (500, "{}", [:]) : replies.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        return (Data(body.utf8), response)
    }

    var sentBodies: [JSONValue] { lock.withLock { requests.compactMap { $0.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } } } }
}

let endpoint = ModelEndpoint(provider: "gemini", baseURL: URL(string: "https://example.test/v1/")!, apiKey: "k", model: "m",
                             extraHeaders: ["X-Title": "Zoop"], simplifiesSchemas: true)

@Suite struct OpenAICompatibleModelTests {
    @Test func encodesConversationToolsAndImagesInChatCompletionsFormat() throws {
        let request = ModelRequest(system: "sys", messages: [
            .user("do it"),
            ModelMessage(role: .assistant, content: [], toolCalls: [ModelToolCall(id: "c1", name: "click", arguments: #"{"x":1}"#)]),
            .toolResult(id: "c1", #"{"ok":true}"#),
            ModelMessage(role: .user, content: [.text("shot"), .image(data: Data([1, 2]), mediaType: "image/jpeg")]),
        ], tools: [ModelTool(name: "click", description: "d", inputSchema: [
            "type": "object", "additionalProperties": false,
            "properties": ["default": ["type": "boolean", "default": false]],
        ])], maxOutputTokens: 100)
        let body = OpenAICompatibleModel.body(for: request, endpoint: endpoint)
        #expect(body["model"] == "m")
        #expect(body["max_tokens"] == 100)
        #expect(body["tool_choice"] == "auto")
        guard case .array(let messages)? = body["messages"] else { Issue.record("no messages"); return }
        #expect(messages[0] == ["role": "system", "content": "sys"])
        #expect(messages[1] == ["role": "user", "content": "do it"])
        #expect(messages[2]["tool_calls"]?.jsonText == #"[{"function":{"arguments":"{\"x\":1}","name":"click"},"id":"c1","type":"function"}]"#)
        #expect(messages[3] == ["role": "tool", "tool_call_id": "c1", "content": #"{"ok":true}"#])
        #expect(messages[4]["content"]?.jsonText == #"[{"text":"shot","type":"text"},{"image_url":{"url":"data:image/jpeg;base64,AQI="},"type":"image_url"}]"#)
        // Gemini-style simplification removes additionalProperties/default but keeps a property named "default".
        let parameters = body["tools"].flatMap { if case .array(let tools) = $0 { tools.first } else { nil } }?["function"]?["parameters"]
        #expect(parameters == ["type": "object", "properties": ["default": ["type": "boolean"]]])
    }

    @Test func decodesToolCallsUsageAndEchoesSafeFieldsOnly() throws {
        let json = #"""
        {"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":"Looking.","annotations":[],"refusal":null,
          "tool_calls":[{"type":"function","function":{"name":"screenshot","arguments":"{}"},"extra_content":{"google":{"thought_signature":"sig"}}},
                        {"id":"b","type":"function","function":{"name":"click","arguments":{"x":3,"y":4}}}]}}],
         "usage":{"prompt_tokens":10,"completion_tokens":5}}
        """#
        let response = try OpenAICompatibleModel.response(from: Data(json.utf8))
        #expect(response.stopReason == .toolCalls)
        #expect(response.usage == ModelUsage(inputTokens: 10, outputTokens: 5))
        #expect(response.message.text == "Looking.")
        #expect(response.message.toolCalls == [ModelToolCall(id: "call_0", name: "screenshot", arguments: "{}"),
                                                ModelToolCall(id: "b", name: "click", arguments: #"{"x":3,"y":4}"#)])
        let echo = try #require(response.message.providerEcho)
        #expect(echo["annotations"] == nil && echo["refusal"] == nil)
        #expect(echo["role"] == "assistant")
        // The generated id is written into the echo, and provider extras on the call survive.
        #expect(echo.jsonText.contains(#""id":"call_0""#))
        #expect(echo.jsonText.contains("thought_signature"))
        #expect(OpenAICompatibleModel.encode(response.message) == echo)
    }

    @Test func retriesRateLimitsThenSucceeds() async throws {
        let ok = #"{"choices":[{"finish_reason":"stop","message":{"content":"OK"}}]}"#
        let transport = FakeTransport([(429, #"{"error":{"message":"slow down"}}"#, ["Retry-After": "0"]), (200, ok, [:])])
        let model = OpenAICompatibleModel(endpoint: endpoint, transport: transport, retryDelay: .milliseconds(1))
        let response = try await model.complete(ModelRequest(system: "s", messages: [.user("hi")]))
        #expect(response.message.text == "OK")
        #expect(response.stopReason == .endTurn)
        #expect(transport.requests.count == 2)
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://example.test/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(request.value(forHTTPHeaderField: "X-Title") == "Zoop")
    }

    @Test func mapsHTTPFailuresToModelErrors() async {
        let cases: [(Int, String, ModelError)] = [
            (401, #"{"error":{"message":"bad key"}}"#, .authentication("HTTP 401: bad key")),
            (400, #"[{"error":{"message":"unknown model"}}]"#, .badRequest("HTTP 400: unknown model")),
            (503, "down", .unavailable("HTTP 503: down")),
        ]
        for (status, body, expected) in cases {
            let model = OpenAICompatibleModel(endpoint: endpoint, transport: FakeTransport(Array(repeating: (status, body, [:]), count: 3)),
                                              maxRetries: 1, retryDelay: .milliseconds(1))
            await #expect(throws: expected) { try await model.complete(ModelRequest(system: "s", messages: [.user("hi")])) }
        }
    }
}

@Suite struct ModelConfigurationTests {
    @Test func environmentOverridesFileAndFlagsOverrideBoth() throws {
        let file: JSONValue = ["agents": ["executor": ["provider": "openrouter", "model": "file-model"]],
                               "providers": ["openrouter": ["apiKey": "file-key"], "gemini": ["apiKey": "g-file"]]]
        let fromFile = try ModelConfiguration(environment: [:], file: file).endpoint(for: .executor)
        #expect(fromFile.provider == "openrouter" && fromFile.model == "file-model" && fromFile.apiKey == "file-key")
        #expect(fromFile.baseURL.absoluteString == "https://openrouter.ai/api/v1/")

        let environment = ["ZOOP_EXECUTOR_MODEL": "env-model", "OPENROUTER_API_KEY": "env-key"]
        let fromEnv = try ModelConfiguration(environment: environment, file: file).endpoint(for: .executor)
        #expect(fromEnv.model == "env-model" && fromEnv.apiKey == "env-key")

        let flagged = try ModelConfiguration(environment: environment, file: file)
            .endpoint(for: .executor, overrides: .init(provider: "gemini", model: "flag-model"))
        #expect(flagged.provider == "gemini" && flagged.model == "flag-model" && flagged.apiKey == "g-file" && flagged.simplifiesSchemas)
    }

    @Test func explainsMissingSettings() {
        let empty = ModelConfiguration(environment: [:], file: [:])
        #expect(throws: ModelError.self) { try empty.endpoint(for: .executor) }
        #expect(throws: ModelError.self) { try empty.endpoint(for: .executor, overrides: .init(provider: "gemini", model: "m")) }
        #expect(throws: ModelError.self) { try empty.endpoint(for: .executor, overrides: .init(provider: "nope", model: "m")) }
        #expect(throws: ModelError.self) { try empty.endpoint(for: .executor, overrides: .init(provider: "custom", model: "m")) }
        // Local servers need no key.
        #expect(throws: Never.self) { try empty.endpoint(for: .chat, overrides: .init(provider: "ollama", model: "m")) }
    }
}
