import Foundation
import Combine

enum EQStyle: String, CaseIterable, Identifiable {
    case led, bars, center, glow, pulse, vu, aura, waterfall, scope, sparks
    var id: String { rawValue }

    var title: String {
        switch self {
        case .led: return "LED"
        case .bars: return "Bars"
        case .center: return "Center"
        case .glow: return "Glow"
        case .pulse: return "Pulse"
        case .vu: return "VU"
        case .aura: return "Aura"
        case .waterfall: return "Waterfall"
        case .scope: return "Scope"
        case .sparks: return "Sparks"
        }
    }

    var symbol: String {
        switch self {
        case .led: return "square.grid.3x3.fill"
        case .bars: return "chart.bar.fill"
        case .center: return "waveform"
        case .glow: return "sun.max.fill"
        case .pulse: return "waveform.path.ecg"
        case .vu: return "arrow.left.and.right"
        case .aura: return "rays"
        case .waterfall: return "water.waves"
        case .scope: return "waveform.path"
        case .sparks: return "sparkles"
        }
    }

    var subtitle: String {
        switch self {
        case .led: return "Segmented bars, like a hardware EQ"
        case .bars: return "Solid bars"
        case .center: return "Bars that grow from the middle"
        case .glow: return "Soft color wash that lights up with each frequency"
        case .pulse: return "The whole menu bar color pulses with the beat"
        case .vu: return "Stereo meter shooting out of the notch"
        case .aura: return "A glow around the notch that pulses with the bass"
        case .waterfall: return "The music's history flowing out across the menu bar"
        case .scope: return "A live waveform, like an oscilloscope"
        case .sparks: return "Sparks shoot out of the notch on every beat"
        }
    }

    /// These always split around the notch; the others can be full width or stereo.
    var alwaysStereo: Bool { self == .vu || self == .aura || self == .sparks }
    var supportsLayout: Bool { !alwaysStereo }
    /// Styles where the band count changes the picture.
    var usesBands: Bool { [.led, .bars, .center, .glow, .waterfall].contains(self) }
    var usesPeaks: Bool { [.led, .bars, .center, .vu].contains(self) }
}

/// Where the sound comes from.
enum AudioSourceKind: String, CaseIterable, Identifiable {
    case system, app, device
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "System"
        case .app: return "One App"
        case .device: return "Input"
        }
    }
}

enum EQLayout: String, CaseIterable, Identifiable {
    case full, stereo
    var id: String { rawValue }
    var title: String {
        switch self {
        case .full: return "Full width"
        case .stereo: return "Stereo L | R"
        }
    }
}

/// User preferences, saved to UserDefaults as they change.
final class Settings: ObservableObject {
    static let shared = Settings()
    static let bandChoices = [16, 31, 48, 64, 96, 128]

    private let defaults = UserDefaults.standard

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Key.enabled) } }
    @Published var style: EQStyle { didSet { defaults.set(style.rawValue, forKey: Key.style) } }
    @Published var layout: EQLayout { didSet { defaults.set(layout.rawValue, forKey: Key.layout) } }
    @Published var palette: Palette { didSet { defaults.set(palette.rawValue, forKey: Key.palette) } }
    @Published var bandCount: Int { didSet { defaults.set(bandCount, forKey: Key.bandCount) } }
    @Published var opacity: Double { didSet { defaults.set(opacity, forKey: Key.opacity) } }
    /// Extra gain in dB, -12...+12.
    @Published var sensitivity: Double { didSet { defaults.set(sensitivity, forKey: Key.sensitivity) } }
    @Published var autoLevel: Bool { didSet { defaults.set(autoLevel, forKey: Key.autoLevel) } }
    @Published var showPeaks: Bool { didSet { defaults.set(showPeaks, forKey: Key.showPeaks) } }
    @Published var allDisplays: Bool { didSet { defaults.set(allDisplays, forKey: Key.allDisplays) } }
    /// Ambient glow along the left, right and bottom edges of the screen (and the top, with `edgeGlowTop`).
    @Published var edgeGlow: Bool { didSet { defaults.set(edgeGlow, forKey: Key.edgeGlow) } }
    /// How far the edge glow reaches into the screen, in points (see `edgeGlowDepthRange`).
    @Published var edgeGlowDepth: Double { didSet { defaults.set(edgeGlowDepth, forKey: Key.edgeGlowDepth) } }
    /// The edge glow also runs along the top of the screen, just below the menu bar.
    @Published var edgeGlowTop: Bool { didSet { defaults.set(edgeGlowTop, forKey: Key.edgeGlowTop) } }
    /// Intensity of the glows and colors, 0.3...2.
    @Published var brightness: Double { didSet { defaults.set(brightness, forKey: Key.brightness) } }
    /// Extra gain for the low / mid / high frequencies in dB, -12...+12.
    @Published var lowGain: Double { didSet { defaults.set(lowGain, forKey: Key.lowGain) } }
    @Published var midGain: Double { didSet { defaults.set(midGain, forKey: Key.midGain) } }
    @Published var highGain: Double { didSet { defaults.set(highGain, forKey: Key.highGain) } }
    /// How hard sparks get shot out, 0...1. Higher reaches further toward the screen edges.
    @Published var sparkPower: Double { didSet { defaults.set(sparkPower, forKey: Key.sparkPower) } }

    /// The gradient used by the Custom palette.
    @Published var customGradient: CustomGradient { didSet { store(customGradient, Key.customGradient) } }
    /// Four preset slots for custom gradients; nil is an empty slot.
    @Published var savedGradients: [CustomGradient?] { didSet { store(savedGradients, Key.savedGradients) } }
    @Published var colorDrift: ColorDrift { didSet { defaults.set(colorDrift.rawValue, forKey: Key.colorDrift) } }
    /// What the Screen palette takes from the screen: its main colors, or the colors next to each spot.
    @Published var screenColorMode: ScreenColorMode {
        didSet { defaults.set(screenColorMode.rawValue, forKey: Key.screenColorMode) }
    }
    /// Screen palette: bright beams and flashes sweeping across the picture spill their own color into the glow.
    @Published var screenBeams: Bool { didSet { defaults.set(screenBeams, forKey: Key.screenBeams) } }
    /// How strongly light beams take over (see `screenBeamStrengthRange`; 1 is the default).
    @Published var screenBeamStrength: Double {
        didSet { defaults.set(screenBeamStrength, forKey: Key.screenBeamStrength) }
    }
    /// Keep drawing over apps in full screen (the edge glow, and the strip if `fullScreenStrip` is on).
    @Published var showInFullScreen: Bool { didSet { defaults.set(showInFullScreen, forKey: Key.showInFullScreen) } }
    /// In full screen, also draw the menu bar strip, in the band where the hidden menu bar would be.
    /// Off: just the edge glow, on all four sides.
    @Published var fullScreenStrip: Bool { didSet { defaults.set(fullScreenStrip, forKey: Key.fullScreenStrip) } }
    /// Tones down strip colors that would wash out the menu bar's own text and icons.
    @Published var readableMenuBar: Bool { didSet { defaults.set(readableMenuBar, forKey: Key.readableMenuBar) } }

    /// What to listen to. The app and device are remembered by ID, with a name to show while they're away.
    @Published var audioSource: AudioSourceKind { didSet { defaults.set(audioSource.rawValue, forKey: Key.audioSource) } }
    @Published var sourceAppID: String { didSet { defaults.set(sourceAppID, forKey: Key.sourceAppID) } }
    @Published var sourceAppName: String { didSet { defaults.set(sourceAppName, forKey: Key.sourceAppName) } }
    @Published var sourceDeviceUID: String { didSet { defaults.set(sourceDeviceUID, forKey: Key.sourceDeviceUID) } }
    @Published var sourceDeviceName: String { didSet { defaults.set(sourceDeviceName, forKey: Key.sourceDeviceName) } }

    // First-launch values (Ichiro's own setup).
    static let defaultSparkPower = 0.6
    static let defaultEdgeGlowDepth = 241.0
    static let defaultBrightness = 1.36
    static let defaultSensitivity = -5.0
    static let defaultLowGain = -4.0, defaultMidGain = -2.0, defaultHighGain = 0.0
    static let edgeGlowDepthRange = 16.0...480.0
    static let screenBeamStrengthRange = 0.25...2.0
    static let presetSlots = 4

    /// Starts the Custom palette from a copy of the chosen built-in palette.
    func customizeCurrentPalette() {
        customGradient = CustomGradient(sampling: palette)
        palette = .custom
    }

    func resetTuning() {
        brightness = Settings.defaultBrightness
        lowGain = Settings.defaultLowGain
        midGain = Settings.defaultMidGain
        highGain = Settings.defaultHighGain
        sparkPower = Settings.defaultSparkPower
    }

    private enum Key {
        static let enabled = "enabled", style = "style", layout = "layout", palette = "palette", bandCount = "bandCount"
        static let opacity = "opacity", sensitivity = "sensitivity", autoLevel = "autoLevel"
        static let showPeaks = "showPeaks", allDisplays = "allDisplays", edgeGlow = "edgeGlow"
        static let edgeGlowDepth = "edgeGlowDepth", edgeGlowTop = "edgeGlowTop"
        static let brightness = "brightness", lowGain = "lowGain", midGain = "midGain", highGain = "highGain"
        static let sparkPower = "sparkPower"
        static let customGradient = "customGradient", savedGradients = "savedGradients", colorDrift = "colorDrift"
        static let screenColorMode = "screenColorMode", showInFullScreen = "showInFullScreen"
        static let fullScreenStrip = "fullScreenStrip", readableMenuBar = "readableMenuBar"
        static let screenBeams = "screenBeams", screenBeamStrength = "screenBeamStrength"
        static let audioSource = "audioSource", sourceAppID = "sourceAppID", sourceAppName = "sourceAppName"
        static let sourceDeviceUID = "sourceDeviceUID", sourceDeviceName = "sourceDeviceName"
    }

    /// Gradients are saved as JSON text, so they're readable with `defaults read`.
    private func store<T: Encodable>(_ value: T, _ key: String) {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return }
        defaults.set(text, forKey: key)
    }

    private func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = defaults.string(forKey: key)?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private init() {
        defaults.register(defaults: [
            Key.enabled: true,
            // First launch (Ichiro's own setup): 128 stereo Center bars in Screen › Ambient light colors,
            // with a deep edge glow on all sides; in full screen just the glow.
            Key.style: EQStyle.center.rawValue,
            Key.layout: EQLayout.stereo.rawValue,
            Key.palette: Palette.screen.rawValue,
            Key.bandCount: 128,
            Key.opacity: 0.74,
            Key.sensitivity: Settings.defaultSensitivity,
            Key.autoLevel: true,
            Key.showPeaks: false,
            Key.allDisplays: true,
            Key.edgeGlow: true,
            Key.edgeGlowDepth: Settings.defaultEdgeGlowDepth,
            Key.edgeGlowTop: true,
            Key.brightness: Settings.defaultBrightness,
            Key.lowGain: Settings.defaultLowGain,
            Key.midGain: Settings.defaultMidGain,
            Key.highGain: Settings.defaultHighGain,
            Key.sparkPower: Settings.defaultSparkPower,
            Key.colorDrift: ColorDrift.off.rawValue,
            Key.screenColorMode: ScreenColorMode.ambient.rawValue,
            Key.screenBeams: true,
            Key.screenBeamStrength: 1.0,
            Key.showInFullScreen: true,
            Key.fullScreenStrip: false,
            Key.readableMenuBar: true,
            Key.audioSource: AudioSourceKind.system.rawValue,
            Key.sourceAppID: "",
            Key.sourceAppName: "",
            Key.sourceDeviceUID: "",
            Key.sourceDeviceName: "",
        ])
        enabled = defaults.bool(forKey: Key.enabled)
        style = EQStyle(rawValue: defaults.string(forKey: Key.style) ?? "") ?? .center
        layout = EQLayout(rawValue: defaults.string(forKey: Key.layout) ?? "") ?? .stereo
        palette = Palette(rawValue: defaults.string(forKey: Key.palette) ?? "") ?? .screen
        let savedBands = defaults.integer(forKey: Key.bandCount)
        bandCount = Settings.bandChoices.contains(savedBands) ? savedBands : 128
        opacity = defaults.double(forKey: Key.opacity)
        sensitivity = defaults.double(forKey: Key.sensitivity)
        autoLevel = defaults.bool(forKey: Key.autoLevel)
        showPeaks = defaults.bool(forKey: Key.showPeaks)
        allDisplays = defaults.bool(forKey: Key.allDisplays)
        edgeGlow = defaults.bool(forKey: Key.edgeGlow)
        let range = Settings.edgeGlowDepthRange
        edgeGlowDepth = min(max(defaults.double(forKey: Key.edgeGlowDepth), range.lowerBound), range.upperBound)
        edgeGlowTop = defaults.bool(forKey: Key.edgeGlowTop)
        brightness = defaults.double(forKey: Key.brightness)
        lowGain = defaults.double(forKey: Key.lowGain)
        midGain = defaults.double(forKey: Key.midGain)
        highGain = defaults.double(forKey: Key.highGain)
        sparkPower = defaults.double(forKey: Key.sparkPower)
        customGradient = CustomGradient.default
        savedGradients = Array(repeating: nil, count: Settings.presetSlots)
        colorDrift = ColorDrift(rawValue: defaults.string(forKey: Key.colorDrift) ?? "") ?? .off
        screenColorMode = ScreenColorMode(rawValue: defaults.string(forKey: Key.screenColorMode) ?? "") ?? .ambient
        screenBeams = defaults.bool(forKey: Key.screenBeams)
        let beamRange = Settings.screenBeamStrengthRange
        screenBeamStrength = min(max(defaults.double(forKey: Key.screenBeamStrength), beamRange.lowerBound),
                                 beamRange.upperBound)
        showInFullScreen = defaults.bool(forKey: Key.showInFullScreen)
        fullScreenStrip = defaults.bool(forKey: Key.fullScreenStrip)
        readableMenuBar = defaults.bool(forKey: Key.readableMenuBar)
        audioSource = AudioSourceKind(rawValue: defaults.string(forKey: Key.audioSource) ?? "") ?? .system
        sourceAppID = defaults.string(forKey: Key.sourceAppID) ?? ""
        sourceAppName = defaults.string(forKey: Key.sourceAppName) ?? ""
        sourceDeviceUID = defaults.string(forKey: Key.sourceDeviceUID) ?? ""
        sourceDeviceName = defaults.string(forKey: Key.sourceDeviceName) ?? ""
        // Read these after every property is set (load needs self). didSet doesn't run inside init.
        if let saved = load(CustomGradient.self, Key.customGradient) { customGradient = saved }
        if var slots = load([CustomGradient?].self, Key.savedGradients) {
            slots += Array(repeating: nil, count: max(0, Settings.presetSlots - slots.count))
            savedGradients = Array(slots.prefix(Settings.presetSlots))
        }
    }
}

/// What the settings panel shows about audio capture.
final class AudioStatus: ObservableObject {
    static let shared = AudioStatus()

    enum State: Equatable {
        case off
        case starting
        case listening
        case silent
        case demo
        case noMenuBar
        case failed(String)
        /// "One App" is chosen but that app has no sound running (or no app is picked yet).
        case waitingForApp
        case askingForMicrophone
        case microphoneDenied
    }

    @Published var state: State = .off
    /// What's being captured right now, e.g. "system audio", "Spotify", "MacBook Pro Microphone".
    @Published var sourceName = "system audio"
    @Published var sourceKind: AudioSourceKind = .system
    /// The chosen input device when it's unplugged and system audio is used meanwhile.
    @Published var missingDevice: String?
}
