import Foundation

/// The tools an agent can call to work inside the agent session.
public enum SessionToolName: String, Sendable, CaseIterable, Codable {
    case sessionStatus = "session_status"
    case screenshot
    case openApp = "open_app"
    case listElements = "list_elements"
    case inspectPoint = "inspect_point"
    case click
    case typeText = "type_text"
    case setText = "set_text"
    case pressKey = "press_key"
    case scrollTo = "scroll_to"
}

/// The single source of truth for the agent-facing tool layer: definitions, the operating
/// guide, and the generated reference in Docs/AgentTools.md.
public enum SessionTools {
    public static let catalog: [ToolDefinition] = SessionToolName.allCases.map { definition(for: $0) }

    public static func definition(for name: SessionToolName) -> ToolDefinition { makeDefinition(name) }

    /// Declarations ready to send to a model (`name`, `description`, `input_schema`).
    public static var declarations: [JSONValue] { catalog.map(\.declaration) }

    // MARK: - Operating guide

    /// How to work with these tools. Intended for the agent's system prompt.
    public static let guide = """
    You operate a separate macOS user session (the "agent session") in the background. The person \
    you work for keeps using their own session at the same time. Nothing you do reaches their screen, \
    cursor or keyboard, and their activity does not affect yours. The agent session is not on screen, \
    so apps there are never "active" in the usual sense; the tools are built for that.

    Coordinates: every x/y is a screen point in the agent session, origin at the top-left of the main \
    display, y growing downward. `screenshot` returns an image where one pixel is one point, so a \
    position read off the image can be used directly.

    Work in a loop: observe, act, check.
    1. Observe with `screenshot` (what is visible) and `list_elements` (exact targets: role, name, \
    center point and supported actions). Prefer element centers from `list_elements` over positions \
    estimated from pixels.
    2. Act with one tool call at a time. Actions run one after another in the agent session.
    3. Check every action's `verified` field. `true` means Accessibility read the result back; \
    `false` means it did not take effect; `null` means it cannot be read back, so take a screenshot \
    before relying on it.

    What works, and how:
    - Clicking uses Accessibility only: buttons, links, menu items, sidebar rows and other controls \
    that support AXPress are pressed; text fields are focused. Right click opens an element's context \
    menu. Double click works only on elements that advertise AXOpen. There is no mouse-event \
    fallback, because apps in a background session ignore synthetic mouse events.
    - Text: click a text field to focus it, then `type_text`. To replace a field's whole content \
    exactly, use `set_text`, which is verified. Apps may autocorrect typed text; `set_text` avoids that.
    - Keys and shortcuts: `press_key` (cmd+l, cmd+a, return, tab, escape, arrows, pageup, pagedown). \
    Keys go to the focused element, or to the frontmost app when nothing reports focus, so app \
    shortcuts work.
    - Scrolling: `scroll_to` sets a scroll area's position from 0 (top) to 1 (bottom) and is \
    verified. For page-sized steps use `press_key` pageup/pagedown on a focused document.
    - Apps: `open_app` launches or brings forward an app by bundle id.

    Not available: drag and drop, hover, mouse-wheel scrolling, selecting text by double click, and \
    anything outside the agent session.

    When a tool fails, read `error` and `next`:
    - `invalid_arguments`: fix the arguments. Do not repeat the same call.
    - `not_found`: the target is gone or the coordinates are stale. Observe again.
    - `unsupported`: this target cannot do that. Choose another element or another method (for \
    example the keyboard instead of a click).
    - `interrupted` or `timed_out` on an action: it may or may not have happened. Take a screenshot \
    before deciding to repeat it. Never repeat an action blindly.
    - `permission_denied`, `helper_unavailable`, `setup_error`: stop and report the message to the \
    person; they must fix the setup.
    """

    // MARK: - Definitions

    private static let pointX = ToolParameter("x", .number, "Horizontal position in screen points from the left edge.", minimum: 0)
    private static let pointY = ToolParameter("y", .number, "Vertical position in screen points from the top edge.", minimum: 0)
    private static let staleTarget = "`not_found`: nothing is at that point any more. Take a new screenshot or call list_elements."
    private static let needsAccessibility = "`permission_denied`: Accessibility is not granted to ZoopHelper in the agent session. Stop and tell the person."
    private static let needsPostEvent = "`permission_denied`: Accessibility or \"Send input events\" is not granted to ZoopHelper in the agent session. Stop and tell the person."
    private static let mayHaveRun = "`interrupted` or `timed_out`: the action may have happened. Take a screenshot before repeating it."

    private static func makeDefinition(_ name: SessionToolName) -> ToolDefinition {
        switch name {
        case .sessionStatus:
            return ToolDefinition(
                name: name,
                summary: "Report whether the agent session is reachable and which permissions it has.",
                usage: "Call once before a task, and again after a `helper_unavailable` error. Read-only.",
                parameters: [],
                returns: "`user`, `on_console` (false while it runs in the background), `display` size in points, and `permissions` (screen_recording, accessibility, post_events). Each permission must be true for the tools that need it.",
                failures: ["`helper_unavailable`: the agent user is not logged in or ZoopHelper is not running. Stop and tell the person."],
                isReadOnly: true)
        case .screenshot:
            return ToolDefinition(
                name: name,
                summary: "Capture the agent session's main display.",
                usage: "Use it to see the current state, and after any action whose `verified` is null. One image pixel is one screen point, so positions read from the image can be passed to other tools unchanged. Read-only.",
                parameters: [],
                returns: "A PNG image plus `width` and `height` (pixels) and `points_per_pixel`: 1 normally; any other value means multiply image positions by it to get points.",
                failures: ["`permission_denied`: Screen Recording is not granted to ZoopHelper in the agent session. Stop and tell the person.",
                           "`timed_out`: safe to retry once."],
                isReadOnly: true)
        case .openApp:
            return ToolDefinition(
                name: name,
                summary: "Launch an app in the agent session, or bring it forward if it is already running.",
                usage: "Use the app's bundle identifier (for example com.apple.Safari, com.apple.TextEdit, com.apple.calculator, com.apple.systempreferences). Waits until the app has finished launching. A new app may still need a moment to show its window: take a screenshot before acting on it.",
                parameters: [ToolParameter("bundle_id", .string, "Bundle identifier of the app, such as com.apple.Safari.")],
                returns: "`app` (bundle id), `name` and `pid`.",
                failures: ["`not_found`: no app with that bundle id is installed. Check the identifier.", mayHaveRun],
                isReadOnly: false)
        case .listElements:
            return ToolDefinition(
                name: name,
                summary: "List an app's on-screen controls from its accessibility tree.",
                usage: "The most reliable way to find targets. Each line gives a role, name, center point and supported actions; pass the center to click, set_text or scroll_to. By default only elements that can be acted on are listed; set `all` to include labels and static text (for example to read a result). The list is bounded and may be partial for very large apps. Read-only.",
                parameters: [
                    ToolParameter("bundle_id", .string, "Bundle identifier of a running app."),
                    ToolParameter("all", .boolean, "Include non-interactive elements such as labels and static text.", required: false, defaultValue: false),
                    ToolParameter("limit", .integer, "Maximum number of elements to return.", required: false, minimum: 1, maximum: 1000, defaultValue: 200),
                ],
                returns: "`count` and `elements`: one line per element, `Role \"name\" value=\"…\" at (x, y) actions: …`. Long names and values are shortened. Elements without an on-screen frame are omitted.",
                failures: ["`not_found`: the app is not running. Call open_app first.", needsAccessibility],
                isReadOnly: true)
        case .inspectPoint:
            return ToolDefinition(
                name: name,
                summary: "Show the element at a point and the elements that contain it.",
                usage: "Use it to learn what a click at that point would hit, or to read an element's value. The first line is the innermost element; later lines are its containers up to the window and app. Read-only.",
                parameters: [pointX, pointY],
                returns: "`elements`: one line per element, innermost first, in the same format as list_elements.",
                failures: [staleTarget, needsAccessibility],
                isReadOnly: true)
        case .click:
            return ToolDefinition(
                name: name,
                summary: "Click the element at a point, using Accessibility.",
                usage: "Left click presses buttons, links, menu items, sidebar rows and other controls that support AXPress, and focuses text fields so type_text and press_key go to them. `button: right` opens the element's context menu; it appears after about a second, at the element's caret rather than the point, so wait before the screenshot. Close it with press_key escape. `double: true` works only on elements that advertise AXOpen. The helper checks the element at the point and up to five containers for a matching action.",
                parameters: [
                    pointX, pointY,
                    ToolParameter("button", .string, "Mouse button.", required: false, allowed: ["left", "right"], defaultValue: "left"),
                    ToolParameter("double", .boolean, "Double click (left button only).", required: false, defaultValue: false),
                ],
                returns: "`method` (axPress, axFocus, axShowMenu or axOpen), the `target` element, `verified` (true when a focus was confirmed, otherwise null) and `next`.",
                failures: ["`unsupported`: nothing there accepts this click; the message lists what was found. Pick another element from list_elements, or reach the control with the keyboard (press_key).",
                           staleTarget, needsAccessibility, mayHaveRun],
                isReadOnly: false)
        case .typeText:
            return ToolDefinition(
                name: name,
                summary: "Type text as keystrokes into the focused element.",
                usage: "Click a text field first so it has focus. Each character becomes a key press; \\n presses Return and \\t presses Tab, so \"query\\n\" types and submits. Apps can autocorrect or capitalize typed text; to set an exact value use set_text instead.",
                parameters: [ToolParameter("text", .string, "Text to type. Use \\n for Return and \\t for Tab.")],
                returns: "`verified` (true when the field's value changed exactly as expected, otherwise null), the focused `target`, and `detail` with the value before and after.",
                failures: ["`not_found`: no element has keyboard focus. Click a text field first.", needsPostEvent, mayHaveRun],
                isReadOnly: false)
        case .setText:
            return ToolDefinition(
                name: name,
                summary: "Replace a text element's entire value through Accessibility.",
                usage: "Exact and verified, with no autocorrection. Targets the element at (x, y), or the focused element when x and y are omitted. Replaces the whole value; it does not insert at the cursor. Some apps update their display but not their internal state from a direct write; if a form does not react, type_text into it instead.",
                parameters: [
                    ToolParameter("text", .string, "The complete new value."),
                    ToolParameter("x", .number, "Horizontal position of the element, in points. Give x and y together, or neither.", required: false, minimum: 0),
                    ToolParameter("y", .number, "Vertical position of the element, in points. Give x and y together, or neither.", required: false, minimum: 0),
                ],
                returns: "`verified` (true when the value read back matches exactly) and the `target`.",
                failures: ["`unsupported`: the element's value is not writable. Click it and use type_text.",
                           "`not_found`: nothing at that point, or no focused element.", needsAccessibility, mayHaveRun],
                isReadOnly: false)
        case .pressKey:
            return ToolDefinition(
                name: name,
                summary: "Press a key or keyboard shortcut in the focused app.",
                usage: "Write keys as modifiers plus one key joined by +: cmd+l, cmd+shift+t, return, tab, escape, space, delete, up, down, left, right, home, end, pageup, pagedown, f1–f12, or a letter, digit or symbol. Modifiers: cmd, shift, opt (alt), ctrl, fn. The key goes to the focused element, or to the frontmost app when nothing reports focus, so app shortcuts such as cmd+l (address bar) or cmd+n work.",
                parameters: [ToolParameter("keys", .string, "Key combination such as cmd+l or return.")],
                returns: "The `target` that received the keys and `verified: null`. Take a screenshot (or inspect the focused element) to confirm the effect.",
                failures: ["`invalid_arguments` or `unsupported`: the key name is not recognised. Use a name from the list.",
                           "`not_found`: no app is frontmost in the agent session. Call open_app first.", needsPostEvent, mayHaveRun],
                isReadOnly: false)
        case .scrollTo:
            return ToolDefinition(
                name: name,
                summary: "Scroll the scroll area under a point to an absolute position.",
                usage: "`position` 0 is the top (or left edge) and 1 is the bottom (or right edge); 0.5 is the middle. Point at the content to scroll, such as a document, web page or sidebar. Verified by reading the scroll bar back. To move one page at a time, use press_key pagedown/pageup instead.",
                parameters: [
                    pointX, pointY,
                    ToolParameter("position", .number, "Target position from 0 (start) to 1 (end).", minimum: 0, maximum: 1),
                    ToolParameter("horizontal", .boolean, "Scroll horizontally instead of vertically.", required: false, defaultValue: false),
                ],
                returns: "`verified` (true when the scroll bar reads back the requested position), the scroll bar `target`, and `detail` with the positions before and after.",
                failures: ["`unsupported`: nothing under the point has a scroll bar on that axis, or it cannot be set. Point at the scrolling content itself, or use press_key pagedown.",
                           staleTarget, needsAccessibility, mayHaveRun],
                isReadOnly: false)
        }
    }

    // MARK: - Reference document

    /// Markdown reference for Docs/AgentTools.md. A test keeps the file identical to this.
    public static func referenceMarkdown() -> String {
        var lines: [String] = [
            "# Agent tools",
            "",
            "<!-- Generated by `zoop-bridge tools --markdown` from Sources/ZoopShared/Tools/SessionTools.swift. Do not edit by hand. -->",
            "",
            "The agent layer controls the agent session through these tools. `SessionToolbox.call(_:arguments:)` executes them over the session bridge; `SessionTools.declarations` gives the model-facing schemas, and `SessionTools.guide` is the operating guide for the system prompt.",
            "",
            "## Operating guide",
            "",
            guide,
            "",
            "## Results",
            "",
            "Every call returns one JSON object. Successful calls have `\"ok\": true`, the tool's fields, and `next` when a follow-up is recommended. Actions also include `method`, `target`, `verified` (true, false or null) and `detail`. Failed calls have `\"ok\": false`, `error` (a code from the guide above), `message`, `retry` (`safe`, `after_check` or `no`) and `next`. `screenshot` also returns the PNG image.",
            "",
            "## Tools",
            "",
            "| Tool | Read-only | Summary |",
            "|---|---|---|",
        ]
        lines += catalog.map { "| `\($0.name.rawValue)` | \($0.isReadOnly ? "yes" : "no") | \($0.summary) |" }
        for tool in catalog {
            lines += ["", "### `\(tool.name.rawValue)`", "", tool.summary + " " + tool.usage, ""]
            if tool.parameters.isEmpty {
                lines.append("Arguments: none.")
            } else {
                lines += ["| Argument | Type | Required | Description |", "|---|---|---|---|"]
                for parameter in tool.parameters {
                    var notes: [String] = []
                    if let allowed = parameter.allowed { notes.append("One of " + allowed.map { "`\($0)`" }.joined(separator: ", ") + ".") }
                    if let minimum = parameter.minimum, let maximum = parameter.maximum {
                        notes.append("\(JSONValue.number(minimum).jsonText)–\(JSONValue.number(maximum).jsonText).")
                    }
                    if let value = parameter.defaultValue { notes.append("Default `\(value.jsonText)`.") }
                    let description = ([parameter.description] + notes).joined(separator: " ").replacingOccurrences(of: "|", with: "\\|")
                    lines.append("| `\(parameter.name)` | \(parameter.kind.rawValue) | \(parameter.required ? "yes" : "no") | \(description) |")
                }
            }
            lines += ["", "Returns: " + tool.returns, "", "Failures:", ""]
            lines += tool.failures.map { "- " + $0 }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
