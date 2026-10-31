import Foundation

/// An image returned by a tool, ready to attach to a model message.
public struct ToolImage: Sendable, Equatable {
    public var data: Data
    public var mediaType: String
    public var width: Int
    public var height: Int

    public init(data: Data, mediaType: String, width: Int, height: Int) {
        self.data = data
        self.mediaType = mediaType
        self.width = width
        self.height = height
    }
}

/// The outcome of one tool call. `content` is what the model reads; `image` is attached
/// alongside it (screenshots only).
public struct ToolResult: Sendable, Equatable {
    public var tool: String
    public var isError: Bool
    public var content: JSONValue
    public var image: ToolImage?

    public init(tool: String, isError: Bool, content: JSONValue, image: ToolImage? = nil) {
        self.tool = tool
        self.isError = isError
        self.content = content
        self.image = image
    }

    /// `content` as compact JSON, the text to send back to the model.
    public var text: String { content.jsonText }
}

/// Executes agent tool calls against the agent session through the session bridge.
///
/// `call` never throws. Bad arguments, helper failures and connection problems all come back
/// as error results with a stable `error` code and a `next` instruction, so an agent loop can
/// hand every result straight back to the model.
public struct SessionToolbox: Sendable {
    public let connection: HelperConnection

    public init(connection: HelperConnection) {
        self.connection = connection
    }

    public static var definitions: [ToolDefinition] { SessionTools.catalog }

    /// Runs a tool call whose arguments arrive as raw JSON text, as model APIs often deliver them.
    public func call(_ name: String, argumentsJSON: String) async -> ToolResult {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return await call(name, arguments: .object([:])) }
        guard let arguments = try? JSONValue.parse(trimmed) else {
            return Self.failure(name, ToolCallError.invalidArguments("arguments are not valid JSON"), readOnly: true)
        }
        return await call(name, arguments: arguments)
    }

    public func call(_ name: String, arguments: JSONValue = .object([:])) async -> ToolResult {
        guard let tool = SessionToolName(rawValue: name) else {
            let names = SessionToolName.allCases.map(\.rawValue).joined(separator: ", ")
            return Self.failure(name, ToolCallError.unknownTool("unknown tool '\(name)'; available tools: \(names)"), readOnly: true)
        }
        let definition = SessionTools.definition(for: tool)
        do {
            let args = try definition.validate(arguments)
            return try await run(tool, args)
        } catch {
            return Self.failure(name, error, readOnly: definition.isReadOnly)
        }
    }

    // MARK: - Dispatch

    private func run(_ tool: SessionToolName, _ args: ToolArguments) async throws -> ToolResult {
        switch tool {
        case .sessionStatus:
            let session = try await connection.sessionInfo()
            let p = session.permissions
            let missing = [("Screen Recording", p.screenCapture), ("Accessibility", p.accessibility),
                           ("Send input events", p.postEvent)].filter { !$0.1 }.map(\.0)
            var content: [String: JSONValue] = [
                "user": .string(session.user),
                "on_console": .bool(session.onConsole),
                "display": ["width": .number(Double(session.displayWidth)), "height": .number(Double(session.displayHeight))],
                "permissions": ["screen_recording": .bool(p.screenCapture), "accessibility": .bool(p.accessibility),
                                "post_events": .bool(p.postEvent)],
            ]
            if !missing.isEmpty {
                content["next"] = .string("Tell the person to grant \(missing.joined(separator: ", ")) to ZoopHelper in the agent session (System Settings > Privacy & Security).")
            }
            return Self.success(tool, content)

        case .screenshot:
            // Downscale to the display's point width so one image pixel is one point.
            let width = try await connection.connect().session.displayWidth
            let frame = try await connection.capture(CaptureOptions(maxPixelWidth: width > 0 ? width : nil))
            let m = frame.metadata
            let scale = (m.pointWidth / Double(max(m.width, 1)) * 10_000).rounded() / 10_000
            var result = Self.success(tool, ["width": .number(Double(m.width)), "height": .number(Double(m.height)),
                                             "points_per_pixel": .number(scale)])
            result.image = ToolImage(data: frame.png, mediaType: "image/png", width: m.width, height: m.height)
            return result

        case .openApp:
            let app = try await connection.openApp(bundleID: args.string("bundle_id")!)
            return Self.success(tool, ["app": .string(app.bundleID), "name": .string(app.name), "pid": .number(Double(app.pid)),
                                       "next": "Take a screenshot before acting on the app's window."])

        case .listElements:
            let bundleID = args.string("bundle_id")!
            let limit = Int(args.number("limit") ?? 200)
            let all = args.bool("all", default: false)
            let list = try await connection.elements(ElementQuery(bundleID: bundleID, interactiveOnly: !all, limit: limit))
            let lines = list.filter { element in
                guard let frame = element.frame else { return false }
                return frame.width > 0 && frame.height > 0
            }.map(Self.line)
            var content: [String: JSONValue] = ["app": .string(bundleID), "count": .number(Double(lines.count)),
                                                "elements": .array(lines.map(JSONValue.string))]
            if list.count >= limit {
                content["next"] = .string("The list reached the limit and may be incomplete. Raise `limit` if the target is missing.")
            }
            return Self.success(tool, content)

        case .inspectPoint:
            let list = try await connection.inspect(at: Point(x: args.number("x")!, y: args.number("y")!))
            return Self.success(tool, ["elements": .array(list.map { .string(Self.line($0)) })])

        case .click:
            let right = args.string("button") == "right"
            let double = args.bool("double", default: false)
            if right && double { throw ToolCallError.invalidArguments("double click is only available with the left button") }
            let byPoint = try Self.checkClickTarget(args)
            let point = byPoint ? Point(x: args.number("x")!, y: args.number("y")!)
                                : try await resolve(args.string("element")!, in: args.string("bundle_id")!)
            return try await act(tool, .click(ClickAction(point: point, button: right ? .right : .left, count: double ? 2 : 1)))

        case .typeText:
            return try await act(tool, .type(text: args.string("text")!))

        case .setText:
            guard args.has("x") == args.has("y") else { throw ToolCallError.invalidArguments("give x and y together, or neither") }
            let point = args.has("x") ? Point(x: args.number("x")!, y: args.number("y")!) : nil
            return try await act(tool, .setText(SetTextAction(text: args.string("text")!, point: point)))

        case .pressKey:
            let keys = args.string("keys")!
            guard let combo = KeyCombo.parse(keys) else {
                throw ToolCallError.invalidArguments("'\(keys)' is not a key combination; write modifiers and one key joined by +, such as cmd+l")
            }
            return try await act(tool, .key(combo))

        case .scrollTo:
            let point = Point(x: args.number("x")!, y: args.number("y")!)
            let axis: ScrollAxis = args.bool("horizontal", default: false) ? .horizontal : .vertical
            return try await act(tool, .scrollTo(ScrollToAction(point: point, axis: axis, fraction: args.number("position")!)))

        case .batch:
            return try await runBatch(args.values["actions"] ?? .array([]))
        }
    }

    /// A click needs exactly one target form. Returns true for a point, false for a name.
    static func checkClickTarget(_ args: ToolArguments) throws(ToolCallError) -> Bool {
        let byPoint = args.has("x") && args.has("y")
        let byName = args.has("bundle_id") && args.has("element")
        guard byPoint != byName, args.has("x") == args.has("y"), args.has("bundle_id") == args.has("element") else {
            throw .invalidArguments("give x and y, or bundle_id and element (not both)")
        }
        return byPoint
    }

    // MARK: - Batch

    /// Checks every action first, so a malformed one stops the batch before anything runs,
    /// then runs them in order and stops at the first failure or `verified: false`.
    private func runBatch(_ value: JSONValue) async throws -> ToolResult {
        guard case .array(let items) = value else { throw ToolCallError.invalidArguments("actions must be an array") }
        var planned: [(SessionToolName, JSONValue)] = []
        for (index, item) in items.enumerated() {
            guard var fields = item.objectValue else { throw ToolCallError.invalidArguments("action \(index + 1) must be an object") }
            let name = fields.removeValue(forKey: "tool")?.stringValue ?? ""
            guard let tool = SessionToolName(rawValue: name), SessionTools.batchable.contains(tool) else {
                throw ToolCallError.invalidArguments("action \(index + 1): tool must be one of \(SessionTools.batchable.map(\.rawValue).joined(separator: ", "))")
            }
            let arguments = JSONValue.object(fields.filter { $0.value != .null })
            do {
                let checked = try SessionTools.definition(for: tool).validate(arguments)
                if tool == .click { _ = try Self.checkClickTarget(checked) }
            } catch let error as ToolCallError {
                guard case .invalidArguments(let message) = error else { throw error }
                throw ToolCallError.invalidArguments("action \(index + 1) (\(name)): \(message)")
            }
            planned.append((tool, arguments))
        }
        var results: [JSONValue] = []
        for (index, (tool, arguments)) in planned.enumerated() {
            let result = await call(tool.rawValue, arguments: arguments)
            var entry: [String: JSONValue] = ["tool": .string(tool.rawValue), "ok": .bool(!result.isError)]
            for key in ["method", "verified", "target", "error", "message"] { if let field = result.content[key] { entry[key] = field } }
            results.append(.object(entry))
            if result.isError || result.content["verified"] == false {
                var content: [String: JSONValue] = [
                    "ok": false, "error": result.content["error"] ?? "not_verified",
                    "message": .string("Action \(index + 1) of \(planned.count) (\(tool.rawValue)) \(result.isError ? "failed" : "did not take effect"): \(result.content["message"]?.stringValue ?? result.content["detail"]?.stringValue ?? "")"),
                    "retry": result.content["retry"] ?? "after_check",
                    "completed": .number(Double(index)), "total": .number(Double(planned.count)), "results": .array(results),
                    "next": .string("Actions before it ran. Take a screenshot, fix action \(index + 1), then send it and the remaining actions."),
                ]
                content["ok"] = false
                return ToolResult(tool: SessionToolName.batch.rawValue, isError: true, content: .object(content))
            }
        }
        return Self.success(.batch, ["completed": .number(Double(planned.count)), "total": .number(Double(planned.count)),
                                     "results": .array(results), "next": "Take a screenshot to confirm the final state."])
    }

    // MARK: - Targets by name

    /// Finds the on-screen element with this title or label (falling back to value) in an
    /// app, preferring pressable elements, and returns its center.
    private func resolve(_ element: String, in bundleID: String) async throws -> Point {
        let list = try await connection.elements(ElementQuery(bundleID: bundleID, interactiveOnly: true, limit: 1000))
            .filter { ($0.frame?.width ?? 0) > 0 && ($0.frame?.height ?? 0) > 0 }
        func normalized(_ text: String?) -> String? { text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let wanted = normalized(element)
        var matches = list.filter { normalized($0.title) == wanted || normalized($0.label) == wanted }
        if matches.isEmpty { matches = list.filter { normalized($0.value) == wanted } }
        let pressable = matches.filter { $0.actions.contains("AXPress") }
        if !pressable.isEmpty { matches = pressable }
        let centers = matches.compactMap { $0.frame?.center }
        var unique: [Point] = []
        for center in centers where !unique.contains(where: { abs($0.x - center.x) < 1 && abs($0.y - center.y) < 1 }) { unique.append(center) }
        guard let first = unique.first else {
            let names = list.compactMap(\.name).filter { $0.lowercased().contains(wanted ?? "") || (wanted ?? "").contains($0.lowercased()) }
            let hint = names.isEmpty ? "Call list_elements to see the names." : "Similar: " + names.prefix(8).map { "\"\($0)\"" }.joined(separator: ", ")
            throw HelperFailure(.notFound, "no on-screen element named \"\(element)\" in \(bundleID). \(hint)")
        }
        guard unique.count == 1 else {
            throw HelperFailure(.unsupported, "\(unique.count) elements are named \"\(element)\", at \(unique.prefix(4).map(\.description).joined(separator: ", ")). Click by x and y instead.")
        }
        return first
    }

    private func act(_ tool: SessionToolName, _ action: InputAction) async throws -> ToolResult {
        let report = try await connection.perform(action)
        var content: [String: JSONValue] = [
            "method": .string(report.method.rawValue),
            "verified": report.landed.map(JSONValue.bool) ?? .null,
            "detail": .string(report.detail),
        ]
        if let target = report.target { content["target"] = .string(Self.line(target)) }
        if let app = report.app { content["app"] = .string(app) }
        if let error = report.axError, error != 0 { content["ax_error"] = .number(Double(error)) }
        switch report.landed {
        case true?: break
        case false?:
            content["next"] = "The action did not take effect. Do not assume success: observe again and choose another approach."
        case nil:
            if let error = report.axError, error != 0 {
                content["next"] = .string("Accessibility returned error \(error), but the action may still have happened. Take a screenshot before repeating it.")
            } else {
                content["next"] = "Take a screenshot to confirm the effect."
            }
        }
        return Self.success(tool, content)
    }

    // MARK: - Formatting

    /// One compact line per element: role, name, value, center and actions.
    static func line(_ element: ElementInfo) -> String {
        func short(_ text: String) -> String {
            let flat = text.replacingOccurrences(of: "\n", with: "\\n")
            return flat.count > 80 ? String(flat.prefix(79)) + "…" : flat
        }
        var parts = [element.role]
        if let name = element.name { parts.append("\"\(short(name))\"") }
        if let value = element.value, !value.isEmpty, value != element.name { parts.append("value=\"\(short(value))\"") }
        if let frame = element.frame {
            parts.append("at (\(Int(frame.center.x.rounded())), \(Int(frame.center.y.rounded())))")
        }
        if !element.actions.isEmpty { parts.append("actions: " + element.actions.map(short).joined(separator: ",")) }
        if let app = element.app { parts.append("[\(app)]") }
        return parts.joined(separator: " ")
    }

    // MARK: - Results

    static func success(_ tool: SessionToolName, _ fields: [String: JSONValue]) -> ToolResult {
        var content = fields
        content["ok"] = true
        return ToolResult(tool: tool.rawValue, isError: false, content: .object(content))
    }

    /// Maps any error to a stable code, a retry rule and the next step for the model.
    static func failure(_ tool: String, _ error: Error, readOnly: Bool) -> ToolResult {
        let (code, message) = classify(error)
        let retry: String
        let next: String
        switch code {
        case "invalid_arguments":
            retry = "no"; next = "Fix the arguments and call again; do not repeat the same call."
        case "not_found":
            retry = "after_check"; next = "Take a new screenshot or call list_elements, then try again with a current target."
        case "unsupported":
            retry = "no"; next = "This target cannot do that. Choose another element or another method."
        case "interrupted", "timed_out":
            retry = readOnly ? "safe" : "after_check"
            next = readOnly ? "Safe to call again." : "The action may have happened. Take a screenshot before deciding to repeat it."
        case "permission_denied", "setup_error", "helper_unavailable":
            retry = "no"; next = "Stop and tell the person: \(message)"
        default:
            retry = "after_check"; next = "Take a screenshot to check the state, then try a different approach."
        }
        return ToolResult(tool: tool, isError: true, content: [
            "ok": false, "error": .string(code), "message": .string(message), "retry": .string(retry), "next": .string(next),
        ])
    }

    private static func classify(_ error: Error) -> (code: String, message: String) {
        if let error = error as? ToolCallError {
            switch error {
            case .unknownTool(let message), .invalidArguments(let message): return ("invalid_arguments", message)
            }
        }
        if let error = error as? HelperFailure { return classify(BridgeError.helperFailure(error)) }
        guard let error = error as? BridgeError else { return ("internal_error", String(describing: error)) }
        switch error {
        case .helperFailure(let failure):
            switch failure.code {
            case .permissionDenied: return ("permission_denied", failure.message)
            case .notFound: return ("not_found", failure.message)
            case .unsupported: return ("unsupported", failure.message)
            case .badRequest: return ("invalid_arguments", failure.message)
            case .unauthorized: return ("setup_error", error.userMessage)
            case .handshakeRequired, .internalError: return ("internal_error", failure.message)
            }
        case .interrupted: return ("interrupted", error.userMessage)
        case .timedOut: return ("timed_out", error.userMessage)
        case .unauthorized, .versionMismatch, .invalidConfiguration: return ("setup_error", error.userMessage)
        case .retriesExhausted(_, let last):
            let inner = classify(last)
            return inner.code == "setup_error" ? inner : ("helper_unavailable", error.userMessage)
        case .helperUnavailable, .handshakeFailed, .connectionLost, .closed: return ("helper_unavailable", error.userMessage)
        }
    }
}
