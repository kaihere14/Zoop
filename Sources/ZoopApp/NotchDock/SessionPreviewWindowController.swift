import AppKit
import SwiftUI

enum SessionPreviewGeometry {
    static func initialFrame(in visibleFrame: CGRect) -> CGRect {
        let size = CGSize(width: min(visibleFrame.width, max(360, visibleFrame.width / 2)),
                          height: min(visibleFrame.height, max(240, visibleFrame.height / 2)))
        return CGRect(x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}

/// One detachable viewer. It observes the same task-scoped screenshots as the notch;
/// moving, resizing or closing it never changes execution or starts another capture loop.
@MainActor
final class SessionPreviewWindowController {
    private let store: CompanionStore
    private var panel: NSPanel?
    private var closeObserver: NSObjectProtocol?

    init(store: CompanionStore) { self.store = store }

    func show(taskID: UUID) {
        guard store.task(taskID) != nil else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens.first
        if panel == nil {
            let frame = SessionPreviewGeometry.initialFrame(in: screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900))
            let window = NSPanel(contentRect: frame, styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            window.setFrame(frame, display: false)
            window.title = "Zoop — Agent workspace"
            window.contentMinSize = CGSize(width: min(360, frame.width), height: min(240, frame.height))
            window.isReleasedWhenClosed = false
            window.isFloatingPanel = true
            window.hidesOnDeactivate = false
            window.level = .floating
            window.appearance = NSAppearance(named: .darkAqua)
            window.collectionBehavior = [.fullScreenAuxiliary]
            window.standardWindowButton(.zoomButton)?.isHidden = true
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.store.isPreviewWindowOpen = false }
            }
            panel = window
        }
        guard let panel else { return }
        let hosting = NSHostingView(rootView: SessionPreviewWindowView(store: store, taskID: taskID))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        // Keep the person's last size and position, but recover a window whose display
        // was disconnected while it was closed.
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }), let screen {
            panel.setFrame(SessionPreviewGeometry.initialFrame(in: screen.visibleFrame), display: false)
        }
        panel.makeKeyAndOrderFront(nil)
        store.isPreviewWindowOpen = true
    }

    func close() { panel?.close() }
}

private struct SessionPreviewWindowView: View {
    @Bindable var store: CompanionStore
    let taskID: UUID

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.task(taskID)?.title ?? "Agent workspace").font(.headline).lineLimit(1)
                    Text(store.task(taskID)?.statusNote ?? "Latest observed screen")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Text("PREVIEW").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(14)
            ZStack {
                Color.black
                if let data = store.screenshot(for: taskID), let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit()
                        .accessibilityLabel("Latest screenshot of the agent session")
                } else {
                    Text(store.task(taskID) == nil ? "This task is no longer available." : "Waiting for the agent’s next screenshot…")
                        .font(.callout).foregroundStyle(.secondary).padding()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("Live view of the agent session · Drag the title bar to move; drag an edge to resize")
                .font(.system(size: 10)).foregroundStyle(.secondary).padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
    }
}
