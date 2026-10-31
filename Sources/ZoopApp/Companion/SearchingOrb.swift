import SwiftUI

/// One consistent searching globe. Other states change the label, never the orb shape.
struct SearchingOrb: View {
    var active: Bool
    var size: CGFloat = 24
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active || reduceMotion)) { timeline in
            Canvas { context, canvasSize in
                let time = active && !reduceMotion ? timeline.date.timeIntervalSinceReferenceDate * 0.65 : 0
                let radius = Double(min(canvasSize.width, canvasSize.height)) * 0.41
                let centerX = Double(canvasSize.width) / 2
                let centerY = Double(canvasSize.height) / 2
                let points = (0..<96).map { index -> (Double, Double, Double) in
                    let y = 1 - Double(index) / 95 * 2
                    let ring = sqrt(max(0, 1 - y * y))
                    let angle = Double(index) * .pi * (3 - sqrt(5)) + time
                    return (cos(angle) * ring, y, sin(angle) * ring)
                }.sorted { $0.2 < $1.2 }
                for (x, y, z) in points {
                    let depth = (z + 1) / 2
                    let perspective = 1 + z * 0.18
                    let dot = CGFloat(max(0.35, 0.42 + depth * 0.48))
                    let point = CGPoint(x: CGFloat(centerX + x * radius * perspective), y: CGFloat(centerY + y * radius * perspective))
                    context.fill(Path(ellipseIn: CGRect(x: point.x - dot, y: point.y - dot, width: dot * 2, height: dot * 2)), with: .color(ZoopTheme.lime.opacity(0.15 + depth * 0.85)))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct NotchStatus: View {
    let label: String
    let active: Bool
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            if label != "idling" { SearchingOrb(active: active, size: compact ? 26 : 17) }
            ZStack(alignment: .leading) {
                Text(label).id(label)
                    .font(.system(size: compact ? 11 : 9, design: .monospaced))
                    .foregroundStyle(label == "idling" ? ZoopTheme.secondary : ZoopTheme.text.opacity(0.8))
                    .lineLimit(1).truncationMode(.tail)
                    .transition(reduceMotion ? .opacity : .statusWord)
            }
            .animation(reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.36, dampingFraction: 0.86), value: label)
        }
        .frame(height: 26, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}
