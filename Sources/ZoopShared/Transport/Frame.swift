import Foundation

/// One message on the wire.
///
/// ```
/// ┌──────────────┬───────────────┬─────────────┬────────────────┐
/// │ headerLength │ payloadLength │ header JSON │ payload bytes  │
/// │ UInt32 BE    │ UInt32 BE     │             │ (may be empty) │
/// └──────────────┴───────────────┴─────────────┴────────────────┘
/// ```
///
/// The 8-byte prefix tells the reader exactly how many bytes belong to this frame before it
/// reads any of them. That avoids the two weak spots of newline-delimited JSON: the reader
/// never has to scan for a delimiter, and it can reject an absurd size before allocating.
public struct Frame: Sendable, Equatable {
    public var header: Data
    public var payload: Data

    public init(header: Data, payload: Data = Data()) {
        self.header = header
        self.payload = payload
    }
}

public enum FrameError: Error, Sendable, Equatable, CustomStringConvertible {
    case headerTooLarge(Int)
    case payloadTooLarge(Int)

    public var description: String {
        switch self {
        case .headerTooLarge(let n): "frame header of \(n) bytes exceeds \(FrameCodec.maxHeaderSize)"
        case .payloadTooLarge(let n): "frame payload of \(n) bytes exceeds \(FrameCodec.maxPayloadSize)"
        }
    }
}

public enum FrameCodec {
    public static let prefixSize = 8
    /// JSON headers are small. Anything near this size means a broken or hostile peer.
    public static let maxHeaderSize = 1 << 20
    /// Large enough for a full-resolution PNG of a 6K display.
    public static let maxPayloadSize = 128 << 20

    public static func encode(_ frame: Frame) throws -> Data {
        guard frame.header.count <= maxHeaderSize else { throw FrameError.headerTooLarge(frame.header.count) }
        guard frame.payload.count <= maxPayloadSize else { throw FrameError.payloadTooLarge(frame.payload.count) }
        var out = Data(capacity: prefixSize + frame.header.count + frame.payload.count)
        appendUInt32(UInt32(frame.header.count), to: &out)
        appendUInt32(UInt32(frame.payload.count), to: &out)
        out.append(frame.header)
        out.append(frame.payload)
        return out
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}

/// Reassembles frames from a byte stream.
///
/// A socket `read` returns whatever bytes have arrived, which can be half a frame or several
/// frames at once. Feed every chunk to `append`, then call `nextFrame` until it returns nil.
public struct FrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ bytes: Data) {
        buffer.append(bytes)
    }

    /// Returns the next complete frame, or nil if more bytes are needed.
    /// Throws if the peer announces a frame larger than the limits.
    public mutating func nextFrame() throws -> Frame? {
        guard buffer.count >= FrameCodec.prefixSize else { return nil }
        let headerLength = Int(readUInt32(at: 0))
        let payloadLength = Int(readUInt32(at: 4))
        guard headerLength <= FrameCodec.maxHeaderSize else { throw FrameError.headerTooLarge(headerLength) }
        guard payloadLength <= FrameCodec.maxPayloadSize else { throw FrameError.payloadTooLarge(payloadLength) }

        let total = FrameCodec.prefixSize + headerLength + payloadLength
        guard buffer.count >= total else { return nil }

        let start = buffer.startIndex
        let headerStart = start + FrameCodec.prefixSize
        let payloadStart = headerStart + headerLength
        let frame = Frame(header: Data(buffer[headerStart..<payloadStart]),
                          payload: Data(buffer[payloadStart..<(start + total)]))
        buffer.removeSubrange(start..<(start + total))
        return frame
    }

    private func readUInt32(at offset: Int) -> UInt32 {
        let start = buffer.startIndex + offset
        return buffer[start..<(start + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }
}
