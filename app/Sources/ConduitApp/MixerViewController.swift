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
    private let statusDot = NSView(), status = NSTextField(labelWithString: "")
    private let presets = NSPopUpButton(frame: .zero, pullsDown: true)
    private let windowButton = NSButton(), menuButton = NSButton()
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
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        status.font = .systemFont(ofSize: 10); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail
        statusDot.wantsLayer = true; statusDot.layer?.cornerRadius = 3.5

        presets.menu = NSMenu(); presets.menu?.delegate = self; presets.controlSize = .mini; presets.font = .systemFont(ofSize: 10)
        presets.toolTip = "Routing presets"
        for (b, symbol, tip, action) in [(windowButton, "macwindow.on.rectangle", "Open the mixer in its own window", #selector(windowTapped)),
                                         (menuButton, "ellipsis.circle", "Conduit menu: driver, launch at login, quit…", #selector(menuTapped(_:)))] {
            b.bezelStyle = .inline; b.isBordered = false; b.imagePosition = .imageOnly
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip); b.toolTip = tip
            b.target = self; b.action = action
        }
        windowButton.isHidden = inWindow   // already in a window

        installButton.bezelStyle = .rounded; installButton.controlSize = .mini; installButton.font = .systemFont(ofSize: 10, weight: .medium)
        installButton.target = self; installButton.action = #selector(installTapped); installButton.isHidden = true

        scroll.documentView = grid
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay

        spectrumPopup.controlSize = .mini; spectrumPopup.font = .systemFont(ofSize: 10)
        spectrumPopup.target = self; spectrumPopup.action = #selector(spectrumChosen)
        hint.font = .systemFont(ofSize: 10); hint.textColor = .systemOrange; hint.isHidden = true

        [titleField, statusDot, status, installButton, presets, windowButton, menuButton, labels, scroll, spectrumPopup, spectrum, strips, hint].forEach(root.addSubview)
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

        // Header, right to left.
        var x = w - pad
        menuButton.frame = CGRect(x: x - 20, y: 5, width: 20, height: 20); x -= 22
        if !windowButton.isHidden { windowButton.frame = CGRect(x: x - 20, y: 5, width: 20, height: 20); x -= 22 }
        presets.frame = CGRect(x: x - 78, y: 6, width: 78, height: 18); x -= 82
        if !installButton.isHidden { installButton.frame = CGRect(x: x - 96, y: 6, width: 96, height: 18); x -= 100 }
        titleField.sizeToFit()
        titleField.frame = CGRect(x: pad, y: 7, width: titleField.frame.width, height: 16)
        statusDot.frame = CGRect(x: titleField.frame.maxX + 8, y: 11.5, width: 7, height: 7)
        status.frame = CGRect(x: statusDot.frame.maxX + 5, y: 8, width: max(30, x - statusDot.frame.maxX - 8), height: 14)

        labels.frame = CGRect(x: 0, y: Layout.headerH, width: w, height: Layout.labelsH)
        let hintH: CGFloat = hint.isHidden ? 0 : 30
        let bottomTop = h - Layout.bottomH - hintH
        let scrollTop = Layout.headerH + Layout.labelsH
        scroll.frame = CGRect(x: 0, y: scrollTop, width: w, height: max(Layout.rowH, bottomTop - scrollTop))
        grid.frame.size.width = w

        let leftW = Layout.leftWidth
        spectrumPopup.frame = CGRect(x: pad, y: bottomTop + 4, width: leftW - 6, height: 16)
        spectrum.frame = CGRect(x: pad, y: bottomTop + 24, width: leftW - 6, height: Layout.bottomH - 28)
        strips.frame = CGRect(x: 0, y: bottomTop + 2, width: w, height: Layout.bottomH - 4)
        hint.frame = CGRect(x: pad, y: h - hintH + 2, width: w - 2 * pad, height: 28)
    }

    // MARK: Observation
    func modelStructureChanged() {
        guard isViewLoaded else { return }
        grid.reload()
        strips.reload()
        labels.pairs = model.pairCount
        status.stringValue = model.statusShort
        status.toolTip = model.statusText
        let healthy = model.driverConnected && model.lastError == nil
        statusDot.layer?.backgroundColor = (model.lastError != nil ? NSColor.systemRed : healthy ? NSColor.systemGreen : NSColor.systemOrange).cgColor
        if let err = model.lastError { status.stringValue = "Capture error"; status.toolTip = err }

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
