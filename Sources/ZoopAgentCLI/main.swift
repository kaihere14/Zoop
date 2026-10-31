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
  trace               summarize logged model calls: tokens, retries, tools per run
      --runs N          how many recent runs to show (default 5)
      --calls           list every model call of those runs
      --file PATH       read another log (default: today's in ~/Zoop/logs)
  plan TASK           inspect read-only and print a proposed executable plan
  run TASK            propose a plan, ask for approval, then execute it
      --approve         approve the displayed task plan (risky-step confirmations still apply)
      --auto            Auto mode: actions the plan lists need no further confirmation
      --no-plan         use the previous free-form executor
      --step TEXT       add a plain-language hint to --no-plan (repeatable)
      --max-steps N     model calls before giving up (default 50)
      --save DIR        save every screenshot the executor takes into DIR
      --keep-apps       leave the agent session's apps open after a successful run
                        (by default every app except Finder is quit)

model options (override env and ~/.zoop/config.json):
  --provider NAME     anthropic, gemini, openrouter, groq, openai, ollama, lmstudio or custom
  --model NAME        model name as the provider spells it
  --base-url URL      endpoint for custom providers
  --planner-provider NAME / --planner-model NAME / --planner-base-url URL
                      optional separate planner; defaults to executor when unconfigured

The executor asks before risky steps; answer on this terminal.
"""

struct Options {
    var command = ""
    var positional: [String] = []
    var steps: [String] = []
    var maxSteps = 50
    var save: String?
    var overrides = ModelConfiguration.Overrides()
    var plannerOverrides = ModelConfiguration.Overrides()
    var approve = false
    var auto = false
    var noPlan = false
    var keepApps = false
    var traceRuns = 5
    var traceCalls = false
    var traceFile: String?

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
        case "--approve": options.approve = true
        case "--auto": options.auto = true
        case "--no-plan": options.noPlan = true
        case "--keep-apps": options.keepApps = true
        case "--planner-provider": options.plannerOverrides.provider = value(argument)
        case "--planner-model": options.plannerOverrides.model = value(argument)
        case "--planner-base-url": options.plannerOverrides.baseURL = value(argument)
        case "--step": options.steps.append(value(argument))
        case "--max-steps":
            guard let n = Int(value(argument)), n > 0 else { fail("--max-steps needs a positive number", code: 64) }
            options.maxSteps = n
        case "--save": options.save = value(argument)
        case "--runs": options.traceRuns = Int(value(argument)) ?? 5
        case "--calls": options.traceCalls = true
        case "--file": options.traceFile = value(argument)
        case "--provider": options.overrides.provider = value(argument)
        case "--model": options.overrides.model = value(argument)
        case "--base-url": options.overrides.baseURL = value(argument)
        case "-h", "--help": print(usage); exit(0)
        default:
            if argument.hasPrefix("--") { fail("unknown option '\(argument)'", code: 64) }
            if options.command.isEmpty { options.command = argument } else { options.positional.append(argument) }
        }
    }
    if options.command == "plan", options.noPlan || options.approve || !options.steps.isEmpty {
        fail("plan is read-only and does not accept --no-plan, --approve or --step", code: 64)
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
    for role in [AgentRole.executor, .planner, .chat] {
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
        let names = try await ModelConfiguration.listModels(endpoint)
        print("\(names.count) models from \(endpoint.provider):")
        for name in names { print("  \(name)") }
    } catch {
        fail("\(error)")
    }

case "trace":
    let file = options.traceFile.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? ModelTrace.file()
    TraceReport.print(file: file, runs: options.traceRuns, detail: options.traceCalls)

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

case "run", "plan":
    guard options.positional.count == 1 else { fail("run needs the task as one quoted argument", code: 64) }
    let model: any ChatModel
    do {
        if options.command == "plan" {
            let specific = options.plannerOverrides
            let hasOverrides = specific.provider != nil || specific.model != nil || specific.baseURL != nil
            model = try configuration.model(for: .planner, overrides: hasOverrides ? specific : options.overrides)
        } else { model = try configuration.model(for: .executor, overrides: options.overrides) }
    } catch { fail("\(error)") }
    if let save = options.save { try? FileManager.default.createDirectory(atPath: save, withIntermediateDirectories: true) }

    let connection = HelperConnection(configuration: .init(clientName: "zoop-agent"))
    let tools = SessionToolbox(connection: connection)
    let prompter = TerminalPrompter()
    let limits = ExecutorLimits(maxSteps: options.maxSteps)
    guard options.noPlan || options.steps.isEmpty else { fail("--step is for --no-plan; structured plans are generated from TASK", code: 64) }
    let plannerModel: any ChatModel
    do {
        // General flags also configure the fallback planner; explicit planner configuration
        // keeps its separate provider/model. No key is printed or copied to the plan.
        let plannerOptions = options.plannerOverrides
        if options.noPlan || options.command == "plan" { plannerModel = model }
        else if plannerOptions.provider == nil && plannerOptions.model == nil && plannerOptions.baseURL == nil,
           ProcessInfo.processInfo.environment["ZOOP_PLANNER_PROVIDER"] == nil,
           ProcessInfo.processInfo.environment["ZOOP_PLANNER_MODEL"] == nil,
           !configuration.hasPlannerConfiguration { plannerModel = model }
        else { plannerModel = try configuration.model(for: .planner, overrides: plannerOptions) }
    } catch { fail("\(error)") }

    let saveDirectory = options.save
    let counter = Counter()

    // Ctrl-C stops between steps instead of killing the process mid-action.
    signal(SIGINT, SIG_IGN)
    let traceContext = TraceContext(label: "cli \(options.command): " + String(options.positional[0].prefix(80)))
    let run = Task { await ModelTrace.$context.withValue(traceContext) {
        let events: @Sendable (AgentEvent) -> Void = { event in
            switch event {
            case .started(let name): print("agent on \(name)")
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
        let executionTools = PermissionToolRunner(tools: tools, permissions: connection, prompter: prompter, onEvent: events)
        if options.noPlan {
            return await ExecutorAgent(model: model, tools: executionTools, prompter: prompter, limits: limits)
                .run(ExecutorTask(request: options.positional[0], plan: options.steps), onEvent: events)
        }
        do {
            print("planning on \(plannerModel.name)")
            let proposed = try await PlannerAgent(model: plannerModel, tools: tools).plan(options.positional[0], onEvent: events)
            print("\nPROPOSED PLAN: \(proposed.plan.title)")
            for (index, step) in proposed.plan.steps.enumerated() {
                print("  \(index + 1). \(step.summary)\(step.requiresConfirmation ? " [confirmation required]" : "")")
                if let tool = step.tool { print("     \(tool.rawValue) \(step.arguments.jsonText)") }
                else { print("     decide: \(step.goal)") }
            }
            print("Planner: \(proposed.modelCalls) calls, \(proposed.usage.inputTokens) input + \(proposed.usage.outputTokens) output tokens")
            if options.command == "plan" {
                return AgentOutcome(status: .completed, summary: "Plan proposed; no actions executed.", steps: proposed.modelCalls, usage: proposed.usage)
            }
            let approved: Bool
            if options.approve { approved = true }
            else { approved = PlanRunner.isApproval(await prompter.ask("Run this plan in the agent session? Reply yes to approve.") ?? "") }
            return await PlanRunner(model: model, tools: executionTools, prompter: prompter, limits: limits)
                .run(proposed.plan, approved: approved, mode: options.auto ? .auto : .ask, onEvent: events)
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            print("\(cancelled ? "CANCELLED" : "FAILED"): \(error)")
            return AgentOutcome(status: cancelled ? .cancelled : .failed, summary: String(describing: error), steps: 0,
                                usage: ModelUsage(inputTokens: 0, outputTokens: 0))
        }
    } }
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler {
        print("\nstopping after the current step…")
        run.cancel()
    }
    interrupt.resume()
    var outcome = await run.value
    if options.command == "run", !options.keepApps, outcome.status == .completed {
        let cleaned = await SessionCleanup.afterTask(outcome, using: connection)
        if cleaned.summary != outcome.summary { print(cleaned.summary.dropFirst(outcome.summary.count).trimmingCharacters(in: .whitespacesAndNewlines)) }
        outcome = cleaned
    }
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
