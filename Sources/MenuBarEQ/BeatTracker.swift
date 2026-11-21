import Foundation

/// Follows the music's tempo and keeps a beat clock locked to it, like a DJ app's beat grid, so effects land on
/// every beat, even where the kick drum drops out, and not on off-beat bass notes.
///
/// - Onsets: how sharply the bars rise, summed across the spectrum (the bass counts double), at 60 per second.
/// - Tempo: autocorrelation of the last 8 seconds of onsets between 60 and 200 BPM, favoring the usual 90 to 160
///   (so a 174 drum & bass track reads 87 or 174, never 58), refreshed four times a second and smoothed.
/// - Phase: a clock that ticks at that tempo; onsets close to a predicted beat nudge it into line, onsets halfway
///   between beats (syncopation) don't. When the tempo is new or the clock has drifted, it re-aligns to the beat
///   grid that fits the last few seconds best.
///
/// Foundation only, so the tuning harness can run it on songs.
final class BeatTracker {
    /// The tempo in beats per minute (0 until there's enough music to tell).
    private(set) var bpm: Float = 0
    /// Where in the beat it is: 0 on the beat, rising to 1 just before the next.
    private(set) var phase: Float = 0
    /// How sure it is of the tempo and the beat grid, 0...1. Below `sure` the beats are guesses.
    private(set) var confidence: Float = 0
    /// From here on the clock's beats are worth following.
    static let sure: Float = 0.4
    /// True on the frame a beat falls (from the clock: on time even when the drum is quiet).
    private(set) var isBeat = false
    /// How strong the music is on its beats lately, 0...1 (for effects that scale with it).
    private(set) var beatStrength: Float = 0
    /// Beats counted so far (for the tuning harness).
    private(set) var beats = 0

    static let rate: Double = 60             // onset samples per second
    /// How much earlier than the clock's beat the beat is reported (seconds).
    static let lead: Double = 0.025
    private var fired = false                // this beat was already reported
    private static let historySeconds = 8.0
    private let length = Int(BeatTracker.rate * BeatTracker.historySeconds)
    private var onsets: [Float]
    private var head = 0                     // where the next sample goes
    private var filled = 0
    private var previous: [Float] = []
    private var pending: Double = 0          // time not yet turned into samples
    private var accumulated: Float = 0       // onset energy since the last sample
    private var sinceEstimate: Double = 0
    private var period: Double = 0           // seconds per beat (0 = none yet)
    private var candidate: Double = 0        // a different tempo that keeps winning
    private var candidateTime: Double = 0
    private var onsetFloor: Float = 0
    private var recentPeak: Float = 0
    private var lastOnset: Float = 0
    private var rising = false
    private var aligned = false
    private var hits: [Float] = []           // how close recent onsets fell to predicted beats (1 = on the beat)

    init() {
        onsets = [Float](repeating: 0, count: length)
    }

    func reset() {
        onsets = [Float](repeating: 0, count: length)
        head = 0; filled = 0; previous = []; pending = 0; accumulated = 0; sinceEstimate = 0
        period = 0; candidate = 0; candidateTime = 0; bpm = 0; phase = 0; confidence = 0; isBeat = false
        beatStrength = 0; onsetFloor = 0; recentPeak = 0; lastOnset = 0; rising = false; aligned = false; hits = []
        fired = false
    }

    /// One frame: `levels` are the bar heights, bass first (the analyzer's mid spectrum).
    func update(levels: [Float], playing: Bool, dt: Double) {
        isBeat = false
        guard playing, levels.count >= 8 else {
            // Silence: forget the clock slowly, keep the tempo for when the music comes back.
            confidence *= Float(exp(-dt / 1.5))
            previous = []
            return
        }
        // Onset: how much the bars rose since the last frame (falls don't count). The bass counts double.
        var flux: Float = 0
        if previous.count == levels.count {
            let bass = max(1, levels.count / 6)
            for i in levels.indices {
                let rise = levels[i] - previous[i]
                if rise > 0 { flux += rise * (i < bass ? 2 : 1) }
            }
            flux /= Float(levels.count)
        }
        previous = levels
        accumulated += flux

        // Into evenly spaced samples, whatever the frame rate (30 on battery): each frame's onset goes to the
        // samples its time covers.
        pending += dt
        let step = 1 / Self.rate
        var samples = 0
        while pending >= step { pending -= step; samples += 1 }
        if samples > 0 {
            let share = accumulated / Float(samples)
            for _ in 0..<samples { push(share) }
            accumulated = 0
            noteOnset(share)
        }

        sinceEstimate += dt
        if sinceEstimate >= 0.25, filled >= Int(Self.rate * 3) {
            sinceEstimate = 0
            estimateTempo(dt: 0.25)
        }

        // The clock. The beat fires a little early: the onsets it locks to arrive about that late (the bars take a
        // moment to rise), and the picture takes a frame to show.
        guard period > 0 else { return }
        phase += Float(dt / period)
        if !fired, phase + Float(Self.lead / period) >= 1 {
            fire()
        }
        if phase >= 1 {
            phase -= Float(Int(phase))
            if !fired { fire() }   // a correction jumped past the early point
            fired = false
        }
    }

    private func fire() {
        isBeat = true
        fired = true
        beats += 1
    }

    private func push(_ value: Float) {
        onsets[head] = value
        head = (head + 1) % length
        filled = min(length, filled + 1)
    }

    /// The sample `back` steps ago (0 = newest).
    private func sample(_ back: Int) -> Float {
        onsets[(head - 1 - back + length * 2) % length]
    }

    /// An onset peak (a local high well above the usual) near a predicted beat nudges the clock toward it.
    private func noteOnset(_ value: Float) {
        onsetFloor += (value - onsetFloor) * 0.02
        recentPeak = max(recentPeak * 0.995, value)
        defer { lastOnset = value }
        // A peak: it was rising and now falls, and the high stands out from the floor.
        let wasRising = rising
        rising = value > lastOnset
        guard wasRising, !rising, lastOnset > onsetFloor * 2.2, lastOnset > recentPeak * 0.25, period > 0 else { return }
        // The peak was one sample ago; where did it fall in the beat?
        let peakPhase = phase - Float(1 / (Self.rate * period))
        var offset = peakPhase - peakPhase.rounded()            // -0.5...0.5, 0 = right on a beat
        if offset < -0.5 { offset += 1 }
        let closeness = max(0, 1 - abs(offset) / 0.25)
        hits.append(closeness)
        if hits.count > 16 { hits.removeFirst() }
        // Only onsets near a beat steer the clock; the stronger the onset, the more.
        if abs(offset) < 0.2 {
            let weight = min(1, lastOnset / max(1e-6, recentPeak))
            phase -= offset * 0.25 * weight
            beatStrength += (min(1, lastOnset / max(1e-6, recentPeak)) - beatStrength) * 0.2
        }
    }

    /// Autocorrelation of the onset history, weighted toward common tempos, with each lag also scored by its
    /// double (a beat at that period usually comes with one at twice the period).
    private func estimateTempo(dt: Double) {
        let n = filled
        // Mean-removed onsets, newest last.
        var e = [Float](repeating: 0, count: n)
        var mean: Float = 0
        for i in 0..<n { e[i] = sample(n - 1 - i); mean += e[i] }
        mean /= Float(n)
        for i in 0..<n { e[i] = max(0, e[i] - mean) }

        let minLag = Int(Self.rate * 60 / 200), maxLag = Int(Self.rate * 60 / 60)
        func ac(_ lag: Int) -> Float {
            guard lag < n else { return 0 }
            var s: Float = 0
            for i in lag..<n { s += e[i] * e[i - lag] }
            return s / Float(n - lag)
        }
        var raw = [Float](repeating: 0, count: maxLag * 2 + 2)
        for lag in minLag...min(maxLag * 2, n - 1) { raw[lag] = ac(lag) }
        var best: Float = 0, bestLag = 0, total: Float = 0, count: Float = 0
        var scores = [Float](repeating: 0, count: maxLag + 1)
        for lag in minLag...maxLag {
            let bpmHere = 60 * Self.rate / Double(lag)
            // Log-normal preference around 120 BPM (about an octave wide).
            let octaves = log2(bpmHere / 120)
            let prior = Float(exp(-0.5 * (octaves / 0.9) * (octaves / 0.9)))
            let double = lag * 2 < raw.count ? raw[lag * 2] : 0
            let score = (raw[lag] + 0.5 * double) * prior
            scores[lag] = score
            total += score; count += 1
            if score > best { best = score; bestLag = lag }
        }
        guard bestLag > 0, total > 0 else { return }
        // Parabolic peak for a finer period.
        var lag = Double(bestLag)
        if bestLag > minLag, bestLag < maxLag {
            let a = scores[bestLag - 1], b = scores[bestLag], c = scores[bestLag + 1]
            let den = a - 2 * b + c
            if den < 0 { lag += Double(0.5 * (a - c) / den) }
        }
        let estimate = lag / Self.rate
        let peakiness = best / (total / count)              // about 1.5 for no rhythm, 3+ for a clear beat

        // Follow small changes; switch to a different tempo only after it has won for two seconds.
        if period == 0 {
            period = estimate
            aligned = false
        } else if abs(estimate / period - 1) < 0.06 {
            period += (estimate - period) * 0.25
            candidate = 0
        } else if candidate > 0, abs(estimate / candidate - 1) < 0.06 {
            candidateTime += dt
            if candidateTime >= 2 {
                period = estimate
                candidate = 0
                aligned = false
            }
        } else {
            candidate = estimate
            candidateTime = 0
        }
        bpm = Float(60 / period)

        // Re-align the clock to the grid that fits the last four seconds best, when new or drifting.
        let onBeat = hits.isEmpty ? 0 : hits.reduce(0, +) / Float(hits.count)
        if !aligned || (hits.count >= 8 && onBeat < 0.35) { align() }
        let tempoSure = min(1, max(0, (peakiness - 1.4) / 1.6))
        let target = tempoSure * (hits.count >= 4 ? min(1, onBeat * 1.6) : 0.5)
        confidence += (target - confidence) * 0.3
    }

    /// Finds where the beats fall: the offset whose every-beat comb collects the most onset energy.
    private func align() {
        guard period > 0 else { return }
        let periodSamples = period * Self.rate
        let span = min(filled, Int(Self.rate * 4))
        let steps = max(4, Int(periodSamples.rounded()))
        var bestOffset = 0, best: Float = -1
        for offset in 0..<steps {
            var s: Float = 0
            var back = Double(offset)
            while Int(back) < span {
                let i = Int(back)
                // A little spread, so a beat a sample off still counts.
                s += sample(i) + 0.5 * (i > 0 ? sample(i - 1) : 0) + 0.5 * (i + 1 < span ? sample(i + 1) : 0)
                back += periodSamples
            }
            if s > best { best = s; bestOffset = offset }
        }
        // The newest beat was `bestOffset` samples ago: that's how far into the beat we are now.
        phase = Float(Double(bestOffset) / periodSamples)
        phase -= Float(Int(phase))
        aligned = true
        hits.removeAll()
    }
}
