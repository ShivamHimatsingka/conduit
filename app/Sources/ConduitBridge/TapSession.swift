// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
import CConduit
import CoreAudio
import Foundation

public struct TapError: Error, CustomStringConvertible, Sendable {
    public let step: String
    public let status: OSStatus
    public var description: String {
        "\(step) failed: OSStatus \(status) \(fourCC(status))"
    }
    private func fourCC(_ s: OSStatus) -> String {
        let u = UInt32(bitPattern: s), b = [24, 16, 8, 0].map { UInt8((u >> $0) & 0xFF) }
        return b.allSatisfy { $0 >= 32 && $0 < 127 } ? "'\(String(decoding: b, as: UTF8.self))'" : ""
    }
}

/// Something that feeds audio into Conduit.
public enum SourceKind: Sendable {
    case app(AudioApp)                          // Process Tap on the app and all its helper processes
    case microphone(uid: String, name: String)  // hardware input added to the aggregate as a sub-device
}

public struct TapSource: Sendable {
    public var kind: SourceKind
    /// Send level (linear) into stereo pair p = device channels (2p, 2p+1). Missing pairs are off.
    public var sends: [Int: Float]
    public var mute: Bool
    public var mono: Bool
    /// Apps only: silence the app on its normal output while it is tapped.
    public var silenceOriginal: Bool

    public init(kind: SourceKind, sends: [Int: Float] = [0: 1], mute: Bool = false, mono: Bool = false, silenceOriginal: Bool = false) {
        self.kind = kind; self.sends = sends; self.mute = mute; self.mono = mono; self.silenceOriginal = silenceOriginal
    }
    public init(app: AudioApp, busFirst: Int = 0, gain: Float = 1, mute: Bool = false, mono: Bool = false, silenceOriginal: Bool = false) {
        self.init(kind: .app(app), sends: [busFirst / 2: gain], mute: mute, mono: mono, silenceOriginal: silenceOriginal)
    }
    public var displayName: String {
        switch kind { case .app(let a): return a.name; case .microphone(_, let n): return n }
    }
}

/// Owns the Process Taps, hardware inputs, the private aggregate device and the C IOProc.
///
///   apps ──► CATapDescription taps ─┐
///   microphones (sub-devices) ──────┼─► private aggregate ──► conduit_tap_ioproc (C, real-time)
///   Conduit device (clock master) ──┘                              │ per-source sends → stereo pairs
///                                                                  ▼
///                                                    injection ring ──► driver input stream
///
/// The Conduit device is the aggregate's clock master, so every IO cycle is driven by the same clock
/// as the driver's timeline (and starting the aggregate starts the driver); taps and microphones are
/// drift-compensated against it. Without a Conduit link the session runs in monitor-only mode,
/// clocked by the default output device, and only meters.
public final class TapSession: @unchecked Sendable {
    public static let defaultDeviceUID = "com.conduit.driver.device.16ch"

    public struct Stats: Sendable {
        public var cycles: UInt64, idleCycles: UInt64, resyncs: UInt64, shortCycles: UInt64, bufferFrames: UInt64
    }

    private let link: ConduitLink?
    private let deviceUID: String
    private let latencyFrames: UInt32
    private let bufferFrames: UInt32

    private var engine: OpaquePointer?
    private var taps: [AudioObjectID] = []
    private var aggregate: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    public private(set) var sources: [TapSource] = []

    /// - Parameters:
    ///   - link: connection to the driver; nil for monitor-only.
    ///   - latencyFrames: device-time offset between capture and injection; must be at least the IO buffer
    ///     (the driver has already read the current cycle). nil = bufferFrames + 64.
    ///   - bufferFrames: requested aggregate IO buffer size (smaller = lower latency, more CPU).
    public init(link: ConduitLink?, deviceUID: String = TapSession.defaultDeviceUID, latencyFrames: UInt32? = nil, bufferFrames: UInt32 = 64) {
        // The budget must be at least one IO buffer (otherwise audio is injected into slots the driver has already
        // read and is lost); one buffer + 64 frames of scheduling margin never loses audio. See `make test-bench`.
        self.link = link; self.deviceUID = deviceUID; self.bufferFrames = bufferFrames
        self.latencyFrames = latencyFrames ?? bufferFrames + 64
    }

    deinit { stop() }

    public var isRunning: Bool { procID != nil }
    public var isMonitorOnly: Bool { link == nil }

    public func start(sources newSources: [TapSource]) throws {
        stop()
        guard !newSources.isEmpty, newSources.count <= Int(CONDUIT_MAX_TAP_SOURCES) else {
            throw TapError(step: "source count (1...\(CONDUIT_MAX_TAP_SOURCES))", status: -50)
        }
        sources = newSources
        do { try build() } catch { stop(); throw error }
    }

    public func stop() {
        if let procID, aggregate != 0 {
            AudioDeviceStop(aggregate, procID)
            AudioDeviceDestroyIOProcID(aggregate, procID)
        }
        procID = nil
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        for t in taps { AudioHardwareDestroyProcessTap(t) }
        taps.removeAll()
        if let engine { conduit_tap_engine_destroy(engine) }  // IOProc is stopped: safe
        engine = nil
    }

    // MARK: Live control (no rebuild; levels ramp inside the IOProc)
    public func setSend(_ index: Int, pair: Int, gain: Float) {
        guard sources.indices.contains(index), (0..<Int(CONDUIT_MAX_PAIRS)).contains(pair) else { return }
        if gain == 0 { sources[index].sends[pair] = nil } else { sources[index].sends[pair] = gain }
        if let engine { conduit_tap_engine_set_send(engine, UInt32(index), UInt32(pair), gain) }
    }
    public func setFlags(_ index: Int, mute: Bool? = nil, mono: Bool? = nil) {
        guard sources.indices.contains(index) else { return }
        if let mute { sources[index].mute = mute }
        if let mono { sources[index].mono = mono }
        if let engine { conduit_tap_engine_set_flags(engine, UInt32(index), sources[index].mute, sources[index].mono) }
    }

    /// Max-hold peak (linear, pre-fader) since the last call.
    public func takePeak(_ index: Int) -> Float { engine.map { conduit_tap_engine_take_peak($0, UInt32(index)) } ?? 0 }

    /// Latest `frames` mono samples of a source (pre-fader), for RMS and spectrum analysis.
    /// Returns false until enough audio has flowed. Allocation-free if `buffer` is already sized.
    public func latestSamples(_ index: Int, frames: Int, into buffer: inout [Float]) -> Bool {
        guard let engine, sources.indices.contains(index) else { return false }
        if buffer.count != frames { buffer = [Float](repeating: 0, count: frames) }
        return buffer.withUnsafeMutableBufferPointer { conduit_tap_engine_latest(engine, UInt32(index), $0.baseAddress!, UInt32(frames)) }
    }

    public var sampleRate: Double { link?.clock()?.sampleRate ?? 48000 }

    public var stats: Stats? {
        guard let e = engine else { return nil }
        func s(_ w: ConduitTapStat) -> UInt64 { conduit_tap_engine_stat(e, w) }
        return Stats(cycles: s(CONDUIT_STAT_CYCLES), idleCycles: s(CONDUIT_STAT_IDLE), resyncs: s(CONDUIT_STAT_RESYNCS),
                     shortCycles: s(CONDUIT_STAT_SHORT), bufferFrames: s(CONDUIT_STAT_LAST_FRAMES))
    }

    // MARK: Construction
    private func build() throws {
        let created: OpaquePointer? = link.map { conduit_tap_engine_create($0.rawShared, $0.rawRing) } ?? conduit_tap_engine_create(nil, nil)
        guard let eng = created else { throw TapError(step: "engine alloc", status: -108) }
        engine = eng
        conduit_tap_engine_set_latency(eng, latencyFrames)

        // Clock master first: its input streams occupy the first aggregate buffers.
        let clockUID = try link != nil ? deviceUID : Self.defaultOutputUID()
        var subDevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: clockUID]]
        var nextHardwareBuffer = DeviceDiscovery.deviceID(forUID: clockUID).map(DeviceDiscovery.inputStreamCount) ?? 1

        var tapEntries: [[String: Any]] = []
        var tapOrdinal = 0
        for (i, src) in sources.enumerated() {
            switch src.kind {
            case .app(let app):
                guard !app.processObjectIDs.isEmpty else { throw TapError(step: "\(app.name) has no Core Audio process yet", status: -50) }
                let desc = CATapDescription(stereoMixdownOfProcesses: app.processObjectIDs)
                desc.name = "Conduit tap: \(app.name)"
                desc.isPrivate = true
                desc.muteBehavior = src.silenceOriginal ? CATapMuteBehavior.muted : CATapMuteBehavior.unmuted
                var tapID = AudioObjectID(kAudioObjectUnknown)
                let st = AudioHardwareCreateProcessTap(desc, &tapID)
                guard st == noErr else { throw TapError(step: "AudioHardwareCreateProcessTap(\(app.name))", status: st) }
                taps.append(tapID)
                tapEntries.append([kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true])
                conduit_tap_engine_set_source(eng, UInt32(i), CONDUIT_SOURCE_TAP, UInt32(tapOrdinal))
                tapOrdinal += 1
            case .microphone(let uid, let name):
                guard let dev = DeviceDiscovery.deviceID(forUID: uid), DeviceDiscovery.inputStreamCount(deviceID: dev) > 0 else {
                    throw TapError(step: "microphone '\(name)' is not available", status: -50)
                }
                subDevices.append([kAudioSubDeviceUIDKey: uid, kAudioSubDeviceDriftCompensationKey: true])
                conduit_tap_engine_set_source(eng, UInt32(i), CONDUIT_SOURCE_HARDWARE, UInt32(nextHardwareBuffer))
                nextHardwareBuffer += DeviceDiscovery.inputStreamCount(deviceID: dev)
            }
            conduit_tap_engine_set_flags(eng, UInt32(i), src.mute, src.mono)
            for (pair, gain) in src.sends { conduit_tap_engine_set_send(eng, UInt32(i), UInt32(pair), gain) }
        }
        conduit_tap_engine_configure(eng, UInt32(sources.count), UInt32(tapOrdinal))

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Conduit Capture",
            kAudioAggregateDeviceUIDKey: "com.conduit.capture.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: tapEntries,
        ]
        var st = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard st == noErr else { aggregate = 0; throw TapError(step: "AudioHardwareCreateAggregateDevice", status: st) }

        var frames = bufferFrames
        var bufAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(aggregate, &bufAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)

        st = AudioDeviceCreateIOProcID(aggregate, conduit_tap_ioproc, UnsafeMutableRawPointer(eng), &procID)
        guard st == noErr else { procID = nil; throw TapError(step: "AudioDeviceCreateIOProcID", status: st) }
        st = AudioDeviceStart(aggregate, procID)
        guard st == noErr else {
            AudioDeviceDestroyIOProcID(aggregate, procID!); procID = nil
            throw TapError(step: "AudioDeviceStart", status: st)
        }
    }

    private static func defaultOutputUID() throws -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
        var st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        guard st == noErr, dev != kAudioObjectUnknown else { throw TapError(step: "default output device", status: st) }
        addr.mSelector = kAudioDevicePropertyDeviceUID
        var ref: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        st = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &ref)
        guard st == noErr, let ref else { throw TapError(step: "default output UID", status: st) }
        return ref.takeRetainedValue() as String
    }
}
