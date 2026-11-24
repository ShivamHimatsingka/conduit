// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
//
// conduitctl: command-line control and telemetry for the Conduit driver.
import ConduitBridge
import Darwin
import Foundation

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("conduitctl: \(msg)\n".utf8))
    exit(1)
}

let usage = """
usage: conduitctl [--service NAME] <command>
  info                          channel count, clock, driver activity
  meters [seconds]              print peak/RMS for every input strip and output bus
  gain in|bus <ch> <dB>         set strip or bus gain
  mute|solo|busmute <ch> on|off
  route <bus> <in> <linear>     set one crosspoint of the matrix
  matrix                        print non-zero crosspoints
  reset                         unity gains, identity routing
  tone <ch> <seconds> [Hz] [amp]  inject a sine into device input channel <ch>
  apps                          list Core Audio client apps (bundle id, name, pid, playing)
  tap <app> <seconds> [--bus N] [--gain dB] [--silence] [--mono] [--monitor]
                                capture one app (bundle id, name or pid) into device channels N, N+1.
                                --monitor: meter only (no Conduit driver needed); --silence mutes the
                                app on its normal output while tapped.
"""

var args = Array(CommandLine.arguments.dropFirst())
var service = ConduitLink.defaultService
if args.first == "--service", args.count >= 2 { service = args[1]; args.removeFirst(2) }
guard let command = args.first else { print(usage); exit(2) }
args.removeFirst()

// Commands that work without a driver connection.
if command == "apps" {
    for app in ProcessDiscovery.apps() {
        print("\(app.bundleID)\t\(app.name)\tpid \(app.pid)\tprocesses \(app.processObjectIDs.count)\t\(app.isProducingAudio ? "playing" : "idle")")
    }
    exit(0)
}
if command == "tap" {
    guard args.count >= 2, let seconds = Double(args[1]), seconds > 0 else { fail("tap <app> <seconds> [options]") }
    guard let app = ProcessDiscovery.app(matching: args[0]) else { fail("no Core Audio app matches '\(args[0])' (see: conduitctl apps)") }
    func opt(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    let bus = Int(opt("--bus") ?? "0") ?? 0
    let gain = ConduitLink.dbToLinear(Float(opt("--gain") ?? "0") ?? 0)
    let monitorOnly = args.contains("--monitor")
    let link = monitorOnly ? nil : try? ConduitLink(service: service)
    if link == nil && !monitorOnly { print("note: Conduit driver not reachable, running in monitor-only mode") }
    let session = TapSession(link: link, latencyFrames: opt("--latency").flatMap { UInt32($0) },
                             bufferFrames: UInt32(opt("--buffer") ?? "64") ?? 64)
    do {
        try session.start(sources: [TapSource(app: app, busFirst: bus, gain: gain, mono: args.contains("--mono"),
                                              silenceOriginal: args.contains("--silence"))])
    } catch { fail("\(error)") }
    print("tapping \(app.name) (\(app.bundleID), \(app.processObjectIDs.count) process(es)) -> " + (link == nil ? "meter only" : "device channels \(bus),\(bus + 1)"))
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        usleep(500_000)
        let st = session.stats
        print("peak \(f3(session.takePeak(0)))  cycles \(st?.cycles ?? 0) idle \(st?.idleCycles ?? 0) resync \(st?.resyncs ?? 0) buf \(st?.bufferFrames ?? 0)")
    }
    session.stop()
    exit(0)
}

let link: ConduitLink
do { link = try ConduitLink(service: service) } catch { fail("\(error)") }

@MainActor func intArg(_ i: Int, _ name: String) -> Int {
    guard i < args.count, let v = Int(args[i]), v >= 0, v < link.channels else { fail("\(name) must be 0..<\(link.channels)") }
    return v
}
@MainActor func floatArg(_ i: Int, _ name: String) -> Float {
    guard i < args.count, let v = Float(args[i]) else { fail("\(name) must be a number") }
    return v
}
@MainActor func onOff(_ i: Int) -> Bool {
    guard i < args.count, ["on", "off"].contains(args[i]) else { fail("expected on|off") }
    return args[i] == "on"
}
func f3(_ v: Float) -> String { String(format: "%.3f", v) }

switch command {
case "info":
    print("channels \(link.channels)")
    if let c = link.clock() { print("clock rate \(Int(c.sampleRate)) running \(c.running) seed \(c.seed)") }
    print("blocks \(link.blockCount)")
    print("instance \(String(link.instanceID, radix: 16))")
    print("mute \(String(link.muteMask, radix: 2)) solo \(String(link.soloMask, radix: 2)) busmute \(String(link.busMuteMask, radix: 2))")

case "meters":
    let seconds = args.isEmpty ? 1.0 : Double(args[0]) ?? 1.0
    var ins: [MeterLevel] = [], buses: [MeterLevel] = []
    link.readMeters(inputs: &ins, buses: &buses)  // discard stale max-hold
    usleep(UInt32(seconds * 1_000_000))
    link.readMeters(inputs: &ins, buses: &buses)
    for ch in 0..<link.channels { print("in \(ch) peak \(f3(ins[ch].peak)) rms \(f3(ins[ch].rms))") }
    for ch in 0..<link.channels { print("bus \(ch) peak \(f3(buses[ch].peak)) rms \(f3(buses[ch].rms))") }

case "gain":
    guard args.count == 3, ["in", "bus"].contains(args[0]) else { fail("gain in|bus <ch> <dB>") }
    let ch = intArg(1, "channel"), g = ConduitLink.dbToLinear(floatArg(2, "dB"))
    if args[0] == "in" { link.setInputGain(ch, g) } else { link.setBusGain(ch, g) }

case "mute": link.setMute(intArg(0, "channel"), onOff(1))
case "solo": link.setSolo(intArg(0, "channel"), onOff(1))
case "busmute": link.setBusMute(intArg(0, "channel"), onOff(1))
case "route": link.setCrosspoint(bus: intArg(0, "bus"), input: intArg(1, "input"), gain: floatArg(2, "gain"))
case "reset": link.resetRouting()

case "matrix":
    for bus in 0..<link.channels { for i in 0..<link.channels {
        let g = link.crosspoint(bus: bus, input: i)
        if g != 0 { print("bus \(bus) <- in \(i) : \(f3(g))") }
    } }

case "tone":
    let ch = intArg(0, "channel")
    let seconds = args.count > 1 ? Double(args[1]) ?? 2 : 2
    let freq = args.count > 2 ? Double(args[2]) ?? 1000 : 1000
    let amp = args.count > 3 ? Float(args[3]) ?? 0.5 : 0.5
    let block = 256, lead: Int64 = 3072
    var buf = [Float](repeating: 0, count: block * link.channels)
    var next: Int64? = nil, seed: UInt64 = 0, phase = 0.0
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        guard let clk = link.clock(), clk.running else { usleep(5_000); next = nil; continue }
        let nowSample = clk.sampleTime(atHost: mach_absolute_time())
        if next == nil || clk.seed != seed { next = nowSample + 1024; seed = clk.seed }  // (re)sync after a driver restart
        let step = 2 * Double.pi * freq / clk.sampleRate
        while next! < nowSample + lead {
            for f in 0..<block {
                for c in 0..<link.channels { buf[f * link.channels + c] = 0 }
                buf[f * link.channels + ch] = amp * Float(sin(phase))
                phase += step
            }
            buf.withUnsafeBufferPointer { link.writeInjection(startFrame: next!, frames: block, samples: $0.baseAddress!) }
            next! += Int64(block)
        }
        usleep(2_000)
    }

default:
    print(usage); exit(2)
}
