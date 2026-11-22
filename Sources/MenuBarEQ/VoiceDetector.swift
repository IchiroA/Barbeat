// Barbeat, a light show for the Mac's menu bar · @IchiroA · MIT License
import Foundation
import Accelerate
import AVFoundation
import SoundAnalysis

/// What kind of voice to react to.
enum VoiceTarget: String, CaseIterable, Identifiable, Codable {
    case singing, speech, both
    var id: String { rawValue }

    var title: String {
        switch self {
        case .singing: return "Singing"
        case .speech: return "Speech"
        case .both: return "Both"
        }
    }
}

/// Finds voices in the music, in two parts:
/// - Apple's sound recognizer, four times a second: is anyone singing (or talking) right now? That decides whether
///   there's a voice at all, so a guitar or synth solo in the middle doesn't count while nobody sings.
/// - The sound itself, every frame: how loud the part panned to the middle is in the voice range (singers almost
///   always sit in the middle), which moves with every word, and the singer's note from the harmonics of that part.
/// Tuned against Demucs vocal stems with scripts/tune-voice (score.py). Foundation, Accelerate and SoundAnalysis
/// only, so the tuning harness can run it on songs.
final class VoiceDetector {
    /// Numbers found with scripts/tune-voice/score.py. The harness can change them (V_<name>=value) to try others.
    struct Tuning: Equatable {
        // Recognizer: one-second looks, a new one every quarter second.
        var recognizerWindow: Double = 1
        var recognizerOverlap: Double = 0.75
        // Gate: the effect shows while `presence` is above about this (it fades in over +-0.1).
        var gateAt: Float = 0.7
        // Level: loudness of the centered voice range against its own recent loudest.
        var levelRange: Float = 15     // dB below the recent loudest that reads as 0
        var levelDecay: Float = 0.5    // dB per second the "recent loudest" sinks
        var levelRelease: Float = 0.05 // seconds
        // Words: a jump up of the level from where it just was.
        var wordRise: Float = 0.15
        var wordFloor: Float = 0.15    // seconds the "where it just was" takes to catch up
        // Pitch: harmonic salience on a flattened spectrum.
        var flatten: Float = 0.7       // 0 = raw magnitudes, 1 = fully flattened
        var lowestNote: Float = 45     // 110 Hz
        var highestNote: Float = 84    // 1047 Hz
        var harmonics = 10
        var harmonicWeight: Float = 0.85
        var lowestHarmonicHz: Float = 150
        var confident: Float = 2.4     // salience above this trusts the note
        var noteMedian = 5             // frames
        var octaveSnap = true          // fold only jumps of about an octave (false: fold everything into +-7 semitones)
        var noteSmoothing: Float = 0.2 // share of the old note kept each frame
    }
    var tuning = Tuning()

    /// How loud the voice is right now, 0...1 (0 while the recognizer hears no voice).
    private(set) var level: Float = 0
    /// How hard a new word or syllable starts this frame (0 on most frames).
    private(set) var word: Float = 0
    /// The voice's pitch as a MIDI note (60 = middle C), smoothed. Nil while unsure.
    private(set) var pitch: Float?
    /// How sure the detector is that the chosen kind of voice is there, 0...1: the recognizer's answers over the last
    /// two seconds and the loudness of the centered voice range, weighed by `Gate`.
    private(set) var presence: Float = 0
    /// Voice loudness from the sound alone, before the recognizer's gate, 0...1.
    private(set) var raw: Float = 0
    /// For tuning: how strongly the best note stands out (about 1.5 to 2 without a voice, 2 to 4 with one), and
    /// that note before smoothing.
    private(set) var salience: Float = 0
    private(set) var candidate: Float?
    /// The recognizer's latest confidences (for the meter and tuning).
    var heard: (singing: Float, speech: Float) { observer.latest }

    var target: VoiceTarget = .singing
    /// Runs the recognizer on the calling thread (the tuning harness runs faster than real time).
    var synchronous = false
    /// `--voice-demo`: a made-up singer (phrases, words, a wandering melody), to try the effects without music.
    var demo = false

    // MARK: Sound analysis state

    private static let n = 4096
    private let half = VoiceDetector.n / 2
    private let log2n = vDSP_Length(12)
    private let setup: FFTSetup
    private let window: UnsafeMutablePointer<Float>
    private let bufL: UnsafeMutablePointer<Float>
    private let bufR: UnsafeMutablePointer<Float>
    private let bufM: UnsafeMutablePointer<Float>
    private let bufS: UnsafeMutablePointer<Float>
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>
    private let powerM: UnsafeMutablePointer<Float>
    private let powerS: UnsafeMutablePointer<Float>
    private let center: UnsafeMutablePointer<Float>   // magnitude of the part panned to the middle, per bin
    private let flat: UnsafeMutablePointer<Float>     // the same, flattened (each bin over its neighbourhood)
    private let running: UnsafeMutablePointer<Float>  // running sum of `center`, for the neighbourhood averages
    private let peak3: UnsafeMutablePointer<Float>    // the strongest of each flattened bin and its two neighbours
    private var layout = Layout()

    /// Where each candidate note's harmonics fall in the spectrum. Depends only on the sample rate and the tuning,
    /// so it's worked out once instead of every frame.
    private struct Layout {
        static let step: Float = 0.2   // candidates a fifth of a semitone apart
        struct Key: Equatable {
            var binHz: Float
            var tuning: Tuning
        }
        var key = Key(binHz: 0, tuning: Tuning())
        var top = 0, notes = 0, harmonics = 0
        var from: [Int] = [], to: [Int] = []   // each bin's neighbourhood
        var bins: [Int] = []                   // notes x harmonics, 0 = outside the range that counts
        var weights: [Float] = []
        var exponents: [Float] = []

        init() {}

        init(binHz: Float, half: Int, tuning t: Tuning) {
            key = Key(binHz: binHz, tuning: t)
            top = min(half - 2, Int(5000 / binHz) + 2)
            from = [Int](repeating: 0, count: top)
            to = from
            for k in 1..<top {
                let w = max(3, Int(Float(k) * 0.06))
                from[k] = max(0, k - w)
                to[k] = min(top, k + w + 1)
            }
            harmonics = max(1, t.harmonics)
            notes = max(1, Int((t.highestNote - t.lowestNote) / Self.step) + 1)
            weights = (0..<harmonics).map { pow(t.harmonicWeight, Float($0)) }
            let lowBin = max(1, Int(t.lowestHarmonicHz / binHz))
            bins = [Int](repeating: 0, count: notes * harmonics)
            for c in 0..<notes {
                let f0 = 440 * pow(2, (t.lowestNote + Float(c) * Self.step - 69) / 12)
                for h in 0..<harmonics {
                    let i = Int(f0 * Float(h + 1) / binHz + 0.5)
                    bins[c * harmonics + h] = i >= lowBin && i + 1 < top ? i : 0
                }
            }
            exponents = [Float](repeating: t.flatten, count: top)
        }
    }

    private var reference: Float = -60
    private var envelope: Float = 0
    private var floorLevel: Float = 0
    private var wordPeak: Float = 0
    private var wordArmed = true
    private var wordCooldown: Float = 0
    private var smoothPitch: Float?
    private var recentNotes: [Float] = []
    private var unsure: Float = 0
    private var clock: Double = 0

    // MARK: Recognizer state

    private let queue = DispatchQueue(label: "Barbeat.voice", qos: .utility)
    private let observer = Observer()
    private var stream: SNAudioStreamAnalyzer?
    private var streamFormat: AVAudioFormat?
    private var streamStart: UInt64?
    private var cursor: UInt64 = 0
    private var feedTimer: Float = 0
    private var recognizerFailed = false
    private let mono: UnsafeMutablePointer<Float>
    private static let monoCapacity = 1 << 15

    init() {
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        func buffer(_ count: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: count)
            p.initialize(repeating: 0, count: count)
            return p
        }
        window = buffer(Self.n)
        bufL = buffer(Self.n); bufR = buffer(Self.n); bufM = buffer(Self.n); bufS = buffer(Self.n)
        realp = buffer(Self.n / 2); imagp = buffer(Self.n / 2)
        powerM = buffer(Self.n / 2); powerS = buffer(Self.n / 2); center = buffer(Self.n / 2)
        flat = buffer(Self.n / 2); running = buffer(Self.n / 2 + 1); peak3 = buffer(Self.n / 2)
        mono = buffer(Self.monoCapacity)
        vDSP_hann_window(window, vDSP_Length(Self.n), Int32(vDSP_HANN_DENORM))
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        [window, bufL, bufR, bufM, bufS, realp, imagp, powerM, powerS, center, flat, running, peak3, mono].forEach { $0.deallocate() }
    }

    /// Call once per frame while voices are wanted. `ring: nil` when no fresh audio is arriving.
    func update(ring: SampleRingBuffer?, sampleRate: Double, dt: Float) {
        clock += Double(dt)
        if demo { return updateDemo(dt: dt) }
        guard let ring else {
            decay(dt: dt)
            return
        }
        feedRecognizer(ring: ring, sampleRate: sampleRate, dt: dt)
        analyzeSound(ring: ring, sampleRate: sampleRate, dt: dt)

        // Is the voice there? The recognizer's answers over the last two seconds (so one doubtful answer mid-line
        // doesn't switch it off) and how loud the centered voice range is. Speech doesn't count toward singing:
        // that made audiobooks and podcasts light up.
        let heard = observer.latest
        let fresh = recognizerFailed || observer.secondsSinceResult < 3
        let wanted: Float = recognizerFailed ? 1 : !fresh ? 0 : {
            switch target {
            case .singing: return heard.singing
            case .speech: return heard.speech
            case .both: return max(heard.singing, heard.speech)
            }
        }()
        history.add(time: clock, heard: wanted, raw: raw)
        presence = recognizerFailed ? 1 : Gate.presence(heard: wanted, history: history, raw: raw, now: clock)
        let gate = Self.smoothstep(tuning.gateAt - 0.1, tuning.gateAt + 0.1, presence)
        level = raw * gate
        detectWords(dt: dt)
    }

    /// The last two seconds of the recognizer's answers and of the sound-only level, one entry per frame.
    private struct History {
        private var time: [Double] = []
        private var heard: [Float] = []
        private var raw: [Float] = []

        mutating func add(time t: Double, heard h: Float, raw r: Float) {
            time.append(t); heard.append(h); raw.append(r)
            var old = 0
            while old < time.count, time[old] < t - 2 { old += 1 }
            if old > 0 { time.removeFirst(old); heard.removeFirst(old); raw.removeFirst(old) }
        }

        mutating func clear() { time.removeAll(); heard.removeAll(); raw.removeAll() }

        /// Highest and mean recognizer answer, and mean level, over the last `seconds`.
        func summary(seconds: Double, now: Double) -> (maxHeard: Float, meanHeard: Float, meanRaw: Float) {
            var top: Float = 0, sumHeard: Float = 0, sumRaw: Float = 0, count: Float = 0
            for i in stride(from: time.count - 1, through: 0, by: -1) where time[i] > now - seconds {
                top = max(top, heard[i]); sumHeard += heard[i]; sumRaw += raw[i]; count += 1
            }
            return count > 0 ? (top, sumHeard / count, sumRaw / count) : (0, 0, 0)
        }
    }
    private var history = History()

    /// Logistic regression fit with scripts/tune-voice/fit_gate.py on 13 songs (Demucs stems say where the singing is)
    /// and 5 talk-only clips (audiobooks, a podcast, talk radio, stand-up), checked on 7 other songs and 4 other clips.
    private enum Gate {
        static func presence(heard: Float, history: History, raw: Float, now: Double) -> Float {
            let last1 = history.summary(seconds: 1, now: now)
            let last2 = history.summary(seconds: 2, now: now)
            let half = history.summary(seconds: 0.5, now: now)
            let z = 3.777 * heard + 2.074 * last1.maxHeard + 4.954 * last2.maxHeard + 3.207 * last1.meanHeard
                + 1.61 * raw + 2.175 * half.meanRaw - 5.549
            return 1 / (1 + exp(-z))
        }
    }

    /// Lets go of the recognizer and resets (Voice switched off).
    func stop() {
        let old = stream
        stream = nil
        streamFormat = nil
        streamStart = nil
        if let old { queue.async { old.completeAnalysis() } }
        observer.reset()
        level = 0; word = 0; raw = 0; presence = 0; pitch = nil; smoothPitch = nil; candidate = nil; salience = 0
        recentNotes.removeAll()
        history.clear()
        envelope = 0; reference = -60
    }

    // MARK: - The sound itself

    private func analyzeSound(ring: SampleRingBuffer, sampleRate: Double, dt: Float) {
        let n = Self.n
        ring.readLatest(n, left: bufL, right: bufR)
        // Mid (what's in both channels) and side (what differs). A voice in the middle is all mid, no side.
        var halfGain: Float = 0.5
        vDSP_vadd(bufL, 1, bufR, 1, bufM, 1, vDSP_Length(n))
        vDSP_vsmul(bufM, 1, &halfGain, bufM, 1, vDSP_Length(n))
        vDSP_vsub(bufR, 1, bufL, 1, bufS, 1, vDSP_Length(n))   // L - R
        vDSP_vsmul(bufS, 1, &halfGain, bufS, 1, vDSP_Length(n))
        power(bufM, into: powerM)
        power(bufS, into: powerS)

        let binHz = Float(sampleRate) / Float(n)
        let k0 = max(1, Int(200 / binHz)), k1 = min(half - 1, Int(4000 / binHz))
        var centerSum: Float = 0
        for k in 0..<half {
            // Roughly the part panned to the middle: mid power that side power doesn't explain.
            let c = max(0, powerM[k] - powerS[k])
            center[k] = c.squareRoot()
            guard k >= k0, k <= k1 else { continue }
            // Formants (300 Hz to 3.5 kHz) count fully, the edges of the range less.
            let hz = Float(k) * binHz
            let weight: Float = hz < 300 ? 0.5 : (hz > 3500 ? 0.5 : 1)
            centerSum += c * weight
        }
        estimatePitch(binHz: binHz, dt: dt)

        // Loudness of the centered voice range against its own recent loudest (an auto level, like the bars'). On its
        // own this follows the isolated vocal better than anything mixed into it (pitch strength, how centered).
        let db = 10 * log10(max(centerSum, 1e-12))
        if db > reference { reference += (db - reference) * 0.5 } else { reference -= tuning.levelDecay * dt }
        reference = max(reference, -70)
        let target = min(1, max(0, (db - (reference - tuning.levelRange)) / tuning.levelRange))
        let rate: Float = target > envelope ? 1 - pow(0.45, dt * 60) : 1 - exp(-dt / tuning.levelRelease)
        envelope += (target - envelope) * rate
        raw = envelope
    }

    /// Power spectrum of one windowed channel (in place on `samples`).
    private func power(_ samples: UnsafeMutablePointer<Float>, into out: UnsafeMutablePointer<Float>) {
        vDSP_vmul(samples, 1, window, 1, samples, 1, vDSP_Length(Self.n))
        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        samples.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        imagp[0] = 0
        vDSP_zvmags(&split, 1, out, 1, vDSP_Length(half))
    }

    /// The singer's note: the pitch whose harmonics line up best with the centered sound. The spectrum is flattened
    /// first (each bin over its neighbourhood), so the loud bass and kick can't win just by being loud, and harmonics
    /// below 150 Hz don't count.
    private func estimatePitch(binHz: Float, dt: Float) {
        let t = tuning
        if layout.key != Layout.Key(binHz: binHz, tuning: t) { layout = Layout(binHz: binHz, half: half, tuning: t) }
        let top = layout.top
        // Flatten: each bin over the average of its neighbourhood (about a sixth of an octave), to the power `flatten`.
        running[0] = 0
        for k in 0..<top { running[k + 1] = running[k] + center[k] }
        for k in 1..<top {
            let a = layout.from[k], b = layout.to[k]
            flat[k] = (running[b] - running[a]) / Float(b - a) + 1e-9
        }
        var count = Int32(top - 1)
        layout.exponents.withUnsafeBufferPointer { vvpowf(flat + 1, $0.baseAddress!, flat + 1, &count) }
        vDSP_vdiv(flat + 1, 1, center + 1, 1, flat + 1, 1, vDSP_Length(top - 1))   // center / mean^flatten
        // The strongest of each bin and its two neighbours, so a harmonic between bins still counts fully.
        for k in 1..<(top - 1) { peak3[k] = max(flat[k - 1], flat[k], flat[k + 1]) }
        // Every candidate note (a fifth of a semitone apart): its harmonics' peaks, the higher ones weighing less.
        var best: Float = 0, bestIndex = 0, total: Float = 0
        let harmonics = layout.harmonics
        for c in 0..<layout.notes {
            var score: Float = 0
            let row = c * harmonics
            for h in 0..<harmonics {
                let bin = layout.bins[row + h]
                if bin > 0 { score += peak3[bin] * layout.weights[h] }
            }
            total += score
            if score > best { best = score; bestIndex = c }
        }
        let bestNote = t.lowestNote + Float(bestIndex) * Layout.step
        salience = total > 0 ? best / (total / Float(layout.notes)) : 0
        candidate = best > 0 ? bestNote : nil
        if salience > t.confident {
            unsure = 0
            // The middle of the last few confident notes, so a stray frame doesn't move the color.
            recentNotes.append(bestNote)
            if recentNotes.count > max(1, t.noteMedian) { recentNotes.removeFirst(recentNotes.count - max(1, t.noteMedian)) }
            var heardNote = recentNotes.sorted()[recentNotes.count / 2]
            if let current = smoothPitch {
                if t.octaveSnap {
                    // A jump of about an octave is usually the tracker, not the singer: fold it back.
                    let folded = heardNote - 12 * ((heardNote - current) / 12).rounded()
                    if abs(heardNote - current) > 9, abs(folded - current) < 2.5 { heardNote = folded }
                } else {
                    while heardNote - current > 7 { heardNote -= 12 }
                    while current - heardNote > 7 { heardNote += 12 }
                }
                smoothPitch = current + (heardNote - current) * (1 - pow(t.noteSmoothing, dt * 60))
            } else {
                smoothPitch = heardNote
            }
        } else {
            recentNotes.removeAll(keepingCapacity: true)
            unsure += dt
            if unsure > 0.6 { smoothPitch = nil }
        }
        pitch = smoothPitch
    }

    /// A word starts when the voice jumps up from where it just was.
    private func detectWords(dt: Float) {
        word = 0
        wordCooldown -= dt
        floorLevel = level < floorLevel ? level : floorLevel + (level - floorLevel) * (1 - exp(-dt / tuning.wordFloor))
        if !wordArmed {
            wordPeak = max(wordPeak, level)
            if level < wordPeak * 0.85 || level < 0.12 { wordArmed = true }
        } else if wordCooldown <= 0, level > 0.2, level - floorLevel > tuning.wordRise {
            word = min(1, (level - floorLevel) * 2.5)
            wordArmed = false
            wordPeak = level
            wordCooldown = 0.15
        }
    }

    private func decay(dt: Float) {
        envelope *= exp(-dt / 0.12)
        raw = envelope
        presence *= exp(-dt / 0.9)
        history.clear()
        level = raw * Self.smoothstep(tuning.gateAt - 0.1, tuning.gateAt + 0.1, presence)
        word = 0
        unsure += dt
        if unsure > 0.6 { smoothPitch = nil; pitch = nil }
    }

    private func updateDemo(dt: Float) {
        // Four-second phrases with a breath between them, about four words a second, and a slow melody.
        let t = Float(clock)
        let phrase = t.truncatingRemainder(dividingBy: 4)
        let singing: Float = phrase < 3.2 ? 1 : 0
        let syllable = (t * 4).truncatingRemainder(dividingBy: 1)
        let target = singing * (0.55 + 0.45 * exp(-syllable * 4))
        envelope += (target - envelope) * (1 - pow(0.5, dt * 60))
        raw = envelope
        presence += (singing - presence) * (1 - exp(-dt / 0.3))
        level = raw * Self.smoothstep(0.12, 0.42, presence)
        pitch = singing > 0 ? 62 + 10 * sin(t * 0.7) + 3 * sin(t * 2.3) : nil
        detectWords(dt: dt)
    }

    // MARK: - Apple's sound recognizer

    private func feedRecognizer(ring: SampleRingBuffer, sampleRate: Double, dt: Float) {
        guard !recognizerFailed else { return }
        feedTimer += dt
        guard feedTimer >= 0.1 || synchronous else { return }
        feedTimer = 0
        if streamFormat?.sampleRate != sampleRate { startStream(sampleRate: sampleRate, ring: ring) }
        guard let stream, let format = streamFormat else { return }
        let (count, position) = ring.readNew(since: &cursor, into: mono, limit: Self.monoCapacity)
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { return }
        channel.update(from: mono, count: count)
        buffer.frameLength = AVAudioFrameCount(count)
        if streamStart == nil { streamStart = position }
        let frame = AVAudioFramePosition(position &- (streamStart ?? position))
        if synchronous {
            stream.analyze(buffer, atAudioFramePosition: frame)
        } else {
            queue.async { stream.analyze(buffer, atAudioFramePosition: frame) }
        }
    }

    private func startStream(sampleRate: Double, ring: SampleRingBuffer) {
        if let old = stream { queue.async { old.completeAnalysis() } }
        stream = nil
        streamStart = nil
        guard sampleRate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            // One-second looks (shorter ones miss most singing), overlapping so a new answer comes every quarter second.
            request.windowDuration = CMTime(seconds: tuning.recognizerWindow, preferredTimescale: 48_000)
            request.overlapFactor = tuning.recognizerOverlap
            let analyzer = SNAudioStreamAnalyzer(format: format)
            try analyzer.add(request, withObserver: observer)
            stream = analyzer
            streamFormat = format
            // Start from now, not from whatever the ring already holds.
            _ = ring.readNew(since: &cursor, into: mono, limit: Self.monoCapacity)
        } catch {
            recognizerFailed = true
        }
    }

    /// Collects the recognizer's results (on its queue); the render loop reads the latest.
    private final class Observer: NSObject, SNResultsObserving {
        private let lock = NSLock()
        private var singing: Float = 0
        private var speech: Float = 0
        private var lastResult = Date.distantPast

        var latest: (singing: Float, speech: Float) {
            lock.lock(); defer { lock.unlock() }
            return (singing, speech)
        }

        var secondsSinceResult: Double {
            lock.lock(); defer { lock.unlock() }
            return Date().timeIntervalSince(lastResult)
        }

        func reset() {
            lock.lock(); defer { lock.unlock() }
            singing = 0; speech = 0; lastResult = .distantPast
        }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            func confidence(_ id: String) -> Float { Float(result.classification(forIdentifier: id)?.confidence ?? 0) }
            let sing = max(confidence("singing"), confidence("choir_singing"), confidence("rapping"),
                           confidence("humming"), confidence("yodeling"))
            let talk = max(confidence("speech"), confidence("whispering"), confidence("shout"), confidence("yell"))
            lock.lock(); defer { lock.unlock() }
            singing = sing
            speech = talk
            lastResult = Date()
        }
    }

    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}
