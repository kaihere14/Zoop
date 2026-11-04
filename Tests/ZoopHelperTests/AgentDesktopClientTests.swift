import Foundation
import Testing
import ZoopShared
@testable import ZoopHelper

@Suite struct AgentDesktopClientTests {
    let target = ElementInfo(role: "AXButton", title: "OK", identifier: "confirm", frame: Rect(x: 10, y: 20, width: 80, height: 24), pid: 42)
    let button: JSONValue = ["role": "button", "name": "OK", "native_id": ["kind": "ax_identifier", "value": "confirm"],
        "bounds": ["x": 10, "y": 20, "width": 80, "height": 24], "available_actions": ["Click"], "ref_id": "@snapshot:e1"]

    func snapshot(_ nodes: [JSONValue], complete: Bool = true) -> JSONValue {
        ["version": "2.6", "ok": true, "command": "snapshot", "data": ["complete": .bool(complete),
            "snapshot_id": "snapshot", "tree": ["role": "sheet", "children": .array(nodes)]]]
    }

    func changed(_ node: JSONValue, _ key: String, _ value: JSONValue) -> JSONValue {
        var object = node.objectValue!; object[key] = value; return .object(object)
    }

    @Test func matchesTheReviewedButtonUsingAFreshQualifiedReference() throws {
        let other = changed(button, "bounds", ["x": 110, "y": 20, "width": 80, "height": 24])
        #expect(try AgentDesktopClient.reference(in: snapshot([other, button]), target: target, label: "OK") == "@snapshot:e1")
    }

    @Test func incompleteTreesAndAmbiguousButtonsAreNeverActionable() {
        for envelope in [snapshot([button], complete: false), snapshot([button, button]),
                         snapshot([changed(button, "subtree_truncated", true)])] {
            #expect(throws: HelperFailure.self) { try AgentDesktopClient.reference(in: envelope, target: target, label: "OK") }
        }
    }

    @Test func changedIdentityDisabledButtonsAndUnqualifiedRefsAreRefused() {
        let invalid = [changed(button, "native_id", ["kind": "ax_identifier", "value": "different"]),
            changed(button, "name", "Allow"), changed(button, "states", ["disabled"]),
            changed(button, "ref_id", "@e1"), changed(button, "ref_id", "@other:e1"),
            changed(button, "available_actions", []), changed(button, "bounds", .null)]
        for node in invalid {
            #expect(throws: HelperFailure.self) { try AgentDesktopClient.reference(in: snapshot([node]), target: target, label: "OK") }
        }
    }

    @Test func onlyProvenUndeliveredStaleErrorsReturnToHumanReview() {
        for (delivery, retry, expected) in [("not_delivered", "safe", HelperFailure.Code.notFound),
                                           ("delivered_unverified", "unsafe", .unsupported), ("unknown", "safe", .unsupported)] {
            let envelope: JSONValue = ["version": "2.6", "ok": false, "command": "click", "error": ["code": "STALE_REF",
                "disposition": ["delivery": .string(delivery), "retry": .string(retry)]]]
            do {
                _ = try AgentDesktopClient.result(envelope, command: "click")
                Issue.record("An error envelope was accepted")
            } catch let failure as HelperFailure { #expect(failure.code == expected) }
            catch { Issue.record("Unexpected error: \(error)") }
        }
    }

    @Test func deliveryAloneDoesNotVerifyDialogDismissal() throws {
        let data = try AgentDesktopClient.result(["version": "2.6", "ok": true, "command": "click",
            "data": ["disposition": ["delivery": "delivered_unverified", "retry": "unsafe"]]], command: "click")
        #expect(data["disposition"]?["delivery"] == "delivered_unverified")
        #expect(data["verified"] == nil)
    }

    @Test func cancellationStopsAChildWithoutSendingAnotherCommand() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("agent-desktop")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = AgentDesktopClient(executable: executable)
        let start = ContinuousClock.now
        let task = Task { try await client.snapshot(app: "Finder", surface: "window", windowID: nil) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(3))
    }
}
