import Foundation
import ZoopShared

// zoop-bridge: tries the session bridge from the main user's terminal.
// Every command prints connection state changes to stderr, so retries are visible.

let usage = """
usage: zoop-bridge <command> [options]

commands:
  status              connect and show the agent session and its permissions
  ping [-n COUNT]     measure round-trip time
  info                print session details as JSON
  capture             save one screenshot of the agent session
      --out DIR         folder for the PNG (default: frames)
      --max-width PX    downscale to at most PX pixels wide
  inspect X Y         element at a point and its ancestors
  elements BUNDLE_ID [--all] [--limit N]
  open BUNDLE_ID      launch or bring forward an app in the agent session
  click X Y [--right] [--double]
  type TEXT           keystrokes to the focused app (quote TEXT as one argument)
  set-text TEXT [--at X Y]
  key COMBO           e.g. cmd+shift+l, return, tab, escape
  scroll X Y --dy N [--dx N]  positive deltas scroll down/right
  scroll-page X Y --direction up|down|left|right [--pages N]
                      explicit AX page scroll; defaults to 1 page (maximum 10)
  watch               stay connected and print every state change; press Enter to retry after a failure

options:
  --verify            check primary-session isolation around an action (keep hands still)
  --socket PATH       helper socket (default: \(ZoopPaths.helperSocket()))
  --retries N         retries after the first failed attempt (default: 3)
"""

struct Options {
    var command = ""
    var socketPath = ZoopPaths.helperSocket()
    var retries = 3
    var count = 3
    var outDirectory = "frames"
    var maxWidth: Int?
    var positional: [String] = []
    var verify = false
    var all = false
    var limit = 300
    var right = false
    var double = false
    var at: Point?
    var dy: Int?
    var dx = 0
    var pageDirection: PageScrollDirection?
    var pages: Int?
}

func parse() -> Options {
    var options = Options()
    var arguments = CommandLine.arguments.dropFirst().makeIterator()
    func value(for flag: String) -> String {
        guard let value = arguments.next() else { fail("\(flag) needs a value", code: 64) }
        return value
    }
    func integer(_ flag: String) -> Int {
        guard let n = Int(value(for: flag)) else { fail("\(flag) needs an integer", code: 64) }
        return n
    }
    func number(_ flag: String) -> Double {
        guard let n = Double(value(for: flag)), n.isFinite else { fail("\(flag) needs a finite number", code: 64) }
        return n
    }
    var literal = false
    while let argument = arguments.next() {
        if literal {
            if options.command.isEmpty { options.command = argument } else { options.positional.append(argument) }
            continue
        }
        switch argument {
        case "--socket": options.socketPath = value(for: argument)
        case "--retries": options.retries = integer(argument)
        case "-n": options.count = integer(argument)
        case "--out": options.outDirectory = value(for: argument)
        case "--max-width": options.maxWidth = integer(argument)
        case "--verify": options.verify = true
        case "--all": options.all = true
        case "--limit": options.limit = integer(argument)
        case "--right": options.right = true
        case "--double": options.double = true
        case "--at": options.at = Point(x: number(argument), y: number(argument))
        case "--dy": options.dy = integer(argument)
        case "--dx": options.dx = integer(argument)
        case "--direction":
            guard let direction = PageScrollDirection(rawValue: value(for: argument)) else {
                fail("--direction must be up, down, left or right", code: 64)
            }
            options.pageDirection = direction
        case "--pages": options.pages = integer(argument)
        case "--": literal = true
        case "-h", "--help": print(usage); exit(0)
        default:
            if options.command.isEmpty { options.command = argument }
            else if argument.hasPrefix("--") { fail("unknown option '\(argument)' (use -- before literal text)", code: 64) }
            else { options.positional.append(argument) }
        }
    }
    guard options.retries >= 0, options.count > 0, (1...1000).contains(options.limit),
          options.maxWidth.map({ $0 > 0 }) ?? true,
          options.pages.map({ (1...PageScrollAction.maximumPages).contains($0) }) ?? true else { fail("numeric options are out of range", code: 64) }
    if options.command != "scroll-page", options.pageDirection != nil || options.pages != nil {
        fail("--direction and --pages require scroll-page", code: 64)
    }
    return options
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    if code == 64 { FileHandle.standardError.write(Data((usage + "\n").utf8)) }
    exit(code)
}

func note(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

func describe(_ state: HelperConnection.State) -> String {
    switch state {
    case .disconnected:
        "· disconnected"
    case .connecting(let attempt, let total):
        "· connecting (attempt \(attempt) of \(total))"
    case .connected(let hello):
        "✓ connected to \(hello.session.user) (uid \(hello.session.uid)), helper \(hello.helperVersion)"
    case .waitingToRetry(let next, let total, let delay, let error):
        "! \(error.description)\n  retrying in \(String(format: "%.1f", delay.inSeconds))s (attempt \(next) of \(total))"
    case .failed(let error):
        "✗ \(error.userMessage)"
    }
}

func printPermissions(_ session: SessionInfo) {
    let p = session.permissions
    func mark(_ ok: Bool) -> String { ok ? "granted" : "MISSING" }
    print("""
    agent session   \(session.user) (uid \(session.uid)), helper pid \(session.pid)
    on console      \(session.onConsole ? "yes (agent session is on screen)" : "no (running in the background)")
    display         \(session.displayWidth)x\(session.displayHeight) points
    permissions     screen recording \(mark(p.screenCapture)), accessibility \(mark(p.accessibility)), post events \(mark(p.postEvent))
    """)
}

func report(_ error: Error) -> Never {
    guard let error = error as? BridgeError else { fail(String(describing: error)) }
    fail("\(error.userMessage)\n  detail: \(error.description)")
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

func printElements(_ elements: [ElementInfo]) {
    for element in elements {
        // Custom AX action names can also contain newlines; quote them along with values.
        func quoted(_ value: String?) -> String {
            guard let value, let data = try? JSONEncoder().encode(value) else { return "null" }
            return String(decoding: data, as: UTF8.self)
        }
        print("\(element.role) name=\(quoted(element.name)) value=\(quoted(element.value)) center=\(element.frame.map { String(describing: $0.center) } ?? "unknown") actions=\(quoted(element.actions.joined(separator: ","))) pid=\(element.pid)")
    }
}

let options = parse()
guard !options.command.isEmpty else { print(usage); exit(64) }
func requireArguments(_ count: Int) {
    guard options.positional.count == count else { fail("\(options.command) needs \(count) positional argument(s)", code: 64) }
}
func pointArguments() -> Point {
    requireArguments(2)
    guard let x = Double(options.positional[0]), let y = Double(options.positional[1]), x.isFinite, y.isFinite else {
        fail("coordinates must be finite numbers", code: 64)
    }
    return Point(x: x, y: y)
}

// Parse the entire action before connecting or making any changes.
let action: InputAction?
switch options.command {
case "click": action = .click(ClickAction(point: pointArguments(), button: options.right ? .right : .left, count: options.double ? 2 : 1))
case "type": requireArguments(1); action = .type(text: options.positional[0])
case "set-text": requireArguments(1); action = .setText(SetTextAction(text: options.positional[0], point: options.at))
case "key":
    requireArguments(1)
    guard let combo = KeyCombo.parse(options.positional[0]) else { fail("invalid key combo", code: 64) }
    action = .key(combo)
case "scroll":
    let point = pointArguments()
    guard let dy = options.dy else { fail("scroll requires --dy", code: 64) }
    action = .scroll(ScrollAction(point: point, deltaX: options.dx, deltaY: dy))
case "scroll-page":
    let point = pointArguments()
    guard let direction = options.pageDirection else { fail("scroll-page requires --direction", code: 64) }
    guard options.dy == nil, options.dx == 0 else { fail("scroll-page uses --direction and --pages instead of wheel deltas", code: 64) }
    action = .scrollPage(PageScrollAction(point: point, direction: direction, pages: options.pages ?? 1))
case "open", "elements": requireArguments(1); action = nil
case "inspect": _ = pointArguments(); action = nil
case "status", "ping", "info", "capture", "watch": requireArguments(0); action = nil
default: fail("unknown command '\(options.command)'", code: 64)
}
if options.verify && action == nil && options.command != "open" { fail("--verify requires an input action or open", code: 64) }

let connection = HelperConnection(configuration: .init(
    socketPath: options.socketPath,
    clientName: "zoop-bridge",
    retry: RetryPolicy(maxRetries: options.retries)))
let states = await connection.stateUpdates()
let stateTask = Task {
    for await state in states { note(describe(state)) }
}

var verification: IsolationVerification?
var verificationPassed = true
var commandError: Error?
do {
    if options.verify {
        let hello = try await connection.connect()
        note("Measuring primary-session isolation; keep mouse and keyboard still until the report.")
        verification = try IsolationVerification(helper: hello.session)
    }
    if let action {
        try printJSON(await connection.perform(action))
    } else {
        switch options.command {
        case "status": printPermissions(try await connection.connect().session)
        case "ping":
            for index in 1...options.count {
                let rtt = try await connection.ping()
                print("ping \(index): \(String(format: "%.2f", rtt.inSeconds * 1000)) ms")
            }
        case "info": try printJSON(await connection.sessionInfo())
        case "inspect": printElements(try await connection.inspect(at: pointArguments()))
        case "elements": printElements(try await connection.elements(ElementQuery(bundleID: options.positional[0], interactiveOnly: !options.all, limit: options.limit)))
        case "open": try printJSON(await connection.openApp(bundleID: options.positional[0]))
        case "capture":
            let frame = try await connection.capture(CaptureOptions(maxPixelWidth: options.maxWidth))
            try FileManager.default.createDirectory(atPath: options.outDirectory, withIntermediateDirectories: true)
            let path = "\(options.outDirectory)/frame-\(Int(Date().timeIntervalSince1970 * 1000)).png"
            try frame.png.write(to: URL(fileURLWithPath: path))
            let m = frame.metadata
            print("\(m.width)x\(m.height) PNG, \(m.pointWidth)x\(m.pointHeight) points, scale \(m.pointWidth / Double(m.width))x\(m.pointHeight / Double(m.height)) points/pixel, \(frame.png.count) bytes, saved \(path)")
        case "watch":
            note("watching; restart or stop the helper to see reconnects. Enter retries after failure. Ctrl-C quits.")
            Task.detached {
                while readLine() != nil {
                    if case .failed = await connection.state { _ = try? await connection.connect() }
                }
            }
            _ = try? await connection.connect()
            try await Task.sleep(for: .seconds(60 * 60 * 24 * 365))
        default: break
        }
    }
} catch { commandError = error }

if let verification {
    // Include events consumed just after the helper reply, including openApp activation.
    try? await Task.sleep(for: .milliseconds(200))
    verificationPassed = verification.finish()
}
await connection.disconnect()
stateTask.cancel()
if let commandError { report(commandError) }
if !verificationPassed { fail("primary-session isolation verification failed") }
