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
  watch               stay connected and print every state change; press Enter to retry after a failure

options:
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
}

func parse() -> Options {
    var options = Options()
    var arguments = CommandLine.arguments.dropFirst().makeIterator()
    func value(for flag: String) -> String {
        guard let value = arguments.next() else { fail("\(flag) needs a value", code: 64) }
        return value
    }
    while let argument = arguments.next() {
        switch argument {
        case "--socket": options.socketPath = value(for: argument)
        case "--retries": options.retries = Int(value(for: argument)) ?? options.retries
        case "-n": options.count = Int(value(for: argument)) ?? options.count
        case "--out": options.outDirectory = value(for: argument)
        case "--max-width": options.maxWidth = Int(value(for: argument))
        case "-h", "--help": print(usage); exit(0)
        default:
            guard options.command.isEmpty, !argument.hasPrefix("-") else { fail("unexpected argument '\(argument)'", code: 64) }
            options.command = argument
        }
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

let options = parse()
guard !options.command.isEmpty else { print(usage); exit(64) }

let connection = HelperConnection(configuration: .init(
    socketPath: options.socketPath,
    clientName: "zoop-bridge",
    retry: RetryPolicy(maxRetries: options.retries)))

// Subscribe before the first command, or the first states are missed.
let states = await connection.stateUpdates()
let stateTask = Task {
    for await state in states { note(describe(state)) }
}

do {
    switch options.command {
    case "status":
        let hello = try await connection.connect()
        printPermissions(hello.session)

    case "ping":
        for index in 1...max(1, options.count) {
            let rtt = try await connection.ping()
            print("ping \(index): \(String(format: "%.2f", rtt.inSeconds * 1000)) ms")
        }

    case "info":
        let session = try await connection.sessionInfo()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(session), as: UTF8.self))

    case "capture":
        let frame = try await connection.capture(CaptureOptions(maxPixelWidth: options.maxWidth))
        try FileManager.default.createDirectory(atPath: options.outDirectory, withIntermediateDirectories: true)
        let path = "\(options.outDirectory)/frame-\(Int(Date().timeIntervalSince1970 * 1000)).png"
        try frame.png.write(to: URL(fileURLWithPath: path))
        print("\(frame.metadata.width)x\(frame.metadata.height) PNG, \(frame.png.count) bytes, saved \(path)")

    case "watch":
        note("watching; restart or stop the helper to see reconnects. Ctrl-C to quit.")
        // Retry on demand: after a failed cycle, Enter starts a new one.
        Task.detached {
            while readLine() != nil {
                if case .failed = await connection.state {
                    _ = try? await connection.connect()
                }
            }
        }
        _ = try? await connection.connect()
        try await Task.sleep(for: .seconds(60 * 60 * 24 * 365))

    default:
        fail("unknown command '\(options.command)'", code: 64)
    }
} catch {
    report(error)
}

await connection.disconnect()
stateTask.cancel()
