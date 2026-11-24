// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// Menu-bar app that becomes a regular app (Dock icon + menu bar) while any of its windows is open.
///
/// One rule keeps windows from getting lost: **the popover is closed before anything else is shown.** The popover lives at the
/// status-bar window level, above normal windows and alerts, so an About box, Settings window or dialog opened while it was up
/// used to appear *behind* it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, NSPopoverDelegate, MixerHost, SettingsHost {
    let model = MixerModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var mixerWindow: NSWindow?
    private var settings: SettingsWindowController?
    private var about: AboutWindowController?
    private var clickMonitor: Any?, keyMonitor: Any?
    private var modalDepth = 0
    /// AppKit closes windows while quitting; that must not count as the user closing the mixer.
    private var terminating = false
    private let defaults = UserDefaults.standard

    // MARK: Launch
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.apply()                      // dark unless the user chose otherwise
        NSApp.setActivationPolicy(AppSettings.showInDock ? .regular : .accessory)
        NSApp.mainMenu = buildMainMenu()
        model.start()                            // restores the last saved routing and bus settings

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Conduit")
            button.image?.isTemplate = true
            button.toolTip = "Conduit"
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.contentViewController = MixerViewController(model: model, host: self)
        popover.behavior = .applicationDefined   // closed by us (outside click, Esc, status item), never by activation churn
        popover.animates = true
        popover.delegate = self
        TestHooks.shared.popoverShown = { [weak self] in self?.popover.isShown ?? false }
        TestHooks.shared.routing = { [weak self] in
            guard let m = self?.model else { return [:] }
            return ["sources": m.routing.mapValues { ["enabled": $0.enabled, "pairs": $0.pairs, "gainDB": Double($0.gainDB), "mute": $0.mute] as [String: Any] },
                    "buses": m.buses.map { ["gainDB": Double($0.gainDB), "mute": $0.mute] as [String: Any] }, "rows": m.rows.map { ["id": $0.id, "available": $0.available] as [String: Any] }]
        }
        TestHooks.shared.register("statusItem") { [weak self] in self?.statusItem.button }
        TestHooks.shared.start()

        NotificationCenter.default.addObserver(forName: AppSettings.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        settingsChanged()

        switch AppSettings.launchBehavior {
        case .window: DispatchQueue.main.async { [weak self] in self?.showWindow() }
        case .restore: if defaults.bool(forKey: "mixerWindowOpen") { DispatchQueue.main.async { [weak self] in self?.showWindow() } }
        case .menuBar: break
        }
        // First launch (or after an update): offer to install the bundled audio driver, once per bundled version.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.offerDriverInstallIfNeeded() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { terminating = true; return .terminateNow }
    func applicationWillTerminate(_ notification: Notification) { GlobalHotKey.shared.unregister(); model.shutdown() }

    /// Double-clicking the app in Finder (or clicking its Dock icon) while it is running opens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    /// Settings changed (from the Settings window or elsewhere): apply everything that is live.
    private func settingsChanged() {
        AppSettings.apply()
        popover.appearance = AppSettings.appearance.nsAppearance
        mixerWindow?.level = AppSettings.floatOnTop ? .floating : .normal
        updateActivationPolicy()
        if AppSettings.globalShortcut {
            GlobalHotKey.shared.register(keyCode: kVK_ANSI_M, modifiers: cmdKey | optionKey | controlKey) { [weak self] in
                TestHooks.shared.note("global shortcut pressed")
                self?.showWindow()
            }
        } else { GlobalHotKey.shared.unregister() }
        model.settingsChanged()
    }

    private func offerDriverInstallIfNeeded() {
        let status = DriverInstaller.status()
        guard status.needsAction, let bundled = DriverInstaller.bundledURL else { return }
        let key = "driverOfferDeclined-\(DriverInstaller.version(of: bundled) ?? "?")"
        guard !defaults.bool(forKey: key) else { return }
        var updating = false
        if case .outdated = status { updating = true }
        let alert = NSAlert()
        alert.messageText = updating ? "Update the Conduit audio driver?" : "Install the Conduit audio driver?"
        alert.informativeText = "Conduit’s virtual audio device (“Conduit 16ch”) is a small driver that lives in /Library/Audio/Plug-Ins/HAL. macOS will ask for your administrator password and restart Core Audio, so audio pauses for a moment.\n\nWithout it Conduit can still show meters, but it cannot route audio into other apps."
        alert.addButton(withTitle: updating ? "Update Driver" : "Install Driver")
        alert.addButton(withTitle: "Not Now")
        beginModal(); let choice = alert.runModal(); endModal()
        if choice == .alertFirstButtonReturn { installDriver() } else { defaults.set(true, forKey: key) }
    }

    // MARK: Activation policy: a regular app (Dock icon, menu bar) while a window is open or if the user wants the Dock icon
    private var anyWindowOpen: Bool { [mixerWindow, settings?.window, about?.window].contains { $0?.isVisible == true } }
    private func updateActivationPolicy() {
        let wanted: NSApplication.ActivationPolicy = (AppSettings.showInDock || anyWindowOpen) ? .regular : .accessory
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
    }

    /// Brings a window to the front, for real: popover out of the way, regular policy (menu bar + Dock), app activated, window ordered front.
    private func present(_ window: NSWindow) {
        closePopover(reason: "presenting \(window.title)")
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if w === mixerWindow {
            if !terminating { defaults.set(false, forKey: "mixerWindowOpen") }   // only a user close forgets that the window was open
            mixerWindow = nil
        }
        DispatchQueue.main.async { [weak self] in self?.updateActivationPolicy() }
    }

    // MARK: Status item and popover
    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp { showStatusMenu(); return }
        if let mixerWindow, mixerWindow.isVisible { present(mixerWindow); return }
        TestHooks.shared.note(popover.isShown ? "status item click: closing popover" : "status item click: opening popover")
        popover.isShown ? closePopover(reason: "status item") : showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate()
        popover.contentViewController?.view.window?.makeKey()
        // Close on a click anywhere outside the app, and on Esc. (A click inside our own windows is not "outside".)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.modalDepth == 0 else { return }
                self.closePopover(reason: "click outside the app")
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == UInt16(kVK_Escape), self.popover.isShown else { return event }
            self.closePopover(reason: "Esc")
            return nil
        }
    }

    func closePopover(reason: String = "") {
        guard popover.isShown else { return }
        TestHooks.shared.note("closePopover: \(reason)")
        popover.performClose(nil)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    func popoverDidShow(_ notification: Notification) { TestHooks.shared.note("popoverDidShow") }
    func popoverDidClose(_ notification: Notification) { TestHooks.shared.note("popoverDidClose") }

    private func showStatusMenu() {
        let m = makeAppMenu(); TestHooks.shared.watch(m)
        statusItem.menu = m
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: Windows
    @objc func showWindow() {
        if mixerWindow == nil {
            let vc = MixerViewController(model: model, host: self, inWindow: true)
            let w = NSWindow(contentViewController: vc)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.title = "Conduit"
            w.collectionBehavior = [.fullScreenPrimary]
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: Layout.width(pairs: model.pairCount), height: Layout.height(rows: Layout.minRows))
            w.setFrameAutosaveName("ConduitMixerWindowV2")
            w.delegate = self
            mixerWindow = w
            if !w.setFrameUsingName("ConduitMixerWindowV2") { w.center() }
        }
        mixerWindow?.level = AppSettings.floatOnTop ? .floating : .normal
        defaults.set(true, forKey: "mixerWindowOpen")
        present(mixerWindow!)
    }

    @objc func showSettings() {
        if settings == nil {
            let c = SettingsWindowController(model: model, host: self)
            c.onClose = { [weak self] in DispatchQueue.main.async { self?.settings = nil; self?.updateActivationPolicy() } }
            settings = c
        }
        settings?.refresh()
        present(settings!.window)
    }

    @objc func showAbout() {
        if about == nil {
            let c = AboutWindowController()
            c.onClose = { [weak self] in DispatchQueue.main.async { self?.about = nil; self?.updateActivationPolicy() } }
            about = c
        }
        present(about!.window)
    }

    // MARK: MixerHost
    func detachMixer() { showWindow() }
    func installDriver() { Task { @MainActor in await runDriverChange(uninstall: false) } }
    /// Every dialog goes through here: the popover (which would cover it) is closed and the app is brought forward first.
    func beginModal() { modalDepth += 1; closePopover(reason: "dialog"); NSApp.activate() }
    func endModal() { modalDepth = max(0, modalDepth - 1) }

    /// Runs the admin-prompted install/uninstall, then reconnects once Core Audio has restarted.
    private func runDriverChange(uninstall: Bool) async {
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
        add(mixerWindow == nil ? "Open Mixer in a Window" : "Show Mixer Window", #selector(showWindow))
        menu.addItem(.separator())
        add("Reconnect to Driver", #selector(reconnect))
        switch DriverInstaller.status() {
        case .notInstalled: add("Install Audio Driver…", #selector(installDriverAction))
        case .outdated: add("Update Audio Driver…", #selector(installDriverAction))
        case .upToDate: add("Reinstall Audio Driver…", #selector(installDriverAction)); add("Uninstall Audio Driver…", #selector(uninstallDriverAction))
        case .notBundled: break
        }
        add("Launch at Login", #selector(toggleLaunchAtLogin))
        menu.item(withTitle: "Launch at Login")?.state = launchAtLoginEnabled ? .on : .off
        add("Show Presets in Finder", #selector(revealPresets))
        menu.addItem(.separator())
        add("Settings…", #selector(showSettings), key: ",")
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
            add(m, "Settings…", #selector(showSettings), ",", target: self)
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
        case #selector(toggleLaunchAtLogin): item.state = launchAtLoginEnabled ? .on : .off; return true
        case #selector(toggleFloatOnTop): item.state = AppSettings.floatOnTop ? .on : .off; return true
        case #selector(installDriverAction): return DriverInstaller.bundledURL != nil
        case #selector(uninstallDriverAction): return DriverInstaller.status() == .upToDate || { if case .outdated = DriverInstaller.status() { return true } else { return false } }()
        default: return true
        }
    }

    // MARK: Menu actions
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func reconnect() { model.reconnect() }
    @objc private func installDriverAction() { installDriver() }
    @objc private func toggleFloatOnTop() { AppSettings.floatOnTop.toggle() }
    @objc private func openGitHub() { NSWorkspace.shared.open(URL(string: "https://github.com/ShivamHimatsingka/conduit")!) }
    @objc private func openIssues() { NSWorkspace.shared.open(URL(string: "https://github.com/ShivamHimatsingka/conduit/issues")!) }
    @objc func revealPresets() {
        try? PresetStore.ensureDirectory()
        NSWorkspace.shared.activateFileViewerSelecting([PresetStore.directory])
    }

    @objc func uninstallDriverAction() {
        beginModal(); defer { endModal() }
        let confirm = NSAlert()
        confirm.messageText = "Remove the Conduit audio driver?"
        confirm.informativeText = "“Conduit 16ch” disappears from your audio devices and apps routed through it fall back to their default device. macOS will ask for your administrator password and restart Core Audio."
        confirm.addButton(withTitle: "Remove Driver"); confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in await self.runDriverChange(uninstall: true) }
    }

    // MARK: SettingsHost
    func uninstallDriver() { uninstallDriverAction() }
    func reconnectDriver() { model.reconnect() }
    var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }
    func setLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do { if on { try service.register() } else { try service.unregister() } }
        catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Could not change the login item"
            alert.informativeText = "Launch at Login only works when Conduit is run from /Applications.\n\n\(error.localizedDescription)"
            beginModal(); alert.runModal(); endModal()
        }
    }
    /// Registers/unregisters the login item (macOS 13+ API; only works from an installed .app bundle).
    @objc private func toggleLaunchAtLogin() { setLaunchAtLogin(!launchAtLoginEnabled) }
}

/// A system-wide shortcut (Carbon hot key: needs no accessibility permission).
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    nonisolated(unsafe) fileprivate static var action: (() -> Void)?
    private var ref: EventHotKeyRef?, handler: EventHandlerRef?

    func register(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        unregister()
        Self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { GlobalHotKey.action?() }
            return noErr
        }, 1, &spec, nil, &handler)
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: 0x434E4454, id: 1), GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        Self.action = nil
    }
}
