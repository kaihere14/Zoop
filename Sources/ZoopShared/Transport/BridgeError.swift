import Darwin
import Foundation

/// Everything that can go wrong between the app and the helper.
///
/// The important split is `isRetryable`. Some failures go away on their own (the helper is
/// restarting), so retrying helps. Others never fix themselves (the helper rejects our UID,
/// versions differ), so retrying only delays the error the user needs to see.
public enum BridgeError: Error, Sendable, Equatable {
    /// No helper to talk to: the socket file is missing or nobody listens on it.
    case helperUnavailable(String)
    /// Connected, but the helper did not complete the hello exchange.
    case handshakeFailed(String)
    /// An established connection dropped.
    case connectionLost(String)
    /// A request that changes the agent session was in flight when the connection dropped.
    /// It may or may not have run, so it is not replayed. The caller decides what to do.
    case interrupted(command: String)
    case timedOut(command: String, seconds: Double)
    /// The helper refused this user, or the socket path is not accessible to it.
    case unauthorized(String)
    case versionMismatch(client: Int, helper: Int)
    /// Bad local setup, such as a socket path that is too long.
    case invalidConfiguration(String)
    /// The helper ran the command and reported a failure, for example a missing permission.
    case helperFailure(HelperFailure)
    /// Every connection attempt failed with a retryable error.
    indirect case retriesExhausted(attempts: Int, last: BridgeError)
    /// `disconnect()` was called.
    case closed

    /// Whether another connection attempt could succeed.
    public var isRetryable: Bool {
        switch self {
        case .helperUnavailable, .handshakeFailed, .connectionLost, .timedOut:
            true
        case .interrupted, .unauthorized, .versionMismatch, .invalidConfiguration,
             .helperFailure, .retriesExhausted, .closed:
            false
        }
    }

    /// Classifies a failed `connect()`.
    init(connecting error: SocketError, path: String) {
        switch error.code {
        case ENOENT:
            self = .helperUnavailable("no socket at \(path): the agent session is not running or the helper has not started")
        case ECONNREFUSED:
            self = .helperUnavailable("nothing is listening on \(path): the helper is restarting or has crashed")
        case EACCES, EPERM:
            self = .unauthorized("no permission to open \(path)")
        case ENAMETOOLONG:
            self = .invalidConfiguration(error.description)
        default:
            self = .helperUnavailable(error.description)
        }
    }

    /// Text to show the person using Zoop: what happened and what to do about it.
    public var userMessage: String {
        switch self {
        case .helperUnavailable:
            "Zoop can't reach the agent session. Make sure the agent user is logged in (switch to it once with Fast User Switching) and that ZoopHelper is installed."
        case .handshakeFailed, .connectionLost:
            "The connection to the agent session was lost."
        case .interrupted(let command):
            "The connection dropped while '\(command)' was running, so it may or may not have happened."
        case .timedOut(let command, let seconds):
            "The agent session did not answer '\(command)' within \(Self.format(seconds)) s."
        case .unauthorized:
            "The helper refused this user. Reinstall ZoopHelper so that it allows user ID \(getuid())."
        case .versionMismatch(let client, let helper):
            "Zoop (protocol v\(client)) and ZoopHelper (protocol v\(helper)) are different versions. Rebuild and reinstall the helper."
        case .invalidConfiguration(let detail):
            "Zoop is misconfigured: \(detail)."
        case .helperFailure(let failure):
            failure.code == .permissionDenied ? failure.message : "The helper reported an error: \(failure.message)"
        case .retriesExhausted(let attempts, let last):
            "Couldn't connect after \(attempts) attempts. \(last.userMessage)"
        case .closed:
            "The connection to the agent session was closed."
        }
    }

    private static func format(_ seconds: Double) -> String {
        String(format: seconds < 10 ? "%.1f" : "%.0f", seconds)
    }
}

extension BridgeError: CustomStringConvertible {
    /// Technical detail for logs.
    public var description: String {
        switch self {
        case .helperUnavailable(let detail): "helper unavailable: \(detail)"
        case .handshakeFailed(let detail): "handshake failed: \(detail)"
        case .connectionLost(let detail): "connection lost: \(detail)"
        case .interrupted(let command): "'\(command)' interrupted by a dropped connection"
        case .timedOut(let command, let seconds): "'\(command)' timed out after \(seconds)s"
        case .unauthorized(let detail): "unauthorized: \(detail)"
        case .versionMismatch(let client, let helper): "protocol mismatch: client v\(client), helper v\(helper)"
        case .invalidConfiguration(let detail): "invalid configuration: \(detail)"
        case .helperFailure(let failure): "helper failure: \(failure)"
        case .retriesExhausted(let attempts, let last): "gave up after \(attempts) attempts; last error: \(last)"
        case .closed: "connection closed by client"
        }
    }
}
