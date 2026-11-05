import Foundation
import Metal

/// Sparks that fly out of the notch on bass hits. Distance is stored as a fraction of the way from
/// the notch to the screen edge (0...1), so one system serves every screen and "power" means the same everywhere.
final class SparkSystem {
    static let maxParticles = 96

    private struct Particle {
        var side: Float      // -1 = left of the notch, +1 = right
        var distance: Float  // 0 = at the notch, 1 = at the screen edge
        var y: Float         // 0 = bottom of the menu bar, 1 = top
        var life: Float      // 1 = just born, 0 = gone
        var speed: Float     // screen-halves per second
        var vy: Float        // heights per second
        var hue: Float
        var size: Float
        var decay: Float
    }

    private var particles: [Particle] = []
    private var cooldown: (left: Float, right: Float) = (0, 0)
    private var trickle: (left: Float, right: Float) = (0, 0)

    var isEmpty: Bool { particles.isEmpty }
    var count: Int { particles.count }

    /// `power` 0...1: how hard sparks are shot out. At 1 most beats reach the screen edges.
    func update(dt: Float, left: BandSet, right: BandSet, spawning: Bool, power: Float) {
        let drag = exp(-(1.4 - 0.8 * power) * dt)
        particles = particles.compactMap { particle in
            var p = particle
            p.distance += p.speed * dt
            p.speed *= drag
            p.y += p.vy * dt
            if p.y < 0.08 || p.y > 0.92 { p.vy = -p.vy; p.y = min(0.92, max(0.08, p.y)) }
            p.life -= p.decay * dt
            return p.life > 0 && p.distance < 1.05 ? p : nil
        }
        guard spawning else { return }
        spawn(side: -1, from: left, cooldown: &cooldown.left, trickle: &trickle.left, dt: dt, power: power)
        spawn(side: 1, from: right, cooldown: &cooldown.right, trickle: &trickle.right, dt: dt, power: power)
    }

    private func spawn(side: Float, from set: BandSet, cooldown: inout Float, trickle: inout Float,
                       dt: Float, power: Float) {
        cooldown -= dt
        var count = 0
        if set.kick > 0.06, cooldown <= 0 {
            count += Int(6 + set.kick * 60)   // a burst on every beat
            cooldown = 0.12
        }
        trickle += dt * 25 * set.pulse        // plus a few with general loudness
        while trickle >= 1 { count += 1; trickle -= 1 }

        for _ in 0..<count where particles.count < Self.maxParticles {
            particles.append(Particle(
                side: side,
                distance: .random(in: 0...0.004),
                y: .random(in: 0.2...0.8),
                life: 1,
                speed: .random(in: 0.25...0.9) * (0.6 + set.kick * 2) * (0.5 + power * 1.5),
                vy: .random(in: -0.6...0.6),
                hue: min(1, max(0, set.tone + .random(in: -0.25...0.25))),
                size: .random(in: 2.0...3.4),
                decay: .random(in: 0.6...1.1)))
        }
    }

    /// Two float4s per particle for the shader: (side, distance, y, life), (speed, vy, hue, size).
    func pack(into buffer: inout [SIMD4<Float>]) -> Int {
        let n = min(particles.count, Self.maxParticles)
        for i in 0..<n {
            let p = particles[i]
            buffer[i * 2] = SIMD4(p.side, p.distance, p.y, p.life)
            buffer[i * 2 + 1] = SIMD4(p.speed, p.vy, p.hue, p.size)
        }
        return n
    }
}

/// The last ~1000 frames of band levels, kept in a GPU texture for the Waterfall style.
/// One column per frame; rows are mid, left and right bands (`ShaderParam.maxBands` each).
final class SpectrumHistory {
    static let length = 1024
    static let rows = ShaderParam.maxBands * 3

    let texture: MTLTexture
    private(set) var index = 0
    private var column = [UInt8](repeating: 0, count: SpectrumHistory.rows)
    private var quietColumns = SpectrumHistory.length

    /// True once everything on screen has scrolled away.
    var isEmpty: Bool { quietColumns >= Self.length }

    init?(device: MTLDevice) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: Self.length, height: Self.rows, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let zeros = [UInt8](repeating: 0, count: Self.length * Self.rows)
        texture.replace(region: MTLRegionMake2D(0, 0, Self.length, Self.rows), mipmapLevel: 0,
                        withBytes: zeros, bytesPerRow: Self.length)
        self.texture = texture
    }

    func push(_ analyzer: SpectrumAnalyzer) {
        var loud = false
        for (channel, set) in [analyzer.mid, analyzer.left, analyzer.right].enumerated() {
            for i in 0..<ShaderParam.maxBands {
                let level = i < set.count ? set.levels[i] : 0
                column[channel * ShaderParam.maxBands + i] = UInt8(max(0, min(255, level * 255)))
                if level > 0.004 { loud = true }
            }
        }
        index = (index + 1) % Self.length
        texture.replace(region: MTLRegionMake2D(index, 0, 1, Self.rows), mipmapLevel: 0,
                        withBytes: column, bytesPerRow: 1)
        quietColumns = loud ? 0 : quietColumns + 1
    }
}
