import SwiftUI
import ZoopShared

struct ChatView: View {
    @Bindable var store: CompanionStore
    let onStart: (UUID) -> Void
    @State private var pinned = true
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
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.contentSize.height - geometry.visibleRect.maxY < 64
                    } action: { _, nearBottom in pinned = nearBottom }
                    .onAppear { pinned = true; reader.scrollTo("latest-message", anchor: .bottom) }
                    .onChange(of: store.messages.count) { if pinned { reader.scrollTo("latest-message", anchor: .bottom) } }
                    .onChange(of: store.streamPositions) { if pinned { reader.scrollTo("latest-message", anchor: .bottom) } }
                    .onChange(of: store.isThinking) { if pinned { reader.scrollTo("latest-message", anchor: .bottom) } }
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
                    .onSubmit { pinned = true; store.send() }
                    .onChange(of: store.draft) { if store.draft.count > 1_200 { store.draft = String(store.draft.prefix(1_200)) } }
                Text("⌘ K").font(.system(size: 9, design: .monospaced)).foregroundStyle(ZoopTheme.secondary.opacity(0.7))
                Button { pinned = true; store.send() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.75)).frame(width: 31, height: 31)
                        .background(ZoopTheme.lime.opacity(store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isResponding ? 0.3 : 1), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isResponding)
                .accessibilityLabel("Send message")
            }
            .padding(.leading, 15).padding(.trailing, 7).frame(height: 47)
            .background(.white.opacity(0.035), in: Capsule())
            .overlay(Capsule().strokeBorder(inputFocused ? ZoopTheme.lime.opacity(0.3) : .white.opacity(0.1), lineWidth: 1))
            HStack {
                Circle().fill(ZoopTheme.lime.opacity(0.7)).frame(width: 3, height: 3)
                Text("Your cursor stays yours.")
                Spacer()
                Text("UI preview · sample tasks")
            }.font(.system(size: 8)).foregroundStyle(ZoopTheme.secondary).padding(.horizontal, 12)
        }.padding(.top, 6).padding(.bottom, 15)
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
                HStack(spacing: 6) {
                    Image(systemName: "doc.text").font(.system(size: 11))
                    Text("~/Zoop/exports/\(task.fileName)").font(.system(size: 8, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                }.foregroundStyle(ZoopTheme.secondary).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                Divider().overlay(ZoopTheme.lime.opacity(0.05))
                HStack {
                    if task.phase == .pending {
                        Text("Can I start now?").font(.system(size: 10)).foregroundStyle(ZoopTheme.text.opacity(0.8))
                        Spacer()
                        Button { onStart(task.id) } label: { Label("Start Process", systemImage: "arrow.up.right").labelStyle(.titleAndIcon) }
                            .buttonStyle(GlassButtonStyle(accent: true)).zoopControlFrame("start-\(task.id.uuidString)")
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
