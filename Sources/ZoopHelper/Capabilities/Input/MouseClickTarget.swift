import CoreGraphics
import Foundation
import ZoopShared

/// Selects only the visible normal window under a point. Never click through another app.
struct MouseClickTarget: Equatable {
    let pid: Int32
    let windowNumber: Int64

    init(point: Point, expectedPID: Int32, windows: [[String: Any]]) throws {
        let location = CGPoint(x: point.x, y: point.y)
        guard let window = windows.first(where: { window in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return rect.contains(location)
        }), let owner = window[kCGWindowOwnerPID as String] as? Int32, owner == expectedPID, owner > 0,
            let number = window[kCGWindowNumber as String] as? Int64, number > 0 else {
            throw HelperFailure(.notFound, "no visible target app window owns \(point). Call open_app, then screenshot and locate the target again.")
        }
        pid = owner
        windowNumber = number
    }

    /// Creates events without posting them, so targeting and double-click state are testable.
    func events(for click: ClickAction) throws -> [CGEvent] {
        let source = CGEventSource(stateID: .privateState)
        let right = click.button == .right
        let location = CGPoint(x: click.point.x, y: click.point.y)
        var result: [CGEvent] = []
        for count in 1...click.count {
            for type: CGEventType in [right ? .rightMouseDown : .leftMouseDown, right ? .rightMouseUp : .leftMouseUp] {
                guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location,
                                          mouseButton: right ? .right : .left) else {
                    throw HelperFailure(.internalError, "could not create mouse events")
                }
                event.flags = []
                event.setIntegerValueField(.mouseEventClickState, value: Int64(count))
                event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: windowNumber)
                event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: windowNumber)
                result.append(event)
            }
        }
        return result
    }
}
