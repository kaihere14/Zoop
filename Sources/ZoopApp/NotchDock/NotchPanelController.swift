import AppKit
import SwiftUI

private final class NotchPanel: NSPanel {
    var permitsKey = false
    override var canBecomeKey: Bool { permitsKey }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchPanelController: NSObject, NSWindowDelegate {
    private let store: CompanionStore
    private let panel: NotchPanel
    private var hosting: NSHostingView<NotchRootView>?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var metrics = NotchMetrics(screenFrame: .init(x: 0, y: 0, width: 1440, height: 900), hardwareWidth: 160, hardwareHeight: 34, hasPhysicalNotch: false)
    var excludedScreenRects: () -> [CGRect] = { [] }

    init(store: CompanionStore) {
        self.store = store
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        refreshScreen()
        installEventMonitors()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshScreen() }
        }
    }

    func show() { updateGeometry(); panel.orderFrontRegardless() }

    func setAboveFullscreen(_ enabled: Bool) { panel.level = enabled ? .screenSaver : .statusBar }

    private func refreshScreen() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let left = screen.auxiliaryTopLeftArea
        let right = screen.auxiliaryTopRightArea
        let notchWidth = left.flatMap { left in right.map { $0.minX - left.maxX } } ?? 160
        metrics = .init(screenFrame: screen.frame, hardwareWidth: max(160, notchWidth), hardwareHeight: max(34, screen.safeAreaInsets.top), hasPhysicalNotch: screen.safeAreaInsets.top > 0)
        let root = NotchRootView(store: store, metrics: metrics, onWindowGeometryChange: { [weak self] in self?.updateGeometry() })
        if let hosting { hosting.rootView = root }
        else {
            let view = NSHostingView(rootView: root)
            view.sizingOptions = []
            view.autoresizingMask = [.width, .height]
            hosting = view
            panel.contentView = view
        }
        updateGeometry()
    }

    private func updateGeometry() {
        let size = metrics.windowSize(expanded: store.isExpanded, activities: store.destination == .activities)
        let frame = CGRect(x: metrics.screenFrame.midX - size.width / 2, y: metrics.screenFrame.maxY - size.height, width: size.width, height: size.height)
        panel.permitsKey = store.isExpanded
        panel.setFrame(frame, display: true, animate: false)
        if store.isExpanded { panel.makeKeyAndOrderFront(nil) }
        else if panel.isKeyWindow { panel.resignKey() }
    }

    private func installEventMonitors() {
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismissOutside() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents.union(.keyDown)) { [weak self] event in
            let isKey = event.type == .keyDown
            let code: UInt16 = isKey ? event.keyCode : 0
            let flags = event.modifierFlags
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                if isKey { return handleKey(code: code, flags: flags) }
                dismissOutside()
                return false
            }
            return consumed ? nil : event
        }
    }

    private func dismissOutside() {
        guard store.isExpanded else { return }
        let point = NSEvent.mouseLocation
        guard !panel.frame.contains(point), !excludedScreenRects().contains(where: { $0.contains(point) }) else { return }
        store.isExpanded = false
    }

    private func handleKey(code: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard panel.isKeyWindow else { return false }
        if code == 53 { store.isExpanded = false; return true }
        if code == 40, flags.contains(.command) { store.openChat(); return true }
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !excludedScreenRects().contains(where: { $0.contains(NSEvent.mouseLocation) }) else { return }
        if store.isExpanded { store.isExpanded = false }
    }

    func shutdown() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        globalMonitor = nil; localMonitor = nil; screenObserver = nil
        panel.orderOut(nil)
    }
}
