// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
//
// `Conduit --uitest [outdir]`: exercises the real views by delivering genuine NSEvent mouse events through
// NSWindow.sendEvent (the same path the window server uses), against the installed driver and a real playing app.
// Writes light and dark screenshots of the live UI to `outdir`.
import AppKit
import ConduitBridge
import Foundation

@MainActor
enum UITest {
    private static var failures = 0
    private static func check(_ ok: Bool, _ what: String) { print(ok ? "  ok    \(what)" : "  FAIL  \(what)"); if !ok { failures += 1 } }

    private static func pump(_ model: MixerModel, _ vc: MixerViewController, _ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { model.poll(dt: 1.0 / 60); vc.updateMeters(); RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60)) }
    }

    private static func mouse(_ type: NSEvent.EventType, in view: NSView, at p: NSPoint, window: NSWindow) {
        let ev = NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        window.sendEvent(ev)
    }
    private static func cellCenter(row: Int, col: Int) -> NSPoint {
        NSPoint(x: Layout.matrixX + Layout.cellW * (CGFloat(col) + 0.5), y: Layout.rowH * (CGFloat(row) + 0.5))
    }
    private static func click(_ grid: MixerGridView, row: Int, col: Int, window: NSWindow) {
        mouse(.leftMouseDown, in: grid, at: cellCenter(row: row, col: col), window: window)
        mouse(.leftMouseUp, in: grid, at: cellCenter(row: row, col: col), window: window)
    }
    private static func drag(_ grid: MixerGridView, row: Int, from: Int, to: Int, window: NSWindow) {
        mouse(.leftMouseDown, in: grid, at: cellCenter(row: row, col: from), window: window)
        for c in stride(from: from, through: to, by: from <= to ? 1 : -1) { mouse(.leftMouseDragged, in: grid, at: cellCenter(row: row, col: c), window: window) }
        mouse(.leftMouseUp, in: grid, at: cellCenter(row: row, col: to), window: window)
    }
    private static func render(_ vc: MixerViewController, window: NSWindow, dark: Bool, to path: String) {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.appearance?.performAsCurrentDrawingAppearance { vc.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
        vc.view.layoutSubtreeIfNeeded(); vc.updateMeters()
        if let rep = vc.view.bitmapImageRepForCachingDisplay(in: vc.view.bounds) {
            vc.view.cacheDisplay(in: vc.view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    static func run(outDir: String) -> Bool {
        let model = MixerModel()
        model.persistsState = false
        model.start()
        for _ in 0..<30 where !model.driverConnected { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); model.refreshSources() }
        guard model.driverConnected else { print("UI TEST ABORTED: driver not installed"); return false }

        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-uitest.wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        try? LiveTest.writeTone(to: wav, seconds: 90)
        let player = Process(); player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay"); player.arguments = [wav.path]
        try? player.run(); defer { player.terminate() }

        var rowID: String?
        for _ in 0..<40 where rowID == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25)); model.refreshSources()
            if let obj = ProcessDiscovery.processes().first(where: { $0.pid == player.processIdentifier })?.objectID {
                rowID = model.rows.first { if case .app(let a?) = $0.kind { return a.processObjectIDs.contains(obj) } else { return false } }?.id
            }
        }
        guard let id = rowID, let r = model.rows.firstIndex(where: { $0.id == id }) else { print("UI TEST ABORTED: no playing source found"); return false }

        let size = NSSize(width: Layout.width(pairs: model.pairCount), height: 470)
        let vc = MixerViewController(model: model, host: nil)
        // Mouse events are only dispatched to windows that are ordered in; keep it far off-screen (borderless so it is not clamped back).
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = vc
        window.setContentSize(size)
        window.orderFrontRegardless()
        vc.view.layoutSubtreeIfNeeded()
        vc.modelStructureChanged()
        vc.view.layoutSubtreeIfNeeded()
        guard let row = vc.grid.subviews.compactMap({ $0 as? SourceRowView }).first(where: { $0.id == id }) else { print("UI TEST ABORTED: row view missing"); return false }
        func peak(_ p: Int) -> Float { model.busLevels[p].peakDB }

        print("clicking the real controls")
        check(model.routing(for: id).enabled == false, "starts disabled")
        row.toggle.performClick(nil)
        check(model.routing(for: id).enabled, "clicking the row's switch enables the source")
        click(vc.grid, row: r, col: 0, window: window)
        check(model.routing(for: id).pairs == [0], "mouse click on matrix cell (row \(r), bus 1-2) routes the source there")
        pump(model, vc, 4.5)
        check(abs(peak(0) - (-6)) < 1.5, "bus 1-2 meter reads \(String(format: "%.1f", peak(0))) dBFS (expect -6)")
        check(peak(1) < -60, "bus 3-4 stays silent")

        model.spectrumSourceID = id
        pump(model, vc, 1.5)
        check(vc.spectrumPopup.titleOfSelectedItem == row.name_, "spectrum picker shows the selected source")

        drag(vc.grid, row: r, from: 2, to: 4, window: window)
        check(model.routing(for: id).pairs == [0, 2, 3, 4], "dragging across cells paints routes 5-6, 7-8, 9-10")
        pump(model, vc, 2.0)
        check(abs(peak(3) - (-6)) < 1.5 && abs(peak(4) - (-6)) < 1.5, "all painted buses carry audio at once")
        drag(vc.grid, row: r, from: 3, to: 4, window: window)
        check(model.routing(for: id).pairs == [0, 2], "dragging from an active cell erases routes 7-8 and 9-10")
        click(vc.grid, row: r, col: 2, window: window)
        check(model.routing(for: id).pairs == [0], "clicking an active cell removes it")
        pump(model, vc, 2.0)
        check(peak(2) < -60 && peak(3) < -60 && peak(4) < -60, "erased buses go silent")

        row.gain.doubleValue = -12; _ = row.gain.sendAction(row.gain.action, to: row.gain.target)
        pump(model, vc, 1.5)
        check(abs(peak(0) - (-18)) < 2.0, "source level slider -12 dB -> bus \(String(format: "%.1f", peak(0))) dBFS")
        row.gain.doubleValue = 0; _ = row.gain.sendAction(row.gain.action, to: row.gain.target)
        row.mute.performClick(nil)
        pump(model, vc, 1.8)
        check(model.routing(for: id).mute && peak(0) < -60, "source M button mutes it")
        row.mute.performClick(nil)
        pump(model, vc, 1.5)
        check(abs(peak(0) - (-6)) < 1.5, "second click unmutes")

        let fader = vc.strips.faders[0]
        fader.doubleValue = -6; _ = fader.sendAction(fader.action, to: fader.target)
        pump(model, vc, 1.5)
        check(abs(peak(0) - (-12)) < 2.0, "bus fader -6 dB -> \(String(format: "%.1f", peak(0))) dBFS")
        vc.strips.mutes[0].performClick(nil)
        pump(model, vc, 1.5)
        check(model.buses[0].mute && peak(0) < -60, "bus M button mutes the bus")
        vc.strips.mutes[0].performClick(nil)
        fader.doubleValue = 0; _ = fader.sendAction(fader.action, to: fader.target)
        pump(model, vc, 3.0)

        print("rendering the live UI")
        render(vc, window: window, dark: false, to: outDir + "/live-light.png")
        render(vc, window: window, dark: true, to: outDir + "/live-dark.png")
        check(FileManager.default.fileExists(atPath: outDir + "/live-light.png"), "wrote \(outDir)/live-light.png and live-dark.png")

        row.toggle.performClick(nil)
        pump(model, vc, 2.5)
        check(!model.routing(for: id).enabled && peak(0) < -60, "switching the source off stops the capture")
        model.shutdown(persist: false)
        print(failures == 0 ? "UI TEST PASSED" : "UI TEST FAILED (\(failures))")
        return failures == 0
    }
}
