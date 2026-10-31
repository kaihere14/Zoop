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
    private var globalMoveMonitor: Any?
    private var localMoveMonitor: Any?
    private var hoverTask: Task<Void, Never>?
    /// After the island closes under the pointer, hovering must leave and come back before it reopens.
    private var hoverArmed = true
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
        // The window is a transparent rectangle; an AppKit shadow would outline that rectangle.
        // SwiftUI draws the shadow around the rounded island instead.
        panel.hasShadow = false
        panel.acceptsMouseMovedEvents = true
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
        let root = NotchRootView(store: store, metrics: metrics, onStateChange: { [weak self] in self?.stateChanged() })
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

    /// The window keeps one fixed size; only the SwiftUI island inside it animates. Resizing the
    /// window per state would make every open/close jump instead of morph.
    private func updateGeometry() {
        let size = metrics.windowSize
        let frame = CGRect(x: metrics.screenFrame.midX - size.width / 2, y: metrics.screenFrame.maxY - size.height, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true, animate: false) }
        stateChanged()
    }

    /// Screen rectangle of the visible island. Everything else in the window is transparent and click-through.
    private var interactiveRect: CGRect {
        let size = metrics.interactiveSize(expanded: store.isExpanded, activities: store.destination == .activities, busy: store.notchBusy)
        return CGRect(x: metrics.screenFrame.midX - size.width / 2, y: metrics.screenFrame.maxY - size.height, width: size.width, height: size.height)
    }

    private var completionRect: CGRect? {
        guard !store.isExpanded, store.completionAlert != nil else { return nil }
        return CGRect(x: interactiveRect.minX, y: interactiveRect.minY - 10 - NotchMetrics.completionHeight,
                      width: min(NotchMetrics.completionWidth, metrics.expandedWidth), height: NotchMetrics.completionHeight)
    }

    private func containsInteractivePoint(_ point: NSPoint) -> Bool {
        interactiveRect.contains(point) || (completionRect?.contains(point) ?? false)
    }

    private func stateChanged() {
        panel.permitsKey = store.isExpanded
        if store.isExpanded {
            hoverTask?.cancel(); hoverTask = nil
            panel.makeKeyAndOrderFront(nil)
        } else {
            if panel.isKeyWindow { panel.resignKey() }
            if interactiveRect.contains(NSEvent.mouseLocation) { hoverArmed = false }
        }
        updateMousePassThrough()
    }

    /// A transparent window still captures clicks over its whole frame, so we toggle
    /// `ignoresMouseEvents` as the pointer enters or leaves the island.
    private func updateMousePassThrough() {
        let inside = containsInteractivePoint(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
    }

    private func mouseMoved() {
        updateMousePassThrough()
        let inside = interactiveRect.contains(NSEvent.mouseLocation)
        if inside { store.recordInteraction() }
        guard !store.isExpanded else { return }
        if !inside {
            hoverArmed = true
            hoverTask?.cancel(); hoverTask = nil
        } else if hoverArmed, hoverTask == nil {
            // A short dwell avoids opening when the pointer only passes by on its way to the menu bar.
            hoverTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                self.hoverTask = nil
                if !self.store.isExpanded, self.interactiveRect.contains(NSEvent.mouseLocation) { self.store.isExpanded = true }
            }
        }
    }

    private func installEventMonitors() {
        let moveEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        globalMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: moveEvents) { [weak self] _ in
            Task { @MainActor [weak self] in self?.mouseMoved() }
        }
        localMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: moveEvents) { [weak self] event in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return event
        }
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismissOutside() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents.union([.keyDown, .scrollWheel])) { [weak self] event in
            let isKey = event.type == .keyDown
            let code: UInt16 = isKey ? event.keyCode : 0
            let flags = event.modifierFlags
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                if isKey { return self.handleKey(code: code, flags: flags) }
                if self.containsInteractivePoint(NSEvent.mouseLocation) { self.store.recordInteraction() }
                self.dismissOutside()
                return false
            }
            return consumed ? nil : event
        }
    }

    private func dismissOutside() {
        guard store.isExpanded else { return }
        let point = NSEvent.mouseLocation
        guard !containsInteractivePoint(point), !excludedScreenRects().contains(where: { $0.contains(point) }) else { return }
        store.isExpanded = false
    }

    private func handleKey(code: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard panel.isKeyWindow else { return false }
        store.recordInteraction()
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
        if let globalMoveMonitor { NSEvent.removeMonitor(globalMoveMonitor) }
        if let localMoveMonitor { NSEvent.removeMonitor(localMoveMonitor) }
        hoverTask?.cancel(); hoverTask = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        globalMonitor = nil; localMonitor = nil; globalMoveMonitor = nil; localMoveMonitor = nil; screenObserver = nil
        panel.orderOut(nil)
    }
}
