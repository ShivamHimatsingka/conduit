// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
import AppKit
import ConduitBridge

@MainActor
protocol MixerHost: AnyObject {
    func detachMixer()
    func beginModal()
    func endModal()
}

final class MixerRootView: NSView {
    override var isFlipped: Bool { true }
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
}

@MainActor
final class MixerViewController: NSViewController, MixerModelObserver, NSMenuDelegate {
    private let model: MixerModel
    private weak var host: MixerHost?

    private let root = MixerRootView()
    private let titleField = NSTextField(labelWithString: "Conduit")
    private let statusDot = NSView(), status = NSTextField(labelWithString: "")
    private let presets = NSPopUpButton(frame: .zero, pullsDown: true)
    private let detach = NSButton()
    private let labels = BusLabelsView()
    private let scroll = NSScrollView()
    private let grid: MixerGridView
    private let strips: BusStripsView
    private let spectrumPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let spectrum = SpectrumView(bands: 32)
    private let spectrumTitle = NSTextField(labelWithString: "SPECTRUM")
    private let busTitle = NSTextField(labelWithString: "OUTPUT BUSES  (meter · level · mute)")
    private let hint = NSTextField(wrappingLabelWithString: "")
    private var displayLink: CADisplayLink?
    private let bottomHeight: CGFloat = 128

    init(model: MixerModel, host: MixerHost?) {
        self.model = model; self.host = host
        grid = MixerGridView(model: model)
        strips = BusStripsView(model: model)
        super.init(nibName: nil, bundle: nil)
        model.addObserver(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: View construction
    override func loadView() {
        root.frame = NSRect(x: 0, y: 0, width: Layout.width(pairs: model.pairCount), height: 470)
        root.wantsLayer = true
        titleField.font = .systemFont(ofSize: 15, weight: .semibold)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail
        statusDot.wantsLayer = true; statusDot.layer?.cornerRadius = 4

        presets.menu = NSMenu(); presets.menu?.delegate = self; presets.controlSize = .small; presets.font = .systemFont(ofSize: 11)
        presets.toolTip = "Routing presets"
        detach.bezelStyle = .inline; detach.isBordered = false; detach.imagePosition = .imageOnly
        detach.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "Detach mixer")
        detach.toolTip = "Detach into a floating window"; detach.target = self; detach.action = #selector(detachTapped)

        scroll.documentView = grid
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay

        for t in [spectrumTitle, busTitle] { t.font = .systemFont(ofSize: 9, weight: .semibold); t.textColor = .tertiaryLabelColor }
        spectrumPopup.controlSize = .small; spectrumPopup.font = .systemFont(ofSize: 11)
        spectrumPopup.target = self; spectrumPopup.action = #selector(spectrumChosen)
        hint.font = .systemFont(ofSize: 11); hint.textColor = .systemOrange; hint.isHidden = true

        [titleField, statusDot, status, presets, detach, labels, scroll, spectrumTitle, spectrumPopup, spectrum, busTitle, strips, hint].forEach(root.addSubview)
        if let m = presets.menu { menuNeedsUpdate(m) }   // so the pull-down shows its title before first opened
        root.onLayout = { [weak self] in self?.layoutAll() }
        view = root
        modelStructureChanged()
    }

    private func layoutAll() {
        let w = root.bounds.width, h = root.bounds.height, pad = Layout.pad
        titleField.frame = CGRect(x: pad, y: 10, width: 80, height: 20)
        statusDot.frame = CGRect(x: pad + 82, y: 16, width: 8, height: 8)
        presets.frame = CGRect(x: w - pad - 26 - 4 - 110, y: 8, width: 110, height: 22)
        detach.frame = CGRect(x: w - pad - 22, y: 9, width: 22, height: 22)
        status.frame = CGRect(x: pad + 96, y: 11, width: max(40, presets.frame.minX - (pad + 96) - 8), height: 16)

        labels.frame = CGRect(x: 0, y: 38, width: w, height: 22)
        let hintH: CGFloat = hint.isHidden ? 0 : 30
        let scrollTop: CGFloat = 60, bottomTop = h - bottomHeight - hintH
        scroll.frame = CGRect(x: 0, y: scrollTop, width: w, height: max(60, bottomTop - scrollTop))
        grid.frame.size.width = w

        let leftW = Layout.pad + Layout.leftWidth
        spectrumTitle.frame = CGRect(x: pad, y: bottomTop + 6, width: 70, height: 12)
        spectrumPopup.frame = CGRect(x: pad + 66, y: bottomTop + 1, width: leftW - pad - 66 - 8, height: 20)
        spectrum.frame = CGRect(x: pad, y: bottomTop + 26, width: leftW - pad - 8, height: bottomHeight - 34)
        busTitle.frame = CGRect(x: Layout.matrixX, y: bottomTop + 4, width: 300, height: 12)
        strips.frame = CGRect(x: 0, y: bottomTop + 20, width: w, height: bottomHeight - 20)
        hint.frame = CGRect(x: pad, y: h - hintH + 2, width: w - 2 * pad, height: 28)
    }

    // MARK: Observation
    func modelStructureChanged() {
        guard isViewLoaded else { return }
        grid.reload()
        strips.reload()
        labels.pairs = model.pairCount
        status.stringValue = model.lastError.map { "Capture error: \($0)" } ?? model.statusText
        statusDot.layer?.backgroundColor = (model.lastError != nil ? NSColor.systemRed : model.driverConnected ? NSColor.systemGreen : NSColor.systemOrange).cgColor
        hint.stringValue = model.hint ?? ""
        hint.isHidden = model.hint == nil

        // Spectrum source list = enabled, available sources.
        let enabled = model.rows.filter { model.routing(for: $0.id).enabled && $0.available }
        spectrumPopup.removeAllItems()
        spectrumPopup.addItem(withTitle: "Off"); spectrumPopup.lastItem?.representedObject = nil
        for r in enabled { spectrumPopup.addItem(withTitle: r.title); spectrumPopup.lastItem?.representedObject = r.id }
        if let sel = model.spectrumSourceID, let idx = enabled.firstIndex(where: { $0.id == sel }) { spectrumPopup.selectItem(at: idx + 1) }
        else { spectrumPopup.selectItem(at: 0) }
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
    @objc private func detachTapped() { host?.detachMixer() }

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

    @objc private func savePreset() {
        host?.beginModal(); defer { host?.endModal() }
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
