// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Shivam Himatsingka
//
// Level math and spectrum analysis on Accelerate (vDSP). All batch operations
// run on whole arrays, so per-frame cost is a handful of vector calls.
import Accelerate
import Foundation

enum MeterMath {
    static let floorDB: Float = -72

    /// Linear amplitudes -> dBFS, clamped to [floorDB, 0], for a whole array at once.
    static func dBFS(_ linear: [Float]) -> [Float] {
        guard !linear.isEmpty else { return [] }
        var out = [Float](repeating: floorDB, count: linear.count)
        var ref: Float = 1, lo = floorDB, hi: Float = 0
        let n = vDSP_Length(linear.count)
        vDSP_vdbcon(linear, 1, &ref, &out, 1, n, 1)   // 20*log10(x/ref)
        vDSP_vclip(out, 1, &lo, &hi, &out, 1, n)
        return out
    }

    static func rms(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        var r: Float = 0
        vDSP_rmsqv(x, 1, &r, vDSP_Length(x.count))
        return r
    }

    static func peak(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        var p: Float = 0
        vDSP_maxmgv(x, 1, &p, vDSP_Length(x.count))
        return p
    }

    /// dB -> 0...1 meter position.
    static func position(_ db: Float) -> Float { max(0, min(1, (db - floorDB) / -floorDB)) }
}

/// Smoothed level with peak hold. Attack is instant, release falls at a fixed dB/s.
struct LevelState: Equatable {
    var peakDB: Float = MeterMath.floorDB
    var rmsDB: Float = MeterMath.floorDB
    var holdDB: Float = MeterMath.floorDB
    var holdAge: Float = 0

    static let fallDBPerSecond: Float = 42
    /// Set from Settings. (Only touched on the main thread.)
    nonisolated(unsafe) static var holdSeconds: Float = 1.3

    mutating func update(peakDB newPeak: Float, rmsDB newRMS: Float, dt: Float) {
        let fall = Self.fallDBPerSecond * dt
        peakDB = max(newPeak, peakDB - fall)
        rmsDB = max(newRMS, rmsDB - fall)
        if Self.holdSeconds <= 0 { holdDB = newPeak; holdAge = 0; return }                // peak hold off
        if newPeak >= holdDB { holdDB = newPeak; holdAge = 0 }
        else {
            holdAge += dt
            if holdAge > Self.holdSeconds { holdDB = max(newPeak, holdDB - fall) }
        }
    }
}

/// Real FFT spectrum on vDSP: Hann window -> zrip FFT -> power -> dB -> log-spaced bands.
@MainActor
final class SpectrumAnalyzer {
    let size = 2048
    let bandCount = 32
    private let log2n: vDSP_Length = 11
    nonisolated(unsafe) private let setup: FFTSetup
    private var window: [Float]
    private var windowed: [Float]
    nonisolated(unsafe) private let realp: UnsafeMutablePointer<Float>
    nonisolated(unsafe) private let imagp: UnsafeMutablePointer<Float>
    private var power: [Float]
    private var db: [Float]
    private var bands: [Float]
    private var edges: [(Int, Int)] = []   // FFT bin ranges per band
    private var configuredRate: Double = 0

    /// Dividing |X| by this makes a full-scale sine read ~0 dBFS (coherent gain of the window included).
    private let normalisation: Float

    init() {
        let n = size
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        windowed = [Float](repeating: 0, count: n)
        realp = .allocate(capacity: n / 2); realp.initialize(repeating: 0, count: n / 2)
        imagp = .allocate(capacity: n / 2); imagp.initialize(repeating: 0, count: n / 2)
        power = [Float](repeating: 0, count: n / 2)
        db = [Float](repeating: MeterMath.floorDB, count: n / 2)
        bands = [Float](repeating: 0, count: 32)
        // vDSP_fft_zrip output is 2x the DFT, and a sine of amplitude A has |DFT| = A * sum(window) / 2,
        // so |zrip| = A * sum(window): dividing by sum(window) makes a full-scale sine read 0 dBFS.
        normalisation = Float(window.reduce(0, +))
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        realp.deallocate(); imagp.deallocate()
    }

    private func configureBands(sampleRate: Double) {
        guard sampleRate != configuredRate else { return }
        configuredRate = sampleRate
        let binHz = sampleRate / Double(size), lo = 40.0, hi = min(16_000.0, sampleRate / 2 * 0.95)
        edges = (0..<bandCount).map { b in
            let f0 = lo * pow(hi / lo, Double(b) / Double(bandCount)), f1 = lo * pow(hi / lo, Double(b + 1) / Double(bandCount))
            let i0 = max(1, Int((f0 / binHz).rounded(.down))), i1 = max(i0, min(size / 2 - 1, Int((f1 / binHz).rounded(.up))))
            return (i0, i1)
        }
    }

    /// `samples.count` must equal `size`. Returns `bandCount` values in 0...1 (-72...0 dBFS), smoothed.
    func analyze(_ samples: [Float], sampleRate: Double, dt: Float) -> [Float] {
        precondition(samples.count == size)
        configureBands(sampleRate: sampleRate)

        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(size))
        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        windowed.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
            }
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(size / 2))

        // power -> amplitude -> dBFS:  10*log10(P) - 20*log10(norm)
        var ref = normalisation * normalisation, lo = MeterMath.floorDB, hi: Float = 0
        vDSP_vdbcon(power, 1, &ref, &db, 1, vDSP_Length(size / 2), 0)
        vDSP_vclip(db, 1, &lo, &hi, &db, 1, vDSP_Length(size / 2))

        let fall = LevelState.fallDBPerSecond * dt / -MeterMath.floorDB
        for (b, e) in edges.enumerated() {
            var m = MeterMath.floorDB
            vDSP_maxv(Array(db[e.0...e.1]), 1, &m, vDSP_Length(e.1 - e.0 + 1))
            let pos = MeterMath.position(m)
            bands[b] = max(pos, bands[b] - fall)
        }
        return bands
    }

    func reset() { for i in bands.indices { bands[i] = 0 } }
}
