import Foundation
import Accelerate

struct AnalyzerOptions {
    var bandCount: Int
    var sensitivityDb: Float
    var autoLevel: Bool
    /// One mid spectrum (bandCount bands).
    var mono: Bool = true
    /// Separate left/right spectra (bandCount / 2 bands each).
    var stereo: Bool = false
    /// Keep a triggered waveform for the Scope style.
    var scope: Bool = false
    /// Extra gain for low / mid / high frequencies in dB (applied after auto level, so it really boosts).
    var lowGainDb: Float = 0
    var midGainDb: Float = 0
    var highGainDb: Float = 0

    /// The Low/Mid/High gain at a frequency, blended smoothly between ranges on a log scale
    /// (low below 150 Hz, mid 400 Hz-2.5 kHz, high above 6 kHz).
    func rangeGain(hz: Float) -> Float {
        func blend(_ a: Float, _ b: Float, from lo: Float, to hi: Float) -> Float {
            let t = min(1, max(0, (log2(max(hz, 1)) - log2(lo)) / (log2(hi) - log2(lo))))
            return a + (b - a) * t
        }
        return hz < 1000 ? blend(lowGainDb, midGainDb, from: 150, to: 400)
                         : blend(midGainDb, highGainDb, from: 2500, to: 6000)
    }
}

/// Smoothed bar heights (0...1) with falling peak caps for one signal,
/// plus the "pulse" values used by the background-color style.
final class BandSet {
    private(set) var levels: [Float] = []
    private(set) var peaks: [Float] = []
    /// Overall intensity for the Pulse style, 0...1.
    private(set) var pulse: Float = 0
    /// Where the energy sits, 0 = bassy ... 1 = bright. Changes slowly.
    private(set) var tone: Float = 0.5
    /// How hard the latest bass hit was (0 = none). Drives Sparks.
    private(set) var kick: Float = 0

    fileprivate var db: [Float] = []
    fileprivate var targets: [Float] = []
    private var peakHold: [Float] = []
    private var peakSpeed: [Float] = []
    private var bassAverage: Float = 0
    private var centroidAverage: Float = 0.5

    var count: Int { levels.count }

    var isAtRest: Bool {
        pulse < 0.002 && !levels.contains { $0 > 0.002 } && !peaks.contains { $0 > 0.002 }
    }

    fileprivate func reset(count: Int) {
        guard count != levels.count else { return }
        levels = Array(repeating: 0, count: count)
        peaks = levels
        db = Array(repeating: -200, count: count)
        targets = levels
        peakHold = levels
        peakSpeed = levels
    }

    fileprivate func silence() {
        for i in targets.indices { targets[i] = 0 }
    }

    fileprivate func update(dt: Float) {
        let attack = 1 - pow(0.35, dt * 60) // quick rise
        let fall = 1.7 * dt                  // steady GEQ-style fall
        for i in levels.indices {
            let target = targets[i]
            if target > levels[i] {
                levels[i] += (target - levels[i]) * attack
            } else {
                levels[i] = max(target, levels[i] - fall)
            }

            // Peak caps: hold briefly, then drop with gravity.
            if levels[i] >= peaks[i] {
                peaks[i] = levels[i]
                peakHold[i] = 0.6
                peakSpeed[i] = 0
            } else if peakHold[i] > 0 {
                peakHold[i] -= dt
            } else {
                peakSpeed[i] += 2.4 * dt
                peaks[i] = max(levels[i], peaks[i] - peakSpeed[i] * dt)
            }
        }
        updatePulse(dt: dt)
    }

    /// Pulse = a dim base from overall loudness + bass + a kick on every bass hit.
    /// Tone follows changes in the sound: bass hits push it down, bright sounds push it up.
    private func updatePulse(dt: Float) {
        let n = levels.count
        guard n > 0 else { return }
        let bassCount = max(1, n / 6)
        var bass: Float = 0, overall: Float = 0, weighted: Float = 0
        for i in 0..<n {
            overall += levels[i]
            weighted += levels[i] * Float(i)
            if i < bassCount { bass += levels[i] }
        }
        bass /= Float(bassCount)
        let mean = overall / Float(n)

        bassAverage += (bass - bassAverage) * (1 - pow(0.96, dt * 60))
        let hit = max(0, bass - bassAverage)
        kick = hit
        let target = mean < 0.01 ? 0 : min(1, 0.35 * pow(mean, 1.3) + 0.3 * bass + 1.6 * hit)

        let rate: Float = target > pulse ? 1 - pow(0.3, dt * 60) : 1 - pow(0.88, dt * 60)
        pulse += (target - pulse) * rate

        if overall > 0.05, n > 1 {
            let centroid = weighted / overall / Float(n - 1)
            centroidAverage += (centroid - centroidAverage) * (1 - pow(0.996, dt * 60))
            let toneTarget = min(1, max(0, 0.5 + (centroid - centroidAverage) * 8))
            tone += (toneTarget - tone) * (1 - pow(0.93, dt * 60))
        }
    }
}

/// Turns the latest audio window into bars, stereo VU levels and pulse values.
final class SpectrumAnalyzer {
    static let fftSize = 4096

    // Tuning. Checked against real music so bars fill the menu bar and loud beats reach the top.
    private static let rangeDb: Float = 34         // dB shown from the bottom to the top of a bar
    private static let headroomDb: Float = -2      // auto level: bar top relative to the loudest band (below it, so beats hit the top)
    private static let tiltDbPerOctave: Float = 3  // lifts highs so typical music reads level across the bars
    private static let meterRangeDb: Float = 16    // VU meter span
    private static let meterWindow = 2048          // samples per VU reading (~43 ms)

    let mid = BandSet()
    let left = BandSet()
    let right = BandSet()

    /// Stereo VU meter, 0...1, with falling peak markers.
    private(set) var meterLeft: Float = 0
    private(set) var meterRight: Float = 0
    private(set) var meterPeakLeft: Float = 0
    private(set) var meterPeakRight: Float = 0
    /// Loudness of the latest window (louder channel), used to tell "silent" from "playing".
    private(set) var rms: Float = 0

    var isAtRest: Bool {
        mid.isAtRest && left.isAtRest && right.isAtRest && meterPeakLeft < 0.002 && meterPeakRight < 0.002
            && scopeLevel < 0.002
    }

    /// Scope waveform: mid, left, right, `scopePoints` each, scaled to -1...1.
    static let scopePoints = 320
    private(set) var scope = [Float](repeating: 0, count: SpectrumAnalyzer.scopePoints * 3)
    /// Fades the scope line in with sound and out in silence.
    private(set) var scopeLevel: Float = 0
    private var scopePeak: Float = 0.1

    private let n = SpectrumAnalyzer.fftSize
    private let half = SpectrumAnalyzer.fftSize / 2
    private let log2n = vDSP_Length(12)
    private let setup: FFTSetup

    // Scratch buffers (allocated once, reused every frame).
    private let window: UnsafeMutablePointer<Float>
    private let bufferL: UnsafeMutablePointer<Float>
    private let bufferR: UnsafeMutablePointer<Float>
    private let bufferMid: UnsafeMutablePointer<Float>
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>
    private let mags: UnsafeMutablePointer<Float>

    private struct Band {
        let lo: Float      // edges and center in FFT-bin units
        let hi: Float
        let center: Float
        let tiltDb: Float
        let hz: Float
    }

    private var bandCache: [Int: [Band]] = [:]
    private var cachedRate = 0.0
    private var reference: Float = -30
    private var meterReference: Float = -20
    private var meterHold: (Float, Float) = (0, 0)
    private var meterSpeed: (Float, Float) = (0, 0)

    init() {
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = .allocate(capacity: n)
        bufferL = .allocate(capacity: n)
        bufferR = .allocate(capacity: n)
        bufferMid = .allocate(capacity: n)
        realp = .allocate(capacity: half)
        imagp = .allocate(capacity: half)
        mags = .allocate(capacity: half)
        vDSP_hann_window(window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        [window, bufferL, bufferR, bufferMid, realp, imagp, mags].forEach { $0.deallocate() }
    }

    private func bands(count: Int, sampleRate: Double) -> [Band] {
        if sampleRate != cachedRate {
            bandCache.removeAll()
            cachedRate = sampleRate
        }
        if let cached = bandCache[count] { return cached }
        let binHz = Float(sampleRate) / Float(n)
        let fMin: Float = 32
        let fMax: Float = min(16_000, Float(sampleRate) * 0.45)
        let made = (0..<count).map { i -> Band in
            let lo = fMin * pow(fMax / fMin, Float(i) / Float(count))
            let hi = fMin * pow(fMax / fMin, Float(i + 1) / Float(count))
            let center = (lo * hi).squareRoot()
            return Band(lo: lo / binHz, hi: hi / binHz, center: center / binHz,
                        tiltDb: Self.tiltDbPerOctave * log2(center / 1000), hz: center)
        }
        bandCache[count] = made
        return made
    }

    /// Pass `ring: nil` when no fresh audio is arriving; everything then simply falls.
    func process(ring: SampleRingBuffer?, sampleRate: Double, dt: Float, options: AnalyzerOptions) {
        let stereoCount = max(4, options.bandCount / 2)
        mid.reset(count: options.bandCount)
        left.reset(count: stereoCount)
        right.reset(count: stereoCount)

        var meterTargets: (Float, Float) = (0, 0)
        if let ring {
            ring.readLatest(n, left: bufferL, right: bufferR)
            meterTargets = meterLevels(options: options, dt: dt)
            updateScope(active: options.scope, dt: dt, options: options)
            // Nothing playing and everything already settled: skip the FFTs entirely.
            if rms < 1e-5 && isAtRest { return }

            // Mid has to be made before the left/right buffers get windowed in place.
            if options.mono {
                var halfGain: Float = 0.5
                vDSP_vadd(bufferL, 1, bufferR, 1, bufferMid, 1, vDSP_Length(n))
                vDSP_vsmul(bufferMid, 1, &halfGain, bufferMid, 1, vDSP_Length(n))
            }
            var loudest: Float = -200
            var computed: [BandSet] = []
            if options.stereo {
                loudest = max(loudest, spectrum(bufferL, into: left, sampleRate: sampleRate, options: options))
                loudest = max(loudest, spectrum(bufferR, into: right, sampleRate: sampleRate, options: options))
                computed += [left, right]
            } else {
                left.silence()
                right.silence()
            }
            if options.mono {
                loudest = max(loudest, spectrum(bufferMid, into: mid, sampleRate: sampleRate, options: options))
                computed.append(mid)
            } else {
                mid.silence()
            }
            let top = updateReference(loudest: loudest, options: options, dt: dt)
            for set in computed {
                let config = bands(count: set.count, sampleRate: sampleRate)
                for i in set.db.indices {
                    let db = set.db[i] + options.rangeGain(hz: config[i].hz)
                    set.targets[i] = min(1, max(0, (db - (top - Self.rangeDb)) / Self.rangeDb))
                }
            }
        } else {
            rms = 0
            updateScope(active: false, dt: dt, options: options)
            mid.silence()
            left.silence()
            right.silence()
        }

        mid.update(dt: dt)
        left.update(dt: dt)
        right.update(dt: dt)
        updateMeters(targets: meterTargets, dt: dt)
    }

    // MARK: - Spectrum

    /// Fills `set.db` from one channel. Returns the loudest band in dB.
    private func spectrum(_ samples: UnsafeMutablePointer<Float>, into set: BandSet,
                          sampleRate: Double, options: AnalyzerOptions) -> Float {
        vDSP_vmul(samples, 1, window, 1, samples, 1, vDSP_Length(n))
        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        samples.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        imagp[0] = 0 // that slot holds the Nyquist bin; drop it
        vDSP_zvabs(&split, 1, mags, 1, vDSP_Length(half))
        // Hann (x0.5) and vDSP's x2 packing cancel to N/2, so this makes a full-scale sine read 1.0.
        var scale = 2 / Float(n)
        vDSP_vsmul(mags, 1, &scale, mags, 1, vDSP_Length(half))

        var loudest: Float = -200
        for (i, band) in bands(count: set.count, sampleRate: sampleRate).enumerated() {
            var magnitude: Float = 0
            if band.hi - band.lo < 1.5 {
                // Band narrower than an FFT bin (low end): interpolate at its center.
                let k = min(Int(band.center), half - 2)
                let f = band.center - Float(k)
                magnitude = mags[k] * (1 - f) + mags[k + 1] * f
            } else {
                let k0 = max(1, Int(band.lo.rounded(.up)))
                let k1 = max(k0, min(half - 1, Int(band.hi.rounded(.down))))
                for k in k0...k1 { magnitude = max(magnitude, mags[k]) }
            }
            let db = 20 * log10(max(magnitude, 1e-9)) + band.tiltDb
            set.db[i] = db
            loudest = max(loudest, db)
        }
        return loudest
    }

    /// Auto level: jump up with loud passages, drift down slowly in quiet ones. Returns the bar top in dB.
    /// Sensitivity lowers the top on top of that, so it still makes bars taller with auto level on.
    private func updateReference(loudest: Float, options: AnalyzerOptions, dt: Float) -> Float {
        guard options.autoLevel else { return -8 - options.sensitivityDb }
        if loudest > reference {
            reference += (loudest - reference) * 0.6
        } else {
            reference -= 3 * dt
        }
        reference = max(reference, -38)
        return reference + Self.headroomDb - options.sensitivityDb
    }

    // MARK: - Scope

    /// Finds a rising zero crossing so the waveform holds still, then keeps ~21 ms of it.
    private func updateScope(active: Bool, dt: Float, options: AnalyzerOptions) {
        let points = Self.scopePoints
        guard active else {
            for i in scope.indices { scope[i] *= 0.85 }
            scopeLevel = max(0, scopeLevel - 3 * dt)
            return
        }
        let span = 1024
        var start = n - span
        var i = n - span - 1
        while i > n - span - 1024 {
            if bufferL[i - 1] + bufferR[i - 1] < 0 && bufferL[i] + bufferR[i] >= 0 { start = i; break }
            i -= 1
        }
        let step = Float(span) / Float(points)
        var peak: Float = 0
        for k in 0..<points {
            let j = start + Int(Float(k) * step)
            let l = bufferL[j], r = bufferR[j]
            scope[points + k] = l
            scope[2 * points + k] = r
            scope[k] = (l + r) / 2
            peak = max(peak, abs(l), abs(r))
        }
        // Instant attack, quick release, so the line recovers right after a loud hit.
        scopePeak = peak > scopePeak ? peak : max(peak, scopePeak * exp(-3 * dt))
        scopePeak = max(scopePeak, 0.02)
        let gain = 0.85 / scopePeak * pow(10, options.sensitivityDb / 20)
        for k in scope.indices { scope[k] = max(-1, min(1, scope[k] * gain)) }
        let target = min(1, rms * 40)
        scopeLevel += (target - scopeLevel) * (1 - pow(0.8, dt * 60))
    }

    // MARK: - VU meter

    private func meterLevels(options: AnalyzerOptions, dt: Float) -> (Float, Float) {
        let count = Self.meterWindow
        var rmsL: Float = 0, rmsR: Float = 0
        vDSP_rmsqv(bufferL + (n - count), 1, &rmsL, vDSP_Length(count))
        vDSP_rmsqv(bufferR + (n - count), 1, &rmsR, vDSP_Length(count))
        rms = max(rmsL, rmsR)

        let dbL = 20 * log10(max(rmsL, 1e-9))
        let dbR = 20 * log10(max(rmsR, 1e-9))
        // Scale the sensitivity boost to the meter's narrower range so the slider feels the same as on the bars.
        let boost = options.sensitivityDb * Self.meterRangeDb / Self.rangeDb
        let top: Float
        if options.autoLevel {
            let loudest = max(dbL, dbR)
            if loudest > meterReference {
                meterReference += (loudest - meterReference) * 0.3
            } else {
                meterReference -= 1 * dt
            }
            meterReference = max(meterReference, -45)
            top = meterReference + 1.5 - boost
        } else {
            top = -8 - boost
        }
        let floor = top - Self.meterRangeDb
        return (min(1, max(0, (dbL - floor) / Self.meterRangeDb)),
                min(1, max(0, (dbR - floor) / Self.meterRangeDb)))
    }

    private func updateMeters(targets: (Float, Float), dt: Float) {
        let attack = 1 - pow(0.4, dt * 60)
        let fall = 1.3 * dt
        func step(_ level: inout Float, _ peak: inout Float, _ hold: inout Float, _ speed: inout Float, _ target: Float) {
            level = target > level ? level + (target - level) * attack : max(target, level - fall)
            if level >= peak {
                peak = level; hold = 1.0; speed = 0
            } else if hold > 0 {
                hold -= dt
            } else {
                speed += 1.5 * dt
                peak = max(level, peak - speed * dt)
            }
        }
        step(&meterLeft, &meterPeakLeft, &meterHold.0, &meterSpeed.0, targets.0)
        step(&meterRight, &meterPeakRight, &meterHold.1, &meterSpeed.1, targets.1)
    }
}
