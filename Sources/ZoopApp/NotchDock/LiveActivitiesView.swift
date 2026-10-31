import AppKit
import SwiftUI
import ZoopShared

/// The base version displays one executing task and its latest observed screen.
struct LiveActivitiesView: View {
    @Bindable var store: CompanionStore

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button { store.destination = .chat } label: { Label("Back to chat", systemImage: "arrow.left") }
                    .buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(ZoopTheme.text.opacity(0.8))
                Spacer()
                Text("Agent workspace").font(.system(size: 9)).foregroundStyle(ZoopTheme.secondary)
            }.frame(height: 26)
            if let task = store.activityTask {
                HStack {
                    Text(task.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer()
                    Button { store.expandPreview(for: task.id) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.plain).font(.system(size: 12)).padding(5)
                    .help("Open a larger, movable preview")
                    .accessibilityLabel("Expand agent preview")
                    Text(task.phase.rawValue).font(.system(size: 9, design: .monospaced)).foregroundStyle(ZoopTheme.secondary)
                }
                if store.workingTask?.id == task.id, let question = store.question {
                    AgentQuestionView(question: question, answer: store.answerQuestion).id(question.id)
                } else {
                    ZStack {
                        Color.black.opacity(0.25)
                        if let data = store.screenshot(for: task.id), let image = NSImage(data: data) {
                            Image(nsImage: image).resizable().scaledToFit()
                                .accessibilityLabel("Latest screenshot of the agent session")
                        } else {
                            VStack(spacing: 10) {
                                if task.phase == .running { SearchingOrb(active: true, size: 28) }
                                else { ZoopMascot(size: 38) }
                                Text(task.phase == .failed ? (task.statusNote ?? "The task could not finish.") : "Screenshots appear when the agent observes its workspace.")
                                    .font(.system(size: 11)).foregroundStyle(ZoopTheme.secondary).multilineTextAlignment(.center)
                            }.padding()
                        }
                    }.frame(height: 238).clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Text(task.statusNote ?? (task.phase == .running ? "Working through the approved plan…" : "Ready."))
                    .font(.system(size: 10)).foregroundStyle(ZoopTheme.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ProgressView(value: Double(task.progress), total: 100).tint(ZoopTheme.lime)
                HStack {
                    Text("Your own desktop stays yours.").font(.system(size: 8)).foregroundStyle(ZoopTheme.secondary)
                    Spacer()
                    if task.phase == .complete {
                        Button { store.saveReport(task) } label: { Label("Save result", systemImage: "arrow.down.to.line") }
                            .buttonStyle(GlassButtonStyle())
                    }
                }.font(.system(size: 9))
                Spacer(minLength: 0)
            } else {
                Spacer()
                ZoopMascot(size: 60)
                Text("No task running.").font(.system(size: 23)).foregroundStyle(ZoopTheme.text)
                Text("Give me a task in chat, review the plan, then choose Execute the plan.")
                    .font(.system(size: 11)).foregroundStyle(ZoopTheme.secondary)
                Button("Back to chat") { store.openChat() }.buttonStyle(GlassButtonStyle(accent: true))
                Spacer()
            }
        }.padding(.bottom, 12)
    }
}

private struct AgentQuestionView: View {
    let question: CompanionPrompter.Question
    let answer: (String) -> Void
    @State private var response = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question.permission.map { $0.kind == .appDialog ? "\($0.ownerName) needs your choice" : "Permission needed in the agent session" }
                 ?? (question.kind == .confirm ? "Zoop needs your approval" : "Zoop needs your input")).font(.system(size: 12, weight: .semibold))
            if question.permission != nil {
                Text("Choose a button to answer this dialog.").font(.system(size: 10)).foregroundStyle(ZoopTheme.secondary)
            }
            if let permission = question.permission {
                // Only the dialog text scrolls. The choices stay pinned below it, so a long
                // Save sheet description can never push the buttons out of sight.
                ScrollView {
                    Text(question.text).font(.system(size: 11)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(permission.choices) { choice in
                            Button(choice.title) { answer(choice.id) }
                                .buttonStyle(GlassButtonStyle())
                        }
                    }.font(.system(size: 11))
                }.fixedSize(horizontal: false, vertical: true)
                Button("Leave unchanged and end task") { answer("cancel_permission") }
                    .buttonStyle(GlassButtonStyle()).font(.system(size: 10))
            } else {
                ScrollView { Text(question.text).font(.system(size: 11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                if question.kind == .confirm {
                    HStack {
                        Button("Deny") { answer("no") }.buttonStyle(GlassButtonStyle())
                        Spacer()
                        Button("Allow") { answer("yes") }.buttonStyle(GlassButtonStyle(accent: true))
                    }.font(.system(size: 10))
                } else {
                    TextField("Your answer", text: $response).textFieldStyle(.roundedBorder)
                        .onSubmit { if !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { answer(response) } }
                    HStack {
                        Button("Decline") { answer("no") }.buttonStyle(GlassButtonStyle())
                        Spacer()
                        Button("Send answer") { answer(response) }.buttonStyle(GlassButtonStyle(accent: true))
                            .disabled(response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.font(.system(size: 10))
                }
            }
        }.padding(14).frame(height: 238)
            .background(ZoopTheme.lime.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}
