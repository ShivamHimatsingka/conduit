// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
import AppKit
import ConduitBridge
import Foundation

@MainActor
enum SelfTest {
    private static var failures = 0
    private static func check(_ ok: Bool, _ what: String) {
        print(ok ? "  ok    \(what)" : "  FAIL  \(what)")
        if !ok { failures += 1 }
    }
    private static func near(_ a: Float, _ b: Float, _ tol: Float) -> Bool { abs(a - b) <= tol }

    static func run() -> Bool {
        print("metering math (vDSP)")
        let db = MeterMath.dBFS([1, 0.5, 0.1, 0, 2])
        check(near(db[0], 0, 0.01) && near(db[1], -6.02, 0.02) && near(db[2], -20, 0.02), "linear -> dBFS (1.0, 0.5, 0.1)")
        check(db[3] == MeterMath.floorDB && db[4] == 0, "clamped to floor and 0 dBFS")
        let sine = (0..<4800).map { 0.5 * sinf(2 * .pi * 1000 * Float($0) / 48000) }
        check(near(MeterMath.rms(sine), 0.3536, 0.002), "RMS of a 0.5 sine = 0.354")
        check(near(MeterMath.peak(sine), 0.5, 0.001), "peak of a 0.5 sine = 0.5")

        print("ballistics")
        var l = LevelState()
        l.update(peakDB: -6, rmsDB: -12, dt: 1 / 60)
        check(l.peakDB == -6 && l.holdDB == -6, "instant attack, hold captured")
        for _ in 0..<60 { l.update(peakDB: MeterMath.floorDB, rmsDB: MeterMath.floorDB, dt: 1 / 60) }
        check(near(l.peakDB, -6 - LevelState.fallDBPerSecond, 0.5), "release falls at 42 dB/s")
        check(l.holdDB == -6, "peak-hold tick persists for 1 s (hold time is 1.3 s)")
        for _ in 0..<30 { l.update(peakDB: MeterMath.floorDB, rmsDB: MeterMath.floorDB, dt: 1 / 60) }
        check(l.holdDB < -6, "peak-hold tick then starts to fall")

        print("spectrum (vDSP real FFT)")
        let an = SpectrumAnalyzer()
        func bands(_ f: Float, _ amp: Float) -> [Float] {
            let x = (0..<an.size).map { amp * sinf(2 * .pi * f * Float($0) / 48000) }
            an.reset()
            return an.analyze(x, sampleRate: 48000, dt: 1)
        }
        let b1k = bands(1000, 0.5)
        let hi = b1k.indices.max { b1k[$0] < b1k[$1] }!
        let lo = 40.0 * pow(16000.0 / 40.0, Double(hi) / 32), up = 40.0 * pow(16000.0 / 40.0, Double(hi + 1) / 32)
        check(lo <= 1000 * 1.1 && up >= 1000 * 0.9, "1 kHz energy lands in band \(hi) (\(Int(lo))–\(Int(up)) Hz)")
        let peakDB = b1k[hi] * -MeterMath.floorDB + MeterMath.floorDB
        check(near(peakDB, -6.0, 2.0), "0.5-amplitude sine reads \(String(format: "%.1f", peakDB)) dBFS (expect ≈ -6)")
        check(bands(100, 0.5)[hi] < 0.4, "100 Hz sine does not light the 1 kHz band")
        let silent = bands(1000, 0)
        check(silent.allSatisfy { $0 < 0.02 }, "silence reads as silence")

        print("presets (JSON)")
        let preset = Preset(name: "Streaming", sources: [
            "app:com.spotify.client": SourceRouting(enabled: true, gainDB: -3, mute: false, mono: false, silenceOriginal: true, pairs: [0, 2]),
            "mic:BuiltInMicrophoneDevice": SourceRouting(enabled: true, gainDB: 0, mute: false, mono: true, silenceOriginal: false, pairs: [1]),
        ], buses: [BusSettings(gainDB: -2, mute: false)] + Array(repeating: BusSettings(), count: 7))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-selftest-\(getpid()).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(preset).write(to: tmp)
            check(try PresetStore.load(url: tmp) == preset, "save -> load round trip is lossless")
            try Data(#"{"version":99,"name":"x","sources":{},"buses":[]}"#.utf8).write(to: tmp)
            check((try? PresetStore.load(url: tmp)) == nil, "unknown preset version is rejected")
            try Data("not json".utf8).write(to: tmp)
            check((try? PresetStore.load(url: tmp)) == nil, "corrupt preset is rejected, not crashed on")
        } catch { check(false, "preset IO: \(error)") }

        print("routing model")
        let m = MixerModel(demo: true); m.start()
        m.togglePair("app:com.hnc.Discord", 5, on: true)
        check(m.routing(for: "app:com.hnc.Discord").pairs == [3, 5], "toggle on adds a pair, kept sorted")
        m.togglePair("app:com.hnc.Discord", 3, on: false)
        check(m.routing(for: "app:com.hnc.Discord").pairs == [5], "toggle off removes it")
        m.togglePair("app:com.hnc.Discord", 99, on: true)
        check(m.routing(for: "app:com.hnc.Discord").pairs == [5], "out-of-range bus is ignored")
        m.update("app:com.spotify.client") { $0.gainDB = -9; $0.mute = true }
        let snap = m.snapshot(named: "t")
        m.update("app:com.spotify.client") { $0.gainDB = 0; $0.mute = false }
        m.apply(snap)
        check(m.routing(for: "app:com.spotify.client").gainDB == -9 && m.routing(for: "app:com.spotify.client").mute, "apply(snapshot) restores state")

        print("driver installer logic")
        check(DriverInstaller.shellQuote("/a b/it's") == "'/a b/it'\\''s'", "shell quoting survives spaces and apostrophes")
        check(DriverInstaller.appleScriptEscape("say \"hi\" \\ ok") == "say \\\"hi\\\" \\\\ ok", "AppleScript string escaping")
        let script = DriverInstaller.installScript(source: URL(fileURLWithPath: "/Applications/My App/Conduit.app/Contents/Resources/Conduit.driver"),
                                                   destination: DriverInstaller.installedURL)
        check(script.contains("--noqtn") && script.contains("chown -R root:wheel") && script.contains("coreaudiod") && script.hasPrefix("set -e;"),
              "install script copies without quarantine, fixes ownership, restarts coreaudiod")
        check(!DriverInstaller.uninstallScript(destination: DriverInstaller.installedURL).contains("ditto"), "uninstall script only removes")
        do {
            let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("conduit-drv-\(getpid())")
            defer { try? fm.removeItem(at: root) }
            func fake(_ name: String, version: String, binary: String) throws -> URL {
                let u = root.appendingPathComponent(name + ".driver")
                try fm.createDirectory(at: u.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
                try (["CFBundleShortVersionString": version] as NSDictionary).write(to: u.appendingPathComponent("Contents/Info.plist"))
                try Data(binary.utf8).write(to: u.appendingPathComponent("Contents/MacOS/Conduit"))
                return u
            }
            let bundled = try fake("bundled", version: "0.0.2", binary: "binary-A")
            check(DriverInstaller.status(bundled: nil, installed: bundled) == .notBundled, "no bundled driver -> nothing to offer")
            check(DriverInstaller.status(bundled: bundled, installed: root.appendingPathComponent("absent.driver")) == .notInstalled, "missing install detected")
            check(DriverInstaller.status(bundled: bundled, installed: try fake("same", version: "0.0.2", binary: "binary-A")) == .upToDate, "identical copy is up to date")
            check(DriverInstaller.status(bundled: bundled, installed: try fake("old", version: "0.0.1", binary: "binary-A")) == .outdated(installed: "0.0.1"), "older version is outdated")
            check(DriverInstaller.status(bundled: bundled, installed: try fake("rebuilt", version: "0.0.2", binary: "binary-B")) == .outdated(installed: "0.0.2"), "same version but different binary is outdated")
        } catch { check(false, "driver status fixtures: \(error)") }

        print("menus (a way to quit must always exist)")
        let delegate = AppDelegate()
        let actions = delegate.makeAppMenu()
        let titles = actions.items.map(\.title)
        check(titles.contains("Quit Conduit"), "the ⋯ / status-item menu has Quit Conduit")
        check(titles.contains("Open Mixer in a Window") && titles.contains("Reconnect to Driver") && titles.contains("Launch at Login"), "…and window, reconnect and launch-at-login items")
        let main = delegate.buildMainMenu()
        check(main.items.map(\.title) == ["Conduit", "File", "Edit", "View", "Window", "Help"], "main menu bar: Conduit, File, Edit, View, Window, Help")
        let quit = main.items.first?.submenu?.items.first { $0.title == "Quit Conduit" }
        check(quit?.keyEquivalent == "q" && quit?.keyEquivalentModifierMask == .command, "⌘Q quits")
        check(main.items.first?.submenu?.items.contains { $0.title == "Hide Conduit" && $0.keyEquivalent == "h" } == true, "⌘H hides")
        check(Layout.height(rows: 5) < 340 && Layout.width(pairs: 8) < 540, "compact: 5 sources fit in \(Int(Layout.width(pairs: 8)))×\(Int(Layout.height(rows: 5))) pt")

        print("per-frame cost (model poll + all meters + FFT every 2nd frame)")
        let vc = MixerViewController(model: m, host: nil)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Layout.width(pairs: 8), height: Layout.height(rows: 5)), styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentViewController = vc; vc.view.layoutSubtreeIfNeeded()
        for _ in 0..<60 { m.poll(dt: 1 / 60); vc.updateMeters() }
        let frames = 1200
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<frames { m.poll(dt: 1 / 60); vc.updateMeters() }
        let perFrame = Double(DispatchTime.now().uptimeNanoseconds - t0) / Double(frames) / 1000
        print("  info  \(String(format: "%.0f", perFrame)) µs/frame -> \(String(format: "%.2f", perFrame * 60 / 10_000)) % of one core at 60 fps (includes synthetic signal generation)")
        check(perFrame * 60 / 10_000 < 1.0, "metering + rendering costs < 1 % of a core at 60 fps")

        print(failures == 0 ? "APP SELFTEST PASSED" : "APP SELFTEST FAILED (\(failures))")
        return failures == 0
    }
}
