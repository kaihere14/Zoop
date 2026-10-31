import Foundation

/// Filesystem locations shared by the app (main user) and the helper (agent user).
///
/// Defaults match the README layout. Environment variables override them:
/// `ZOOP_SHARED_ROOT` moves the whole shared folder, `ZOOP_SOCKET` moves only the socket.
public enum ZoopPaths {
    public static let defaultSharedRoot = "/Users/Shared/Zoop"

    public static func sharedRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment["ZOOP_SHARED_ROOT"] ?? defaultSharedRoot
    }

    /// Runtime files: the helper socket and the helper log.
    public static func runDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        sharedRoot(environment: environment) + "/run"
    }

    public static func helperSocket(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment["ZOOP_SOCKET"] ?? runDirectory(environment: environment) + "/helper.sock"
    }
}
