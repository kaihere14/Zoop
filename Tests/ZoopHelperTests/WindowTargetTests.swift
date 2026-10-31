import CoreGraphics
import Foundation
import Testing
import ZoopShared
@testable import ZoopHelper

@Suite struct WindowTargetTests {
    private let point = Point(x: 439, y: 359)

    private func window(pid: Int32, number: Int, bounds: CGRect, alpha: Double = 1) -> [String: Any] {
        [kCGWindowOwnerPID as String: pid,
         kCGWindowNumber as String: number,
         kCGWindowBounds as String: bounds.dictionaryRepresentation,
         kCGWindowAlpha as String: alpha]
    }

    @Test func axOwnerSkipsScreenSizedOverlayFromAnotherApp() throws {
        let overlay = window(pid: 39682, number: 41825, bounds: CGRect(x: 0, y: 0, width: 1470, height: 956))
        let textEdit = window(pid: 50879, number: 50000, bounds: CGRect(x: 146, y: 62, width: 586, height: 500))
        let target = try WindowTarget.select(at: point, windows: [overlay, textEdit], ownerPID: 50879)
        #expect(target.pid == 50879)
        #expect(target.number == 50000)
    }

    @Test func missingAXOwnerWindowNeverRedirectsToAnotherApp() {
        let overlay = window(pid: 39682, number: 41825, bounds: CGRect(x: 0, y: 0, width: 1470, height: 956))
        #expect {
            try WindowTarget.select(at: point, windows: [overlay], ownerPID: 50879)
        } throws: { error in (error as? HelperFailure)?.code == .notFound }
    }

    @Test func preservesFrontToBackOrderAndRequiresContainmentForSameOwner() throws {
        let elsewhere = window(pid: 50879, number: 1, bounds: CGRect(x: 900, y: 100, width: 200, height: 200))
        let hidden = window(pid: 50879, number: 2, bounds: CGRect(x: 100, y: 100, width: 600, height: 600), alpha: 0)
        let front = window(pid: 50879, number: 3, bounds: CGRect(x: 100, y: 100, width: 600, height: 600))
        let back = window(pid: 50879, number: 4, bounds: CGRect(x: 100, y: 100, width: 600, height: 600))
        let target = try WindowTarget.select(at: point, windows: [elsewhere, hidden, front, back], ownerPID: 50879)
        #expect(target.number == 3)
    }

    @Test func withoutAXUsesExistingWindowListFallback() throws {
        let front = window(pid: 123, number: 1, bounds: CGRect(x: 100, y: 100, width: 600, height: 600))
        let back = window(pid: 456, number: 2, bounds: CGRect(x: 100, y: 100, width: 600, height: 600))
        let target = try WindowTarget.select(at: point, windows: [front, back], ownerPID: nil)
        #expect(target.pid == 123)
        #expect(target.number == 1)
    }
}
