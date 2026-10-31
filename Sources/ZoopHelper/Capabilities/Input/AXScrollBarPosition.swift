import ApplicationServices
import ZoopShared

/// Absolute scrolling through a scroll area's scroll bar. TextEdit advertises
/// AXScroll…ByPage on its AXScrollArea but rejects it with -25205, while its scroll bar
/// exposes the position as an AXValue from 0 to 1. Writing that value is a separate,
/// explicit strategy with no fallback to wheel events or page keys.
struct AXScrollBarPosition {
    /// Readback within this distance of the request counts as landed. AppKit can snap the
    /// position to whole pixels, so an exact match is too strict.
    static let tolerance = 0.01
    /// How many elements (the hit element and its parents) to search for a scroll area.
    /// Safari article text sits more than five levels below its AXScrollArea.
    static let ancestorLimit = 30
    /// Apps apply the new position asynchronously (Safari took longer than 50 ms), so the
    /// readback is polled this many times, 50 ms apart, before reporting a mismatch.
    static let readbackAttempts = 10

    let fraction: Double
    /// The AXScrollArea attribute that holds the scroll bar for this axis.
    let scrollBarAttribute: String

    init(_ action: ScrollToAction) throws {
        guard action.fraction.isFinite, (0...1).contains(action.fraction) else {
            throw HelperFailure(.badRequest, "fraction must be between 0 and 1")
        }
        guard Float(action.point.x).isFinite, Float(action.point.y).isFinite else {
            throw HelperFailure(.badRequest, "coordinates must be finite")
        }
        fraction = action.fraction
        switch action.axis {
        case .vertical: scrollBarAttribute = kAXVerticalScrollBarAttribute
        case .horizontal: scrollBarAttribute = kAXHorizontalScrollBarAttribute
        }
    }

    /// `true` when the readback matches, `false` when it clearly does not, and `nil` when
    /// the value could not be read. A write that "succeeds" without moving is a miss.
    func landed(after: Double?) -> Bool? {
        guard let after, after.isFinite else { return nil }
        return abs(after - fraction) <= Self.tolerance
    }
}
