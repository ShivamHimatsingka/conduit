// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
import AppKit
import ConduitBridge

@MainActor
protocol MixerModelObserver: AnyObject {
    func modelStructureChanged()   // rows, routing, status or presets changed
}

/// Everything the UI shows, and everything the UI can change. Views never talk to the driver or to
/// Core Audio directly. The model is the single owner of the ConduitLink and the TapSession.
@MainActor
final class MixerModel {
    // MARK: Row model
    enum RowKind { case app(AudioApp?), microphone(InputDevice?) }
    struct Row {
        let id: String
        let title: String
        let kind: RowKind
        let available: Bool    // can be tapped right now
        let playing: Bool      // app is currently producing audio
        let pid: pid_t?        // for the icon
    }

    // MARK: State
    private(set) var link: ConduitLink?
    private var session: TapSession?
    private(set) var apps: [AudioApp] = []
    private(set) var mics: [InputDevice] = []
    private(set) var routing: [String: SourceRouting] = [:]
    private(set) var buses: [BusSettings] = Array(repeating: BusSettings(), count: 8)
    private(set) var rows: [Row] = []
    private(set) var statusText = "Looking for the Conduit driver…"
    private(set) var driverConnected = false
    private(set) var driverStatus: DriverInstaller.Status = .notBundled
    private var refreshCount = 0
    private(set) var lastError: String?
    private(set) var hint: String?
    var spectrumSourceID: String? { didSet { spectrum.reset(); notify() } }

    // Levels (updated by poll, read by views every frame)
    private(set) var sourceLevels: [String: LevelState] = [:]
    private(set) var busLevels: [LevelState] = Array(repeating: LevelState(), count: 8)
    private(set) var spectrumBands: [Float] = Array(repeating: 0, count: 32)

    var pairCount: Int { buses.count }
    let demo: Bool
    /// Writes routing to the hidden `_last` preset after changes. Tests turn this off so they never touch the user's state.
    var persistsState = true

    private var observers: [WeakObserver] = []
    private struct WeakObserver { weak var object: MixerModelObserver? }

    private var activeIDs: [String] = []
    private var activeSignature = ""
    private var lastRebuild = Date.distantPast
    private var pendingReconcile = false
    private var monitor: ProcessMonitor?
    private var maintenance: Timer?
    private var saveTask: Task<Void, Never>?
    private let spectrum = SpectrumAnalyzer()
    private var scratch: [Float] = []
    private var silentFor: [String: Float] = [:]
    private var tick = 0
    private var demoClock: Float = 0

    init(demo: Bool = false) { self.demo = demo }

    // MARK: Lifecycle
    func start() {
        if demo { loadDemo(); return }
        if persistsState, let last = try? PresetStore.load(name: "_last") { adopt(last, reconcileNow: false) }
        refreshSources()
        driverStatus = DriverInstaller.status()
        monitor = ProcessMonitor { [weak self] in Task { @MainActor in self?.refreshSources() } }
        maintenance = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSources() }
        }
        maintenance?.tolerance = 0.5
    }

    func addObserver(_ o: MixerModelObserver) { observers.removeAll { $0.object == nil }; observers.append(WeakObserver(object: o)) }
    private func notify() { observers.forEach { $0.object?.modelStructureChanged() } }

    // MARK: Driver connection
    func reconnect() {
        link = nil
        session?.stop(); session = nil; activeIDs = []; activeSignature = ""
        refreshSources()
    }

    private func connectIfNeeded() {
        guard link == nil else { return }
        if let l = try? ConduitLink() {
            link = l
            let pairs = max(1, l.channels / 2)
            if buses.count != pairs { buses = Array(repeating: BusSettings(), count: pairs); busLevels = Array(repeating: LevelState(), count: pairs) }
            pushBuses()
        }
    }

    // MARK: Source discovery
    func refreshSources() {
        guard !demo else { return }
        refreshCount += 1
        if refreshCount % 4 == 1 { driverStatus = DriverInstaller.status() }      // hashes ~1 MB: not every tick
        if refreshCount % 4 == 0 { dropLinkIfDriverRestarted() }                    // a restarted coreaudiod leaves our mapping stale
        connectIfNeeded()
        driverConnected = link != nil
        apps = ProcessDiscovery.apps()
        mics = DeviceDiscovery.inputDevices()
        if driverConnected {
            let rate = link?.clock().map { Int($0.sampleRate) } ?? 48000
            statusText = "Conduit driver connected · \(link?.channels ?? 0) ch · \(rate / 1000).\((rate % 1000) / 100) kHz"
            if case .outdated = driverStatus { statusText += " · update available" }
        } else {
            switch driverStatus {
            case .notInstalled: statusText = "Audio driver not installed · capture is meter-only"
            case .outdated: statusText = "Audio driver needs updating · capture is meter-only"
            default: statusText = "Driver not found · capture is meter-only"
            }
        }
        rebuildRows()
        reconcile()
        notify()
    }

    /// The driver publishes a random id per coreaudiod lifetime. If it changed (driver updated, coreaudiod restarted) or the
    /// driver vanished, our shared-memory mapping is stale: drop it, and the capture session built on it, and reconnect.
    private func dropLinkIfDriverRestarted() {
        guard let link else { return }
        let probe = ConduitLink.probeInstanceID()
        guard probe == nil || (link.instanceID != 0 && probe != link.instanceID) else { return }
        self.link = nil
        session?.stop(); session = nil; activeIDs = []; activeSignature = ""
    }

    /// Called after the driver is installed, updated or removed.
    func driverChanged() {
        driverStatus = DriverInstaller.status()
        reconnect()
    }

    private func rebuildRows() {
        var out: [Row] = []
        var seen = Set<String>()
        for a in apps {
            let id = "app:" + a.bundleID
            seen.insert(id)
            out.append(Row(id: id, title: a.name, kind: .app(a), available: true, playing: a.isProducingAudio, pid: a.pid))
        }
        for m in mics {
            let id = "mic:" + m.uid
            seen.insert(id)
            out.append(Row(id: id, title: m.name, kind: .microphone(m), available: true, playing: false, pid: nil))
        }
        // Routings that are saved/enabled but whose source is not present right now stay visible, greyed.
        for (id, r) in routing where !seen.contains(id) && (r.enabled || !r.pairs.isEmpty) {
            let name = id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? id
            out.append(Row(id: id, title: name, kind: id.hasPrefix("mic:") ? .microphone(nil) : .app(nil), available: false, playing: false, pid: nil))
        }
        rows = out
    }

    // MARK: Editing
    func routing(for id: String) -> SourceRouting { routing[id] ?? SourceRouting() }

    func update(_ id: String, _ change: (inout SourceRouting) -> Void) {
        var r = routing(for: id)
        change(&r)
        r.pairs = Array(Set(r.pairs.filter { $0 >= 0 && $0 < pairCount })).sorted()
        guard r != routing[id] else { return }
        routing[id] = r
        reconcile()
        scheduleAutosave()
        notify()
    }

    func togglePair(_ id: String, _ pair: Int, on: Bool) {
        update(id) { r in
            if on { if !r.pairs.contains(pair) { r.pairs.append(pair) } } else { r.pairs.removeAll { $0 == pair } }
        }
    }

    func updateBus(_ pair: Int, _ change: (inout BusSettings) -> Void) {
        guard buses.indices.contains(pair) else { return }
        change(&buses[pair])
        pushBuses()
        scheduleAutosave()
        notify()
    }

    private func pushBuses() {
        guard let link else { return }
        for (p, b) in buses.enumerated() {
            let g = ConduitLink.dbToLinear(b.gainDB)
            for ch in [2 * p, 2 * p + 1] where ch < link.channels { link.setBusGain(ch, g); link.setBusMute(ch, b.mute) }
        }
    }

    // MARK: Presets
    func snapshot(named name: String) -> Preset { Preset(name: name, sources: routing, buses: buses) }
    func apply(_ preset: Preset) { adopt(preset, reconcileNow: true); scheduleAutosave() }

    private func adopt(_ p: Preset, reconcileNow: Bool) {
        routing = p.sources
        for id in routing.keys { routing[id]?.pairs.removeAll { $0 >= max(pairCount, p.buses.count) } }
        if !p.buses.isEmpty { buses = (0..<pairCount).map { $0 < p.buses.count ? p.buses[$0] : BusSettings() } }
        pushBuses()
        if reconcileNow { rebuildRows(); reconcile(); notify() }
    }

    private func scheduleAutosave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, !self.demo, self.persistsState else { return }
            _ = try? PresetStore.save(self.snapshot(named: "_last"))
        }
    }

    // MARK: Reconciling routing with the capture session
    private func wantedSources() -> [(id: String, source: TapSource, signature: String)] {
        rows.compactMap { row in
            let r = routing(for: row.id)
            guard r.enabled, row.available else { return nil }
            let gain = ConduitLink.dbToLinear(r.gainDB)
            var sends: [Int: Float] = [:]
            for p in r.pairs { sends[p] = gain }
            switch row.kind {
            case .app(let a?):
                guard !a.processObjectIDs.isEmpty else { return nil }
                let s = TapSource(kind: .app(a), sends: sends, mute: r.mute, mono: r.mono, silenceOriginal: r.silenceOriginal)
                return (row.id, s, "\(row.id)|\(a.processObjectIDs.sorted())|\(r.silenceOriginal)")
            case .microphone(let m?):
                return (row.id, TapSource(kind: .microphone(uid: m.uid, name: m.name), sends: sends, mute: r.mute, mono: r.mono), "\(row.id)")
            default:
                return nil
            }
        }
    }

    private func reconcile() {
        guard !demo else { return }
        let wanted = wantedSources()
        let signature = wanted.map(\.signature).joined(separator: ";") + (link == nil ? "|monitor" : "|driver")
        if signature == activeSignature, let session {
            // Same source set: push live parameters. Levels ramp inside the real-time engine, no rebuild.
            for (i, w) in wanted.enumerated() {
                for p in 0..<pairCount { session.setSend(i, pair: p, gain: w.source.sends[p] ?? 0) }
                session.setFlags(i, mute: w.source.mute, mono: w.source.mono)
            }
            return
        }
        // Source set changed: rebuild, but never more than once every 2 s (helper processes come and go).
        let wait = 2.0 + lastRebuild.timeIntervalSinceNow
        if wait > 0, session != nil, !pendingReconcile {
            pendingReconcile = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                self?.pendingReconcile = false
                self?.reconcile()
            }
            return
        }
        guard !pendingReconcile else { return }
        lastRebuild = Date()
        session?.stop(); session = nil; activeIDs = []; activeSignature = ""
        lastError = nil
        guard !wanted.isEmpty else { return }
        let s = TapSession(link: link)
        do {
            try s.start(sources: wanted.map(\.source))
            session = s; activeIDs = wanted.map(\.id); activeSignature = signature
        } catch {
            lastError = "\(error)"
        }
    }

    // MARK: Metering (called once per display frame while a mixer view is visible)
    private var lastPoll: CFTimeInterval = 0
    /// Several mixer views (popover + floating panel) may share one model; meters are consumed
    /// (peak max-hold is read-and-clear), so only the first caller in each frame polls.
    func pollIfDue() {
        let now = CACurrentMediaTime()
        let dt = now - lastPoll
        guard dt >= 0.012 else { return }
        lastPoll = now
        poll(dt: Float(min(dt, 0.25)))
    }

    func shutdown(persist: Bool = true) {
        session?.stop(); session = nil
        if persist && persistsState && !demo { _ = try? PresetStore.save(snapshot(named: "_last")) }
    }

    func poll(dt: Float) {
        tick += 1
        if demo { pollDemo(dt: dt); return }

        // Bus pairs from the driver (post-fader), plus per-source peaks from the capture engine.
        var busPeaks = [Float](repeating: 0, count: pairCount), busRMS = busPeaks
        if let link {
            var ins: [MeterLevel] = [], outs: [MeterLevel] = []
            link.readMeters(inputs: &ins, buses: &outs)   // always read: this also clears the max-hold peaks
            // The driver keeps its last block's RMS when no audio is flowing; only trust meters while its clock runs.
            let running = link.clock()?.running ?? false
            for p in 0..<pairCount where running {
                let a = 2 * p, b = min(2 * p + 1, outs.count - 1)
                busPeaks[p] = max(outs[a].peak, outs[b].peak)
                busRMS[p] = max(outs[a].rms, outs[b].rms)
            }
        }
        var srcPeaks = [Float](repeating: 0, count: activeIDs.count), srcRMS = srcPeaks
        for i in activeIDs.indices {
            srcPeaks[i] = session?.takePeak(i) ?? 0
            if session?.latestSamples(i, frames: 1024, into: &scratch) == true { srcRMS[i] = MeterMath.rms(scratch) }
        }
        let bp = MeterMath.dBFS(busPeaks), br = MeterMath.dBFS(busRMS), sp = MeterMath.dBFS(srcPeaks), sr = MeterMath.dBFS(srcRMS)
        for p in 0..<pairCount { busLevels[p].update(peakDB: bp[p], rmsDB: br[p], dt: dt) }
        var live = Set<String>()
        for (i, id) in activeIDs.enumerated() {
            live.insert(id)
            sourceLevels[id, default: LevelState()].update(peakDB: sp[i], rmsDB: sr[i], dt: dt)
        }
        for id in sourceLevels.keys where !live.contains(id) { sourceLevels[id]?.update(peakDB: MeterMath.floorDB, rmsDB: MeterMath.floorDB, dt: dt) }

        updateHint(srcPeaks: srcPeaks, dt: dt)

        if tick % 2 == 0, let sid = spectrumSourceID, let idx = activeIDs.firstIndex(of: sid),
           session?.latestSamples(idx, frames: spectrum.size, into: &scratch) == true {
            spectrumBands = spectrum.analyze(scratch, sampleRate: session?.sampleRate ?? 48000, dt: dt * 2)
        }
    }

    /// An app that is clearly playing but whose tap stays at exact silence usually means the
    /// "Audio Capture" privacy permission has not been granted.
    private func updateHint(srcPeaks: [Float], dt: Float) {
        var suspect = false
        for (i, id) in activeIDs.enumerated() {
            guard case .app(let a?)? = rows.first(where: { $0.id == id })?.kind, a.isProducingAudio else { silentFor[id] = 0; continue }
            silentFor[id] = srcPeaks[i] == 0 ? (silentFor[id] ?? 0) + dt : 0
            if (silentFor[id] ?? 0) > 5 { suspect = true }
        }
        let new = suspect ? "An app is playing but nothing is captured. Allow Conduit under System Settings → Privacy & Security → Audio Capture." : nil
        if new != hint { hint = new; notify() }
    }

    // MARK: Demo data (used for screenshots and UI development; never touches Core Audio)
    private func loadDemo() {
        func app(_ id: String, _ name: String, _ pid: pid_t, playing: Bool) -> AudioApp {
            AudioApp(bundleID: id, name: name, pid: pid, processObjectIDs: [UInt32(pid)], isProducingAudio: playing)
        }
        apps = [app("com.spotify.client", "Spotify", 101, playing: true), app("com.google.Chrome", "Google Chrome", 102, playing: true),
                app("com.hnc.Discord", "Discord", 103, playing: true), app("com.apple.logic10", "Logic Pro", 104, playing: false)]
        mics = [InputDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", channels: 1)]
        routing = [
            "app:com.spotify.client": SourceRouting(enabled: true, gainDB: -3, pairs: [0, 2]),
            "app:com.google.Chrome": SourceRouting(enabled: true, gainDB: 0, pairs: [1]),
            "app:com.hnc.Discord": SourceRouting(enabled: true, gainDB: -6, silenceOriginal: true, pairs: [3]),
            "mic:BuiltInMicrophoneDevice": SourceRouting(enabled: true, gainDB: 0, mono: true, pairs: [0, 1, 3]),
        ]
        buses = (0..<8).map { _ in BusSettings() }
        buses[2].gainDB = -4
        buses[5].mute = true
        driverConnected = true
        statusText = "Conduit driver connected · 16 ch · 48.0 kHz (demo data)"
        rebuildRows()
        spectrumSourceID = "app:com.spotify.client"
    }

    private func pollDemo(dt: Float) {
        demoClock += dt
        let t = demoClock
        var busPeak = [Float](repeating: 0, count: pairCount)
        for row in rows {
            let r = routing(for: row.id)
            guard r.enabled else { continue }
            let seed = Float(abs(row.id.hashValue % 97)) / 97
            let level = row.playing || row.id.hasPrefix("mic:") ? 0.18 + 0.55 * abs(sin(t * (1.1 + seed) + seed * 9)) * (0.6 + 0.4 * abs(sin(t * 7.3 + seed))) : 0
            sourceLevels[row.id, default: LevelState()].update(peakDB: MeterMath.dBFS([level])[0], rmsDB: MeterMath.dBFS([level * 0.55])[0], dt: dt)
            if !r.mute { for p in r.pairs where p < pairCount { busPeak[p] = max(busPeak[p], level * ConduitLink.dbToLinear(r.gainDB)) } }
        }
        for p in 0..<pairCount {
            let g = buses[p].mute ? 0 : ConduitLink.dbToLinear(buses[p].gainDB)
            let v = busPeak[p] * g
            busLevels[p].update(peakDB: MeterMath.dBFS([v])[0], rmsDB: MeterMath.dBFS([v * 0.6])[0], dt: dt)
        }
        if tick % 2 == 0, spectrumSourceID != nil {   // synthetic programme material -> real vDSP FFT
            let n = spectrum.size
            if scratch.count != n { scratch = [Float](repeating: 0, count: n) }
            for i in 0..<n {
                let x = Float(i) / 48000 + t
                scratch[i] = 0.30 * sin(2 * .pi * 110 * x) * (0.7 + 0.3 * sin(t * 3)) + 0.18 * sin(2 * .pi * 440 * x) + 0.10 * sin(2 * .pi * 1760 * x)
                    + 0.05 * sin(2 * .pi * 5200 * x) * abs(sin(t * 5))
            }
            spectrumBands = spectrum.analyze(scratch, sampleRate: 48000, dt: dt * 2)
        }
    }
}
