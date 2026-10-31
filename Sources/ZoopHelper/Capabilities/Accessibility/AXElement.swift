import AppKit
import ApplicationServices
import ZoopShared

/// Confined to SessionActions. AX references never cross its actor boundary.
struct AXElement {
    let raw: AXUIElement

    init(_ raw: AXUIElement) {
        self.raw = raw
        AXUIElementSetMessagingTimeout(raw, 2)
    }

    static func requirePermission() throws {
        guard AXIsProcessTrusted() else {
            throw HelperFailure(.permissionDenied, "Accessibility is not allowed for ZoopHelper in \(NSUserName())'s session. Enable it in System Settings > Privacy & Security > Accessibility.")
        }
    }

    /// Retry only a read: an AX action can take effect even when it returns an error.
    static func read(_ body: () -> AXError) -> AXError {
        let result = body()
        guard result == .apiDisabled else { return result }
        // The prototype needed a brief pause while a fresh AX connection initialized.
        usleep(300_000)
        return body()
    }

    static func system() -> AXElement {
        let element = AXElement(AXUIElementCreateSystemWide())
        // Also sets the process-wide default for subsequently obtained elements.
        AXUIElementSetMessagingTimeout(element.raw, 2)
        return element
    }

    static func at(_ point: Point) throws -> AXElement {
        guard Float(point.x).isFinite, Float(point.y).isFinite else { throw HelperFailure(.badRequest, "coordinates must be finite") }
        let system = system()
        var element: AXUIElement?
        let error = read { AXUIElementCopyElementAtPosition(system.raw, Float(point.x), Float(point.y), &element) }
        guard error == .success, let element else {
            throw HelperFailure(.notFound, "no accessibility element at \(point) (AXError \(error.rawValue))")
        }
        return AXElement(element)
    }

    static func focused() throws -> AXElement {
        guard let element = system().element(kAXFocusedUIElementAttribute) else {
            throw HelperFailure(.notFound, "no focused accessibility element in the agent session; click a text field first")
        }
        return element
    }

    func attribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard Self.read({ AXUIElementCopyAttributeValue(raw, name as CFString, &value) }) == .success else { return nil }
        return value
    }

    func string(_ name: String) -> String? {
        guard let value = attribute(name) else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    func element(_ name: String) -> AXElement? {
        guard let value = attribute(name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(value as! AXUIElement)
    }

    var children: [AXElement] {
        // Bound each child list as well as the overall tree walk.
        var values: CFArray?
        guard Self.read({ AXUIElementCopyAttributeValues(raw, kAXChildrenAttribute as CFString, 0, 1000, &values) }) == .success else { return [] }
        return (values as? [AXUIElement] ?? []).map(AXElement.init)
    }

    var pid: pid_t { var pid: pid_t = 0; AXUIElementGetPid(raw, &pid); return pid }
    var actions: [String] {
        var names: CFArray?
        _ = Self.read { AXUIElementCopyActionNames(raw, &names) }
        return names as? [String] ?? []
    }
    func isSettable(_ name: String) -> Bool {
        var result = DarwinBoolean(false)
        return Self.read { AXUIElementIsAttributeSettable(raw, name as CFString, &result) } == .success && result.boolValue
    }
    func set(_ name: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(raw, name as CFString, value)
    }
    func perform(_ action: String) -> AXError { AXUIElementPerformAction(raw, action as CFString) }

    var info: ElementInfo {
        var frame: Rect?
        if let position = attribute(kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
           let size = attribute(kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() {
            var p = CGPoint.zero
            var s = CGSize.zero
            if AXValueGetValue(position as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) {
                frame = Rect(x: p.x, y: p.y, width: s.width, height: s.height)
            }
        }
        return ElementInfo(role: string(kAXRoleAttribute) ?? "AXUnknown", subrole: string(kAXSubroleAttribute),
                           title: string(kAXTitleAttribute), label: string(kAXDescriptionAttribute),
                           value: string(kAXValueAttribute), identifier: string(kAXIdentifierAttribute),
                           frame: frame, actions: actions, pid: Int(pid),
                           app: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
    }

    var ancestors: [AXElement] {
        var result = [self]
        while result.count < 6, let parent = result.last?.element(kAXParentAttribute),
              !result.contains(where: { CFEqual($0.raw, parent.raw) }) { result.append(parent) }
        return result
    }

    static func elements(_ query: ElementQuery) throws -> [ElementInfo] {
        guard (1...1000).contains(query.limit) else { throw HelperFailure(.badRequest, "element limit must be 1...1000") }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: query.bundleID).first else {
            throw HelperFailure(.notFound, "\(query.bundleID) is not running in the agent session")
        }
        var queue = [AXElement(AXUIElementCreateApplication(app.processIdentifier))]
        var seen = Set<AXUIElement>()
        var index = 0
        var result: [ElementInfo] = []
        let deadline = ContinuousClock.now + .seconds(7)
        while index < queue.count, index < 2000, result.count < query.limit, ContinuousClock.now < deadline {
            let element = queue[index]
            index += 1
            guard seen.insert(element.raw).inserted else { continue }
            let info = element.info
            if !query.interactiveOnly || !info.actions.isEmpty || element.isSettable(kAXValueAttribute) { result.append(info) }
            queue.append(contentsOf: element.children.prefix(max(0, 2000 - queue.count)))
        }
        return result
    }
}
