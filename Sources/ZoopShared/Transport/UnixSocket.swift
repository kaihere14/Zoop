import Darwin
import Foundation

/// A failed POSIX socket call, with the `errno` it produced.
public struct SocketError: Error, Sendable, Equatable, CustomStringConvertible {
    public var operation: String
    public var code: Int32

    public init(_ operation: String, code: Int32 = errno) {
        self.operation = operation
        self.code = code
    }

    public var description: String {
        "\(operation) failed: \(String(cString: strerror(code))) (errno \(code))"
    }
}

/// Thin wrappers over the BSD socket calls for `AF_UNIX` stream sockets.
package enum UnixSocket {
    /// `sockaddr_un.sun_path` holds 104 bytes on macOS, including the terminating zero.
    package static func address(for path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw SocketError("socket path '\(path)' is too long", code: ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return addr
    }

    /// New stream socket. `SO_NOSIGPIPE` makes writes to a closed peer return `EPIPE`
    /// instead of killing the whole process with `SIGPIPE`.
    package static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        configureConnected(fd)
        return fd
    }

    /// Options every connected socket gets, including ones returned by `accept`.
    package static func configureConnected(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // A peer that stops reading must not block our writer forever.
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Connects to a listening socket. Connecting to a Unix socket never waits on the
    /// network: it either succeeds immediately or fails with `ENOENT` (no socket file),
    /// `ECONNREFUSED` (file exists but nobody listens) or `EACCES` (no permission).
    package static func connect(path: String) throws -> Int32 {
        var addr = try address(for: path)
        let fd = try makeSocket()
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = SocketError("connect to \(path)")
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    /// Creates the socket file at `path` and starts listening. The caller removes any old
    /// file first. The socket is non-blocking so `accept` can be driven by a dispatch source.
    package static func listen(path: String, backlog: Int32 = 16, mode: mode_t = 0o666) throws -> Int32 {
        var addr = try address(for: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let error = SocketError("bind \(path)")
            Darwin.close(fd)
            throw error
        }
        // Anyone may connect at the file level. Access control happens per connection with
        // getpeereid, which cannot be spoofed, instead of with file permissions.
        chmod(path, mode)
        guard Darwin.listen(fd, backlog) == 0 else {
            let error = SocketError("listen")
            Darwin.close(fd)
            throw error
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    /// Accepts one pending connection, or returns nil when none is waiting.
    package static func accept(_ listenFD: Int32) throws -> Int32? {
        while true {
            let fd = Darwin.accept(listenFD, nil, nil)
            if fd >= 0 {
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                // On macOS an accepted socket inherits O_NONBLOCK from the listener.
                // Connections use blocking reads on their own thread, so clear it.
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
                configureConnected(fd)
                return fd
            }
            switch errno {
            case EINTR: continue
            case EAGAIN, ECONNABORTED: return nil
            default: throw SocketError("accept")
            }
        }
    }

    /// UID of the process on the other end, as recorded by the kernel when it connected.
    package static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    /// Whether `path` is a socket file (as opposed to a missing path or a regular file).
    package static func isSocketFile(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
    }
}
