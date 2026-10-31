import SwiftUI
import ZoopAgents
import ZoopShared

struct GhostDeskView: View {
    let task: CompanionTask
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var epoch = Date()

    private var active: Bool { task.phase == .running }
    private var heading: String {
        switch task.kind {
        case .keyboards: "Good keys. Great company."
        case .getaway: "A change of scenery."
        case .tools: "Tools for a calmer workday."
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active || reduceMotion)) { timeline in
            let elapsed = active && !reduceMotion ? max(0, timeline.date.timeIntervalSince(epoch)) : 0
            let segment = elapsed / 2.3
            let row = Int(segment) % 3
            let fraction = segment - floor(segment)
            VStack(spacing: 0) {
                browserChrome
                browserPage(row: row, fraction: fraction)
                HStack(spacing: 6) {
                    if active { SearchingOrb(active: true, size: 14) }
                    else { Circle().fill(ZoopTheme.lime.opacity(0.6)).frame(width: 4, height: 4) }
                    Text(statusText).font(.system(size: 8)).lineLimit(1).foregroundStyle(ZoopTheme.secondary)
                    Spacer()
                    Text("\(task.progress)%").font(.system(size: 8, design: .monospaced)).foregroundStyle(ZoopTheme.secondary)
                }.padding(.horizontal, 10).frame(height: 29).background(Color(red: 0.06, green: 0.08, blue: 0.045))
                GeometryReader { geometry in
                    ZoopTheme.lime.opacity(0.7).frame(width: geometry.size.width * CGFloat(task.progress) / 100)
                        .animation(.easeOut(duration: 0.8), value: task.progress)
                }.frame(height: 2).background(ZoopTheme.lime.opacity(0.05))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Simulated isolated desk")
    }

    private var browserChrome: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) { ForEach([Color(red: 0.9, green: 0.43, blue: 0.38), Color(red: 0.84, green: 0.71, blue: 0.36), Color(red: 0.54, green: 0.68, blue: 0.38)], id: \.self) { color in Circle().fill(color).frame(width: 6, height: 6) } }
            Image(systemName: "chevron.left").font(.system(size: 9)).foregroundStyle(ZoopTheme.secondary)
            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(ZoopTheme.secondary.opacity(0.5))
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "lock").font(.system(size: 7))
                Text(task.domain.components(separatedBy: " · ")[0]).font(.system(size: 8))
                Spacer(minLength: 2)
                Image(systemName: "arrow.clockwise").font(.system(size: 8))
            }.foregroundStyle(ZoopTheme.secondary).padding(.horizontal, 8).frame(width: 330, height: 18)
                .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
            Spacer()
            Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(ZoopTheme.secondary)
        }.padding(.horizontal, 11).frame(height: 29).background(Color(red: 0.15, green: 0.17, blue: 0.13))
    }

    private func browserPage(row: Int, fraction: Double) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(task.kind == .keyboards ? "RTINGS.com" : task.kind == .getaway ? "somewhere good." : "the shortlist.")
                    .font(.system(size: 11, weight: .semibold)).tracking(-0.5)
                Spacer()
                Text("REVIEWS  /  \(task.kind == .keyboards ? "KEYBOARDS" : task.kind == .getaway ? "GETAWAYS" : "WORKSPACE")")
                    .font(.system(size: 6, design: .monospaced)).tracking(0.8).foregroundStyle(.black.opacity(0.4))
                Image(systemName: "magnifyingglass").font(.system(size: 10)).padding(.leading, 12)
            }.frame(height: 30).overlay(alignment: .bottom) { Color.black.opacity(0.08).frame(height: 1) }
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("A LITTLE RESEARCH GOES A LONG WAY").font(.system(size: 6, design: .monospaced)).tracking(1).foregroundStyle(.black.opacity(0.4))
                    Text(heading).font(.system(size: 19, weight: .regular)).tracking(-0.6)
                    Text("Three thoughtful options, with the useful details.").font(.system(size: 8)).foregroundStyle(.black.opacity(0.45))
                }
                Spacer()
                Text("03").font(.system(size: 31, design: .serif)).foregroundStyle(Color(red: 0.55, green: 0.6, blue: 0.45))
            }.frame(height: 70)
            HStack {
                Text("THE SHORTLIST").frame(maxWidth: .infinity, alignment: .leading)
                Text(task.kind == .keyboards ? "LATENCY" : "RATING").frame(width: 80, alignment: .leading)
                Text("PRICE").frame(width: 60, alignment: .trailing)
            }.font(.system(size: 6, design: .monospaced)).tracking(0.7).foregroundStyle(.black.opacity(0.4)).frame(height: 14)
            ForEach(Array(DemoResearch.rows(for: task.kind).enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 10) {
                    ProductArt(kind: task.kind, index: index, initial: String(item.name.prefix(1))).frame(width: 45, height: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.system(size: 9, weight: .semibold))
                        Text(item.detail).font(.system(size: 7)).foregroundStyle(.black.opacity(0.4)).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(item.metric).font(.system(size: 9, design: .monospaced)).foregroundStyle(Color(red: 0.4, green: 0.48, blue: 0.31)).frame(width: 80, alignment: .leading)
                    HStack(spacing: 5) { Text(item.price).font(.system(size: 11)); Image(systemName: "checkmark").font(.system(size: 7)).foregroundStyle(.black.opacity(0.35)) }.frame(width: 60, alignment: .trailing)
                }
                .padding(.horizontal, 3).frame(height: 38)
                .background(active && row == index ? ZoopTheme.lime.opacity(0.13) : .clear)
                .overlay(alignment: .top) { Color.black.opacity(0.065).frame(height: 0.5) }
            }
            HStack {
                Label("Collected with a little care", systemImage: "sparkles")
                Spacer()
                Text("Illustrative data · Native UI preview")
            }.font(.system(size: 6)).foregroundStyle(.black.opacity(0.4)).frame(height: 20)
        }
        .padding(.horizontal, 20)
        .foregroundStyle(Color(red: 0.18, green: 0.22, blue: 0.15))
        .background(Color(red: 0.94, green: 0.945, blue: 0.91))
        .overlay {
            GeometryReader { geometry in
                let previous = (row + 2) % 3
                let interpolation = min(1, fraction / 0.4)
                let eased = interpolation * interpolation * (3 - 2 * interpolation)
                let xs = [0.68, 0.78, 0.72]
                let ys = [134.0, 172.0, 210.0]
                let x = xs[previous] + (xs[row] - xs[previous]) * eased
                let y = ys[previous] + (ys[row] - ys[previous]) * eased
                GhostPointer(ripple: fraction > 0.72 ? (fraction - 0.72) / 0.28 : 0)
                    .position(x: geometry.size.width * CGFloat(x), y: CGFloat(y))
                    .opacity(active ? 1 : 0)
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private var statusText: String {
        if task.phase == .complete { return "Research complete. Your file is ready." }
        if task.phase == .paused { return "Taking a breather. Resume whenever you’re ready." }
        if task.progress < 34 { return "Reading reviews and gathering the good bits…" }
        if task.progress < 68 { return "Comparing the details, one at a time…" }
        return "Putting the finishing touches on your report…"
    }
}

private struct ProductArt: View {
    let kind: ResearchKind
    let index: Int
    let initial: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(kind == .tools ? Color(red: 0.23 + Double(index) * 0.13, green: 0.29 + Double(index) * 0.08, blue: 0.19 + Double(index) * 0.06) : Color(red: 0.86, green: 0.88, blue: 0.81))
            if kind == .keyboards {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(3), spacing: 1), count: 8), spacing: 1) {
                    ForEach(0..<24) { key in RoundedRectangle(cornerRadius: 0.5).fill(key.isMultiple(of: 5) ? Color.white.opacity(0.8) : Color.gray.opacity(0.7)).frame(width: 3, height: 3) }
                }.padding(3).background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 2)).frame(width: 36, height: 19).rotationEffect(.degrees(-5))
            } else {
                if kind == .getaway { Image(systemName: "house.fill").font(.system(size: 20)).foregroundStyle(.white.opacity(0.7)) }
                else { Text(initial).font(.system(size: 19, weight: .semibold)).foregroundStyle(.white.opacity(0.85)) }
            }
        }
    }
}

private struct GhostPointer: View {
    let ripple: Double
    var body: some View {
        ZStack(alignment: .topLeading) {
            if ripple > 0 {
                Circle().stroke(ZoopTheme.lime.opacity(1 - ripple), lineWidth: 1)
                    .frame(width: 14, height: 14).scaleEffect(1 + ripple * 2.2).offset(x: -5, y: -5)
            }
            Path { path in
                path.move(to: .init(x: 1, y: 1)); path.addLines([.init(x: 1, y: 22), .init(x: 7, y: 17), .init(x: 12, y: 25), .init(x: 16, y: 23), .init(x: 11, y: 15), .init(x: 20, y: 14)]); path.closeSubpath()
            }.fill(ZoopTheme.lime).overlay {
                Path { path in path.move(to: .init(x: 1, y: 1)); path.addLines([.init(x: 1, y: 22), .init(x: 7, y: 17), .init(x: 12, y: 25), .init(x: 16, y: 23), .init(x: 11, y: 15), .init(x: 20, y: 14)]); path.closeSubpath() }.stroke(Color.black.opacity(0.4), lineWidth: 1)
            }.frame(width: 22, height: 27)
            Text("zoop").font(.system(size: 6, weight: .medium)).foregroundStyle(.black.opacity(0.65)).padding(.horizontal, 6).padding(.vertical, 3).background(ZoopTheme.lime, in: RoundedRectangle(cornerRadius: 4)).offset(x: 17, y: 22)
        }.frame(width: 48, height: 34).shadow(color: .black.opacity(0.15), radius: 2, y: 2)
    }
}
