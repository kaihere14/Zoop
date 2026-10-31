import Foundation
import Testing
@testable import ZoopShared

@Suite struct FrameCodecTests {
    @Test func roundTripsHeaderAndPayload() throws {
        let frame = Frame(header: Data(#"{"id":1}"#.utf8), payload: Data((0..<1000).map { UInt8($0 % 256) }))
        var decoder = FrameDecoder()
        decoder.append(try FrameCodec.encode(frame))
        #expect(try decoder.nextFrame() == frame)
        #expect(try decoder.nextFrame() == nil)
    }

    @Test func emptyPayloadIsAllowed() throws {
        let frame = Frame(header: Data("{}".utf8))
        let bytes = try FrameCodec.encode(frame)
        #expect(bytes.count == FrameCodec.prefixSize + 2)
        var decoder = FrameDecoder()
        decoder.append(bytes)
        #expect(try decoder.nextFrame() == frame)
    }

    @Test func reassemblesFrameArrivingOneByteAtATime() throws {
        let frame = Frame(header: Data(#"{"a":"b"}"#.utf8), payload: Data(repeating: 7, count: 300))
        var decoder = FrameDecoder()
        var decoded: [Frame] = []
        for byte in try FrameCodec.encode(frame) {
            decoder.append(Data([byte]))
            if let next = try decoder.nextFrame() { decoded.append(next) }
        }
        #expect(decoded == [frame])
    }

    @Test func splitsSeveralFramesInOneChunk() throws {
        let frames = (1...3).map { Frame(header: Data("{\"id\":\($0)}".utf8), payload: Data(repeating: UInt8($0), count: $0 * 10)) }
        var chunk = Data()
        for frame in frames { chunk.append(try FrameCodec.encode(frame)) }
        var decoder = FrameDecoder()
        decoder.append(chunk)
        var decoded: [Frame] = []
        while let next = try decoder.nextFrame() { decoded.append(next) }
        #expect(decoded == frames)
    }

    @Test func rejectsOversizedAnnouncementBeforeReadingIt() {
        // A prefix claiming a 4 GB header: the decoder must refuse instead of waiting for it.
        var decoder = FrameDecoder()
        decoder.append(Data([0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0]))
        #expect(throws: FrameError.self) { try decoder.nextFrame() }
    }

    @Test func refusesToEncodeOversizedPayload() {
        let frame = Frame(header: Data("{}".utf8), payload: Data(count: FrameCodec.maxPayloadSize + 1))
        #expect(throws: FrameError.payloadTooLarge(FrameCodec.maxPayloadSize + 1)) { try FrameCodec.encode(frame) }
    }
}
