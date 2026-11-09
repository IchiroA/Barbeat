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
/// - The sound itself, every frame: energy panned to the middle (singers almost always are), in the voice range,
///   in held, pitched notes rather than hits. Moves with every word and costs next to nothing.
/// - Apple's sound recognizer, twice a second: is anyone singing (or talking) right now? It gates the first part,
///   so a guitar or synth solo in the middle doesn't count while nobody sings.
/// Foundation, Accelerate and SoundAnalysis only, so the tuning harness can run it on songs.
final class VoiceDetector {
    /// How loud the voice is right now, 0...1 (0 while the recognizer hears no voice).
    private(set) var level: Float = 0
    /// How hard a new word or syllable starts this frame (0 on most frames).
    private(set) var word: Float = 0
    /// The voice's pitch as a MIDI note (60 = middle C), smoothed. Nil while unsure.
    private(set) var pitch: Float?
    /// The recognizer's confidence that the chosen kind of voice is there, smoothed, 0...1.
    private(set) var presence: Float = 0
    /// Voice-likeness from the sound alone, before the recognizer's gate, 0...1.
    private(set) var raw: Float = 0
    /// The sound-only signal's ingredients (for tuning): loudness, how centered, how strongly one pitch stands out.
    private(set) var parts: (loud: Float, centered: Float, harmonic: Float) = (0, 0, 0)
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

    private var reference: Float = -60
    private var envelope: Float = 0
    private var floorLevel: Float = 0
    private var wordPeak: Float = 0
    private var wordArmed = true
    private var wordCooldown: Float = 0
    private var smoothPitch: Float?
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
        mono = buffer(Self.monoCapacity)
        vDSP_hann_window(window, vDSP_Length(Self.n), Int32(vDSP_HANN_DENORM))
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        [window, bufL, bufR, bufM, bufS, realp, imagp, powerM, powerS, center, mono].forEach { $0.deallocate() }
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

        // The recognizer's word on whether a voice is there: quick to notice, slow to let go between lines.
        let heard = observer.latest
        let wanted: Float = recognizerFailed ? 1 : {
            switch target {
            case .singing: return heard.singing
            case .speech: return heard.speech
            case .both: return max(heard.singing, heard.speech)
            }
        }()
        let fresh = recognizerFailed || observer.secondsSinceResult < 3
        let goal = fresh ? wanted : 0
        presence += (goal - presence) * (1 - exp(-dt / (goal > presence ? 0.2 : 0.9)))
        let gate = Self.smoothstep(0.12, 0.42, presence)
        level = raw * gate
        detectWords(dt: dt)
    }

    /// Lets go of the recognizer and resets (Voice switched off).
    func stop() {
        let old = stream
        stream = nil
        streamFormat = nil
        streamStart = nil
        if let old { queue.async { old.completeAnalysis() } }
        observer.reset()
        level = 0; word = 0; raw = 0; presence = 0; pitch = nil; smoothPitch = nil
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
        var centerSum: Float = 0, midSum: Float = 0
        for k in 0..<half {
            // Roughly the part panned to the middle: mid power that side power doesn't explain.
            let c = max(0, powerM[k] - powerS[k])
            center[k] = c.squareRoot()
            guard k >= k0, k <= k1 else { continue }
            // Formants (300 Hz to 3.5 kHz) count fully, the edges of the range less.
            let hz = Float(k) * binHz
            let weight: Float = hz < 300 ? 0.5 : (hz > 3500 ? 0.5 : 1)
            centerSum += c * weight
            midSum += powerM[k] * weight
        }
        // Pitched: a sung or spoken syllable is one strong stack of harmonics. Drums, pads and chords aren't,
        // and the stack falls apart between words, so this moves with every syllable.
        let harmonic = estimatePitch(binHz: binHz, dt: dt)
        let pitched = Self.smoothstep(3.5, 8, harmonic)
        // Centered: how much of the voice range sits in the middle.
        let share = midSum > 0 ? centerSum / midSum : 0
        let centered = Self.smoothstep(0.25, 0.7, share)

        // Loudness of the centered voice range against its own recent loudest (an auto level, like the bars').
        let db = 10 * log10(max(centerSum, 1e-12))
        if db > reference { reference += (db - reference) * 0.5 } else { reference -= 2.5 * dt }
        reference = max(reference, -70)
        let loud = min(1, max(0, (db - (reference - 18)) / 18))

        parts = (loud, centered, harmonic)
        // Layered vocals (a chorus, doubled lines) have no single pitch standing out; there the loudness of the
        // voice range carries the motion, and the recognizer decides whether it's a voice at all.
        let target = max(pitched * (0.35 + 0.65 * loud), 0.55 * loud) * centered
        let rate: Float = target > envelope ? 1 - pow(0.45, dt * 60) : 1 - exp(-dt / 0.12)
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

    /// The singer's note: the pitch whose harmonics line up best with the centered sound (82 Hz to 1 kHz).
    /// Returns how far that pitch stands out from the rest (about 2 to 4 for plain music, 6 to 12 for a voice).
    private func estimatePitch(binHz: Float, dt: Float) -> Float {
        func magnitude(_ hz: Float) -> Float {
            let x = hz / binHz
            let i = Int(x)
            guard i >= 1, i + 1 < half else { return 0 }
            let f = x - Float(i)
            return center[i] * (1 - f) + center[i + 1] * f
        }
        var best: Float = 0, bestNote: Float = 40, total: Float = 0, candidates: Float = 0
        var scores: [Float] = []
        scores.reserveCapacity(130)
        // Candidates a third of a semitone apart, MIDI 40 (82 Hz) to 83 (988 Hz).
        var note: Float = 40
        while note <= 83 {
            let f0 = 440 * pow(2, (note - 69) / 12)
            var score: Float = 0, weight: Float = 1
            for h in 1...6 {
                score += magnitude(f0 * Float(h)) * weight
                weight *= 0.82
            }
            scores.append(score)
            total += score
            candidates += 1
            if score > best { best = score; bestNote = note }
            note += 1.0 / 3
        }
        // Harmonic sums favour the octave below; take the octave above when it scores nearly as well.
        let upIndex = Int(((bestNote + 12) - 40) * 3 + 0.5)
        if best > 0, upIndex >= 0, upIndex < scores.count, scores[upIndex] >= best * 0.8 {
            bestNote += 12
            best = scores[upIndex]
        }
        let ratio = candidates > 0 && total > 0 ? best / (total / candidates) : 0
        let confident = ratio > 4.5
        if confident {
            unsure = 0
            var heardNote = bestNote
            if let current = smoothPitch {
                // Fold octave jumps back toward the melody so the color doesn't flicker.
                while heardNote - current > 7 { heardNote -= 12 }
                while current - heardNote > 7 { heardNote += 12 }
                smoothPitch = current + (heardNote - current) * (1 - pow(0.8, dt * 60))
            } else {
                smoothPitch = heardNote
            }
        } else {
            unsure += dt
            if unsure > 0.6 { smoothPitch = nil }
        }
        pitch = smoothPitch
        return ratio
    }

    /// A word starts when the voice jumps up from where it just was.
    private func detectWords(dt: Float) {
        word = 0
        wordCooldown -= dt
        floorLevel = level < floorLevel ? level : floorLevel + (level - floorLevel) * (1 - exp(-dt / 0.25))
        if !wordArmed {
            wordPeak = max(wordPeak, level)
            if level < wordPeak * 0.85 || level < 0.12 { wordArmed = true }
        } else if wordCooldown <= 0, level > 0.2, level - floorLevel > 0.09 {
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
        level = raw * Self.smoothstep(0.12, 0.42, presence)
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
            // One-second looks, every half second: quick enough to notice a singer coming in.
            request.windowDuration = CMTime(seconds: 1, preferredTimescale: 48_000)
            request.overlapFactor = 0.5
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
