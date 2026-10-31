import SwiftUI

enum ZoopTheme {
    static let lime = Color(red: 182 / 255, green: 245 / 255, blue: 66 / 255)
    static let text = Color(red: 0.94, green: 0.95, blue: 0.91)
    static let secondary = Color(red: 0.61, green: 0.66, blue: 0.55)
    static let spring = Animation.interpolatingSpring(mass: 0.8, stiffness: 300, damping: 28, initialVelocity: 0)
    static let quiet = Animation.easeOut(duration: 0.18)
    /// Island morph: damping 0.78 overshoots by about 2% before settling, like the Dynamic Island.
    static let island = Animation.spring(response: 0.46, dampingFraction: 0.78)
}

struct GlassButtonStyle: ButtonStyle {
    var accent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(accent ? Color.black.opacity(0.85) : ZoopTheme.text)
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(accent ? ZoopTheme.lime.opacity(configuration.isPressed ? 0.8 : 1) : Color.white.opacity(configuration.isPressed ? 0.1 : 0.045), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(accent ? ZoopTheme.lime.opacity(0.6) : Color.white.opacity(0.09), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct BlurSlide: ViewModifier {
    var opacity: Double
    var blur: CGFloat
    var y: CGFloat
    func body(content: Content) -> some View { content.opacity(opacity).blur(radius: blur).offset(y: y) }
}

extension AnyTransition {
    /// Content that drops out of the notch: it starts slightly above, blurred and transparent, and arrives
    /// after the island has started growing. Removal is a quick fade so it never lingers outside a shrinking shape.
    static func notchContent(delay: Double) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurSlide(opacity: 0, blur: 8, y: -18), identity: BlurSlide(opacity: 1, blur: 0, y: 0))
                .animation(.spring(response: 0.42, dampingFraction: 0.86).delay(delay)),
            removal: .opacity.animation(.easeIn(duration: 0.1)))
    }

    static var statusWord: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurSlide(opacity: 0, blur: 6, y: 8), identity: BlurSlide(opacity: 1, blur: 0, y: 0)),
            removal: .modifier(active: BlurSlide(opacity: 0, blur: 5, y: -7), identity: BlurSlide(opacity: 1, blur: 0, y: 0)))
    }
}

struct ControlFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

extension View {
    func zoopControlFrame(_ key: String) -> some View {
        background(GeometryReader { proxy in Color.clear.preference(key: ControlFramesKey.self, value: [key: proxy.frame(in: .named("notch"))]) })
    }
}
