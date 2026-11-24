// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
import AppKit
import ConduitBridge

enum Layout {
    static let pad: CGFloat = 8
    static let leftWidth: CGFloat = 256
    static let defaultCellW: CGFloat = 28
    static let rowH: CGFloat = 24
    static let headerH: CGFloat = 30
    static let labelsH: CGFloat = 16
    static let bottomH: CGFloat = 78
    static let minRows = 2, maxRows = 10
    static func width(pairs: Int) -> CGFloat { pad * 2 + leftWidth + defaultCellW * CGFloat(pairs) }
    static var matrixX: CGFloat { pad + leftWidth }
    /// Height that fits `rows` sources without wasted space (more than `maxRows` scroll).
    static func height(rows: Int, hint: Bool = false) -> CGFloat {
        headerH + labelsH + CGFloat(min(max(rows, minRows), maxRows)) * rowH + bottomH + (hint ? 30 : 0)
    }
    /// Cells stretch to use a wider window, never narrower than the default.
    static func cellWidth(forWidth w: CGFloat, pairs: Int) -> CGFloat {
        min(max((w - 2 * pad - leftWidth) / CGFloat(max(pairs, 1)), defaultCellW), 64)
    }
}

private func busLabel(_ pair: Int) -> String { "\(2 * pair + 1)-\(2 * pair + 2)" }

// MARK: - Meters (CALayer only: no drawRect, no per-frame allocation)

/// Gradient level bar. Peak (translucent) and RMS (solid) are two gradient layers revealed by
/// resizable mask layers, plus a peak-hold tick. Updating a meter is three frame assignments inside a
/// disabled-actions transaction, and is skipped entirely when nothing moved by more than ~0.2 %.
final class LevelBarView: NSView {
    private let vertical: Bool
    private let track = CALayer(), peakGrad = CAGradientLayer(), rmsGrad = CAGradientLayer()
    private let peakMask = CALayer(), rmsMask = CALayer(), holdTick = CALayer()
    private var last: (Float, Float, Float) = (-1, -1, -1)
    private var state = LevelState()

    init(vertical: Bool) {
        self.vertical = vertical
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 2
        layer?.masksToBounds = true
        let colors = [NSColor.systemGreen, .systemGreen, .systemYellow, .systemRed].map(\.cgColor)
        let locations: [NSNumber] = [0, 0.75, 0.92, 1]   // -72 dB ... -18 dB | -6 dB | 0 dB
        for g in [peakGrad, rmsGrad] {
            g.colors = colors; g.locations = locations
            g.startPoint = vertical ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 0, y: 0.5)
            g.endPoint = vertical ? CGPoint(x: 0.5, y: 1) : CGPoint(x: 1, y: 0.5)
        }
        peakGrad.opacity = 0.32
        for m in [peakMask, rmsMask] { m.backgroundColor = NSColor.white.cgColor }
        peakGrad.mask = peakMask; rmsGrad.mask = rmsMask
        holdTick.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        [track, peakGrad, rmsGrad, holdTick].forEach { layer?.addSublayer($0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { track.backgroundColor = NSColor.quaternaryLabelColor.cgColor }
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        [track, peakGrad, rmsGrad].forEach { $0.frame = bounds }
        CATransaction.commit()
        effectiveAppearance.performAsCurrentDrawingAppearance { track.backgroundColor = NSColor.quaternaryLabelColor.cgColor }
        apply(force: true)
    }

    func update(_ s: LevelState) { state = s; apply(force: false) }

    private func apply(force: Bool) {
        let p = CGFloat(MeterMath.position(state.peakDB)), r = CGFloat(MeterMath.position(state.rmsDB)), h = CGFloat(MeterMath.position(state.holdDB))
        if !force, abs(Float(p) - last.0) < 0.002, abs(Float(r) - last.1) < 0.002, abs(Float(h) - last.2) < 0.002 { return }
        last = (Float(p), Float(r), Float(h))
        let w = bounds.width, hgt = bounds.height
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if vertical {
            peakMask.frame = CGRect(x: 0, y: 0, width: w, height: hgt * p)
            rmsMask.frame = CGRect(x: 0, y: 0, width: w, height: hgt * r)
            holdTick.frame = CGRect(x: 0, y: max(0, hgt * h - 1), width: w, height: 2)
        } else {
            peakMask.frame = CGRect(x: 0, y: 0, width: w * p, height: hgt)
            rmsMask.frame = CGRect(x: 0, y: 0, width: w * r, height: hgt)
            holdTick.frame = CGRect(x: max(0, w * h - 1), y: 0, width: 2, height: hgt)
        }
        holdTick.isHidden = h < 0.02
        CATransaction.commit()
    }
}

/// 32-band spectrum: one gradient layer revealed through a mask that holds the bars.
final class SpectrumView: NSView {
    private let grad = CAGradientLayer(), maskHost = CALayer()
    private var bars: [CALayer] = []
    private var values: [Float] = []

    init(bands: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        grad.colors = [NSColor.systemTeal, .systemGreen, .systemYellow, .systemRed].map(\.cgColor)
        grad.locations = [0, 0.5, 0.8, 1]
        grad.startPoint = CGPoint(x: 0.5, y: 0); grad.endPoint = CGPoint(x: 0.5, y: 1)
        bars = (0..<bands).map { _ in let l = CALayer(); l.backgroundColor = NSColor.white.cgColor; l.cornerRadius = 1; maskHost.addSublayer(l); return l }
        grad.mask = maskHost
        layer?.addSublayer(grad)
        values = [Float](repeating: 0, count: bands)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor }
    }
    override func layout() { super.layout(); grad.frame = bounds; maskHost.frame = bounds; viewDidChangeEffectiveAppearance(); render() }

    func update(_ bands: [Float]) { values = bands; render() }

    private func render() {
        guard !bars.isEmpty else { return }
        let n = CGFloat(bars.count), gap: CGFloat = 2, w = (bounds.width - gap * (n + 1)) / n
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            let v = CGFloat(i < values.count ? values[i] : 0)
            bar.frame = CGRect(x: gap + CGFloat(i) * (w + gap), y: 0, width: max(1, w), height: max(1.5, (bounds.height - 2) * v))
        }
        CATransaction.commit()
    }
}

// MARK: - Source row

@MainActor
final class SourceRowView: NSView {
    let id: String
    private unowned let model: MixerModel
    let toggle = NSSwitch(), icon = NSImageView(), name = NSTextField(labelWithString: ""), live = CALayer()
    var name_: String { name.stringValue }
    let meter = LevelBarView(vertical: false)
    let gain = NSSlider(value: 0, minValue: -30, maxValue: 6, target: nil, action: nil)
    let mute = NSButton(title: "M", target: nil, action: nil)
    private let more = NSButton()
    private var isApp = true

    override var isFlipped: Bool { true }

    init(id: String, model: MixerModel) {
        self.id = id; self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        toggle.controlSize = .mini; toggle.target = self; toggle.action = #selector(toggled)
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: 11); name.lineBreakMode = .byTruncatingTail
        name.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(selectForSpectrum)))
        gain.controlSize = .mini; gain.target = self; gain.action = #selector(gainChanged); gain.toolTip = "Source level (dB)"
        gain.doubleValue = 0
        mute.setButtonType(.pushOnPushOff); mute.bezelStyle = .smallSquare; mute.controlSize = .mini
        mute.font = .systemFont(ofSize: 9, weight: .semibold); mute.target = self; mute.action = #selector(muteChanged); mute.toolTip = "Mute"
        more.bezelStyle = .inline; more.isBordered = false; more.imagePosition = .imageOnly
        more.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Options"); more.target = self; more.action = #selector(showMore(_:))
        live.backgroundColor = NSColor.systemGreen.cgColor; live.cornerRadius = 2.5; live.isHidden = true
        layer?.addSublayer(live)
        more.toolTip = "More options for this source"
        [toggle, icon, name, meter, gain, mute, more].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ row: MixerModel.Row) {
        let r = model.routing(for: row.id)
        isApp = { if case .app = row.kind { return true } else { return false } }()
        name.stringValue = row.title
        name.toolTip = row.title
        name.textColor = row.available ? .labelColor : .tertiaryLabelColor
        toggle.state = r.enabled ? .on : .off
        toggle.isEnabled = row.available
        if abs(gain.doubleValue - Double(r.gainDB)) > 0.05 { gain.doubleValue = Double(r.gainDB) }
        mute.state = r.mute ? .on : .off
        if let pid = row.pid, let img = NSRunningApplication(processIdentifier: pid)?.icon { icon.image = img }
        else { icon.image = NSImage(systemSymbolName: isApp ? "app.dashed" : "mic.fill", accessibilityDescription: nil); icon.contentTintColor = .secondaryLabelColor }
        CATransaction.begin(); CATransaction.setDisableActions(true); live.isHidden = !row.playing; CATransaction.commit()
        toolTip = row.available ? nil : "Not running or not available right now"
    }

    override func layout() {
        super.layout()
        let cy = bounds.height / 2
        toggle.frame = CGRect(x: 0, y: cy - 7.5, width: 28, height: 15)
        icon.frame = CGRect(x: 32, y: cy - 7, width: 14, height: 14)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        live.frame = CGRect(x: 49, y: cy - 2.5, width: 5, height: 5)
        CATransaction.commit()
        name.frame = CGRect(x: 58, y: cy - 7, width: 76, height: 14)
        meter.frame = CGRect(x: 138, y: cy - 2, width: 28, height: 4)
        gain.frame = CGRect(x: 170, y: cy - 7, width: 34, height: 14)
        mute.frame = CGRect(x: 208, y: cy - 8, width: 18, height: 16)
        more.frame = CGRect(x: 230, y: cy - 8, width: 16, height: 16)
    }

    @objc private func toggled() { model.update(id) { $0.enabled = toggle.state == .on } }
    @objc private func gainChanged() { model.update(id) { $0.gainDB = Float(gain.doubleValue.rounded()) } }
    @objc private func muteChanged() { model.update(id) { $0.mute = mute.state == .on } }
    @objc private func selectForSpectrum() { model.spectrumSourceID = id }

    @objc private func showMore(_ sender: NSButton) {
        let r = model.routing(for: id)
        let menu = NSMenu()
        let mono = menu.addItem(withTitle: "Mono (fold L+R)", action: #selector(toggleMono), keyEquivalent: ""); mono.target = self; mono.state = r.mono ? .on : .off
        if isApp {
            let s = menu.addItem(withTitle: "Silence on normal output while captured", action: #selector(toggleSilence), keyEquivalent: "")
            s.target = self; s.state = r.silenceOriginal ? .on : .off
        }
        menu.addItem(.separator())
        let sp = menu.addItem(withTitle: "Show spectrum", action: #selector(selectForSpectrum), keyEquivalent: ""); sp.target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }
    @objc private func toggleMono() { model.update(id) { $0.mono.toggle() } }
    @objc private func toggleSilence() { model.update(id) { $0.silenceOriginal.toggle() } }
}

// MARK: - Matrix grid (rows = sources, columns = stereo buses)

@MainActor
final class MixerGridView: NSView {
    private unowned let model: MixerModel
    private var rowViews: [String: SourceRowView] = [:]
    private var order: [String] = []
    private var hover: (row: Int, col: Int)?
    private var paintTarget = true
    private var tracking: NSTrackingArea?
    /// Stretches with the window; set by the view controller.
    var cellW: CGFloat = Layout.defaultCellW { didSet { if cellW != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    init(model: MixerModel) { self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    var contentHeight: CGFloat { CGFloat(max(order.count, 1)) * Layout.rowH }

    func reload() {
        let rows = model.rows
        let ids = Set(rows.map(\.id))
        for (id, v) in rowViews where !ids.contains(id) { v.removeFromSuperview(); rowViews[id] = nil }
        for row in rows {
            let v = rowViews[row.id] ?? { let n = SourceRowView(id: row.id, model: model); addSubview(n); rowViews[row.id] = n; return n }()
            v.configure(row)
        }
        order = rows.map(\.id)
        frame.size = NSSize(width: max(frame.width, Layout.width(pairs: model.pairCount)), height: contentHeight)
        needsLayout = true
        needsDisplay = true
    }

    func updateMeters() {
        for (id, v) in rowViews { v.meter.update(model.sourceLevels[id] ?? LevelState()) }
    }

    override func layout() {
        super.layout()
        for (i, id) in order.enumerated() {
            rowViews[id]?.frame = CGRect(x: Layout.pad, y: CGFloat(i) * Layout.rowH, width: Layout.leftWidth - 4, height: Layout.rowH)
        }
    }

    private func cellRect(row: Int, col: Int) -> CGRect {
        CGRect(x: Layout.matrixX + CGFloat(col) * cellW, y: CGFloat(row) * Layout.rowH, width: cellW, height: Layout.rowH).insetBy(dx: 2, dy: 3)
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        for (r, id) in order.enumerated() {
            let routing = model.routing(for: id)
            let available = model.rows.first { $0.id == id }?.available ?? false
            if r > 0 { NSColor.separatorColor.withAlphaComponent(0.4).setFill(); NSRect(x: Layout.pad, y: CGFloat(r) * Layout.rowH, width: bounds.width - 2 * Layout.pad, height: 0.5).fill() }
            for c in 0..<model.pairCount {
                let rect = cellRect(row: r, col: c)
                let on = routing.pairs.contains(c)
                let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
                if on {
                    accent.withAlphaComponent(routing.enabled && available ? 1 : 0.35).setFill(); path.fill()
                    NSColor.white.withAlphaComponent(routing.enabled && available ? 0.95 : 0.6).setFill()
                    NSBezierPath(ovalIn: CGRect(x: rect.midX - 2.5, y: rect.midY - 2.5, width: 5, height: 5)).fill()
                } else {
                    // labelColor adapts to light/dark; the stroke keeps empty cells visible on the popover's vibrant background.
                    NSColor.labelColor.withAlphaComponent(hover?.row == r && hover?.col == c ? 0.16 : 0.06).setFill(); path.fill()
                    NSColor.labelColor.withAlphaComponent(0.18).setStroke()
                    let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4); outline.lineWidth = 1; outline.stroke()
                }
            }
        }
        if order.isEmpty {
            let s = "No audio apps or microphones found.\nStart playing audio in an app and it will appear here." as NSString
            s.draw(in: bounds.insetBy(dx: 30, dy: 40), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
                                                                          .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }()])
        }
    }

    // In the floating panel (or a popover that is not yet key) the first click must toggle a cell, not just activate the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Click toggles a cell; dragging paints the same state across cells.
    private func hit(_ p: NSPoint) -> (Int, Int)? {
        let col = Int((p.x - Layout.matrixX) / cellW), row = Int(p.y / Layout.rowH)
        guard p.x >= Layout.matrixX, col >= 0, col < model.pairCount, row >= 0, row < order.count else { return nil }
        return (row, col)
    }
    override func mouseDown(with event: NSEvent) {
        guard let (r, c) = hit(convert(event.locationInWindow, from: nil)) else { return }
        paintTarget = !model.routing(for: order[r]).pairs.contains(c)
        model.togglePair(order[r], c, on: paintTarget)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let (r, c) = hit(convert(event.locationInWindow, from: nil)) else { return }
        if model.routing(for: order[r]).pairs.contains(c) != paintTarget { model.togglePair(order[r], c, on: paintTarget) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseMoved(with event: NSEvent) {
        let h = hit(convert(event.locationInWindow, from: nil)).map { (row: $0.0, col: $0.1) }
        if h?.row != hover?.row || h?.col != hover?.col { hover = h; needsDisplay = true }
    }
    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }
}

// MARK: - Bus labels and strips

final class BusLabelsView: NSView {
    var pairs = 8 { didSet { needsDisplay = true } }
    var cellW: CGFloat = Layout.defaultCellW { didSet { if cellW != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
        ("SOURCES" as NSString).draw(at: NSPoint(x: Layout.pad, y: 3), withAttributes: [.font: NSFont.systemFont(ofSize: 8, weight: .semibold), .foregroundColor: NSColor.tertiaryLabelColor])
        for p in 0..<pairs {
            let s = busLabel(p) as NSString, size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: Layout.matrixX + CGFloat(p) * cellW + (cellW - size.width) / 2, y: 2), withAttributes: attrs)
        }
    }
}

@MainActor
final class BusStripsView: NSView {
    private unowned let model: MixerModel
    var meters: [LevelBarView] = [], faders: [NSSlider] = [], mutes: [NSButton] = []
    var cellW: CGFloat = Layout.defaultCellW { didSet { if cellW != oldValue { needsLayout = true } } }
    override var isFlipped: Bool { true }

    init(model: MixerModel) { self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    func reload() {
        let n = model.pairCount
        if meters.count != n {
            (meters as [NSView] + faders + mutes).forEach { $0.removeFromSuperview() }
            meters = (0..<n).map { _ in LevelBarView(vertical: true) }
            faders = (0..<n).map { i in
                let s = NSSlider(value: 0, minValue: -30, maxValue: 6, target: self, action: #selector(faderChanged(_:)))
                s.isVertical = true; s.controlSize = .mini; s.tag = i; s.toolTip = "Bus \(busLabel(i)) level (dB)"; return s
            }
            mutes = (0..<n).map { i in
                let b = NSButton(title: "M", target: self, action: #selector(muteChanged(_:)))
                b.setButtonType(.pushOnPushOff); b.bezelStyle = .smallSquare; b.controlSize = .mini
                b.font = .systemFont(ofSize: 9, weight: .semibold); b.tag = i; b.toolTip = "Mute bus \(busLabel(i))"; return b
            }
            (meters as [NSView] + faders + mutes).forEach(addSubview)
            needsLayout = true
        }
        for i in 0..<n {
            let b = model.buses[i]
            if abs(faders[i].doubleValue - Double(b.gainDB)) > 0.05 { faders[i].doubleValue = Double(b.gainDB) }
            mutes[i].state = b.mute ? .on : .off
        }
    }

    func updateMeters() { for (i, m) in meters.enumerated() where i < model.busLevels.count { m.update(model.busLevels[i]) } }

    override func layout() {
        super.layout()
        let top: CGFloat = 2, mH = max(20, bounds.height - 22)
        let meterW: CGFloat = 6, faderW: CGFloat = 14, gap: CGFloat = 2
        for i in 0..<meters.count {
            let x = Layout.matrixX + CGFloat(i) * cellW + (cellW - (meterW + gap + faderW)) / 2
            meters[i].frame = CGRect(x: x, y: top, width: meterW, height: mH)
            faders[i].frame = CGRect(x: x + meterW + gap, y: top, width: faderW, height: mH)
            mutes[i].frame = CGRect(x: Layout.matrixX + CGFloat(i) * cellW + (cellW - 20) / 2, y: top + mH + 3, width: 20, height: 14)
        }
    }

    @objc private func faderChanged(_ s: NSSlider) { model.updateBus(s.tag) { $0.gainDB = Float(s.doubleValue.rounded()) } }
    @objc private func muteChanged(_ b: NSButton) { model.updateBus(b.tag) { $0.mute = b.state == .on } }
}
