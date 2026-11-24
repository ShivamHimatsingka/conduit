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
