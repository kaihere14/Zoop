import ApplicationServices
import Testing
import ZoopShared
@testable import ZoopHelper

@Suite struct AXScrollBarPositionTests {
    @Test func mapsEachAxisToItsScrollBarAttribute() throws {
        let vertical = try AXScrollBarPosition(ScrollToAction(point: Point(x: 1, y: 2), axis: .vertical, fraction: 0.5))
        let horizontal = try AXScrollBarPosition(ScrollToAction(point: Point(x: 1, y: 2), axis: .horizontal, fraction: 0.5))
        #expect(vertical.scrollBarAttribute == kAXVerticalScrollBarAttribute)
        #expect(horizontal.scrollBarAttribute == kAXHorizontalScrollBarAttribute)
    }

    @Test func acceptsTheWholeClosedRange() throws {
        for fraction in [0.0, 0.25, 1.0] {
            #expect(try AXScrollBarPosition(ScrollToAction(point: Point(x: 1, y: 2), fraction: fraction)).fraction == fraction)
        }
    }

    @Test func rejectsInvalidFractionsAndCoordinatesBeforeAnyAXCall() {
        for fraction in [-0.01, 1.01, .nan, .infinity] {
            #expect {
                try AXScrollBarPosition(ScrollToAction(point: Point(x: 1, y: 2), fraction: fraction))
            } throws: { ($0 as? HelperFailure)?.code == .badRequest }
        }
        for x in [Double.nan, .infinity, .greatestFiniteMagnitude] {
            #expect {
                try AXScrollBarPosition(ScrollToAction(point: Point(x: x, y: 2), fraction: 0.5))
            } throws: { ($0 as? HelperFailure)?.code == .badRequest }
        }
    }

    @Test func landedComparesReadbackWithinTolerance() throws {
        let plan = try AXScrollBarPosition(ScrollToAction(point: Point(x: 1, y: 2), fraction: 0.5))
        #expect(plan.landed(after: 0.5) == true)
        #expect(plan.landed(after: 0.505) == true)
        // An accepted write that leaves the bar where it was is a miss, not a success.
        #expect(plan.landed(after: 0) == false)
        #expect(plan.landed(after: 0.52) == false)
        #expect(plan.landed(after: nil) == nil)
        #expect(plan.landed(after: .nan) == nil)
    }
}
