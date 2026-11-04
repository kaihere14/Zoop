import AppKit
import ApplicationServices
import CoreGraphics
import ZoopShared

/// One shared instance per backend, across all connections. The gate remains held across
/// suspension (launching an app); actor isolation alone would permit reentrant input.
actor SessionActions {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var permissionDialogs: [PermissionDialogs.Observed] = []
    private var appDialogCache: [PermissionDialogs.Observed] = []

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
    func quitApps(keeping: [String]) async -> QuitAppsReport {
        await acquire()
        defer { release() }
        return await Apps.quitAll(keeping: Set(keeping))
    }
    func inspect(_ point: Point) throws -> [ElementInfo] {
        try AXElement.requirePermission()
        return try AXElement.at(point).ancestors.map(\.info)
    }
    func elements(_ query: ElementQuery) throws -> [ElementInfo] {
        try AXElement.requirePermission()
        return try AXElement.elements(query)
    }

    func permissionPrompts() throws -> [PermissionPrompt] {
        try AXElement.requirePermission()
        permissionDialogs = PermissionDialogs.scan(previous: permissionDialogs)
        return permissionDialogs.map(\.prompt)
    }

    func appDialogs(bundleID: String) throws -> [PermissionPrompt] {
        try AXElement.requirePermission()
        appDialogCache = PermissionDialogs.scan(previous: appDialogCache, bundleID: bundleID)
        return appDialogCache.map(\.prompt)
    }

    func respondToPermission(promptID: String, choiceID: String) async throws -> ActionReport {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        if let cached = appDialogCache.first(where: { $0.prompt.id == promptID }) {
            _ = try appDialogs(bundleID: cached.prompt.ownerApp)
        } else { _ = try permissionPrompts() }
        let (dialog, index) = try PermissionDialogs.selection(promptID: promptID, choiceID: choiceID, in: permissionDialogs + appDialogCache)
        let target = dialog.buttons[index].info
        let desktop = try AgentDesktopClient.installed()
        var reference: String?
        if let desktop {
            let surface = dialog.window.string(kAXRoleAttribute) == kAXSheetRole ? "sheet"
                : dialog.prompt.kind == .systemPermission ? "alert" : "window"
            let owners = NSWorkspace.shared.runningApplications.filter { $0.localizedName == dialog.prompt.ownerName && !$0.isTerminated }
            guard owners.count == 1, owners[0].processIdentifier == dialog.window.pid else {
                throw HelperFailure(.unsupported, "The dialog's app name is ambiguous. Nothing was pressed; inspect the agent session.")
            }
            let snapshot = try await desktop.snapshot(app: dialog.prompt.ownerName, surface: surface,
                                                      windowID: PermissionDialogs.windowID(for: dialog))
            reference = try AgentDesktopClient.reference(in: snapshot, target: target, label: dialog.labels[index])
            try Task.checkCancellation()
            // The snapshot can take seconds. Recheck the human's exact request and the
            // native button after it, before consuming the choice or sending an action.
            if dialog.prompt.kind == .appDialog { _ = try appDialogs(bundleID: dialog.prompt.ownerApp) }
            else { _ = try permissionPrompts() }
            let (current, currentIndex) = try PermissionDialogs.selection(promptID: promptID, choiceID: choiceID,
                                                                         in: permissionDialogs + appDialogCache)
            guard CFEqual(current.buttons[currentIndex].raw, dialog.buttons[index].raw) else {
                throw HelperFailure(.notFound, "The reviewed button changed while agent-desktop observed it. Nothing was pressed; review the new dialog.")
            }
        }
        try Task.checkCancellation()
        // Consume before performing: even an AX error can mean the press happened.
        permissionDialogs.removeAll { $0.prompt.id == promptID }
        appDialogCache.removeAll { $0.prompt.id == promptID }
        var axError: Int?
        var delivery: String
        if let desktop, let reference {
            do { delivery = "agent-desktop: \(try await desktop.click(reference))." }
            catch let failure as HelperFailure where failure.code == .notFound { throw failure }
            catch {
                try Task.checkCancellation()
                // A failed mutation can still have landed. Observe, never fall back to AXPress.
                delivery = "agent-desktop: \(error)."
            }
        } else {
            if dialog.prompt.kind == .appDialog {
                bringForward(dialog.buttons[index])
                _ = dialog.window.perform(kAXRaiseAction)
            }
            let error = dialog.buttons[index].perform(kAXPressAction)
            axError = Int(error.rawValue)
            delivery = "Native AXPress returned \(error.rawValue) (agent-desktop is not installed)."
        }
        var dismissed = false
        let deadline = ContinuousClock.now + .seconds(4)
        repeat {
            try Task.checkCancellation()
            if PermissionDialogs.isPresent(dialog) == false { dismissed = true; break }
            if NSRunningApplication(processIdentifier: dialog.window.pid)?.isTerminated != false { dismissed = true; break }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        return ActionReport(action: "permissionChoice", method: .axPress, target: target, pid: target.pid,
            app: target.app, axError: axError, landed: dismissed ? true : nil,
            detail: delivery + " " + (dismissed
                ? "Selected \(dialog.labels[index]); the dialog closed. \(dialog.prompt.kind == .appDialog ? "Verify the app's result separately; this is not proof that a file was saved." : "This does not independently verify the permission grant.")"
                : "The \(dialog.labels[index]) choice was attempted, but dialog dismissal could not be confirmed within four seconds. macOS may require direct interaction in the agent session. No automatic retry was sent."))
    }

    func perform(_ action: InputAction) async throws -> ActionReport {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        if !(try permissionPrompts()).isEmpty {
            throw HelperFailure(.unsupported, "A system permission dialog is waiting for the person's choice in Zoop. Do not click it or send keys automatically.")
        }
        switch action {
        case .click(let click):
            let result = try clickAt(click)
            if result.landed == nil {
                // Apps consume input asynchronously; especially AXShowMenu can appear
                // about a second later. Hold the action gate while it settles before the
                // runner captures its verification image.
                try await Task.sleep(for: result.method == .axShowMenu ? .milliseconds(1000) : .milliseconds(200))
            }
            return result
        case .setText(let action): return try setText(action)
        case .type(let text): return try type(text)
        case .key(let combo): return try key(combo)
        case .scrollTo(let scroll): return try scrollTo(scroll)
        case .saveDocument(let save):
            // A Save sheet left open would compete with the scripted save; the model must close it first.
            if let sheet = PermissionDialogs.scan(previous: [], bundleID: save.bundleID).first {
                throw HelperFailure(.unsupported, "\(sheet.prompt.ownerName) still has a dialog open (\(sheet.labels.joined(separator: ", "))). Close it with its Cancel button first, then save again.")
            }
            return try await DocumentSaver.save(save)
        case .sendEmail(let email):
            return try await MailSender.send(email)
        }
    }

    /// The person answers dialogs and sheets through Zoop's card; the agent never sends input to
    /// them. Refusing here, before any event is posted, covers clicks, typing and keys alike.
    private func refuseDialogInput(_ element: AXElement) throws {
        // Save-panel controls sit deep inside nested groups, so look further up than click targeting does.
        guard let dialog = element.ancestors(limit: 25).first(where: {
            PermissionDialogs.isDialog(role: $0.string(kAXRoleAttribute) ?? "", subrole: $0.string(kAXSubroleAttribute),
                                       modal: $0.attribute(kAXModalAttribute) as? Bool == true)
        }) else { return }
        let app = element.info.app ?? "the app"
        let title = dialog.string(kAXTitleAttribute).flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
        throw HelperFailure(.unsupported, "That control is in a dialog\(title). The person answers dialogs: call request_dialog_help with bundle_id \(app). Nothing was sent.")
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

    private func bringForward(_ element: AXElement) {
        let app = AXElement(AXUIElementCreateApplication(element.pid))
        _ = app.set(kAXFrontmostAttribute, kCFBooleanTrue)
        if let window = element.element(kAXWindowAttribute) {
            _ = window.set(kAXMainAttribute, kCFBooleanTrue)
            if window.actions.contains(kAXRaiseAction) { _ = window.perform(kAXRaiseAction) }
        }
    }

    private func focus(_ element: AXElement) -> AXError {
        bringForward(element)
        return element.set(kAXFocusedAttribute, kCFBooleanTrue)
    }

    /// Strategies are explicit: never send a second click just because AX returned an error.
    private func clickAt(_ click: ClickAction) throws -> ActionReport {
        guard (1...2).contains(click.count) else { throw HelperFailure(.badRequest, "click count must be 1 or 2") }
        guard click.point.x.isFinite, click.point.y.isFinite else { throw HelperFailure(.badRequest, "coordinates must be finite") }
        try AXElement.requirePermission()
        if click.strategy == .mouse { return try mouseClick(click) }
        let hit = try AXElement.at(click.point)
        try refuseDialogInput(hit)
        if let bundleID = click.bundleID, hit.info.app != bundleID {
            throw HelperFailure(.notFound, "the target point is not in \(bundleID). Call open_app, then take a new screenshot before locating it again.")
        }
        bringForward(hit)
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

    private func mouseClick(_ click: ClickAction) throws -> ActionReport {
        try requirePostEvent()
        guard let bundleID = click.bundleID, !bundleID.isEmpty else {
            throw HelperFailure(.badRequest, "mouse clicks require the target app's bundleID")
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              !app.isTerminated else { throw HelperFailure(.notFound, "\(bundleID) is not running in the agent session") }
        let pid = app.processIdentifier
        guard AXElement.focusedApp()?.pid == pid else {
            throw HelperFailure(.unsupported, "\(bundleID) is not the agent session's focused app. Call open_app, then screenshot and locate the target again before using strategy mouse.")
        }
        var process = proc_bsdinfo()
        let bytes = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &process, bytes) == bytes,
              process.pbi_uid == getuid() else {
            throw HelperFailure(.unsupported, "mouse target must belong to the helper's user session")
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let window = try MouseClickTarget(point: click.point, expectedPID: pid, windows: windows)
        let hit = try? AXElement.at(click.point)
        if let hit { try refuseDialogInput(hit) }
        let target = hit?.info
        let events = try window.events(for: click)
        // No global event taps, pointer warps or HID injection.
        for event in events { event.postToPid(pid); usleep(20_000) }
        return ActionReport(action: InputAction.click(click).name, method: .pidMouse, target: target,
                            pid: Int(pid), app: bundleID,
                            detail: "Mouse down/up posted to pid \(pid), window \(window.windowNumber). Delivery is unconfirmed; inspect the next screenshot before any further action. Background apps may ignore these events.")
    }

    private func setText(_ action: SetTextAction) throws -> ActionReport {
        try AXElement.requirePermission()
        let element = try action.point.map { try AXElement.at($0) } ?? AXElement.focused()
        try refuseDialogInput(element)
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
        try refuseDialogInput(element)
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
        if let focused { try refuseDialogInput(focused) }
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
