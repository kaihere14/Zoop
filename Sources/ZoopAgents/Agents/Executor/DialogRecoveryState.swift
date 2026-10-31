import ZoopShared

/// Evidence for the final, human-assisted dialog fallback. Unconfirmed clicks are
/// observed between model responses; the helper cannot replace either earlier strategy.
struct DialogRecoveryState: Sendable {
    private var axApps: Set<String> = []
    private var mouseApps: Set<String> = []

    func canRequestHelp(in app: String) -> Bool { axApps.contains(app) && mouseApps.contains(app) }
    mutating func clear(_ app: String) { axApps.remove(app); mouseApps.remove(app) }

    mutating func record(name: String, arguments: JSONValue?, result: ToolResult) {
        if name == "batch", case .array(let actions)? = arguments?["actions"],
           case .array(let entries)? = result.content["results"], let last = entries.last,
           !entries.isEmpty, actions.indices.contains(entries.count - 1) {
            let action = actions[entries.count - 1]
            var fields = last.objectValue ?? [:]
            fields["requires_observation"] = result.content["requires_observation"]
            record(name: action["tool"]?.stringValue ?? "", arguments: action,
                   result: ToolResult(tool: last["tool"]?.stringValue ?? "", isError: result.isError, content: .object(fields)))
            return
        }
        guard name == "click", let app = arguments?["bundle_id"]?.stringValue ?? result.content["app"]?.stringValue else { return }
        if result.content["verified"] == true { clear(app); return }
        guard result.requiresObservation else { return }
        if arguments?["strategy"] == "mouse" { mouseApps.insert(app) }
        else { axApps.insert(app) }
    }
}
