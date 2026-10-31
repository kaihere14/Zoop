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

/// Background of the island. Collapsed it is solid black so it reads as part of the hardware notch.
/// Expanded it is clear Liquid Glass under a black gradient: pitch black at the top, where it meets the
/// hardware notch and the header, fading to a light tint at the bottom so the desktop shows through
/// while text stays readable. SwiftUI draws the glass and shadow, so both follow the rounded shape
/// exactly (an AppKit window shadow or NSVisualEffectView would stay rectangular).
struct LiquidGlass: View {
    var expanded: Bool
    var working: Bool
    var flare: CGFloat
    var radius: CGFloat
    /// 0 is nearly solid black, 1 is the clearest glass. Set from the settings panel.
    var intensity: Double = GlassSettings.defaultIntensity

    var body: some View {
        let shape = NotchShape(flare: flare, radius: radius)
        // `dark` is how much black tint sits over the glass below the header; the top always stays pitch black.
        let dark = 1 - min(1, max(0, intensity))
        ZStack {
            Color.clear.glassEffect(.clear, in: shape)
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.14),
                .init(color: .black.opacity(0.62 + 0.33 * dark), location: 0.38),
                .init(color: .black.opacity(0.32 + 0.6 * dark), location: 0.7),
                .init(color: .black.opacity(0.2 + 0.7 * dark), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            Color.black.opacity(expanded ? 0 : 1)
        }
        .clipShape(shape)
        .overlay(
            NotchShape(flare: flare, radius: radius, closed: false)
                .stroke(LinearGradient(stops: [
                    .init(color: .white.opacity(0), location: 0),
                    .init(color: .white.opacity(0), location: 0.2),
                    .init(color: .white.opacity(0.12), location: 0.65),
                    .init(color: ZoopTheme.lime.opacity(0.14), location: 1),
                ], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                .opacity(expanded ? 1 : 0)
        )
        .background(
            // The shadow needs a filled shape to cast from, but a fill under the glass would be all the
            // glass shows. The mask cuts the fill out, leaving only the shadow outside the island.
            shape.fill(.black)
                .shadow(color: .black.opacity(expanded ? 0.45 : 0), radius: 24, y: 12)
                .shadow(color: ZoopTheme.lime.opacity(expanded ? (working ? 0.14 : 0.05) : 0), radius: 26, y: 20)
                .mask {
                    ZStack {
                        Rectangle().padding(-80)
                        shape.blendMode(.destinationOut)
                    }.compositingGroup()
                }
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum GlassSettings {
    static let intensityKey = "glassIntensity"
    /// Noticeably more solid than fully clear glass, so text reads well on bright wallpapers.
    static let defaultIntensity = 0.45
}
