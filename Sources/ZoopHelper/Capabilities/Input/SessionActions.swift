import AppKit
import ApplicationServices
import CoreGraphics
import ZoopShared

/// One shared instance per backend, across all connections. The gate remains held across
/// suspension (launching an app); actor isolation alone would permit reentrant input.
actor SessionActions {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    func openApp(_ bundleID: String) async throws -> AppInfo {
        await acquire()
        defer { release() }
        return try await Apps.open(bundleID)
    }
    func inspect(_ point: Point) throws -> [ElementInfo] {
        try AXElement.requirePermission()
        return try AXElement.at(point).ancestors.map(\.info)
    }
    func elements(_ query: ElementQuery) throws -> [ElementInfo] {
        try AXElement.requirePermission()
        return try AXElement.elements(query)
    }

    func perform(_ action: InputAction) async throws -> ActionReport {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        switch action {
        case .click(let click): return try clickAt(click)
        case .setText(let action): return try setText(action)
        case .type(let text): return try type(text)
        case .key(let combo): return try key(combo)
        case .scrollTo(let scroll): return try scrollTo(scroll)
        }
    }

    private func requirePostEvent() throws {
        guard CGPreflightPostEventAccess() else {
            throw HelperFailure(.permissionDenied, "Send input events (PostEvent) is not allowed for ZoopHelper in \(NSUserName())'s session. Enable it in System Settings > Privacy & Security.")
        }
    }

    private func report(_ name: String, _ method: ActionMethod, _ element: AXElement,
                        error: AXError? = nil, landed: Bool? = nil, detail: String) -> ActionReport {
        let info = element.info
        return ActionReport(action: name, method: method, target: info, pid: info.pid, app: info.app,
                            axError: error.map { Int($0.rawValue) }, landed: landed, detail: detail)
    }

    private func focus(_ element: AXElement) -> AXError {
        let app = AXElement(AXUIElementCreateApplication(element.pid))
        _ = app.set(kAXFrontmostAttribute, kCFBooleanTrue)
        if let window = element.element(kAXWindowAttribute) { _ = window.set(kAXMainAttribute, kCFBooleanTrue) }
        return element.set(kAXFocusedAttribute, kCFBooleanTrue)
    }

    /// Accessibility-only. In a background session apps ignore PID-targeted mouse events
    /// (tested in AppKit, WebKit and SwiftUI), so there is deliberately no event fallback:
    /// an `unsupported` failure tells the agent to choose another approach.
    private func clickAt(_ click: ClickAction) throws -> ActionReport {
        guard (1...2).contains(click.count) else { throw HelperFailure(.badRequest, "click count must be 1 or 2") }
        guard click.point.x.isFinite, click.point.y.isFinite else { throw HelperFailure(.badRequest, "coordinates must be finite") }
        try AXElement.requirePermission()
        let hit = try AXElement.at(click.point)
        let (action, method): (String, ActionMethod) =
            click.button == .right ? (kAXShowMenuAction, .axShowMenu)
            : click.count == 2 ? ("AXOpen", .axOpen)
            : (kAXPressAction, .axPress)
        let chain = hit.ancestors
        for element in chain {
            if element.actions.contains(action) {
                // Capture the target first: pressing may close a menu or destroy the element.
                let info = element.info
                let error = element.perform(action)
                return ActionReport(action: InputAction.click(click).name, method: method, target: info,
                                    pid: info.pid, app: info.app, axError: Int(error.rawValue),
                                    detail: "\(action) performed. AX success means the app accepted the request; confirm the effect in the next screenshot.")
            }
            if click.button == .left, click.count == 1,
               [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(element.string(kAXRoleAttribute) ?? ""),
               element.isSettable(kAXFocusedAttribute) {
                let error = focus(element)
                let focused = element.attribute(kAXFocusedAttribute) as? Bool
                return report("click", .axFocus, element, error: error, landed: focused == true ? true : nil,
                              detail: "Text element focused through Accessibility; type_text and press_key now go to it.")
            }
        }
        let found = chain.map { "\($0.string(kAXRoleAttribute) ?? "AXUnknown")[\($0.actions.joined(separator: ","))]" }.joined(separator: " < ")
        throw HelperFailure(.unsupported, "nothing at \(click.point) or its ancestors supports \(action). Found: \(found)")
    }

    private func setText(_ action: SetTextAction) throws -> ActionReport {
        try AXElement.requirePermission()
        let element = try action.point.map { try AXElement.at($0) } ?? AXElement.focused()
        guard element.isSettable(kAXValueAttribute) else { throw HelperFailure(.unsupported, "target's AXValue is not writable") }
        let error = element.set(kAXValueAttribute, action.text as CFString)
        let value = element.string(kAXValueAttribute)
        return report("setText", .axSetValue, element, error: error,
                      landed: value.map { $0 == action.text }, detail: "AXValue written and read back; no keystrokes were sent.")
    }

    private func sendKey(_ code: CGKeyCode, pid: pid_t, flags: CGEventFlags = [], unicode: [UniChar]? = nil) throws {
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw HelperFailure(.internalError, "could not create key events")
        }
        for event in [down, up] {
            event.flags = flags
            if let unicode {
                unicode.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
            }
            event.postToPid(pid)
        }
    }

    private func type(_ text: String) throws -> ActionReport {
        try AXElement.requirePermission()
        try requirePostEvent()
        let element = try AXElement.focused()
        let pid = element.pid
        guard pid > 0 else { throw HelperFailure(.notFound, "focused element has no app pid") }
        let before = element.string(kAXValueAttribute)
        // Capture a selection when available so replacement can be checked exactly.
        var selection: CFRange?
        if let value = element.attribute(kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(value as! AXValue, .cfRange, &range) { selection = range }
        }
        for character in text {
            if character == "\n" || character == "\r\n" || character == "\r" { try sendKey(36, pid: pid) }
            else if character == "\t" { try sendKey(48, pid: pid) }
            else { try sendKey(0, pid: pid, unicode: Array(String(character).utf16)) }
            usleep(5_000)
        }
        // Apps consume posted events asynchronously. This pause stays inside the action gate.
        usleep(100_000)
        let after = element.string(kAXValueAttribute)
        var landed: Bool?
        if let before, let after, let selection,
           selection.location >= 0, selection.length >= 0,
           selection.location <= (before as NSString).length,
           selection.length <= (before as NSString).length - selection.location,
           !text.contains("\t") {
            let expected = (before as NSString).replacingCharacters(in: NSRange(location: selection.location, length: selection.length), with: text)
            if after == expected { landed = true }
            // An unchanged value after posting can also mean delayed consumption; unknown.
        }
        return report("type", .pidKeys, element, landed: landed,
                      detail: "Posted \(text.count) characters to pid \(pid). AXValue before=\(before.map { String(reflecting: $0) } ?? "unavailable"), after=\(after.map { String(reflecting: $0) } ?? "unavailable").")
    }

    private func key(_ combo: KeyCombo) throws -> ActionReport {
        guard let code = KeyMap.code(for: combo.key) else { throw HelperFailure(.unsupported, "unknown key '\(combo.key)'") }
        try AXElement.requirePermission()
        try requirePostEvent()
        // Shortcuts such as Cmd+L need only the app, not a focused element. When nothing
        // reports focus, target the session's focused/frontmost app itself.
        let focused = try? AXElement.focused()
        guard let element = focused ?? AXElement.focusedApp() else {
            throw HelperFailure(.notFound, "no focused element or frontmost app in the agent session")
        }
        guard element.pid > 0 else { throw HelperFailure(.notFound, "focused element has no app pid") }
        try sendKey(code, pid: element.pid, flags: KeyMap.flags(combo.modifiers))
        let target = focused == nil ? "the frontmost app (no focused element was reported)" : "the focused app"
        return report("key", .pidKeys, element, detail: "Posted \(combo) to \(target); check the next screenshot.")
    }

    private func scrollTo(_ scroll: ScrollToAction) throws -> ActionReport {
        let plan = try AXScrollBarPosition(scroll)
        try AXElement.requirePermission()
        let hit = try AXElement.at(scroll.point)
        let pid = hit.pid
        guard pid > 0 else { throw HelperFailure(.notFound, "accessibility target has no valid app pid") }
        // Overlay scroll bars are usually hidden, so hit testing lands on the content. Find
        // the nearest ancestor in the same app that owns a scroll bar for this axis.
        // Web content nests deeply, so search further up than clicks do.
        guard let bar = hit.ancestors(limit: AXScrollBarPosition.ancestorLimit).lazy.filter({ $0.pid == pid })
                .compactMap({ $0.element(plan.scrollBarAttribute) }).first else {
            throw HelperFailure(.unsupported, "no scroll area at \(scroll.point) or its nearby ancestors has a \(scroll.axis.rawValue) scroll bar")
        }
        guard bar.isSettable(kAXValueAttribute) else {
            throw HelperFailure(.unsupported, "the \(scroll.axis.rawValue) scroll bar's AXValue is not writable")
        }
        let before = bar.number(kAXValueAttribute)
        let error = bar.set(kAXValueAttribute, NSNumber(value: plan.fraction))
        // The app applies the new position asynchronously. Poll inside the action gate.
        var after: Double?
        for _ in 0..<AXScrollBarPosition.readbackAttempts {
            usleep(50_000)
            after = bar.number(kAXValueAttribute)
            if plan.landed(after: after) == true { break }
        }
        func format(_ value: Double?) -> String { value.map { String(format: "%.4f", $0) } ?? "unavailable" }
        return report("scrollTo", .axScrollBarValue, bar, error: error, landed: plan.landed(after: after),
                      detail: "\(scroll.axis.rawValue.capitalized) scroll bar AXValue \(format(before)) -> requested \(format(plan.fraction)), read back \(format(after)). No retry or fallback.")
    }
}
