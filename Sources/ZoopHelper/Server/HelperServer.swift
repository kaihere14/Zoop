import Darwin
import Foundation
import ZoopShared

/// What the server needs from the rest of the helper. `SystemBackend` talks to macOS;
/// tests pass a fake so the server can be tested without a second user session.
protocol HelperBackend: Sendable {
    func sessionInfo() async -> SessionInfo
    func capture(_ options: CaptureOptions) async throws -> (CaptureMetadata, Data)
    func inspect(_ point: Point) async throws -> [ElementInfo]
    func elements(_ query: ElementQuery) async throws -> [ElementInfo]
    func openApp(_ bundleID: String) async throws -> AppInfo
    func perform(_ action: InputAction) async throws -> ActionReport
    func permissionPrompts() async throws -> [PermissionPrompt]
    func appDialogs(bundleID: String) async throws -> [PermissionPrompt]
    func respondToPermission(promptID: String, choiceID: String) async throws -> ActionReport
}

func helperLog(_ message: String) {
    let line = "[ZoopHelper \(Date().formatted(.iso8601))] \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}

/// Listens on the helper socket and serves each allowed client.
///
/// Per connection:
/// 1. `getpeereid` asks the kernel which user connected. That answer can't be faked by the
///    client. Users not on the allow list get one `unauthorized` reply (id 0) and are closed.
/// 2. The first request must be `hello`. The server answers with its own hello. If the
///    protocol versions differ, it closes the connection after replying.
/// 3. Each later request runs in its own task, so a slow capture never delays a heartbeat ping.
final class HelperServer: @unchecked Sendable {
    struct Configuration: Sendable {
        var socketPath: String
        /// UIDs allowed to connect. The helper's own UID is not added automatically.
        var allowedUIDs: Set<uid_t>
        var helperVersion: String
    }

    enum StartError: Error, CustomStringConvertible {
        case alreadyRunning(String)
        case pathOccupied(String)
        case socket(SocketError)

        var description: String {
            switch self {
            case .alreadyRunning(let path): "another helper is already listening on \(path)"
            case .pathOccupied(let path): "\(path) exists and is not a socket; refusing to delete it"
            case .socket(let error): error.description
            }
        }
    }

    private let config: Configuration
    private let backend: HelperBackend
    private let queue = DispatchQueue(label: "zoop.helper.accept")
    private let lock = NSLock()
    private var acceptSource: DispatchSourceRead?
    private var sessions: [ObjectIdentifier: ClientSession] = [:]

    init(configuration: Configuration, backend: HelperBackend) {
        self.config = configuration
        self.backend = backend
    }

    func start() throws {
        let path = config.socketPath
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try removeStaleSocket(at: path)

        let listenFD: Int32
        do {
            listenFD = try UnixSocket.listen(path: path)
        } catch let error as SocketError {
            throw StartError.socket(error)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(listenFD) }
        source.setCancelHandler { Darwin.close(listenFD) }
        lock.withLock { acceptSource = source }
        source.resume()
        let uids = config.allowedUIDs.sorted().map(String.init).joined(separator: ", ")
        helperLog("listening on \(path) as uid \(getuid()); allowed uids: [\(uids)]")
    }

    /// Stops listening, closes every connection and removes the socket file.
    func stop() {
        let (source, open) = lock.withLock { () -> (DispatchSourceRead?, [ClientSession]) in
            defer { acceptSource = nil; sessions = [:] }
            return (acceptSource, Array(sessions.values))
        }
        guard let source else { return }
        source.cancel()
        open.forEach { $0.close() }
        unlink(config.socketPath)
        helperLog("stopped")
    }

    /// A socket file left behind by a crashed helper blocks `bind`, so remove it. But only
    /// if nobody is listening on it: if a connect succeeds, another helper is running.
    private func removeStaleSocket(at path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard UnixSocket.isSocketFile(path) else { throw StartError.pathOccupied(path) }
        if let fd = try? UnixSocket.connect(path: path) {
            Darwin.close(fd)
            throw StartError.alreadyRunning(path)
        }
        unlink(path)
    }

    private func acceptPending(_ listenFD: Int32) {
        while true {
            let fd: Int32
            do {
                guard let accepted = try UnixSocket.accept(listenFD) else { return }
                fd = accepted
            } catch {
                helperLog("\(error)")
                return
            }
            admit(FramedSocket(fd: fd))
        }
    }

    private func admit(_ socket: FramedSocket) {
        guard let uid = socket.peerUID, config.allowedUIDs.contains(uid) else {
            let who = socket.peerUID.map { "uid \($0)" } ?? "unknown uid"
            helperLog("rejected connection from \(who)")
            let failure = HelperFailure(.unauthorized, "\(who) is not allowed to use this helper")
            if let header = try? WireCoding.encode(ResponseEnvelope(id: 0, failure: failure)) {
                try? socket.send(Frame(header: header))
            }
            socket.close()
            return
        }

        let session = ClientSession(socket: socket, peerUID: uid, backend: backend, helperVersion: config.helperVersion)
        let key = ObjectIdentifier(session)
        lock.withLock { sessions[key] = session }
        session.start { [weak self] in
            _ = self?.lock.withLock { self?.sessions.removeValue(forKey: key) }
        }
    }
}

/// One connected client.
final class ClientSession: @unchecked Sendable {
    private let socket: FramedSocket
    private let peerUID: uid_t
    private let backend: HelperBackend
    private let helperVersion: String
    private let lock = NSLock()
    private var greeted = false

    init(socket: FramedSocket, peerUID: uid_t, backend: HelperBackend, helperVersion: String) {
        self.socket = socket
        self.peerUID = peerUID
        self.backend = backend
        self.helperVersion = helperVersion
    }

    func start(onClose: @escaping @Sendable () -> Void) {
        socket.startReading(
            onFrame: { [self] frame in received(frame) },
            onClose: { [peerUID] reason in
                helperLog("client uid \(peerUID) disconnected: \(reason)")
                onClose()
            })
    }

    func close() {
        socket.close()
    }

    private func received(_ frame: Frame) {
        let envelope: RequestEnvelope
        do {
            envelope = try WireCoding.decode(RequestEnvelope.self, from: frame.header)
        } catch {
            // Most likely a command from a newer client. Answer it by id if we can read that much.
            let id = (try? WireCoding.decode(EnvelopeID.self, from: frame.header))?.id ?? 0
            reply(id, failure: HelperFailure(.badRequest, "unreadable or unsupported request"))
            return
        }

        if case .hello(let client) = envelope.request {
            handleHello(client, id: envelope.id)
            return
        }
        guard lock.withLock({ greeted }) else {
            reply(envelope.id, failure: HelperFailure(.handshakeRequired, "send hello first"))
            return
        }
        let request = envelope.request
        Task { [self] in
            let (outcome, payload) = await execute(request)
            switch outcome {
            case .success(let result): reply(envelope.id, result: result, payload: payload)
            case .failure(let failure): reply(envelope.id, failure: failure)
            }
        }
    }

    private func handleHello(_ client: ClientHello, id: UInt64) {
        let compatible = client.protocolVersion == ZoopProtocol.version
        // Mark greeted before replying, so requests sent right after the hello are accepted.
        lock.withLock { greeted = compatible }
        helperLog("hello from '\(client.clientName)' uid \(peerUID), protocol v\(client.protocolVersion)\(compatible ? "" : " (incompatible, closing)")")
        Task { [self] in
            let hello = HelperHello(protocolVersion: ZoopProtocol.version, helperVersion: helperVersion,
                                    session: await backend.sessionInfo())
            reply(id, result: .hello(helper: hello))
            // Unix sockets hand written bytes straight to the peer's buffer, so the reply
            // still arrives after we close.
            if !compatible { socket.close() }
        }
    }

    private func execute(_ request: HelperRequest) async -> (Result<HelperResult, HelperFailure>, Data) {
        do {
            switch request {
            case .hello: throw HelperFailure(.badRequest, "hello was already sent")
            case .ping: return (.success(.pong), Data())
            case .info: return (.success(.info(session: await backend.sessionInfo())), Data())
            case .capture(let options):
                let (metadata, png) = try await backend.capture(options)
                return (.success(.capture(frame: metadata)), png)
            case .inspect(let point): return (.success(.elements(list: try await backend.inspect(point))), Data())
            case .elements(let query): return (.success(.elements(list: try await backend.elements(query))), Data())
            case .openApp(let bundleID): return (.success(.app(info: try await backend.openApp(bundleID))), Data())
            case .input(let action): return (.success(.action(report: try await backend.perform(action))), Data())
            case .permissionPrompts: return (.success(.permissionPrompts(list: try await backend.permissionPrompts())), Data())
            case .appDialogs(let bundleID): return (.success(.permissionPrompts(list: try await backend.appDialogs(bundleID: bundleID))), Data())
            case .respondToPermission(let promptID, let choiceID):
                return (.success(.action(report: try await backend.respondToPermission(promptID: promptID, choiceID: choiceID))), Data())
            }
        } catch let failure as HelperFailure {
            return (.failure(failure), Data())
        } catch {
            helperLog("\(request.name) failed: \(error)")
            return (.failure(HelperFailure(.internalError, "\(request.name) failed: \(error.localizedDescription)")), Data())
        }
    }

    private func reply(_ id: UInt64, result: HelperResult, payload: Data = Data()) {
        send(ResponseEnvelope(id: id, result: result), payload: payload)
    }

    private func reply(_ id: UInt64, failure: HelperFailure) {
        send(ResponseEnvelope(id: id, failure: failure), payload: Data())
    }

    private func send(_ envelope: ResponseEnvelope, payload: Data) {
        do {
            try socket.send(Frame(header: try WireCoding.encode(envelope), payload: payload))
        } catch {
            helperLog("reply \(envelope.id) to uid \(peerUID) not sent: \(error)")
        }
    }
}
