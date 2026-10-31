import Foundation

/// The tools an agent can call to work inside the agent session.
public enum SessionToolName: String, Sendable, CaseIterable, Codable {
    case sessionStatus = "session_status"
    case screenshot
    case openApp = "open_app"
    case listElements = "list_elements"
    case inspectPoint = "inspect_point"
    case readPage = "read_page"
    case click
    case typeText = "type_text"
    case setText = "set_text"
    case pressKey = "press_key"
    case scrollTo = "scroll_to"
    case saveDocument = "save_document"
    case sendEmail = "send_email"
    case wait
    case batch
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
    center point and supported actions). To click a named element, pass its app and name \
    (`bundle_id` and `element`) instead of copying coordinates.
    2. Act. When several actions do not need a look at the screen in between (pressing a known \
    sequence of buttons, filling a form), send them in one `batch` call: it runs them in order and \
    stops at the first failure. That saves a model round trip per action.
    3. Check every action's `verified` field. `true` means Accessibility read the result back; \
    `false` means it did not take effect; `null` means it cannot be read back, so take a screenshot \
    before relying on it.

    What works, and how:
    - Clicking defaults to Accessibility: press controls with AXPress, or focus text fields. \
    AX errors can occur after a click took effect. For an unsuccessful or unconfirmed click, inspect \
    a fresh screenshot first. If the intended effect is already visible, continue without retrying. \
    Otherwise call open_app to focus/raise the target app inside the agent session, screenshot again \
    (focus can change what is visible), locate the control visually, and use click with strategy \
    mouse plus x, y and bundle_id. This sends down/up events only to that app's visible window, \
    bypassing AXPress. Background apps may ignore mouse events: check the next screenshot; never \
    assume success or repeat blindly. Use keyboard navigation if this approach also fails. \
    An unconfirmed click ends the current batch; completed includes that sent click. Check it, then \
    execute only the remaining actions. Never replay the whole batch.
    - Text: click a text field to focus it, then `type_text`. To replace a field's whole content \
    exactly, use `set_text`, which is verified. Apps may autocorrect typed text; `set_text` avoids that.
    - Keys and shortcuts: `press_key` (cmd+l, cmd+a, return, tab, escape, arrows, pageup, pagedown). \
    Keys go to the focused element, or to the frontmost app when nothing reports focus, so app \
    shortcuts work.
    - Scrolling: `scroll_to` sets a scroll area's position from 0 (top) to 1 (bottom) and is \
    verified. For page-sized steps use `press_key` pageup/pagedown on a focused document.
    - Apps: `open_app` launches or brings forward an app by bundle id.
    - New documents: TextEdit (and most document apps) opens a blank "Untitled" document when it \
    starts. After open_app, check its windows with list_elements and write into that document. \
    Press cmd+n only when no document window is open; never create a second document.
    - Calculator: clicking its buttons in the background session is unreliable. Clear it with \
    press_key escape, then type the whole expression in one `type_text`, such as 149900*3=, and \
    read the result with `list_elements` (all true) or a screenshot before using it. Clear again \
    before the next calculation.
    - Saving: `save_document` saves an app's front document to a full path, for example \
    ~/Documents/Quote.rtf. Never use cmd+s or a Save sheet. The person approves each save.
    - Email: `send_email` sends with the Mail app's account (to, subject, body). Never compose \
    email in a web page or in Mail's window. The person approves each send.
    - Dialogs and sheets are answered by the person, not by these tools. Clicks, typing and keys \
    aimed at a dialog are refused.
    - Waiting: `wait` pauses for a few seconds without touching anything, for pages and apps \
    that are still loading. It can go inside a batch, for example press_key cmd+r then wait 5.

    Web pages: the agent session is not on screen, so Safari often skips drawing animated or \
    fading content. A screenshot can show a blank or half-drawn page that has in fact loaded. \
    Do not judge a page by its screenshot. Use `read_page`, which reads the page's text through \
    Accessibility whether or not it was drawn, and click links by name (`bundle_id` + `element`). \
    A page that has not loaded is not a failed action: do not click on it. Instead:
    1. Open the URL and `wait` 10 seconds in the same batch (press_key cmd+l, type_text the URL \
    with \\n, wait 10), then call `read_page`.
    2. No page text yet: reload and wait in one batch (press_key cmd+r, wait 10), then `read_page` \
    again. Repeat up to 3 reloads.
    3. After 3 reloads, or when the site shows an error, blocks you or lacks the information, use \
    another source: a search engine (for example https://duckduckgo.com/?q=… or \
    https://www.google.com/search?q=…), the same site's other pages, or another reputable site. \
    Say in your result which source the information came from.
    Only report the task as blocked after several sources have failed.

    Not available: drag and drop, hover, mouse-wheel scrolling, selecting text by double click, and \
    anything outside the agent session.

    When a tool fails, read `error` and `next`:
    - `invalid_arguments`: fix the arguments. Do not repeat the same call.
    - `not_found`: the target is gone or the coordinates are stale. Observe again.
    - `unsupported`: this target cannot do that. Choose another element or another method (for \
    example the keyboard instead of a click).
    - `interrupted` or `timed_out` on an action: it may or may not have happened. Take a screenshot \
    before deciding to repeat it. Never repeat an action blindly.
    - `consent_pending`: macOS is asking the person for permission; nothing ran yet. Zoop shows \
    them the request. Call the tool again once.
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
        case .readPage:
            return ToolDefinition(
                name: name,
                summary: "Read the text and links of the page or window an app is showing, through Accessibility.",
                usage: "Use it to read web pages and documents, and to check whether a page has loaded: it works even when the screenshot is blank because the background session did not draw the page. Lines come in reading order (top to bottom); links are marked. Pass `find` to keep only lines containing any of its words, for example \"₹ price From\". Click a link it lists with click bundle_id + element. Read-only.",
                parameters: [
                    ToolParameter("bundle_id", .string, "App to read.", required: false, defaultValue: "com.apple.Safari"),
                    ToolParameter("find", .string, "Optional words separated by spaces; only lines containing at least one of them are returned (case-insensitive).", required: false),
                    ToolParameter("max_chars", .integer, "Maximum characters of text to return.", required: false, minimum: 500, maximum: 20000, defaultValue: 6000),
                ],
                returns: "`lines` (count), `text` (one line per text element; links as `[link] name`), `truncated`, and `next`. No text means the page has not loaded yet (or the app shows no text).",
                failures: ["`not_found`: the app is not running. Call open_app first.", needsAccessibility],
                isReadOnly: true)
        case .click:
            return ToolDefinition(
                name: name,
                summary: "Click through Accessibility, or explicitly try a PID-targeted mouse click at a screenshot position.",
                usage: "Target it either by point (`x`, `y`) or by name (`bundle_id` plus `element`, the name list_elements shows, such as \"7\" or \"Equals\"); naming avoids coordinate mistakes. Left click presses buttons, links, menu items, sidebar rows and other controls that support AXPress, and focuses text fields so type_text and press_key go to them. `button: right` opens the element's context menu; it appears after about a second, at the element's caret rather than the point, so wait before the screenshot. Close it with press_key escape. `double: true` works only on elements that advertise AXOpen. The helper checks the element at the point and up to five containers for a matching action. Named clicks bring the app forward first. For visual recovery use strategy mouse with x, y and bundle_id after open_app and a fresh screenshot. Mouse clicks bypass AXPress and remain unconfirmed until inspected; never fall back blindly after an AX error.",
                parameters: [
                    ToolParameter("x", .number, "Horizontal position in screen points. Give x and y, or bundle_id and element.", required: false, minimum: 0),
                    ToolParameter("y", .number, "Vertical position in screen points.", required: false, minimum: 0),
                    ToolParameter("bundle_id", .string, "App that owns the element; required for named targets and strategy mouse.", required: false),
                    ToolParameter("element", .string, "Element name exactly as list_elements shows it (title or label), when clicking by name.", required: false),
                    ToolParameter("strategy", .string, "Use accessibility first; mouse is an explicit visual retry with x, y and bundle_id (no element), after open_app and a fresh screenshot.", required: false, allowed: ["accessibility", "mouse"], defaultValue: "accessibility"),
                    ToolParameter("button", .string, "Mouse button.", required: false, allowed: ["left", "right"], defaultValue: "left"),
                    ToolParameter("double", .boolean, "Double click (left button only).", required: false, defaultValue: false),
                ],
                returns: "`method` (axPress, axFocus, axShowMenu, axOpen or pidMouse), the `target` when available, `verified` (true when focus was confirmed, otherwise null), `requires_observation` for unconfirmed clicks, and `next`.",
                failures: ["`unsupported`: nothing there accepts this click, or several elements share that name; the message says which. Pick another element from list_elements, click by point, or reach the control with the keyboard (press_key).",
                           "`not_found`: nothing at that point, or no on-screen element with that name (the message lists similar names).",
                           needsPostEvent, mayHaveRun],
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
                usage: "Exact and verified, with no autocorrection. Targets the element at (x, y), or the focused element when x and y are omitted. Replaces the whole value; it does not insert at the cursor. Some apps update their display but not their internal state from a direct write; if a form does not react, type_text into it instead. Not available in dialogs or sheets.",
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
        case .saveDocument:
            return ToolDefinition(
                name: name,
                summary: "Save an app's front document to a file through the app's scripting interface.",
                usage: "The only way to save a file: never use cmd+s or a Save sheet. Zoop first asks the person to approve the save with a card in their session; the first time, macOS also asks them to allow ZoopHelper to control the app. Works with scriptable document apps such as TextEdit, Pages and Preview. The path must be inside the agent user's home folder; its extension should match the document (.rtf for TextEdit rich text, .txt for plain text). An existing file is refused unless `overwrite` is true, which the approval card states. If a sheet is open in the app, call request_dialog_help first.",
                parameters: [
                    ToolParameter("bundle_id", .string, "Bundle identifier of the app that has the document open."),
                    ToolParameter("path", .string, "Full file path, absolute or starting with ~/, for example ~/Documents/Quote.rtf."),
                    ToolParameter("overwrite", .boolean, "Replace an existing file. Only after the person agreed.", required: false, defaultValue: false),
                ],
                returns: "`verified` (true when the file was written on disk) and `detail` with the saved path.",
                failures: ["`declined`: the person did not approve this save. Do not save another way.",
                           "`unsupported`: a dialog is still open in the app, the file exists, or the app refused the save. Read the message.",
                           "`not_found`: the app is not running or the folder does not exist.",
                           "`consent_pending`: macOS is asking the person for Automation permission. Call again once after they answer.",
                           "`permission_denied`: Automation permission was denied. Stop and tell the person.", mayHaveRun],
                isReadOnly: false)
        case .sendEmail:
            return ToolDefinition(
                name: name,
                summary: "Send an email with the Mail app's configured account.",
                usage: "The only way to send email: never type into a web mail page or Mail's compose window. Zoop shows the person the recipients, subject and full text and sends only after they approve; the first time, macOS also asks them to let ZoopHelper control Mail. Write the complete message in `body` as plain text.",
                parameters: [
                    ToolParameter("to", .string, "Recipient email addresses, separated by commas."),
                    ToolParameter("subject", .string, "Subject line."),
                    ToolParameter("body", .string, "The complete message as plain text."),
                ],
                returns: "`verified` (true when Mail reported the message sent) and `detail`.",
                failures: ["`declined`: the person did not approve this email. Do not send it another way.",
                           "`invalid_arguments`: an address is not a plain email address.",
                           "`unsupported`: Mail could not send, for example because no account is set up.",
                           "`consent_pending`: macOS is asking the person for Automation permission. Call again once after they answer.",
                           "`permission_denied`: Automation permission was denied. Stop and tell the person.", mayHaveRun],
                isReadOnly: false)
        case .wait:
            return ToolDefinition(
                name: name,
                summary: "Pause for a few seconds without doing anything in the agent session.",
                usage: "Use it while a web page or app is still loading, then take a screenshot to check. Typical wait: 10 seconds after opening a URL or reloading, then read_page. Allowed inside batch (for example press_key cmd+r, then wait). Changes nothing.",
                parameters: [ToolParameter("seconds", .number, "How long to wait, from 0.5 to 15 seconds.", required: false, minimum: 0.5, maximum: 15, defaultValue: 3)],
                returns: "`waited`: the seconds waited, and `next`.",
                failures: ["`interrupted`: the task was stopped while waiting."],
                isReadOnly: true)
        case .batch:
            return ToolDefinition(
                name: name,
                summary: "Run several actions in order with one call.",
                usage: "Use it for steps that do not need a look at the screen in between, such as pressing a known sequence of buttons or filling several fields. Each action names its `tool` (click, type_text, set_text, press_key, scroll_to, open_app or wait) and that tool's arguments as sibling fields, for example {\"tool\": \"click\", \"bundle_id\": \"com.apple.calculator\", \"element\": \"7\"}. All actions are checked before any runs. They run in order and stop at the first failure, `verified: false`, or unconfirmed click (`requires_observation`). After an unconfirmed click, `completed` includes that sent click; inspect it before continuing only the remaining actions. Mouse recovery must be a separate call, never a batch item. Take a screenshot afterwards to confirm the final state.",
                parameters: [ToolParameter("actions", .array, "The actions, in order.", minimum: 1, maximum: Double(batchLimit), items: batchItemSchema)],
                returns: "`completed` and `total` counts and `results`: one compact entry per action that ran (tool, ok, method, verified, target or error); `requires_observation` when paused at an unconfirmed click.",
                failures: ["`invalid_arguments`: an action is malformed; nothing ran. The message names the action.",
                           "Any other error: the batch stopped at that action. `completed` says how many ran before it; fix that action and send the rest.",
                           mayHaveRun],
                isReadOnly: false)
        }
    }

    /// Tools allowed inside `batch`: actions, plus `wait`. Observation tools would lose their output.
    static let batchable: [SessionToolName] = [.click, .typeText, .setText, .pressKey, .scrollTo, .openApp, .wait]
    static let batchLimit = 25

    /// One batch action: `tool` plus the union of the batchable tools' arguments, flattened so
    /// every provider's schema subset accepts it.
    private static var batchItemSchema: JSONValue {
        var properties: [String: JSONValue] = ["tool": ["type": "string", "enum": .array(batchable.map { .string($0.rawValue) }),
                                                        "description": "The tool to run."]]
        for tool in batchable {
            for parameter in makeDefinition(tool).parameters where properties[parameter.name] == nil {
                var schema = parameter.schema
                if case .object(var object) = schema { object["description"] = .string("Argument for the tools that take it: \(parameter.description)"); schema = .object(object) }
                properties[parameter.name] = schema
            }
        }
        return ["type": "object", "required": ["tool"], "additionalProperties": false, "properties": .object(properties)]
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
