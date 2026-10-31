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
        case .scroll(let scroll): return try scrollAt(scroll)
        case .scrollPage(let scroll): return try scrollPageAt(scroll)
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

    private func clickAt(_ click: ClickAction) throws -> ActionReport {
        guard (1...2).contains(click.count) else { throw HelperFailure(.badRequest, "click count must be 1 or 2") }
        guard click.point.x.isFinite, click.point.y.isFinite else { throw HelperFailure(.badRequest, "coordinates must be finite") }
        var hit: AXElement?
        if AXIsProcessTrusted() {
            hit = try? AXElement.at(click.point)
            for element in hit?.ancestors ?? [] {
                let actions = element.actions
                let action: String
                let method: ActionMethod
                if click.button == .right {
                    action = kAXShowMenuAction; method = .axShowMenu
                } else if click.count == 2 {
                    action = "AXOpen"; method = .axOpen
                } else {
                    action = kAXPressAction; method = .axPress
                }
                if actions.contains(action) {
                    // Capture the target first: pressing may close a menu or destroy the element.
                    let info = element.info
                    let error = element.perform(action)
                    return ActionReport(action: InputAction.click(click).name, method: method, target: info,
                                        pid: info.pid, app: info.app, axError: Int(error.rawValue),
                                        detail: "\(action) attempted; check the next screenshot. No event fallback after an AX attempt.")
                }
                if click.button == .left, click.count == 1,
                   [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(element.string(kAXRoleAttribute) ?? ""),
                   element.isSettable(kAXFocusedAttribute) {
                    let error = focus(element)
                    let focused = element.attribute(kAXFocusedAttribute) as? Bool
                    return report("click", .axFocus, element, error: error, landed: focused == true ? true : nil,
                                  detail: "AX focus attempted; window main and app frontmost were requested best effort.")
                }
            }
        }
        try requirePostEvent()
        let window = try WindowTarget.at(click.point, ownerPID: hit?.pid)
        let source = CGEventSource(stateID: .privateState)
        for index in 1...click.count {
            let right = click.button == .right
            guard let down = CGEvent(mouseEventSource: source, mouseType: right ? .rightMouseDown : .leftMouseDown,
                                     mouseCursorPosition: click.point.cgPoint, mouseButton: right ? .right : .left),
                  let up = CGEvent(mouseEventSource: source, mouseType: right ? .rightMouseUp : .leftMouseUp,
                                   mouseCursorPosition: click.point.cgPoint, mouseButton: right ? .right : .left) else {
                throw HelperFailure(.internalError, "could not create mouse events")
            }
            for event in [down, up] {
                window.configure(event)
                event.setIntegerValueField(.mouseEventClickState, value: Int64(index))
                event.postToPid(window.pid)
                usleep(10_000)
            }
        }
        return ActionReport(action: InputAction.click(click).name, method: .pidMouse, target: hit?.info,
                            pid: Int(window.pid), app: window.app, detail: "Mouse events sent to window \(window.number); delivery is unconfirmed.")
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
        let element = try AXElement.focused()
        guard element.pid > 0 else { throw HelperFailure(.notFound, "focused element has no app pid") }
        try sendKey(code, pid: element.pid, flags: KeyMap.flags(combo.modifiers))
        return report("key", .pidKeys, element, detail: "Posted \(combo) to the focused app; check the next screenshot.")
    }

    private func scrollPageAt(_ scroll: PageScrollAction) throws -> ActionReport {
        let plan = try AXPageScroll(scroll)
        try AXElement.requirePermission()
        let hit = try AXElement.at(scroll.point)
        let pid = hit.pid
        guard pid > 0 else { throw HelperFailure(.notFound, "accessibility target has no valid app pid") }
        guard let element = hit.ancestors.first(where: { $0.pid == pid && $0.actions.contains(plan.actionName) }) else {
            throw HelperFailure(.unsupported, "no element at \(scroll.point) or its nearby ancestors advertises \(plan.actionName)")
        }
        let info = element.info
        let outcome = plan.run { element.perform(plan.actionName) }
        return ActionReport(action: "scrollPage", method: .axScrollPage, target: info, pid: info.pid, app: info.app,
                            axError: Int(outcome.error.rawValue),
                            detail: "\(plan.actionName): \(outcome.attempted) attempt(s), \(outcome.accepted) accepted of \(scroll.pages) requested page(s). Check the next screenshot; accepted does not prove movement. No retry or event fallback.")
    }

    private func scrollAt(_ scroll: ScrollAction) throws -> ActionReport {
        guard let dy = Int32(exactly: scroll.deltaY), let dx = Int32(exactly: scroll.deltaX),
              dy != Int32.min, dx != Int32.min else { throw HelperFailure(.badRequest, "scroll deltas are out of range") }
        try requirePostEvent()
        let hit = AXIsProcessTrusted() ? try? AXElement.at(scroll.point) : nil
        let window = try WindowTarget.at(scroll.point, ownerPID: hit?.pid)
        guard let event = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .privateState), units: .line,
                                  wheelCount: 2, wheel1: -dy, wheel2: -dx, wheel3: 0) else {
            throw HelperFailure(.internalError, "could not create scroll event")
        }
        event.location = scroll.point.cgPoint
        window.configure(event)
        event.postToPid(window.pid)
        return ActionReport(action: "scroll", method: .pidScroll, target: hit?.info, pid: Int(window.pid), app: window.app,
                            detail: "Scroll sent to window \(window.number); delivery is unconfirmed.")
    }
}

private extension Point { var cgPoint: CGPoint { CGPoint(x: x, y: y) } }

struct WindowTarget {
    let pid: pid_t
    let number: Int
    var app: String? { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier }

    static func at(_ point: Point, ownerPID: pid_t? = nil) throws -> WindowTarget {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return try select(at: point, windows: windows, ownerPID: ownerPID)
    }

    /// Window bounds include transparent/click-through regions (for example Notification
    /// Center's screen-sized window). AX hit testing identifies the app actually at the
    /// point. Constrain the window list to that owner while preserving its front-to-back
    /// order. If the AX owner disappears, never redirect the event to another app.
    static func select(at point: Point, windows: [[String: Any]], ownerPID: pid_t?) throws -> WindowTarget {
        guard point.x.isFinite, point.y.isFinite else { throw HelperFailure(.badRequest, "coordinates must be finite") }
        if let ownerPID, ownerPID <= 0 { throw HelperFailure(.notFound, "accessibility target has no valid app pid") }
        for window in windows {
            guard let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point.cgPoint),
                  let pid = window[kCGWindowOwnerPID as String] as? Int32, pid > 0,
                  ownerPID == nil || pid == ownerPID,
                  let number = window[kCGWindowNumber as String] as? Int,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            return WindowTarget(pid: pid, number: number)
        }
        let owner = ownerPID.map { " for AX target pid \($0)" } ?? ""
        throw HelperFailure(.notFound, "no window at \(point)\(owner) in the agent session")
    }
    func configure(_ event: CGEvent) {
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(number))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(number))
    }
}
