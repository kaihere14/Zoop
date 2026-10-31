import SwiftUI
import ZoopShared

struct NotchMetrics: Equatable {
    var screenFrame: CGRect
    var hardwareWidth: CGFloat
    var hardwareHeight: CGFloat
    var hasPhysicalNotch: Bool

    var expandedWidth: CGFloat { min(820, screenFrame.width - 32) }
    var collapsedWidth: CGFloat { min(hardwareWidth + 216, screenFrame.width - 32) }
    func mainHeight(expanded: Bool, activities: Bool) -> CGFloat {
        expanded ? min(activities ? 488 : 520, screenFrame.height - 80) : hardwareHeight
    }
    func windowSize(expanded: Bool, activities: Bool) -> CGSize {
        .init(width: expanded ? expandedWidth : collapsedWidth, height: mainHeight(expanded: expanded, activities: activities) + (expanded ? 24 : 0))
    }
}

struct NotchRootView: View {
    @Bindable var store: CompanionStore
    let metrics: NotchMetrics
    let onWindowGeometryChange: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var controlFrames: [String: CGRect] = [:]
    @State private var flights: [PaperFlight] = []
    @State private var pulse = false

    private var width: CGFloat { store.isExpanded ? metrics.expandedWidth : metrics.collapsedWidth }
    private var height: CGFloat { metrics.mainHeight(expanded: store.isExpanded, activities: store.destination == .activities) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // Only the glass changes dimensions. The content is never scaled or blurred.
                LiquidGlass(expanded: store.isExpanded, working: store.workingTask != nil)
                    .frame(width: width, height: height)
                    .animation(reduceMotion ? .easeOut(duration: 0.1) : ZoopTheme.spring, value: store.isExpanded)
                    .animation(reduceMotion ? .easeOut(duration: 0.1) : ZoopTheme.spring, value: store.destination)
                if store.isExpanded {
                    VStack(spacing: 0) {
                        header
                        if store.destination == .chat { ChatView(store: store, onStart: dispatch) }
                        else { LiveActivitiesView(store: store) }
                    }
                    .padding(.horizontal, 23)
                    .padding(.top, metrics.hardwareHeight)
                    .frame(width: width, height: height)
                    .transition(.opacity)
                } else {
                    Button { store.isExpanded = true } label: {
                        HStack {
                            ZoopMascot(mood: store.mood, size: 30)
                            Spacer(minLength: metrics.hardwareWidth)
                            NotchStatus(label: store.compactStatus, active: store.workingTask != nil || store.mood == .thinking, compact: true)
                                .frame(width: 94, alignment: .leading)
                        }.padding(.leading, 20).padding(.trailing, 12).frame(width: width, height: height)
                    }.buttonStyle(.plain).accessibilityLabel("Open Zoop")
                }
                RoundedRectangle(cornerRadius: 0).fill(.black)
                    .frame(width: metrics.hardwareWidth, height: metrics.hardwareHeight)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 16, bottomTrailingRadius: 16, topTrailingRadius: 0))
                    .overlay(alignment: .trailing) {
                        if !metrics.hasPhysicalNotch { Circle().fill(Color(red: 0.04, green: 0.06, blue: 0.08)).frame(width: 5, height: 5).padding(.trailing, 26) }
                    }.allowsHitTesting(false).accessibilityHidden(true)
                ForEach(flights) { flight in
                    FlyingPaperTicket(flight: flight, reduceMotion: reduceMotion) {
                        store.finishDispatch(flight.taskID)
                        flights.removeAll { $0.id == flight.id }
                    }
                }
            }
            .frame(width: width, height: height, alignment: .top)
            .coordinateSpace(name: "notch")
            .onPreferenceChange(ControlFramesKey.self) { frames in
                Task { @MainActor in controlFrames = frames }
            }
            if store.isExpanded { underbar.frame(height: 24) }
        }
        .frame(width: width, height: metrics.windowSize(expanded: store.isExpanded, activities: store.destination == .activities).height, alignment: .top)
        .preferredColorScheme(.dark)
        .onChange(of: store.isExpanded) { onWindowGeometryChange() }
        .onChange(of: store.destination) { onWindowGeometryChange() }
        .onChange(of: store.liveTasks.count) { old, new in
            guard new > old, !reduceMotion else { return }
            Task { @MainActor in
                withAnimation(.spring(response: 0.18, dampingFraction: 0.6)) { pulse = true }
                try? await Task.sleep(for: .milliseconds(160))
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { pulse = false }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZoopMascot(mood: store.mood, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .top, spacing: 1) {
                    Text("zoop").font(.system(size: 18, weight: .bold)).tracking(-0.8)
                    Text("®").font(.system(size: 7)).padding(.top, 2)
                }.foregroundStyle(ZoopTheme.text)
                NotchStatus(label: store.status, active: store.workingTask != nil || store.mood == .thinking)
                    .frame(width: min(250, width * 0.35), height: 18, alignment: .leading)
            }
            Spacer()
            Button { store.destination = store.destination == .activities ? .chat : .activities } label: {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path.ecg").font(.system(size: 11))
                    Text("Live Activities").font(.system(size: 10))
                    Text("\(store.liveTasks.count)").font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(store.liveTasks.isEmpty ? ZoopTheme.secondary : .black)
                        .frame(width: 17, height: 17)
                        .background(store.liveTasks.isEmpty ? Color.white.opacity(0.04) : ZoopTheme.lime, in: Circle())
                }.foregroundStyle(ZoopTheme.text.opacity(0.8)).padding(.horizontal, 9).padding(.vertical, 6)
                    .background(.white.opacity(0.035), in: Capsule()).overlay(Capsule().strokeBorder(.white.opacity(0.09), lineWidth: 1))
            }
            .buttonStyle(.plain).scaleEffect(pulse ? 1.12 : 1)
            .zoopControlFrame("live-activities")
            Button { store.isExpanded = false } label: { Image(systemName: "chevron.up").font(.system(size: 12)).foregroundStyle(ZoopTheme.secondary).padding(5) }
                .buttonStyle(.plain).accessibilityLabel("Minimize Zoop")
        }
        .frame(height: 46)
        .padding(.bottom, 0)
        .overlay(alignment: .bottom) { Color.white.opacity(0.045).frame(height: 1) }
    }

    private var underbar: some View {
        HStack(spacing: 10) {
            if let notice = store.notice {
                Text(notice).font(.system(size: 8)).lineLimit(1).foregroundStyle(Color.orange.opacity(0.9))
                Button { store.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 8)) }.buttonStyle(.plain).accessibilityLabel("Dismiss notice")
            } else {
                Text("YOUR EXTRA PAIR OF HANDS").font(.system(size: 7, design: .monospaced)).tracking(1.2)
            }
            Spacer(minLength: 8)
            Button { store.revealExports() } label: { Image(systemName: "folder").font(.system(size: 11)) }.accessibilityLabel("Open exports folder")
            Button { store.toggleSound() } label: { Image(systemName: store.soundEnabled ? "speaker.wave.2" : "speaker.slash").font(.system(size: 11)) }.accessibilityLabel(store.soundEnabled ? "Mute sounds" : "Enable sounds")
            Button { store.reset() } label: { Image(systemName: "arrow.counterclockwise").font(.system(size: 10)) }.accessibilityLabel("Reset demo")
        }.buttonStyle(.plain).foregroundStyle(ZoopTheme.secondary).padding(.horizontal, 20)
    }

    private func dispatch(_ id: UUID) {
        guard store.approve(id) else { return }
        if let start = controlFrames["start-\(id.uuidString)"], let end = controlFrames["live-activities"] {
            flights.append(PaperFlight(taskID: id, start: CGPoint(x: start.midX, y: start.midY), end: CGPoint(x: end.midX, y: end.midY)))
        }
    }
}

private struct PaperFlight: Identifiable {
    let id = UUID()
    let taskID: UUID
    let start: CGPoint
    let end: CGPoint
}

private struct TicketArc: GeometryEffect {
    var progress: CGFloat
    let start: CGPoint
    let end: CGPoint
    var animatableData: CGFloat { get { progress } set { progress = newValue } }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let control = CGPoint(x: start.x + (end.x - start.x) * 0.35, y: min(start.y, end.y) - 45)
        let q = 1 - progress
        let point = CGPoint(x: q * q * start.x + 2 * q * progress * control.x + progress * progress * end.x,
                            y: q * q * start.y + 2 * q * progress * control.y + progress * progress * end.y)
        let scale = 1 - progress * 0.85
        let transform = CGAffineTransform(translationX: point.x, y: point.y)
            .rotated(by: (-8 + 16 * progress) * .pi / 180).scaledBy(x: scale, y: scale)
            .translatedBy(x: -size.width / 2, y: -size.height / 2)
        return ProjectionTransform(transform)
    }
}

private struct FlyingPaperTicket: View {
    let flight: PaperFlight
    let reduceMotion: Bool
    let onArrival: () -> Void
    @State private var progress: CGFloat = 0

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text").font(.system(size: 12))
            Text("on my way").font(.system(size: 8, design: .monospaced))
            Image(systemName: "arrow.up.right").font(.system(size: 9))
        }
        .foregroundStyle(ZoopTheme.lime)
        .frame(width: 112, height: 40)
        .background(ZoopTheme.lime.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ZoopTheme.lime.opacity(0.55), lineWidth: 1))
        .shadow(color: ZoopTheme.lime.opacity(0.2), radius: 12)
        .modifier(TicketArc(progress: progress, start: flight.start, end: flight.end))
        .allowsHitTesting(false).accessibilityHidden(true)
        .task {
            withAnimation(.timingCurve(0.33, 0, 0.22, 1, duration: reduceMotion ? 0.05 : 0.8)) { progress = 1 }
            do {
                try await Task.sleep(for: .milliseconds(reduceMotion ? 50 : 800))
                guard !Task.isCancelled else { return }
                onArrival()
            } catch {}
        }
    }
}
