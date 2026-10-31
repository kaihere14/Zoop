import Foundation
import Observation
import ZoopAgents
import ZoopShared

@MainActor @Observable
final class CompanionStore {
    enum Destination: Equatable { case chat, activities, settings }
    var isExpanded = false
    var destination: Destination = .chat
    var draft = ""
    private(set) var messages: [CompanionMessage] = []
    private(set) var tasks: [CompanionTask] = []
    private(set) var isThinking = false
    private(set) var latestScreenshot: Data?
    private var screenshotTaskID: UUID?
    private(set) var question: CompanionPrompter.Question? {
        didSet {
            if let old = oldValue, old.id != question?.id { notifier?.withdraw(old.id) }
            if let question, question.id != oldValue?.id, !isExpanded { notifier?.post(question, task: workingTask?.title) }
        }
    }
    @ObservationIgnored private var prompter: CompanionPrompter?
    /// Shows questions as macOS notifications while the notch is closed. Set by the app delegate;
    /// tests run without it because notifications need a real app bundle.
    @ObservationIgnored var notifier: QuestionNotifying?
    @ObservationIgnored var onExpandPreview: ((UUID) -> Void)?
    /// The detachable Agent workspace window is open.
    var isPreviewWindowOpen = false
    /// Someone can see the workspace preview, so frames are worth capturing quickly.
    var isWatchingWorkspace: Bool { isPreviewWindowOpen || (isExpanded && destination == .activities) }
    /// The mode chosen on each plan card. Plans start in Ask first; Auto is chosen per plan.
    var approvalModes: [UUID: ApprovalMode] = [:]

    private(set) var soundEnabled = true
    private(set) var streamPositions: [UUID: Int] = [:]
    private(set) var recentlyCompleted: Set<UUID> = []
    var selectedTaskID: UUID?
    var focusRequest = 0
    var notice: String?
    private(set) var completionQueue: [CompanionTask] = []
    private(set) var isCelebrating = false
    @ObservationIgnored private var lastInteraction = Date()
    @ObservationIgnored private var completionPresentation: Task<Void, Never>?

    @ObservationIgnored private let service: any CompanionService
    @ObservationIgnored private let persistence: CompanionPersistence
    @ObservationIgnored private let exports: ExportCoordinator
    @ObservationIgnored private let audio = CompanionAudio()
    private var chatStreams: Set<UUID> = []
    @ObservationIgnored private var planning: Task<Void, Never>?
    @ObservationIgnored private var streams: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var executions: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var dispatches: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var retirements: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation = 0

    init(service: any CompanionService = LiveCompanionService(), persistence: CompanionPersistence = .init(), exports: ExportCoordinator = .init()) {
        self.service = service
        self.persistence = persistence
        self.exports = exports
        do {
            let snapshot = try persistence.load()
            messages = snapshot.messages; tasks = snapshot.tasks; soundEnabled = snapshot.soundEnabled
        } catch { notice = "Saved chat couldn’t be restored. You can start a new conversation." }
    }

    var liveTasks: [CompanionTask] { tasks.filter { $0.phase.isLive } }
    var activityTabs: [CompanionTask] { tasks.filter { $0.phase.isLive || recentlyCompleted.contains($0.id) } }
    var workingTask: CompanionTask? { tasks.first { $0.phase == .running || $0.phase == .dispatching } }
    var workingTaskCount: Int { tasks.filter { $0.phase == .running || $0.phase == .dispatching }.count }
    var completionAlert: CompanionTask? { completionQueue.first }
    var isResponding: Bool { isThinking || !streamPositions.isEmpty || workingTask != nil }
    var mood: CompanionMood { isCelebrating ? .done : workingTask != nil ? .cooking : isThinking || !chatStreams.isEmpty ? .thinking : .sleeping }
    var compactStatus: String {
        if workingTask != nil { return question == nil ? "working" : "needs you" }
        if isThinking { return "thinking" }
        if !chatStreams.isEmpty { return "writing" }
        return liveTasks.isEmpty ? "idling" : "paused"
    }
    var status: String {
        if let task = workingTask { return task.statusNote ?? compactStatus }
        return compactStatus
    }
    var activityTask: CompanionTask? {
        tasks.first { $0.id == selectedTaskID && ($0.phase.isLive || $0.phase == .complete || $0.phase == .failed) }
            ?? liveTasks.last ?? tasks.last { $0.phase == .complete || $0.phase == .failed }
    }

    func task(_ id: UUID?) -> CompanionTask? { tasks.first { $0.id == id } }
    func screenshot(for id: UUID) -> Data? { screenshotTaskID == id ? latestScreenshot : nil }
    func expandPreview(for id: UUID) {
        guard task(id) != nil else { return }
        onExpandPreview?(id)
    }
    func openChat() { destination = .chat; isExpanded = true; focusRequest += 1 }
    func toggle() { isExpanded.toggle() }
    func toggleSound() { soundEnabled.toggle(); if !soundEnabled { audio.stopVoice() }; persist() }
    func recordInteraction() { lastInteraction = Date() }

    func openCompletedTask(_ id: UUID) {
        selectedTaskID = id; destination = .activities; isExpanded = true
        dismissCompletionAlerts()
    }

    func dismissCompletionAlerts() {
        completionPresentation?.cancel(); completionPresentation = nil
        completionQueue = []; isCelebrating = false; audio.stopVoice()
    }

    func dismissCurrentCompletion() {
        completionPresentation?.cancel(); completionPresentation = nil
        audio.stopVoice(); isCelebrating = false
        if !completionQueue.isEmpty { completionQueue.removeFirst() }
        presentNextCompletion()
    }

    private func presentNextCompletion() {
        guard completionPresentation == nil, !completionQueue.isEmpty else { return }
        isCelebrating = true
        let duration = soundEnabled ? audio.completion { [weak self] playing in
            self?.isCelebrating = playing
        } : 1.8
        // Starting a new voice first stops the previous one; keep the silent fallback cheerful too.
        isCelebrating = true
        completionPresentation = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
                guard let self else { return }
                if !self.audio.isSpeaking { self.isCelebrating = false }
                try await Task.sleep(for: .seconds(max(0, 7 - duration)))
                self.completionPresentation = nil
                if !self.completionQueue.isEmpty { self.completionQueue.removeFirst() }
                self.presentNextCompletion()
            } catch { /* Opening, dismissal, reset, and shutdown cancel the alert. */ }
        }
    }

    func send(_ request: String? = nil) {
        let text = (request ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        if let command = ChatCommand.parse(text) {
            draft = ""
            run(command)
            return
        }
        guard !text.isEmpty, !isResponding else { return }
        draft = ""
        messages.append(.init(role: .user, text: String(text.prefix(1_200))))
        isThinking = true
        persist()
        let requestGeneration = generation
        planning = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let pending = tasks.last { $0.phase == .pending }
                // Local command output such as /help is UI only, so it is not sent to the model.
                let history = messages.filter { $0.text != ChatCommand.helpText }
                let reply = try await service.respond(to: history, pendingPlan: pending?.executablePlan)
                try Task.checkCancellation()
                guard self.generation == requestGeneration else { return }
                isThinking = false
                if let plan = reply.plan {
                    try plan.validate()
                    if let index = tasks.firstIndex(where: { $0.id == pending?.id }) { tasks[index].apply(.stop) }
                    let id = UUID()
                    let task = CompanionTask(id: id, request: plan.request, title: plan.title, domain: "Agent workspace",
                        fileName: "zoop-result-\(id.uuidString.prefix(8).lowercased()).md",
                        steps: plan.steps.map(\.summary), kind: .tools, executablePlan: plan)
                    tasks.append(task)
                    stream(.init(role: .assistant, text: reply.text, taskID: id))
                } else {
                    stream(.init(role: .assistant, text: reply.text))
                }
                persist()
            } catch is CancellationError { if self.generation == requestGeneration { isThinking = false } }
            catch {
                if self.generation == requestGeneration {
                    isThinking = false
                    notice = "The response could not be prepared. Check model and helper settings."
                    stream(.init(role: .assistant, text: "I couldn’t prepare a response: \(error)"))
                }
            }
        }
    }

    /// Commands never reach the model. `/clear` uses the same reset as the clear button, so the
    /// erased state is also saved to disk and stays empty after a restart.
    private func run(_ command: ChatCommand.Parsed) {
        switch command {
        case .command(.clear): reset()
        case .command(.help): stream(.init(role: .assistant, text: ChatCommand.helpText), wake: false)
        case .unknown(let name): notice = "Unknown command \(name). Type /help to see the commands."
        }
    }

    func displayedText(_ message: CompanionMessage) -> String {
        String(message.text.prefix(streamPositions[message.id] ?? message.text.count))
    }
    func textIsComplete(_ message: CompanionMessage) -> Bool { (streamPositions[message.id] ?? Int.max) >= message.text.count }
    func displayedStep(_ step: String, index: Int, message: CompanionMessage, task: CompanionTask) -> String {
        guard let position = streamPositions[message.id] else { return step }
        let preceding = task.steps.prefix(index).reduce(0) { $0 + $1.count + 1 }
        return String(step.prefix(max(0, position - message.text.count - preceding)))
    }

    private func stream(_ message: CompanionMessage, wake: Bool = true) {
        messages.append(message)
        streamPositions[message.id] = 0
        if wake { chatStreams.insert(message.id) }
        let planLength = task(message.taskID)?.steps.joined(separator: "\n").count ?? 0
        let total = message.text.count + planLength
        streams[message.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                while let position = streamPositions[message.id], position < total {
                    try await Task.sleep(for: .milliseconds(26))
                    streamPositions[message.id] = min(total, position + 3)
                }
                streamPositions.removeValue(forKey: message.id)
                chatStreams.remove(message.id)
                streams.removeValue(forKey: message.id)
                persist()
            } catch { /* Reset or shutdown intentionally stops streaming. */ }
        }
    }

    @discardableResult
    func approve(_ id: UUID) -> Bool {
        guard workingTask == nil else { return false }
        guard task(id)?.executablePlan != nil else {
            notice = "This older preview plan cannot execute. Send a new request to prepare a live plan."
            return false
        }
        guard !messages.contains(where: { $0.taskID == id && streamPositions[$0.id] != nil }),
              let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].apply(.approve) else { return false }
        if soundEnabled { audio.chime() }
        persist()
        // Approval remains valid if the drawer closes during the ticket flight.
        dispatches[id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(950)); self?.finishDispatch(id) } catch {}
        }
        return true
    }

    func finishDispatch(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].apply(.arrive) else { return }
        dispatches.removeValue(forKey: id)?.cancel()
        selectedTaskID = id
        persist()
        execute(id)
    }

    /// Opens the task whose question is waiting, for example after a notification is clicked.
    func showQuestion() {
        if let task = workingTask { selectedTaskID = task.id }
        destination = .activities; isExpanded = true
    }

    /// An answer from a notification: only the question it was posted for is answered.
    func answerQuestion(_ id: UUID, text: String) {
        guard question?.id == id else { return }
        answerQuestion(text)
    }

    func answerPermission(_ id: UUID, choiceID: String) {
        guard let question, question.id == id,
              question.permission?.choices.contains(where: { $0.id == choiceID }) == true else { return }
        answerQuestion(choiceID)
    }

    func answerQuestion(_ text: String) {
        guard let question, let prompter, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { await prompter.answer(question.id, text: text) }
    }

    private func execute(_ id: UUID) {
        guard executions.isEmpty, let plan = task(id)?.executablePlan else { return }
        latestScreenshot = nil; screenshotTaskID = id
        let requestGeneration = generation
        let input = CompanionPrompter { [weak self] question in
            Task { @MainActor [weak self] in
                guard let self, self.generation == requestGeneration else { return }
                self.question = question
            }
        }
        prompter = input
        executions[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            let (events, sink) = AsyncStream.makeStream(of: AgentEvent.self)
            let consumer = Task { @MainActor [weak self] in
                for await event in events {
                    guard let self, self.generation == requestGeneration,
                          let index = self.tasks.firstIndex(where: { $0.id == id }), self.tasks[index].phase == .running else { continue }
                    switch event {
                    case .progress(let note, _, let percent): self.tasks[index].updateExecution(note: note, percent: percent)
                    case .toolFinished(_, let result):
                        if let image = result.image { self.latestScreenshot = image.data }
                    default: break
                    }
                }
            }
            // Live preview: about 8 frames per second while someone is watching, and an occasional
            // frame otherwise so the notch thumbnail stays current.
            let feed = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let watching = self.isWatchingWorkspace
                    let service = self.service
                    if let frame = await service.previewFrame(), !Task.isCancelled, self.screenshotTaskID == id { self.latestScreenshot = frame }
                    try? await Task.sleep(for: .milliseconds(watching ? 60 : 1000))
                }
            }
            let outcome = await service.execute(plan, mode: approvalModes[id] ?? .ask, prompter: input) { sink.yield($0) }
            feed.cancel()
            sink.finish()
            await consumer.value
            guard self.generation == requestGeneration, !Task.isCancelled,
                  let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].phase == .running else {
                executions.removeValue(forKey: id)
                return
            }
            question = nil; prompter = nil
            if outcome.status == .cancelled {
                tasks[index].apply(.stop)
                stream(.init(role: .assistant, text: outcome.summary), wake: false)
            } else {
                tasks[index].finishExecution(success: outcome.status == .completed, summary: outcome.summary, report: outcome.report)
                if outcome.status == .completed { finish(tasks[index]) }
                else {
                    stream(.init(role: .assistant, text: outcome.summary, taskID: id), wake: false)
                    notice = "The task could not finish. Review the result and send a new request if needed."
                }
            }
            persist()
            executions.removeValue(forKey: id)
        }
    }

    private func finish(_ task: CompanionTask) {
        recentlyCompleted.insert(task.id)
        if selectedTaskID == task.id, let next = liveTasks.last { selectedTaskID = next.id }
        let text: String
        do {
            _ = try exports.write(task)
            text = "\(task.resultSummary ?? "Done.")\n\nSaved the result to ~/Zoop/exports/\(task.fileName)."
        } catch {
            text = "\(task.resultSummary ?? "Done.")\n\nI couldn’t write the result to the exports folder. Use Save report in Live Activities."
            notice = "Automatic export failed. Use Save report to choose a folder."
        }
        stream(.init(role: .assistant, text: text), wake: false)
        if !isExpanded || Date().timeIntervalSince(lastInteraction) >= 15 {
            completionQueue.append(task)
            presentNextCompletion()
        }
        retirements[task.id] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(600))
                self?.recentlyCompleted.remove(task.id)
                self?.retirements.removeValue(forKey: task.id)
            } catch {}
        }
        persist()
    }

    func saveReport(_ task: CompanionTask) {
        exports.saveAs(task) { [weak self] error in
            if error != nil { self?.notice = "The report couldn’t be saved. Try a different folder." }
        }
    }

    func revealExports() {
        do { try exports.revealExports() } catch { notice = "The exports folder couldn’t be opened." }
    }

    func reset() {
        guard workingTask == nil else { notice = "Wait for the current task to finish before clearing the conversation."; return }
        cancelWork()
        messages = []; tasks = []; streamPositions = [:]; chatStreams = []; recentlyCompleted = []
        draft = ""; isThinking = false; selectedTaskID = nil; notice = nil; destination = .chat; latestScreenshot = nil; question = nil
        persist()
    }

    func shutdown() {
        cancelWork(); persist(); audio.stop()
        if let browser { Task { await browser.shutdown() } }
    }

    /// Zoop's Playwright browser, when Node.js is available.
    var browser: BrowserSession? { (service as? LiveCompanionService)?.browser }
    private(set) var isBrowserSigningIn = false

    /// Opens or closes the visible sign-in window that shares the task browser's profile.
    func toggleBrowserSignIn() {
        guard let browser else {
            notice = "Install Node.js (brew install node) to let Zoop use a browser."
            return
        }
        let opening = !isBrowserSigningIn
        isBrowserSigningIn = opening
        Task { @MainActor [weak self] in
            if opening {
                do { try await browser.openSignInWindow() } catch {
                    self?.isBrowserSigningIn = false
                    self?.notice = "Could not open the sign-in window: \(error)"
                }
            } else {
                await browser.closeSignInWindow()
            }
        }
    }

    private func cancelWork() {
        dismissCompletionAlerts()
        generation += 1
        question = nil; prompter = nil
        planning?.cancel(); planning = nil
        for task in Array(streams.values) + Array(executions.values) + Array(dispatches.values) + Array(retirements.values) { task.cancel() }
        streams = [:]; executions = [:]; dispatches = [:]; retirements = [:]
    }

    private func persist() {
        do {
            try persistence.save(.init(messages: Array(messages.suffix(120)), tasks: Array(tasks.suffix(40)), soundEnabled: soundEnabled))
        } catch { notice = "Chat couldn’t be saved on this Mac. This session still works." }
    }
}
