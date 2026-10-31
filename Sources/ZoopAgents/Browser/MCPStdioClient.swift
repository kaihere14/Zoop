import Foundation
import ZoopShared

public enum MCPError: Error, CustomStringConvertible {
    case launchFailed(String)
    case closed(String)
    case timedOut(String)
    case server(String)

    public var description: String {
        switch self {
        case .launchFailed(let detail): "Could not start the browser tools: \(detail)"
        case .closed(let detail): "The browser tools stopped: \(detail)"
        case .timedOut(let method): "The browser did not answer \(method) in time."
        case .server(let message): message
        }
    }
}

/// A minimal Model Context Protocol client over stdio: newline-delimited JSON-RPC 2.0 with a
/// child process. Used for Microsoft's Playwright MCP server; only `initialize`, `tools/list` and
/// `tools/call` are needed. Server notifications are ignored.
actor MCPStdioClient {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var reader: Task<Void, Never>?
    private var closedReason: String?

    init(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    var isRunning: Bool { process.isRunning && closedReason == nil }

    func start() async throws {
        do { try process.run() } catch { throw MCPError.launchFailed(String(describing: error)) }
        let lines = output.fileHandleForReading.bytes.lines
        reader = Task { [weak self] in
            do {
                for try await line in lines { await self?.receive(line) }
                await self?.fail("the server closed its output")
            } catch { await self?.fail(String(describing: error)) }
        }
        _ = try await request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:],
                                             "clientInfo": ["name": "Zoop", "version": "0.1"]], timeout: .seconds(60))
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    func request(_ method: String, _ params: JSONValue, timeout: Duration) async throws -> JSONValue {
        if let closedReason { throw MCPError.closed(closedReason) }
        nextID += 1
        let id = nextID
        let message: JSONValue = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.resolve(id, .failure(MCPError.timedOut(method)))
        }
        defer { watchdog.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try send(message) } catch { resolve(id, .failure(error)) }
        }
    }

    func stop() {
        fail("stopped by Zoop")
        if process.isRunning { process.terminate() }
    }

    private func send(_ message: JSONValue) throws {
        guard let data = (message.jsonText + "\n").data(using: .utf8) else { return }
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func receive(_ line: String) {
        guard let message = try? JSONValue.parse(line), let id = message["id"]?.numberValue.map(Int.init) else { return }
        if let error = message["error"] {
            resolve(id, .failure(MCPError.server(error["message"]?.stringValue ?? error.jsonText)))
        } else {
            resolve(id, .success(message["result"] ?? .null))
        }
    }

    private func resolve(_ id: Int, _ result: Result<JSONValue, any Error>) {
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func fail(_ reason: String) {
        if closedReason == nil { closedReason = reason }
        let waiting = pending
        pending = [:]
        for continuation in waiting.values { continuation.resume(throwing: MCPError.closed(reason)) }
    }
}
