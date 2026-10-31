import SwiftUI

/// The island outline: a flat top that continues the hardware notch, concave "flares" where it meets
/// the menu bar, and rounded bottom corners. Both radii are animatable so the shape morphs smoothly.
/// With `closed == false` the top edge is omitted, which lets the stroke outline only the sides and bottom.
struct NotchShape: Shape {
    var flare: CGFloat
    var radius: CGFloat
    var closed = true

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(flare, radius) }
        set { flare = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let f = max(0, min(flare, rect.width / 4, rect.height / 2))
        let r = max(0, min(radius, (rect.width - 2 * f) / 2, rect.height - f))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.minX + f, y: rect.minY), tangent2End: CGPoint(x: rect.minX + f, y: rect.minY + f), radius: f)
        path.addLine(to: CGPoint(x: rect.minX + f, y: rect.maxY - r))
        path.addArc(tangent1End: CGPoint(x: rect.minX + f, y: rect.maxY), tangent2End: CGPoint(x: rect.minX + f + r, y: rect.maxY), radius: r)
        path.addLine(to: CGPoint(x: rect.maxX - f - r, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX - f, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - f, y: rect.maxY - r), radius: r)
        path.addLine(to: CGPoint(x: rect.maxX - f, y: rect.minY + f))
        path.addArc(tangent1End: CGPoint(x: rect.maxX - f, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: f)
        if closed { path.closeSubpath() }
        return path
    }
}

/// Background of the island. Collapsed it is solid black so it reads as part of the hardware notch;
/// expanded it becomes dark glass. SwiftUI draws the material and shadow, so both follow the rounded
/// shape exactly (an AppKit window shadow or NSVisualEffectView would stay rectangular).
struct LiquidGlass: View {
    var expanded: Bool
    var working: Bool
    var flare: CGFloat
    var radius: CGFloat

    var body: some View {
        let shape = NotchShape(flare: flare, radius: radius)
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: Color(red: 0.02, green: 0.02, blue: 0.03).opacity(0.98), location: 0.12),
                .init(color: Color(red: 0.06, green: 0.07, blue: 0.09).opacity(0.78), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            Color.black.opacity(expanded ? 0 : 1)
        }
        .clipShape(shape)
        .overlay(
            NotchShape(flare: flare, radius: radius, closed: false)
                .stroke(LinearGradient(stops: [
                    .init(color: .white.opacity(0), location: 0),
                    .init(color: .white.opacity(0), location: 0.25),
                    .init(color: .white.opacity(0.07), location: 0.7),
                    .init(color: ZoopTheme.lime.opacity(0.1), location: 1),
                ], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                .opacity(expanded ? 1 : 0)
        )
        .background(
            shape.fill(.black)
                .shadow(color: .black.opacity(expanded ? 0.45 : 0), radius: 24, y: 12)
                .shadow(color: ZoopTheme.lime.opacity(expanded ? (working ? 0.14 : 0.05) : 0), radius: 26, y: 20)
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
