import CoreGraphics
import Foundation
import ZoopShared

/// The real backend: answers requests from macOS, inside the agent session.
struct SystemBackend: HelperBackend {
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
