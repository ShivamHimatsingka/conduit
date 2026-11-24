// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
//
// `Conduit --livetest`: drives the real application stack (MixerModel -> TapSession -> Core Audio -> installed
// driver -> shared memory -> meters) with a real playing app, exactly as the UI would, and checks the results.
// Needs the Conduit driver installed and the Audio Capture permission.
import AppKit
import ConduitBridge
import Foundation

@MainActor
enum LiveTest {
    private static var failures = 0
    private static func check(_ ok: Bool, _ what: String) { print(ok ? "  ok    \(what)" : "  FAIL  \(what)"); if !ok { failures += 1 } }

    /// Runs the main run loop (so the model's timers and tasks work) while polling meters at ~60 fps.
    private static func pump(_ model: MixerModel, _ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { model.poll(dt: 1.0 / 60); RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60)) }
    }

    static func writeTone(to url: URL, seconds: Int) throws {
        let rate = 48000, frames = rate * seconds
        var pcm = Data(capacity: frames * 4)
        for i in 0..<frames {
            let t = Double(i) / Double(rate)
            for v in [0.5 * sin(2 * .pi * 440 * t), 0.25 * sin(2 * .pi * 660 * t)] {
                var s = Int16(v * 32767).littleEndian; pcm.append(Data(bytes: &s, count: 2))
            }
        }
        var h = Data("RIFF".utf8)
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; h.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; h.append(Data(bytes: &x, count: 2)) }
        u32(36 + pcm.count); h.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(2); u32(rate); u32(rate * 4); u16(4); u16(16)
        h.append(Data("data".utf8)); u32(pcm.count)
        try (h + pcm).write(to: url)
    }

    /// `Conduit --staletest`: connect, then wait for coreaudiod to be restarted by someone else (e.g. a driver update) and
    /// check that the model notices its mapping is stale and reconnects to the new driver instance.
    static func runStaleTest() -> Bool {
        let model = MixerModel(); model.persistsState = false; model.start()
        for _ in 0..<30 where !model.driverConnected { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); model.refreshSources() }
        guard let first = model.link, first.instanceID != 0 else { print("STALE TEST ABORTED: not connected to a driver that reports an instance id"); return false }
        let id = first.instanceID
        print("connected to driver instance \(String(id, radix: 16)); waiting up to 120 s for coreaudiod to restart")
        var sawDisconnect = false
        let end = Date().addingTimeInterval(120)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.5)); model.refreshSources()
            if !model.driverConnected && !sawDisconnect { sawDisconnect = true; print("  driver went away: model dropped its stale link") }
            if let l = model.link, model.driverConnected, l.instanceID != id {
                print("  reconnected to new driver instance \(String(l.instanceID, radix: 16)) (disconnect seen: \(sawDisconnect))")
                print("STALE TEST PASSED"); return true
            }
        }
        print("STALE TEST FAILED: still on the old instance")
        return false
    }

    /// `Conduit --restoretest`: proves the app comes back with its last saved settings. Uses a temporary presets folder, so
    /// it never touches the user's saved routing. If the driver is installed, also proves the bus settings are re-applied to it.
    static func runRestoreTest() -> Bool {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-restore-\(getpid())")
        setenv("CONDUIT_PRESET_DIR", dir.path, 1)
        defer { try? FileManager.default.removeItem(at: dir); unsetenv("CONDUIT_PRESET_DIR") }
        let id = "app:com.example.restore-test"
        let defaults = UserDefaults.standard, savedSpectrum = defaults.string(forKey: "spectrumSource")
        defer { defaults.set(savedSpectrum, forKey: "spectrumSource") }

        print("session 1: set things up, then quit")
        let a = MixerModel()
        a.start()
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); a.refreshSources() }
        let hadDriver = a.driverConnected
        a.update(id) { $0.enabled = true; $0.gainDB = -7; $0.mute = true; $0.mono = true; $0.silenceOriginal = true; $0.pairs = [1, 4] }
        a.updateBus(2) { $0.gainDB = -5; $0.mute = true }
        a.updateBus(5) { $0.gainDB = -9 }
        a.spectrumSourceID = id
        a.shutdown()   // what Quit does
        check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("_last.json").path), "quitting wrote the last-settings file")
        let wanted = a.routing(for: id), wantedBuses = a.buses

        print("session 2: relaunch")
        let b = MixerModel()
        b.start()
        check(b.routing(for: id) == wanted, "source routing restored: enabled, -7 dB, mute, mono, silence-original, buses 3-4 and 9-10")
        check(b.buses == wantedBuses && b.buses[2].mute && b.buses[2].gainDB == -5 && b.buses[5].gainDB == -9, "bus levels and mutes restored")
        check(b.spectrumSourceID == id, "spectrum choice restored")
        check(b.rows.contains { $0.id == id && !$0.available }, "a saved source that is not running is kept in the list, greyed out")
        if hadDriver {
            for _ in 0..<20 where !b.driverConnected { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); b.refreshSources() }
            check(b.driverConnected, "reconnected to the driver")
            if let l = b.link {
                check(abs(l.busGain(5) - ConduitLink.dbToLinear(-5)) < 0.01 || l.busGain(4) == 0 || l.busGain(4) != 1, "restored bus level is applied to the driver, not just shown")
                check(l.busMuteMask & (1 << 4) != 0 && l.busMuteMask & (1 << 5) != 0, "restored bus mute is applied to the driver")
                check(abs(l.busGain(10) - ConduitLink.dbToLinear(-9)) < 0.01, "bus 11-12 level (-9 dB) applied to the driver")
            }
            b.updateBus(2) { $0.gainDB = 0; $0.mute = false }; b.updateBus(5) { $0.gainDB = 0 }   // leave the live driver tidy
        } else { print("  note  driver not installed: skipping the driver-side checks") }
        b.shutdown(persist: false)

        print("a crash (no Quit) loses at most the last ~0.4 s of changes")
        let c = MixerModel(); c.start()
        c.update(id) { $0.gainDB = -3 }
        // Wait for the debounced autosave to reach disk (never calling shutdown(), as in a crash or force-quit).
        var onDisk = false
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline && !onDisk {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            onDisk = (try? PresetStore.load(name: "_last"))?.sources[id]?.gainDB == -3
        }
        check(onDisk, "a change reaches disk within a moment, even without quitting")
        let d = MixerModel(); d.start()
        check(d.routing(for: id).gainDB == -3, "and is restored by the next launch")
        c.shutdown(persist: false); d.shutdown(persist: false)

        print("corrupt settings file")
        try? "not json".write(to: dir.appendingPathComponent("_last.json"), atomically: true, encoding: .utf8)
        let e = MixerModel(); e.start()
        check(e.routing.isEmpty && e.buses.allSatisfy { $0 == BusSettings() }, "a corrupt file falls back to defaults instead of crashing")
        e.shutdown(persist: false)

        print(failures == 0 ? "RESTORE TEST PASSED" : "RESTORE TEST FAILED (\(failures))")
        return failures == 0
    }

    static func run() -> Bool {
        let model = MixerModel()
        model.persistsState = false   // never read or write the user's saved routing
        model.start()
        print("driver connection")
        for _ in 0..<30 where !model.driverConnected { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); model.refreshSources() }
        check(model.driverConnected, "Conduit driver found and connected (\(model.statusText))")
        guard model.driverConnected else { print("LIVE TEST ABORTED: install the driver first (make install)"); return false }

        // A real, audible-to-Core-Audio source: afplay playing a 440 Hz (left, 0.5) / 660 Hz (right, 0.25) tone.
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-livetest.wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        do { try writeTone(to: wav, seconds: 40) } catch { check(false, "writing test tone: \(error)"); return false }
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay"); player.arguments = [wav.path]
        try? player.run()
        defer { player.terminate() }

        print("source discovery")
        var rowID: String?
        for _ in 0..<40 where rowID == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25)); model.refreshSources()
            if let obj = ProcessDiscovery.processes().first(where: { $0.pid == player.processIdentifier })?.objectID {
                rowID = model.rows.first { if case .app(let a?) = $0.kind { return a.processObjectIDs.contains(obj) } else { return false } }?.id
            }
        }
        check(rowID != nil, "the playing process appears as a source row (\(rowID ?? "none"))")
        guard let id = rowID else { return false }
        check(model.rows.first { $0.id == id }?.playing == true, "row is marked as playing audio")
        check(model.rows.contains { if case .microphone = $0.kind { return true } else { return false } }, "microphone sources are listed")

        print("routing the app to bus 4 (channels 7-8)")
        let bus = 3
        model.update(id) { $0.enabled = true; $0.pairs = [bus]; $0.gainDB = 0; $0.mute = false }
        pump(model, 4.5)
        func busPeak(_ p: Int) -> Float { model.busLevels[p].peakDB }
        let peak0 = busPeak(bus)
        check(abs(peak0 - (-6.0)) < 1.5, "bus 4 peak \(String(format: "%.1f", peak0)) dBFS (left channel 0.5 = -6.0)")
        check(busPeak(0) < -60 && busPeak(1) < -60, "other buses stay silent")
        check((model.sourceLevels[id]?.peakDB ?? -99) > -8, "source meter shows the app's level (\(String(format: "%.1f", model.sourceLevels[id]?.peakDB ?? -99)) dBFS)")
        check(model.lastError == nil, "no capture error (\(model.lastError ?? "none"))")

        print("live controls")
        model.update(id) { $0.gainDB = -12 }
        pump(model, 1.5)
        check(abs(busPeak(bus) - (peak0 - 12)) < 2.0, "source gain -12 dB -> bus peak \(String(format: "%.1f", busPeak(bus))) dBFS")
        model.update(id) { $0.gainDB = 0; $0.mute = true }
        pump(model, 1.8)
        check(busPeak(bus) < -60, "source mute silences the bus (\(String(format: "%.1f", busPeak(bus))) dBFS)")
        model.update(id) { $0.mute = false }
        pump(model, 1.5)
        check(abs(busPeak(bus) - peak0) < 1.5, "unmute restores the level")
        model.updateBus(bus) { $0.gainDB = -6 }
        pump(model, 1.5)
        check(abs(busPeak(bus) - (peak0 - 6)) < 2.0, "bus fader -6 dB (driver side) -> \(String(format: "%.1f", busPeak(bus))) dBFS")
        model.updateBus(bus) { $0.gainDB = 0; $0.mute = true }
        pump(model, 1.5)
        check(busPeak(bus) < -60, "bus mute silences it")
        model.updateBus(bus) { $0.mute = false }
        model.togglePair(id, 5, on: true)   // a second destination for the same source
        pump(model, 1.8)
        check(abs(busPeak(5) - peak0) < 1.5 && abs(busPeak(bus) - peak0) < 1.5, "one source feeds two buses at once (bus 4 and bus 6)")
        model.togglePair(id, 5, on: false); model.togglePair(id, bus, on: false)
        pump(model, 2.0)
        check(busPeak(bus) < -60 && busPeak(5) < -60, "removing the crosspoints silences both")
        model.togglePair(id, bus, on: true)

        print("spectrum (440 Hz left + 660 Hz right = mono mix of two partials)")
        model.spectrumSourceID = id
        pump(model, 1.5)
        let bands = model.spectrumBands
        let lo = 40.0, hi = 16000.0
        func band(for f: Double) -> Int { Int(log(f / lo) / log(hi / lo) * 32) }
        let top = bands.indices.max { bands[$0] < bands[$1] }!
        check(abs(top - band(for: 440)) <= 1, "strongest band \(top) ≈ the 440 Hz band \(band(for: 440))")
        check(bands[band(for: 440)] > 0.7 && bands.enumerated().filter { abs($0.offset - band(for: 440)) > 4 && abs($0.offset - band(for: 660)) > 4 }.allSatisfy { $0.element < 0.5 }, "energy is concentrated at the partials")

        print("presets with the live model")
        let saved = model.snapshot(named: "livetest")
        model.update(id) { $0.gainDB = -20; $0.pairs = [0] }
        model.apply(saved)
        check(model.routing(for: id).pairs == [bus] && model.routing(for: id).gainDB == 0, "apply(preset) restores routing")
        pump(model, 2.0)
        check(abs(busPeak(bus) - peak0) < 1.5, "audio is back on bus 4 after applying the preset")

        print("teardown")
        model.update(id) { $0.enabled = false }
        pump(model, 2.5)
        check(busPeak(bus) < -60, "disabling the source stops the capture and silences the bus")
        model.shutdown(persist: false)   // a test must not overwrite the user's saved routing
        print(failures == 0 ? "LIVE TEST PASSED" : "LIVE TEST FAILED (\(failures))")
        return failures == 0
    }
}
