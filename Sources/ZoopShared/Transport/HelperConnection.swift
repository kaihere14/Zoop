import Foundation
import os

/// The app's side of the session bridge: one long-lived connection to ZoopHelper running in
/// the agent user's session.
///
/// What it takes care of so callers don't have to:
/// - **Connecting lazily.** The first command connects. Callers never manage sockets.
/// - **Retrying.** A failed connection is retried with exponential backoff (`RetryPolicy`,
///   by default 3 retries, so 4 attempts). Errors that retrying cannot fix fail at once.
/// - **Reporting.** Every state change goes to `stateUpdates()` subscribers, so the UI can
///   show "Reconnecting (2 of 4)" or "Agent session unreachable".
/// - **Retry on demand.** After a failed cycle nothing runs in the background. The next
///   command, or an explicit `connect()` such as a Retry button, starts a fresh cycle.
/// - **Noticing a dead helper.** A heartbeat ping runs while connected. Missing several in a
///   row counts as a lost connection, even when the socket itself still looks open.
/// - **Reconnecting after a drop**, then resending read-only requests that were in flight.
///   Requests that act on the session are failed instead (see `HelperRequest.isReplayable`).
/// - **Multiplexing.** Each request has an id, so the preview's captures and the executor's
///   commands can share the connection without waiting for each other.
///
/// It is an `actor`, so all of this state is only touched by one task at a time.
public actor HelperConnection {

    // MARK: Configuration

    public struct Configuration: Sendable {
        public var socketPath: String
        /// Sent in the hello. Shows up in the helper's log.
        public var clientName: String
        public var retry: RetryPolicy
        public var handshakeTimeout: Duration
        /// Time between heartbeat pings while connected. `nil` turns the heartbeat off.
        public var heartbeatInterval: Duration?
        public var heartbeatTimeout: Duration
        /// Consecutive unanswered heartbeats before the connection counts as dead.
        public var missedHeartbeatLimit: Int
        public var timeouts: RequestTimeouts
        /// Only changed by tests, to simulate an incompatible client.
        var protocolVersion = ZoopProtocol.version

        public init(socketPath: String = ZoopPaths.helperSocket(),
                    clientName: String = "zoop",
                    retry: RetryPolicy = RetryPolicy(),
                    handshakeTimeout: Duration = .seconds(3),
                    heartbeatInterval: Duration? = .seconds(5),
                    heartbeatTimeout: Duration = .seconds(2),
                    missedHeartbeatLimit: Int = 2,
                    timeouts: RequestTimeouts = RequestTimeouts()) {
            self.socketPath = socketPath
            self.clientName = clientName
            self.retry = retry
            self.handshakeTimeout = handshakeTimeout
            self.heartbeatInterval = heartbeatInterval
            self.heartbeatTimeout = heartbeatTimeout
            self.missedHeartbeatLimit = max(1, missedHeartbeatLimit)
            self.timeouts = timeouts
        }
    }

    /// How long each kind of request may take before it fails with `.timedOut`.
    /// A timeout fails only that request. Whether the helper is alive is the heartbeat's job.
    public struct RequestTimeouts: Sendable {
        public var ping: Duration
        public var info: Duration
        public var capture: Duration
        /// inspect and elements. Walking a big accessibility tree can take a few seconds.
        public var query: Duration
        public var openApp: Duration
        public var input: Duration

        public init(ping: Duration = .seconds(2), info: Duration = .seconds(5), capture: Duration = .seconds(15),
                    query: Duration = .seconds(10), openApp: Duration = .seconds(15), input: Duration = .seconds(10)) {
            self.ping = ping
            self.info = info
            self.capture = capture
            self.query = query
            self.openApp = openApp
            self.input = input
        }

        func timeout(for request: HelperRequest) -> Duration {
            switch request {
            case .hello, .ping: ping
            case .info: info
            case .capture: capture
            case .inspect, .elements: query
            case .openApp: openApp
            case .input: input
            }
        }
    }

    // MARK: State

    public enum State: Sendable, Equatable {
        /// Not connected and not trying. The next command connects.
        case disconnected
        /// Connection attempt `attempt` of `of` is in progress.
        case connecting(attempt: Int, of: Int)
        case connected(HelperHello)
        /// The last attempt failed with a retryable error. Attempt `nextAttempt` starts after `delay`.
        case waitingToRetry(nextAttempt: Int, of: Int, delay: Duration, lastError: BridgeError)
        /// Gave up. `BridgeError.userMessage` explains it to the user. The next command retries.
        case failed(BridgeError)
    }

    /// A screenshot from the agent session.
    public struct CapturedFrame: Sendable {
        public var metadata: CaptureMetadata
        public var png: Data
    }

    struct Response: Sendable {
        var result: HelperResult
        var payload: Data
    }

    private enum SocketEvent: Sendable {
        case frame(Frame)
        case closed(SocketCloseReason)
    }

    private struct Pending {
        let command: String
        let generation: Int
        let continuation: CheckedContinuation<Response, Error>
        let timer: Task<Void, Never>
    }

    private enum HeartbeatOutcome {
        case answered, missed, stop
    }

    private let config: Configuration
    private let log = Logger(subsystem: "com.zoop", category: "bridge")

    public private(set) var state: State = .disconnected
    private var socket: FramedSocket?
    /// Increases with every new socket. Callbacks from an older socket carry an older number
    /// and are ignored, so a late "closed" event can never tear down a newer connection.
    private var generation = 0
    private var nextRequestID: UInt64 = 1
    private var pending: [UInt64: Pending] = [:]
    /// The running connect cycle. Everyone who needs a connection awaits this one task
    /// instead of starting their own, so ten callers still mean one cycle.
    private var connectTask: Task<HelperHello, Error>?
    private var connectCycle = 0
    private var heartbeatTask: Task<Void, Never>?
    /// Why we closed the socket ourselves, for the log line when the close is observed.
    private var dropReason: String?
    private var subscribers: [UUID: AsyncStream<State>.Continuation] = [:]

    public init(configuration: Configuration = Configuration()) {
        self.config = configuration
    }

    deinit {
        connectTask?.cancel()
        heartbeatTask?.cancel()
        socket?.close()
        for subscriber in subscribers.values { subscriber.finish() }
    }

    // MARK: Public API

    /// A stream of state changes. It starts with the current state.
    public func stateUpdates() -> AsyncStream<State> {
        let (stream, continuation) = AsyncStream.makeStream(of: State.self, bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        subscribers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    /// Connects if needed and returns the helper's hello. Use this for a Retry button: after
    /// a failure it starts a fresh cycle of attempts.
    @discardableResult
    public func connect() async throws -> HelperHello {
        try await ensureConnected()
    }

    /// Closes the connection and stops any retries. Requests in flight fail with `.closed`.
    public func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        connectCycle += 1
        heartbeatTask?.cancel()
        heartbeatTask = nil
        generation += 1
        for (id, entry) in pending {
            pending[id] = nil
            entry.timer.cancel()
            entry.continuation.resume(throwing: BridgeError.closed)
        }
        socket?.close()
        socket = nil
        setState(.disconnected)
    }

    /// Round trip to the helper, not counting connection setup.
    public func ping() async throws -> Duration {
        try await ensureConnected()
        let clock = ContinuousClock()
        let start = clock.now
        _ = try await request(.ping)
        return clock.now - start
    }

    public func sessionInfo() async throws -> SessionInfo {
        let response = try await request(.info)
        guard case .info(let session) = response.result else { throw Self.unexpectedReply(to: "info") }
        return session
    }

    public func capture(_ options: CaptureOptions = CaptureOptions()) async throws -> CapturedFrame {
        let response = try await request(.capture(options: options))
        guard case .capture(let metadata) = response.result else { throw Self.unexpectedReply(to: "capture") }
        return CapturedFrame(metadata: metadata, png: response.payload)
    }

    /// The element at `point` and its ancestors, innermost first.
    public func inspect(at point: Point) async throws -> [ElementInfo] {
        let response = try await request(.inspect(point: point))
        guard case .elements(let list) = response.result else { throw Self.unexpectedReply(to: "inspect") }
        return list
    }

    /// Interactive elements of a running app, with their frames in display points.
    public func elements(_ query: ElementQuery) async throws -> [ElementInfo] {
        let response = try await request(.elements(query: query))
        guard case .elements(let list) = response.result else { throw Self.unexpectedReply(to: "elements") }
        return list
    }

    public func openApp(bundleID: String) async throws -> AppInfo {
        let response = try await request(.openApp(bundleID: bundleID))
        guard case .app(let info) = response.result else { throw Self.unexpectedReply(to: "openApp") }
        return info
    }

    /// Runs one input action. Never replayed: if the connection drops while it runs, this
    /// throws `.interrupted` because the action may already have happened.
    public func perform(_ action: InputAction) async throws -> ActionReport {
        let response = try await request(.input(action: action))
        guard case .action(let report) = response.result else { throw Self.unexpectedReply(to: action.name) }
        return report
    }

    // MARK: Requests

    /// Sends a request on a working connection, connecting first if needed.
    ///
    /// If the connection drops mid-request, a replayable request waits for the automatic
    /// reconnect and is sent once more. A non-replayable one fails with `.interrupted`.
    func request(_ request: HelperRequest) async throws -> Response {
        let timeout = config.timeouts.timeout(for: request)
        var replaysLeft = request.isReplayable ? 1 : 0
        while true {
            try await ensureConnected()
            do {
                return try await transmit(request, timeout: timeout)
            } catch BridgeError.connectionLost(let reason) {
                guard replaysLeft > 0 else { throw BridgeError.interrupted(command: request.name) }
                replaysLeft -= 1
                log.notice("replaying '\(request.name, privacy: .public)' after connection loss: \(reason, privacy: .public)")
            }
        }
    }

    /// Writes one request on the current socket and waits for the matching reply.
    private func transmit(_ request: HelperRequest, timeout: Duration) async throws -> Response {
        guard let socket else { throw BridgeError.connectionLost("not connected") }
        let id = nextRequestID
        nextRequestID += 1
        let header = try WireCoding.encode(RequestEnvelope(id: id, request: request))
        let generation = self.generation
        let command = request.name

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Response, Error>) in
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.expire(id, after: timeout)
                }
                pending[id] = Pending(command: command, generation: generation, continuation: continuation, timer: timer)
                do {
                    try socket.send(Frame(header: header))
                } catch {
                    // Don't fail the request here. If the peer is gone, the reader sees the
                    // close (after any final message, such as "unauthorized") and fails it
                    // with the real reason. Otherwise the timeout ends it.
                    log.error("write of '\(command, privacy: .public)' failed: \(String(describing: error), privacy: .public)")
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
    }

    private func expire(_ id: UInt64, after timeout: Duration) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        log.error("'\(entry.command, privacy: .public)' timed out after \(timeout.inSeconds)s")
        entry.continuation.resume(throwing: BridgeError.timedOut(command: entry.command, seconds: timeout.inSeconds))
    }

    private func cancelRequest(_ id: UInt64) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timer.cancel()
        entry.continuation.resume(throwing: CancellationError())
    }

    private func failPending(generation: Int, with error: BridgeError) {
        for (id, entry) in pending where entry.generation == generation {
            pending[id] = nil
            entry.timer.cancel()
            entry.continuation.resume(throwing: error)
        }
    }

    private static func unexpectedReply(to command: String) -> BridgeError {
        .helperFailure(HelperFailure(.internalError, "unexpected reply type to '\(command)'"))
    }

    // MARK: Connecting

    @discardableResult
    private func ensureConnected() async throws -> HelperHello {
        if case .connected(let hello) = state, socket != nil { return hello }
        let task = connectTask ?? startConnectCycle()
        return try await task.value
    }

    private func startConnectCycle() -> Task<HelperHello, Error> {
        connectCycle += 1
        let cycle = connectCycle
        let task = Task { try await self.runConnectCycle(cycle) }
        connectTask = task
        return task
    }

    /// One cycle: up to `retry.maxAttempts` attempts with backoff in between.
    private func runConnectCycle(_ cycle: Int) async throws -> HelperHello {
        defer { if connectCycle == cycle { connectTask = nil } }
        let attempts = config.retry.maxAttempts
        var lastError = BridgeError.helperUnavailable("not attempted")

        for attempt in 1...attempts {
            if Task.isCancelled { throw BridgeError.closed }
            setState(.connecting(attempt: attempt, of: attempts))
            do {
                let hello = try await attemptConnection()
                setState(.connected(hello))
                startHeartbeat()
                log.notice("connected to helper \(hello.helperVersion, privacy: .public) as \(hello.session.user, privacy: .public) (attempt \(attempt)/\(attempts))")
                return hello
            } catch {
                lastError = (error as? BridgeError) ?? .connectionLost(String(describing: error))
            }

            // disconnect() was called while this attempt ran.
            if Task.isCancelled || lastError == .closed { throw BridgeError.closed }

            guard lastError.isRetryable else {
                log.error("connection failed, not retrying: \(lastError.description, privacy: .public)")
                setState(.failed(lastError))
                throw lastError
            }
            if attempt < attempts {
                let delay = config.retry.delay(beforeRetry: attempt)
                log.notice("attempt \(attempt)/\(attempts) failed (\(lastError.description, privacy: .public)); retrying in \(delay.inSeconds)s")
                setState(.waitingToRetry(nextAttempt: attempt + 1, of: attempts, delay: delay, lastError: lastError))
                do { try await Task.sleep(for: delay) } catch { throw BridgeError.closed }
            }
        }

        let error = BridgeError.retriesExhausted(attempts: attempts, last: lastError)
        log.error("\(error.description, privacy: .public)")
        setState(.failed(error))
        throw error
    }

    /// One attempt: open the socket, start reading, exchange hellos.
    private func attemptConnection() async throws -> HelperHello {
        let fd: Int32
        do {
            fd = try UnixSocket.connect(path: config.socketPath)
        } catch let error as SocketError {
            throw BridgeError(connecting: error, path: config.socketPath)
        }

        let socket = FramedSocket(fd: fd)
        generation += 1
        let generation = self.generation
        self.socket = socket
        dropReason = nil

        // The reader thread pushes events into this stream; one task drains it in order.
        // Keeping order matters: a final "unauthorized" reply must be handled before the
        // close that follows it.
        let (events, sink) = AsyncStream.makeStream(of: SocketEvent.self)
        socket.startReading(onFrame: { sink.yield(.frame($0)) },
                            onClose: { sink.yield(.closed($0)); sink.finish() })
        Task {
            for await event in events { self.handle(event, generation: generation) }
        }

        let reply: Response
        do {
            let hello = ClientHello(protocolVersion: config.protocolVersion, clientName: config.clientName)
            reply = try await transmit(.hello(client: hello), timeout: config.handshakeTimeout)
        } catch let error as BridgeError {
            socket.close()
            throw Self.handshakeError(error)
        }
        guard case .hello(let hello) = reply.result else {
            socket.close()
            throw BridgeError.handshakeFailed("unexpected reply to hello")
        }
        guard hello.protocolVersion == config.protocolVersion else {
            socket.close()
            throw BridgeError.versionMismatch(client: config.protocolVersion, helper: hello.protocolVersion)
        }
        return hello
    }

    private static func handshakeError(_ error: BridgeError) -> BridgeError {
        switch error {
        case .helperFailure(let failure) where failure.code == .unauthorized:
            .unauthorized(failure.message)
        case .helperFailure(let failure):
            .handshakeFailed(failure.description)
        case .timedOut(_, let seconds):
            .handshakeFailed("no reply to hello within \(seconds)s")
        case .connectionLost(let reason):
            .handshakeFailed(reason)
        default:
            error
        }
    }

    // MARK: Socket events

    private func handle(_ event: SocketEvent, generation: Int) {
        switch event {
        case .frame(let frame): handleFrame(frame, generation: generation)
        case .closed(let reason): connectionClosed(generation: generation, reason: reason)
        }
    }

    private func handleFrame(_ frame: Frame, generation: Int) {
        let envelope: ResponseEnvelope
        do {
            envelope = try WireCoding.decode(ResponseEnvelope.self, from: frame.header)
        } catch {
            // The helper sent something we can't read. Start over on a fresh connection.
            log.error("unreadable reply from helper: \(String(describing: error), privacy: .public)")
            if generation == self.generation {
                dropReason = "unreadable reply from helper"
                socket?.close()
            }
            return
        }

        // id 0: the helper is failing the whole connection, e.g. our UID is not allowed.
        if envelope.id == 0 {
            let failure = envelope.failure ?? HelperFailure(.internalError, "connection rejected without a reason")
            log.error("helper rejected the connection: \(failure.description, privacy: .public)")
            failPending(generation: generation, with: .helperFailure(failure))
            return
        }

        // No entry means the request already timed out or was cancelled. Drop the late reply.
        guard let entry = pending.removeValue(forKey: envelope.id) else { return }
        entry.timer.cancel()
        if let failure = envelope.failure {
            entry.continuation.resume(throwing: BridgeError.helperFailure(failure))
        } else if let result = envelope.result {
            entry.continuation.resume(returning: Response(result: result, payload: frame.payload))
        } else {
            entry.continuation.resume(throwing: BridgeError.helperFailure(HelperFailure(.internalError, "reply without a result")))
        }
    }

    private func connectionClosed(generation: Int, reason: SocketCloseReason) {
        let detail = dropReason ?? (reason == .peerClosed ? "the helper closed the connection" : reason.description)
        failPending(generation: generation, with: .connectionLost(detail))
        guard generation == self.generation else { return }
        socket = nil
        dropReason = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil

        // If the drop happened during the handshake, the running connect cycle already sees
        // it as a failed attempt. Only a drop of an established connection needs a new cycle.
        guard case .connected = state else { return }
        log.notice("connection lost (\(detail, privacy: .public)); reconnecting")
        if connectTask == nil { _ = startConnectCycle() }
    }

    // MARK: Heartbeat

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        guard let interval = config.heartbeatInterval else { return }
        let generation = self.generation
        let limit = config.missedHeartbeatLimit
        heartbeatTask = Task { [weak self] in
            var missed = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self else { return }
                switch await self.sendHeartbeat(generation: generation) {
                case .answered:
                    missed = 0
                case .missed:
                    missed += 1
                    if missed >= limit {
                        await self.dropConnection(generation: generation,
                                                  reason: "helper missed \(missed) heartbeats in a row")
                        return
                    }
                case .stop:
                    return
                }
            }
        }
    }

    private func sendHeartbeat(generation: Int) async -> HeartbeatOutcome {
        guard generation == self.generation, case .connected = state else { return .stop }
        do {
            _ = try await transmit(.ping, timeout: config.heartbeatTimeout)
            return .answered
        } catch BridgeError.timedOut {
            return .missed
        } catch {
            return .stop
        }
    }

    /// Closes the socket ourselves. The reader then reports the close, which triggers the
    /// same reconnect path as a drop caused by the helper.
    private func dropConnection(generation: Int, reason: String) {
        guard generation == self.generation, let socket else { return }
        log.error("dropping connection: \(reason, privacy: .public)")
        dropReason = reason
        socket.close()
    }

    // MARK: Subscribers

    private func setState(_ newState: State) {
        guard newState != state else { return }
        state = newState
        for subscriber in subscribers.values { subscriber.yield(newState) }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }
}
