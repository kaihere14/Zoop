import Foundation
import Testing
@testable import ZoopShared

@Suite struct SessionToolsTests {
    @Test func catalogCoversEveryToolOnceWithConsistentSchemas() throws {
        #expect(SessionTools.catalog.map(\.name) == SessionToolName.allCases)
        for tool in SessionTools.catalog {
            #expect(!tool.summary.isEmpty && !tool.usage.isEmpty && !tool.returns.isEmpty)
            let schema = tool.inputSchema
            #expect(schema["type"] == "object")
            #expect(schema["additionalProperties"] == false)
            let properties = try #require(schema["properties"]?.objectValue)
            #expect(Set(properties.keys) == Set(tool.parameters.map(\.name)))
            #expect(schema["required"] == .array(tool.parameters.filter(\.required).map { .string($0.name) }))
            #expect(tool.declaration["name"] == .string(tool.name.rawValue))
        }
    }

    /// Docs/AgentTools.md is generated; regenerate with `zoop-bridge tools --markdown`.
    @Test func referenceDocumentIsUpToDate() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let document = try String(contentsOf: root.appendingPathComponent("Docs/AgentTools.md"), encoding: .utf8)
        #expect(document == SessionTools.referenceMarkdown(),
                "Docs/AgentTools.md is stale: run `swift run zoop-bridge tools --markdown > Docs/AgentTools.md`")
    }

    @Test func validationRejectsBadArgumentsBeforeTheHelper() {
        let click = SessionTools.definition(for: .click)
        let cases: [(JSONValue, String)] = [
            (["x": 1, "y": 2, "z": 3], "unknown argument 'z'"),
            (["x": "1", "y": 2], "'x' must be a number"),
            (["x": -1, "y": 2], "'x' must be at least 0"),
            (["x": 1, "y": 2, "button": "middle"], "'button' must be one of left, right"),
            (["x": 1, "y": 2, "double": "yes"], "'double' must be true or false"),
            ("text", "arguments must be a JSON object"),
        ]
        for (arguments, message) in cases {
            do {
                _ = try click.validate(arguments)
                Issue.record("accepted \(arguments.jsonText)")
            } catch {
                guard case .invalidArguments(let text) = error else { Issue.record("wrong error \(error)"); continue }
                #expect(text.hasPrefix(message))
            }
        }
        #expect(throws: Never.self) { try click.validate(["x": 1.5, "y": 2, "button": "right"]) }
        #expect(throws: ToolCallError.self) { try SessionTools.definition(for: .listElements).validate(["bundle_id": "a", "limit": 2.5]) }
        #expect(throws: ToolCallError.self) { try SessionTools.definition(for: .scrollTo).validate(["x": 1, "y": 2, "position": 1.5]) }
        #expect(throws: ToolCallError.invalidArguments("missing required argument 'text'")) { try SessionTools.definition(for: .setText).validate([:]) }
        #expect(throws: ToolCallError.invalidArguments("'actions' needs at least 1 item")) { try SessionTools.definition(for: .batch).validate(["actions": []]) }
        #expect(throws: Never.self) { try SessionTools.definition(for: .sessionStatus).validate(.null) }
    }

    @Test func jsonValueRoundTripsAndPrintsWholeNumbersAsIntegers() throws {
        let value: JSONValue = ["a": [1, 2.5, "x", true, nil], "b": ["c": false]]
        #expect(try JSONValue.parse(value.jsonText) == value)
        #expect(value.jsonText == #"{"a":[1,2.5,"x",true,null],"b":{"c":false}}"#)
    }

    @Test func failuresMapToStableCodesRetryRulesAndNextSteps() {
        func content(_ error: Error, readOnly: Bool = false) -> JSONValue {
            SessionToolbox.failure("click", error, readOnly: readOnly).content
        }
        let expectations: [(Error, Bool, String, String)] = [
            (ToolCallError.invalidArguments("x"), false, "invalid_arguments", "no"),
            (HelperFailure(.notFound, "gone"), false, "not_found", "after_check"),
            (BridgeError.helperFailure(HelperFailure(.unsupported, "no AXPress")), false, "unsupported", "no"),
            (BridgeError.helperFailure(HelperFailure(.permissionDenied, "grant it")), false, "permission_denied", "no"),
            (BridgeError.interrupted(command: "click"), false, "interrupted", "after_check"),
            (BridgeError.timedOut(command: "capture", seconds: 15), true, "timed_out", "safe"),
            (BridgeError.versionMismatch(client: 5, helper: 4), true, "setup_error", "no"),
            (BridgeError.retriesExhausted(attempts: 4, last: .helperUnavailable("no socket")), true, "helper_unavailable", "no"),
        ]
        for (error, readOnly, code, retry) in expectations {
            let result = content(error, readOnly: readOnly)
            #expect(result["ok"] == false)
            #expect(result["error"] == .string(code))
            #expect(result["retry"] == .string(retry))
            #expect(result["next"]?.stringValue?.isEmpty == false)
        }
    }

    @Test func elementLinesAreCompactAndBounded() {
        let element = ElementInfo(role: "AXTextArea", value: String(repeating: "Line\n", count: 50),
                                  frame: Rect(x: 0, y: 0, width: 100, height: 50), actions: ["AXShowMenu"], pid: 1, app: "com.apple.TextEdit")
        let line = SessionToolbox.line(element)
        #expect(line.hasPrefix("AXTextArea \"Line\\nLine"))
        #expect(line.contains("…\" at (50, 25) actions: AXShowMenu [com.apple.TextEdit]"))
        #expect(!line.contains("value="))
        #expect(line.count < 200)
    }
}
