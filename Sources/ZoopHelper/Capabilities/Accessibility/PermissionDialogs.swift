import AppKit
import ApplicationServices
import ZoopShared

/// System consent UI is hosted separately from the app asking for access (for example,
/// Maps location consent belongs to CoreLocationAgent). Never search the app's menu tree.
enum PermissionDialogs {
    static let hosts: Set<String> = [
        "com.apple.CoreLocationAgent", "com.apple.UserNotificationCenter", "com.apple.TCCUIService",
        "com.apple.SecurityAgent", "com.apple.universalaccessAuthWarn", "com.apple.accessibility.universalAccessAuthWarn",
    ]

    struct Observed {
        let window: AXElement
        let prompt: PermissionPrompt
        let buttons: [AXElement]
        let labels: [String]
        var parent: AXElement? = nil
    }

    static func retainedPrompt(window: AXElement, message: String, labels: [String], previous: [Observed]) -> PermissionPrompt? {
        previous.first { CFEqual($0.window.raw, window.raw) && $0.prompt.message == message && $0.labels == labels }?.prompt
    }

    static func selection(promptID: String, choiceID: String, in dialogs: [Observed]) throws -> (Observed, Int) {
        guard let dialog = dialogs.first(where: { $0.prompt.id == promptID }),
              let index = dialog.prompt.choices.firstIndex(where: { $0.id == choiceID }), dialog.buttons.indices.contains(index) else {
            throw HelperFailure(.notFound, "This permission dialog changed or closed. No button was pressed; review the current request.")
        }
        return (dialog, index)
    }

    static func scan(previous: [Observed], bundleID: String? = nil) -> [Observed] {
        var result: [Observed] = []
        let deadline = ContinuousClock.now + .seconds(3)
        for app in NSWorkspace.shared.runningApplications where bundleID.map({ app.bundleIdentifier == $0 }) ?? hosts.contains(app.bundleIdentifier ?? "") {
            guard ContinuousClock.now < deadline else { break }
            guard !app.isTerminated else { continue }
            var process = proc_bsdinfo()
            let bytes = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(app.processIdentifier, PROC_PIDTBSDINFO, 0, &process, bytes) == bytes,
                  process.pbi_uid == getuid() else { continue }
            let root = AXElement(AXUIElementCreateApplication(app.processIdentifier))
            let windows = (root.attribute(kAXWindowsAttribute) as? [AXUIElement] ?? []).prefix(6).map(AXElement.init)
            let candidates: [Container]
            if bundleID == nil { candidates = windows.map { Container(element: $0, context: "", depth: 0) } }
            else {
                let discovered = containers(in: windows, deadline: deadline)
                guard discovered.complete else { continue }
                candidates = discovered.values
            }
            for candidate in candidates {
                guard ContinuousClock.now < deadline else { break }
                let window = candidate.element
                var queue = [window], index = 0
                var texts: [String] = candidate.context.isEmpty ? [] : [candidate.context]
                var buttons: [AXElement] = [], labels: [String] = []
                var secure = false
                // A static text ending in ":" (such as "Save As:") labels the next field.
                // It is not shown on its own; the field line carries it with the value.
                var fieldLabel: String?
                while index < queue.count, index < 100, ContinuousClock.now < deadline {
                    let element = queue[index]; index += 1
                    let role = element.string(kAXRoleAttribute) ?? ""
                    if element.string(kAXSubroleAttribute) == kAXSecureTextFieldSubrole { secure = true; break }
                    if [kAXStaticTextRole, "AXHeading"].contains(role),
                       let text = element.string(kAXValueAttribute) ?? element.string(kAXTitleAttribute) ?? element.string(kAXDescriptionAttribute),
                       !text.isEmpty, !texts.contains(text) {
                        let trimmed = text.trimmingCharacters(in: .whitespaces)
                        if bundleID != nil, trimmed.hasSuffix(":"), trimmed.count <= 40 { fieldLabel = String(trimmed.dropLast()) }
                        else { texts.append(String(text.prefix(4000))) }
                    }
                    if bundleID != nil, [kAXTextFieldRole, kAXComboBoxRole, kAXPopUpButtonRole].contains(role),
                       let value = element.string(kAXValueAttribute), !value.isEmpty {
                        let named = [element.string(kAXTitleAttribute), element.string(kAXDescriptionAttribute)]
                            .compactMap { $0?.trimmingCharacters(in: CharacterSet(charactersIn: ": ")) }.first { !$0.isEmpty }
                        let line = "\(named ?? fieldLabel ?? "Field"): \(String(value.prefix(4000)))"
                        if !texts.contains(line) { texts.append(line) }
                        fieldLabel = nil
                    }
                    if role == kAXButtonRole, element.attribute(kAXEnabledAttribute) as? Bool != false,
                       element.actions.contains(kAXPressAction),
                       let label = element.string(kAXTitleAttribute) ?? element.string(kAXDescriptionAttribute),
                       !label.isEmpty, label != "Help", label != "?", labels.count < 8 {
                        buttons.append(element); labels.append(label)
                    }
                    let children = [kAXTextAreaRole, kAXTableRole, kAXOutlineRole, "AXBrowser", "AXWebArea"].contains(role) ? [] : element.children
                    guard queue.count + children.count <= 100 else { secure = true; break }
                    queue.append(contentsOf: children)
                }
                let message = texts.joined(separator: "\n\n")
                guard index == queue.count, !secure, !message.isEmpty, !buttons.isEmpty else { continue }
                let prompt = retainedPrompt(window: window, message: message, labels: labels, previous: previous)
                    ?? PermissionPrompt(id: UUID().uuidString, ownerApp: app.bundleIdentifier!,
                    ownerName: app.localizedName ?? app.bundleIdentifier!, message: message,
                    choices: labels.map { PermissionChoice(id: UUID().uuidString, title: $0) },
                    kind: bundleID == nil ? .systemPermission : .appDialog)
                result.append(Observed(window: window, prompt: prompt, buttons: buttons, labels: labels,
                                       parent: bundleID == nil ? nil : window.element(kAXParentAttribute)))
            }
        }
        return result
    }
    struct Container {
        let element: AXElement
        let context: String
        let depth: Int
    }

    static func isDialog(role: String, subrole: String?, modal: Bool) -> Bool {
        role == kAXSheetRole || subrole == kAXDialogSubrole || subrole == kAXSystemDialogSubrole || modal
    }

    /// Search window structure, never an app's entire menu or web/document tree.
    /// Deepest sheets come first, so a replace confirmation wins over its Save sheet.
    static func containers(in windows: [AXElement], deadline: ContinuousClock.Instant) -> (values: [Container], complete: Bool) {
        var found: [Container] = [], visited = 0
        for window in windows {
            let title = window.string(kAXTitleAttribute) ?? "App dialog"
            var queue = [Container(element: window, context: title, depth: 0)], index = 0
            while index < queue.count {
                guard ContinuousClock.now < deadline, visited < 150 else { return (found, false) }
                let node = queue[index]; index += 1; visited += 1
                let role = node.element.string(kAXRoleAttribute) ?? ""
                if isDialog(role: role, subrole: node.element.string(kAXSubroleAttribute),
                            modal: node.element.attribute(kAXModalAttribute) as? Bool == true) { found.append(node) }
                guard node.depth < 8, ![kAXMenuBarRole, kAXMenuRole, kAXTextAreaRole, kAXTableRole, kAXOutlineRole, "AXBrowser", "AXWebArea"].contains(role) else { continue }
                let children = node.element.children
                // An attached sheet blocks the content behind it. Follow the sheet branch
                // rather than spending the budget walking Maps' entire map/view hierarchy.
                let sheets = children.filter { $0.string(kAXRoleAttribute) == kAXSheetRole }
                let selected = sheets.isEmpty ? children : sheets
                guard queue.count + selected.count <= 150 else { return (found, false) }
                queue.append(contentsOf: selected.map {
                    Container(element: $0, context: title, depth: node.depth + 1)
                })
            }
        }
        return (found.sorted { $0.depth > $1.depth }, true)
    }

    /// Nil is an unreadable/incomplete tree, never proof that a sheet closed.
    static func isPresent(_ dialog: Observed) -> Bool? {
        if dialog.prompt.kind == .appDialog, let parent = dialog.parent,
           let children = parent.attribute(kAXChildrenAttribute) as? [AXUIElement] {
            return children.contains { CFEqual($0, dialog.window.raw) }
        }
        let app = AXElement(AXUIElementCreateApplication(dialog.window.pid))
        guard let raw = app.attribute(kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        if dialog.prompt.kind == .systemPermission { return raw.contains { CFEqual($0, dialog.window.raw) } }
        let current = containers(in: raw.map(AXElement.init), deadline: .now + .seconds(3))
        guard current.complete else { return nil }
        return current.values.contains { CFEqual($0.element.raw, dialog.window.raw) }
    }

}
