import Darwin
import Foundation
import ZoopShared

/// Runs only in ZoopHelper's GUI session. Never invokes a shell or physical input.
struct AgentDesktopClient: Sendable {
    let executable: URL

    static func installed(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self? {
        if let path = environment["ZOOP_AGENT_DESKTOP_BIN"] {
            guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
                throw HelperFailure(.unsupported, "ZOOP_AGENT_DESKTOP_BIN must name an executable at an absolute path in the agent session.")
            }
            return Self(executable: URL(fileURLWithPath: path))
        }
        let bundled = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("agent-desktop")
        let paths = [bundled?.path, "/opt/homebrew/bin/agent-desktop", "/usr/local/bin/agent-desktop"]
        return paths.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { Self(executable: URL(fileURLWithPath: $0)) }
    }

    func snapshot(app: String, surface: String, windowID: String?) async throws -> JSONValue {
        var arguments = ["snapshot", "--app", app, "--surface", surface, "--include-bounds", "--max-depth", "30", "--timeout-ms", "3000"]
        if let windowID { arguments += ["--window-id", windowID] }
        var envelope = try await command(arguments)
        // Some system hosts expose a normal AXWindow, and some apps nest their sheet
        // beyond agent-desktop's surface search. Widen only this read, never an action.
        if surface != "window", envelope["error"]?["code"] == "WINDOW_NOT_FOUND" {
            if let index = arguments.firstIndex(of: "--surface") { arguments[index + 1] = "window" }
            envelope = try await command(arguments)
        }
        if envelope["ok"] == true, let windowID, envelope["data"]?["window"]?["id"] != .string(windowID) {
            throw HelperFailure(.unsupported, "agent-desktop observed a different window. Nothing was pressed.")
        }
        return envelope
    }

    /// Bind a fresh qualified ref to the button already reviewed in Zoop. Bounds only
    /// correlate the two observations; agent-desktop revalidates the ref before delivery.
    static func reference(in envelope: JSONValue, target: ElementInfo, label: String) throws -> String {
        let data = try result(envelope, command: "snapshot")
        guard data["complete"] == true, let snapshotID = data["snapshot_id"]?.stringValue, !snapshotID.isEmpty,
              let tree = data["tree"], let frame = target.frame else {
            throw HelperFailure(.unsupported, "agent-desktop could not completely observe this dialog and button. Nothing was pressed.")
        }
        var queue = [tree], index = 0, matches: [String] = []
        while index < queue.count {
            guard queue.count <= 5000, queue[index]["subtree_truncated"] != true else {
                throw HelperFailure(.unsupported, "agent-desktop returned an incomplete dialog tree. Nothing was pressed.")
            }
            let node = queue[index]; index += 1
            if case .array(let children)? = node["children"] { queue.append(contentsOf: children) }
            guard node["role"] == "button", (node["name"]?.stringValue ?? node["description"]?.stringValue) == label,
                  let bounds = node["bounds"], sameBounds(bounds, frame),
                  case .array(let states) = node["states"] ?? .array([]), !states.contains("disabled"),
                  case .array(let actions)? = node["available_actions"], actions.contains("Click"),
                  let ref = node["ref_id"]?.stringValue else { continue }
            if let identifier = target.identifier, !identifier.isEmpty,
               node["native_id"]?["value"]?.stringValue != identifier { continue }
            let prefix = "@\(snapshotID):e"
            guard ref.hasPrefix(prefix), !ref.dropFirst(prefix.count).isEmpty,
                  ref.dropFirst(prefix.count).allSatisfy({ $0.isASCII && $0.isNumber }) else { continue }
            matches.append(ref)
        }
        guard matches.count == 1 else {
            throw HelperFailure(.unsupported, "agent-desktop could not uniquely match the reviewed \(label) button (\(matches.count) matches). Nothing was pressed; inspect the agent session.")
        }
        return matches[0]
    }

    static func sameBounds(_ bounds: JSONValue, _ frame: Rect) -> Bool {
        let values = [("x", frame.x), ("y", frame.y), ("width", frame.width), ("height", frame.height)]
        return frame.width > 0 && frame.height > 0 && values.allSatisfy { key, expected in
            guard expected.isFinite, let actual = bounds[key]?.numberValue, actual.isFinite else { return false }
            return abs(actual - expected) <= 0.5
        }
    }

    /// A command's success is delivery evidence, never proof that a dialog closed.
    /// There is deliberately no retry or native-click fallback after this call starts.
    func click(_ ref: String) async throws -> String {
        let envelope = try await command(["click", ref, "--timeout-ms", "3000"])
        let data = try Self.result(envelope, command: "click")
        return data["disposition"]?["delivery"]?.stringValue ?? "unknown"
    }

    static func result(_ envelope: JSONValue, command: String) throws -> JSONValue {
        guard envelope["version"] == "2.6", envelope["command"] == .string(command) else {
            throw HelperFailure(.unsupported, "Unsupported agent-desktop JSON contract; install the version pinned by Scripts/fetch-agent-desktop.sh. No automatic retry was sent.")
        }
        guard envelope["ok"] == true, let data = envelope["data"] else {
            let error = envelope["error"]
            let code = error?["code"]?.stringValue ?? "UNKNOWN"
            let delivery = error?["disposition"]?["delivery"]?.stringValue ?? "unknown"
            let retry = error?["disposition"]?["retry"]?.stringValue ?? "unknown"
            // Only a proven unsent stale reference may return to the human-review loop.
            let stale = ["STALE_REF", "SNAPSHOT_NOT_FOUND", "ELEMENT_NOT_FOUND"].contains(code)
                && delivery == "not_delivered" && retry == "safe"
            throw HelperFailure(stale ? .notFound : .unsupported,
                "agent-desktop \(command): \(code) (delivery: \(delivery), retry: \(retry)). \(error?["message"]?.stringValue ?? "No result") No automatic retry was sent. Check Accessibility for ZoopHelper and agent-desktop in the agent user's session if permission was denied.")
        }
        return data
    }

    private func command(_ arguments: [String]) async throws -> JSONValue {
        let command = DesktopCommand(executable: executable, arguments: arguments)
        let output: Data
        do {
            output = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in command.start(continuation) }
            } onCancel: { command.stop() }
        } catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        do { return try JSONDecoder().decode(JSONValue.self, from: output) }
        catch { throw HelperFailure(.unsupported, "agent-desktop returned unreadable output. Delivery is unknown; no fallback click was sent.") }
    }
}

/// Drain stdout off the actor; bound output, lifetime, and cancellation, including a
/// child that ignores SIGTERM. stderr cannot fill a second pipe or corrupt JSON output.
private final class DesktopCommand: @unchecked Sendable {
    private let process = Process()
    private let pipe = Pipe()
    private let lock = NSLock()
    private var stopped = false
    private var finished = false

    init(executable: URL, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        // A user's active CLI session or headed defaults must not change helper behavior.
        environment.removeValue(forKey: "AGENT_DESKTOP_SESSION")
        process.environment = environment
    }

    func start(_ continuation: CheckedContinuation<Data, any Error>) {
        DispatchQueue.global().async { [self] in
            do {
                try lock.withLock {
                    guard !stopped else { throw CancellationError() }
                    try process.run()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 8) { [self] in stop() }
                var output = Data()
                while let chunk = try pipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                    guard output.count + chunk.count <= 2_000_000 else {
                        stop()
                        throw HelperFailure(.unsupported, "agent-desktop output exceeded its limit; delivery is unknown. No fallback click was sent.")
                    }
                    output.append(chunk)
                }
                process.waitUntilExit()
                let interrupted = lock.withLock { finished = true; return stopped }
                guard !interrupted else {
                    throw HelperFailure(.unsupported, "agent-desktop was cancelled or exceeded its deadline; delivery is unknown. No fallback click was sent.")
                }
                // Nonzero exits carry structured errors, which must still be decoded.
                continuation.resume(returning: output)
            } catch {
                lock.withLock {
                    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                    finished = true
                }
                if process.isRunning { process.waitUntilExit() }
                continuation.resume(throwing: error)
            }
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
    }

    func stop() {
        lock.withLock {
            guard !finished else { return }
            stopped = true
            if process.isRunning {
                process.terminate()
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [self] in
                    lock.withLock { if !finished && process.isRunning { _ = Darwin.kill(pid, SIGKILL) } }
                }
            }
        }
    }
}
