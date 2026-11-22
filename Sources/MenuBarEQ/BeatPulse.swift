// Part of Barbeat, by Ichiro Ashihara (@IchiroA). MIT License.
import SwiftUI
import AppKit
import Combine
import QuartzCore

// The beat pulse: the whole screen pulses with the music. It has its own switch and settings (`pulse.*`) and
// doesn't change anything else Barbeat draws. Clicks always go straight through, and the menu bar stays as it is.

/// How the screen pulses.
enum PulseLook: String, CaseIterable, Identifiable {
    case edges, wash, brightness
    var id: String { rawValue }

    var title: String {
        switch self {
        case .edges: return "Glow from the edges"
        case .wash: return "Whole screen"
        case .brightness: return "Brightness"
        }
    }

    var help: String {
        switch self {
        case .edges: return "A glow comes in from the edges of the screen on every beat. The middle stays clear."
        case .wash: return "A see-through wash of color over the whole screen on every beat."
        case .brightness: return "The screen itself dims between beats and comes back to full brightness on each one, like lights dimming with the music. Barbeat puts the display back as soon as the pulse stops."
        }
    }

    var symbol: String {
        switch self {
        case .edges: return "rectangle.dashed"
        case .wash: return "rectangle.fill"
        case .brightness: return "sun.max"
        }
    }
}

/// Where the glow's color comes from.
enum PulseColorMode: String, CaseIterable, Identifiable {
    case barbeat, white
    var id: String { rawValue }

    var title: String {
        switch self {
        case .barbeat: return "Barbeat's colors"
        case .white: return "White"
        }
    }
}

/// The beat pulse preferences, saved to UserDefaults as they change.
final class PulseSettings: ObservableObject {
    static let shared = PulseSettings()
    private let defaults = UserDefaults.standard

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Key.enabled) } }
    @Published var look: PulseLook { didSet { defaults.set(look.rawValue, forKey: Key.look) } }
    @Published var colorMode: PulseColorMode { didSet { defaults.set(colorMode.rawValue, forKey: Key.color) } }
    /// How strong each beat is, 0.1...1.
    @Published var strength: Double { didSet { defaults.set(strength, forKey: Key.strength) } }
    /// The edges that glow (at least one).
    @Published var sides: ScreenSides { didSet { defaults.set(sides.rawValue, forKey: Key.sides) } }

    /// A switch for one side; the last side that's on can't be switched off.
    func side(_ side: ScreenSides) -> Binding<Bool> {
        Binding(get: { self.sides.contains(side) },
                set: { on in
                    if on { self.sides.insert(side) } else if self.sides != side { self.sides.remove(side) }
                })
    }

    /// Something to say about the settings in one line, for the panel.
    var summary: String {
        guard enabled else { return "The screen pulses with the beat" }
        var parts = [look.title]
        if look == .edges, sides != .all {
            parts.append(ScreenSides.named.filter { sides.contains($0.side) }.map(\.title).joined(separator: ", "))
        }
        if look != .brightness { parts.append(colorMode.title) }
        parts.append("\(Int((strength * 100).rounded()))%")
        return parts.joined(separator: " · ")
    }

    private enum Key {
        static let enabled = "pulse.enabled", look = "pulse.look", color = "pulse.color", strength = "pulse.strength"
        static let sides = "pulse.sides"
    }

    private init() {
        defaults.register(defaults: [
            Key.enabled: false, Key.look: PulseLook.edges.rawValue, Key.color: PulseColorMode.barbeat.rawValue,
            Key.strength: 0.5, Key.sides: ScreenSides.all.rawValue,
        ])
        enabled = defaults.bool(forKey: Key.enabled)
        look = PulseLook(rawValue: defaults.string(forKey: Key.look) ?? "") ?? .edges
        colorMode = PulseColorMode(rawValue: defaults.string(forKey: Key.color) ?? "") ?? .barbeat
        strength = min(1, max(0.1, defaults.double(forKey: Key.strength)))
        let savedSides = ScreenSides(rawValue: defaults.integer(forKey: Key.sides)).intersection(.all)
        sides = savedSides.isEmpty ? .all : savedSides
    }
}

// MARK: - Drawing

/// The edge glow's shape: opaque at the screen's chosen edges, fading in toward the middle, the same depth in points
/// on every side, with rounded corners. Small (the window stretches it smoothly), made once per screen shape and sides.
enum PulseArt {
    /// How far in the glow reaches, as a share of the screen's height (where it's about a fifth as strong).
    static let depth: CGFloat = 0.16

    /// The glow's strength at each pixel of a `width` x `height` picture of the screen, 0...255, top row first.
    static func edgeAlpha(width: Int, height: Int, sides: ScreenSides = .all) -> [UInt8] {
        var alpha = [UInt8](repeating: 0, count: width * height)
        guard !sides.isEmpty else { return alpha }
        let k: CGFloat = 0.02   // corner rounding
        let h = CGFloat(height)
        for y in 0..<height {
            // Distances to each glowing edge, in screen heights (row 0 is the top).
            let top = (CGFloat(y) + 0.5) / h, bottom = (h - CGFloat(y) - 0.5) / h
            for x in 0..<width {
                let left = (CGFloat(x) + 0.5) / h, right = (CGFloat(width) - CGFloat(x) - 0.5) / h
                // A soft minimum of the distances to the edges that glow: rounded corners where two meet.
                var sum: CGFloat = 0
                if sides.contains(.left) { sum += exp(-left / k) }
                if sides.contains(.right) { sum += exp(-right / k) }
                if sides.contains(.top) { sum += exp(-top / k) }
                if sides.contains(.bottom) { sum += exp(-bottom / k) }
                let edge = sum > 0 ? -k * log(sum) : .infinity
                let a = exp(-max(0, edge) / (depth / 1.6))
                alpha[y * width + x] = UInt8(min(255, max(0, (a * 255).rounded())))
            }
        }
        return alpha
    }

    /// The glow's shape as a layer mask: white, with the glow's strength as its alpha.
    static func edgeMask(aspect: CGFloat, sides: ScreenSides) -> CGImage? {
        let height = 160, width = max(16, min(1024, Int((CGFloat(height) * aspect).rounded())))
        let alpha = edgeAlpha(width: width, height: height, sides: sides)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let a = alpha[i]
            pixels[i * 4] = a; pixels[i * 4 + 1] = a; pixels[i * 4 + 2] = a; pixels[i * 4 + 3] = a   // premultiplied white
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// `--pulse-snapshot out.png`: the edge glow (on the chosen sides) at full strength in Neon's middle color over a grey screen, and the
    /// whole-screen wash beside it (so the shapes can be checked without looking at the screen).
    static func writeSnapshot(to path: String) {
        let w = 640, h = 400, gap = 20, total = w * 2 + gap
        let alpha = edgeAlpha(width: w, height: h, sides: PulseSettings.shared.sides)
        let color: (CGFloat, CGFloat, CGFloat) = (0.55, 0.35, 1), grey: CGFloat = 0.45
        var pixels = [UInt8](repeating: 255, count: total * h * 4)
        for y in 0..<h {
            for x in 0..<total where x < w || x >= w + gap {
                let a = x < w ? CGFloat(alpha[y * w + x]) / 255 : PulseController.washOpacity
                let i = (y * total + x) * 4
                pixels[i] = UInt8((grey + (color.0 - grey) * a) * 255)
                pixels[i + 1] = UInt8((grey + (color.1 - grey) * a) * 255)
                pixels[i + 2] = UInt8((grey + (color.2 - grey) * a) * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: total, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: total * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
        PNGFile.write(image, to: path)
        print("pulse snapshot: wrote \(path)")
    }
}

/// One screen's pulse: a colored layer, shaped by the edge mask (or covering everything), whose opacity follows
/// the beat. Only the color and opacity change from frame to frame.
private final class PulseView: NSView {
    private let colorLayer = CALayer()
    private let maskLayer = CALayer()
    private var maskKey: (aspect: CGFloat, sides: ScreenSides)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        colorLayer.opacity = 0
        maskLayer.contentsGravity = .resize
        maskLayer.magnificationFilter = .linear
        layer?.addSublayer(colorLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        colorLayer.frame = bounds
        maskLayer.frame = bounds
        CATransaction.commit()
    }

    func show(look: PulseLook, sides: ScreenSides, color: RGB, opacity: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if colorLayer.frame != bounds {
            colorLayer.frame = bounds
            maskLayer.frame = bounds
        }
        if look == .edges {
            let aspect = bounds.height > 0 ? (bounds.width / bounds.height * 20).rounded() / 20 : 1.6
            if maskKey?.aspect != aspect || maskKey?.sides != sides {
                maskKey = (aspect, sides)
                maskLayer.contents = PulseArt.edgeMask(aspect: aspect, sides: sides)
            }
            if colorLayer.mask == nil { colorLayer.mask = maskLayer }
        } else if colorLayer.mask != nil {
            colorLayer.mask = nil
        }
        colorLayer.backgroundColor = color.cgColor
        colorLayer.opacity = opacity
        CATransaction.commit()
    }
}

/// A click-through window over one whole screen, above apps and the Dock, under the menu bar.
private final class PulseWindow: NSPanel {
    let pulseView = PulseView(frame: .zero)

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        contentView = pulseView
    }

    func showInFullScreen(_ show: Bool) {
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, show ? .fullScreenAuxiliary : .fullScreenNone]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// MARK: - The pulse itself

/// Runs the beat pulse: the windows for the two glow looks, or the displays' brightness for the third.
/// The render loop calls `tick` every frame while Barbeat listens.
final class PulseController {
    /// The whole-screen wash is see-through even at full strength.
    static let washOpacity: CGFloat = 0.35
    /// The most the Brightness look dims the screen between beats (at full strength).
    static let deepestDim: Float = 0.4

    private let settings = PulseSettings.shared
    private let app: Settings
    private let engine = BeatPulse()
    private var windows: [PulseWindow] = []
    private var windowsShowing = false
    private var silence: Double = .infinity
    private let verbose = CommandLine.arguments.contains("--verbose")
    private var lastLog: Double = 0
    private var clock: Double = 0

    /// Brightness: each display's own transfer table when the pulse took it over, and what it's set to now.
    private var tables: [CGDirectDisplayID: (r: [CGGammaValue], g: [CGGammaValue], b: [CGGammaValue])] = [:]
    private var brightness: Float = 1
    private var lastBrightnessUpdate: Double = 0
    private var brightnessUpdates = 0
    /// True while some display's brightness is changed (for quitting).
    private static var holdingDisplays = false

    init(app: Settings) {
        self.app = app
    }

    /// The screens the pulse covers: the same as the menu bar visuals' choice.
    private var screens: [NSScreen] { app.allDisplays ? NSScreen.screens : Array(NSScreen.screens.prefix(1)) }

    /// Sets things up for the current settings and screens (or takes everything down when the pulse is off).
    func apply() {
        let wantWindows = settings.enabled && settings.look != .brightness
        let targets = wantWindows ? screens : []
        while windows.count > targets.count { windows.removeLast().orderOut(nil) }
        while windows.count < targets.count { windows.append(PulseWindow()) }
        for (window, screen) in zip(windows, targets) {
            window.showInFullScreen(app.showInFullScreen)
            window.setFrame(screen.frame, display: false)
            if windowsShowing { window.orderFrontRegardless() }
        }
        if !settings.enabled { engine.reset() }
        // Brightness: let go of displays that aren't wanted any more (all of them when the look changes or it's off).
        if !(settings.enabled && settings.look == .brightness) || Set(tables.keys) != Set(screens.map(\.displayID)) {
            restoreBrightness()
        }
    }

    func tick(analyzer: SpectrumAnalyzer, sound: Float, colors: FrameColors, tempo: BeatTracker, dt: Double) {
        guard settings.enabled else { return }
        clock += dt
        silence = sound > 0.0005 ? 0 : silence + dt
        let playing = silence < 1.2
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let value = engine.frame(kick: analyzer.mid.kick, intensity: analyzer.mid.pulse, playing: playing,
                                 reduceMotion: reduceMotion, dt: dt, tempo: tempo)
        let strength = Float(settings.strength)

        switch settings.look {
        case .brightness:
            hideWindows()
            // Dim between beats, full brightness on each one; back to normal when the music stops.
            let target = 1 - Self.deepestDim * strength * engine.active * (1 - value)
            setBrightness(target, letGo: engine.active < 0.005)
        case .edges, .wash:
            let color = settings.colorMode == .white ? RGB.white : colors.gradient.color(at: CGFloat(analyzer.mid.tone))
            let opacity = value * strength * (settings.look == .wash ? Float(Self.washOpacity) : 1)
            if opacity < 0.002, !playing, engine.active < 0.01 {
                hideWindows()
            } else {
                if !windowsShowing {
                    windowsShowing = true
                    apply()
                    windows.forEach { $0.orderFrontRegardless() }
                }
                windows.forEach { $0.pulseView.show(look: settings.look, sides: settings.sides, color: color, opacity: opacity) }
            }
        }
        if verbose, clock - lastLog >= 0.5 {
            lastLog = clock
            print(String(format: "pulse: %@ value %.2f active %.2f beats %d, tempo %.1f BPM (sure %.2f)%@", settings.look.rawValue,
                         value, engine.active, engine.beats, tempo.bpm, tempo.confidence, settings.look == .brightness
                            ? String(format: " brightness %.3f, %d display updates", brightness, brightnessUpdates) : ""))
            brightnessUpdates = 0
        }
    }

    private func hideWindows() {
        guard windowsShowing else { return }
        windowsShowing = false
        windows.forEach { $0.orderOut(nil) }
    }

    // MARK: Brightness

    /// Scales each display's own transfer table (so calibration and color profiles stay as they are).
    /// `letGo`: the music has stopped, so give the displays back instead of holding them at full brightness.
    private func setBrightness(_ value: Float, letGo: Bool) {
        if letGo {
            restoreBrightness()
            return
        }
        let value = min(1, max(0.3, value))
        // Each change is a round trip to the window server, which then reloads the display's curve: at most 30 a
        // second, none too small to see, but a big jump (a beat coming in) goes out right away.
        let change = abs(value - brightness)
        guard tables.isEmpty || change >= 0.05 || (change >= 0.004 && clock - lastBrightnessUpdate >= 1.0 / 30) else { return }
        lastBrightnessUpdate = clock
        brightnessUpdates += 1
        for screen in screens {
            let display = screen.displayID
            if tables[display] == nil {
                let capacity = CGDisplayGammaTableCapacity(display)
                var r = [CGGammaValue](repeating: 0, count: Int(capacity)), g = r, b = r
                var count: UInt32 = 0
                guard capacity > 0, CGGetDisplayTransferByTable(display, capacity, &r, &g, &b, &count) == .success,
                      count > 0 else { continue }
                // 256 steps are plenty (macOS fills in between), and a quarter of the 1024 to send each time.
                func thin(_ t: [CGGammaValue]) -> [CGGammaValue] {
                    let n = Int(count)
                    guard n > 256 else { return Array(t[0..<n]) }
                    return (0..<256).map { t[Int((Double($0) * Double(n - 1) / 255).rounded())] }
                }
                tables[display] = (thin(r), thin(g), thin(b))
            }
            guard let table = tables[display] else { continue }
            var r = table.r.map { $0 * value }, g = table.g.map { $0 * value }, b = table.b.map { $0 * value }
            if CGSetDisplayTransferByTable(display, UInt32(r.count), &r, &g, &b) == .success { Self.holdingDisplays = true }
        }
        brightness = value
    }

    private func restoreBrightness() {
        if !tables.isEmpty || Self.holdingDisplays { Self.restoreDisplays() }
        tables.removeAll()
        brightness = 1
    }

    /// Puts every display back to its color profile (quitting, or the pulse letting go). macOS also does this by
    /// itself when Barbeat quits for any reason.
    static func restoreDisplays() {
        guard holdingDisplays else { return }
        CGDisplayRestoreColorSyncSettings()
        holdingDisplays = false
    }
}

// MARK: - The tempo readout

/// The tempo the beat clock hears, for the Settings pages. Updated twice a second while the beat pulse or the
/// kaleidoscope runs.
final class TempoMonitor: ObservableObject {
    static let shared = TempoMonitor()
    @Published private(set) var bpm = 0
    @Published private(set) var locked = false
    private var last: Double = 0

    func update(_ tracker: BeatTracker, now: Double) {
        guard now - last >= 0.5 else { return }
        last = now
        let bpm = Int(tracker.bpm.rounded()), locked = tracker.confidence >= BeatTracker.sure && bpm > 0
        if bpm != self.bpm { self.bpm = bpm }
        if locked != self.locked { self.locked = locked }
    }

    var text: String { locked ? "\(bpm) BPM" : "Listening for the beat…" }
}

/// "128 BPM" (or still listening), with a metronome.
struct TempoBadge: View {
    @ObservedObject var monitor = TempoMonitor.shared

    var body: some View {
        Label(monitor.text, systemImage: "metronome")
            .font(.callout.monospacedDigit())
            .foregroundStyle(monitor.locked ? Color.primary : Color.secondary)
            .help("The tempo Barbeat hears. Effects land on every beat once it's locked on (it takes a few seconds of music).")
    }
}

// MARK: - The panel row

/// The Beat pulse row in the menu bar panel.
struct PulseRow: View {
    @ObservedObject var settings: PulseSettings

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rays")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(settings.enabled ? Color.accentColor : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("Beat pulse").font(.callout)
                Text(settings.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("Options…") { SettingsWindow.show(.pulse) }
                .controlSize(.small)
            Toggle("Beat pulse", isOn: $settings.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .help("The whole screen pulses with the beat")
    }
}

// MARK: - The Settings page

struct PulsePage: View {
    @ObservedObject var settings: PulseSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Toggle("Pulse the screen with the beat", isOn: $settings.enabled)
                    .toggleStyle(.switch)
                Spacer()
                if settings.enabled { TempoBadge() }
            }
            VStack(alignment: .leading, spacing: 22) {
                SettingsSection("Look", caption: settings.look.help) {
                    HStack(spacing: 8) {
                        ForEach(PulseLook.allCases) { look in
                            Button { settings.look = look } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: look.symbol).font(.system(size: 20))
                                    Text(look.title).font(.caption).multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity, minHeight: 64)
                                .background(RoundedRectangle(cornerRadius: 8)
                                    .fill(settings.look == look ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .stroke(settings.look == look ? Color.accentColor : .clear, lineWidth: 1.5))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if settings.look == .edges {
                    SettingsSection("Sides", caption: "The edges that glow. At least one stays on.") {
                        HStack(spacing: 16) {
                            ForEach(ScreenSides.named, id: \.title) { item in
                                Toggle(item.title, isOn: settings.side(item.side))
                                    .toggleStyle(.checkbox)
                                    .disabled(settings.sides == item.side)
                            }
                        }
                    }
                }
                if settings.look != .brightness {
                    SettingsSection("Color") {
                        Picker("Color", selection: $settings.colorMode) {
                            ForEach(PulseColorMode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 320)
                    }
                }
                SettingsSection("Strength", caption: settings.look == .brightness
                                ? "How far the screen dims between beats (up to 40%)."
                                : "How bright the glow gets on a beat.") {
                    SettingsSlider("On each beat", value: $settings.strength, in: 0.1...1,
                                   text: "\(Int((settings.strength * 100).rounded()))%")
                }
            }
            .disabled(!settings.enabled)
            .opacity(settings.enabled ? 1 : 0.55)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                note("Clicks go straight through, and the menu bar stays as it is. It covers the same screens as the menu bar visuals, and full-screen apps too when Show over full-screen apps is on.")
                note("For safety the screen never flashes more than three times a second. With Reduce motion on (System Settings › Accessibility › Display) beats are softer and slower.")
                if settings.look == .brightness {
                    note("Brightness changes the display's color curve, like f.lux and similar apps do, so it may not mix well with them. Barbeat gives the display back whenever the pulse stops, and macOS does too if Barbeat quits.")
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
