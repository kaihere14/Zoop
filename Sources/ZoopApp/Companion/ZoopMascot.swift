import SwiftUI
import ZoopShared

struct ZoopMascot: View {
    var mood: CompanionMood = .sleeping
    var size: CGFloat = 32
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pixels = [
        "................", ".........LL.....", "........LL......", ".....GGGGGG.....",
        "...GGGGGGGGGG...", "..GGGGGGGGGGGG..", "..GGGGGGGGGGGG..", ".GGGGGGGGGGGGGG.",
        ".GGGGGGGGGGGGGG.", ".GGGGGGGGGGGGGG.", ".GGGGGGGGGGGGGG.", "..GGGGGGGGGGGG..",
        "...GGGGGGGGGG...", "....GGGGGGGG....", "....GG....GG....", "................",
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { graphics, canvasSize in
                let context = graphics
                let unit = canvasSize.width / 16
                let breath = mood == .done ? -abs(sin(time * 10)) * 0.9 : mood == .sleeping ? sin(time * 1.5) * 0.2 : mood == .cooking ? sin(time * 7) * 0.35 : sin(time * 2) * 0.15
                func pixel(_ x: Double, _ y: Double, _ width: Double = 1, _ height: Double = 1, _ color: Color = ZoopTheme.lime) {
                    let rect = CGRect(x: CGFloat(x) * unit, y: CGFloat(y + breath) * unit, width: CGFloat(width) * unit, height: CGFloat(height) * unit)
                    context.fill(Path(rect), with: .color(color), style: FillStyle(antialiased: false))
                }
                for (y, row) in pixels.enumerated() {
                    for (x, character) in row.enumerated() where character != "." {
                        pixel(Double(x), Double(y), 1, 1, character == "L" ? Color(red: 0.84, green: 1, blue: 0.55) : ZoopTheme.lime)
                    }
                }
                let ink = Color(red: 0.11, green: 0.17, blue: 0.04)
                if mood == .sleeping {
                    for x in [3.0, 9.0] { pixel(x, 7, 1, 1, ink); pixel(x + 1, 8, 2, 1, ink); pixel(x + 3, 7, 1, 1, ink) }
                    let drift = reduceMotion ? 0 : (sin(time * 1.5) + 1) * 0.5
                    let z = ZoopTheme.lime.opacity(0.35 + drift * 0.4)
                    pixel(13, -drift, 3, 1, z); pixel(15, 1 - drift, 1, 1, z)
                    pixel(14, 2 - drift, 1, 1, z); pixel(13, 3 - drift, 3, 1, z)
                } else if mood == .done {
                    for x in [3.0, 9.0] {
                        pixel(x, 7, 1, 1, ink); pixel(x + 1, 6, 2, 1, ink); pixel(x + 3, 7, 1, 1, ink)
                    }
                    let sparkle = Color(red: 0.89, green: 1, blue: 0.68)
                    pixel(0, 3, 3, 1, sparkle); pixel(1, 2, 1, 3, sparkle)
                    pixel(13, 11, 3, 1, sparkle); pixel(14, 10, 1, 3, sparkle)
                } else {
                    let glance = mood == .thinking ? (sin(time * 2) > 0 ? 0.5 : -0.5) : 0
                    let blink = mood == .idle && time.truncatingRemainder(dividingBy: 4.5) > 4.3
                    pixel(4 + glance, blink ? 7 : 6, 2, blink ? 1 : 3, ink)
                    pixel(10 + glance, mood == .done || blink ? 7 : 6, mood == .done ? 3 : 2, mood == .done || blink ? 1 : 3, ink)
                }
                if mood == .cooking || mood == .done {
                    pixel(6, 10, 1, 1, ink); pixel(9, 10, 1, 1, ink); pixel(6, 11, 4, 1, ink)
                    pixel(3, 9, 2, 1, .pink.opacity(0.7)); pixel(11, 9, 2, 1, .pink.opacity(0.7))
                } else { pixel(7, 10, 2, 1, ink) }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Zoop is \(mood.rawValue)")
    }
}
