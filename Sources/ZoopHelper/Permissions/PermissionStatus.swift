import ApplicationServices
import CoreGraphics
import ZoopShared

/// Privacy permissions of this helper, inside the agent user's session.
///
/// TCC grants are per user and tied to the app's code signature, so these only become true
/// after someone approves ZoopHelper while logged in as the agent user. The values travel
/// to the app in every hello. A missing permission then shows up as soon as the app
/// connects, not as a silent failure halfway through a task.
enum PermissionStatus {
    static func current() -> Permissions {
        Permissions(screenCapture: CGPreflightScreenCaptureAccess(),
                    accessibility: AXIsProcessTrusted(),
                    postEvent: CGPreflightPostEventAccess())
    }

    /// Shows the system prompt for each missing permission. macOS only shows these while the
    /// agent session is on screen, so start the helper there once (see Docs/SessionBridge.md).
    ///
    /// All three are requested now, even though only capture uses them today. A permission
    /// that was never requested stays off with no error. In the prototype, that is why
    /// keystrokes were silently dropped (missing PostEvent).
    static func requestMissing() {
        if !CGPreflightScreenCaptureAccess() {
            helperLog("Screen Recording not granted; requesting it")
            _ = CGRequestScreenCaptureAccess()
        }
        if !AXIsProcessTrusted() {
            helperLog("Accessibility not granted; requesting it")
            // Literal value of kAXTrustedCheckOptionPrompt (the global is not concurrency-safe in Swift 6).
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        if !CGPreflightPostEventAccess() {
            helperLog("PostEvent (send input events) not granted; requesting it")
            _ = CGRequestPostEventAccess()
        }
    }
}
