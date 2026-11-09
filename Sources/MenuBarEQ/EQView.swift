import AppKit
import Metal
import QuartzCore

/// Compiles the shader once and holds the GPU objects every overlay shares.
final class MetalRenderer {
    static let shared = MetalRenderer()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    /// Band history for the Waterfall style, shared by every overlay.
    let history: SpectrumHistory
    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let history = SpectrumHistory(device: device) else { return nil }
        do {
            let library = try device.makeLibrary(source: Shaders.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "eq_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "eq_fragment")
            descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("Barbeat: shader failed to compile: \(error)")
            return nil
        }
        self.device = device
        self.queue = queue
        self.history = history
    }
}

/// Draws the visuals on the GPU: into the menu bar strip, or along one screen edge.
final class EQView: NSView {
    weak var analyzer: SpectrumAnalyzer?
    weak var sparks: SparkSystem?
    /// 0 = menu bar strip; 1 left, 2 right, 3 bottom, 4 top screen-edge glow.
    let edge: Int
    /// Horizontal span hidden by the camera notch, in view coordinates. Nil on screens without one.
    var notch: ClosedRange<CGFloat>?
    /// Edge glow: the length of each side's run of bands in points (side window plus top corner); 0 = own height.
    var edgeRun: CGFloat = 0
    private let settings: Settings
    private var params = [Float](repeating: 0, count: ShaderParam.count)
    private var bands = [Float](repeating: 0, count: ShaderParam.bandBufferCount)
    private var particles = [SIMD4<Float>](repeating: .zero, count: SparkSystem.maxParticles * 2)
    /// Ambient light: the screen's colors along each edge.
    private var ambient = [SIMD4<Float>](repeating: .zero, count: ShaderParam.ambientCount)
    /// This frame's colors (the palette with drift applied), shared by the shader and the pulse colors.
    private var gradient = ResolvedGradient(palette: .neon, drift: .off, time: 0)

    init(settings: Settings, edge: Int = 0) {
        self.settings = settings
        self.edge = edge
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { false }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = MetalRenderer.shared?.device
        layer.pixelFormat = MetalRenderer.pixelFormat
        layer.isOpaque = false
        layer.framebufferOnly = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.maximumDrawableCount = 3
        return layer
    }

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }
    private var scale: CGFloat { Self.snapshotScale ?? window?.backingScaleFactor ?? 2 }
    /// `--snapshot-scale 2` draws at that pixel density whatever the screen's (for sharp pictures from a 1× screen).
    private static let snapshotScale: CGFloat? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot-scale"), i + 1 < args.count, let value = Double(args[i + 1]) else { return nil }
        return CGFloat(value)
    }()

    /// Bar columns per band. The analyzer has at most 128 bands, so on a screen wider than 16:9 (a 32:9 ultrawide,
    /// say) each bar would stretch: there, bars keep the width they'd have on a 16:9 screen of the same height,
    /// and the shader fills the extra columns with levels in between the bands.
    private var barColumns: CGFloat {
        if let forced = Self.forcedBarColumns { return forced }
        guard let screen = window?.screen?.frame, screen.height > 0 else { return 1 }
        return max(1, (screen.width / screen.height) / (16.0 / 9.0))
    }
    /// `--bar-columns 2` acts as if the screen were that much wider than 16:9 (to test in-between bars on any screen).
    private static let forcedBarColumns: CGFloat? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--bar-columns"), i + 1 < args.count, let value = Double(args[i + 1]) else { return nil }
        return CGFloat(max(1, min(8, value)))
    }()

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        guard let metalLayer else { return }
        metalLayer.contentsScale = scale
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        if size.width > 0, size.height > 0, metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
        }
        render()
    }

    /// Draws one frame. Called by the render loop and whenever settings change.
    func render() {
        guard let renderer = MetalRenderer.shared, let metalLayer, prepareFrame(),
              metalLayer.drawableSize.width > 0, let drawable = metalLayer.nextDrawable(),
              let commands = renderer.queue.makeCommandBuffer() else { return }
        encode(into: drawable.texture, commands: commands, renderer: renderer)
        commands.present(drawable)
        commands.commit()
    }

    /// Renders the current frame offscreen and returns it as an image (for `--snapshot`).
    func snapshotImage() -> CGImage? {
        guard let renderer = MetalRenderer.shared, prepareFrame() else { return nil }
        let width = Int((bounds.width * scale).rounded()), height = Int((bounds.height * scale).rounded())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalRenderer.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = renderer.device.hasUnifiedMemory ? .shared : .managed
        guard let texture = renderer.device.makeTexture(descriptor: descriptor),
              let commands = renderer.queue.makeCommandBuffer() else { return nil }
        encode(into: texture, commands: commands, renderer: renderer)
        if texture.storageMode == .managed, let blit = commands.makeBlitCommandEncoder() {
            blit.synchronize(resource: texture)
            blit.endEncoding()
        }
        commands.commit()
        commands.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                                | CGImageAlphaInfo.premultipliedFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private func encode(into texture: MTLTexture, commands: MTLCommandBuffer, renderer: MetalRenderer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        let stops = gradient.stops.map { SIMD4<Float>(Float($0.1.r), Float($0.1.g), Float($0.1.b), Float($0.0)) }
        encoder.setRenderPipelineState(renderer.pipeline)
        params.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        bands.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        stops.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
        particles.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 3) }
        if let analyzer {
            analyzer.scope.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 4) }
        }
        ambient.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 5) }
        encoder.setFragmentTexture(renderer.history.texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    // MARK: - Per-frame parameters

    /// Fills `params` and `bands` from the analyzer and settings. Returns false if there's nothing to draw.
    private func prepareFrame() -> Bool {
        guard let analyzer, bounds.width > 0, bounds.height > 0 else { return false }
        let style = settings.style
        let colors = FrameColors.current(settings: settings, display: window?.screen?.displayID, time: CACurrentMediaTime())
        gradient = colors.gradient
        let ambientColors = colors.ambient
        let palette = gradient
        let stereo = edge > 0 || style.alwaysStereo || settings.layout == .stereo
        let height = bounds.height, width = bounds.width, scale = self.scale
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        func set(_ index: Int, _ value: CGFloat) { params[index] = Float(value) }

        set(ShaderParam.width, width)
        set(ShaderParam.height, height)
        set(ShaderParam.scale, scale)
        set(ShaderParam.style, CGFloat(style.shaderIndex))
        set(ShaderParam.showPeaks, settings.showPeaks ? 1 : 0)
        set(ShaderParam.axis, palette.axis == .vertical ? 0 : 1)
        set(ShaderParam.stopCount, CGFloat(gradient.stops.count))
        set(ShaderParam.stereo, stereo ? 1 : 0)
        set(ShaderParam.brightness, settings.brightness)
        set(ShaderParam.edgeMode, CGFloat(edge))
        set(ShaderParam.edgeThickness, edge >= 3 ? height : min(width, height))
        set(ShaderParam.edgeRun, edgeRun)
        set(ShaderParam.textGuard, edge == 0 && settings.readableMenuBar ? (MenuBarText.isLight ? 1 : 2) : 0)
        set(ShaderParam.edgeBands, CGFloat(min(analyzer.left.count, ShaderParam.maxBands)))
        set(ShaderParam.barColumns, barColumns)
        // Voice: the menu bar strip and the edge glow each follow their own "Show on" switch.
        let voice = VoiceFrame.current, voiceSettings = VoiceSettings.shared
        let voiceHere = edge == 0 ? voiceSettings.onMenuBar : voiceSettings.onEdgeGlow
        set(ShaderParam.voiceColor, voice.color.r)
        set(ShaderParam.voiceColor + 1, voice.color.g)
        set(ShaderParam.voiceColor + 2, voice.color.b)
        set(ShaderParam.voiceTint, voiceHere ? CGFloat(voice.tint) : 0)
        set(ShaderParam.voiceGlow, edge == 0 && voiceSettings.onMenuBar ? CGFloat(voice.glow) : 0)
        // Where this window sits on its screen (the voice color spreads from the screen's middle; Ambient light too).
        if let window, let screen = window.screen?.frame, screen.width > 0, screen.height > 0 {
            let f = window.frame
            params[ShaderParam.ambientRect] = Float((f.minX - screen.minX) / screen.width)
            params[ShaderParam.ambientRect + 1] = Float((f.maxX - screen.minX) / screen.width)
            params[ShaderParam.ambientRect + 2] = Float((f.minY - screen.minY) / screen.height)
            params[ShaderParam.ambientRect + 3] = Float((f.maxY - screen.minY) / screen.height)
        }
        set(ShaderParam.ambient, ambientColors != nil ? 1 : 0)
        if let ambientColors { fillAmbient(ambientColors) }

        // Regions: the whole strip, or left/right of the notch (a sliver at the center without one).
        let mid = width / 2
        let gap = notch ?? (mid - 5)...(mid + 5)
        let pad: CGFloat = notch == nil ? 0 : 6
        let regions: [(x0: CGFloat, x1: CGFloat, channel: Int, mirrored: Bool, set: BandSet)] = stereo
            ? [(0, max(0, gap.lowerBound - pad), 1, true, analyzer.left),
               (min(width, gap.upperBound + pad), width, 2, false, analyzer.right)]
            : [(0, width, 0, false, analyzer.mid)]
        set(ShaderParam.regionCount, CGFloat(regions.count))
        set(ShaderParam.gapLow, gap.lowerBound)
        set(ShaderParam.gapHigh, gap.upperBound)
        set(ShaderParam.notchRadius, min(10, height * 0.3))
        for (i, region) in regions.enumerated() {
            let base = ShaderParam.region0 + i * 5
            set(base, region.x0)
            set(base + 1, region.x1)
            set(base + 2, CGFloat(region.channel))
            set(base + 3, region.mirrored ? 1 : 0)
            set(base + 4, CGFloat(min(region.set.count, ShaderParam.maxBands)))
        }

        // Band levels and peaks for mid / left / right.
        for (channel, source) in [analyzer.mid, analyzer.left, analyzer.right].enumerated() {
            let count = min(source.count, ShaderParam.maxBands)
            for i in 0..<count {
                bands[channel * ShaderParam.maxBands + i] = source.levels[i]
                bands[(3 + channel) * ShaderParam.maxBands + i] = source.peaks[i]
            }
        }

        // Bar, LED and VU sizes, snapped to whole pixels.
        set(ShaderParam.capHeight, snap(height >= 30 ? 2 : 1.5))
        let segment = snap(height >= 30 ? 2.5 : 2), segmentGap = snap(1)
        let pitch = segment + segmentGap
        let rows = max(4, Int((height + segmentGap) / pitch))
        set(ShaderParam.ledRows, CGFloat(rows))
        set(ShaderParam.ledSegment, segment)
        set(ShaderParam.ledPitch, pitch)
        set(ShaderParam.ledOffset, snap((height - (CGFloat(rows) * pitch - segmentGap)) / 2))
        set(ShaderParam.vuSegment, max(1 / scale, snap(3)))
        set(ShaderParam.vuSpacing, max(1 / scale, snap(2)))

        params[ShaderParam.meterLeft] = analyzer.meterLeft
        params[ShaderParam.meterRight] = analyzer.meterRight
        params[ShaderParam.meterPeakLeft] = analyzer.meterPeakLeft
        params[ShaderParam.meterPeakRight] = analyzer.meterPeakRight

        // Pulse colors: by tone for horizontal palettes, by intensity for vertical ones.
        // Ambient light uses the screen's colors along that half of the top edge (or all of it).
        func pulseColor(_ set: BandSet, half: ClosedRange<CGFloat>, into index: Int) {
            let rgb: RGB
            if let ambientColors {
                rgb = ambientColors.topAverage(from: half.lowerBound, to: half.upperBound)
            } else {
                rgb = palette.axis == .horizontal ? palette.color(at: CGFloat(set.tone)) : palette.color(at: CGFloat(set.pulse))
            }
            params[index] = Float(rgb.r)
            params[index + 1] = Float(rgb.g)
            params[index + 2] = Float(rgb.b)
            params[index + 3] = set.pulse * 0.92
        }
        pulseColor(stereo ? analyzer.left : analyzer.mid, half: stereo ? 0...0.5 : 0...1, into: ShaderParam.pulseLeft)
        pulseColor(stereo ? analyzer.right : analyzer.mid, half: stereo ? 0.5...1 : 0...1, into: ShaderParam.pulseRight)
        var blend = gap
        if blend.upperBound - blend.lowerBound < width * 0.1 {
            blend = (width * 0.42)...(width * 0.58)
        }
        set(ShaderParam.blendLow, blend.lowerBound)
        set(ShaderParam.blendHigh, blend.upperBound)

        // Sparks, Scope and Waterfall.
        set(ShaderParam.particleCount, CGFloat(style == .sparks ? (sparks?.pack(into: &particles) ?? 0) : 0))
        params[ShaderParam.scopeAlpha] = analyzer.scopeLevel
        set(ShaderParam.scopePoints, CGFloat(SpectrumAnalyzer.scopePoints))
        if let history = MetalRenderer.shared?.history {
            set(ShaderParam.historyIndex, CGFloat(history.index))
            set(ShaderParam.historyLength, CGFloat(SpectrumHistory.length))
        }
        set(ShaderParam.waterfallColumn, 2)
        return true
    }

    /// Ambient light: copies the screen's edge colors, and where this window sits on its screen
    /// so each pixel can look up the color next to it.
    private func fillAmbient(_ colors: ScreenColors.Colors) {
        var i = 0
        func copy(_ list: [RGB]) {
            for c in list where i < ambient.count {
                // The fourth value is how strongly a light beam lights this spot.
                ambient[i] = SIMD4(Float(c.r), Float(c.g), Float(c.b), i < colors.beam.count ? colors.beam[i] : 0)
                i += 1
            }
        }
        copy(colors.top)
        copy(colors.bottom)
        copy(colors.left)
        copy(colors.right)
        guard let window, let screen = window.screen?.frame, screen.width > 0, screen.height > 0 else { return }
        let f = window.frame
        params[ShaderParam.ambientRect] = Float((f.minX - screen.minX) / screen.width)
        params[ShaderParam.ambientRect + 1] = Float((f.maxX - screen.minX) / screen.width)
        params[ShaderParam.ambientRect + 2] = Float((f.minY - screen.minY) / screen.height)
        params[ShaderParam.ambientRect + 3] = Float((f.maxY - screen.minY) / screen.height)
    }
}

/// What the menu bar's own text and icons look like right now (light or dark), taken from how macOS draws
/// Barbeat's menu bar icon. With "Keep menu bar text readable" the strip keeps its colors clear of that.
enum MenuBarText {
    private(set) static var isLight = true
    private static var checked = false

    static func update() {
        // The menu bar icon lives in a status bar window; its appearance follows the menu bar's.
        let statusWindow = NSApp.windows.first { String(describing: type(of: $0)).contains("StatusBarWindow") }
        let appearance = statusWindow?.contentView?.effectiveAppearance ?? NSApp.effectiveAppearance
        let light = [.darkAqua, .vibrantDark].contains(appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]))
        if CommandLine.arguments.contains("--verbose"), !checked || light != isLight {
            print("menu bar text: \(light ? "light" : "dark") (from \(statusWindow == nil ? "the app's appearance" : "the menu bar icon"))")
        }
        isLight = light
        checked = true
    }
}

/// A click-through, borderless window that covers one screen's menu bar strip,
/// sitting one level below the menu bar so menus and icons stay on top.
final class OverlayWindow: NSPanel {
    let eqView: EQView

    /// `edge` 0 covers the menu bar; 1/2/3/4 are the left/right/bottom/top screen-edge glow windows.
    init(settings: Settings, edge: Int = 0) {
        eqView = EQView(settings: settings, edge: edge)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 24),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        // The menu bar strip sits just under the menu bar; edge glow sits above apps but under the Dock.
        level = edge == 0 ? Self.stripLevel : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
        showInFullScreen(settings.showInFullScreen)
        contentView = eqView
    }

    private static let stripLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
    /// Over a full-screen app the hidden menu bar is still there (black on screens with a notch) and would cover
    /// the strip, so the strip goes just above it.
    private static let raisedStripLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)

    /// The strip is drawing over a full-screen app, in the band where the hidden menu bar would be.
    var overFullScreenApp = false { didSet { applyStripLevel() } }
    /// The hidden menu bar is showing (pointer at the top, or a menu open): the strip drops below it.
    var menuBarShowing = false { didSet { if menuBarShowing != oldValue { applyStripLevel() } } }
    /// When the menu bar counts as showing until (CACurrentMediaTime), after the pointer leaves it.
    var menuBarShowingUntil: CFTimeInterval = 0

    private func applyStripLevel() {
        guard eqView.edge == 0 else { return }
        let target = overFullScreenApp && !menuBarShowing ? Self.raisedStripLevel : Self.stripLevel
        if level != target { level = target }
    }

    /// Whether to stay visible over apps in full screen, or only on regular desktops.
    func showInFullScreen(_ show: Bool) {
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, show ? .fullScreenAuxiliary : .fullScreenNone]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Borderless windows may sit over the menu bar; don't let AppKit push us down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Height of the menu bar on this screen, or nil if it has none (or it auto-hides).
    static func menuBarHeight(on screen: NSScreen) -> CGFloat? {
        let height = screen.frame.maxY - screen.visibleFrame.maxY
        return height >= 10 ? height : nil
    }

    /// A regular window from another app covering all of this screen (on screens with a notch, everything below
    /// the notch), as an app in full screen does. Returns the gap above that window, in points: the black band
    /// around the notch, or 0. Nil when no window covers the screen.
    /// Needs no permission: only window frames are read.
    static func coveringWindowGap(on screen: NSScreen) -> CGFloat? {
        if let pretend = pretendFullScreenGap { return pretend }
        guard let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        // Window bounds are measured from the top left of the main screen.
        let f = screen.frame
        let frame = CGRect(x: f.minX, y: primary.frame.maxY - f.maxY, width: f.width, height: f.height)
        let topInset = max(1, screen.safeAreaInsets.top) + 1
        let me = ProcessInfo.processInfo.processIdentifier
        let gaps = list.compactMap { info -> CGFloat? in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != me,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  abs(bounds.minX - frame.minX) < 1, abs(bounds.maxX - frame.maxX) < 1,
                  abs(bounds.maxY - frame.maxY) < 1, bounds.minY <= frame.minY + topInset else { return nil }
            return max(0, bounds.minY - frame.minY).rounded()
        }
        return gaps.min()
    }

    /// `--pretend-full-screen <gap>` acts as if an app were in full screen on every screen, with a band of that
    /// many points above it (49 on a screen with a notch, 0 without), to test the layout without one.
    static let pretendFullScreenGap: CGFloat? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--pretend-full-screen"), i + 1 < args.count,
              let gap = Double(args[i + 1]) else { return nil }
        return CGFloat(gap)
    }()

    /// Whether a menu is open in another app (menus sit at the pop-up menu level), so the menu bar is in use.
    static func otherAppMenuIsOpen() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return list.contains { info in
            (info[kCGWindowLayer as String] as? Int) == menuLevel && (info[kCGWindowOwnerPID as String] as? Int32) != me
        }
    }

    /// The notch's horizontal span in window coordinates, if this screen has one.
    static func notchSpan(on screen: NSScreen) -> ClosedRange<CGFloat>? {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
              right.minX > left.maxX else { return nil }
        return (left.maxX - screen.frame.minX)...(right.minX - screen.frame.minX)
    }
}
