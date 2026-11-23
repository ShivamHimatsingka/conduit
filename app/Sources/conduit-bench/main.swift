// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
//
// conduit-bench: round-trip latency, clock-drift and sample-rate benchmarks against real Core Audio devices.
import CConduit
import ConduitBridge
import CoreAudio
import Foundation

// MARK: - Utilities
func fail(_ msg: String) -> Never { FileHandle.standardError.write(Data("conduit-bench: \(msg)\n".utf8)); exit(1) }
let usage = """
usage: conduit-bench <command> [options]
  devices                              list audio devices (uid, channels, rate)
  loopback [--uid UID] [--buffer N] [--seconds S] [--channel C] [--json]
                                       impulse round trip through a loopback device (default: the Conduit device).
                                       Reports sample-accuracy and callback-to-callback latency.
  clocks <uidA> [uidB] [--seconds S]   measure each device's real sample rate against the host clock and the
                                       relative drift between two devices
  rates [--uid UID]                    switch the device through 44.1/48/96 kHz and verify the real clock each time
"""

struct Timebase {
    static let secondsPerTick: Double = { var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb); return Double(tb.numer) / Double(tb.denom) * 1e-9 }()
}
func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func getU32(_ dev: AudioObjectID, _ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
    var a = addr(s, scope), v: UInt32 = 0, n = UInt32(4)
    return AudioObjectGetPropertyData(dev, &a, 0, nil, &n, &v) == noErr ? v : nil
}
func nominalRate(_ dev: AudioObjectID) -> Double? {
    var a = addr(kAudioDevicePropertyNominalSampleRate), v = 0.0, n = UInt32(8)
    return AudioObjectGetPropertyData(dev, &a, 0, nil, &n, &v) == noErr ? v : nil
}
func setNominalRate(_ dev: AudioObjectID, _ r: Double) -> Bool {
    var a = addr(kAudioDevicePropertyNominalSampleRate), v = r
    return AudioObjectSetPropertyData(dev, &a, 0, nil, 8, &v) == noErr
}
func setBuffer(_ dev: AudioObjectID, _ frames: UInt32) { var a = addr(kAudioDevicePropertyBufferFrameSize), v = frames; AudioObjectSetPropertyData(dev, &a, 0, nil, 4, &v) }
func stringProp(_ dev: AudioObjectID, _ s: AudioObjectPropertySelector) -> String {
    var a = addr(s), ref: Unmanaged<CFString>?, n = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &n, &ref) == noErr, let ref else { return "?" }
    return ref.takeRetainedValue() as String
}
func outputChannels(_ dev: AudioObjectID) -> Int {
    var a = addr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput), n: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &n) == noErr, n > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(n), alignment: 16); defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &n, raw) == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
}
func allDevices() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyDevices), n: UInt32 = 0
    let sys = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &n) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(n) / 4)
    return AudioObjectGetPropertyData(sys, &a, 0, nil, &n, &ids) == noErr ? ids : []
}

struct Stats {
    let n: Int, mean: Double, min: Double, max: Double, sd: Double, p95: Double
    init(_ x: [Double]) {
        let count = x.count, sorted = x.sorted()
        let m = x.isEmpty ? 0 : x.reduce(0, +) / Double(count)
        n = count; mean = m
        min = sorted.first ?? 0; max = sorted.last ?? 0
        sd = count > 1 ? (x.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(count - 1)).squareRoot() : 0
        p95 = sorted.isEmpty ? 0 : sorted[Swift.min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
    }
    func line(_ unit: String) -> String { String(format: "mean %8.3f  min %8.3f  max %8.3f  sd %6.3f  p95 %8.3f %@  (n=%d)", mean, min, max, sd, p95, unit, n) }
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(2) }
args.removeFirst()
@MainActor func opt(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
@MainActor func flag(_ name: String) -> Bool { args.contains(name) }
let positional: [String] = { var out: [String] = [], skip = false
    for a in args { if skip { skip = false; continue }; if a.hasPrefix("--") { skip = !["--json"].contains(a); continue }; out.append(a) }
    return out }()

/// Runs an IOProc on `dev` for `seconds`, then tears it down.
func runIOProc(_ dev: AudioObjectID, _ proc: AudioDeviceIOProc, _ client: UnsafeMutableRawPointer, seconds: Double) {
    var id: AudioDeviceIOProcID?
    guard AudioDeviceCreateIOProcID(dev, proc, client, &id) == noErr, let id else { fail("could not create IOProc (is the device in use exclusively?)") }
    guard AudioDeviceStart(dev, id) == noErr else { AudioDeviceDestroyIOProcID(dev, id); fail("could not start the device") }
    Thread.sleep(forTimeInterval: seconds)
    AudioDeviceStop(dev, id); AudioDeviceDestroyIOProcID(dev, id)
}

// MARK: - Commands
switch command {
case "devices":
    for d in allDevices() {
        let uid = stringProp(d, kAudioDevicePropertyDeviceUID), name = stringProp(d, kAudioObjectPropertyName)
        print(String(format: "%-34@ in %2d out %2d  %6.0f Hz  %@", uid as NSString, DeviceDiscovery.inputChannelCount(deviceID: d), outputChannels(d), nominalRate(d) ?? 0, name as NSString))
    }

case "loopback":
    let uid = opt("--uid") ?? TapSession.defaultDeviceUID
    guard let dev = DeviceDiscovery.deviceID(forUID: uid) else { fail("device '\(uid)' not found. Install the Conduit driver, or pass --uid of another loopback device.") }
    guard DeviceDiscovery.inputChannelCount(deviceID: dev) > 0, outputChannels(dev) > 0 else { fail("device needs both input and output streams") }
    let seconds = Double(opt("--seconds") ?? "8") ?? 8, channel = UInt32(opt("--channel") ?? "0") ?? 0
    if let b = opt("--buffer").flatMap(UInt32.init) { setBuffer(dev, b) }
    guard let rate = nominalRate(dev), let buffer = getU32(dev, kAudioDevicePropertyBufferFrameSize) else { fail("cannot read device format") }
    let interval = UInt32(rate / 4)
    guard let bench = conduit_bench_create(channel, interval, UInt32(seconds * 4) + 8, 0.5, 1 / (rate * Timebase.secondsPerTick)) else { fail("alloc") }
    defer { conduit_bench_destroy(bench) }
    runIOProc(dev, conduit_bench_ioproc, UnsafeMutableRawPointer(bench), seconds: seconds)

    var offsets: [Double] = [], trip: [Double] = [], lead: [Double] = [], lag: [Double] = [], r = ConduitBenchRecord()
    let n = conduit_bench_completed(bench)
    for i in 0..<n where conduit_bench_record(bench, i, &r) {
        offsets.append(Double(r.detectSample - r.writeSample))
        trip.append(Double(Int64(bitPattern: r.detectCallbackHost &- r.writeCallbackHost)) * Timebase.secondsPerTick * 1000)
        lead.append(Double(Int64(bitPattern: r.writeSampleHost &- r.writeCallbackHost)) * Timebase.secondsPerTick * 1000)
        lag.append(Double(Int64(bitPattern: r.detectCallbackHost &- r.detectSampleHost)) * Timebase.secondsPerTick * 1000)
    }
    let scheduled = conduit_bench_scheduled(bench), lost = Int(scheduled) - Int(n)
    if flag("--json") {
        let d: [String: Any] = ["uid": uid, "rate": rate, "bufferFrames": buffer, "impulses": scheduled, "lost": lost,
                                "sampleOffsetFrames": ["mean": Stats(offsets).mean, "min": Stats(offsets).min, "max": Stats(offsets).max],
                                "roundTripMs": ["mean": Stats(trip).mean, "min": Stats(trip).min, "max": Stats(trip).max, "sd": Stats(trip).sd]]
        print(String(decoding: try! JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    } else {
        print("device \(uid)  \(Int(rate)) Hz  buffer \(buffer) frames (\(String(format: "%.2f", Double(buffer) / rate * 1000)) ms)")
        print("impulses \(scheduled)  returned \(n)  lost \(lost)")
        print("sample offset (frames)  \(Stats(offsets).line("frames"))   <- 0 means sample-accurate loopback")
        print("round trip, app write -> app read  \(Stats(trip).line("ms"))")
        print("  output lead (write ahead of play) \(Stats(lead).line("ms"))")
        print("  input lag   (capture to read)     \(Stats(lag).line("ms"))")
    }
    exit(lost == 0 && n > 0 ? 0 : 1)

case "clocks":
    guard (1...2).contains(positional.count) else { fail("clocks <uidA> [uidB]") }
    let seconds = Double(opt("--seconds") ?? "10") ?? 10
    var devs: [(uid: String, id: AudioObjectID, nominal: Double, probe: OpaquePointer)] = []
    for uid in positional {
        guard let d = DeviceDiscovery.deviceID(forUID: uid), let nom = nominalRate(d) else { fail("device '\(uid)' not found") }
        guard let p = conduit_clock_probe_create(1 << 17) else { fail("alloc") }
        devs.append((uid, d, nom, p))
    }
    // Start all devices on their own IOProcs, then let them run concurrently.
    var procs: [AudioDeviceIOProcID] = []
    for d in devs {
        var id: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcID(d.id, conduit_clock_probe_ioproc, UnsafeMutableRawPointer(d.probe), &id) == noErr, let id else { fail("IOProc failed for \(d.uid)") }
        procs.append(id)
    }
    for (d, p) in zip(devs, procs) { guard AudioDeviceStart(d.id, p) == noErr else { fail("could not start \(d.uid)") } }
    Thread.sleep(forTimeInterval: seconds)
    for (d, p) in zip(devs, procs) { AudioDeviceStop(d.id, p); AudioDeviceDestroyIOProcID(d.id, p) }

    var ppm: [Double] = []
    for d in devs {
        let n = conduit_clock_probe_count(d.probe)
        var xs = [Double](), ys = [Double](), h0: UInt64 = 0, s0 = 0.0, h = UInt64(0), s = 0.0
        for i in 0..<n where conduit_clock_probe_get(d.probe, i, &h, &s) {
            if xs.isEmpty { h0 = h; s0 = s }
            xs.append(Double(h &- h0) * Timebase.secondsPerTick); ys.append(s - s0)
        }
        guard xs.count > 10 else { fail("too few IO cycles from \(d.uid) (\(xs.count)); is the device running?") }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        var sxy = 0.0, sxx = 0.0
        for (x, y) in zip(xs, ys) { sxy += (x - mx) * (y - my); sxx += (x - mx) * (x - mx) }
        let measured = sxy / sxx, p = (measured / d.nominal - 1) * 1e6
        ppm.append(p)
        print(String(format: "%@  nominal %.0f Hz  measured %.3f Hz  (%+.1f ppm vs host clock)  %d IO cycles", d.uid, d.nominal, measured, p, xs.count))
        conduit_clock_probe_destroy(d.probe)
    }
    if ppm.count == 2 {
        let rel = ppm[0] - ppm[1]
        print(String(format: "relative drift %+.1f ppm", rel))
        if abs(rel) > 0.5 {
            let rate = devs[0].nominal
            print(String(format: "without drift compensation the injection path would re-align every ~%.0f s (48-frame tolerance at %.0f Hz); the aggregate device's drift compensation removes this.", 48 / (abs(rel) * 1e-6 * rate), rate))
        }
    }

case "rates":
    let uid = opt("--uid") ?? TapSession.defaultDeviceUID
    guard let dev = DeviceDiscovery.deviceID(forUID: uid) else { fail("device '\(uid)' not found") }
    let original = nominalRate(dev) ?? 48000
    var allOK = true
    for target in [44100.0, 48000.0, 96000.0] {
        guard setNominalRate(dev, target) else { print("\(Int(target)) Hz: set refused"); allOK = false; continue }
        var applied = false
        for _ in 0..<60 { if nominalRate(dev) == target { applied = true; break }; Thread.sleep(forTimeInterval: 0.05) }
        guard applied, let probe = conduit_clock_probe_create(1 << 16) else { print("\(Int(target)) Hz: not applied"); allOK = false; continue }
        var id: AudioDeviceIOProcID?
        AudioDeviceCreateIOProcID(dev, conduit_clock_probe_ioproc, UnsafeMutableRawPointer(probe), &id)
        AudioDeviceStart(dev, id); Thread.sleep(forTimeInterval: 1.5); AudioDeviceStop(dev, id); AudioDeviceDestroyIOProcID(dev, id!)
        let n = conduit_clock_probe_count(probe)
        var h0: UInt64 = 0, s0 = 0.0, h1: UInt64 = 0, s1 = 0.0
        _ = conduit_clock_probe_get(probe, 0, &h0, &s0); _ = conduit_clock_probe_get(probe, n - 1, &h1, &s1)
        let measured = (s1 - s0) / (Double(h1 &- h0) * Timebase.secondsPerTick), err = (measured / target - 1) * 1e6
        let ok = abs(err) < 1000
        allOK = allOK && ok
        print(String(format: "%6.0f Hz  measured %.2f Hz (%+.0f ppm)  %@", target, measured, err, ok ? "ok" : "FAIL"))
        conduit_clock_probe_destroy(probe)
    }
    _ = setNominalRate(dev, original)
    exit(allOK ? 0 : 1)

default:
    print(usage); exit(2)
}
