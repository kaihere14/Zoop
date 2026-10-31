import Foundation
import Observation
import ZoopAgents
import ZoopShared

@MainActor @Observable
final class CompanionStore {
    enum Destination: Equatable { case chat, activities }
    var isExpanded = false
    var destination: Destination = .chat
    var draft = ""
    private(set) var messages: [CompanionMessage] = []
    private(set) var tasks: [CompanionTask] = []
    private(set) var isThinking = false
    private(set) var soundEnabled = true
    private(set) var streamPositions: [UUID: Int] = [:]
    private(set) var recentlyCompleted: Set<UUID> = []
    var selectedTaskID: UUID?
    var focusRequest = 0
    var notice: String?

    @ObservationIgnored private let service: any CompanionService
    @ObservationIgnored private let persistence: CompanionPersistence
    @ObservationIgnored private let exports = ExportCoordinator()
    @ObservationIgnored private let audio = CompanionAudio()
    private var chatStreams: Set<UUID> = []
    @ObservationIgnored private var planning: Task<Void, Never>?
    @ObservationIgnored private var streams: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var executions: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var dispatches: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var retirements: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation = 0

    init(service: any CompanionService = DemoCompanionService(), persistence: CompanionPersistence = .init()) {
        self.service = service
        self.persistence = persistence
        do {
            let snapshot = try persistence.load()
            messages = snapshot.messages; tasks = snapshot.tasks; soundEnabled = snapshot.soundEnabled
        } catch { notice = "Saved chat couldn’t be restored. You can start a new conversation." }
    }

    var liveTasks: [CompanionTask] { tasks.filter { $0.phase.isLive } }
    var activityTabs: [CompanionTask] { tasks.filter { $0.phase.isLive || recentlyCompleted.contains($0.id) } }
    var workingTask: CompanionTask? { tasks.first { $0.phase == .running || $0.phase == .dispatching } }
    var isResponding: Bool { isThinking || !streamPositions.isEmpty }
    var mood: CompanionMood { workingTask != nil ? .cooking : isThinking || !chatStreams.isEmpty ? .thinking : .sleeping }
    var compactStatus: String {
        if let task = workingTask { return task.progress < 28 ? "searching" : "cooking" }
        if isThinking { return "thinking" }
        if !chatStreams.isEmpty { return "writing" }
        return liveTasks.isEmpty ? "idling" : "paused"
    }
    var status: String {
        if let task = workingTask { return "\(compactStatus): \(task.domain.components(separatedBy: " · ")[0])" }
        return compactStatus
    }
    var activityTask: CompanionTask? {
        tasks.first { $0.id == selectedTaskID && ($0.phase.isLive || $0.phase == .complete) }
            ?? liveTasks.last ?? tasks.last { $0.phase == .complete }
    }

    func task(_ id: UUID?) -> CompanionTask? { tasks.first { $0.id == id } }
    func openChat() { destination = .chat; isExpanded = true; focusRequest += 1 }
    func toggle() { isExpanded.toggle() }
    func toggleSound() { soundEnabled.toggle(); persist() }

    func send(_ request: String? = nil) {
        let text = (request ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding else { return }
        draft = ""
        messages.append(.init(role: .user, text: String(text.prefix(1_200))))
        isThinking = true
        persist()
        let requestGeneration = generation
        planning = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let normalized = text.lowercased().trimmingCharacters(in: .punctuationCharacters)
                if ["hi", "hello", "hey", "thanks", "thank you", "help", "what can you do"].contains(normalized) {
                    try await Task.sleep(for: .milliseconds(650))
                    try Task.checkCancellation()
                    guard self.generation == requestGeneration else { return }
                    isThinking = false
                    stream(.init(role: .assistant, text: "Hey, I’m Zoop. Give me a little research, a comparison, or a trip to plan. I’ll show you my plan before I start. This native UI preview uses sample data."))
                } else {
                    let pending = tasks.last { $0.phase == .pending }
                    let refinement = pending != nil && ["also", "only", "make", "keep", "under", "include", "instead", "focus", "actually", "change", "budget"].contains { normalized.hasPrefix($0) }
                    let plan = try await service.propose(request: text, context: refinement ? pending : nil)
                    try Task.checkCancellation()
                    guard self.generation == requestGeneration else { return }
                    if refinement, let index = tasks.firstIndex(where: { $0.id == pending?.id }) { tasks[index].apply(.stop) }
                    tasks.append(plan)
                    isThinking = false
                    stream(.init(role: .assistant, text: refinement ? "Got it. I’ve adjusted the plan with that in mind. Here’s what I’ll do:" : "Of course. I’ll take a look in my own little workspace, while you keep doing your thing. Here’s the plan:", taskID: plan.id))
                }
                persist()
            } catch is CancellationError { if self.generation == requestGeneration { isThinking = false } }
            catch {
                if self.generation == requestGeneration {
                    isThinking = false
                    notice = "The plan couldn’t be prepared. Try again."
                }
            }
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

    func control(_ id: UUID, _ action: TaskAction) {
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].apply(action) else { return }
        if tasks[index].phase == .cancelled {
            executions.removeValue(forKey: id)?.cancel()
            dispatches.removeValue(forKey: id)?.cancel()
        }
        if case .resume = action, executions[id] == nil { execute(id) }
        persist()
    }

    private func execute(_ id: UUID) {
        executions[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                while let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].phase.isLive {
                    try Task.checkCancellation()
                    if tasks[index].phase == .paused {
                        try await Task.sleep(for: .milliseconds(200))
                        continue
                    }
                    let amount = try await service.nextProgressIncrement()
                    try Task.checkCancellation()
                    guard let current = tasks.firstIndex(where: { $0.id == id }) else { break }
                    tasks[current].advance(by: amount)
                    persist()
                    if tasks[current].phase == .complete { finish(tasks[current]); break }
                }
            } catch is CancellationError { /* A stopped task must never complete or export. */ }
            catch {
                control(id, .pause)
                notice = "The task paused after an error. You can resume or stop it."
            }
            executions.removeValue(forKey: id)
        }
    }

    private func finish(_ task: CompanionTask) {
        recentlyCompleted.insert(task.id)
        if selectedTaskID == task.id, let next = liveTasks.last { selectedTaskID = next.id }
        let text: String
        do {
            _ = try exports.write(task)
            text = "All done! I saved your sample comparison to ~/Zoop/exports/\(task.fileName). You can find it in your exports folder or save another copy from Live Activities."
        } catch {
            text = "Your comparison is ready. I couldn’t write to the exports folder, but you can choose a destination with Save report in Live Activities."
            notice = "Automatic export failed. Use Save report to choose a folder."
        }
        stream(.init(role: .assistant, text: text), wake: false)
        if soundEnabled { audio.chime() }
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
        cancelWork()
        messages = []; tasks = []; streamPositions = [:]; chatStreams = []; recentlyCompleted = []
        draft = ""; isThinking = false; selectedTaskID = nil; notice = nil; destination = .chat
        persist()
    }

    func shutdown() { cancelWork(); persist(); audio.stop() }

    private func cancelWork() {
        generation += 1
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
