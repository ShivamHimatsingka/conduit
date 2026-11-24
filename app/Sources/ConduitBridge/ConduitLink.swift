// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
import CConduit
import Darwin

public struct ConduitError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public var description: String {
        switch code {
        case 1001: return "Conduit driver not found (is it installed and is coreaudiod running?)"
        case 1002: return "unexpected reply from driver"
        case 1003: return "driver protocol version mismatch"
        case 1004: return "the audio driver refused the connection (it is an older version that rejects this user after a reboot). Update the driver."
        default: return "Mach error \(code)"
        }
    }
}

public struct MeterLevel: Sendable, Equatable {
    public var peak: Float = 0   // linear, max-hold since the previous read
    public var rms: Float = 0    // linear, last audio block
    public init() {}
    public var peakDB: Float { ConduitLink.linearToDB(peak) }
    public var rmsDB: Float { ConduitLink.linearToDB(rms) }
}

public struct ClockSnapshot: Sendable {
    public let sampleRate: Double
    public let running: Bool
    public let seed: UInt64
    fileprivate let raw: ConduitClockSnapshot
    /// Device sample time corresponding to a `mach_absolute_time()` value.
    public func sampleTime(atHost host: UInt64) -> Int64 {
        var r = raw
        return conduit_clock_sample_at(&r, host)
    }
}

/// Typed, allocation-free view of the shared control block, telemetry and
/// injection ring. Every call is a handful of relaxed atomic operations, so
/// the UI can poll at 60 fps and the audio thread can call `writeInjection`.
public final class ConduitLink: @unchecked Sendable {
    public static let defaultService = "com.conduit.driver.ipc"

    private var connection = ConduitConnection()
    private let ring: UnsafeMutablePointer<ConduitRing>
    private let shared: OpaquePointer  // ConduitShared* (over-aligned, so opaque to Swift)
    public let channels: Int

    /// For the capture engine only: the mapped control region and the injection ring.
    var rawShared: OpaquePointer { shared }
    var rawRing: UnsafeMutablePointer<ConduitRing> { ring }

    public init(service: String = ConduitLink.defaultService) throws {
        var c = ConduitConnection()
        let rc = conduit_connect(service, &c)
        guard rc == 0, let s = c.shared else { throw ConduitError(code: rc == 0 ? 1002 : rc) }
        connection = c
        shared = s
        ring = .allocate(capacity: 1)
        ring.initialize(to: c.appRing)
        channels = Int(conduit_channels(s))
    }

    deinit {
        ring.deallocate()
        conduit_disconnect(&connection)
    }

    /// Identity of the driver instance this link is mapped to (0 if the driver predates the field).
    public var instanceID: UInt64 { conduit_instance_id(shared) }

    /// Cheap probe used to detect a restarted driver: connects, reads the instance id, disconnects.
    /// Returns nil if the driver cannot be reached.
    public static func probeInstanceID(service: String = ConduitLink.defaultService) -> UInt64? {
        var c = ConduitConnection()
        guard conduit_connect(service, &c) == 0, let s = c.shared else { return nil }
        defer { conduit_disconnect(&c) }
        return conduit_instance_id(s)
    }

    // MARK: Units
    public static func dbToLinear(_ db: Float) -> Float { db <= -120 ? 0 : powf(10, db / 20) }
    public static func linearToDB(_ x: Float) -> Float { x <= 1e-6 ? -120 : 20 * log10f(x) }

    // MARK: Control plane (app -> driver)
    public func inputGain(_ ch: Int) -> Float { conduit_get_in_gain(shared, UInt32(ch)) }
    public func busGain(_ ch: Int) -> Float { conduit_get_bus_gain(shared, UInt32(ch)) }
    public func crosspoint(bus: Int, input: Int) -> Float { conduit_get_matrix(shared, UInt32(bus), UInt32(input)) }
    @discardableResult public func setInputGain(_ ch: Int, _ g: Float) -> Bool { conduit_set_in_gain(shared, UInt32(ch), g) }
    @discardableResult public func setBusGain(_ ch: Int, _ g: Float) -> Bool { conduit_set_bus_gain(shared, UInt32(ch), g) }
    @discardableResult public func setCrosspoint(bus: Int, input: Int, gain: Float) -> Bool { conduit_set_matrix(shared, UInt32(bus), UInt32(input), gain) }
    @discardableResult public func setMute(_ ch: Int, _ on: Bool) -> Bool { conduit_set_mute(shared, UInt32(ch), on) }
    @discardableResult public func setSolo(_ ch: Int, _ on: Bool) -> Bool { conduit_set_solo(shared, UInt32(ch), on) }
    @discardableResult public func setBusMute(_ ch: Int, _ on: Bool) -> Bool { conduit_set_bus_mute(shared, UInt32(ch), on) }
    public var muteMask: UInt64 { conduit_mute_mask(shared) }
    public var soloMask: UInt64 { conduit_solo_mask(shared) }
    public var busMuteMask: UInt64 { conduit_bus_mute_mask(shared) }

    /// Restore unity gains, identity routing, nothing muted or soloed.
    public func resetRouting() {
        for ch in 0..<channels {
            setInputGain(ch, 1); setBusGain(ch, 1); setMute(ch, false); setSolo(ch, false); setBusMute(ch, false)
            for bus in 0..<channels { setCrosspoint(bus: bus, input: ch, gain: bus == ch ? 1 : 0) }
        }
    }

    // MARK: Telemetry (driver -> app)
    /// Fills the arrays (resized to `channels`). Peaks are max-hold and are reset by this call.
    public func readMeters(inputs: inout [MeterLevel], buses: inout [MeterLevel]) {
        if inputs.count != channels { inputs = Array(repeating: MeterLevel(), count: channels) }
        if buses.count != channels { buses = Array(repeating: MeterLevel(), count: channels) }
        for ch in 0..<channels {
            let c = UInt32(ch)
            inputs[ch].peak = conduit_take_in_peak(shared, c)
            inputs[ch].rms = sqrtf(conduit_in_msq(shared, c))
            buses[ch].peak = conduit_take_bus_peak(shared, c)
            buses[ch].rms = sqrtf(conduit_bus_msq(shared, c))
        }
    }
    public var blockCount: UInt64 { conduit_block_count(shared) }

    // MARK: Clock + injection ring
    public func clock() -> ClockSnapshot? {
        var snap = ConduitClockSnapshot()
        guard conduit_clock_read(shared, &snap) else { return nil }
        return ClockSnapshot(sampleRate: Double(snap.sampleRate), running: snap.running, seed: snap.seed, raw: snap)
    }

    /// Real-time safe. Writes interleaved `channels`-wide frames at device sample time `startFrame`;
    /// the driver mixes them into the device's input stream.
    public func writeInjection(startFrame: Int64, frames: Int, samples: UnsafePointer<Float>) {
        conduit_ring_write(ring, startFrame, UInt32(frames), samples)
    }
    public var injectionUnderruns: UInt64 { conduit_ring_underruns(ring) }
    public var injectionGaps: UInt64 { conduit_ring_gaps(ring) }
}
