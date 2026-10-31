import Foundation
import ZoopAgents
import ZoopShared

// zoop-agent: runs Zoop's agents from a terminal, against the real agent session.

let usage = """
usage: zoop-agent <command> [options]

commands:
  config              show which provider and model each agent resolves to (keys hidden)
  models              list the model names your provider and key offer
  hello               send one short request to check the provider, key and model
  run TASK            let the executor carry out TASK in the agent session
      --step TEXT       add a plan step (repeatable); without steps the executor plans itself
      --max-steps N     model calls before giving up (default 50)
      --save DIR        save every screenshot the executor takes into DIR

model options (override env and ~/.zoop/config.json):
  --provider NAME     gemini, openrouter, groq, openai, ollama, lmstudio or custom
  --model NAME        model name as the provider spells it
  --base-url URL      endpoint for custom providers

The executor asks before risky steps; answer on this terminal.
"""

struct Options {
    var command = ""
    var positional: [String] = []
    var steps: [String] = []
    var maxSteps = 50
    var save: String?
    var overrides = ModelConfiguration.Overrides()
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    if code == 64 { FileHandle.standardError.write(Data((usage + "\n").utf8)) }
    exit(code)
}

func parse() -> Options {
    var options = Options()
    var arguments = CommandLine.arguments.dropFirst().makeIterator()
    func value(_ flag: String) -> String {
        guard let value = arguments.next() else { fail("\(flag) needs a value", code: 64) }
        return value
    }
    while let argument = arguments.next() {
        switch argument {
        case "--step": options.steps.append(value(argument))
        case "--max-steps":
            guard let n = Int(value(argument)), n > 0 else { fail("--max-steps needs a positive number", code: 64) }
            options.maxSteps = n
        case "--save": options.save = value(argument)
        case "--provider": options.overrides.provider = value(argument)
        case "--model": options.overrides.model = value(argument)
        case "--base-url": options.overrides.baseURL = value(argument)
        case "-h", "--help": print(usage); exit(0)
        default:
            if argument.hasPrefix("--") { fail("unknown option '\(argument)'", code: 64) }
            if options.command.isEmpty { options.command = argument } else { options.positional.append(argument) }
        }
    }
    return options
}

/// Reads answers to the executor's questions from this terminal.
struct TerminalPrompter: UserPrompting {
    func ask(_ question: String) async -> String? {
        print("\n?  \(question)")
        print("   answer> ", terminator: "")
        fflush(stdout)
        return readLine()
    }
}

func short(_ text: String, _ limit: Int = 220) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ")
    return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
}

let options = parse()
let configuration = ModelConfiguration()

switch options.command {
case "config":
    print("config file: \(ModelConfiguration.configPath())")
    for role in [AgentRole.executor, .chat] {
        do {
            let endpoint = try configuration.endpoint(for: role, overrides: options.overrides)
            print("\(role.rawValue): \(endpoint.provider) / \(endpoint.model) at \(endpoint.baseURL.absoluteString), key \(endpoint.apiKey?.isEmpty == false ? "set" : "none")")
        } catch {
            print("\(role.rawValue): \(error)")
        }
    }

case "models":
    do {
        let endpoint = try configuration.endpoint(for: .executor, overrides: options.overrides, requireModel: false)
        let names = try await OpenAICompatibleModel.listModels(endpoint)
        print("\(names.count) models from \(endpoint.provider):")
        for name in names { print("  \(name)") }
    } catch {
        fail("\(error)")
    }

case "hello":
    do {
        let model = try configuration.model(for: .executor, overrides: options.overrides)
        print("asking \(model.name)…")
        let response = try await model.complete(ModelRequest(system: "You are a connectivity check.",
                                                             messages: [.user("Reply with exactly: OK")]))
        print("reply: \(response.message.text)")
        if let usage = response.usage { print("tokens: \(usage.inputTokens) in, \(usage.outputTokens) out") }
    } catch {
        fail("\(error)")
    }

case "run":
    guard options.positional.count == 1 else { fail("run needs the task as one quoted argument", code: 64) }
    let model: any ChatModel
    do { model = try configuration.model(for: .executor, overrides: options.overrides) } catch { fail("\(error)") }
    if let save = options.save { try? FileManager.default.createDirectory(atPath: save, withIntermediateDirectories: true) }

    let connection = HelperConnection(configuration: .init(clientName: "zoop-agent"))
    let agent = ExecutorAgent(model: model, tools: SessionToolbox(connection: connection), prompter: TerminalPrompter(),
                              limits: ExecutorLimits(maxSteps: options.maxSteps))
    let saveDirectory = options.save
    let counter = Counter()

    // Ctrl-C stops between steps instead of killing the process mid-action.
    signal(SIGINT, SIG_IGN)
    let run = Task {
        await agent.run(ExecutorTask(request: options.positional[0], plan: options.steps)) { event in
            switch event {
            case .started(let name): print("executor on \(name)")
            case .step(let number): print("\n[model call \(number)]")
            case .thought(let text): print("\n·  \(short(text, 400))")
            case .toolStarted(let name, let arguments): print("→  \(name) \(short(arguments, 160))")
            case .toolFinished(_, let result):
                print("   \(result.isError ? "✗" : "✓") \(short(result.text))")
                if let image = result.image, let directory = saveDirectory {
                    let path = "\(directory)/step-\(String(format: "%03d", counter.next())).png"
                    try? image.data.write(to: URL(fileURLWithPath: path))
                    print("   saved \(path)")
                }
            case .progress(let note, let step, let percent):
                print("◆  \(step.map { "step \($0): " } ?? "")\(note)\(percent.map { " (\($0)%)" } ?? "")")
            case .question: break   // The prompter prints it.
            case .answer(let answer): print("   answered: \(answer.isEmpty ? "(none)" : answer)")
            case .usage: break
            case .finished(let outcome):
                print("\n\(outcome.status.rawValue.uppercased()) after \(outcome.steps) steps, \(outcome.usage.inputTokens) input + \(outcome.usage.outputTokens) output tokens")
                print(outcome.summary)
                if let report = outcome.report { print("\n--- report ---\n\(report)") }
            }
        }
    }
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler {
        print("\nstopping after the current step…")
        run.cancel()
    }
    interrupt.resume()
    let outcome = await run.value
    await connection.disconnect()
    exit(outcome.status == .completed ? 0 : 1)

case "":
    print(usage)
default:
    fail("unknown command '\(options.command)'", code: 64)
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}
