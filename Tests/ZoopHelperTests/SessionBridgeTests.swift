import Darwin
import Foundation
import Testing
@testable import ZoopHelper
@testable import ZoopShared

// End-to-end tests of the session bridge: a real HelperServer and a real HelperConnection
// talking over a real Unix socket in /tmp. Only the backend (screen capture, session facts)
// is faked, so these run without a second macOS user.

// MARK: - Fixtures

struct FakeBackend: HelperBackend {
    var captureDelay: Duration = .zero
    var captureFailure: HelperFailure?
    var png = Data((0..<3_000_000).map { UInt8($0 % 251) })   // ~3 MB, spans many socket reads

    static let session = SessionInfo(uid: Int(getuid()), user: "fake-agent", pid: 1234, onConsole: false,
                                     permissions: Permissions(screenCapture: true, accessibility: true, postEvent: false),
                                     displayWidth: 1470, displayHeight: 956)

    func sessionInfo() async -> SessionInfo { Self.session }

    func capture(_ options: CaptureOptions) async throws -> (CaptureMetadata, Data) {
        try await Task.sleep(for: captureDelay)
        if let captureFailure { throw captureFailure }
        return (CaptureMetadata(width: 100, height: 50), png)
    }
}

/// Short path: sockaddr_un only holds 104 bytes, so the test bundle's temp dir is too long.
func temporarySocketPath() -> String {
    "/tmp/zoop-test-\(UUID().uuidString.prefix(8)).sock"
}

func startServer(at path: String, allowed: Set<uid_t> = [getuid()], backend: FakeBackend = FakeBackend()) throws -> HelperServer {
    let server = HelperServer(configuration: .init(socketPath: path, allowedUIDs: allowed, helperVersion: "test"),
                              backend: backend)
    try server.start()
    return server
}

/// Fast retries and no heartbeat unless a test turns it on.
func testConfiguration(_ path: String, retries: Int = 3, delay: Duration = .milliseconds(20)) -> HelperConnection.Configuration {
    .init(socketPath: path, clientName: "tests",
          retry: RetryPolicy(maxRetries: retries, initialDelay: delay, multiplier: 2, maxDelay: .seconds(1), jitter: 0),
          handshakeTimeout: .seconds(2), heartbeatInterval: nil)
}

/// Collects every state a connection reports.
final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HelperConnection.State] = []
    private var task: Task<Void, Never>?

    static func attach(to connection: HelperConnection) async -> StateRecorder {
        let recorder = StateRecorder()
        let stream = await connection.stateUpdates()
        recorder.task = Task { for await state in stream { recorder.lock.withLock { recorder.recorded.append(state) } } }
        return recorder
    }

    var states: [HelperConnection.State] { lock.withLock { recorded } }

    func count(where predicate: (HelperConnection.State) -> Bool) -> Int { states.filter(predicate).count }

    /// Waits until a recorded state matches, because the stream delivers asynchronously.
    func waitFor(timeout: Duration = .seconds(3), _ predicate: (HelperConnection.State) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if states.contains(where: predicate) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    deinit { task?.cancel() }
}

func isConnecting(_ state: HelperConnection.State) -> Bool { if case .connecting = state { true } else { false } }
func isConnected(_ state: HelperConnection.State) -> Bool { if case .connected = state { true } else { false } }
func isWaiting(_ state: HelperConnection.State) -> Bool { if case .waitingToRetry = state { true } else { false } }
func isFailed(_ state: HelperConnection.State) -> Bool { if case .failed = state { true } else { false } }

// MARK: - Tests

@Suite(.serialized) struct SessionBridgeTests {

    @Test func connectsAndServesCommands() async throws {
        let path = temporarySocketPath()
        let server = try startServer(at: path)
        defer { server.stop() }
        let connection = HelperConnection(configuration: testConfiguration(path))

        let hello = try await connection.connect()
        #expect(hello.protocolVersion == ZoopProtocol.version)
        #expect(hello.session == FakeBackend.session)

        _ = try await connection.ping()
        #expect(try await connection.sessionInfo() == FakeBackend.session)

        let frame = try await connection.capture()
        #expect(frame.metadata == CaptureMetadata(width: 100, height: 50))
        #expect(frame.png == FakeBackend().png)
        await connection.disconnect()
    }

    @Test func givesUpAfterThreeRetries() async throws {
        let path = temporarySocketPath()   // nothing listens here
        let connection = HelperConnection(configuration: testConfiguration(path))
        let recorder = await StateRecorder.attach(to: connection)

        await #expect {
            try await connection.connect()
        } throws: { error in
            guard case .retriesExhausted(4, .helperUnavailable) = error as? BridgeError else { return false }
            return true
        }
        #expect(await recorder.waitFor(isFailed))
        #expect(recorder.count(where: isConnecting) == 4)   // first try + 3 retries
        #expect(recorder.count(where: isWaiting) == 3)
    }

    @Test func recoversWhenHelperStartsDuringRetries() async throws {
        let path = temporarySocketPath()
        let connection = HelperConnection(configuration: testConfiguration(path, delay: .milliseconds(150)))
        let recorder = await StateRecorder.attach(to: connection)

        // The helper comes up while the client is still retrying, like a launchd restart.
        let starter = Task {
            try await Task.sleep(for: .milliseconds(100))
            return try startServer(at: path)
        }
        let hello = try await connection.connect()
        let server = try await starter.value
        defer { server.stop() }

        #expect(hello.session.user == "fake-agent")
        #expect(recorder.count(where: isWaiting) >= 1)
        await connection.disconnect()
    }

    @Test func unauthorizedUserIsNotRetried() async throws {
        let path = temporarySocketPath()
        let server = try startServer(at: path, allowed: [])   // our uid is not allowed
        defer { server.stop() }
        let connection = HelperConnection(configuration: testConfiguration(path))
        let recorder = await StateRecorder.attach(to: connection)

        await #expect {
            try await connection.connect()
        } throws: { error in
            guard case .unauthorized = error as? BridgeError else { return false }
            return true
        }
        #expect(await recorder.waitFor(isFailed))
        #expect(recorder.count(where: isConnecting) == 1)
    }

    @Test func versionMismatchIsNotRetried() async throws {
        let path = temporarySocketPath()
        let server = try startServer(at: path)
        defer { server.stop() }
        var configuration = testConfiguration(path)
        configuration.protocolVersion = 99
        let connection = HelperConnection(configuration: configuration)
        let recorder = await StateRecorder.attach(to: connection)

        await #expect(throws: BridgeError.versionMismatch(client: 99, helper: ZoopProtocol.version)) {
            try await connection.connect()
        }
        #expect(recorder.count(where: isConnecting) == 1)
    }

    @Test func nextCommandRetriesAfterGivingUp() async throws {
        let path = temporarySocketPath()
        let connection = HelperConnection(configuration: testConfiguration(path, retries: 1))
        await #expect(throws: BridgeError.self) { try await connection.connect() }
        guard case .failed = await connection.state else {
            Issue.record("expected failed state")
            return
        }

        // Nothing retries in the background. The next command starts a fresh cycle.
        let server = try startServer(at: path)
        defer { server.stop() }
        #expect(try await connection.sessionInfo() == FakeBackend.session)
        await connection.disconnect()
    }

    @Test func replaysCaptureAfterHelperRestart() async throws {
        let path = temporarySocketPath()
        let backend = FakeBackend(captureDelay: .milliseconds(400))
        var server = try startServer(at: path, backend: backend)
        let connection = HelperConnection(configuration: testConfiguration(path))
        let recorder = await StateRecorder.attach(to: connection)
        try await connection.connect()

        let capture = Task { try await connection.capture() }
        try await Task.sleep(for: .milliseconds(100))
        // Kill the helper mid-capture and bring up a new one, as launchd's KeepAlive would.
        server.stop()
        server = try startServer(at: path, backend: backend)
        defer { server.stop() }

        let frame = try await capture.value
        #expect(frame.png == backend.png)
        #expect(recorder.count(where: isConnected) == 2)
        await connection.disconnect()
    }

    @Test func slowRequestTimesOutButConnectionSurvives() async throws {
        let path = temporarySocketPath()
        let server = try startServer(at: path, backend: FakeBackend(captureDelay: .seconds(2)))
        defer { server.stop() }
        var configuration = testConfiguration(path)
        configuration.timeouts.capture = .milliseconds(200)
        let connection = HelperConnection(configuration: configuration)

        await #expect(throws: BridgeError.timedOut(command: "capture", seconds: 0.2)) {
            try await connection.capture()
        }
        _ = try await connection.ping()
        await connection.disconnect()
    }

    @Test func pingIsNotBlockedBySlowCapture() async throws {
        let path = temporarySocketPath()
        let server = try startServer(at: path, backend: FakeBackend(captureDelay: .milliseconds(600)))
        defer { server.stop() }
        let connection = HelperConnection(configuration: testConfiguration(path))
        try await connection.connect()

        let capture = Task { try await connection.capture() }
        try await Task.sleep(for: .milliseconds(50))
        let rtt = try await connection.ping()
        #expect(rtt < .milliseconds(300))   // answered while the capture was still running
        _ = try await capture.value
        await connection.disconnect()
    }

    @Test func permissionFailureIsReportedNotRetried() async throws {
        let path = temporarySocketPath()
        let failure = HelperFailure(.permissionDenied, "Screen Recording is not allowed")
        let server = try startServer(at: path, backend: FakeBackend(captureFailure: failure))
        defer { server.stop() }
        let connection = HelperConnection(configuration: testConfiguration(path))

        await #expect(throws: BridgeError.helperFailure(failure)) { try await connection.capture() }
        #expect(BridgeError.helperFailure(failure).userMessage == failure.message)
        await connection.disconnect()
    }

    @Test func heartbeatDetectsUnresponsiveHelper() async throws {
        let path = temporarySocketPath()
        let silent = try SilentHelper(path: path)
        defer { silent.stop() }
        var configuration = testConfiguration(path)
        configuration.heartbeatInterval = .milliseconds(50)
        configuration.heartbeatTimeout = .milliseconds(50)
        configuration.missedHeartbeatLimit = 2
        let connection = HelperConnection(configuration: configuration)
        let recorder = await StateRecorder.attach(to: connection)

        try await connection.connect()
        // The socket stays open, but pings go unanswered. The client must notice on its own
        // and reconnect: connected, then connecting again.
        let reconnected = await recorder.waitFor { _ in
            let states = recorder.states
            guard let first = states.firstIndex(where: isConnected) else { return false }
            return states[(first + 1)...].contains(where: isConnecting)
        }
        #expect(reconnected)
        await connection.disconnect()
    }

    @Test func serverRejectsCommandsBeforeHello() async throws {
        let path = temporarySocketPath()
        let server = try startServer(at: path)
        defer { server.stop() }

        let socket = FramedSocket(fd: try UnixSocket.connect(path: path))
        let (replies, sink) = AsyncStream.makeStream(of: Frame.self)
        socket.startReading(onFrame: { sink.yield($0) }, onClose: { _ in sink.finish() })
        try socket.send(Frame(header: WireCoding.encode(RequestEnvelope(id: 5, request: .ping))))

        var iterator = replies.makeAsyncIterator()
        let frame = try #require(await iterator.next())
        let reply = try WireCoding.decode(ResponseEnvelope.self, from: frame.header)
        #expect(reply.id == 5)
        #expect(reply.failure?.code == .handshakeRequired)
        socket.close()
    }

    @Test func refusesToReplaceARunningHelper() throws {
        let path = temporarySocketPath()
        let server = try startServer(at: path)
        defer { server.stop() }
        #expect(throws: HelperServer.StartError.self) { try startServer(at: path) }
    }
}

/// A fake helper that completes the hello but never answers anything else, like a helper
/// whose request handling has hung while its socket stays open.
final class SilentHelper: @unchecked Sendable {
    private let path: String
    private let listenFD: Int32
    private let lock = NSLock()
    private var running = true
    private var sockets: [FramedSocket] = []

    init(path: String) throws {
        self.path = path
        listenFD = try UnixSocket.listen(path: path)
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    private func acceptLoop() {
        while lock.withLock({ running }) {
            guard let fd = try? UnixSocket.accept(listenFD) else {
                usleep(5_000)
                continue
            }
            let socket = FramedSocket(fd: fd)
            lock.withLock { sockets.append(socket) }
            socket.startReading(onFrame: { frame in
                guard let envelope = try? WireCoding.decode(RequestEnvelope.self, from: frame.header),
                      case .hello = envelope.request else { return }
                let hello = HelperHello(protocolVersion: ZoopProtocol.version, helperVersion: "silent", session: FakeBackend.session)
                if let header = try? WireCoding.encode(ResponseEnvelope(id: envelope.id, result: .hello(helper: hello))) {
                    try? socket.send(Frame(header: header))
                }
            }, onClose: { _ in })
        }
    }

    func stop() {
        let open = lock.withLock { () -> [FramedSocket] in
            running = false
            return sockets
        }
        open.forEach { $0.close() }
        close(listenFD)
        unlink(path)
    }
}
