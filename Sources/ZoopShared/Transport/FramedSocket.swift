import Darwin
import Foundation

/// Why a `FramedSocket` stopped reading.
package enum SocketCloseReason: Sendable, Equatable, CustomStringConvertible {
    /// The other side closed the connection (read returned 0 bytes).
    case peerClosed
    /// `close()` was called on this side.
    case closedLocally
    /// A read failed or the peer sent a malformed frame.
    case failed(String)

    package var description: String {
        switch self {
        case .peerClosed: "the other side closed the connection"
        case .closedLocally: "closed locally"
        case .failed(let reason): reason
        }
    }
}

/// A connected Unix socket that sends and receives `Frame`s.
///
/// Threading model, kept simple on purpose:
/// - One dedicated thread per socket does blocking `read` calls and hands complete frames
///   to `onFrame` in order. A connection only ever has one of these threads.
/// - `send` may be called from any thread. A lock makes each frame's bytes go out
///   together, so two concurrent senders never interleave their frames.
/// - `close()` calls `shutdown`, which wakes the blocked `read`. The reader thread then
///   closes the file descriptor and calls `onClose` exactly once.
package final class FramedSocket: @unchecked Sendable {
    private let fd: Int32
    // Guards `descriptorClosed` and serializes writes. Held while closing the descriptor,
    // so a write can never reach a descriptor number the system has already reused.
    private let writeLock = NSLock()
    private var descriptorClosed = false
    private let stateLock = NSLock()
    private var closeRequested = false
    private var readerStarted = false

    package init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        if !readerStarted && !descriptorClosed { Darwin.close(fd) }
    }

    package var peerUID: uid_t? { UnixSocket.peerUID(fd) }

    /// Starts the reader thread. Call at most once.
    package func startReading(onFrame: @escaping @Sendable (Frame) -> Void,
                              onClose: @escaping @Sendable (SocketCloseReason) -> Void) {
        stateLock.withLock { readerStarted = true }
        let thread = Thread { [self] in
            let reason = readLoop(onFrame: onFrame)
            writeLock.withLock {
                descriptorClosed = true
                Darwin.close(fd)
            }
            onClose(reason)
        }
        thread.name = "zoop.socket.reader.\(fd)"
        thread.start()
    }

    private func readLoop(onFrame: @Sendable (Frame) -> Void) -> SocketCloseReason {
        var decoder = FrameDecoder()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count == 0 {
                return stateLock.withLock { closeRequested } ? .closedLocally : .peerClosed
            }
            if count < 0 {
                if errno == EINTR { continue }
                if stateLock.withLock({ closeRequested }) { return .closedLocally }
                return .failed(SocketError("read").description)
            }
            decoder.append(Data(chunk[0..<count]))
            do {
                while let frame = try decoder.nextFrame() { onFrame(frame) }
            } catch {
                return .failed("malformed frame: \(error)")
            }
        }
    }

    /// Writes one frame. Blocks until the bytes are in the socket buffer, or up to the
    /// socket's 10 s send timeout if the peer stopped reading.
    package func send(_ frame: Frame) throws {
        let bytes = try FrameCodec.encode(frame)
        try writeLock.withLock {
            guard !descriptorClosed else { throw SocketError("write", code: EBADF) }
            try bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, base + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw SocketError("write")
                    }
                    offset += written
                }
            }
        }
    }

    /// Closes the connection. Safe to call more than once and from any thread.
    package func close() {
        let startedReader = stateLock.withLock { () -> Bool in
            closeRequested = true
            return readerStarted
        }
        writeLock.withLock {
            guard !descriptorClosed else { return }
            // Wakes the reader thread, which closes the descriptor itself.
            shutdown(fd, SHUT_RDWR)
            if !startedReader {
                descriptorClosed = true
                Darwin.close(fd)
            }
        }
    }
}
