import SwiftUI
import AppKit
import Combine
import Metal
import MetalKit
import CoreVideo
import ScreenCaptureKit
import os

// The kaleidoscope: a show mode that turns the screen into a kaleidoscope moving with the music. It captures the
// screen the pointer is on below the menu bar (everything but itself, so Barbeat's edge glow spins along), mirrors
// it into wedges on the GPU and draws that over the whole screen, menu bar included. Pointing at the top of the
// screen brings the menu bar back, as in a full-screen app. It stays on the desktop it started on (and rests while
// another one shows). Click anywhere or press Esc to stop.
// Its options are saved (`kaleidoscope.*`); whether it's running is not, so it never starts by itself.

/// What the kaleidoscope did, in the system log (Console, or `log show --predicate 'subsystem == "com.ia.MenuBarEQ"'`).
private let kaleidoscopeLog = Logger(subsystem: "com.ia.MenuBarEQ", category: "kaleidoscope")

/// The kaleidoscope's patterns.
enum KaleidoscopePattern: String, CaseIterable, Identifiable {
    case mirror, crystal, tunnel
    var id: String { rawValue }

    var title: String {
        switch self {
        case .mirror: return "Mirror"
        case .crystal: return "Crystal"
        case .tunnel: return "Tunnel"
        }
    }

    var help: String {
        switch self {
        case .mirror: return "The classic: mirrored wedges of your screen around the middle."
        case .crystal: return "The wedges folded again and again into a finer, crystal-like pattern."
        case .tunnel: return "The wedges become a tunnel that flows toward you, a step on every beat."
        }
    }
}

/// How the kaleidoscope's colors look.
enum KaleidoscopeColors: String, CaseIterable, Identifiable {
    case natural, vivid, barbeat
    var id: String { rawValue }

    var title: String {
        switch self {
        case .natural: return "Natural"
        case .vivid: return "Vivid"
        case .barbeat: return "Barbeat's colors"
        }
    }
}

/// The kaleidoscope's options, saved to UserDefaults as they change.
final class KaleidoscopeSettings: ObservableObject {
    static let shared = KaleidoscopeSettings()
    private let defaults = UserDefaults.standard

    @Published var pattern: KaleidoscopePattern { didSet { defaults.set(pattern.rawValue, forKey: Key.pattern) } }
    /// How many mirrored wedges make the circle.
    @Published var segments: Int { didSet { defaults.set(segments, forKey: Key.segments) } }
    @Published var colors: KaleidoscopeColors { didSet { defaults.set(colors.rawValue, forKey: Key.colors) } }
    /// A flower of the music's spectrum in Barbeat's colors, opening and closing with the sound.
    @Published var flower: Bool { didSet { defaults.set(flower, forKey: Key.flower) } }
    /// A soft glow around bright parts that swells on the beat.
    @Published var glow: Bool { didSet { defaults.set(glow, forKey: Key.glow) } }
    /// How fast it turns (with the tempo), 0...1.
    @Published var spin: Double { didSet { defaults.set(spin, forKey: Key.spin) } }
    /// How far it zooms in on each beat, 0...1.
    @Published var beatZoom: Double { didSet { defaults.set(beatZoom, forKey: Key.beatZoom) } }
    /// The middle of the pattern drifts slowly across the screen, so the picture keeps changing.
    @Published var wander: Bool { didSet { defaults.set(wander, forKey: Key.wander) } }

    static let segmentChoices = [6, 8, 10, 12]

    var summary: String { "\(pattern.title) · \(segments) mirrors" }

    private enum Key {
        static let segments = "kaleidoscope.segments", spin = "kaleidoscope.spin", beatZoom = "kaleidoscope.beatZoom"
        static let wander = "kaleidoscope.wander", pattern = "kaleidoscope.pattern", colors = "kaleidoscope.colors"
        static let flower = "kaleidoscope.flower", glow = "kaleidoscope.glow"
    }

    private init() {
        defaults.register(defaults: [
            Key.segments: 8, Key.spin: 0.5, Key.beatZoom: 0.5, Key.wander: true, Key.pattern: KaleidoscopePattern.crystal.rawValue,
            Key.colors: KaleidoscopeColors.vivid.rawValue, Key.flower: true, Key.glow: true,
        ])
        let saved = defaults.integer(forKey: Key.segments)
        segments = Self.segmentChoices.contains(saved) ? saved : 8
        spin = min(1, max(0, defaults.double(forKey: Key.spin)))
        beatZoom = min(1, max(0, defaults.double(forKey: Key.beatZoom)))
        wander = defaults.bool(forKey: Key.wander)
        pattern = KaleidoscopePattern(rawValue: defaults.string(forKey: Key.pattern) ?? "") ?? .crystal
        colors = KaleidoscopeColors(rawValue: defaults.string(forKey: Key.colors) ?? "") ?? .vivid
        flower = defaults.bool(forKey: Key.flower)
        glow = defaults.bool(forKey: Key.glow)
    }
}

// MARK: - Drawing

/// The kaleidoscope shader and its pipeline (compiled when first used).
final class KaleidoscopeRenderer {
    static let shared = KaleidoscopeRenderer()

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    /// The newest screen frame, copied with smaller and smaller versions of itself (for the glow).
    private var picture: MTLTexture?

    static let bandCount = 32

    /// What one frame needs. Matches `KParams` in the shader.
    struct Params {
        var aspect: Float = 1.6      // screen width / height
        var segments: Float = 8
        var rotation: Float = 0      // radians
        var zoom: Float = 1          // above 1 = closer
        var center: SIMD2<Float> = SIMD2(0.5, 0.5)   // where the pattern's middle sits in the captured picture (0...1)
        var sourceAspect: Float = 1.6
        var fade: Float = 1          // 0 = black, 1 = full
        var pattern: Float = 1       // 0 mirror, 1 crystal, 2 tunnel
        var time: Float = 0
        var beat: Float = 0          // the beat pulse, 0...1
        var vivid: Float = 1         // 0 natural, 1 vivid
        var tint: Float = 0          // how much of Barbeat's colors
        var flower: Float = 1
        var glow: Float = 1
        var travel: Float = 0        // how far the tunnel has flowed
        var fold: Float = 0          // the crystal's fold angle (moves with the music)
        var padding: Float = 0
    }

    /// Barbeat's colors (4) and the spectrum (32 bands, bass first), for the tint and the flower.
    struct Extras {
        var palette: [SIMD4<Float>] = Array(repeating: SIMD4(1, 1, 1, 1), count: 4)
        var bands: [Float] = Array(repeating: 0, count: KaleidoscopeRenderer.bandCount)
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct KOut { float4 position [[position]]; float2 uv; };
    struct KParams {
        float aspect; float segments; float rotation; float zoom; float2 center; float sourceAspect; float fade;
        float pattern; float time; float beat; float vivid; float tint; float flower; float glow; float travel;
        float fold; float padding;
    };

    vertex KOut kaleido_vertex(uint vid [[vertex_id]]) {
        // One triangle that covers the screen.
        float2 p = float2((vid << 1) & 2, vid & 2);
        KOut out;
        out.position = float4(p * 2.0 - 1.0, 0, 1);
        out.uv = float2(p.x, 1.0 - p.y);
        return out;
    }

    static float2 rotate(float2 p, float a) { float c = cos(a), s = sin(a); return float2(c * p.x - s * p.y, s * p.x + c * p.y); }

    static float3 paletteAt(constant float4 *palette, float t) {
        t = clamp(t, 0.0, 1.0) * 3.0;
        int i = min(int(t), 2);
        return mix(palette[i].rgb, palette[i + 1].rgb, t - float(i));
    }

    fragment float4 kaleido_fragment(KOut in [[stage_in]], texture2d<float> picture [[texture(0)]],
                                     constant KParams &p [[buffer(0)]], constant float4 *palette [[buffer(1)]],
                                     constant float *bands [[buffer(2)]]) {
        constexpr sampler s(address::mirrored_repeat, filter::linear, mip_filter::linear);
        // Around the middle of the screen, in screen heights.
        float2 q = in.uv - 0.5;
        q.x *= p.aspect;
        float r = length(q);
        float wedge = 2.0 * M_PI_F / p.segments;
        float a = atan2(q.y, q.x) + p.rotation;
        a = a - wedge * floor(a / wedge);          // into one wedge
        if (a > wedge * 0.5) a = wedge - a;        // every other wedge mirrored
        float across = a / (wedge * 0.5);          // 0 at one mirror, 1 at the other

        float2 k;
        if (p.pattern < 0.5) {
            // Mirror.
            k = float2(cos(a), sin(a)) * r / p.zoom;
        } else if (p.pattern < 1.5) {
            // Crystal: fold the wedge onto itself a few times, turning a little each time.
            k = float2(cos(a), sin(a)) * r / p.zoom * 1.6;
            for (int i = 0; i < 4; i++) {
                k = abs(k) - float2(0.22, 0.12);
                k = rotate(k, p.fold + 0.35 * float(i));
                k *= 1.12;
            }
            k *= 0.55;
        } else {
            // Tunnel: distance from the middle becomes depth, flowing outward.
            float depth = log(max(r, 0.002)) / p.zoom;
            k = float2(depth * 1.1 - p.travel, (across - 0.5) * 0.9);
        }
        // Back into the captured picture, around `center`, keeping its proportions.
        float2 uv = p.center + float2(k.x / p.sourceAspect, k.y);
        float3 c = picture.sample(s, uv).rgb;

        // Glow: a blurred copy (a smaller version of the frame) added on top, more on the beat.
        if (p.glow > 0) {
            float3 soft = picture.sample(s, uv, level(4.5)).rgb;
            c += soft * soft * p.glow * (0.45 + 0.6 * p.beat);
        }
        // Vivid: more saturated and a little more contrast.
        float l = dot(c, float3(0.2126, 0.7152, 0.0722));
        c = mix(float3(l), c, 1.0 + 0.7 * p.vivid);
        c = (c - 0.5) * (1.0 + 0.18 * p.vivid) + 0.5;
        // Barbeat's colors: the picture's light, colored by the palette in rings that drift outward.
        if (p.tint > 0) {
            float3 tinted = paletteAt(palette, fract(r * 0.9 - p.time * 0.05 + across * 0.25)) * (0.25 + 1.3 * l);
            c = mix(c, tinted, p.tint * 0.6);
        }
        // The flower: each wedge holds the spectrum, bass at the mirror line, treble at the other; each band's
        // petal edge sits further out the louder it is.
        if (p.flower > 0) {
            float x = across * 31.0;
            int b = min(int(x), 30);
            float level = mix(bands[b], bands[b + 1], x - float(b));
            float edge = 0.1 + 0.26 * level + 0.04 * p.beat;
            float d = r - edge;
            float rim = exp(-d * d / 0.0006) * (0.55 + level);
            float fill = (d < 0 ? 0.18 : 0.0) * level * smoothstep(0.0, 0.08, r);
            c += paletteAt(palette, across) * (rim + fill) * p.flower;
        }
        // A soft vignette keeps the eye in the middle.
        float2 corner = in.uv - 0.5;
        c *= 1.0 - 0.45 * smoothstep(0.35, 0.75, length(corner * float2(1.0, 1.0)));
        // Premultiplied: fading in and out shows the screen underneath.
        return float4(saturate(c) * p.fade, p.fade);
    }
    """

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: Self.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "kaleido_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "kaleido_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("Barbeat: kaleidoscope shader failed to compile: \(error)")
            return nil
        }
        self.device = device
        self.queue = queue
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    /// Takes a new screen frame: copies it (on the GPU) into a texture with smaller versions for the glow.
    func take(_ pixels: CVPixelBuffer, commands: MTLCommandBuffer) {
        guard let textureCache else { return }
        var made: CVMetalTexture?
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        guard CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixels, nil, .bgra8Unorm, width, height, 0, &made)
                == kCVReturnSuccess, let made, let frame = CVMetalTextureGetTexture(made) else { return }
        take(frame, commands: commands)
        commands.addCompletedHandler { _ in withExtendedLifetime(made) {} }
    }

    func take(_ frame: MTLTexture, commands: MTLCommandBuffer) {
        if picture?.width != frame.width || picture?.height != frame.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: frame.width,
                                                                      height: frame.height, mipmapped: true)
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .private
            picture = device.makeTexture(descriptor: descriptor)
        }
        guard let picture, let blit = commands.makeBlitCommandEncoder() else { return }
        blit.copy(from: frame, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: frame.width, height: frame.height, depth: 1),
                  to: picture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.generateMipmaps(for: picture)
        blit.endEncoding()
    }

    var hasPicture: Bool { picture != nil }
    /// Drops the last show's picture, so a new show doesn't start with it.
    func forget() { picture = nil }
    var pictureAspect: Float { picture.map { Float($0.width) / Float(max(1, $0.height)) } ?? 1.6 }

    /// Nothing (the screen shows through), until the first screen frame comes in.
    func clear(_ target: MTLTexture, commands: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        commands.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
    }

    func encode(into target: MTLTexture, params: Params, extras: Extras, commands: MTLCommandBuffer) {
        guard let picture else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        var params = params
        var palette = extras.palette
        var bands = extras.bands
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(picture, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        encoder.setFragmentBytes(&palette, length: MemoryLayout<SIMD4<Float>>.stride * 4, index: 1)
        encoder.setFragmentBytes(&bands, length: MemoryLayout<Float>.stride * Self.bandCount, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// `--kaleidoscope-image picture.png out.png [mirrors] [mirror|crystal|tunnel]`: the kaleidoscope of a picture,
    /// drawn offscreen (no screen capture or permission needed), at 1280 x 800, with a made-up spectrum and Neon's colors.
    static func writeSnapshot(from input: String, to output: String, segments: Int, pattern: KaleidoscopePattern) {
        guard let renderer = shared,
              let source = try? MTKTextureLoader(device: renderer.device).newTexture(
                URL: URL(fileURLWithPath: input), options: [.SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue]) else {
            print("kaleidoscope snapshot: couldn't read \(input)")
            return
        }
        let width = 1280, height = 800
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = renderer.device.makeTexture(descriptor: descriptor),
              let commands = renderer.queue.makeCommandBuffer() else { return }
        renderer.take(source, commands: commands)
        var params = Params()
        params.aspect = Float(width) / Float(height)
        params.sourceAspect = Float(source.width) / Float(source.height)
        params.segments = Float(segments)
        params.rotation = 0.3
        params.pattern = Float(KaleidoscopePattern.allCases.firstIndex(of: pattern) ?? 1)
        params.beat = 0.6
        params.fold = 0.4
        params.travel = 0.2
        var extras = Extras()
        let neon: [SIMD4<Float>] = [SIMD4(0, 0.9, 1, 1), SIMD4(0.3, 0.6, 1, 1), SIMD4(0.55, 0.35, 1, 1), SIMD4(1, 0.2, 0.75, 1)]
        extras.palette = neon
        extras.bands = (0..<bandCount).map { i in Float(0.9 * exp(-Double(i) / 12) + 0.25 * abs(sin(Double(i) * 0.7))) }
        renderer.encode(into: target, params: params, extras: extras, commands: commands)
        commands.commit()
        commands.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                           | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
        print("kaleidoscope snapshot: wrote \(output) (\(pattern.title), \(segments) mirrors, from \(source.width)x\(source.height))")
    }
}

/// The kaleidoscope's drawing surface.
private final class KaleidoscopeView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = KaleidoscopeRenderer.shared?.device
        layer.pixelFormat = .bgra8Unorm
        // Not opaque, to macOS: an app whose windows are all covered by an opaque window is told it's hidden, and
        // browsers then stop drawing video, which would freeze what the show (and Screen colors) sees. Every pixel
        // is drawn at full strength anyway, except while fading in and out.
        layer.isOpaque = false
        layer.backgroundColor = CGColor(gray: 0, alpha: 0)
        layer.framebufferOnly = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.maximumDrawableCount = 3
        return layer
    }

    var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    /// A click stops the show even when the window isn't the key one (after switching desktops, say).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let metalLayer else { return }
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: (newSize.width * scale).rounded(), height: (newSize.height * scale).rounded())
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        setFrameSize(frame.size)
    }
}

/// Covers one whole screen, menu bar included. Takes clicks and keys (so a click or Esc can stop the show).
private final class KaleidoscopeWindow: NSPanel {
    let view = KaleidoscopeView(frame: .zero)
    var onStop: (() -> Void)?
    /// Clicks right after starting don't count (the click that started it, or closing the panel).
    private let opened = CACurrentMediaTime()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false   // see KaleidoscopeView.makeBackingLayer
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        level = Self.coverLevel
        // Lives on the desktop it opens on (also one with an app in full screen), and slides away with it.
        collectionBehavior = [.managed, .ignoresCycle, .fullScreenAuxiliary]
        contentView = view
        setFrame(screen.frame, display: false)
    }

    /// Above apps, the Dock, the menu bar and all of Barbeat's other windows (menus still open over it).
    private static let coverLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    /// While the menu bar is in use: under it, still above apps, the Dock and Barbeat's edge glow.
    private static let underMenuBarLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 2)

    /// The pointer is at the top of the screen (or a menu is open): the menu bar shows over the kaleidoscope.
    var menuBarShowing = false {
        didSet {
            guard menuBarShowing != oldValue else { return }
            level = menuBarShowing ? Self.underMenuBarLevel : Self.coverLevel
        }
    }
    /// When the menu bar stops counting as in use (CACurrentMediaTime), after the pointer leaves it.
    var menuBarShowingUntil: CFTimeInterval = 0

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func mouseDown(with event: NSEvent) {
        if CACurrentMediaTime() - opened > 0.6 { onStop?() }
    }

    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onStop?() } else { super.keyDown(with: event) }   // Esc
    }

    override func cancelOperation(_ sender: Any?) { onStop?() }
}

/// Receives the screen's frames on its own queue and keeps the newest.
private final class KaleidoscopeCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.ia.Barbeat.kaleidoscope", qos: .userInteractive)
    private let lock = NSLock()
    private var newest: CVPixelBuffer?
    var onStop: ((Error) -> Void)?

    var latest: CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return newest
    }

    /// Captures `display` without `window` (the kaleidoscope itself) and without the top `topBand` points (the menu
    /// bar, or the band where it would be), at half the screen's pixels.
    /// The window only shows up in macOS's list a moment after it opens, so this asks a few times.
    func start(display: CGDirectDisplayID, without window: CGWindowID, topBand: CGFloat, frameRate: Int, attempt: Int = 0) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let content, let scDisplay = content.displays.first(where: { $0.displayID == display }) else {
                    self.onStop?(error ?? NSError(domain: "Barbeat", code: 1,
                                                  userInfo: [NSLocalizedDescriptionKey: "That screen isn't available."]))
                    return
                }
                let mine = content.windows.first(where: { $0.windowID == window })
                if mine == nil, attempt < 5 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.start(display: display, without: window, topBand: topBand, frameRate: frameRate,
                                   attempt: attempt + 1)
                    }
                    return
                }
                let filter: SCContentFilter
                if let mine {
                    filter = SCContentFilter(display: scDisplay, excludingWindows: [mine])
                    if CommandLine.arguments.contains("--verbose") { print("kaleidoscope: capturing everything but itself") }
                } else {
                    if CommandLine.arguments.contains("--verbose") { print("kaleidoscope: capturing everything but Barbeat") }
                    // Not listed yet: leave out all of Barbeat instead (its own visuals then don't show in the pattern).
                    let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                    filter = SCContentFilter(display: scDisplay, excludingApplications: me, exceptingWindows: [])
                }
                let config = SCStreamConfiguration()
                let scale = NSScreen.screens.first { $0.displayID == display }?.backingScaleFactor ?? 1
                // The menu bar stays out of the picture (in display points, measured from the top).
                let band = min(max(0, topBand), CGFloat(scDisplay.height) / 4)
                let source = CGRect(x: 0, y: band, width: CGFloat(scDisplay.width), height: CGFloat(scDisplay.height) - band)
                config.sourceRect = source
                config.width = max(64, Int(source.width * scale / 2))
                config.height = max(64, Int(source.height * scale / 2))
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.colorSpaceName = CGColorSpace.sRGB
                config.showsCursor = false
                config.queueDepth = 4
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                do {
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                } catch {
                    self.onStop?(error)
                    return
                }
                self.stream = stream
                stream.startCapture { [weak self] error in
                    guard let error else { return }
                    DispatchQueue.main.async { self?.onStop?(error) }
                }
            }
        }
    }

    func stop() {
        let stream = self.stream
        stream?.stopCapture { _ in withExtendedLifetime(stream) {} }
        self.stream = nil
        lock.lock(); newest = nil; lock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Frames only come when something changed; "idle" ones carry no picture, so the last one stays.
        guard type == .screen, sampleBuffer.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = sampleBuffer.imageBuffer else { return }
        lock.lock(); let first = newest == nil; newest = pixels; lock.unlock()
        if first, CommandLine.arguments.contains("--verbose") {
            print("kaleidoscope: first screen frame \(CVPixelBufferGetWidth(pixels))x\(CVPixelBufferGetHeight(pixels))")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onStop?(error) }
    }
}

// MARK: - Drawing off the main thread

/// Draws the kaleidoscope on its own queue. Waiting for the screen to take a frame can stall (for up to a second
/// while macOS switches desktops), and that must never hold up the rest of Barbeat: while a frame is still being
/// drawn (or waiting for a drawable), the next one is skipped.
private final class KaleidoscopeDrawer {
    private let queue = DispatchQueue(label: "com.ia.Barbeat.kaleidoscope.draw", qos: .userInteractive)
    private let lock = NSLock()
    private var busy = false
    /// The last screen frame handed to the renderer (only touched on `queue`).
    private var takenFrame: CVPixelBuffer?
    /// Called on the main thread when the screen kept a frame waiting (seconds waited).
    var onStall: ((Double) -> Void)?

    /// Starts drawing one frame, unless the last one is still on its way. Returns false if it skipped.
    @discardableResult
    func draw(into layer: CAMetalLayer, pixels: CVPixelBuffer?, params: KaleidoscopeRenderer.Params,
              extras: KaleidoscopeRenderer.Extras) -> Bool {
        lock.lock()
        if busy { lock.unlock(); return false }
        busy = true
        lock.unlock()
        queue.async { [self] in
            defer { lock.lock(); busy = false; lock.unlock() }
            guard let renderer = KaleidoscopeRenderer.shared, let commands = renderer.queue.makeCommandBuffer() else { return }
            var params = params
            if let pixels, pixels !== takenFrame {
                takenFrame = pixels
                renderer.take(pixels, commands: commands)
            }
            params.sourceAspect = renderer.pictureAspect
            let asked = CACurrentMediaTime()
            let drawable = layer.nextDrawable()
            let waited = CACurrentMediaTime() - asked
            if waited > 0.2 {
                DispatchQueue.main.async { [weak self] in self?.onStall?(waited) }
            }
            guard let drawable else {
                commands.commit()
                return
            }
            if renderer.hasPicture {
                renderer.encode(into: drawable.texture, params: params, extras: extras, commands: commands)
            } else {
                renderer.clear(drawable.texture, commands: commands)
            }
            commands.present(drawable)
            commands.commit()
        }
        return true
    }

    /// Before a new show: forget the last show's pictures.
    func reset() {
        queue.async { [self] in
            takenFrame = nil
            KaleidoscopeRenderer.shared?.forget()
        }
    }
}

// MARK: - The show

/// Starts and stops the kaleidoscope, and draws it every frame from the render loop.
final class KaleidoscopeController: ObservableObject {
    static let shared = KaleidoscopeController()

    @Published private(set) var running = false
    /// Why the last start didn't work, for the Settings page (nil when fine).
    @Published private(set) var problem: String?
    /// Called when `running` changes (the render loop runs while the kaleidoscope does).
    var onRunningChange: (() -> Void)?

    private let settings = KaleidoscopeSettings.shared
    private var window: KaleidoscopeWindow?
    private var capture: KaleidoscopeCapture?
    private let drawer = KaleidoscopeDrawer()
    private let beat = BeatPulse()
    private var params = KaleidoscopeRenderer.Params()
    private var clock: Double = 0
    private var silence: Double = .infinity
    private var stopping = false
    private var extras = KaleidoscopeRenderer.Extras()
    private let verbose = CommandLine.arguments.contains("--verbose")
    private var lastLog: Double = 0
    private var frames = 0
    private var skipped = 0
    /// The display the show is on, and how tall its menu bar (or the band where it would be) is, in points.
    private var displayID: CGDirectDisplayID = 0
    private var topBand: CGFloat = 0
    /// When the screen capture last broke (it's restarted a few times before the show gives up).
    private var captureFailures: [CFTimeInterval] = []
    private var lastMenuCheck: CFTimeInterval = 0
    private var spaceObserver: NSObjectProtocol?
    /// Whether the show's desktop is the one showing. On another one it rests: no capture, no drawing.
    private var onItsDesktop = true
    private var lastDesktopCheck: CFTimeInterval = 0
    /// Set by the render loop: on battery the screen is captured at 30 frames a second instead of 60.
    var onBattery = false

    private init() {
        drawer.onStall = { [weak self] waited in self?.stalled(waited: waited) }
    }

    /// Starts the show on the screen the pointer is on. Asks for Screen Recording first if needed.
    func start() {
        guard !running else { return }
        guard KaleidoscopeRenderer.shared != nil else {
            problem = "This Mac's graphics couldn't start the kaleidoscope."
            return
        }
        if !CGPreflightScreenCaptureAccess() {
            let alert = NSAlert()
            alert.messageText = "Let Barbeat see your screen for the kaleidoscope?"
            alert.informativeText = """
                The kaleidoscope mirrors what's on your screen, so Barbeat needs to see it. Each frame goes straight to the graphics chip and is thrown away: nothing is recorded, saved or sent.

                Next, macOS asks you to allow Barbeat under Screen & System Audio Recording. Then start the kaleidoscope again.
                """
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Not Now")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { CGRequestScreenCaptureAccess() }
            problem = CGPreflightScreenCaptureAccess() ? nil : "Barbeat needs Screen Recording for the kaleidoscope."
            return
        }
        problem = nil
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.screens.first
        else { return }

        // Close the menu bar panel if it's open, so the click that closes it doesn't stop the show.
        NSApp.windows.filter { $0.isVisible && $0.className.contains("MenuBarExtra") }.forEach { $0.orderOut(nil) }

        displayID = screen.displayID
        // The menu bar's height here; without one (it hides itself, or an app is in full screen) the band around the
        // notch, and at least a standard menu bar's height, since the menu bar can still slide in.
        topBand = max(OverlayWindow.menuBarHeight(on: screen) ?? 0, screen.safeAreaInsets.top.rounded(.up),
                      NSStatusBar.system.thickness)
        params = KaleidoscopeRenderer.Params()
        params.aspect = Float(screen.frame.width / max(1, screen.frame.height))
        params.sourceAspect = params.aspect
        params.fade = 0
        beat.reset()
        drawer.reset()
        clock = 0
        frames = 0
        skipped = 0
        captureFailures = []
        stopping = false
        onItsDesktop = true
        NSApp.activate(ignoringOtherApps: true)
        openWindow(on: screen)
        startCapture()
        // Switching desktops: keep the show in front and the keys coming to it (another app becomes active there).
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.spaceChanged()
        }
        running = true
        onRunningChange?()
        kaleidoscopeLog.notice("started on display \(self.displayID, privacy: .public), menu bar band \(Double(self.topBand), privacy: .public) pt")
        if verbose { print("kaleidoscope: started on display \(screen.displayID), \(settings.segments) mirrors, menu bar band \(topBand) pt") }
    }

    /// Fades out, then closes.
    func stop() {
        guard running, !stopping else { return }
        stopping = true
    }

    private func openWindow(on screen: NSScreen) {
        let window = KaleidoscopeWindow(screen: screen)
        window.onStop = { [weak self] in self?.stop() }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func startCapture() {
        guard let window else { return }
        capture?.stop()
        let capture = KaleidoscopeCapture()
        capture.onStop = { [weak self, weak capture] error in
            guard let self, let capture, capture === self.capture else { return }
            self.captureBroke(error)
        }
        self.capture = capture
        capture.start(display: displayID, without: CGWindowID(window.windowNumber), topBand: topBand,
                      frameRate: onBattery ? 30 : 60)
    }

    /// The screen capture stopped by itself: start it again, unless it keeps breaking.
    private func captureBroke(_ error: Error) {
        guard running, !stopping, onItsDesktop else { return }
        let now = CACurrentMediaTime()
        captureFailures = captureFailures.filter { now - $0 < 10 } + [now]
        kaleidoscopeLog.error("screen capture stopped (\(self.captureFailures.count, privacy: .public) in 10 s): \(error.localizedDescription, privacy: .public)")
        if verbose { print("kaleidoscope: screen capture stopped: \(error.localizedDescription)") }
        guard captureFailures.count <= 3 else {
            problem = "The screen capture stopped: \(error.localizedDescription)"
            finish()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.running, !self.stopping, self.onItsDesktop else { return }
            self.startCapture()
        }
    }

    /// Another desktop: the show stays on its own one. While another shows, it rests (no capture, no drawing);
    /// back on its desktop it captures again and takes the keys (Esc). Barbeat isn't made the active app here,
    /// which could pull you to another desktop.
    private func spaceChanged() {
        guard running, let window else { return }
        lastDesktopCheck = CACurrentMediaTime()
        let here = window.isOnActiveSpace
        guard here != onItsDesktop else { return }
        onItsDesktop = here
        kaleidoscopeLog.notice("\(here ? "back on its desktop" : "another desktop: resting", privacy: .public)")
        if verbose { print("kaleidoscope: \(here ? "back on its desktop" : "another desktop: resting")") }
        if here {
            startCapture()
            window.makeKey()
        } else {
            capture?.stop()
            capture = nil
        }
    }

    /// The screen kept a frame waiting: macOS holds the frames while it switches desktops. The show skips frames
    /// meanwhile and carries on by itself; this only notes it.
    private func stalled(waited: Double) {
        guard running else { return }
        kaleidoscopeLog.notice("the screen held its frames for \(waited, format: .fixed(precision: 2), privacy: .public) s")
        if verbose { print(String(format: "kaleidoscope: the screen held its frames for %.2f s", waited)) }
    }

    /// Like a full-screen app: pointing at the top of the screen brings the menu bar back; it goes again once the
    /// pointer leaves it and no menu is open.
    private func updateMenuBar(_ window: KaleidoscopeWindow, now: CFTimeInterval) {
        let pointer = NSEvent.mouseLocation, f = window.frame
        let inBar = pointer.x >= f.minX && pointer.x <= f.maxX && pointer.y <= f.maxY + 1 && pointer.y >= f.maxY - topBand - 2
        if inBar && (window.menuBarShowing || pointer.y >= f.maxY - 2) {
            window.menuBarShowingUntil = now + 0.6
        } else if now < window.menuBarShowingUntil, now - lastMenuCheck > 0.25 {
            // Still showing: keep it while a menu or Barbeat's panel is open (looked up a few times a second).
            lastMenuCheck = now
            let panelOpen = NSApp.windows.contains { $0.isVisible && $0.className.contains("MenuBarExtra") }
            if panelOpen || OverlayWindow.otherAppMenuIsOpen() { window.menuBarShowingUntil = now + 0.5 }
        }
        window.menuBarShowing = now < window.menuBarShowingUntil
    }

    /// Every frame from the render loop: moves the pattern with the music and draws it.
    func tick(analyzer: SpectrumAnalyzer, sound: Float, colors: FrameColors, tempo: BeatTracker, dt: Double) {
        guard running, let window, KaleidoscopeRenderer.shared != nil else { return }
        // Now and then, look whether its desktop is showing (in case a desktop switch went unannounced).
        let now = CACurrentMediaTime()
        if now - lastDesktopCheck > 1 { spaceChanged() }
        guard onItsDesktop else {
            // Stopped from another desktop: nothing to fade, it isn't showing.
            if stopping { finish() }
            return
        }
        clock += dt
        silence = sound > 0.0005 ? 0 : silence + dt
        let playing = silence < 1.2
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let value = beat.frame(kick: analyzer.mid.kick, intensity: analyzer.mid.pulse, playing: playing,
                               reduceMotion: reduceMotion, dt: dt, tempo: tempo)
        let dtf = Float(dt), t = Float(clock)
        let loud = min(1, analyzer.mid.pulse)

        // Fade in at the start (half a second) and out when stopping (a third of one).
        params.fade = stopping ? max(0, params.fade - dtf * 3) : min(1, params.fade + dtf * 2)
        if stopping, params.fade <= 0 {
            finish()
            return
        }
        updateMenuBar(window, now: CACurrentMediaTime())
        // Turning: with a steady tempo, one wedge every bar (four beats) at the middle setting, a bit faster when
        // the music is loud; without one, a slow drift that speeds up with the music.
        let spin = Float(settings.spin) * (reduceMotion ? 0.3 : 1)
        let wedge = 2 * Float.pi / Float(settings.segments)
        let speed: Float = tempo.confidence >= BeatTracker.sure && tempo.bpm > 0
            ? wedge / (4 * 60 / tempo.bpm) * spin * 2 * (0.6 + 0.6 * loud)
            : spin * (0.08 + 0.7 * loud)
        params.rotation = (params.rotation + dtf * speed).truncatingRemainder(dividingBy: 2 * .pi)
        // Beats zoom in a little, push the tunnel on and bend the crystal.
        let zoomTarget = 1 + (reduceMotion ? 0 : Float(settings.beatZoom) * 0.24 * value)
        params.zoom += (zoomTarget - params.zoom) * min(1, dtf * 14)
        params.travel += dtf * (0.04 + 0.9 * value * (reduceMotion ? 0.3 : 1)) * (0.3 + Float(settings.spin))
        params.travel = params.travel.truncatingRemainder(dividingBy: 1000)
        params.fold = 0.35 + 0.25 * sin(t * 0.11) + 0.12 * value
        params.segments = Float(settings.segments)
        params.pattern = Float(KaleidoscopePattern.allCases.firstIndex(of: settings.pattern) ?? 1)
        params.time = t
        params.beat = value
        params.vivid = settings.colors == .natural ? 0 : 1
        params.tint = settings.colors == .barbeat ? 1 : 0
        params.flower = settings.flower ? 1 : 0
        params.glow = settings.glow ? 1 : 0
        if settings.wander {
            params.center = SIMD2(0.5 + 0.22 * sin(t * 0.071) * cos(t * 0.023), 0.5 + 0.18 * sin(t * 0.053 + 1.3))
        } else {
            params.center += (SIMD2(0.5, 0.5) - params.center) * min(1, dtf * 2)
        }

        // Barbeat's colors and the spectrum (32 bands: quick to open, slower to close).
        for (i, u) in [0, 1.0 / 3, 2.0 / 3, 1].enumerated() {
            let c = colors.gradient.color(at: CGFloat(u))
            extras.palette[i] = SIMD4(Float(c.r), Float(c.g), Float(c.b), 1)
        }
        let levels = analyzer.mid.levels
        let count = KaleidoscopeRenderer.bandCount
        for i in 0..<count {
            var level: Float = 0
            if !levels.isEmpty {
                let from = i * levels.count / count, to = max(from + 1, (i + 1) * levels.count / count)
                level = levels[from..<min(to, levels.count)].max() ?? 0
            }
            let old = extras.bands[i]
            extras.bands[i] = old + (level - old) * (level > old ? 0.6 : 0.15)
        }

        guard let metalLayer = window.view.metalLayer else { return }
        if drawer.draw(into: metalLayer, pixels: capture?.latest, params: params, extras: extras) {
            frames += 1
        } else {
            skipped += 1
        }
        if verbose, clock - lastLog >= 1 {
            lastLog = clock
            print(String(format: "kaleidoscope: %d frames (%d skipped), %@, beat %.2f, zoom %.3f, tempo %.1f BPM (sure %.2f), beats %d%@",
                         frames, skipped, settings.pattern.rawValue, value, params.zoom, tempo.bpm, tempo.confidence, beat.beats,
                         window.menuBarShowing ? ", menu bar showing" : ""))
        }
    }

    /// Takes everything down at once.
    private func finish() {
        capture?.stop()
        capture = nil
        window?.orderOut(nil)
        window = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        stopping = false
        guard running else { return }
        running = false
        onRunningChange?()
        kaleidoscopeLog.notice("stopped after \(self.frames, privacy: .public) frames (\(self.skipped, privacy: .public) skipped)")
        if verbose { print("kaleidoscope: stopped after \(frames) frames, \(skipped) skipped") }
    }
}

// MARK: - The panel row

/// The Kaleidoscope row in the menu bar panel.
struct KaleidoscopeRow: View {
    @ObservedObject var controller: KaleidoscopeController
    @ObservedObject var settings: KaleidoscopeSettings

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.hexagongrid")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(controller.running ? Color.accentColor : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("Kaleidoscope").font(.callout)
                Text(controller.running ? "Click anywhere or press Esc to stop" : "Show mode · \(settings.summary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("Options…") { SettingsWindow.show(.kaleidoscope) }
                .controlSize(.small)
            Button(controller.running ? "Stop" : "Start") {
                controller.running ? controller.stop() : controller.start()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .help("Turns your screen into a kaleidoscope that moves with the music")
    }
}

// MARK: - The Settings page

struct KaleidoscopePage: View {
    @ObservedObject var settings: KaleidoscopeSettings
    @ObservedObject var controller: KaleidoscopeController

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Button(controller.running ? "Stop" : "Start Kaleidoscope") {
                    controller.running ? controller.stop() : controller.start()
                }
                .controlSize(.large)
                Text("Click anywhere or press Esc to stop.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                if controller.running { TempoBadge() }
            }
            if let problem = controller.problem {
                Text(problem).font(.callout).foregroundStyle(.orange)
            }
            SettingsSection("Pattern", caption: settings.pattern.help) {
                Picker("Pattern", selection: $settings.pattern) {
                    ForEach(KaleidoscopePattern.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            SettingsSection("Colors") {
                Picker("Colors", selection: $settings.colors) {
                    ForEach(KaleidoscopeColors.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Toggle("Music flower: the spectrum in Barbeat's colors, opening with the sound", isOn: $settings.flower)
                    .toggleStyle(.checkbox)
                Toggle("Glow that swells on the beat", isOn: $settings.glow)
                    .toggleStyle(.checkbox)
            }
            SettingsSection("Mirrors", caption: "How many mirrored wedges make the circle.") {
                Picker("Mirrors", selection: $settings.segments) {
                    ForEach(KaleidoscopeSettings.segmentChoices, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            SettingsSection("Motion", caption: "It follows the music's tempo: at the middle setting it turns one wedge every bar, and every beat zooms in a little (and pushes the tunnel on).") {
                SettingsSlider("Turning", value: $settings.spin, in: 0...1, text: "\(Int((settings.spin * 100).rounded()))%")
                SettingsSlider("Beat zoom", value: $settings.beatZoom, in: 0...1,
                               text: "\(Int((settings.beatZoom * 100).rounded()))%")
                Toggle("Wander slowly across the screen", isOn: $settings.wander)
                    .toggleStyle(.checkbox)
                    .help("The middle of the pattern drifts over your screen, so the picture keeps changing.")
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                note("It covers the whole screen the pointer is on, menu bar included. Point at the top of the screen to bring the menu bar back. Barbeat's edge glow is mirrored in too.")
                note("It stays on the desktop you start it on. Other desktops look as usual, and the show picks up again when you come back.")
                note("Barbeat needs Screen Recording (the same permission as Screen colors). Frames go straight to the graphics chip and are thrown away: nothing is recorded, saved or sent. Copy-protected video shows as black.")
                note("With Reduce motion on it turns slowly and doesn't zoom.")
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
