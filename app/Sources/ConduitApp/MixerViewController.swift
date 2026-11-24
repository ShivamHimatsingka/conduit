// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
import AppKit
import ConduitBridge

@MainActor
protocol MixerHost: AnyObject {
    func detachMixer()
    func installDriver()
    /// The app-wide actions (window, driver, launch at login, presets folder, quit). Built fresh so titles and checkmarks are current.
    func makeAppMenu() -> NSMenu
    func beginModal()
    func endModal()
}

final class MixerRootView: NSView {
    override var isFlipped: Bool { true }
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
}

/// The mixer. Used both in the menu-bar popover (sizes itself to its content) and in a normal resizable window.
@MainActor
final class MixerViewController: NSViewController, MixerModelObserver, NSMenuDelegate {
    private let model: MixerModel
    private weak var host: MixerHost?
    private let inWindow: Bool

    private let root = MixerRootView()
    private let titleField = NSTextField(labelWithString: "Conduit")
    private let pill = StatusPill()
    private let presets = NSPopUpButton(frame: .zero, pullsDown: true)
    private let windowButton = IconButton(symbol: "macwindow.on.rectangle", tip: "Open the mixer in its own window", size: 14)
    private let menuButton = IconButton(symbol: "ellipsis.circle", tip: "Conduit menu: driver, launch at login, quit…", size: 15)
    private let installButton = NSButton(title: "Install Driver…", target: nil, action: nil)
    private let labels = BusLabelsView()
    let scroll = NSScrollView()
    let grid: MixerGridView
    let strips: BusStripsView
    let spectrumPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let spectrum = SpectrumView(bands: 32)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private var displayLink: CADisplayLink?

    init(model: MixerModel, host: MixerHost?, inWindow: Bool = false) {
        self.model = model; self.host = host; self.inWindow = inWindow
        grid = MixerGridView(model: model)
        strips = BusStripsView(model: model)
        super.init(nibName: nil, bundle: nil)
        model.addObserver(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: View construction
    private var idealHeight: CGFloat { Layout.height(rows: model.rows.count, hint: model.hint != nil) }

    override func loadView() {
        root.frame = NSRect(x: 0, y: 0, width: Layout.width(pairs: model.pairCount), height: idealHeight)
        root.wantsLayer = true
        titleField.font = .systemFont(ofSize: 15, weight: .semibold)

        presets.menu = NSMenu(); presets.menu?.delegate = self; presets.controlSize = .small; presets.font = .systemFont(ofSize: 12)
        presets.toolTip = "Routing presets"
        windowButton.target = self; windowButton.action = #selector(windowTapped)
        menuButton.target = self; menuButton.action = #selector(menuTapped(_:))
        windowButton.isHidden = inWindow   // already in a window

        installButton.bezelStyle = .rounded; installButton.controlSize = .small; installButton.font = .systemFont(ofSize: 12, weight: .medium)
        installButton.bezelColor = .controlAccentColor; installButton.contentTintColor = .white
        installButton.target = self; installButton.action = #selector(installTapped); installButton.isHidden = true

        scroll.documentView = grid
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay

        spectrumPopup.controlSize = .small; spectrumPopup.font = .systemFont(ofSize: 11)
        spectrumPopup.target = self; spectrumPopup.action = #selector(spectrumChosen)
        hint.font = .systemFont(ofSize: 11); hint.textColor = .systemOrange; hint.isHidden = true

        [titleField, pill, installButton, presets, windowButton, menuButton, labels, scroll, spectrumPopup, spectrum, strips, hint].forEach(root.addSubview)
        if let m = presets.menu { menuNeedsUpdate(m) }   // so the pull-down shows its title before first opened
        root.onLayout = { [weak self] in self?.layoutAll() }
        view = root
        modelStructureChanged()
    }

    private func layoutAll() {
        let w = root.bounds.width, h = root.bounds.height, pad = Layout.pad
        let pairs = model.pairCount
        let cw = Layout.cellWidth(forWidth: w, pairs: pairs)
        grid.cellW = cw; labels.cellW = cw; strips.cellW = cw

        // Header, right to left: ⋯  window  presets  install; then title and status pill on the left.
        var x = w - pad
        menuButton.frame = CGRect(x: x - 26, y: 12, width: 26, height: 26); x -= 30
        if !windowButton.isHidden { windowButton.frame = CGRect(x: x - 26, y: 12, width: 26, height: 26); x -= 30 }
        presets.frame = CGRect(x: x - 88, y: 13, width: 88, height: 24); x -= 94
        if !installButton.isHidden { installButton.frame = CGRect(x: x - 128, y: 12, width: 128, height: 26); x -= 134 }
        titleField.sizeToFit()
        titleField.frame = CGRect(x: pad, y: 14, width: titleField.frame.width, height: 22)
        let pillX = titleField.frame.maxX + 12
        pill.frame = CGRect(x: pillX, y: 14, width: max(60, min(pill.fittingWidth, x - pillX - 4)), height: 22)

        labels.frame = CGRect(x: 0, y: Layout.headerH, width: w, height: Layout.labelsH)
        let hintH: CGFloat = hint.isHidden ? 0 : 34
        let bottomTop = h - Layout.bottomH - hintH
        let scrollTop = Layout.headerH + Layout.labelsH
        scroll.frame = CGRect(x: 0, y: scrollTop, width: w, height: max(Layout.rowH, bottomTop - scrollTop))
        grid.frame.size.width = w

        let leftW = Layout.leftWidth - 14
        spectrumPopup.frame = CGRect(x: pad, y: bottomTop + 6, width: leftW, height: 22)
        spectrum.frame = CGRect(x: pad, y: bottomTop + 34, width: leftW, height: Layout.bottomH - 44)
        strips.frame = CGRect(x: 0, y: bottomTop + 4, width: w, height: Layout.bottomH - 8)
        hint.frame = CGRect(x: pad, y: h - hintH + 4, width: w - 2 * pad, height: 28)
    }

    // MARK: Observation
    func modelStructureChanged() {
        guard isViewLoaded else { return }
        grid.reload()
        strips.reload()
        labels.pairs = model.pairCount
        let healthy = model.driverConnected && model.lastError == nil
        let color: NSColor = model.lastError != nil ? .systemRed : healthy ? .systemGreen : .systemOrange
        if let err = model.lastError { pill.set(text: "Capture error", color: color, tooltip: err) }
        else { pill.set(text: model.statusShort, color: color, tooltip: model.statusText) }
        switch (model.driverStatus, model.connectRefused) {
        case (_, true): installButton.title = "Reinstall Driver…"; installButton.isHidden = false
        case (.notInstalled, _): installButton.title = "Install Driver…"; installButton.isHidden = false
        case (.outdated, _): installButton.title = "Update Driver…"; installButton.isHidden = false
        default: installButton.isHidden = true
        }
        hint.stringValue = model.hint ?? ""
        hint.isHidden = model.hint == nil

        // Spectrum source list = enabled, available sources.
        let enabled = model.rows.filter { model.routing(for: $0.id).enabled && $0.available }
        spectrumPopup.removeAllItems()
        spectrumPopup.addItem(withTitle: "Spectrum: off"); spectrumPopup.lastItem?.representedObject = nil
        for r in enabled { spectrumPopup.addItem(withTitle: "Spectrum · \(r.title)"); spectrumPopup.lastItem?.representedObject = r.id }
        if let sel = model.spectrumSourceID, let idx = enabled.firstIndex(where: { $0.id == sel }) { spectrumPopup.selectItem(at: idx + 1) }
        else { spectrumPopup.selectItem(at: 0) }

        // The popover hugs its content; a window keeps the size the user gave it.
        if !inWindow { preferredContentSize = NSSize(width: Layout.width(pairs: model.pairCount), height: idealHeight) }
        root.needsLayout = true
    }

    // MARK: 60 fps metering (display link exists only while the mixer is on screen)
    override func viewDidAppear() {
        super.viewDidAppear()
        guard displayLink == nil else { return }
        let link = view.displayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
        model.refreshSources()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        displayLink?.invalidate(); displayLink = nil
    }

    @objc private func frame(_ link: CADisplayLink) { model.pollIfDue(); updateMeters() }

    func updateMeters() {
        grid.updateMeters()
        strips.updateMeters()
        if model.spectrumSourceID != nil { spectrum.update(model.spectrumBands) } else { spectrum.update([]) }
    }

    // MARK: Actions
    @objc private func windowTapped() { host?.detachMixer() }
    @objc private func installTapped() { host?.installDriver() }
    @objc private func menuTapped(_ sender: NSButton) {
        host?.makeAppMenu().popUp(positioning: nil, at: NSPoint(x: sender.bounds.width, y: sender.bounds.height + 2), in: sender)
    }
    @objc private func spectrumChosen() { model.spectrumSourceID = spectrumPopup.selectedItem?.representedObject as? String }

    // Presets menu (rebuilt each time it opens, so it always reflects the folder)
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === presets.menu else { return }
        menu.removeAllItems()
        menu.addItem(withTitle: "Presets", action: nil, keyEquivalent: "")  // pull-down button title
        let names = PresetStore.list().filter { !$0.hasPrefix("_") }
        for n in names { let i = menu.addItem(withTitle: n, action: #selector(loadPreset(_:)), keyEquivalent: ""); i.target = self; i.representedObject = n }
        if names.isEmpty { let i = menu.addItem(withTitle: "No saved presets", action: nil, keyEquivalent: ""); i.isEnabled = false }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Save Current Routing As…", action: #selector(savePreset), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Import Preset…", action: #selector(importPreset), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show in Finder", action: #selector(revealPresets), keyEquivalent: "").target = self
        if !names.isEmpty {
            let del = NSMenuItem(title: "Delete", action: nil, keyEquivalent: ""), sub = NSMenu()
            for n in names { let i = sub.addItem(withTitle: n, action: #selector(deletePreset(_:)), keyEquivalent: ""); i.target = self; i.representedObject = n }
            del.submenu = sub; menu.addItem(del)
        }
    }

    @objc private func loadPreset(_ item: NSMenuItem) {
        guard let name = item.representedObject as? String else { return }
        do { model.apply(try PresetStore.load(name: name)) } catch { show(error: error, while: "loading “\(name)”") }
    }

    /// Reachable from the main menu (File ▸ Save…) through the responder chain, and from the Presets pull-down.
    @objc func savePreset() {
        host?.beginModal(); defer { host?.endModal() }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Save routing preset"
        alert.informativeText = "Saves source routing, levels and bus settings as JSON."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Preset name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.hasPrefix("_") else { return }
        do { try PresetStore.save(model.snapshot(named: name)) } catch { show(error: error, while: "saving “\(name)”") }
    }

    @objc private func importPreset() {
        host?.beginModal(); defer { host?.endModal() }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let p = try PresetStore.load(url: url)
            try PresetStore.save(p)
            model.apply(p)
        } catch { show(error: error, while: "importing the preset") }
    }

    @objc private func revealPresets() {
        try? PresetStore.ensureDirectory()
        NSWorkspace.shared.activateFileViewerSelecting([PresetStore.directory])
    }

    @objc private func deletePreset(_ item: NSMenuItem) {
        guard let name = item.representedObject as? String else { return }
        try? PresetStore.delete(name: name)
    }

    private func show(error: Error, while what: String) {
        host?.beginModal(); defer { host?.endModal() }
        let a = NSAlert(error: error)
        a.messageText = "Problem \(what)"
        a.runModal()
    }
}
