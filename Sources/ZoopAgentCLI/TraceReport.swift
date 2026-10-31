import Foundation
import ZoopAgents
import ZoopShared

/// `zoop-agent trace`: summarizes the model-call log written by the app and the CLI.
enum TraceReport {
    static func print(file: URL, runs limit: Int, detail: Bool) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            Swift.print("no log at \(file.path) yet. Run a task in Zoop first.")
            return
        }
        let entries = text.split(separator: "\n").compactMap { try? JSONValue.parse(String($0)) }
        var order: [String] = []
        var grouped: [String: [JSONValue]] = [:]
        for entry in entries {
            let run = entry["run"]?.stringValue ?? "-"
            if grouped[run] == nil { order.append(run) }
            grouped[run, default: []].append(entry)
        }
        Swift.print("log: \(file.path)\n")
        for run in order.suffix(limit) {
            let items = grouped[run] ?? []
            let calls = items.filter { $0["type"]?.stringValue == "call" }
            let http = items.filter { $0["type"]?.stringValue == "http" }
            func sum(_ key: String) -> Int { calls.reduce(0) { $0 + Int($1[key]?.numberValue ?? 0) } }
            let rateLimited = http.filter { $0["status"]?.numberValue == 429 }.count
            let failedHTTP = http.filter { ($0["status"]?.numberValue ?? 0) >= 400 || $0["error"] != nil }.count
            Swift.print("■ \(items.first?["label"]?.stringValue ?? "(no label)")  [run \(run)]")
            var roles: [String: (calls: Int, input: Int)] = [:]
            for call in calls {
                let role = call["role"]?.stringValue ?? "?"
                roles[role, default: (0, 0)].calls += 1
                roles[role, default: (0, 0)].input += Int(call["inputTokens"]?.numberValue ?? 0)
            }
            Swift.print("  \(calls.count) model calls, \(http.count) HTTP attempts (\(rateLimited) rate-limited, \(failedHTTP) failed)")
            Swift.print("  tokens: \(sum("inputTokens")) input (\(sum("cacheReadTokens")) cache reads, \(sum("cacheWriteTokens")) cache writes), \(sum("outputTokens")) output")
            if let cost = haikuCost(calls) { Swift.print(String(format: "  estimated cost on Claude Haiku 5.5: $%.4f", cost)) }
            Swift.print("  by agent: " + roles.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.calls) calls / \($0.value.input) in" }.joined(separator: ", "))
            if !calls.isEmpty {
                let fixed = calls.map { Int(($0["systemChars"]?.numberValue ?? 0) + ($0["toolsChars"]?.numberValue ?? 0)) }
                let history = calls.map { Int($0["historyChars"]?.numberValue ?? 0) }
                Swift.print("  per call: system+tools avg \(fixed.reduce(0, +) / fixed.count) chars, history avg \(history.reduce(0, +) / history.count) chars, max \(history.max() ?? 0) chars")
                var toolCounts: [String: Int] = [:]
                for call in calls { for tool in call["toolCalls"]?.arrayValue ?? [] { toolCounts[tool["name"]?.stringValue ?? "?", default: 0] += 1 } }
                Swift.print("  tools requested: " + toolCounts.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))
            }
            for error in calls.compactMap({ $0["error"]?.stringValue }).prefix(3) { Swift.print("  error: \(error)") }
            if detail {
                Swift.print("  #  agent     in     out   ms     msgs img  hist   biggest message           → tools")
                for (index, call) in calls.enumerated() {
                    let biggest = call["largest"]?.arrayValue?.first
                    let tools = (call["toolCalls"]?.arrayValue ?? []).map { tool in
                        "\(tool["name"]?.stringValue ?? "?")(\(String((tool["arguments"]?.stringValue ?? "").prefix(50))))"
                    }.joined(separator: " ")
                    let line = String(format: "  %-2d %-9@ %-6d %-5d %-6d %-4d %-4d %-6d %-25@ → %@",
                        index + 1, (call["role"]?.stringValue ?? "?") as NSString,
                        Int(call["inputTokens"]?.numberValue ?? 0), Int(call["outputTokens"]?.numberValue ?? 0),
                        Int(call["ms"]?.numberValue ?? 0), Int(call["messages"]?.numberValue ?? 0), Int(call["images"]?.numberValue ?? 0),
                        Int(call["historyChars"]?.numberValue ?? 0),
                        "\(biggest?["kind"]?.stringValue ?? "-") \(Int(biggest?["chars"]?.numberValue ?? 0))" as NSString,
                        (call["error"].map { "ERROR \($0.stringValue ?? "")" } ?? tools) as NSString)
                    Swift.print(line)
                }
            }
            Swift.print("")
        }
    }
}

/// Claude Haiku 5.5 list prices for prompts of 100K tokens or fewer: $0.10 / $0.50 per million
/// input / output tokens, cache reads 0.1x and 5-minute cache writes 1.25x the input price.
/// Longer prompts use a higher rate card ($0.50 / $2.50). Only calls made on that model are counted.
func haikuCost(_ calls: [JSONValue]) -> Double? {
    let haiku = calls.filter { $0["model"]?.stringValue?.hasSuffix("claude-haiku-5-5") == true }
    guard !haiku.isEmpty else { return nil }
    return haiku.reduce(0.0) { total, call in
        let input = call["inputTokens"]?.numberValue ?? 0, read = call["cacheReadTokens"]?.numberValue ?? 0
        let write = call["cacheWriteTokens"]?.numberValue ?? 0, output = call["outputTokens"]?.numberValue ?? 0
        let inputRate = input > 100_000 ? 0.50 : 0.10, outputRate = input > 100_000 ? 2.50 : 0.50
        let uncached = max(0, input - read - write)
        return total + (uncached + read * 0.1 + write * 1.25) * inputRate / 1_000_000 + output * outputRate / 1_000_000
    }
}

extension JSONValue {
    var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
}
