import CoreGraphics
import Foundation
import ZoopShared

/// The real backend: answers requests from macOS, inside the agent session.
struct SystemBackend: HelperBackend {
    private let actions = SessionActions()

    func inspect(_ point: Point) async throws -> [ElementInfo] { try await actions.inspect(point) }
    func elements(_ query: ElementQuery) async throws -> [ElementInfo] { try await actions.elements(query) }
    func openApp(_ bundleID: String) async throws -> AppInfo { try await actions.openApp(bundleID) }
    func perform(_ action: InputAction) async throws -> ActionReport { try await actions.perform(action) }

    func sessionInfo() async -> SessionInfo {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let bounds = CGDisplayBounds(CGMainDisplayID())
        return SessionInfo(uid: Int(getuid()),
                           user: NSUserName(),
                           pid: Int(getpid()),
                           onConsole: session?[kCGSessionOnConsoleKey] as? Bool ?? false,
                           permissions: PermissionStatus.current(),
                           displayWidth: Int(bounds.width),
                           displayHeight: Int(bounds.height))
    }

    func capture(_ options: CaptureOptions) async throws -> (CaptureMetadata, Data) {
        try await ScreenCapture.capturePNG(options)
    }
}
