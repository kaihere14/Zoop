import Foundation

// Typed messages exchanged between the app (client) and ZoopHelper (server).
//
// Every request travels inside a `RequestEnvelope` with a unique `id`. The helper answers
// with a `ResponseEnvelope` carrying the same `id`, so several requests can be in flight on
// one socket and replies may come back in any order. A response with `id == 0` is a
// connection-level failure (for example "your UID is not allowed") that is not tied to
// any request.

public enum ZoopProtocol {
    /// Bump when a change would make an old app and a new helper (or the reverse)
    /// misunderstand each other. Both sides refuse to talk across a mismatch.
    /// v2: input actions, element queries, app launching, point size in capture metadata.
    /// v3: explicit AX page-scroll action and axScrollPage report method.
    public static let version = 3
}

// MARK: - Payload types

/// macOS privacy permissions as seen from inside the agent session.
/// TCC grants are per user, so these describe the agent user, not the main user.
public struct Permissions: Codable, Sendable, Equatable {
    /// Screen & System Audio Recording: needed for screenshots.
    public var screenCapture: Bool
    /// Accessibility: needed to find and press controls.
    public var accessibility: Bool
    /// "Send input events" (PostEvent): needed for keystrokes. Missing it drops keys silently.
    public var postEvent: Bool

    public init(screenCapture: Bool, accessibility: Bool, postEvent: Bool) {
        self.screenCapture = screenCapture
        self.accessibility = accessibility
        self.postEvent = postEvent
    }
}

public struct SessionInfo: Codable, Sendable, Equatable {
    public var uid: Int
    public var user: String
    /// Process ID of the helper.
    public var pid: Int
    /// True when the agent session is the one shown on the physical screen.
    public var onConsole: Bool
    public var permissions: Permissions
    /// Main display size in points.
    public var displayWidth: Int
    public var displayHeight: Int

    public init(uid: Int, user: String, pid: Int, onConsole: Bool, permissions: Permissions,
                displayWidth: Int, displayHeight: Int) {
        self.uid = uid
        self.user = user
        self.pid = pid
        self.onConsole = onConsole
        self.permissions = permissions
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
    }
}

public struct ClientHello: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var clientName: String

    public init(protocolVersion: Int, clientName: String) {
        self.protocolVersion = protocolVersion
        self.clientName = clientName
    }
}

public struct HelperHello: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var helperVersion: String
    public var session: SessionInfo

    public init(protocolVersion: Int, helperVersion: String, session: SessionInfo) {
        self.protocolVersion = protocolVersion
        self.helperVersion = helperVersion
        self.session = session
    }
}

public struct CaptureOptions: Codable, Sendable, Equatable {
    /// Downscale so the image is at most this many pixels wide. `nil` keeps native resolution.
    /// The live preview uses a small value; the executor uses full resolution.
    public var maxPixelWidth: Int?
    public var showsCursor: Bool

    public init(maxPixelWidth: Int? = nil, showsCursor: Bool = true) {
        self.maxPixelWidth = maxPixelWidth
        self.showsCursor = showsCursor
    }
}

public struct CaptureMetadata: Codable, Sendable, Equatable {
    /// Image size in pixels.
    public var width: Int
    public var height: Int
    public var format: String
    /// Size of the captured display in points: the coordinate space input actions use.
    public var pointWidth: Double
    public var pointHeight: Double

    public init(width: Int, height: Int, format: String = "png", pointWidth: Double, pointHeight: Double) {
        self.width = width
        self.height = height
        self.format = format
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
    }

    /// Converts a position in this image (pixels) to display points for an input action.
    /// The AI reads coordinates off the screenshot; the helper needs them in points.
    public func point(fromPixelX x: Double, y: Double) -> Point {
        Point(x: x * pointWidth / Double(max(width, 1)), y: y * pointHeight / Double(max(height, 1)))
    }
}

// MARK: - Requests and results

public enum HelperRequest: Codable, Sendable, Equatable {
    /// Must be the first request on every connection. The helper always answers with its own
    /// hello, even when the versions differ, so the client can report both versions. On a
    /// mismatch the helper then closes the connection.
    case hello(client: ClientHello)
    case ping
    case info
    case capture(options: CaptureOptions)
    /// The element at a point and its ancestors, innermost first. Read-only.
    case inspect(point: Point)
    /// Interactive elements of one app, from its accessibility tree. Read-only.
    case elements(query: ElementQuery)
    /// Launch an app (or bring it forward) in the agent session.
    case openApp(bundleID: String)
    /// Click, type, key combo, set text, wheel scroll or AX page scroll in the agent session.
    case input(action: InputAction)

    public var name: String {
        switch self {
        case .hello: "hello"
        case .ping: "ping"
        case .info: "info"
        case .capture: "capture"
        case .inspect: "inspect"
        case .elements: "elements"
        case .openApp: "openApp"
        case .input(let action): action.name
        }
    }

    /// Whether the client may send this request again after the connection dropped while
    /// it was in flight.
    ///
    /// Only read-only commands qualify: running them twice cannot change the agent session.
    /// Commands that act (click, type) must never be replayed automatically. The first copy
    /// may already have run before the drop, and a second copy would press the button twice.
    public var isReplayable: Bool {
        switch self {
        case .hello, .ping, .info, .capture, .inspect, .elements: true
        case .openApp, .input: false
        }
    }
}

public enum HelperResult: Codable, Sendable, Equatable {
    case hello(helper: HelperHello)
    case pong
    case info(session: SessionInfo)
    /// The PNG bytes travel as the frame's binary payload, not inside the JSON.
    case capture(frame: CaptureMetadata)
    case elements(list: [ElementInfo])
    case app(info: AppInfo)
    case action(report: ActionReport)
}

/// A failure reported by the helper itself.
public struct HelperFailure: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public enum Code: String, Codable, Sendable {
        /// The connecting user's UID is not on the helper's allow list.
        case unauthorized
        /// A command arrived before `hello`.
        case handshakeRequired
        /// A macOS permission the command needs is not granted in the agent session.
        case permissionDenied
        /// The request could not be decoded or is not supported.
        case badRequest
        /// No element, app or window matched (for example nothing at the clicked point).
        case notFound
        /// The target can't do what was asked (for example set-text on a read-only element).
        case unsupported
        case internalError
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(code.rawValue): \(message)" }
}

// MARK: - Envelopes

public struct RequestEnvelope: Codable, Sendable, Equatable {
    public var id: UInt64
    public var request: HelperRequest

    public init(id: UInt64, request: HelperRequest) {
        self.id = id
        self.request = request
    }
}

public struct ResponseEnvelope: Codable, Sendable, Equatable {
    /// Matches the request's `id`. `0` means a connection-level failure.
    public var id: UInt64
    /// Exactly one of `result` and `failure` is set.
    public var result: HelperResult?
    public var failure: HelperFailure?

    public init(id: UInt64, result: HelperResult) {
        self.id = id
        self.result = result
        self.failure = nil
    }

    public init(id: UInt64, failure: HelperFailure) {
        self.id = id
        self.result = nil
        self.failure = failure
    }
}

/// Decodes only the `id` of an envelope. The server uses it to address an error reply when
/// the rest of a request is unreadable (for example a command from a newer client).
public struct EnvelopeID: Decodable, Sendable {
    public var id: UInt64
}

/// JSON encoding used for frame headers.
public enum WireCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
