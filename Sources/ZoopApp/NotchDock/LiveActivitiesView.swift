import SwiftUI
import ZoopShared

struct LiveActivitiesView: View {
    @Bindable var store: CompanionStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { store.destination = .chat } label: { Label("Back to chat", systemImage: "arrow.left") }
                    .buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(ZoopTheme.text.opacity(0.8))
                Spacer()
                Label("A desk of my own", systemImage: "checkmark.shield").font(.system(size: 8)).foregroundStyle(ZoopTheme.secondary)
            }.frame(height: 30)
            if let task = store.activityTask {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(store.activityTabs) { tab in
                            Button { store.selectedTaskID = tab.id } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(ZoopTheme.lime.opacity(0.8)).frame(width: 3, height: 3)
                                    Text("\(tab.phase == .complete ? "done" : tab.phase == .paused ? "paused" : "cooking"): \(tab.domain.components(separatedBy: " · ")[0])")
                                    if tab.phase == .complete { Image(systemName: "checkmark") }
                                }
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(tab.phase == .complete ? ZoopTheme.lime : ZoopTheme.secondary)
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .background(ZoopTheme.lime.opacity(tab.id == task.id ? 0.045 : 0.015), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ZoopTheme.lime.opacity(tab.id == task.id ? 0.18 : 0.06), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96)), removal: .modifier(active: BlurSlide(opacity: 0, blur: 5, y: -6), identity: BlurSlide(opacity: 1, blur: 0, y: 0)).combined(with: .scale(scale: 0.92, anchor: .leading))))
                        }
                    }.padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
                .frame(height: store.activityTabs.isEmpty ? 0 : 32)
                .clipped()
                .animation(reduceMotion ? .easeOut(duration: 0.1) : ZoopTheme.spring, value: store.activityTabs.map(\.id))
                GhostDeskView(task: task).id(task.id)
                HStack {
                    Text("↗  Separate session. Zero interruptions.").font(.system(size: 8)).foregroundStyle(ZoopTheme.secondary)
                    Spacer()
                    if task.phase == .complete {
                        Button { store.saveReport(task) } label: { Label("Save report", systemImage: "arrow.down.to.line") }.buttonStyle(GlassButtonStyle())
                    } else {
                        Button { store.control(task.id, task.phase == .paused ? .resume : .pause) } label: {
                            Label(task.phase == .paused ? "Resume" : "Pause", systemImage: task.phase == .paused ? "play.fill" : "pause.fill")
                        }.buttonStyle(.plain).foregroundStyle(ZoopTheme.secondary)
                        Button { store.control(task.id, .stop) } label: { Label("Stop", systemImage: "stop.circle") }
                            .buttonStyle(.plain).foregroundStyle(Color(red: 0.7, green: 0.57, blue: 0.5)).padding(.leading, 10)
                    }
                }.font(.system(size: 9)).padding(.top, 8)
                Spacer(minLength: 0)
            } else {
                Spacer()
                ZoopMascot(size: 60)
                Text("A little quiet here.").font(.system(size: 24)).tracking(-0.7).foregroundStyle(ZoopTheme.text).padding(.top, 14)
                Text("Give me a task in chat. I’ll get to work right here.").font(.system(size: 11)).foregroundStyle(ZoopTheme.secondary).padding(.top, 6)
                Button("Let’s find something to do") { store.openChat() }.buttonStyle(GlassButtonStyle(accent: true)).padding(.top, 16)
                Spacer()
            }
        }.padding(.bottom, 12)
    }
}
