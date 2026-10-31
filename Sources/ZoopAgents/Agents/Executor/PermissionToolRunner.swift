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

    public init(tools: any ToolRunning, permissions: any PermissionHandling, prompter: any UserPrompting,
                onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        self.tools = tools; self.permissions = permissions; self.prompter = prompter; self.onEvent = onEvent
    }

    public func call(_ name: String, argumentsJSON: String) async -> ToolResult {
        do {
            try await resolvePermissions()
            if name == ExecutorPrompt.Control.requestDialogHelp.rawValue {
                guard let args = try? JSONValue.parse(argumentsJSON),
                      let app = args["bundle_id"]?.stringValue, !app.isEmpty else {
                    throw PermissionInterruption.message("Dialog help needs the target app's bundle_id.")
                }
                return try await resolveAppDialog(app)
            }
            let result = await tools.call(name, argumentsJSON: argumentsJSON)
            // A launch or action may have just opened the dialog. Observe it before the
            // next model call, rather than spending failed-click retries on system UI.
            if SessionToolName(rawValue: name).map({ !SessionTools.definition(for: $0).isReadOnly }) == true {
                try await resolvePermissions()
            }
            return result
        } catch {
            return ToolResult(tool: name, isError: true, content: ["ok": false, "error": "setup_error",
                "message": .string("System permission needs attention: \(error)"),
                "next": "No automatic permission choice was made. Review the permission request in the agent session, then retry the task."])
        }
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
            guard let choice = await prompter.choosePermission(prompt), let selected = prompt.choices.first(where: { $0.id == choice }) else {
                throw PermissionInterruption.message("The person left the app dialog unchanged and ended the task.")
            }
            onEvent(.answer("\(prompt.ownerName): \(selected.title)"))
            do {
                let report = try await permissions.respondToPermission(promptID: prompt.id, choiceID: choice)
                guard report.landed == true else { throw PermissionInterruption.message(report.detail) }
                return ToolResult(tool: "request_dialog_help", isError: false, content: ["ok": true,
                    "app": .string(bundleID), "human_choice": .string(selected.title), "verified": true,
                    "detail": .string(report.detail), "requires_observation": true,
                    "next": "The person chose this exact button and its dialog closed. Inspect the new screenshot before continuing. Verify the task outcome separately; do not repeat the choice."])
            } catch BridgeError.helperFailure(let failure) where failure.code == .notFound { continue }
        }
        throw PermissionInterruption.message("The app dialog kept changing; no stale choice was pressed.")
    }

    private func resolvePermissions() async throws {
        // Bound chained requests. A changed/stale request is shown again, never translated
        // into an automatic 'Allow' on whatever dialog replaced it.
        for _ in 0..<8 {
            try Task.checkCancellation()
            guard let prompt = try await permissions.permissionPrompts().first else { return }
            onEvent(.progress(note: "Waiting for your permission choice", step: nil, percent: nil))
            onEvent(.question(prompt.message))
            guard let choice = await prompter.choosePermission(prompt), prompt.choices.contains(where: { $0.id == choice }) else {
                throw PermissionInterruption.message("The person dismissed the permission request. The dialog was left unchanged.")
            }
            onEvent(.answer("System dialog: \(prompt.choices.first { $0.id == choice }!.title)"))
            do {
                let report = try await permissions.respondToPermission(promptID: prompt.id, choiceID: choice)
                onEvent(.toolFinished(name: "permission_choice", result: ToolResult(tool: "permission_choice", isError: false,
                    content: ["method": .string(report.method.rawValue), "detail": .string(report.detail),
                              "verified": report.landed.map(JSONValue.bool) ?? .null])))
                guard report.landed == true else { throw PermissionInterruption.message(report.detail) }
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
