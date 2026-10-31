import CoreGraphics
import Foundation
import Testing
import ZoopShared
@testable import ZoopHelper

@Suite struct MouseClickTests {
    private func window(_ pid: Int32, _ number: Int64, layer: Int = 0, alpha: Double = 1) -> [String: Any] {
        [kCGWindowOwnerPID as String: NSNumber(value: pid), kCGWindowNumber as String: NSNumber(value: number),
         kCGWindowLayer as String: layer, kCGWindowAlpha as String: alpha,
         kCGWindowBounds as String: CGRect(x: 10, y: 20, width: 200, height: 150).dictionaryRepresentation]
    }

    @Test func neverClicksThroughAnotherAppsWindow() throws {
        let point = Point(x: 50, y: 60)
        #expect(throws: HelperFailure.self) {
            try MouseClickTarget(point: point, expectedPID: 42, windows: [window(99, 10), window(42, 11)])
        }
        #expect(throws: HelperFailure.self) {
            try MouseClickTarget(point: Point(x: 999, y: 999), expectedPID: 42, windows: [window(42, 11)])
        }
        let target = try MouseClickTarget(point: point, expectedPID: 42,
                                         windows: [window(99, 10, layer: 1), window(99, 12, alpha: 0), window(42, 11)])
        #expect(target.pid == 42 && target.windowNumber == 11)
    }

    @Test func buildsPairedWindowTargetedMouseEventsWithoutPosting() throws {
        let point = Point(x: 50, y: 60)
        let target = try MouseClickTarget(point: point, expectedPID: 42, windows: [window(42, 11)])
        let double = try target.events(for: ClickAction(point: point, count: 2, strategy: .mouse, bundleID: "test.app"))
        #expect(double.map(\.type) == [.leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        #expect(double.map { $0.getIntegerValueField(.mouseEventClickState) } == [1, 1, 2, 2])
        for event in double {
            #expect(event.location == CGPoint(x: 50, y: 60))
            #expect(event.getIntegerValueField(.mouseEventWindowUnderMousePointer) == 11)
            #expect(event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent) == 11)
            #expect(event.flags.isEmpty)
        }
        let right = try target.events(for: ClickAction(point: point, button: .right, strategy: .mouse, bundleID: "test.app"))
        #expect(right.map(\.type) == [.rightMouseDown, .rightMouseUp])
    }
}
