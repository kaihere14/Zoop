import Foundation
import Testing
import ZoopShared
@testable import ZoopAgents

@Suite struct AnthropicModelTests {
    let endpoint = ModelEndpoint(provider: "anthropic", baseURL: URL(string: "https://api.anthropic.com/v1/")!, apiKey: "sk-test", model: "claude-haiku-5-5")

    @Test func toolLoopRoundTripsInTheMessagesFormat() async throws {
        let first = #"{"content":[{"type":"text","text":"Checking."},{"type":"tool_use","id":"toolu_1","name":"screenshot","input":{}}],"stop_reason":"tool_use","usage":{"input_tokens":50,"output_tokens":9,"cache_creation_input_tokens":6000,"cache_read_input_tokens":0}}"#
        let second = #"{"content":[{"type":"text","text":"Done: heads"}],"stop_reason":"end_turn","usage":{"input_tokens":120,"output_tokens":4,"cache_read_input_tokens":6000}}"#
        let transport = FakeTransport([(200, first, [:]), (429, #"{"type":"error","error":{"type":"rate_limit_error","message":"slow"}}"#, ["retry-after": "0"]), (200, second, [:])])
        let model = AnthropicModel(endpoint: endpoint, transport: transport, retryDelay: .milliseconds(1))
        let tool = ModelTool(name: "screenshot", description: "Take one", inputSchema: ["type": "object", "properties": [:]])

        let reply = try await model.complete(ModelRequest(system: "sys", messages: [.user("flip a coin")], tools: [tool]))
        #expect(reply.message.toolCalls == [ModelToolCall(id: "toolu_1", name: "screenshot", arguments: "{}")])
        #expect(reply.usage == ModelUsage(inputTokens: 6050, outputTokens: 9, cacheReadTokens: 0, cacheWriteTokens: 6000))

        let image = ModelMessage(role: .user, content: [.text("shot"), .image(data: Data([1, 2]), mediaType: "image/jpeg")])
        let done = try await model.complete(ModelRequest(system: "sys", messages: [.user("flip a coin"), reply.message,
                                                                                      .toolResult(id: "toolu_1", "ok"), image], tools: [tool]))
        #expect(done.message.text == "Done: heads" && done.usage?.cacheReadTokens == 6000)

        let request = try #require(transport.requests.last)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == AnthropicModel.apiVersion)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        let body = try #require(transport.sentBodies.last)
        #expect(body["thinking"]?["type"]?.stringValue == "disabled")
        #expect(body["system"]?.arrayValue?.first?["cache_control"]?["type"]?.stringValue == "ephemeral")
        #expect(body["tools"]?.arrayValue?.first?["input_schema"]?["type"]?.stringValue == "object")
        let messages = try #require(body["messages"]?.arrayValue)
        #expect(messages.map { $0["role"]?.stringValue } == ["user", "assistant", "user"])
        // Claude's own assistant blocks are echoed unchanged.
        #expect(messages[1]["content"]?.arrayValue?.last?["id"]?.stringValue == "toolu_1")
        // The tool result comes first in the merged user turn, then the screenshot.
        let merged = try #require(messages[2]["content"]?.arrayValue)
        #expect(merged.map { $0["type"]?.stringValue } == ["tool_result", "text", "image"])
        #expect(merged[2]["source"]?["media_type"]?.stringValue == "image/jpeg")
    }

    @Test func refusalsAndAuthFailuresBecomeErrors() async {
        let refusal = #"{"content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","explanation":"policy"}}"#
        let refused = AnthropicModel(endpoint: endpoint, transport: FakeTransport([(200, refusal, [:])]))
        await #expect(throws: ModelError.self) { try await refused.complete(ModelRequest(system: "", messages: [.user("x")])) }
        let denied = AnthropicModel(endpoint: endpoint, transport: FakeTransport([(401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#, [:])]))
        await #expect(throws: ModelError.authentication("HTTP 401: invalid x-api-key")) { try await denied.complete(ModelRequest(system: "", messages: [.user("x")])) }
    }

    @Test func configurationRoutesClaudeToTheMessagesAdapter() throws {
        let file: JSONValue = ["agents": ["chat": ["provider": "anthropic", "model": "claude-haiku-5-5"]]]
        let model = try ModelConfiguration(environment: [:], file: file, keys: InMemoryKeyStore([.anthropic: "k"])).model(for: .chat)
        #expect((model as? TracingModel)?.base is AnthropicModel)
    }
}

private extension JSONValue {
    var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
}
