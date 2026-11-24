// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
import AppKit
import ConduitBridge

/// Sizing rules. Text and controls keep normal macOS sizes; the only thing that is squeezed is the routing matrix
/// (small crosspoint dots on a striped grid), because that is where musicians spend their pixels.
enum Layout {
    static let pad: CGFloat = 14
    static let leftWidth: CGFloat = 326       // source controls: switch, icon, name, meter, level, mute, more
    static let defaultCellW: CGFloat = 22     // one stereo bus column
    static let rowH: CGFloat = 30
    static let headerH: CGFloat = 50
    static let labelsH: CGFloat = 30
    static let bottomH: CGFloat = 100
    static let minRows = 2, maxRows = 9
    static func width(pairs: Int) -> CGFloat { pad * 2 + leftWidth + defaultCellW * CGFloat(pairs) }
    static var matrixX: CGFloat { pad + leftWidth }
    /// Height that fits `rows` sources without wasted space (more than `maxRows` scroll).
    static func height(rows: Int, hint: Bool = false) -> CGFloat {
        headerH + labelsH + CGFloat(min(max(rows, minRows), maxRows)) * rowH + bottomH + (hint ? 34 : 0)
    }
    /// Columns stretch to use a wider window, never narrower than the default.
    static func cellWidth(forWidth w: CGFloat, pairs: Int) -> CGFloat {
        min(max((w - 2 * pad - leftWidth) / CGFloat(max(pairs, 1)), defaultCellW), 56)
    }
}

// MARK: - Small building blocks

/// Borderless symbol button with a rounded hover/pressed background (what modern macOS toolbars do).
final class IconButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?
    private let activeTint: NSColor

    init(symbol: String, alternate: String? = nil, tip: String, size: CGFloat = 13, activeTint: NSColor = .labelColor) {
        self.activeTint = activeTint
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(config)
        if let alternate {
            setButtonType(.pushOnPushOff)
            alternateImage = NSImage(systemSymbolName: alternate, accessibilityDescription: tip)?.withSymbolConfiguration(config)
        }
        toolTip = tip
        contentTintColor = .secondaryLabelColor
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Toggle buttons are tinted while "on" (a muted source should be obvious at a glance).
    func refreshTint() { contentTintColor = state == .on ? activeTint : .secondaryLabelColor }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func draw(_ dirtyRect: NSRect) {
        if hovering || isHighlighted {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.16 : 0.09).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Rounded capsule with a coloured dot and one line of text (driver / capture state).
final class StatusPill: NSView {
    private let label = NSTextField(labelWithString: "")
    private let dot = CALayer()
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        dot.cornerRadius = 3.5
        layer?.addSublayer(dot)
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(text: String, color: NSColor, tooltip: String?) {
        label.stringValue = text
        toolTip = tooltip
        effectiveAppearance.performAsCurrentDrawingAppearance { dot.backgroundColor = color.cgColor }
        needsLayout = true
    }
    var fittingWidth: CGFloat { ceil(label.attributedStringValue.size().width) + 24 + 14 }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dot.frame = CGRect(x: 10, y: (bounds.height - 7) / 2, width: 7, height: 7)
        CATransaction.commit()
        label.frame = CGRect(x: 24, y: (bounds.height - 15) / 2, width: max(0, bounds.width - 30), height: 15)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

/// Slim fader: a thin track with a small round knob. Replaces NSSlider, whose large knobs crowd narrow bus columns.
/// Drag or click to set, double-click (or ⌥-click) to reset to 0 dB, scroll to fine-tune. Behaves like any NSControl.
final class FaderView: NSControl {
    let vertical: Bool
    var minValue = -30.0, maxValue = 6.0, defaultValue = 0.0
    private var value = 0.0
    private let knob: CGFloat = 12

    override var isFlipped: Bool { true }
    override var doubleValue: Double {
        get { value }
        set { let v = min(max(newValue, minValue), maxValue); if v != value { value = v; needsDisplay = true } }
    }

    init(vertical: Bool) { self.vertical = vertical; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    private var travel: CGFloat { (vertical ? bounds.height : bounds.width) - knob }
    private var fraction: CGFloat { CGFloat((value - minValue) / (maxValue - minValue)) }
    /// Knob centre along the axis (vertical faders grow upward, and this view is flipped).
    private var knobCenter: CGFloat { vertical ? bounds.height - knob / 2 - fraction * travel : knob / 2 + fraction * travel }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor, c = knobCenter
        let track: CGRect, fill: CGRect, knobRect: CGRect
        if vertical {
            track = CGRect(x: bounds.midX - 1.5, y: knob / 2, width: 3, height: bounds.height - knob)
            fill = CGRect(x: track.minX, y: c, width: 3, height: track.maxY - c)
            knobRect = CGRect(x: bounds.midX - knob / 2, y: c - knob / 2, width: knob, height: knob)
        } else {
            track = CGRect(x: knob / 2, y: bounds.midY - 1.5, width: bounds.width - knob, height: 3)
            fill = CGRect(x: track.minX, y: track.minY, width: c - track.minX, height: 3)
            knobRect = CGRect(x: c - knob / 2, y: bounds.midY - knob / 2, width: knob, height: knob)
        }
        NSColor.labelColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
        // Unity (0 dB) tick, so the "neutral" position is findable by eye.
        let u = vertical ? bounds.height - knob / 2 - CGFloat((defaultValue - minValue) / (maxValue - minValue)) * travel
                         : knob / 2 + CGFloat((defaultValue - minValue) / (maxValue - minValue)) * travel
        NSColor.labelColor.withAlphaComponent(0.35).setFill()
        (vertical ? CGRect(x: bounds.midX - 4, y: u - 0.5, width: 8, height: 1) : CGRect(x: u - 0.5, y: bounds.midY - 4, width: 1, height: 8)).fill()
        accent.withAlphaComponent(isEnabled ? 0.85 : 0.3).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
        NSGraphicsContext.current?.cgContext.saveGState()
        let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.35); sh.shadowBlurRadius = 2; sh.shadowOffset = NSSize(width: 0, height: -0.5); sh.set()
        NSColor.white.setFill(); NSBezierPath(ovalIn: knobRect).fill()
        NSGraphicsContext.current?.cgContext.restoreGState()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        let ring = NSBezierPath(ovalIn: knobRect.insetBy(dx: 0.25, dy: 0.25)); ring.lineWidth = 0.5; ring.stroke()
    }

    private func set(from event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let t = vertical ? 1 - (p.y - knob / 2) / travel : (p.x - knob / 2) / travel
        doubleValue = minValue + Double(min(max(t, 0), 1)) * (maxValue - minValue)
        sendAction(action, to: target)
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 || event.modifierFlags.contains(.option) { doubleValue = defaultValue; sendAction(action, to: target); return }
        set(from: event)
    }
    override func mouseDragged(with event: NSEvent) { set(from: event) }
    override func scrollWheel(with event: NSEvent) {
        let d = Double(event.scrollingDeltaY != 0 ? event.scrollingDeltaY : -event.scrollingDeltaX) * (event.hasPreciseScrollingDeltas ? 0.05 : 0.5)
        doubleValue += d; sendAction(action, to: target)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

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

    private func refreshTrackColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance { track.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshTrackColor() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2   // capsule
        [track, peakGrad, rmsGrad].forEach { $0.frame = bounds }
        CATransaction.commit()
        refreshTrackColor()
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

/// 32-band spectrum in a rounded card: one gradient layer revealed through a mask that holds the bars.
final class SpectrumView: NSView {
    private let grad = CAGradientLayer(), maskHost = CALayer()
    private var bars: [CALayer] = []
    private var values: [Float] = []

    init(bands: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        grad.colors = [NSColor.systemTeal, .systemGreen, .systemYellow, .systemRed].map(\.cgColor)
        grad.locations = [0, 0.5, 0.8, 1]
        grad.startPoint = CGPoint(x: 0.5, y: 0); grad.endPoint = CGPoint(x: 0.5, y: 1)
        bars = (0..<bands).map { _ in let l = CALayer(); l.backgroundColor = NSColor.white.cgColor; l.cornerRadius = 1.5; maskHost.addSublayer(l); return l }
        grad.mask = maskHost
        layer?.addSublayer(grad)
        values = [Float](repeating: 0, count: bands)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor }
    }
    override func layout() { super.layout(); grad.frame = bounds; maskHost.frame = bounds; viewDidChangeEffectiveAppearance(); render() }

    func update(_ bands: [Float]) { values = bands; render() }

    private func render() {
        guard !bars.isEmpty else { return }
        let n = CGFloat(bars.count), gap: CGFloat = 2, inset: CGFloat = 6
        let w = (bounds.width - 2 * inset - gap * (n - 1)) / n, usable = bounds.height - 8
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            let v = CGFloat(i < values.count ? values[i] : 0)
            bar.frame = CGRect(x: inset + CGFloat(i) * (w + gap), y: 4, width: max(1, w), height: max(2, usable * v))
        }
        CATransaction.commit()
    }
}

// MARK: - Source row

@MainActor
final class SourceRowView: NSView {
    let id: String
    private unowned let model: MixerModel
    let toggle = NSSwitch(), icon = NSImageView(), name = NSTextField(labelWithString: "")
    var name_: String { name.stringValue }
    let meter = LevelBarView(vertical: false)
    let gain = FaderView(vertical: false)
    let mute = IconButton(symbol: "speaker.wave.2.fill", alternate: "speaker.slash.fill", tip: "Mute this source", size: 12, activeTint: .systemOrange)
    private let more = IconButton(symbol: "ellipsis", tip: "More options for this source", size: 13)
    private let live = CALayer()
    private var isApp = true

    override var isFlipped: Bool { true }

    init(id: String, model: MixerModel) {
        self.id = id; self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        toggle.controlSize = .small; toggle.target = self; toggle.action = #selector(toggled)
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: 13); name.lineBreakMode = .byTruncatingTail
        name.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(selectForSpectrum)))
        gain.target = self; gain.action = #selector(gainChanged); gain.toolTip = "Source level (dB). Double-click to reset."
        mute.target = self; mute.action = #selector(muteChanged)
        more.target = self; more.action = #selector(showMore(_:))
        live.cornerRadius = 4; live.borderWidth = 1.5; live.backgroundColor = NSColor.systemGreen.cgColor; live.isHidden = true
        layer?.addSublayer(live)
        [toggle, icon, name, meter, gain, mute, more].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { live.borderColor = NSColor.windowBackgroundColor.cgColor }
    }

    func configure(_ row: MixerModel.Row) {
        let r = model.routing(for: row.id)
        isApp = { if case .app = row.kind { return true } else { return false } }()
        name.stringValue = row.title
        name.toolTip = row.title
        name.textColor = row.available ? .labelColor : .tertiaryLabelColor
        toggle.state = r.enabled ? .on : .off
        toggle.isEnabled = row.available
        if abs(gain.doubleValue - Double(r.gainDB)) > 0.05 { gain.doubleValue = Double(r.gainDB) }
        gain.toolTip = "Source level: \(Int(r.gainDB)) dB (double-click to reset)"
        mute.state = r.mute ? .on : .off; mute.refreshTint()
        if let pid = row.pid, let img = NSRunningApplication(processIdentifier: pid)?.icon { icon.image = img; icon.contentTintColor = nil }
        else {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            icon.image = NSImage(systemSymbolName: isApp ? "app.dashed" : "mic.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config)
            icon.contentTintColor = .secondaryLabelColor
        }
        CATransaction.begin(); CATransaction.setDisableActions(true); live.isHidden = !row.playing; CATransaction.commit()
        toolTip = row.available ? nil : "Not running or not available right now"
    }

    override func layout() {
        super.layout()
        let cy = bounds.height / 2
        toggle.frame = CGRect(x: 0, y: cy - 9, width: 32, height: 18)
        icon.frame = CGRect(x: 40, y: cy - 10, width: 20, height: 20)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        live.frame = CGRect(x: 52, y: cy + 1, width: 8, height: 8)      // green dot on the icon's corner: "this app is playing"
        CATransaction.commit()
        viewDidChangeEffectiveAppearance()
        name.frame = CGRect(x: 68, y: cy - 8, width: 112, height: 16)
        meter.frame = CGRect(x: 186, y: cy - 2, width: 36, height: 4)
        gain.frame = CGRect(x: 228, y: cy - 9, width: 46, height: 18)
        mute.frame = CGRect(x: 278, y: cy - 11, width: 22, height: 22)
        more.frame = CGRect(x: 302, y: cy - 11, width: 22, height: 22)
    }

    @objc private func toggled() { model.update(id) { $0.enabled = toggle.state == .on } }
    @objc private func gainChanged() { model.update(id) { $0.gainDB = Float(gain.doubleValue.rounded()) } }
    @objc private func muteChanged() { mute.refreshTint(); model.update(id) { $0.mute = mute.state == .on } }
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

    func rowView(at index: Int) -> SourceRowView? { order.indices.contains(index) ? rowViews[order[index]] : nil }
    /// Screen-testing helper: the rect of one crosspoint slot, in this view's coordinates.
    func cellView(row: Int, col: Int) -> (NSView, NSRect)? { order.indices.contains(row) && col < model.pairCount ? (self, slot(row: row, col: col)) : nil }

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
            rowViews[id]?.frame = CGRect(x: Layout.pad, y: CGFloat(i) * Layout.rowH, width: Layout.leftWidth - 6, height: Layout.rowH)
        }
    }

    private func slot(row: Int, col: Int) -> CGRect {
        CGRect(x: Layout.matrixX + CGFloat(col) * cellW, y: CGFloat(row) * Layout.rowH, width: cellW, height: Layout.rowH)
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        let pairs = model.pairCount

        // Alternating column stripes make it easy to follow a bus down the grid.
        for c in 0..<pairs where c % 2 == 0 {
            NSColor.labelColor.withAlphaComponent(0.035).setFill()
            NSBezierPath(roundedRect: CGRect(x: Layout.matrixX + CGFloat(c) * cellW, y: 0, width: cellW, height: bounds.height), xRadius: 6, yRadius: 6).fill()
        }
        // Hover guides: the row and column under the pointer.
        if let h = hover, h.row < order.count {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: CGRect(x: Layout.pad - 6, y: CGFloat(h.row) * Layout.rowH + 1, width: bounds.width - 2 * Layout.pad + 12, height: Layout.rowH - 2), xRadius: 8, yRadius: 8).fill()
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: CGRect(x: Layout.matrixX + CGFloat(h.col) * cellW, y: 0, width: cellW, height: bounds.height), xRadius: 6, yRadius: 6).fill()
        }

        for (r, id) in order.enumerated() {
            let routing = model.routing(for: id)
            let available = model.rows.first { $0.id == id }?.available ?? false
            let live = routing.enabled && available
            for c in 0..<pairs {
                let s = slot(row: r, col: c)
                let on = routing.pairs.contains(c), hovered = hover?.row == r && hover?.col == c
                let dotSize: CGFloat = min(cellW - 6, 18)
                if on {
                    // A filled crosspoint: rounded square in the accent colour with a white centre.
                    let rect = CGRect(x: s.midX - dotSize / 2, y: s.midY - dotSize / 2, width: dotSize, height: dotSize)
                    accent.withAlphaComponent(live ? 1 : 0.35).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
                    NSColor.white.withAlphaComponent(live ? 0.95 : 0.6).setFill()
                    NSBezierPath(ovalIn: CGRect(x: s.midX - 2.5, y: s.midY - 2.5, width: 5, height: 5)).fill()
                } else if hovered {
                    let rect = CGRect(x: s.midX - dotSize / 2, y: s.midY - dotSize / 2, width: dotSize, height: dotSize)
                    accent.withAlphaComponent(0.16).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
                    accent.withAlphaComponent(0.7).setStroke()
                    let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 5.5, yRadius: 5.5); ring.lineWidth = 1.5; ring.stroke()
                } else {
                    // An open crosspoint is just a quiet dot.
                    NSColor.labelColor.withAlphaComponent(0.2).setFill()
                    NSBezierPath(ovalIn: CGRect(x: s.midX - 2, y: s.midY - 2, width: 4, height: 4)).fill()
                }
            }
        }
        if order.isEmpty {
            let s = "No audio apps or microphones found.\nStart playing audio in an app and it will appear here." as NSString
            s.draw(in: bounds.insetBy(dx: 30, dy: 30), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
                                                                          .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }()])
        }
    }

    // In the floating window (or a popover that is not yet key) the first click must toggle a cell, not just activate the window.
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
        let p = convert(event.locationInWindow, from: nil)
        updateHover(hit(p))
        guard let (r, c) = hit(p) else { return }
        if model.routing(for: order[r]).pairs.contains(c) != paintTarget { model.togglePair(order[r], c, on: paintTarget) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    private func updateHover(_ h: (Int, Int)?) {
        let new = h.map { (row: $0.0, col: $0.1) }
        if new?.row != hover?.row || new?.col != hover?.col { hover = new; needsDisplay = true }
    }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Over the source controls we still want the row highlight, just without a column.
        let row = Int(p.y / Layout.rowH)
        if p.x < Layout.matrixX, row >= 0, row < order.count {
            let new = (row: row, col: -1)
            if new.row != hover?.row || new.col != hover?.col { hover = new; needsDisplay = true }
        } else { updateHover(hit(p)) }
    }
    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }
}

// MARK: - Bus labels and strips

/// Channel-pair labels above the grid, stacked ("1" over "2") so they fit narrow columns at a readable size.
final class BusLabelsView: NSView {
    var pairs = 8 { didSet { needsDisplay = true } }
    var cellW: CGFloat = Layout.defaultCellW { didSet { if cellW != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let num: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]
        ("Sources" as NSString).draw(at: NSPoint(x: Layout.pad, y: 9), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
        for p in 0..<pairs {
            for (line, ch) in [2 * p + 1, 2 * p + 2].enumerated() {
                let s = "\(ch)" as NSString, size = s.size(withAttributes: num)
                s.draw(at: NSPoint(x: Layout.matrixX + CGFloat(p) * cellW + (cellW - size.width) / 2, y: 3 + CGFloat(line) * 12), withAttributes: num)
            }
        }
    }
}

@MainActor
final class BusStripsView: NSView {
    private unowned let model: MixerModel
    var meters: [LevelBarView] = [], faders: [FaderView] = [], mutes: [IconButton] = []
    var cellW: CGFloat = Layout.defaultCellW { didSet { if cellW != oldValue { needsLayout = true } } }
    override var isFlipped: Bool { true }
    /// This view spans the whole width, over the spectrum picker beside it; only its own controls may take clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { let v = super.hitTest(point); return v === self ? nil : v }

    init(model: MixerModel) { self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    func reload() {
        let n = model.pairCount
        if meters.count != n {
            (meters as [NSView] + faders + mutes).forEach { $0.removeFromSuperview() }
            meters = (0..<n).map { _ in LevelBarView(vertical: true) }
            faders = (0..<n).map { i in
                let f = FaderView(vertical: true)
                f.target = self; f.action = #selector(faderChanged(_:)); f.tag = i
                f.toolTip = "Bus \(2 * i + 1)-\(2 * i + 2) level (dB). Double-click to reset."; return f
            }
            mutes = (0..<n).map { i in
                let b = IconButton(symbol: "speaker.wave.2.fill", alternate: "speaker.slash.fill", tip: "Mute bus \(2 * i + 1)-\(2 * i + 2)", size: 11, activeTint: .systemOrange)
                b.tag = i; b.target = self; b.action = #selector(muteChanged(_:)); return b
            }
            (meters as [NSView] + faders + mutes).forEach(addSubview)
            needsLayout = true
        }
        for i in 0..<n {
            let b = model.buses[i]
            if abs(faders[i].doubleValue - Double(b.gainDB)) > 0.05 { faders[i].doubleValue = Double(b.gainDB) }
            mutes[i].state = b.mute ? .on : .off; mutes[i].refreshTint()
        }
    }

    func updateMeters() { for (i, m) in meters.enumerated() where i < model.busLevels.count { m.update(model.busLevels[i]) } }

    override func layout() {
        super.layout()
        let top: CGFloat = 4, muteH: CGFloat = 20, mH = max(20, bounds.height - muteH - 8)
        let meterW: CGFloat = 4, faderW: CGFloat = 14, gap: CGFloat = 2
        for i in 0..<meters.count {
            let colX = Layout.matrixX + CGFloat(i) * cellW
            let x = colX + (cellW - (meterW + gap + faderW)) / 2
            meters[i].frame = CGRect(x: x, y: top, width: meterW, height: mH)
            faders[i].frame = CGRect(x: x + meterW + gap, y: top, width: faderW, height: mH)
            mutes[i].frame = CGRect(x: colX + (cellW - 20) / 2, y: top + mH + 4, width: 20, height: muteH)
        }
    }

    @objc private func faderChanged(_ s: FaderView) { model.updateBus(s.tag) { $0.gainDB = Float(s.doubleValue.rounded()) } }
    @objc private func muteChanged(_ b: IconButton) { b.refreshTint(); model.updateBus(b.tag) { $0.mute = b.state == .on } }
}
