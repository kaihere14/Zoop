import Foundation
import Testing
@testable import ZoopShared

@Suite struct ProtocolTests {
    static let session = SessionInfo(uid: 502, user: "sbagent", pid: 42, onConsole: false,
                                     permissions: Permissions(screenCapture: true, accessibility: false, postEvent: true),
                                     displayWidth: 1470, displayHeight: 956)

    @Test(arguments: [
        HelperRequest.hello(client: ClientHello(protocolVersion: ZoopProtocol.version, clientName: "test")),
        .ping,
        .info,
        .capture(options: CaptureOptions(maxPixelWidth: 800, showsCursor: false)),
        .inspect(point: Point(x: 10.5, y: 20)),
        .elements(query: ElementQuery(bundleID: "test.app", interactiveOnly: false, limit: 25)),
        .openApp(bundleID: "test.app"),
        .input(action: .click(ClickAction(point: Point(x: 1, y: 2), button: .right, count: 2))),
        .input(action: .type(text: "héllo 🌍\n\t")),
        .input(action: .setText(SetTextAction(text: "replacement", point: Point(x: 1, y: 2)))),
        .input(action: .key(KeyCombo(key: "a", modifiers: [.command]))),
        .input(action: .scroll(ScrollAction(point: Point(x: 3, y: 4), deltaX: -1, deltaY: 3))),
        .input(action: .scrollPage(PageScrollAction(point: Point(x: 439, y: 359), direction: .down, pages: 2))),
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
            ResponseEnvelope(id: 3, result: .hello(helper: HelperHello(protocolVersion: ZoopProtocol.version, helperVersion: "0.1.0", session: Self.session))),
            ResponseEnvelope(id: 4, result: .capture(frame: CaptureMetadata(width: 10, height: 20, pointWidth: 5, pointHeight: 10))),
            ResponseEnvelope(id: 5, result: .elements(list: [ElementInfo(role: "AXButton", title: "7", actions: ["AXPress"], pid: 42)])),
            ResponseEnvelope(id: 6, result: .app(info: AppInfo(bundleID: "test.app", name: "Test", pid: 42, isActive: false))),
            ResponseEnvelope(id: 7, result: .action(report: ActionReport(action: "click", method: .axPress, pid: 42, axError: -25200, landed: nil, detail: "check screenshot"))),
            ResponseEnvelope(id: 8, result: .action(report: ActionReport(action: "setText", method: .axSetValue, landed: false, detail: "mismatch"))),
            ResponseEnvelope(id: 9, result: .action(report: ActionReport(action: "type", method: .pidKeys, landed: true, detail: "verified"))),
            ResponseEnvelope(id: 10, result: .action(report: ActionReport(action: "scrollPage", method: .axScrollPage, axError: 0, landed: nil, detail: "check viewport"))),
            ResponseEnvelope(id: 0, failure: HelperFailure(.unauthorized, "nope")),
        ]
        for response in responses {
            #expect(try WireCoding.decode(ResponseEnvelope.self, from: WireCoding.encode(response)) == response)
        }
    }

    @Test func screenshotPixelsConvertToPointsAfterDownscaling() {
        let metadata = CaptureMetadata(width: 800, height: 500, pointWidth: 1280, pointHeight: 800)
        #expect(metadata.point(fromPixelX: 400, y: 250) == Point(x: 640, y: 400))
    }

    @Test func parsesKeyCombosAndRejectsMalformedOnes() {
        #expect(KeyCombo.parse("cmd+shift+l") == KeyCombo(key: "l", modifiers: [.command, .shift]))
        #expect(KeyCombo.parse(" CTRL + A ") == KeyCombo(key: "a", modifiers: [.control]))
        #expect(KeyCombo.parse("return") == KeyCombo(key: "return"))
        #expect(KeyCombo.parse("cmd+cmd+a") == KeyCombo(key: "a", modifiers: [.command]))
        for invalid in ["", "cmd+", "+a", "cmd++a", "bogus+a", "cmd"] { #expect(KeyCombo.parse(invalid) == nil) }
    }

    @Test func unknownCommandStillYieldsItsID() throws {
        // A newer client may send commands this helper doesn't know. The helper can still
        // read the id and answer that request with an error instead of dropping the connection.
        let json = Data(#"{"id":77,"request":{"teleport":{}}}"#.utf8)
        #expect(throws: DecodingError.self) { try WireCoding.decode(RequestEnvelope.self, from: json) }
        #expect(try WireCoding.decode(EnvelopeID.self, from: json).id == 77)
    }

    @Test func onlyReadOnlyCommandsAreReplayable() {
        // Anything that changes focus or content must never run twice automatically.
        #expect(HelperRequest.ping.isReplayable)
        #expect(HelperRequest.info.isReplayable)
        #expect(HelperRequest.capture(options: CaptureOptions()).isReplayable)
        #expect(HelperRequest.inspect(point: Point(x: 1, y: 2)).isReplayable)
        #expect(HelperRequest.elements(query: ElementQuery(bundleID: "test.app")).isReplayable)
        #expect(!HelperRequest.openApp(bundleID: "test.app").isReplayable)
        for action in [InputAction.click(ClickAction(point: Point(x: 1, y: 2))), .type(text: "x"),
                       .setText(SetTextAction(text: "x")), .key(KeyCombo(key: "return")),
                       .scroll(ScrollAction(point: Point(x: 1, y: 2), deltaY: 1)),
                       .scrollPage(PageScrollAction(point: Point(x: 1, y: 2), direction: .up))] {
            #expect(!HelperRequest.input(action: action).isReplayable)
        }
    }
}
