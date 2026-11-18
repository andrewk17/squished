import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let renderer = MenuBarRenderer()
    private let store: FleetStore
    private var settingsWindow: SettingsWindowController?
    private var appearanceObserver: NSKeyValueObservation?
    /// `.transient` only notices outside clicks while the app is active, which a menu
    /// bar app usually isn't, so clicks in other apps are watched here as well.
    private var outsideClickMonitor: Any?
    init(store: FleetStore) {
        self.store = store
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        // A stable name lets macOS remember where the user ⌘-dragged the item.
        item.autosaveName = "SquishedStatusItem"
        // ⌘-dragging the item off the menu bar quits Squished (a hidden Squished would keep
        // running with no way in). macOS remembers the removal, so show it again on launch.
        item.behavior = [.removalAllowed, .terminationOnRemoval]
        item.isVisible = true
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))

            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            if #available(macOS 27.0, *) {
                // macOS 27 opens and closes custom panels through an expanded-interface
                // session instead of target/action toggling, so menu bar tracking, keyboard
                // navigation and the overflow area know about the panel. The button keeps
                // right-click (the small menu) only.
                item.expandedInterfaceDelegate = self
                button.sendAction(on: [.rightMouseUp])
            }
            button.setAccessibilityLabel("Squished")
            appearanceObserver = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in

                Task { @MainActor in

                    // AppKit can notify during drawing without an appearance change.
                    // The renderer key already includes appearance; preserve its cache.
                    self?.render()
                }
            }
        }

        store.onMenuChange = { [weak self] in
            self?.render()
        }

        render()
    }

    private var deferredRender = false

    private func render() {
        guard let button = item.button else {
            return
        }

        // Swapping the image during a ⌘-drag cancels the system's reorder. While ⌘ is
        // held, check again shortly instead of redrawing (no keyboard monitor needed).
        if NSEvent.modifierFlags.contains(.command) {
            if !deferredRender {
                deferredRender = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.deferredRender = false
                    self?.render()
                }
            }
            return
        }

        let description = renderer.accessibilityLabel(store: store)
        button.setAccessibilityLabel(description)
        button.toolTip = description
        let image = renderer.image(store: store, appearance: button.effectiveAppearance)
        if button.image !== image {
            button.image = image
        }
    }

    @objc private func clicked(_ sender: Any?) {
        // A ⌘-drag (menu bar reordering) ends with this mouse-up. Opening the panel or
        // activating the app here makes the menu bar snap the item back before macOS
        // saves its new position, so leave ⌘-clicks to the system.
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            return
        }

        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Squished", action: #selector(quit), keyEquivalent: "q").target = self
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
            return
        }

        if popover.isShown {
            popover.performClose(nil)
            return
        }

        showPanel()
    }

    fileprivate func showPanel() {
        guard !popover.isShown, let button = item.button else {
            return
        }

        let height = (button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let controller = NSHostingController(
            rootView: HostedPanelView(
                store: store,
                settings: { [weak self] in
                    self?.openSettings()
                },
                maximumHeight: height * 0.8
            )
        )
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        store.setPanelVisible(true)
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Global monitors see clicks in other apps only (never our own windows), and
        // mouse events need no Accessibility permission.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            Task { @MainActor in
                self?.popover.performClose(nil)
            }
        }
    }

    fileprivate func closePanel() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
        // Closed by us (outside click, Settings…): tell macOS the session is over.
        if #available(macOS 27.0, *) {
            item.expandedInterfaceSession?.cancel()
        }
        store.setPanelVisible(false)
        // Dispose of the SwiftUI tree: closed panels perform no view updates.
        popover.contentViewController = nil
    }

    @objc private func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(store: store)
        }

        settingsWindow?.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func stop() {
        removeOutsideClickMonitor()
        popover.performClose(nil)
        store.onMenuChange = nil
        NSStatusBar.system.removeStatusItem(item)
    }
}

@available(macOS 27.0, *)
extension StatusItemController: NSStatusItemExpandedInterfaceDelegate {
    // AppKit calls these on the main thread; the protocol itself isn't main-actor bound.
    nonisolated func statusItem(_ statusItem: NSStatusItem,
                                didBegin session: NSStatusItemExpandedInterfaceSession) {
        MainActor.assumeIsolated { showPanel() }
    }

    nonisolated func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        MainActor.assumeIsolated { closePanel() }
    }
}
