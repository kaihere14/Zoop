import AppKit
import ZoopShared

// ZoopHelper: runs inside the agent user's GUI session, started by launchd from the
// LaunchAgent in Resources/LaunchAgents. Serves the session bridge socket.
//
//   ZoopHelper [--socket PATH] [--allow-uid UID]...
//
// Allowed UIDs come from --allow-uid (repeatable) and ZOOP_ALLOWED_UIDS (comma-separated).
// The helper's own UID is always allowed, so the agent user can test locally.

let helperVersion = "0.1.0"

func parseArguments() -> (socketPath: String, allowedUIDs: Set<uid_t>) {
    let environment = ProcessInfo.processInfo.environment
    var socketPath = ZoopPaths.helperSocket(environment: environment)
    var uids = Set((environment["ZOOP_ALLOWED_UIDS"] ?? "").split(separator: ",").compactMap {
        uid_t($0.trimmingCharacters(in: .whitespaces))
    })

    var arguments = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = arguments.next() {
        switch argument {
        case "--socket":
            if let value = arguments.next() { socketPath = value }
        case "--allow-uid":
            if let value = arguments.next(), let uid = uid_t(value) { uids.insert(uid) }
        default:
            helperLog("ignoring unknown argument '\(argument)'")
        }
    }
    uids.insert(getuid())
    return (socketPath, uids)
}

let (socketPath, allowedUIDs) = parseArguments()
if allowedUIDs == [getuid()] {
    helperLog("warning: only uid \(getuid()) may connect; pass --allow-uid <main user uid> or set ZOOP_ALLOWED_UIDS")
}

let server = HelperServer(
    configuration: .init(socketPath: socketPath, allowedUIDs: allowedUIDs, helperVersion: helperVersion),
    backend: SystemBackend())
do {
    try server.start()
} catch {
    helperLog("cannot start: \(error)")
    exit(1)
}

let permissions = PermissionStatus.current()
helperLog("ZoopHelper \(helperVersion) as \(NSUserName()) (uid \(getuid())); screenCapture=\(permissions.screenCapture) accessibility=\(permissions.accessibility) postEvent=\(permissions.postEvent)")
PermissionStatus.requestMissing()

// launchd stops the job with SIGTERM. Clean up the socket file so the next start is clean.
signal(SIGTERM, SIG_IGN)
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminationSource.setEventHandler {
    server.stop()
    exit(0)
}
terminationSource.resume()

// An accessory app has no Dock icon or menu bar, but gets a run loop and a WindowServer
// connection. ScreenCaptureKit and the permission prompts need both.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
