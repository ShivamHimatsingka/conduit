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

        // First launch (or after an update): offer to install the bundled audio driver, once per bundled version.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.offerDriverInstallIfNeeded() }
    }

    private func offerDriverInstallIfNeeded() {
        let status = DriverInstaller.status()
        guard status.needsAction, let bundled = DriverInstaller.bundledURL else { return }
        let key = "driverOfferDeclined-\(DriverInstaller.version(of: bundled) ?? "?")"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        var updating = false
        if case .outdated = status { updating = true }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = updating ? "Update the Conduit audio driver?" : "Install the Conduit audio driver?"
        alert.informativeText = "Conduit’s virtual audio device (“Conduit 16ch”) is a small driver that lives in /Library/Audio/Plug-Ins/HAL. macOS will ask for your administrator password and restart Core Audio, so audio pauses for a moment.\n\nWithout it Conduit can still show meters, but it cannot route audio into other apps."
        alert.addButton(withTitle: updating ? "Update Driver" : "Install Driver")
        alert.addButton(withTitle: "Not Now")
        beginModal(); let choice = alert.runModal(); endModal()
        if choice == .alertFirstButtonReturn { installDriver() } else { UserDefaults.standard.set(true, forKey: key) }
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
        switch DriverInstaller.status() {
        case .notInstalled: menu.addItem(withTitle: "Install Audio Driver…", action: #selector(installDriverAction), keyEquivalent: "").target = self
        case .outdated: menu.addItem(withTitle: "Update Audio Driver…", action: #selector(installDriverAction), keyEquivalent: "").target = self
        case .upToDate: menu.addItem(withTitle: "Uninstall Audio Driver…", action: #selector(uninstallDriverAction), keyEquivalent: "").target = self
        case .notBundled: break
        }
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
    @objc private func installDriverAction() { installDriver() }

    @objc private func uninstallDriverAction() {
        let confirm = NSAlert()
        confirm.messageText = "Remove the Conduit audio driver?"
        confirm.informativeText = "“Conduit 16ch” disappears from your audio devices and apps routed through it fall back to their default device. macOS will ask for your administrator password and restart Core Audio."
        confirm.addButton(withTitle: "Remove Driver"); confirm.addButton(withTitle: "Cancel")
        NSApp.activate(); beginModal(); let choice = confirm.runModal(); endModal()
        guard choice == .alertFirstButtonReturn else { return }
        Task { @MainActor in await self.runDriverChange(uninstall: true) }
    }

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
    func installDriver() { Task { @MainActor in await runDriverChange(uninstall: false) } }

    /// Runs the admin-prompted install/uninstall, then reconnects once Core Audio has restarted.
    private func runDriverChange(uninstall: Bool) async {
        closePopover()
        beginModal(); defer { endModal() }
        do {
            if uninstall { try await DriverInstaller.uninstall() } else { try await DriverInstaller.install() }
            try? await Task.sleep(for: .seconds(2.5))   // coreaudiod restarts and the driver registers its Mach service
            model.driverChanged()
            try? await Task.sleep(for: .seconds(2))
            model.refreshSources()
            let done = NSAlert()
            done.messageText = uninstall ? "Audio driver removed" : "Audio driver installed"
            done.informativeText = uninstall ? "“Conduit 16ch” is no longer available."
                : "“Conduit 16ch” is now available. Choose it as the input device in OBS, Zoom or your DAW, then route apps to it from Conduit’s menu-bar mixer."
            NSApp.activate(); done.runModal()
        } catch DriverInstaller.Failure.cancelled {
            // The user dismissed the password prompt: nothing changed, nothing to report.
        } catch {
            let a = NSAlert(error: error); a.messageText = uninstall ? "Could not remove the driver" : "Could not install the driver"
            NSApp.activate(); a.runModal()
        }
    }

    func beginModal() { modalDepth += 1 }
    func endModal() { modalDepth = max(0, modalDepth - 1) }
}
