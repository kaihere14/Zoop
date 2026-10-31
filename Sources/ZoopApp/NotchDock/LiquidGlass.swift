import AppKit
import SwiftUI

private struct NativeGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct LiquidGlass: View {
    var expanded: Bool
    var working: Bool

    private var shape: UnevenRoundedRectangle {
        .init(topLeadingRadius: 0, bottomLeadingRadius: expanded ? 28 : 18,
              bottomTrailingRadius: expanded ? 28 : 18, topTrailingRadius: 0)
    }

    var body: some View {
        ZStack {
            NativeGlass()
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: Color(red: 0.02, green: 0.02, blue: 0.03).opacity(0.98), location: 0.12),
                .init(color: Color(red: 0.06, green: 0.07, blue: 0.09).opacity(0.72), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            if !expanded { Color.black }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(expanded ? 0.2 : 0), .white.opacity(0.025), ZoopTheme.lime.opacity(expanded ? 0.12 : 0)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .shadow(color: .black.opacity(expanded ? 0.4 : 0.15), radius: expanded ? 30 : 5, y: 15)
        .shadow(color: ZoopTheme.lime.opacity(expanded ? working ? 0.16 : 0.07 : 0), radius: 28, y: 24)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
