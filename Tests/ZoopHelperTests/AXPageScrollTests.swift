import ApplicationServices
import Testing
import ZoopShared
@testable import ZoopHelper

@Suite struct AXPageScrollTests {
    @Test func mapsAllDirectionsToAdvertisedPageActions() throws {
        let expected: [(PageScrollDirection, String)] = [
            (.up, "AXScrollUpByPage"), (.down, "AXScrollDownByPage"),
            (.left, "AXScrollLeftByPage"), (.right, "AXScrollRightByPage"),
        ]
        for (direction, name) in expected {
            let plan = try AXPageScroll(PageScrollAction(point: Point(x: 10, y: 20), direction: direction))
            #expect(plan.actionName == name)
        }
    }

    @Test func rejectsInvalidCountsAndCoordinatesBeforeAnyAXCall() {
        for pages in [-1, 0, PageScrollAction.maximumPages + 1] {
            #expect {
                try AXPageScroll(PageScrollAction(point: Point(x: 10, y: 20), direction: .down, pages: pages))
            } throws: { ($0 as? HelperFailure)?.code == .badRequest }
        }
        for x in [Double.nan, .infinity, .greatestFiniteMagnitude] {
            #expect {
                try AXPageScroll(PageScrollAction(point: Point(x: x, y: 20), direction: .down))
            } throws: { ($0 as? HelperFailure)?.code == .badRequest }
        }
    }

    @Test func performsExactlyTheRequestedNumberOfPagesOnSuccess() throws {
        let plan = try AXPageScroll(PageScrollAction(point: Point(x: 10, y: 20), direction: .down, pages: 3))
        var calls = 0
        let outcome = plan.run { calls += 1; return .success }
        #expect(calls == 3)
        #expect(outcome.attempted == 3)
        #expect(outcome.accepted == 3)
        #expect(outcome.error == .success)
    }

    @Test(arguments: [AXError.failure, .cannotComplete, .apiDisabled])
    func stopsAtFirstErrorWithoutRetry(_ error: AXError) throws {
        let plan = try AXPageScroll(PageScrollAction(point: Point(x: 10, y: 20), direction: .down, pages: 3))
        var calls = 0
        let outcome = plan.run {
            calls += 1
            return calls == 1 ? .success : error
        }
        #expect(calls == 2)
        #expect(outcome.attempted == 2)
        #expect(outcome.accepted == 1)
        #expect(outcome.error == error)
    }
}
