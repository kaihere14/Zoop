import AppKit
import ZoopShared

/// Saves an app's front document with its AppleScript `save … in` command. This bypasses a
/// Save sheet whose controls ignore synthetic input (its name field lives in a separate
/// system process, so posted keys never reach it and a direct AXValue write leaves Save disabled).
///
/// Apple events need the agent user's Automation consent. macOS shows that consent dialog itself;
/// the helper never waits on it while holding the action gate. It returns a `permissionDenied`
/// failure instead, and Zoop's permission scan shows the dialog to the person.
enum DocumentSaver {
    static func save(_ action: SaveDocumentAction) async throws -> ActionReport {
        let url = try destination(action.path)
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: action.bundleID).first, !app.isTerminated else {
            throw HelperFailure(.notFound, "\(action.bundleID) is not running in the agent session. Open it and its document first.")
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isFolder), isFolder.boolValue else {
            throw HelperFailure(.notFound, "the folder \(url.deletingLastPathComponent().path) does not exist")
        }
        if FileManager.default.fileExists(atPath: url.path), !action.overwrite {
            throw HelperFailure(.unsupported, "\(url.path) already exists. Ask the person before replacing it, then pass overwrite true.")
        }
        try await requireAutomation(action.bundleID, name: app.localizedName ?? action.bundleID)
        try await requireFolderAccess(url.deletingLastPathComponent())

        let before = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        // The client gives an action 10 seconds; stop the Apple event before that.
        let source = """
        with timeout of 8 seconds
            tell application id "\(escape(action.bundleID))"
                if (count of documents) is 0 then error "No document is open." number 1
                save front document in (POSIX file "\(escape(url.path))")
            end tell
        end timeout
        """
        let failure: String? = await MainActor.run {
            var error: NSDictionary?
            guard let script = NSAppleScript(source: source) else { return "could not build the save command" }
            script.executeAndReturnError(&error)
            return error.map { ($0[NSAppleScript.errorMessage] as? String) ?? "\($0)" }
        }
        if let failure {
            throw HelperFailure(.unsupported, "\(app.localizedName ?? action.bundleID) refused the scripted save: \(failure)")
        }
        let after = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        let written = after != nil && after != before
        return ActionReport(action: "saveDocument", method: .appleEvent, pid: Int(app.processIdentifier), app: action.bundleID,
                            landed: written,
                            detail: written ? "Saved the front document to \(url.path); the file exists on disk."
                                            : "The app accepted the save command, but \(url.path) was not written or did not change.")
    }

    /// Resolves `~/` against the agent user's home and keeps the file inside it.
    static func destination(_ path: String, home: String = NSHomeDirectory()) throws -> URL {
        let expanded = path.hasPrefix("~/") ? home + path.dropFirst(1) : path
        guard expanded.hasPrefix("/") else { throw HelperFailure(.badRequest, "path must be absolute or start with ~/") }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let root = URL(fileURLWithPath: home).standardizedFileURL.path + "/"
        guard url.path.hasPrefix(root), !url.lastPathComponent.isEmpty else {
            throw HelperFailure(.badRequest, "path must be a file inside the agent user's home folder (\(home))")
        }
        return url
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func requireAutomation(_ bundleID: String, name: String) async throws {
        switch automationStatus(bundleID, ask: false) {
        case noErr: return
        case OSStatus(errAEEventWouldRequireUserConsent):
            // Asking blocks until the person answers, so ask on a background thread and stop
            // waiting after two seconds. The caller holds the helper's action gate, and pressing
            // the consent button needs that gate, so this must never wait for the answer itself.
            // (A task group cannot be used: it waits for every child, which deadlocked here.)
            let asked = await firstResult(within: .seconds(2)) { automationStatus(bundleID, ask: true) }
            if asked == noErr { return }
            if asked == nil {
                throw HelperFailure(.consentPending, "macOS is asking whether ZoopHelper may control \(name) (Automation). Nothing was saved yet.")
            }
            throw denied(name)
        case OSStatus(errAEEventNotPermitted): throw denied(name)
        case let status:
            throw HelperFailure(.unsupported, "could not check Automation permission for \(name) (status \(status)). Make sure the app is open.")
        }
    }

    /// A sandboxed app such as TextEdit can only write where the helper itself may grant it access,
    /// so the helper needs the destination folder first. For ~/Documents, ~/Desktop and ~/Downloads,
    /// macOS asks once ("ZoopHelper would like to access files in your Documents folder"); the
    /// file access blocks until answered. Ask on a background thread and return without waiting,
    /// so the action gate is free for the person's answer to be pressed. Without this the save
    /// failed with "sandbox_extension_issue_file … Operation not permitted" and deadlocked.
    private static func requireFolderAccess(_ folder: URL) async throws {
        let path = folder.path
        let result = await firstResult(within: .seconds(2)) {
            (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil ? noErr : OSStatus(EPERM)
        }
        switch result {
        case noErr?: return
        case nil:
            throw HelperFailure(.consentPending, "macOS is asking whether ZoopHelper may access \(folder.lastPathComponent). Nothing was saved yet.")
        default:
            throw HelperFailure(.permissionDenied, "ZoopHelper may not access \(path) in the agent session. Allow it in System Settings > Privacy & Security > Files and Folders > ZoopHelper.")
        }
    }

    /// Runs `work` on a background thread and returns its result, or nil if it has not finished
    /// within `limit`. The work keeps running after a timeout; its result is then discarded.
    static func firstResult(within limit: Duration, _ work: @escaping @Sendable () -> OSStatus) async -> OSStatus? {
        let once = OneShot()
        return await withCheckedContinuation { continuation in
            once.set(continuation)
            DispatchQueue.global().async { once.resume(work()) }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(limit.components.seconds * 1000
                + limit.components.attoseconds / 1_000_000_000_000_000))) { once.resume(nil) }
        }
    }

    private static func denied(_ name: String) -> HelperFailure {
        HelperFailure(.permissionDenied, "Automation permission to control \(name) is denied in the agent session. Allow it in System Settings > Privacy & Security > Automation > ZoopHelper.")
    }

    private static func automationStatus(_ bundleID: String, ask: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let descriptor = target.aeDesc else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, ask)
    }
}

/// Resumes a continuation exactly once, from whichever thread finishes first.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OSStatus?, Never>?
    func set(_ continuation: CheckedContinuation<OSStatus?, Never>) { lock.withLock { self.continuation = continuation } }
    func resume(_ value: OSStatus?) {
        let pending = lock.withLock { () -> CheckedContinuation<OSStatus?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
