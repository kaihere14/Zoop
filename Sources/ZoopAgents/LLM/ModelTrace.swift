import Foundation
import ZoopShared

/// Which run a model call belongs to. Set around one chat reply or one task execution, so every
/// model call and HTTP attempt inside it is logged with the same `runID`.
public struct TraceContext: Sendable {
    public var runID: String
    public var label: String
    public init(runID: String = String(UUID().uuidString.prefix(8)).lowercased(), label: String) {
        self.runID = runID
        self.label = label
    }
}

/// A local log of every model call: what was sent (sizes, not the screenshots themselves), how many
/// tokens the provider billed, which tools the model asked for, and every HTTP attempt including
/// rate-limit retries. One JSON object per line in `~/Zoop/logs/model-calls-YYYY-MM-DD.jsonl`.
/// Read it with `zoop-agent trace`.
///
/// The log contains screen text and tool output (for example email drafts), so it stays on this
/// Mac and is readable only by this user.
public enum ModelTrace {
    @TaskLocal public static var context: TraceContext?

    public static var directory: URL {
        if let custom = ProcessInfo.processInfo.environment["ZOOP_LOG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Zoop/logs", isDirectory: true)
    }

    public static func file(for date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return directory.appendingPathComponent("model-calls-\(formatter.string(from: date)).jsonl")
    }

    static func record(_ type: String, role: AgentRole, _ fields: [String: JSONValue]) {
        var entry = fields
        entry["type"] = .string(type)
        entry["role"] = .string(role.rawValue)
        entry["time"] = .string(ISO8601DateFormatter().string(from: Date()))
        if let context {
            entry["run"] = .string(context.runID)
            entry["label"] = .string(context.label)
        }
        TraceWriter.shared.append(JSONValue.object(entry).jsonText, to: file())
    }
}

private final class TraceWriter: @unchecked Sendable {
    static let shared = TraceWriter()
    private let lock = NSLock()

    func append(_ line: String, to url: URL) {
        lock.withLock {
            let manager = FileManager.default
            do {
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !manager.fileExists(atPath: url.path) {
                    manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((line + "\n").utf8))
            } catch {
                // Logging must never break a task.
            }
        }
    }
}

/// Wraps a model and logs each call with a size breakdown of the request.
struct TracingModel: ChatModel {
    let base: any ChatModel
    let role: AgentRole
    var name: String { base.name }

    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        let start = ContinuousClock.now
        var fields = Self.profile(request)
        fields["model"] = .string(base.name)
        do {
            let response = try await base.complete(request)
            fields["ms"] = .number(Double(Self.milliseconds(since: start)))
            if let usage = response.usage {
                fields["inputTokens"] = .number(Double(usage.inputTokens))
                fields["outputTokens"] = .number(Double(usage.outputTokens))
                if usage.cacheReadTokens > 0 { fields["cacheReadTokens"] = .number(Double(usage.cacheReadTokens)) }
                if usage.cacheWriteTokens > 0 { fields["cacheWriteTokens"] = .number(Double(usage.cacheWriteTokens)) }
            }
            fields["stop"] = .string(String(describing: response.stopReason))
            fields["toolCalls"] = .array(response.message.toolCalls.map {
                ["name": .string($0.name), "arguments": .string(String($0.arguments.prefix(240)))]
            })
            let text = response.message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { fields["text"] = .string(String(text.prefix(300))) }
            ModelTrace.record("call", role: role, fields)
            return response
        } catch {
            fields["ms"] = .number(Double(Self.milliseconds(since: start)))
            fields["error"] = .string(String(String(describing: error).prefix(400)))
            ModelTrace.record("call", role: role, fields)
            throw error
        }
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Character counts per part of the request (about 4 characters per token for English text),
    /// the largest messages, and a preview of the newest ones, which show what the model just saw.
    static func profile(_ request: ModelRequest) -> [String: JSONValue] {
        var toolNames: [String: String] = [:]
        for message in request.messages { for call in message.toolCalls { toolNames[call.id] = call.name } }
        func label(_ message: ModelMessage) -> String {
            switch message.role {
            case .tool: "tool:\(message.toolCallID.flatMap { toolNames[$0] } ?? "?")"
            case .assistant: message.toolCalls.isEmpty ? "assistant" : "assistant→\(message.toolCalls.map(\.name).joined(separator: ","))"
            case .user: "user"
            }
        }
        func images(_ message: ModelMessage) -> Int { message.content.filter { if case .image = $0 { true } else { false } }.count }
        func size(_ message: ModelMessage) -> Int { message.text.count + message.toolCalls.reduce(0) { $0 + $1.arguments.count } }

        let toolsChars = request.tools.reduce(0) { $0 + $1.name.count + $1.description.count + $1.inputSchema.jsonText.count }
        let historyChars = request.messages.reduce(0) { $0 + size($1) }
        var byKind: [String: Int] = [:]
        for message in request.messages { byKind[label(message).components(separatedBy: "→")[0], default: 0] += size(message) }
        let largest = request.messages.enumerated().sorted { size($0.element) > size($1.element) }.prefix(3).map { item in
            JSONValue.object(["index": .number(Double(item.offset)), "kind": .string(label(item.element)), "chars": .number(Double(size(item.element)))])
        }
        let newest = request.messages.suffix(3).map { message in
            JSONValue.object(["kind": .string(label(message)), "images": .number(Double(images(message))),
                              "preview": .string(String(message.text.prefix(300)))])
        }
        return [
            "messages": .number(Double(request.messages.count)),
            "images": .number(Double(request.messages.reduce(0) { $0 + images($1) })),
            "systemChars": .number(Double(request.system.count)),
            "toolCount": .number(Double(request.tools.count)),
            "toolsChars": .number(Double(toolsChars)),
            "historyChars": .number(Double(historyChars)),
            "historyByKind": .object(byKind.mapValues { .number(Double($0)) }),
            "largest": .array(Array(largest)),
            "newest": .array(newest),
        ]
    }
}

/// Logs every HTTP attempt, so rate-limit retries inside the adapter are visible too.
struct TracingTransport: HTTPTransport {
    let base: any HTTPTransport
    let role: AgentRole

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let start = ContinuousClock.now
        let bytes = Double(request.httpBody?.count ?? 0)
        do {
            let (data, response) = try await base.send(request)
            var fields: [String: JSONValue] = ["status": .number(Double(response.statusCode)), "requestBytes": .number(bytes),
                                               "ms": .number(Double(TracingModel.milliseconds(since: start)))]
            if !(200..<300).contains(response.statusCode) {
                fields["body"] = .string(String(decoding: data.prefix(400), as: UTF8.self))
                if let retry = response.value(forHTTPHeaderField: "Retry-After") { fields["retryAfter"] = .string(retry) }
            }
            ModelTrace.record("http", role: role, fields)
            return (data, response)
        } catch {
            ModelTrace.record("http", role: role, ["requestBytes": .number(bytes), "error": .string(String(describing: error).prefix(300).description),
                                                   "ms": .number(Double(TracingModel.milliseconds(since: start)))])
            throw error
        }
    }
}
