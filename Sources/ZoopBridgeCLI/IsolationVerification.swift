import AppKit
import CoreGraphics
import Foundation
import ZoopShared

/// Observes the CLI's session, never the helper's. The user must keep their mouse and
/// keyboard still during this short measurement: real input is indistinguishable from leaks.
final class IsolationVerification: @unchecked Sendable {
    private struct Snapshot {
        let cursor: CGPoint?
        let frontPID: pid_t?
        let counts: [UInt32]
        init() {
            cursor = CGEvent(source: nil)?.location
            frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            counts = [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown].map {
                CGEventSource.counterForEventType(.combinedSessionState, eventType: $0)
            }
        }
    }
    private let before = Snapshot()
    private let lock = NSLock()
    private var maxDrift = 0.0
    private var samples = 0
    private var missingSamples = 0
    private var focusChanged = false
    private let timer: DispatchSourceTimer

    init(helper: SessionInfo) throws {
        let localSession = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard helper.uid != Int(getuid()), !helper.onConsole,
              localSession?[kCGSessionOnConsoleKey] as? Bool == true else {
            throw HelperFailure(.badRequest, "--verify requires this CLI in the console user's session and a different, background helper user")
        }
        guard before.cursor != nil, before.frontPID != nil else {
            throw HelperFailure(.internalError, "cannot observe the primary cursor or frontmost app")
        }
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "zoop.verify"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .microseconds(100))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }

    private func sample() {
        let cursor = CGEvent(source: nil)?.location
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        lock.withLock {
            if let cursor, let origin = before.cursor {
                maxDrift = max(maxDrift, hypot(cursor.x - origin.x, cursor.y - origin.y))
                samples += 1
            } else { missingSamples += 1 }
            if frontPID != before.frontPID { focusChanged = true }
        }
    }

    func finish() -> Bool {
        sample()
        let after = Snapshot()
        timer.cancel()
        let (drift, samples, missing, focusChanged) = lock.withLock { (maxDrift, samples, missingSamples, focusChanged) }
        let deltas = zip(after.counts, before.counts).map { $0 &- $1 }
        let cursorOK = samples > 0 && missing == 0 && drift < 0.5
        let appOK = !focusChanged && after.frontPID == before.frontPID
        let eventsOK = deltas.allSatisfy { $0 == 0 }
        print("verify cursor: \(cursorOK ? "PASS" : "FAIL"), max drift \(String(format: "%.2f", drift)) pt, \(samples) samples")
        print("verify frontmost app: \(appOK ? "PASS" : "FAIL"), pid \(before.frontPID ?? -1) -> \(after.frontPID ?? -1)")
        print("verify primary input: \(eventsOK ? "PASS" : "FAIL"), keyDown +\(deltas[0]), left/right/other mouseDown +\(deltas[1])/\(deltas[2])/\(deltas[3])")
        return cursorOK && appOK && eventsOK
    }

    deinit { timer.cancel() }
}
