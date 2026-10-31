import SwiftUI
import ZoopShared

struct NotchMetrics: Equatable {
    var screenFrame: CGRect
    var hardwareWidth: CGFloat
    var hardwareHeight: CGFloat
    var hasPhysicalNotch: Bool

    /// Room around the island for its soft shadow. The window never resizes, so this is fixed.
    static let shadowMargin: CGFloat = 44
    static let underbarHeight: CGFloat = 24
    static let collapsedFlare: CGFloat = 6
    static let expandedFlare: CGFloat = 10
    static let contentInset: CGFloat = 28
    static let maxMainHeight: CGFloat = 520
    static let completionWidth: CGFloat = 340
    static let completionHeight: CGFloat = 84

    var expandedWidth: CGFloat { min(820, screenFrame.width - 32) }
    /// Each wing beside the camera is narrow when idle and widens when status text and the orb need room.
    func collapsedWidth(busy: Bool) -> CGFloat {
        min(hardwareWidth + 2 * (busy ? 118 : 66), screenFrame.width - 32)
    }
    func islandWidth(expanded: Bool, busy: Bool) -> CGFloat { expanded ? expandedWidth : collapsedWidth(busy: busy) }
    func mainHeight(expanded: Bool, activities: Bool) -> CGFloat {
        expanded ? min(activities ? 488 : Self.maxMainHeight, screenFrame.height - 80) : hardwareHeight
    }
    /// The visible, clickable part of the window (island plus the underbar when expanded).
    func interactiveSize(expanded: Bool, activities: Bool, busy: Bool) -> CGSize {
        .init(width: islandWidth(expanded: expanded, busy: busy),
              height: mainHeight(expanded: expanded, activities: activities) + (expanded ? Self.underbarHeight : 0))
    }
    /// Fixed window size large enough for the expanded island and its shadow.
    var windowSize: CGSize {
        .init(width: expandedWidth + 2 * Self.shadowMargin,
              height: min(Self.maxMainHeight, screenFrame.height - 80) + Self.underbarHeight + Self.shadowMargin)
    }
}

extension CompanionStore {
    /// Whether the collapsed island shows activity (orb + status) and therefore needs wider wings.
    var notchBusy: Bool { compactStatus != "idling" }
}

struct NotchRootView: View {
    @Bindable var store: CompanionStore
    let metrics: NotchMetrics
    let onStateChange: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var controlFrames: [String: CGRect] = [:]
    @State private var flights: [PaperFlight] = []
    @State private var pulse = false

    private var expanded: Bool { store.isExpanded }
    private var activities: Bool { store.destination == .activities }
    private var width: CGFloat { metrics.islandWidth(expanded: expanded, busy: store.notchBusy) }
    private var height: CGFloat { metrics.mainHeight(expanded: expanded, activities: activities) }
    private var flare: CGFloat { expanded ? NotchMetrics.expandedFlare : NotchMetrics.collapsedFlare }
    private var radius: CGFloat { expanded ? 28 : 14 }
    private var morph: Animation { reduceMotion ? .easeOut(duration: 0.12) : ZoopTheme.island }

    var body: some View {
        VStack(spacing: 0) {
            island
            if expanded {
                underbar.frame(width: width, height: NotchMetrics.underbarHeight)
                    .transition(reduceMotion ? .opacity : .notchContent(delay: 0.12))
            }
        }
        .frame(width: metrics.windowSize.width, height: metrics.windowSize.height, alignment: .top)
        .overlay(alignment: .top) {
            if let task = store.completionAlert {
                completionCard(task)
                    .frame(width: min(NotchMetrics.completionWidth, metrics.expandedWidth), height: NotchMetrics.completionHeight)
                    .offset(x: -(width - min(NotchMetrics.completionWidth, metrics.expandedWidth)) / 2 + (expanded ? NotchMetrics.contentInset : 0),
                            y: metrics.hardwareHeight + (expanded ? 56 : 10))
                    .id(task.id)
                    .transition(reduceMotion ? .opacity : .offset(y: -12).combined(with: .opacity))
            }
        }
        .animation(morph, value: store.isExpanded)
        .animation(morph, value: store.destination)
        .animation(morph, value: store.notchBusy)
        .animation(morph, value: store.completionAlert?.id)
        .preferredColorScheme(.dark)
        .onChange(of: store.isExpanded) {
            if store.isExpanded { store.recordInteraction(); store.dismissCompletionAlerts() }
            onStateChange()
        }
        .onChange(of: store.completionAlert?.id) { onStateChange() }
        .onChange(of: store.destination) { onStateChange() }
        .onChange(of: store.notchBusy) { onStateChange() }
        .onChange(of: store.liveTasks.count) { old, new in
            guard new > old, !reduceMotion else { return }
            Task { @MainActor in
                withAnimation(.spring(response: 0.18, dampingFraction: 0.6)) { pulse = true }
                try? await Task.sleep(for: .milliseconds(160))
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { pulse = false }
            }
        }
    }

    /// The morphing island. Content is laid out at its final size and clipped by the animated shape,
    /// so text is never scaled while the island grows or shrinks.
    private var island: some View {
        ZStack(alignment: .top) {
            if expanded {
                ZStack(alignment: .top) {
                    Group {
                        if activities { LiveActivitiesView(store: store) }
                        else { ChatView(store: store, onStart: dispatch) }
                    }
                    .padding(.top, metrics.hardwareHeight + 46)
                    .transition(reduceMotion ? .opacity : .notchContent(delay: 0.04))
                    header.padding(.top, metrics.hardwareHeight)
                }
                .padding(.horizontal, NotchMetrics.contentInset)
                .frame(width: metrics.expandedWidth, height: metrics.mainHeight(expanded: true, activities: activities), alignment: .top)
                .transition(reduceMotion ? .opacity : .notchContent(delay: 0.08))
            } else {
                Button { store.isExpanded = true } label: {
                    HStack(spacing: 0) {
                        if store.workingTaskCount > 0 {
                            HStack(spacing: 4) {
                                Text("\(store.workingTaskCount)")
                                    .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(Color(red: 0.84, green: 0.97, blue: 0.66))
                                    .contentTransition(.numericText())
                                Text("working").font(.system(size: 9)).foregroundStyle(Color(red: 0.75, green: 0.8, blue: 0.71))
                            }
                            .padding(.horizontal, 7).frame(height: 20)
                            .background(LinearGradient(colors: [ZoopTheme.lime.opacity(0.07), ZoopTheme.lime.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule())
                            .overlay(Capsule().strokeBorder(ZoopTheme.lime.opacity(0.13), lineWidth: 1))
                            .padding(.leading, NotchMetrics.collapsedFlare + 44)
                            .animation(reduceMotion ? .none : .easeOut(duration: 0.18), value: store.workingTaskCount)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(store.workingTaskCount) \(store.workingTaskCount == 1 ? "task" : "tasks") working")
                        }
                        Spacer(minLength: 0)
                        NotchStatus(label: store.compactStatus, active: store.workingTask != nil || store.mood == .thinking, compact: true)
                            .fixedSize()
                    }
                    .padding(.trailing, NotchMetrics.collapsedFlare + 12)
                    .frame(width: width, height: height)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Open Zoop")
                .transition(.opacity.animation(.easeOut(duration: expanded ? 0.1 : 0.25).delay(expanded ? 0 : 0.12)))
            }
            Color.black
                .frame(width: metrics.hardwareWidth, height: metrics.hardwareHeight)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 16, bottomTrailingRadius: 16, topTrailingRadius: 0))
                .overlay(alignment: .trailing) {
                    if !metrics.hasPhysicalNotch { Circle().fill(Color(red: 0.04, green: 0.06, blue: 0.08)).frame(width: 5, height: 5).padding(.trailing, 26) }
                }.allowsHitTesting(false).accessibilityHidden(true)
            mascot
        }
        .frame(width: width, height: height, alignment: .top)
        .clipShape(NotchShape(flare: flare, radius: radius))
        .background(LiquidGlass(expanded: expanded, working: store.workingTask != nil, flare: flare, radius: radius))
        .overlay(alignment: .topLeading) {
            ForEach(flights) { flight in
                FlyingPaperTicket(flight: flight, reduceMotion: reduceMotion) {
                    store.finishDispatch(flight.taskID)
                    flights.removeAll { $0.id == flight.id }
                }
            }
        }
        .coordinateSpace(name: "notch")
        .onPreferenceChange(ControlFramesKey.self) { frames in
            Task { @MainActor in controlFrames = frames }
        }
    }

    /// One mascot that travels between the collapsed wing and the header, instead of two copies cross-fading.
    private var mascot: some View {
        let size: CGFloat = 32
        let scale: CGFloat = expanded ? 1 : 26 / 32
        let center = expanded
            ? CGPoint(x: (width - metrics.expandedWidth) / 2 + NotchMetrics.contentInset + size / 2, y: metrics.hardwareHeight + 23)
            : CGPoint(x: NotchMetrics.collapsedFlare + 10 + 13, y: metrics.hardwareHeight / 2)
        return ZoopMascot(mood: store.mood, size: size)
            .frame(width: size, height: size)
            .scaleEffect(scale)
            .offset(x: center.x - size / 2, y: center.y - size / 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 32, height: 32) // the shared mascot is drawn here by `mascot`
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .top, spacing: 1) {
                    Text("zoop").font(.system(size: 18, weight: .bold)).tracking(-0.8)
                    Text("®").font(.system(size: 7)).padding(.top, 2)
                }.foregroundStyle(ZoopTheme.text)
                NotchStatus(label: store.status, active: store.workingTask != nil || store.mood == .thinking)
                    .frame(width: min(250, metrics.expandedWidth * 0.35), height: 18, alignment: .leading)
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
        }.buttonStyle(.plain).foregroundStyle(ZoopTheme.secondary).padding(.horizontal, 20 + NotchMetrics.expandedFlare)
    }

    private func completionCard(_ task: CompanionTask) -> some View {
        HStack(spacing: 0) {
            Button { store.openCompletedTask(task.id) } label: {
                HStack(spacing: 11) {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .medium))
                        .foregroundStyle(ZoopTheme.lime).frame(width: 33, height: 33)
                        .background(ZoopTheme.lime.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ZoopTheme.lime.opacity(0.16), lineWidth: 1))
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 12) {
                            Text("A LITTLE WIN").foregroundStyle(ZoopTheme.lime)
                            Text("JUST FINISHED").foregroundStyle(ZoopTheme.secondary)
                        }.font(.system(size: 7, design: .monospaced)).tracking(0.8)
                        Text(task.title).font(.system(size: 12, weight: .medium)).foregroundStyle(ZoopTheme.text).lineLimit(1)
                        HStack(spacing: 4) {
                            Text(store.completionQueue.count > 1 ? "Your report is ready · +\(store.completionQueue.count - 1) more ready" : "Your report is ready. Take a look")
                            Image(systemName: "arrow.up.right")
                        }.font(.system(size: 9)).foregroundStyle(ZoopTheme.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.padding(.leading, 14).frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("View completed task: \(task.title)")
            Button { store.dismissCurrentCompletion() } label: {
                Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(ZoopTheme.secondary).frame(width: 28, height: 32)
            }.buttonStyle(.plain).accessibilityLabel("Dismiss task notification").frame(maxHeight: .infinity, alignment: .top).padding(.top, 4)
        }
        .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 16))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .overlay(alignment: .topLeading) {
            Rectangle().fill(.black.opacity(0.92)).frame(width: 8, height: 8)
                .rotationEffect(.degrees(45)).offset(x: 32, y: -4).allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
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
