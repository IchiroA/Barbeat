import AppKit
import SwiftUI
import ImageIO

struct RGB: Equatable {
    var r: CGFloat, g: CGFloat, b: CGFloat

    func mixed(with other: RGB, _ t: CGFloat) -> RGB {
        RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    func cgColor(alpha: CGFloat) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
    var luminance: CGFloat { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    static let white = RGB(r: 1, g: 1, b: 1)
    static let black = RGB(r: 0, g: 0, b: 0)

    /// The same color with its hue turned by `turns` (1 = all the way around the color wheel).
    func hueRotated(by turns: Double) -> RGB {
        var hsb = HSB(self)
        hsb.h = (hsb.h + turns).truncatingRemainder(dividingBy: 1)
        if hsb.h < 0 { hsb.h += 1 }
        return hsb.rgb
    }
}

/// A color as hue, saturation and brightness (each 0...1). The custom gradient stores its colors this way
/// so the editor's sliders keep their hue even when saturation or brightness is dragged to zero.
struct HSB: Codable, Equatable {
    var h: Double, s: Double, b: Double

    init(h: Double, s: Double, b: Double) {
        self.h = h - floor(h)
        self.s = min(1, max(0, s))
        self.b = min(1, max(0, b))
    }

    init(_ c: RGB) {
        let r = Double(c.r), g = Double(c.g), b = Double(c.b)
        let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
        var hue = 0.0
        if delta > 0 {
            if maxC == r { hue = (g - b) / delta } else if maxC == g { hue = (b - r) / delta + 2 } else { hue = (r - g) / delta + 4 }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        self.init(h: hue, s: maxC == 0 ? 0 : delta / maxC, b: maxC)
    }

    var rgb: RGB {
        let h6 = (h - floor(h)) * 6, sector = Int(h6) % 6, f = h6 - floor(h6)
        let v = b, p = b * (1 - s), q = b * (1 - s * f), t = b * (1 - s * (1 - f))
        let (r, g, bl): (Double, Double, Double)
        switch sector {
        case 0: (r, g, bl) = (v, t, p)
        case 1: (r, g, bl) = (q, v, p)
        case 2: (r, g, bl) = (p, v, t)
        case 3: (r, g, bl) = (p, q, v)
        case 4: (r, g, bl) = (t, p, v)
        default: (r, g, bl) = (v, p, q)
        }
        return RGB(r: CGFloat(r), g: CGFloat(g), b: CGFloat(bl))
    }

    var color: Color { rgb.color }

    /// "#RRGGBB".
    var hex: String {
        let c = rgb
        func byte(_ v: CGFloat) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.r), byte(c.g), byte(c.b))
    }

    /// Accepts "#RRGGBB", "RRGGBB" or the short "#RGB".
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let value = Int(text, radix: 16) else { return nil }
        self.init(RGB(r: CGFloat((value >> 16) & 0xFF) / 255, g: CGFloat((value >> 8) & 0xFF) / 255,
                      b: CGFloat(value & 0xFF) / 255))
    }
}

/// Evenly spaced colors, the way every palette describes itself.
typealias GradientStops = [(CGFloat, RGB)]

enum GradientMath {
    static func sample(_ stops: GradientStops, at t: CGFloat) -> RGB {
        let t = min(1, max(0, t))
        guard var previous = stops.first else { return .white }
        for stop in stops.dropFirst() {
            if t <= stop.0 {
                let span = stop.0 - previous.0
                return previous.1.mixed(with: stop.1, span > 0 ? (t - previous.0) / span : 0)
            }
            previous = stop
        }
        return previous.1
    }

    static func evenlySpaced(_ colors: [RGB]) -> GradientStops {
        guard colors.count > 1 else { return colors.map { (0, $0) } + colors.map { (1, $0) } }
        return colors.enumerated().map { (CGFloat($0.offset) / CGFloat(colors.count - 1), $0.element) }
    }
}

enum Palette: String, CaseIterable, Identifiable {
    case classic, spectrum, neon, fire, ice, mono, accent, wallpaper, screen, custom

    var id: String { rawValue }

    /// Vertical palettes color by bar height (like a hardware GEQ); horizontal ones by frequency.
    enum Axis { case vertical, horizontal }

    var title: String {
        switch self {
        case .classic: return "Classic"
        case .spectrum: return "Spectrum"
        case .neon: return "Neon"
        case .fire: return "Fire"
        case .ice: return "Ice"
        case .mono: return "White"
        case .accent: return "Accent"
        case .wallpaper: return "Wallpaper"
        case .screen: return "Screen"
        case .custom: return "Custom"
        }
    }

    var axis: Axis {
        switch self {
        case .spectrum, .neon: return .horizontal
        case .custom: return Settings.shared.customGradient.byHeight ? .vertical : .horizontal
        case .screen: return Settings.shared.screenColorMode == .ambient ? .horizontal : .vertical
        default: return .vertical
        }
    }

    var stops: GradientStops {
        switch self {
        case .classic:
            return [(0, RGB(r: 0.10, g: 0.85, b: 0.30)), (0.55, RGB(r: 0.45, g: 0.95, b: 0.20)),
                    (0.78, RGB(r: 1.00, g: 0.85, b: 0.10)), (1, RGB(r: 1.00, g: 0.22, b: 0.15))]
        case .spectrum:
            return [(0, RGB(r: 1.00, g: 0.20, b: 0.25)), (0.18, RGB(r: 1.00, g: 0.55, b: 0.10)),
                    (0.36, RGB(r: 1.00, g: 0.90, b: 0.15)), (0.54, RGB(r: 0.25, g: 0.90, b: 0.35)),
                    (0.72, RGB(r: 0.15, g: 0.75, b: 1.00)), (0.88, RGB(r: 0.35, g: 0.40, b: 1.00)),
                    (1, RGB(r: 0.75, g: 0.35, b: 1.00))]
        case .neon:
            return [(0, RGB(r: 0.00, g: 0.90, b: 1.00)), (0.5, RGB(r: 0.55, g: 0.35, b: 1.00)),
                    (1, RGB(r: 1.00, g: 0.20, b: 0.75))]
        case .fire:
            return [(0, RGB(r: 0.75, g: 0.05, b: 0.05)), (0.5, RGB(r: 1.00, g: 0.45, b: 0.00)),
                    (1, RGB(r: 1.00, g: 0.92, b: 0.35))]
        case .ice:
            return [(0, RGB(r: 0.10, g: 0.30, b: 0.95)), (0.55, RGB(r: 0.30, g: 0.80, b: 1.00)),
                    (1, RGB(r: 0.90, g: 1.00, b: 1.00))]
        case .mono:
            return [(0, RGB(r: 0.85, g: 0.85, b: 0.88)), (1, .white)]
        case .accent:
            let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
            let base = RGB(r: accent.redComponent, g: accent.greenComponent, b: accent.blueComponent)
            return [(0, base.mixed(with: .black, 0.25)), (0.7, base), (1, base.mixed(with: .white, 0.45))]
        case .wallpaper:
            return WallpaperColors.stops() ?? Palette.accent.stops
        case .screen:
            return ScreenColors.shared.previewStops
        case .custom:
            return Settings.shared.customGradient.stops
        }
    }

    func color(at t: CGFloat) -> RGB { GradientMath.sample(stops, at: t) }

    /// For the swatches in the settings panel.
    var swatch: LinearGradient {
        LinearGradient(
            stops: stops.map { Gradient.Stop(color: $0.1.color, location: $0.0) },
            startPoint: axis == .vertical ? .bottom : .leading,
            endPoint: axis == .vertical ? .top : .trailing
        )
    }
}

/// How fast the colors slowly turn around the color wheel.
enum ColorDrift: String, CaseIterable, Identifiable {
    case off, slow, medium, fast
    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .slow: return "Slow"
        case .medium: return "Medium"
        case .fast: return "Fast"
        }
    }

    /// Seconds for one full trip around the color wheel.
    var period: Double? {
        switch self {
        case .off: return nil
        case .slow: return 120
        case .medium: return 40
        case .fast: return 12
        }
    }
}

/// What the Screen palette takes from the screen.
enum ScreenColorMode: String, CaseIterable, Identifiable {
    case colors, ambient
    var id: String { rawValue }

    var title: String {
        switch self {
        case .colors: return "Main colors"
        case .ambient: return "Ambient light"
        }
    }

    var subtitle: String {
        switch self {
        case .colors: return "The strongest colors on screen, fading as the picture changes."
        case .ambient: return "Each part of the menu bar and edge glow takes the color of the screen next to it, like TV backlighting."
        }
    }
}

/// The colors the renderer uses for one frame: the chosen palette with drift applied.
struct ResolvedGradient {
    var stops: GradientStops
    var axis: Palette.Axis

    init(palette: Palette, drift: ColorDrift, time: Double) {
        axis = palette.axis
        stops = palette.stops
        if let period = drift.period {
            let turns = (time / period).truncatingRemainder(dividingBy: 1)
            stops = stops.map { ($0.0, $0.1.hueRotated(by: turns)) }
        }
    }

    /// Colors that don't come from a palette (the Screen palette's, for one frame).
    init(stops: GradientStops, axis: Palette.Axis) {
        self.stops = stops
        self.axis = axis
    }

    func color(at t: CGFloat) -> RGB { GradientMath.sample(stops, at: t) }
}

/// Everything that decides this frame's colors: the gradient, plus the screen's edge colors for Ambient light.
/// The menu bar and the lights both take their colors from here, so they always match.
struct FrameColors {
    var gradient: ResolvedGradient
    /// Screen palette in Ambient light mode: what the screen shows along each edge.
    var ambient: ScreenColors.Colors?

    static func current(settings: Settings, display: CGDirectDisplayID?, time: Double) -> FrameColors {
        guard settings.palette == .screen else {
            return FrameColors(gradient: ResolvedGradient(palette: settings.palette, drift: settings.colorDrift, time: time),
                               ambient: nil)
        }
        // The Screen palette brings its own colors (drift doesn't apply); Ambient light colors each spot separately.
        let screen = ScreenColors.shared.colors(for: display)
        let ambient = settings.screenColorMode == .ambient ? screen : nil
        return FrameColors(gradient: ResolvedGradient(stops: screen?.paletteStops ?? ScreenColors.fallbackStops,
                                                      axis: ambient != nil ? .horizontal : .vertical),
                           ambient: ambient)
    }
}

/// The user's own gradient: four evenly spaced colors, across frequency or up the bar height.
struct CustomGradient: Codable, Equatable {
    static let colorCount = 4

    var colors: [HSB]
    /// False colors by frequency (like Neon); true colors by bar height (like Classic).
    var byHeight: Bool

    init(colors: [HSB], byHeight: Bool) {
        self.colors = Self.normalized(colors)
        self.byHeight = byHeight
    }

    /// Copies a built-in palette by sampling it at four even points.
    init(sampling palette: Palette) {
        let stops = palette == .custom ? CustomGradient.default.stops : palette.stops
        let colors = (0..<Self.colorCount).map {
            HSB(GradientMath.sample(stops, at: CGFloat($0) / CGFloat(Self.colorCount - 1)))
        }
        self.init(colors: colors, byHeight: palette.axis == .vertical)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(colors: try container.decode([HSB].self, forKey: .colors),
                  byHeight: try container.decodeIfPresent(Bool.self, forKey: .byHeight) ?? false)
    }

    /// Ichiro's own gradient: cyan, blue, violet, pink across the frequencies.
    static let `default` = CustomGradient(colors: [
        HSB(h: 0.517, s: 1.0, b: 1.0), HSB(h: 0.623, s: 0.633, b: 1.0),
        HSB(h: 0.775, s: 0.673, b: 0.917), HSB(h: 0.885, s: 0.8, b: 1.0),
    ], byHeight: false)

    var stops: GradientStops { GradientMath.evenlySpaced(colors.map(\.rgb)) }

    var swatch: LinearGradient {
        LinearGradient(colors: colors.map(\.color),
                       startPoint: byHeight ? .bottom : .leading,
                       endPoint: byHeight ? .top : .trailing)
    }

    /// Random colors that sit near each other on the color wheel, so they always go together.
    static func shuffled(byHeight: Bool) -> CustomGradient {
        let base = Double.random(in: 0..<1)
        let n = Double(colorCount - 1)
        let colors: [HSB]
        switch Int.random(in: 0..<5) {
        case 0:
            // One hue from deep to bright.
            colors = (0..<colorCount).map { i in
                let t = Double(i) / n
                return HSB(h: base + 0.04 * t, s: 1 - 0.45 * t, b: 0.55 + 0.45 * t)
            }
        case 1:
            // Two neighbours and their opposite: a bolder mix.
            let hues = [base, base + 0.08, base + 0.42, base + 0.5]
            colors = hues.map { HSB(h: $0, s: .random(in: 0.75...1), b: .random(in: 0.88...1)) }
        default:
            // Neighbouring hues, 25°–60° apart, like Neon or Fire.
            let step = Double.random(in: 0.07...0.17) * (Bool.random() ? 1 : -1)
            colors = (0..<colorCount).map { i in
                HSB(h: base + step * Double(i), s: .random(in: 0.7...1), b: .random(in: 0.88...1))
            }
        }
        var gradient = CustomGradient(colors: colors, byHeight: byHeight)
        if byHeight {
            // Darkest at the bottom reads best when color follows bar height.
            gradient.colors.sort { $0.rgb.luminance < $1.rgb.luminance }
        }
        return gradient
    }

    /// Four colors picked from the current desktop picture, or nil if it has none worth using.
    static func fromWallpaper(byHeight: Bool) -> CustomGradient? {
        guard let stops = WallpaperColors.freshStops(count: colorCount) else { return nil }
        let colors = (0..<colorCount).map { HSB(GradientMath.sample(stops, at: CGFloat($0) / CGFloat(colorCount - 1))) }
        return CustomGradient(colors: colors, byHeight: byHeight)
    }

    private static func normalized(_ colors: [HSB]) -> [HSB] {
        if colors.count == colorCount { return colors }
        if colors.isEmpty { return CustomGradient.default.colors }
        let stops = GradientMath.evenlySpaced(colors.map(\.rgb))
        return (0..<colorCount).map { HSB(GradientMath.sample(stops, at: CGFloat($0) / CGFloat(colorCount - 1))) }
    }
}

/// Picks a few vivid colors from the current desktop picture (checked every few seconds, extracted once per picture).
enum WallpaperColors {
    private static var cachedURL: URL?
    private static var cached: GradientStops?
    private static var lastCheck = Date.distantPast

    static func stops() -> GradientStops? {
        if Date().timeIntervalSince(lastCheck) > 5 {
            lastCheck = Date()
            if let url = currentURL(), url != cachedURL {
                cachedURL = url
                cached = extract(from: url, count: 3)
            }
        }
        return cached
    }

    /// Reads the wallpaper right now, for "From Wallpaper" in the custom gradient editor.
    static func freshStops(count: Int) -> GradientStops? {
        currentURL().flatMap { extract(from: $0, count: count) }
    }

    private static func currentURL() -> URL? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        return NSWorkspace.shared.desktopImageURL(for: screen)
    }

    private static func extract(from url: URL, count: Int) -> GradientStops? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 48] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var dominant = DominantColors()
        for i in stride(from: 0, to: pixels.count, by: 4) {
            dominant.add(r: Float(pixels[i]) / 255, g: Float(pixels[i + 1]) / 255, b: Float(pixels[i + 2]) / 255)
        }
        return dominant.colors(count: count).map(GradientMath.evenlySpaced)
    }
}
