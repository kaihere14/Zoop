import Foundation
import ZoopShared

public protocol PermissionHandling: Sendable {
    func permissionPrompts() async throws -> [PermissionPrompt]
    func respondToPermission(promptID: String, choiceID: String) async throws -> ActionReport
    func appDialogs(bundleID: String) async throws -> [PermissionPrompt]
}

extension PermissionHandling {
    public func appDialogs(bundleID: String) async throws -> [PermissionPrompt] { [] }
}

extension HelperConnection: PermissionHandling {}

/// Pauses at the actual system dialog, outside the model loop. The human's chosen token
/// goes directly to the helper, so even Auto mode cannot infer or grant consent.
public struct PermissionToolRunner: ToolRunning {
    let tools: any ToolRunning
    let permissions: any PermissionHandling
    let prompter: any UserPrompting
    let onEvent: @Sendable (AgentEvent) -> Void
    /// Half-second checks for a macOS consent dialog to appear after `consent_pending`.
    let consentPolls: Int

    public init(tools: any ToolRunning, permissions: any PermissionHandling, prompter: any UserPrompting,
                consentPolls: Int = 8, onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        self.tools = tools; self.permissions = permissions; self.prompter = prompter
        self.consentPolls = max(0, consentPolls); self.onEvent = onEvent
    }

    public func extraModelTools() async -> [ModelTool] { await tools.extraModelTools() }

    /// Every permission, dialog and save goes to the person; the model never clicks a dialog.
    /// - macOS permission prompts are checked before every tool and after every action.
    /// - An in-app dialog (Save, Replace, Continue, onboarding) is shown as soon as it is open
    ///   in the app an action targets or touched.
    /// - `save_document` runs only after the person approves that exact save.
    public func call(_ name: String, argumentsJSON: String) async -> ToolResult {
        do {
            try await resolvePermissions()
            let args = try? JSONValue.parse(argumentsJSON.isEmpty ? "{}" : argumentsJSON)
            if name == ExecutorPrompt.Control.requestDialogHelp.rawValue {
                guard let app = args?["bundle_id"]?.stringValue, !app.isEmpty else {
                    throw PermissionInterruption.message("Dialog help needs the target app's bundle_id.")
                }
                return try await resolveAppDialog(app)
            }
            guard SessionToolName(rawValue: name).map({ !SessionTools.definition(for: $0).isReadOnly }) == true else {
                return await tools.call(name, argumentsJSON: argumentsJSON)
            }
            // A dialog already open in the target app comes first. The action is not run, because
            // the person's answer may change what it should be.
            for app in Self.apps(arguments: args, result: nil) {
                if let answered = try await answerOpenDialog(in: app) {
                    return Self.merge(answered, into: ToolResult(tool: name, isError: false, content: ["ok": true,
                        "detail": .string("Not run: a dialog was already open in \(app), and the person answered it first. Inspect the new screenshot, then decide whether to repeat the action.")]))
                }
            }
            if name == SessionToolName.saveDocument.rawValue, let declined = await approveSave(args) { return declined }
            if name == SessionToolName.sendEmail.rawValue, let declined = await approveEmail(args) { return declined }
            var result = await tools.call(name, argumentsJSON: argumentsJSON)
            var answered = try await resolvePermissions()
            // consent_pending guarantees the task action has not run. A save can ask for
            // Automation, then Files & Folders, so allow a bounded chain of prerequisites.
            var consentAttempts = 0
            while result.content["error"] == "consent_pending", consentAttempts < 4 {
                if !answered {
                    for _ in 0..<consentPolls {
                        try await Task.sleep(for: .milliseconds(500))
                        answered = try await resolvePermissions()
                        if answered { break }
                    }
                }
                guard answered else {
                    return ToolResult(tool: name, isError: true, content: ["ok": false, "error": "consent_pending",
                        "message": "macOS requested consent, but no readable permission dialog was answered. Check the agent session and its Accessibility permissions.",
                        "requires_observation": true, "retry": "no",
                        "next": "Pause for the person. The action was not repeated and no permission choice was inferred."])
                }
                try Task.checkCancellation()
                consentAttempts += 1
                result = await tools.call(name, argumentsJSON: argumentsJSON)
                answered = try await resolvePermissions()
            }
            // A dialog the action opened goes to the person straight away.
            for app in Self.apps(arguments: args, result: result) {
                if let answered = try await answerOpenDialog(in: app) { return Self.merge(answered, into: result) }
            }
            return result
        } catch {
            return ToolResult(tool: name, isError: true, content: ["ok": false, "error": "setup_error",
                "message": .string("Waiting on the person: \(error)"),
                "next": "No automatic choice was made for the person. Stop and report what happened."])
        }
    }

    /// Asks the person to approve one exact save. Nil means approved.
    private func approveSave(_ args: JSONValue?) async -> ToolResult? {
        let bundleID = args?["bundle_id"]?.stringValue ?? "the app"
        let path = args?["path"]?.stringValue ?? "the requested file"
        let overwrite = args?["overwrite"]?.boolValue == true
        let app = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        let question = "Save the \(app) document as \(path)?" + (overwrite ? " This replaces the existing file." : "")
        onEvent(.question(question))
        let answer = await prompter.ask(question, kind: .confirm) ?? ""
        onEvent(.answer(answer))
        guard PlanRunner.isApproval(answer) else {
            return ToolResult(tool: SessionToolName.saveDocument.rawValue, isError: true, content: ["ok": false, "error": "declined",
                "message": .string("The person did not approve saving \(path)."),
                "retry": "no", "next": "Do not save another way. Continue without saving or finish and report it."])
        }
        return nil
    }

    /// Asks the person to approve one exact email: recipients, subject and full text. Nil means approved.
    private func approveEmail(_ args: JSONValue?) async -> ToolResult? {
        let to = args?["to"]?.stringValue ?? ""
        let subject = args?["subject"]?.stringValue ?? ""
        let body = args?["body"]?.stringValue ?? ""
        let question = "Send this email to \(to)?\n\nSubject: \(subject)\n\n\(body)"
        onEvent(.question(question))
        let answer = await prompter.ask(question, kind: .confirm) ?? ""
        onEvent(.answer(answer))
        guard PlanRunner.isApproval(answer) else {
            return ToolResult(tool: SessionToolName.sendEmail.rawValue, isError: true, content: ["ok": false, "error": "declined",
                "message": .string("The person did not approve sending this email to \(to)."),
                "retry": "no", "next": "Do not send it another way. Finish and report that the email was not sent."])
        }
        return nil
    }

    /// Shows the app's open dialog to the person, if there is one.
    private func answerOpenDialog(in app: String) async throws -> ToolResult? {
        guard let dialog = try await permissions.appDialogs(bundleID: app).first, dialog.kind == .appDialog else { return nil }
        return try await resolveAppDialog(dialog.ownerApp)
    }

    /// Apps an action named or touched, so their dialogs can be checked.
    static func apps(arguments: JSONValue?, result: ToolResult?) -> [String] {
        var apps: [String] = []
        func add(_ value: JSONValue?) { if let app = value?.stringValue, !app.isEmpty, !apps.contains(app) { apps.append(app) } }
        add(arguments?["bundle_id"])
        if case .array(let actions)? = arguments?["actions"] { actions.forEach { add($0["bundle_id"]) } }
        add(result?.content["app"])
        if case .array(let entries)? = result?.content["results"] { entries.forEach { add($0["app"]) } }
        return apps
    }

    /// The person's dialog answer, attached to the action that led to it.
    static func merge(_ answered: ToolResult, into action: ToolResult) -> ToolResult {
        var content = action.content.objectValue ?? [:]
        for (key, value) in answered.content.objectValue ?? [:] where key != "ok" { content["dialog_\(key)"] = value }
        content["human_choice"] = answered.content["human_choice"]
        content["requires_observation"] = true
        content["next"] = answered.content["next"]
        return ToolResult(tool: action.tool, isError: action.isError || answered.isError, content: .object(content), image: action.image)
    }

    private func resolveAppDialog(_ bundleID: String) async throws -> ToolResult {
        for _ in 0..<3 {
            try Task.checkCancellation()
            guard let prompt = try await permissions.appDialogs(bundleID: bundleID).first else {
                return ToolResult(tool: "request_dialog_help", isError: true, content: ["ok": false, "error": "not_found",
                    "message": "No readable sheet or dialog with actionable buttons was found in that app. It may already have closed; inspect the screenshot.",
                    "requires_observation": true])
            }
            guard prompt.kind == .appDialog, prompt.ownerApp == bundleID else {
                throw PermissionInterruption.message("Dialog help returned a different app or dialog type. No choice was sent.")
            }
            onEvent(.progress(note: "Waiting for your choice in \(prompt.ownerName)", step: nil, percent: nil))
            onEvent(.question(prompt.message))
            guard let choice = await prompter.choosePermission(prompt), let selected = prompt.choices.first(where: { $0.id == choice && $0.enabled }) else {
                throw PermissionInterruption.message("The person left the app dialog unchanged and ended the task.")
            }
            onEvent(.answer("\(prompt.ownerName): \(selected.title)"))
            do {
                let report = try await permissions.respondToPermission(promptID: prompt.id, choiceID: choice)
                guard report.landed == true else { throw PermissionInterruption.message(report.detail) }
                let disabled = prompt.choices.filter { !$0.enabled }.map(\.title)
                var content: [String: JSONValue] = ["ok": true,
                    "app": .string(bundleID), "human_choice": .string(selected.title), "verified": true,
                    "detail": .string(report.detail), "requires_observation": true,
                    "next": "The person chose this exact button and its dialog closed. Inspect the new screenshot before continuing. Verify the task outcome separately; do not repeat the choice."]
                if !disabled.isEmpty {
                    // The card told the person that closing the dialog lets Zoop try another way.
                    content["disabled_choices"] = .array(disabled.map(JSONValue.string))
                    content["next"] = .string("\(disabled.joined(separator: ", ")) was greyed out, so the person could not choose it. The card told them that choosing \(selected.title) closes the stuck dialog so Zoop can try another way; it is not a refusal of the task. For a Save sheet, use save_document. Inspect the new screenshot first.")
                }
                return ToolResult(tool: "request_dialog_help", isError: false, content: .object(content))
            } catch BridgeError.helperFailure(let failure) where failure.code == .notFound { continue }
        }
        throw PermissionInterruption.message("The app dialog kept changing; no stale choice was pressed.")
    }

    /// Shows pending macOS permission dialogs to the person. True if at least one was answered.
    @discardableResult
    private func resolvePermissions() async throws -> Bool {
        // Bound chained requests. A changed/stale request is shown again, never translated
        // into an automatic 'Allow' on whatever dialog replaced it.
        var answered = false
        for _ in 0..<8 {
            try Task.checkCancellation()
            guard let prompt = try await permissions.permissionPrompts().first else { return answered }
            onEvent(.progress(note: "Waiting for your permission choice", step: nil, percent: nil))
            onEvent(.question(prompt.message))
            guard let choice = await prompter.choosePermission(prompt), prompt.choices.contains(where: { $0.id == choice && $0.enabled }) else {
                throw PermissionInterruption.message("The person dismissed the permission request. The dialog was left unchanged.")
            }
            onEvent(.answer("System dialog: \(prompt.choices.first { $0.id == choice }!.title)"))
            do {
                let report = try await permissions.respondToPermission(promptID: prompt.id, choiceID: choice)
                onEvent(.toolFinished(name: "permission_choice", result: ToolResult(tool: "permission_choice", isError: false,
                    content: ["method": .string(report.method.rawValue), "detail": .string(report.detail),
                              "verified": report.landed.map(JSONValue.bool) ?? .null])))
                guard report.landed == true else { throw PermissionInterruption.message(report.detail) }
                answered = true
            } catch BridgeError.helperFailure(let failure) where failure.code == .notFound {
                continue // The person must review the new dialog and its new choices.
            }
        }
        throw PermissionInterruption.message("Too many changing permission dialogs; check the agent session.")
    }
}

private enum PermissionInterruption: Error, CustomStringConvertible {
    case message(String)
    var description: String { switch self { case .message(let text): text } }
}
