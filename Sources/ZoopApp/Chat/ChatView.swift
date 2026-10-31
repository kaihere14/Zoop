import SwiftUI
import ZoopShared
import ZoopAgents

struct ChatView: View {
    @Bindable var store: CompanionStore
    let onStart: (UUID) -> Void
    @State private var pinned = true
    @State private var userScrolling = false
    @State private var followTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if store.messages.isEmpty { welcome.frame(maxHeight: .infinity) }
            else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(store.messages) { message in MessageRow(store: store, message: message, onStart: onStart) }
                            if store.isThinking {
                                HStack(spacing: 8) { SearchingOrb(active: true); Text("Thinking it through").font(.system(size: 10)).foregroundStyle(ZoopTheme.secondary) }
                            }
                            Color.clear.frame(height: 1).id("latest-message")
                        }
                        .padding(.top, 16).padding(.bottom, 12).padding(.trailing, 3)
                    }
                    .scrollIndicators(.hidden)
                    .defaultScrollAnchor(.bottom)
                    .onScrollPhaseChange { _, phase, context in
                        switch phase {
                        case .tracking, .interacting, .decelerating:
                            userScrolling = true
                            followTask?.cancel(); followTask = nil
                            pinned = isNearBottom(context.geometry)
                        case .idle:
                            if userScrolling {
                                pinned = isNearBottom(context.geometry)
                                userScrolling = false
                                followLatest(using: reader)
                            }
                        case .animating:
                            // Programmatic scrolling must not change the user's follow choice.
                            break
                        @unknown default: break
                        }
                    }
                    .onScrollGeometryChange(for: Bool.self) { isNearBottom($0) } action: { _, nearBottom in
                        // Content growth alone must never switch auto-follow off.
                        if userScrolling { pinned = nearBottom }
                    }
                    .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, _ in
                        // Runs after layout, including streamed text and growing plan cards.
                        followLatest(using: reader)
                    }
                    .onAppear {
                        pinned = true; userScrolling = false
                        followLatest(using: reader, animated: false)
                    }
                    .onChange(of: store.messages.count) { followLatest(using: reader) }
                    .onChange(of: store.isThinking) { followLatest(using: reader) }
                    .onDisappear { followTask?.cancel(); followTask = nil }
                }
            }
            composer
        }
        .onChange(of: store.focusRequest) { inputFocused = true }
        .task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            inputFocused = true
        }
    }

    private func isNearBottom(_ geometry: ScrollGeometry) -> Bool {
        geometry.contentSize.height - geometry.visibleRect.maxY < 24
    }

    private func followLatest(using reader: ScrollViewProxy, animated: Bool = true) {
        guard pinned, !userScrolling, followTask == nil else { return }
        // Coalesce updates and let the new text/plan height settle. This throttles instead
        // of cancelling/restarting a debounce on every streamed character.
        followTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(40)) }
            catch { return }
            followTask = nil
            guard pinned, !userScrolling else { return }
            withAnimation(animated && !reduceMotion ? .easeOut(duration: 0.16) : nil) {
                reader.scrollTo("latest-message", anchor: .bottom)
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 12) {
            ZoopMascot(mood: .sleeping, size: 52).padding(.bottom, 3)
            VStack(spacing: 1) {
                Text("A little help.").foregroundStyle(ZoopTheme.text)
                Text("A lot more headspace.").foregroundStyle(ZoopTheme.secondary)
            }.font(.system(size: 29, weight: .regular)).tracking(-0.9)
            Text("Hand me the busywork. Make room for your thing.")
                .font(.system(size: 11)).foregroundStyle(ZoopTheme.secondary)
            HStack(spacing: 8) {
                suggestion("keyboard", "Find my next keyboard", "Research mechanical keyboards on RTINGS and compare prices under $200.")
                suggestion("map", "Plan a weekend away", "Find a quiet weekend getaway near San Francisco and compare three places to stay.")
                suggestion("magnifyingglass", "Research an idea", "Research productivity tools for a small design studio and make a comparison.")
            }.padding(.top, 12)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func suggestion(_ icon: String, _ label: String, _ request: String) -> some View {
        Button { pinned = true; store.send(request) } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(ZoopTheme.lime.opacity(0.65))
                Text(label).lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(ZoopTheme.secondary)
            }.font(.system(size: 10)).padding(.vertical, 7).frame(maxWidth: .infinity)
        }.buttonStyle(GlassButtonStyle())
    }

    private var composer: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 15)).foregroundStyle(ZoopTheme.secondary)
                TextField("What can I take off your plate?", text: $store.draft)
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(ZoopTheme.text)
                    .focused($inputFocused)
                    .disabled(store.workingTask != nil)
                    .onSubmit { pinned = true; submit() }
                    .onKeyPress(.tab) {
                        guard let first = commandSuggestions.first else { return .ignored }
                        store.draft = first.name
                        return .handled
                    }
                    .onChange(of: store.draft) { if store.draft.count > 1_200 { store.draft = String(store.draft.prefix(1_200)) } }
                Text("⌘ K").font(.system(size: 9, design: .monospaced)).foregroundStyle(ZoopTheme.secondary.opacity(0.7))
                Button { pinned = true; submit() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.75)).frame(width: 31, height: 31)
                        .background(ZoopTheme.lime.opacity(sendDisabled ? 0.3 : 1), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(sendDisabled)
                .accessibilityLabel("Send message")
            }
            .padding(.leading, 15).padding(.trailing, 7).frame(height: 47)
            .background(.white.opacity(0.035), in: Capsule())
            .overlay(Capsule().strokeBorder(inputFocused ? ZoopTheme.lime.opacity(0.3) : .white.opacity(0.1), lineWidth: 1))
            // The menu floats above the input so the messages don't jump. A zero-height frame pinned to
            // the input's top edge, with the menu aligned to its bottom, makes the menu grow upward from there.
            .overlay(alignment: .topLeading) {
                if !commandSuggestions.isEmpty {
                    commandMenu
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                        .frame(height: 0, alignment: .bottom)
                        .transition(reduceMotion ? .opacity : .offset(y: 6).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: commandSuggestions)
            HStack {
                Circle().fill(ZoopTheme.lime.opacity(0.7)).frame(width: 3, height: 3)
                Text("Your cursor stays yours.")
                Spacer()
                Text(store.workingTask == nil ? "Chat or give me a task" : "One task in progress")
            }.font(.system(size: 8)).foregroundStyle(ZoopTheme.secondary).padding(.horizontal, 12)
        }.padding(.top, 6).padding(.bottom, 15)
    }
}

private extension ChatView {
    var commandSuggestions: [ChatCommand] { ChatCommand.suggestions(for: store.draft) }

    /// Commands still work while a reply streams; normal messages wait for it to finish.
    var sendDisabled: Bool {
        let text = store.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || (store.isResponding && ChatCommand.parse(text) == nil)
    }

    /// Enter on a partly typed command such as `/cl` runs the only matching command.
    func submit() {
        let matches = commandSuggestions
        if matches.count == 1, let match = matches.first, store.draft.lowercased() != match.name {
            store.send(match.name)
        } else {
            store.send()
        }
    }

    var commandMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(commandSuggestions) { command in
                Button { pinned = true; store.send(command.name) } label: {
                    HStack(spacing: 10) {
                        Text(command.name).font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(ZoopTheme.lime)
                        Text(command.summary).font(.system(size: 10)).foregroundStyle(ZoopTheme.secondary)
                        Spacer(minLength: 12)
                        if command == commandSuggestions.first {
                            Text("tab").font(.system(size: 8, design: .monospaced)).foregroundStyle(ZoopTheme.secondary.opacity(0.7))
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(command.name): \(command.summary)")
            }
        }
        .padding(4)
        .frame(width: 300, alignment: .leading)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }
}

private struct MessageRow: View {
    @Bindable var store: CompanionStore
    let message: CompanionMessage
    let onStart: (UUID) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .user { Spacer(minLength: 80) }
            else {
                ZoopMascot(mood: store.task(message.taskID)?.phase == .complete ? .done : .idle, size: 25)
                    .padding(4).background(ZoopTheme.lime.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(ZoopTheme.lime.opacity(0.08), lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 7) {
                if message.role == .assistant {
                    HStack(spacing: 7) {
                        Text("Zoop").font(.system(size: 10, weight: .semibold)).foregroundStyle(ZoopTheme.text)
                        Text("your extra pair of hands").font(.system(size: 8)).foregroundStyle(ZoopTheme.secondary.opacity(0.7))
                        if store.streamPositions[message.id] != nil { SearchingOrb(active: true, size: 15) }
                    }
                }
                Text(store.displayedText(message)).textSelection(.enabled)
                    .font(.system(size: 12)).lineSpacing(5).foregroundStyle(ZoopTheme.text.opacity(0.83))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let task = store.task(message.taskID), store.textIsComplete(message) {
                    PlanCard(store: store, message: message, task: task, onStart: onStart)
                }
            }
            .padding(message.role == .user ? 11 : 0)
            .background(message.role == .user ? Color.white.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityElement(children: .contain)
    }
}

private struct PlanCard: View {
    @Bindable var store: CompanionStore
    let message: CompanionMessage
    let task: CompanionTask
    let onStart: (UUID) -> Void

    private var streaming: Bool { store.streamPositions[message.id] != nil }
    @State private var detailsExpanded = false
    private var mode: Binding<ApprovalMode> {
        Binding(get: { store.approvalModes[task.id] ?? .ask }, set: { store.approvalModes[task.id] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "globe").foregroundStyle(ZoopTheme.lime.opacity(0.8)).frame(width: 29, height: 29)
                    .background(ZoopTheme.lime.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title).font(.system(size: 11, weight: .medium)).foregroundStyle(ZoopTheme.text)
                    Text(task.domain).font(.system(size: 8, design: .monospaced)).foregroundStyle(ZoopTheme.secondary).lineLimit(1)
                }
                Spacer()
                Text("THE PLAN").font(.system(size: 7, design: .monospaced)).tracking(1).foregroundStyle(ZoopTheme.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(task.steps.enumerated()), id: \.offset) { index, step in
                    let visible = store.displayedStep(step, index: index, message: message, task: task)
                    if !visible.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(String(format: "%02d", index + 1)).font(.system(size: 8, design: .monospaced)).foregroundStyle(ZoopTheme.secondary)
                            Text(visible).font(.system(size: 10)).foregroundStyle(ZoopTheme.text.opacity(0.75)).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            if !streaming {
                if let plan = task.executablePlan {
                    DisclosureGroup("Plan details", isExpanded: $detailsExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                                Text("\(index + 1). \(step.tool?.rawValue ?? "decide"): \(step.tool == nil ? step.goal : step.arguments.jsonText)\(step.requiresConfirmation ? " — asks before proceeding" : "")")
                                    .font(.system(size: 9, design: .monospaced)).textSelection(.enabled)
                            }
                        }.padding(.top, 6)
                    }.font(.system(size: 9)).foregroundStyle(ZoopTheme.secondary)
                }
                HStack(spacing: 6) {
                    Image(systemName: "doc.text").font(.system(size: 11))
                    Text("~/Zoop/exports/\(task.fileName)").font(.system(size: 8, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                }.foregroundStyle(ZoopTheme.secondary).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                Divider().overlay(ZoopTheme.lime.opacity(0.05))
                HStack {
                    if task.phase == .pending {
                        VStack(alignment: .leading, spacing: 5) {
                            Picker("Mode", selection: mode) {
                                Text("Ask first").tag(ApprovalMode.ask)
                                Text("Auto").tag(ApprovalMode.auto)
                            }
                            .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 150)
                            .accessibilityLabel("Approval mode")
                            Text(mode.wrappedValue == .auto
                                 ? "Runs every step in the plan without asking. Still asks before anything the plan doesn’t list."
                                 : "Asks you before sending, buying, deleting or submitting.")
                                .font(.system(size: 8)).foregroundStyle(mode.wrappedValue == .auto ? Color.orange.opacity(0.85) : ZoopTheme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Button { onStart(task.id) } label: { Label("Execute the plan", systemImage: "arrow.up.right").labelStyle(.titleAndIcon) }
                            .disabled(store.workingTask != nil || task.executablePlan == nil)
                            .buttonStyle(GlassButtonStyle(accent: true)).zoopControlFrame("start-\(task.id.uuidString)")
                    } else if task.phase == .failed {
                        Text("This task couldn’t finish.").font(.system(size: 10)).foregroundStyle(ZoopTheme.secondary)
                        Spacer()
                        Button("View result ↗") { store.selectedTaskID = task.id; store.destination = .activities }
                            .buttonStyle(.plain).font(.system(size: 9))
                    } else if task.phase == .cancelled {
                        Text("This plan was cancelled.").font(.system(size: 10)).foregroundStyle(ZoopTheme.secondary)
                    } else {
                        Label(task.phase == .complete ? "All wrapped up" : "On it. Your desk is still yours.", systemImage: "checkmark")
                            .font(.system(size: 9)).foregroundStyle(ZoopTheme.lime.opacity(0.7))
                        Spacer()
                        Button("View activity ↗") { store.selectedTaskID = task.id; store.destination = .activities }
                            .buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(ZoopTheme.secondary)
                    }
                }
            } else {
                HStack(spacing: 6) { SearchingOrb(active: true, size: 15); Text("A plan is coming together").font(.system(size: 8)).foregroundStyle(ZoopTheme.secondary) }
            }
        }
        .padding(14)
        .background(ZoopTheme.lime.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ZoopTheme.lime.opacity(0.12), lineWidth: 1))
    }
}
