// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
import AppKit

@MainActor
protocol SettingsHost: AnyObject {
    var launchAtLoginEnabled: Bool { get }
    func setLaunchAtLogin(_ on: Bool)
    func installDriver()
    func uninstallDriver()
    func reconnectDriver()
    func revealPresets()
}

/// The Settings window (⌘,): appearance, window behaviour, startup, capture latency, meters, driver and saved data.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, MixerModelObserver {
    let window: NSWindow
    private unowned let model: MixerModel
    private unowned let host: SettingsHost
    var onClose: (() -> Void)?

    private let appearance = NSSegmentedControl(labels: AppSettings.Appearance.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let floatOnTop = NSButton(checkboxWithTitle: "Keep the mixer window above other windows", target: nil, action: nil)
    private let showInDock = NSButton(checkboxWithTitle: "Show Conduit in the Dock and menu bar", target: nil, action: nil)
    private let launchBehavior = NSPopUpButton(frame: .zero, pullsDown: false)
    private let shortcut = NSButton(checkboxWithTitle: "Open the mixer with ⌃⌥⌘M, even if the menu-bar icon is hidden", target: nil, action: nil)
    private let login = NSButton(checkboxWithTitle: "Open Conduit when I log in", target: nil, action: nil)
    private let latency = NSPopUpButton(frame: .zero, pullsDown: false)
    private let peakHold = NSPopUpButton(frame: .zero, pullsDown: false)
    private let driverStatus = NSTextField(wrappingLabelWithString: "")
    private let installButton = NSButton(title: "Install Driver…", target: nil, action: nil)
    private let uninstallButton = NSButton(title: "Uninstall…", target: nil, action: nil)
    private let reconnectButton = NSButton(title: "Reconnect", target: nil, action: nil)
    private let revealButton = NSButton(title: "Show Presets in Finder", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset Saved Routing…", target: nil, action: nil)

    init(model: MixerModel, host: SettingsHost) {
        self.model = model; self.host = host
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Conduit Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("ConduitSettingsWindow")
        build()
        refresh()
        model.addObserver(self)
        NotificationCenter.default.addObserver(forName: AppSettings.changed, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        if !window.setFrameUsingName("ConduitSettingsWindow") { window.center() }
    }

    func modelStructureChanged() { refresh() }
    func windowWillClose(_ notification: Notification) { onClose?() }

    // MARK: Layout
    private func heading(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text); l.font = .systemFont(ofSize: 11, weight: .semibold); l.textColor = .secondaryLabelColor; return l
    }
    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text); l.font = .systemFont(ofSize: 13); l.alignment = .right; return l
    }
    private func note(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text); l.font = .systemFont(ofSize: 11); l.textColor = .secondaryLabelColor; l.preferredMaxLayoutWidth = 300; return l
    }

    private func build() {
        for p in [latency, peakHold, launchBehavior] { p.controlSize = .regular }
        appearance.segmentStyle = .rounded
        appearance.segmentDistribution = .fillEqually
        AppSettings.Latency.allCases.forEach { latency.addItem(withTitle: $0.title) }
        AppSettings.PeakHold.allCases.forEach { peakHold.addItem(withTitle: $0.title) }
        AppSettings.LaunchBehavior.allCases.forEach { launchBehavior.addItem(withTitle: $0.title) }
        let controls: [(NSControl, Selector)] = [(appearance, #selector(appearanceChanged)), (floatOnTop, #selector(floatChanged)), (showInDock, #selector(dockChanged)),
            (launchBehavior, #selector(launchChanged)), (shortcut, #selector(shortcutChanged)), (login, #selector(loginChanged)), (latency, #selector(latencyChanged)),
            (peakHold, #selector(holdChanged)), (installButton, #selector(installTapped)), (uninstallButton, #selector(uninstallTapped)),
            (reconnectButton, #selector(reconnectTapped)), (revealButton, #selector(revealTapped)), (resetButton, #selector(resetTapped))]
        for (c, a) in controls { c.target = self; c.action = a }
        driverStatus.font = .systemFont(ofSize: 12); driverStatus.preferredMaxLayoutWidth = 300

        let driverButtons = NSStackView(views: [installButton, uninstallButton, reconnectButton]); driverButtons.spacing = 8
        let dataButtons = NSStackView(views: [revealButton, resetButton]); dataButtons.spacing = 8
        let windowChecks = NSStackView(views: [floatOnTop, showInDock]); windowChecks.orientation = .vertical; windowChecks.alignment = .leading; windowChecks.spacing = 6
        let startupChecks = NSStackView(views: [shortcut, login]); startupChecks.orientation = .vertical; startupChecks.alignment = .leading; startupChecks.spacing = 6
        let audioNote = note("Smaller buffers lower the delay of captured apps and microphones but use more CPU. Takes effect immediately.")
        let driverNote = driverStatus

        let rows: [[NSView]] = [
            [heading("APPEARANCE"), NSView()],
            [label("Theme"), appearance],
            [heading("WINDOW"), NSView()],
            [label("Mixer window"), windowChecks],
            [label("At launch"), launchBehavior],
            [label("Shortcut"), startupChecks],
            [heading("AUDIO"), NSView()],
            [label("Capture latency"), latency],
            [NSView(), audioNote],
            [label("Peak hold"), peakHold],
            [heading("AUDIO DRIVER"), NSView()],
            [label("Status"), driverNote],
            [NSView(), driverButtons],
            [heading("YOUR DATA"), NSView()],
            [label("Presets"), dataButtons],
        ]
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10; grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing; grid.column(at: 0).width = 120
        for i in rows.indices where rows[i][0] is NSTextField && (rows[i][0] as! NSTextField).font?.pointSize == 11 { grid.row(at: i).topPadding = 12 }
        let footer = NSTextField(labelWithString: "Conduit \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") · MIT licensed · github.com/ShivamHimatsingka/conduit")
        footer.font = .systemFont(ofSize: 11); footer.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [grid, footer]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
        window.contentMinSize = stack.fittingSize

        if TestHooks.enabled {
            let h = TestHooks.shared
            for (name, view) in [("appearance", appearance as NSView), ("float", floatOnTop), ("dock", showInDock), ("launch", launchBehavior), ("shortcut", shortcut), ("login", login),
                                 ("latency", latency), ("peakHold", peakHold), ("install", installButton), ("uninstall", uninstallButton), ("reconnect", reconnectButton),
                                 ("reveal", revealButton), ("reset", resetButton)] { h.register("settings.\(name)") { [weak view] in view } }
            h.register("settings.appearance.dark") { [weak self] in self.map { ($0.appearance, $0.segmentRect(0)) } }
            h.register("settings.appearance.light") { [weak self] in self.map { ($0.appearance, $0.segmentRect(1)) } }
            h.register("settings.appearance.system") { [weak self] in self.map { ($0.appearance, $0.segmentRect(2)) } }
        }
    }

    private func segmentRect(_ i: Int) -> NSRect {
        let w = appearance.bounds.width / CGFloat(max(appearance.segmentCount, 1))   // segments are equal width
        return NSRect(x: w * CGFloat(i), y: 0, width: w, height: appearance.bounds.height)
    }

    // MARK: State
    func refresh() {
        appearance.selectedSegment = AppSettings.Appearance.allCases.firstIndex(of: AppSettings.appearance) ?? 0
        floatOnTop.state = AppSettings.floatOnTop ? .on : .off
        showInDock.state = AppSettings.showInDock ? .on : .off
        launchBehavior.selectItem(at: AppSettings.LaunchBehavior.allCases.firstIndex(of: AppSettings.launchBehavior) ?? 0)
        shortcut.state = AppSettings.globalShortcut ? .on : .off
        login.state = host.launchAtLoginEnabled ? .on : .off
        latency.selectItem(at: AppSettings.Latency.allCases.firstIndex(of: AppSettings.latency) ?? 0)
        peakHold.selectItem(at: AppSettings.PeakHold.allCases.firstIndex(of: AppSettings.peakHold) ?? 0)

        let status = DriverInstaller.status()
        var text = model.statusText.replacingOccurrences(of: " · capture is meter-only", with: "")
        var installTitle = "Install Driver…", canInstall = DriverInstaller.bundledURL != nil
        switch status {
        case .notInstalled: installTitle = "Install Driver…"
        case .outdated: installTitle = "Update Driver…"
        case .upToDate: installTitle = "Reinstall Driver…"
        case .notBundled: canInstall = false; text += " (this build does not contain the driver)"
        }
        if model.connectRefused { installTitle = "Reinstall Driver…" }
        driverStatus.stringValue = text
        installButton.title = installTitle; installButton.isEnabled = canInstall
        uninstallButton.isEnabled = status != .notInstalled && status != .notBundled
        reconnectButton.isEnabled = true
    }

    // MARK: Actions
    @objc private func appearanceChanged() { AppSettings.appearance = AppSettings.Appearance.allCases[max(0, appearance.selectedSegment)] }
    @objc private func floatChanged() { AppSettings.floatOnTop = floatOnTop.state == .on }
    @objc private func dockChanged() { AppSettings.showInDock = showInDock.state == .on }
    @objc private func launchChanged() { AppSettings.launchBehavior = AppSettings.LaunchBehavior.allCases[max(0, launchBehavior.indexOfSelectedItem)] }
    @objc private func shortcutChanged() { AppSettings.globalShortcut = shortcut.state == .on }
    @objc private func loginChanged() { host.setLaunchAtLogin(login.state == .on); refresh() }
    @objc private func latencyChanged() { AppSettings.latency = AppSettings.Latency.allCases[max(0, latency.indexOfSelectedItem)] }
    @objc private func holdChanged() { AppSettings.peakHold = AppSettings.PeakHold.allCases[max(0, peakHold.indexOfSelectedItem)] }
    @objc private func installTapped() { host.installDriver() }
    @objc private func uninstallTapped() { host.uninstallDriver() }
    @objc private func reconnectTapped() { host.reconnectDriver() }
    @objc private func revealTapped() { host.revealPresets() }

    @objc private func resetTapped() {
        // A sheet is attached to this window, so it can never end up behind something.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset saved routing?"
        alert.informativeText = "This clears every source's routing, level and mute, and all bus settings, and deletes the automatic backup. Your named presets are not touched."
        alert.addButton(withTitle: "Reset"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { MainActor.assumeIsolated { self?.model.resetRouting() } }
        }
    }
}
