import Foundation
import ZoopShared

/// Web browsing through Microsoft's Playwright MCP server (`@playwright/mcp`), driving the
/// installed Google Chrome headlessly in the person's own macOS session with Zoop's own profile.
/// Playwright works inside the page (DOM, roles, real load waits), which fixes what Accessibility
/// and posted keystrokes could not: web forms such as Gmail compose, blank background renders,
/// and guessing whether a page has loaded. Native apps stay on the session helper.
public actor BrowserSession {
    /// The server version is pinned so a new release cannot silently change the tools.
    public static let package = "@playwright/mcp@0.0.84"
    /// Tools offered to the model. Code evaluation, file uploads, network inspection and closing
    /// the browser are left out on purpose.
    static let allowed: [String] = ["browser_navigate", "browser_navigate_back", "browser_find", "browser_snapshot",
        "browser_click", "browser_type", "browser_fill_form", "browser_press_key", "browser_select_option",
        "browser_hover", "browser_wait_for", "browser_take_screenshot", "browser_tabs", "browser_handle_dialog"]
    static let readOnly: Set<String> = ["browser_find", "browser_snapshot", "browser_take_screenshot", "browser_wait_for"]
    /// A full page snapshot can be 40,000+ characters; longer results are cut to this.
    static let maxText = 16_000

    let profile: URL
    let workspace: URL
    private var client: MCPStdioClient?
    private var signInClient: MCPStdioClient?
    private var tools: [ModelTool]?
    private var lastUse: ContinuousClock.Instant?

    public init(support: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Zoop")) {
        profile = support.appendingPathComponent("Browser Profile")
        workspace = support.appendingPathComponent("Browser Output")
    }

    /// Node's npx, found outside the app's minimal GUI PATH.
    static func npx() -> URL? {
        ["/opt/homebrew/bin/npx", "/usr/local/bin/npx", "/usr/bin/npx"].map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Whether the browser was used in the last 20 seconds (the preview then shows it).
    public var isActive: Bool { lastUse.map { ContinuousClock.now - $0 < .seconds(20) } ?? false }

    public func modelTools() async -> [ModelTool] {
        if let tools { return tools }
        guard let client = try? await running(),
              let listed = try? await client.request("tools/list", [:], timeout: .seconds(30)),
              case .array(let all)? = listed["tools"] else { return [] }
        let byName = Dictionary(all.compactMap { tool in tool["name"]?.stringValue.map { ($0, tool) } }, uniquingKeysWith: { a, _ in a })
        let result = Self.allowed.compactMap { name -> ModelTool? in
            guard let tool = byName[name] else { return nil }
            return ModelTool(name: name, description: tool["description"]?.stringValue ?? name,
                             inputSchema: Self.cleanSchema(tool["inputSchema"] ?? ["type": "object"]))
        }
        tools = result
        return result
    }

    public func call(_ name: String, argumentsJSON: String) async -> ToolResult {
        guard Self.allowed.contains(name) else {
            return ToolResult(tool: name, isError: true, content: ["ok": false, "error": "invalid_arguments", "message": "Unknown browser tool."])
        }
        let arguments = (try? JSONValue.parse(argumentsJSON.isEmpty ? "{}" : argumentsJSON)) ?? [:]
        do {
            let client = try await running()
            lastUse = .now
            let result = try await client.request("tools/call", ["name": .string(name), "arguments": arguments],
                                                  timeout: name == "browser_navigate" ? .seconds(75) : .seconds(40))
            lastUse = .now
            return Self.toolResult(name, result)
        } catch {
            // A crashed or closed server is restarted on the next call.
            if let client, await !client.isRunning { self.client = nil }
            return ToolResult(tool: name, isError: true, content: ["ok": false, "error": "browser_error",
                "message": .string(String(describing: error)), "next": "Try again once; if it fails again, report it."])
        }
    }

    /// One JPEG of the current page for the live preview, or nil.
    public func previewFrame() async -> Data? {
        guard let client, await client.isRunning,
              let result = try? await client.request("tools/call", ["name": "browser_take_screenshot", "arguments": ["type": "jpeg"]],
                                                     timeout: .seconds(5)) else { return nil }
        return Self.image(in: result)?.data
    }

    /// Opens a visible Chrome window with Zoop's browser profile so the person can sign in to sites
    /// (Gmail and others). Playwright keeps its own cookie encryption, so sign-in has to happen in a
    /// Playwright-launched window, not in normal Chrome. The task browser is closed meanwhile,
    /// because Chrome allows one process per profile.
    public func openSignInWindow(url: String = "https://accounts.google.com") async throws {
        await client?.stop(); client = nil; tools = nil
        let window = try launch(headless: false)
        try await window.start()
        signInClient = window
        _ = try await window.request("tools/call", ["name": "browser_navigate", "arguments": ["url": .string(url)]], timeout: .seconds(75))
    }

    public func closeSignInWindow() async {
        await signInClient?.stop()
        signInClient = nil
    }

    public var isSigningIn: Bool { signInClient != nil }

    public func shutdown() async {
        await client?.stop(); client = nil
        await signInClient?.stop(); signInClient = nil
    }

    private func running() async throws -> MCPStdioClient {
        if let client, await client.isRunning { return client }
        if signInClient != nil { throw MCPError.launchFailed("the sign-in browser window is open. Close it from Zoop's menu first.") }
        let fresh = try launch(headless: true)
        try await fresh.start()
        client = fresh
        return fresh
    }

    private func launch(headless: Bool) throws -> MCPStdioClient {
        guard let npx = Self.npx() else {
            throw MCPError.launchFailed("Node.js (npx) is not installed. Install it with `brew install node`.")
        }
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = npx.deletingLastPathComponent().path + ":/usr/bin:/bin:" + (environment["PATH"] ?? "")
        var arguments = ["-y", Self.package, "--browser", "chrome", "--user-data-dir", profile.path,
                         "--output-dir", workspace.path, "--snapshot-mode", "none", "--viewport-size", "1280x800"]
        if headless { arguments.append("--headless") }
        return MCPStdioClient(executable: npx, arguments: arguments, workingDirectory: workspace, environment: environment)
    }

    // MARK: - Result conversion

    static func toolResult(_ name: String, _ result: JSONValue) -> ToolResult {
        var texts: [String] = []
        if case .array(let parts)? = result["content"] {
            for part in parts where part["type"]?.stringValue == "text" { if let text = part["text"]?.stringValue { texts.append(text) } }
        }
        var text = texts.joined(separator: "\n")
        var truncated = false
        if text.count > maxText {
            text = String(text.prefix(maxText)); truncated = true
        }
        let image = Self.image(in: result)
        if result["isError"]?.boolValue == true {
            return ToolResult(tool: name, isError: true, content: ["ok": false, "error": "browser_error", "message": .string(text),
                "next": "Read the message. Take browser_snapshot or browser_find for current element refs, then try a different approach."], image: image)
        }
        var content: [String: JSONValue] = ["ok": true, "result": .string(text)]
        if truncated {
            content["next"] = .string("Output was cut at \(maxText) characters. Use browser_find with words from what you need; it returns matching parts of the page with their refs.")
        }
        return ToolResult(tool: name, isError: false, content: .object(content), image: image)
    }

    static func image(in result: JSONValue) -> ToolImage? {
        guard case .array(let parts)? = result["content"],
              let part = parts.first(where: { $0["type"]?.stringValue == "image" }),
              let base64 = part["data"]?.stringValue, let data = Data(base64Encoded: base64) else { return nil }
        // Size is not reported; the viewport is fixed at 1280×800.
        return ToolImage(data: data, mediaType: part["mimeType"]?.stringValue ?? "image/png", width: 1280, height: 800)
    }

    /// Drops JSON Schema keys some model providers reject.
    static func cleanSchema(_ schema: JSONValue) -> JSONValue {
        switch schema {
        case .object(var fields):
            fields.removeValue(forKey: "$schema")
            return .object(fields.mapValues(cleanSchema))
        case .array(let items): return .array(items.map(cleanSchema))
        default: return schema
        }
    }
}

/// Adds the browser tools to another tool runner: `browser_*` calls go to Playwright, everything
/// else (native apps through the session helper) to `tools`.
public struct BrowserToolRunner: ToolRunning {
    let tools: any ToolRunning
    let browser: BrowserSession

    public init(tools: any ToolRunning, browser: BrowserSession) { self.tools = tools; self.browser = browser }

    public func call(_ name: String, argumentsJSON: String) async -> ToolResult {
        name.hasPrefix("browser_") ? await browser.call(name, argumentsJSON: argumentsJSON) : await tools.call(name, argumentsJSON: argumentsJSON)
    }

    public func extraModelTools() async -> [ModelTool] {
        await tools.extraModelTools() + browser.modelTools()
    }

    /// Browser tools that change the page (count as actions for failure tracking).
    public static func isAction(_ name: String) -> Bool {
        BrowserSession.allowed.contains(name) && !BrowserSession.readOnly.contains(name)
    }

    /// Operating guide appended to the executor and planner prompts when the browser is available.
    public static let guide = """
    Websites: use the browser_* tools. They control a Chrome browser directly through the page \
    (not Safari, and not the agent session's screen), so they work on forms that ignore other \
    input and they wait for pages to load. Never use Safari, read_page, screenshot or click for \
    web pages.
    - browser_navigate opens a URL. Then browser_find with a few words (for example "₹ From") \
    returns the matching parts of the page with element refs; browser_snapshot returns the whole \
    page structure (long, cut at 16,000 characters).
    - browser_click, browser_type, browser_select_option and browser_fill_form take the element \
    description and its ref from the latest find or snapshot. Refs change after the page changes.
    - browser_wait_for waits for text to appear or disappear; browser_take_screenshot shows the page.
    - Sign-in: the browser keeps the person's sign-ins from Zoop's sign-in window. If a site asks \
    you to sign in, do not type credentials: ask_user to sign in with Zoop's "Sign in to websites" menu.
    """
}
