// Barbeat, a light show for the Mac's menu bar · @IchiroA · MIT License
import Foundation

/// The beat pulse's amount for this frame, 0...1: jumps on every bass hit and fades quickly, with a little of the
/// music's own intensity in between so it breathes. Foundation only, so the tuning harness can run it on songs.
///
/// Safety: a rise of 0.3 or more counts as a flash, and there are never more than 3 a second (the
/// photosensitive-seizure guideline, as for the lights). Beyond that a beat only rises partway.
final class BeatPulse {
    /// This frame's amount, 0...1.
    private(set) var value: Float = 0
    /// How much the pulse is on at all: 1 while music plays, gliding to 0 when it stops (the screen goes back to
    /// normal in silence).
    private(set) var active: Float = 0
    /// Beats counted so far (for the tuning harness).
    private(set) var beats = 0

    static let maxFlashesPerSecond = 3
    static let flashSize: Float = 0.3

    private var armed = true
    private var cooldown: Float = 0
    private var beat: Float = 0          // the latest beat's height, fading
    private var amount: Float = 0        // the pulse before `active`
    private var low: Float = 0           // where the amount last bottomed out
    private var rises: [Double] = []     // times of the big rises in the last second
    private var clock: Double = 0
    private var typicalKick: Float = 0.12  // how hard this song's beats hit, lately
    private var hitPeak: Float = 0
    private var sinceBeat: Float = 1

    /// - Parameters:
    ///   - kick: how hard the latest bass hit is (the analyzer's `mid.kick`).
    ///   - intensity: the music's beat-driven intensity (the analyzer's `mid.pulse`).
    ///   - playing: sound is coming in.
    ///   - reduceMotion: macOS "Reduce motion": half-height beats that rise and fade slowly.
    ///   - tempo: the beat clock. While it's sure of the beat, beats come from the clock (on time, on every beat,
    ///     never on off-beat bass), and a kick right after one sets its height; otherwise from the kicks themselves.
    func frame(kick: Float, intensity: Float, playing: Bool, reduceMotion: Bool, dt: Double,
               tempo: BeatTracker? = nil) -> Float {
        clock += dt
        let dt = Float(dt)
        active += ((playing ? 1 : 0) - active) * (1 - exp(-dt / (playing ? 0.3 : 0.8)))

        // A beat: the bass jumps above its recent level, judged against this song's own recent beats (so a quiet
        // track and a pounding one both reach full height). Fires once per hit, on the way up, and follows the hit
        // to its peak.
        cooldown -= dt
        sinceBeat += dt
        let typical = max(0.03, typicalKick)
        if kick < max(0.015, 0.2 * typical) { armed = true }
        let peak: Float = reduceMotion ? 0.5 : 1
        if let tempo, tempo.confidence >= BeatTracker.sure {
            if playing, tempo.isBeat, cooldown <= 0 {
                cooldown = 0.2
                sinceBeat = 0
                hitPeak = 0
                beats += 1
                // A quiet beat until the kick shows how hard it is (a breakdown keeps a gentle pulse).
                beat = max(beat, (0.35 + 0.25 * min(1, intensity)) * peak)
            }
        } else if playing, armed, cooldown <= 0, kick > max(0.025, 0.3 * typical) {
            armed = false
            cooldown = 0.2
            sinceBeat = 0
            hitPeak = 0
            beats += 1
        }
        if sinceBeat < (tempo != nil ? 0.15 : 0.12) {
            hitPeak = max(hitPeak, kick)
            beat = max(beat, min(1, 0.85 * kick / typical) * peak)
        } else if hitPeak > 0 {
            typicalKick += (hitPeak - typicalKick) * 0.15   // about the last eight beats
            hitPeak = 0
        }
        beat *= exp(-dt / (reduceMotion ? 0.45 : 0.2))
        let goal = max(beat, playing ? min(0.3, intensity * 0.3) : 0)

        // Rise fast but not in a single frame, fall smoothly.
        let rate = goal > amount ? 1 - exp(-dt / (reduceMotion ? 0.12 : 0.03)) : 1 - exp(-dt / 0.08)
        var next = amount + (goal - amount) * rate
        low = min(low, next)
        if next - low >= Self.flashSize {
            rises.removeAll { clock - $0 > 1.05 }
            if rises.count >= Self.maxFlashesPerSecond {
                next = low + Self.flashSize - 0.01
            } else {
                rises.append(clock)
                low = next
            }
        }
        amount = next
        value = amount * active
        if value < 0.001 { value = 0 }
        return value
    }

    func reset() {
        value = 0; active = 0; beat = 0; amount = 0; low = 0; armed = true; cooldown = 0; rises.removeAll()
        typicalKick = 0.12; hitPeak = 0; sinceBeat = 1
    }
}
