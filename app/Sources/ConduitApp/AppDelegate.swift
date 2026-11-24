// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
import AppKit
import ServiceManagement

/// Menu-bar app that becomes a regular app (Dock icon + menu bar) while its mixer window is open.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, MixerHost {
    let model = MixerModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var window: NSWindow?
    private var clickMonitor: Any?
    private var modalDepth = 0
    /// AppKit closes windows while quitting; that must not count as the user closing the mixer.
    private var terminating = false
    private let defaults = UserDefaults.standard

    private var floatOnTop: Bool { get { defaults.bool(forKey: "floatOnTop") } set { defaults.set(newValue, forKey: "floatOnTop") } }

    // MARK: Launch
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu-bar utility until a window is opened
        NSApp.mainMenu = buildMainMenu()
        model.start()                           // restores the last saved routing and bus settings

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Conduit")
            button.image?.isTemplate = true
            button.toolTip = "Conduit"
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let vc = MixerViewController(model: model, host: self)
        popover.contentViewController = vc
        popover.behavior = .applicationDefined   // closed by us, so Save/Open dialogs do not dismiss it
        popover.animates = true

        // Reopen the window if that is how the app was left.
        if defaults.bool(forKey: "mixerWindowOpen") { DispatchQueue.main.async { [weak self] in self?.showWindow() } }
        // First launch (or after an update): offer to install the bundled audio driver, once per bundled version.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.offerDriverInstallIfNeeded() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { terminating = true; return .terminateNow }
    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }

    /// Double-clicking the app in Finder (or clicking its Dock icon) while it is running opens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    private func offerDriverInstallIfNeeded() {
        let status = DriverInstaller.status()
        guard status.needsAction, let bundled = DriverInstaller.bundledURL else { return }
        let key = "driverOfferDeclined-\(DriverInstaller.version(of: bundled) ?? "?")"
        guard !defaults.bool(forKey: key) else { return }
        var updating = false
        if case .outdated = status { updating = true }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = updating ? "Update the Conduit audio driver?" : "Install the Conduit audio driver?"
        alert.informativeText = "Conduit’s virtual audio device (“Conduit 16ch”) is a small driver that lives in /Library/Audio/Plug-Ins/HAL. macOS will ask for your administrator password and restart Core Audio, so audio pauses for a moment.\n\nWithout it Conduit can still show meters, but it cannot route audio into other apps."
        alert.addButton(withTitle: updating ? "Update Driver" : "Install Driver")
        alert.addButton(withTitle: "Not Now")
        beginModal(); let choice = alert.runModal(); endModal()
        if choice == .alertFirstButtonReturn { installDriver() } else { defaults.set(true, forKey: key) }
    }

    // MARK: Status item and popover
    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp { showStatusMenu(); return }
        if let window, window.isVisible { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        popover.isShown ? closePopover() : showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
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

    private func showStatusMenu() {
        statusItem.menu = makeAppMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: The mixer window (a normal window: standard title bar, resizable, full-screen capable)
    @objc func showWindow() {
        closePopover()
        NSApp.setActivationPolicy(.regular)     // Dock icon and the menu bar appear
        if window == nil {
            let vc = MixerViewController(model: model, host: self, inWindow: true)
            let w = NSWindow(contentViewController: vc)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.title = "Conduit"
            w.collectionBehavior = [.fullScreenPrimary]
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: Layout.width(pairs: model.pairCount), height: Layout.height(rows: Layout.minRows))
            w.setFrameAutosaveName("ConduitMixerWindowV2")
            w.delegate = self
            window = w
            if !w.setFrameUsingName("ConduitMixerWindowV2") { w.center() }
        }
        window?.level = floatOnTop ? .floating : .normal
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        defaults.set(true, forKey: "mixerWindowOpen")
    }

    func windowWillClose(_ notification: Notification) {
        if !terminating { defaults.set(false, forKey: "mixerWindowOpen") }   // only a user close forgets that the window was open
        window = nil
        NSApp.setActivationPolicy(.accessory)   // back to a menu-bar-only app
    }

    @objc private func toggleFloatOnTop() {
        floatOnTop.toggle()
        window?.level = floatOnTop ? .floating : .normal
    }

    // MARK: MixerHost
    func detachMixer() { showWindow() }
    func installDriver() { Task { @MainActor in await runDriverChange(uninstall: false) } }
    func beginModal() { modalDepth += 1 }
    func endModal() { modalDepth = max(0, modalDepth - 1) }

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
                : "“Conduit 16ch” is now available. Choose it as the input device in OBS, Zoom or your DAW, then route apps to it from Conduit’s mixer."
            NSApp.activate(); done.runModal()
        } catch DriverInstaller.Failure.cancelled {
            // The user dismissed the password prompt: nothing changed, nothing to report.
        } catch {
            let a = NSAlert(error: error); a.messageText = uninstall ? "Could not remove the driver" : "Could not install the driver"
            NSApp.activate(); a.runModal()
        }
    }

    // MARK: Menus
    /// The actions menu: shown from the header's ⋯ button and from right-clicking the menu-bar icon.
    func makeAppMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, key: String = "") { menu.addItem(withTitle: title, action: action, keyEquivalent: key).target = self }
        add(window == nil ? "Open Mixer in a Window" : "Show Mixer Window", #selector(showWindow))
        menu.addItem(.separator())
        add("Reconnect to Driver", #selector(reconnect))
        switch DriverInstaller.status() {
        case .notInstalled: add("Install Audio Driver…", #selector(installDriverAction))
        case .outdated: add("Update Audio Driver…", #selector(installDriverAction))
        case .upToDate: add("Reinstall Audio Driver…", #selector(installDriverAction)); add("Uninstall Audio Driver…", #selector(uninstallDriverAction))
        case .notBundled: break
        }
        add("Launch at Login", #selector(toggleLaunchAtLogin))
        menu.item(withTitle: "Launch at Login")?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        add("Show Presets in Finder", #selector(revealPresets))
        menu.addItem(.separator())
        add("About Conduit", #selector(showAbout))
        add("Quit Conduit", #selector(quit), key: "q")
        return menu
    }

    func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ build: (NSMenu) -> Void) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""), menu = NSMenu(title: title)
            build(menu); item.submenu = menu; main.addItem(item)
        }
        func add(_ m: NSMenu, _ title: String, _ action: Selector?, _ key: String = "", mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) {
            let i = m.addItem(withTitle: title, action: action, keyEquivalent: key); i.keyEquivalentModifierMask = mods; i.target = target
        }

        submenu("Conduit") { m in
            add(m, "About Conduit", #selector(showAbout), target: self)
            m.addItem(.separator())
            add(m, "Install or Update Audio Driver…", #selector(installDriverAction), target: self)
            add(m, "Uninstall Audio Driver…", #selector(uninstallDriverAction), target: self)
            add(m, "Reconnect to Driver", #selector(reconnect), target: self)
            add(m, "Launch at Login", #selector(toggleLaunchAtLogin), target: self)
            m.addItem(.separator())
            add(m, "Hide Conduit", #selector(NSApplication.hide(_:)), "h", target: NSApp)
            add(m, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", mods: [.command, .option], target: NSApp)
            add(m, "Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
            m.addItem(.separator())
            add(m, "Quit Conduit", #selector(quit), "q", target: self)
        }
        submenu("File") { m in
            add(m, "Save Routing Preset…", NSSelectorFromString("savePreset"), "s")      // reaches the mixer through the responder chain
            add(m, "Show Presets in Finder", #selector(revealPresets), target: self)
            m.addItem(.separator())
            add(m, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        }
        submenu("Edit") { m in
            add(m, "Undo", Selector(("undo:")), "z"); add(m, "Redo", Selector(("redo:")), "z", mods: [.command, .shift])
            m.addItem(.separator())
            add(m, "Cut", #selector(NSText.cut(_:)), "x"); add(m, "Copy", #selector(NSText.copy(_:)), "c")
            add(m, "Paste", #selector(NSText.paste(_:)), "v"); add(m, "Select All", #selector(NSText.selectAll(_:)), "a")
        }
        submenu("View") { m in
            add(m, "Show Mixer Window", #selector(showWindow), "0", target: self)
            add(m, "Keep Window on Top", #selector(toggleFloatOnTop), "t", mods: [.command, .option], target: self)
            m.addItem(.separator())
            add(m, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", mods: [.command, .control])
        }
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: ""), windowMenu = NSMenu(title: "Window")
        add(windowMenu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(windowMenu, "Zoom", #selector(NSWindow.performZoom(_:)))
        windowMenu.addItem(.separator())
        add(windowMenu, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), target: NSApp)
        windowItem.submenu = windowMenu; main.addItem(windowItem); NSApp.windowsMenu = windowMenu
        submenu("Help") { m in
            add(m, "Conduit on GitHub", #selector(openGitHub), target: self)
            add(m, "Report an Issue", #selector(openIssues), target: self)
        }
        return main
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleLaunchAtLogin): item.state = SMAppService.mainApp.status == .enabled ? .on : .off; return true
        case #selector(toggleFloatOnTop): item.state = floatOnTop ? .on : .off; return true
        case #selector(installDriverAction): return DriverInstaller.bundledURL != nil
        case #selector(uninstallDriverAction): return DriverInstaller.status() == .upToDate || { if case .outdated = DriverInstaller.status() { return true } else { return false } }()
        default: return true
        }
    }

    // MARK: Menu actions
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func reconnect() { model.reconnect() }
    @objc private func installDriverAction() { installDriver() }
    @objc private func openGitHub() { NSWorkspace.shared.open(URL(string: "https://github.com/ShivamHimatsingka/conduit")!) }
    @objc private func openIssues() { NSWorkspace.shared.open(URL(string: "https://github.com/ShivamHimatsingka/conduit/issues")!) }
    @objc private func revealPresets() {
        try? PresetStore.ensureDirectory()
        NSWorkspace.shared.activateFileViewerSelecting([PresetStore.directory])
    }

    @objc private func showAbout() {
        let credits = NSMutableAttributedString(string: "Free, open-source virtual audio router and mixer.\nMIT licensed.\n\n", attributes: [.font: NSFont.systemFont(ofSize: 11)])
        credits.append(NSAttributedString(string: "github.com/ShivamHimatsingka/conduit", attributes: [.font: NSFont.systemFont(ofSize: 11), .link: URL(string: "https://github.com/ShivamHimatsingka/conduit")!]))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Shivam Himatsingka"])
    }

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
            NSApp.activate(); beginModal(); alert.runModal(); endModal()
        }
    }
}
