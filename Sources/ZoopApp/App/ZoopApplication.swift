import AppKit

@main
struct ZoopApplication {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = ZoopAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class ZoopAppDelegate: NSObject, NSApplicationDelegate {
    private let store = CompanionStore()
    private var notch: NotchPanelController?
    private var questionNotifier: QuestionNotifier?
    private var sessionPreview: SessionPreviewWindowController?
    private var statusItem: NSStatusItem?
    private var aboveFullscreen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let notifier = QuestionNotifier(store: store)
        questionNotifier = notifier
        store.notifier = notifier
        let preview = SessionPreviewWindowController(store: store)
        sessionPreview = preview
        store.onExpandPreview = { [weak preview] taskID in preview?.show(taskID: taskID) }
        let controller = NotchPanelController(store: store)
        notch = controller
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Zoop")
            button.toolTip = "Zoop — click to open, right-click for options"
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        controller.excludedScreenRects = { [weak self] in
            guard let button = self?.statusItem?.button, let window = button.window else { return [] }
            return [window.convertToScreen(button.convert(button.bounds, to: nil))]
        }
        controller.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionPreview?.close(); store.onExpandPreview = nil
        notch?.shutdown(); store.shutdown()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func statusClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp, let button = statusItem?.button {
            let menu = NSMenu()
            menu.addItem(item(store.isExpanded ? "Close Zoop" : "Open Zoop", #selector(toggleNotch), key: ""))
            menu.addItem(item("Open exports folder", #selector(openExports), key: ""))
            menu.addItem(.separator())
            let sound = item("UI sounds", #selector(toggleSound), key: "")
            sound.state = store.soundEnabled ? .on : .off
            menu.addItem(sound)
            let level = item("Float above full-screen apps", #selector(toggleLevel), key: "")
            level.state = aboveFullscreen ? .on : .off
            menu.addItem(level)
            menu.addItem(item("Clear conversation", #selector(resetDemo), key: ""))
            menu.addItem(.separator())
            menu.addItem(item("About Zoop", #selector(showAbout), key: ""))
            menu.addItem(item("Quit Zoop", #selector(quit), key: "q"))
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 4), in: button)
        } else { store.toggle() }
    }

    private func item(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func installMainMenu() {
        let main = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Zoop")
        applicationMenu.addItem(item("About Zoop", #selector(showAbout), key: ""))
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(item("Quit Zoop", #selector(quit), key: "q"))
        applicationItem.submenu = applicationMenu
        main.addItem(applicationItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func toggleNotch() { store.toggle() }
    @objc private func openExports() { store.revealExports() }
    @objc private func toggleSound() { store.toggleSound() }
    @objc private func toggleLevel() { aboveFullscreen.toggle(); notch?.setAboveFullscreen(aboveFullscreen) }
    @objc private func resetDemo() { store.reset(); store.openChat() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Your Mac has room for two."
        alert.informativeText = "Zoop base version\n\nChat normally, review a proposed plan, and choose Execute the plan. Approved tasks run inside the separate agent session. Models are configured in ~/.zoop/config.json."
        alert.addButton(withTitle: "Nice")
        alert.runModal()
    }
}
