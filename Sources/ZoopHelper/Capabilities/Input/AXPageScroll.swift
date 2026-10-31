import ApplicationServices
import ZoopShared

/// A bounded sequence of advertised AX page actions. Each call may take effect even if
/// it returns an error, so the sequence stops immediately on error without retrying.
struct AXPageScroll {
    let actionName: String
    private let pages: Int

    init(_ action: PageScrollAction) throws {
        guard (1...PageScrollAction.maximumPages).contains(action.pages) else {
            throw HelperFailure(.badRequest, "page count must be 1...\(PageScrollAction.maximumPages)")
        }
        guard Float(action.point.x).isFinite, Float(action.point.y).isFinite else {
            throw HelperFailure(.badRequest, "coordinates must be finite")
        }
        pages = action.pages
        switch action.direction {
        case .up: actionName = "AXScrollUpByPage"
        case .down: actionName = "AXScrollDownByPage"
        case .left: actionName = "AXScrollLeftByPage"
        case .right: actionName = "AXScrollRightByPage"
        }
    }

    struct Outcome {
        let attempted: Int
        let accepted: Int
        let error: AXError
    }

    func run(_ perform: () -> AXError) -> Outcome {
        for index in 1...pages {
            let error = perform()
            guard error == .success else { return Outcome(attempted: index, accepted: index - 1, error: error) }
            // Give the app a chance to consume one page before requesting the next.
            if index < pages { usleep(50_000) }
        }
        return Outcome(attempted: pages, accepted: pages, error: .success)
    }
}
