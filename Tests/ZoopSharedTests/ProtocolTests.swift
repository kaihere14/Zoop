import Foundation
import Testing
@testable import ZoopShared

@Suite struct ProtocolTests {
    static let session = SessionInfo(uid: 502, user: "sbagent", pid: 42, onConsole: false,
                                     permissions: Permissions(screenCapture: true, accessibility: false, postEvent: true),
                                     displayWidth: 1470, displayHeight: 956)

    @Test(arguments: [
        HelperRequest.hello(client: ClientHello(protocolVersion: 1, clientName: "test")),
        .ping,
        .info,
        .capture(options: CaptureOptions(maxPixelWidth: 800, showsCursor: false)),
    ])
    func requestsRoundTrip(_ request: HelperRequest) throws {
        let envelope = RequestEnvelope(id: 9, request: request)
        let decoded = try WireCoding.decode(RequestEnvelope.self, from: WireCoding.encode(envelope))
        #expect(decoded == envelope)
    }

    @Test func responsesRoundTrip() throws {
        let responses = [
            ResponseEnvelope(id: 1, result: .pong),
            ResponseEnvelope(id: 2, result: .info(session: Self.session)),
            ResponseEnvelope(id: 3, result: .hello(helper: HelperHello(protocolVersion: 1, helperVersion: "0.1.0", session: Self.session))),
            ResponseEnvelope(id: 4, result: .capture(frame: CaptureMetadata(width: 10, height: 20))),
            ResponseEnvelope(id: 0, failure: HelperFailure(.unauthorized, "nope")),
        ]
        for response in responses {
            #expect(try WireCoding.decode(ResponseEnvelope.self, from: WireCoding.encode(response)) == response)
        }
    }

    @Test func unknownCommandStillYieldsItsID() throws {
        // A newer client may send commands this helper doesn't know. The helper can still
        // read the id and answer that request with an error instead of dropping the connection.
        let json = Data(#"{"id":77,"request":{"teleport":{}}}"#.utf8)
        #expect(throws: DecodingError.self) { try WireCoding.decode(RequestEnvelope.self, from: json) }
        #expect(try WireCoding.decode(EnvelopeID.self, from: json).id == 77)
    }

    @Test func currentCommandsAreAllReplayable() {
        // All commands today are read-only. When click/type arrive they must return false.
        #expect(HelperRequest.ping.isReplayable)
        #expect(HelperRequest.info.isReplayable)
        #expect(HelperRequest.capture(options: CaptureOptions()).isReplayable)
    }
}
