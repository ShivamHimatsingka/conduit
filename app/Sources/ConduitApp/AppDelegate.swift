// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, MixerHost {
    let model = MixerModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var panel: NSPanel?
    private var clickMonitor: Any?
    private var modalDepth = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu-bar utility: no Dock icon, no menu bar of its own
        model.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Conduit")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let vc = MixerViewController(model: model, host: self)
        popover.contentViewController = vc
        popover.behavior = .applicationDefined   // we close it ourselves so Save/Open dialogs do not dismiss it
        popover.animates = true
    }

    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }

    // MARK: Status item
    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(); return }
        if let panel, panel.isVisible { panel.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        popover.isShown ? closePopover() : showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.contentSize = NSSize(width: Layout.width(pairs: model.pairCount), height: 470)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.modalDepth == 0 else { return }
                self.closePopover()
            }
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Floating Mixer", action: #selector(detachMixerAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reconnect to Driver", action: #selector(reconnect), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show Presets in Finder", action: #selector(revealPresets), keyEquivalent: "").target = self
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Conduit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func detachMixerAction() { detachMixer() }
    @objc private func reconnect() { model.reconnect() }

    /// Registers the app as a login item (macOS 13+ API; only works from an installed .app bundle).
    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Could not change the login item"
            alert.informativeText = "Launch at Login only works when Conduit is run from /Applications.\n\n\(error.localizedDescription)"
            beginModal(); alert.runModal(); endModal()
        }
    }
    @objc private func revealPresets() {
        try? PresetStore.ensureDirectory()
        NSWorkspace.shared.activateFileViewerSelecting([PresetStore.directory])
    }

    // MARK: MixerHost
    func detachMixer() {
        closePopover()
        if let panel { panel.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let vc = MixerViewController(model: model, host: self)
        let p = NSPanel(contentViewController: vc)
        p.styleMask = [.titled, .closable, .resizable, .utilityWindow]
        p.title = "Conduit Mixer"
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: Layout.width(pairs: model.pairCount), height: 380)
        p.setFrameAutosaveName("ConduitMixerPanel")
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.panel = nil }
        }
        panel = p
        p.center()
        p.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
    func beginModal() { modalDepth += 1 }
    func endModal() { modalDepth = max(0, modalDepth - 1) }
}
