import Foundation

// The light show: turns the music and Barbeat's colors into a color and brightness for every light.
// Foundation only, so scripts/tune-analyzer can run it offline on real songs.

/// How the lights move with the music.
enum LightMode: String, CaseIterable, Identifiable, Codable {
    case auto, pulse, stereo, bands, mirror
    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .pulse: return "Pulse"
        case .stereo: return "Stereo"
        case .bands: return "Bands"
        case .mirror: return "Mirror"
        }
    }

    var subtitle: String {
        switch self {
        case .auto: return "Barbeat picks for each device: Pulse for 1 light, Stereo for 2, Bands for 3–9, Mirror for strips."
        case .pulse: return "Every light pulses together with the beat, like the Pulse style."
        case .stereo: return "Lights on the left follow the left channel, lights on the right the right channel."
        case .bands: return "A room-sized EQ: bass on the left, treble on the right. Every kick also punches the whole room."
        case .mirror: return "Each light shows the menu bar at the same spot, so a strip becomes a copy of the bars."
        }
    }

    /// What Auto picks for this many lights.
    static func automatic(lightCount: Int) -> LightMode {
        switch lightCount {
        case ...1: return .pulse
        case 2: return .stereo
        case 3...9: return .bands
        default: return .mirror
        }
    }

    func resolved(lightCount: Int) -> LightMode {
        self == .auto ? .automatic(lightCount: lightCount) : self
    }
}

/// One light's output: a full-strength sRGB color plus how bright to show it (0...1, perceptual).
struct LightColor: Equatable {
    var r: Float, g: Float, b: Float
    var brightness: Float

    static let off = LightColor(r: 0, g: 0, b: 0, brightness: 0)
    static let white = LightColor(r: 1, g: 1, b: 1, brightness: 1)

    /// The color as it looks (color × brightness), still sRGB-encoded. For previews and RGB outputs.
    var shown: SIMD3<Float> { SIMD3(r, g, b) * brightness }

    var hex: String {
        let s = shown
        func byte(_ v: Float) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(s.x), byte(s.y), byte(s.z))
    }
}

/// One light Barbeat controls (a bulb, a Gradient segment or a pixel), placed from left (-1) to right (+1).
struct LightSlot: Equatable {
    var channel: Int
    var x: Double
    var y: Double = 0

    /// `count` lights spread evenly from left to right.
    static func row(_ count: Int, reversed: Bool = false) -> [LightSlot] {
        (0..<count).map { i in
            let t = count > 1 ? Double(i) / Double(count - 1) : 0.5
            return LightSlot(channel: i, x: (reversed ? 1 - t : t) * 2 - 1)
        }
    }
}

/// The colors Barbeat is drawing this frame, in a form the light show can use without AppKit.
struct LightPalette {
    var stops: [(t: Float, color: SIMD3<Float>)]
    /// True: colors go by frequency (bass = first color), like Neon. False: by loudness (quiet = first color), like Classic.
    var byFrequency: Bool
    /// Screen › Ambient light: the colors along the top of the screen, left to right.
    var ambient: [SIMD3<Float>]?

    static let neon = LightPalette(stops: [(0, SIMD3(0, 0.9, 1)), (0.5, SIMD3(0.55, 0.35, 1)), (1, SIMD3(1, 0.2, 0.75))],
                                   byFrequency: true, ambient: nil)

    func color(at t: Float) -> SIMD3<Float> {
        let t = min(1, max(0, t))
        guard var previous = stops.first else { return SIMD3(1, 1, 1) }
        for stop in stops.dropFirst() {
            if t <= stop.t {
                let span = stop.t - previous.t
                let f = span > 0 ? (t - previous.t) / span : 0
                return previous.color + (stop.color - previous.color) * f
            }
            previous = stop
        }
        return previous.color
    }

    /// Ambient light: the average screen color around `u` (0 = left edge, 1 = right edge).
    func ambient(at u: Float) -> SIMD3<Float>? {
        guard let ambient, !ambient.isEmpty else { return nil }
        let n = ambient.count
        let center = min(Float(n - 1), max(0, u * Float(n - 1)))
        let i0 = max(0, Int(center) - 2), i1 = min(n - 1, Int(center) + 2)
        var sum = SIMD3<Float>(repeating: 0)
        for i in i0...i1 { sum += ambient[i] }
        return sum / Float(i1 - i0 + 1)
    }
}

/// What the lights react to, copied from the analyzer once per frame.
struct LightSignals {
    struct Channel {
        /// Beat-driven intensity (the Pulse style's), 0...1.
        var pulse: Float = 0
        /// 0 = bassy ... 1 = bright.
        var tone: Float = 0.5
        /// How hard the latest bass hit was.
        var kick: Float = 0
        /// Bar heights, bass first, 0...1.
        var levels: [Float] = []
    }

    var mid = Channel(), left = Channel(), right = Channel()
    /// Seconds since anything was heard.
    var silence: Double = .infinity
    /// The menu bar splits left/right around the notch (Stereo layout), so Mirror does too.
    var stereoLayout = false
}

/// The light show for one device. Keeps a little state per light (envelopes, flashes) between frames.
final class LightShow {
    struct Options: Equatable {
        var mode: LightMode = .auto
        /// Lowest brightness while music plays, so the room never goes dark.
        var baseGlow: Float = 0.25
        /// How hard beats punch above the music's level.
        var beatFlash: Float = 0.6
        var maxBrightness: Float = 1
        /// macOS "Reduce motion": softer flashes.
        var reduceFlashing = false
    }

    /// The mode in use (what Auto picked).
    private(set) var mode: LightMode = .pulse

    private var count = 0
    private var rank: [Int] = []          // each slot's place from left to right
    private var spot: [Float] = []        // each slot's place from left (0) to right (1)
    private var sliceAverage: [Float] = []
    private var sliceCeiling: [Float] = []
    private var sliceFloor: [Float] = []
    private var envelope: [Float] = []
    private var flash: [Float] = []
    private var brightness: [Float] = []
    private var color: [SIMD3<Float>] = []
    private var lows: [Float] = []        // each light's brightness where it last bottomed out
    private var rises: [[Double]] = []    // times of each light's large flashes in the last second (safety cap)
    private var clock: Double = 0
    private var rest: Float = 1           // 0 = music playing, 1 = resting glow

    /// Never more than this many large flashes a second (the photosensitive-seizure guideline).
    static let maxFlashesPerSecond = 3
    /// How big a jump in brightness counts as a flash.
    static let flashSize: Float = 0.3
    /// How fast brightness may fall, per second. Stops lights from snapping fully off between beats.
    static let maxFall: Float = 2.6

    func frame(slots: [LightSlot], signals s: LightSignals, palette: LightPalette, options o: Options, dt: Double) -> [LightColor] {
        let n = slots.count
        guard n > 0 else { return [] }
        if n != count || spot.count != n { layout(slots) }
        mode = o.mode.resolved(lightCount: n)
        clock += dt
        let dtf = Float(dt)

        // Music stops: glide to a dim resting glow. It comes back the moment sound does.
        let restTarget: Float = s.silence > 1.2 ? 1 : 0
        rest += (restTarget - rest) * Float(1 - exp(-dt / (restTarget > rest ? 0.8 : 0.15)))

        let flashGain = o.beatFlash * (o.reduceFlashing ? 0.5 : 1)
        let maxFall = Self.maxFall * (o.reduceFlashing ? 0.6 : 1)
        let roomKick = min(1, s.mid.kick * 2.5)

        var out = [LightColor](repeating: .off, count: n)
        var drives = [Float](repeating: 0, count: n)
        var tones = [Float](repeating: 0.5, count: n)      // where the light sits in frequency (for by-frequency palettes)
        var hits = [Float](repeating: 0, count: n)
        var decays = [Float](repeating: 0.3, count: n)
        var smooth = [Bool](repeating: true, count: n)    // false: the drive is already smoothed (bars, pulse)

        switch mode {
        case .auto, .pulse:
            for i in 0..<n {
                drives[i] = s.mid.pulse
                tones[i] = s.mid.tone
                hits[i] = roomKick
                smooth[i] = false
            }
        case .stereo:
            for i in 0..<n {
                let u = spot[i]
                let channel = u < 0.42 ? s.left : (u > 0.58 ? s.right : s.mid)
                drives[i] = channel.pulse
                tones[i] = channel.tone
                hits[i] = min(1, channel.kick * 2.5)
                smooth[i] = false
            }
        case .bands:
            let slices = sliceLevels(s.mid.levels, count: n, dt: dtf)
            for i in 0..<n {
                let r = rank[i]
                let t: Float = n > 1 ? Float(r) / Float(n - 1) : 0
                drives[i] = slices[r].level
                tones[i] = t
                // Bass lights swell and fade slowly, treble lights sparkle; every light gets some of the kick.
                hits[i] = max(slices[r].hit, roomKick * 0.4)
                decays[i] = 0.45 + (0.12 - 0.45) * t
            }
        case .mirror:
            for i in 0..<n {
                let u = spot[i]
                let channel: LightSignals.Channel
                let p: Float
                if s.stereoLayout {
                    channel = u < 0.5 ? s.left : s.right
                    p = abs(u - 0.5) * 2   // bass at the center, like the bars around the notch
                } else {
                    channel = s.mid
                    p = u
                }
                drives[i] = Self.level(channel.levels, at: p)
                tones[i] = p
                hits[i] = roomKick * 0.25
                smooth[i] = false
            }
        }

        for i in 0..<n {
            // Body: follows the music, rising fast and fading at the light's own pace.
            let drive = drives[i] * (1 - rest)
            if !smooth[i] {
                envelope[i] = drive
            } else if drive > envelope[i] {
                envelope[i] += (drive - envelope[i]) * (1 - pow(0.3, dtf * 60))
            } else {
                envelope[i] = max(drive, envelope[i] - dtf / decays[i])
            }

            // Punch: beats kick the brightness up, then it fades quickly.
            flash[i] *= exp(-dtf / 0.14)
            flash[i] = max(flash[i], hits[i] * flashGain * (1 - rest))

            // Color: Barbeat's palette, by frequency or by loudness, or the screen next to the light.
            var target: SIMD3<Float>
            if let screen = palette.ambient(at: spot[i]) {
                target = screen
            } else if palette.byFrequency {
                target = palette.color(at: tones[i])
            } else {
                let intensity = mode == .pulse || mode == .stereo ? drives[i] : envelope[i]
                target = palette.color(at: intensity + (0.4 - intensity) * rest)
            }
            if color.count != n { color = Array(repeating: target, count: n) }
            color[i] += (target - color[i]) * (1 - pow(0.75, dtf * 60))
        }

        let floor = o.baseGlow * (0.7 + 0.3 * (1 - rest))
        for i in 0..<n {
            var b = floor + (1 - floor) * min(1, envelope[i] * 0.8 + flash[i] * 0.7)
            if b < brightness[i] { b = max(b, brightness[i] - maxFall * dtf) }
            // Safety: a large flash is a rise of 30 points or more from where the light last bottomed out.
            // A light gets at most 3 a second; beyond that it rises only partway.
            lows[i] = min(lows[i], b)
            if b - lows[i] >= Self.flashSize {
                rises[i].removeAll { clock - $0 > 1.05 }
                if rises[i].count >= Self.maxFlashesPerSecond {
                    b = lows[i] + Self.flashSize - 0.01
                } else {
                    rises[i].append(clock)
                    lows[i] = b
                }
            }
            brightness[i] = b
            let c = color[i]
            out[i] = LightColor(r: c.x, g: c.y, b: c.z, brightness: min(1, b) * o.maxBrightness)
        }
        return out
    }

    /// Orders the lights from left to right (ties go front to back), and spreads them over the whole width.
    private func layout(_ slots: [LightSlot]) {
        let n = slots.count
        count = n
        let order = slots.indices.sorted { a, b in
            slots[a].x != slots[b].x ? slots[a].x < slots[b].x : slots[a].y < slots[b].y
        }
        rank = Array(repeating: 0, count: n)
        for (r, i) in order.enumerated() { rank[i] = r }
        let xs = slots.map(\.x)
        let lo = xs.min() ?? -1, hi = xs.max() ?? 1
        spot = slots.map { hi - lo > 0.05 ? Float(($0.x - lo) / (hi - lo)) : 0.5 }
        sliceAverage = Array(repeating: 0, count: n)
        sliceCeiling = Array(repeating: 0.35, count: n)
        sliceFloor = Array(repeating: 0, count: n)
        lows = Array(repeating: 1, count: n)
        rises = Array(repeating: [], count: n)
        envelope = Array(repeating: 0, count: n)
        flash = Array(repeating: 0, count: n)
        brightness = Array(repeating: 0, count: n)
        color = []
    }

    /// Splits the bars into `count` frequency slices (bass first). Each slice keeps its own range (its recent
    /// quietest to loudest), so treble lights move as much as bass lights even under a steady wash of sound,
    /// and reports a "hit" when it jumps above its recent level.
    private func sliceLevels(_ levels: [Float], count: Int, dt: Float) -> [(level: Float, hit: Float)] {
        let bands = levels.count
        return (0..<count).map { k in
            guard bands > 0 else { return (0, 0) }
            let i0 = min(bands - 1, k * bands / count)
            let i1 = max(i0 + 1, min(bands, (k + 1) * bands / count))
            var sum: Float = 0, top: Float = 0
            for i in i0..<i1 { sum += levels[i]; top = max(top, levels[i]) }
            let value = 0.5 * sum / Float(i1 - i0) + 0.5 * top
            // Loudest: jumps up with hits, drifts down over several seconds.
            sliceCeiling[k] = max(0.3, max(value, sliceCeiling[k] - 0.06 * dt))
            // Quietest: drops right away, creeps back up over a few seconds.
            sliceFloor[k] = value < sliceFloor[k] ? value : sliceFloor[k] + (value - sliceFloor[k]) * (1 - pow(0.995, dt * 60))
            let span = max(0.2, sliceCeiling[k] - sliceFloor[k])
            let level = pow(min(1, max(0, (value - sliceFloor[k]) / span)), 1.2)
            let hit = min(1, max(0, (level - sliceAverage[k] - 0.05) * 3))
            sliceAverage[k] += (level - sliceAverage[k]) * (1 - pow(0.9, dt * 60))
            return (level, hit)
        }
    }

    /// A bar height at `p` (0 = bass ... 1 = treble), blended between neighbouring bars.
    static func level(_ levels: [Float], at p: Float) -> Float {
        guard levels.count > 1 else { return levels.first ?? 0 }
        let x = min(1, max(0, p)) * Float(levels.count - 1)
        let i = min(levels.count - 2, Int(x))
        let f = x - Float(i)
        return levels[i] * (1 - f) + levels[i + 1] * f
    }
}

extension LightSignals {
    /// Copies what the lights need from the analyzer (call on the render loop's thread).
    init(analyzer: SpectrumAnalyzer, silence: Double, stereoLayout: Bool) {
        func channel(_ set: BandSet) -> Channel {
            Channel(pulse: set.pulse, tone: set.tone, kick: set.kick, levels: set.levels)
        }
        self.init(mid: channel(analyzer.mid), left: channel(analyzer.left), right: channel(analyzer.right),
                  silence: silence, stereoLayout: stereoLayout)
    }
}
