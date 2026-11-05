import Foundation

/// A synthetic stereo music-like signal for testing with `--demo`:
/// kick in the center, hats to the right, chord to the left, and a sweep that pans side to side.
final class DemoSignal {
    let sampleRate: Double = 48_000
    private var time: Double = 0
    private var sweepPhase: Double = 0
    private var noise: UInt32 = 0x1234_5678
    private var left = [Float](repeating: 0, count: 8192)
    private var right = [Float](repeating: 0, count: 8192)
    /// `--demo-seconds N`: the music stops after N seconds (for testing what happens in silence).
    private let playFor: Double? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--demo-seconds"), i + 1 < args.count else { return nil }
        return Double(args[i + 1])
    }()

    func render(seconds: Double, into ring: SampleRingBuffer) {
        let count = min(left.count, Int(seconds * sampleRate))
        guard count > 0 else { return }
        for i in 0..<count {
            let t = time + Double(i) / sampleRate

            let beat = t.truncatingRemainder(dividingBy: 0.5)
            let kick = sin(2 * .pi * (48 + 90 * exp(-beat * 35)) * beat) * exp(-beat * 9) * 0.7

            noise = noise &* 1_664_525 &+ 1_013_904_223
            let white = Double(Int32(bitPattern: noise)) / Double(Int32.max)
            let hatTime = (t + 0.25).truncatingRemainder(dividingBy: 0.5)
            let hat = white * exp(-hatTime * 45) * 0.12

            let sweepFreq = 150 * pow(2, 6.5 * (0.5 + 0.5 * sin(t * 0.5)))
            sweepPhase += 2 * .pi * sweepFreq / sampleRate
            let sweep = sin(sweepPhase) * 0.08
            let pan = 0.5 + 0.5 * sin(t * 0.9) // 0 = left, 1 = right

            let swell = 0.5 + 0.5 * sin(t * 1.3)
            let chord = (sin(2 * .pi * 220 * t) + sin(2 * .pi * 277.2 * t) + sin(2 * .pi * 329.6 * t)) * 0.04 * swell

            let gain: Double = playFor.map { t < $0 ? 1 : 0 } ?? 1
            left[i] = Float((kick + hat * 0.3 + sweep * (1 - pan) + chord) * gain)
            right[i] = Float((kick + hat + sweep * pan + chord * 0.3) * gain)
        }
        time += Double(count) / sampleRate
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                ring.write(left: l.baseAddress!, right: r.baseAddress!, count: count)
            }
        }
    }
}
