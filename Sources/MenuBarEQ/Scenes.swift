import SwiftUI
import AppKit

/// The groups of settings a scene can set. Each scene can leave groups out, and those stay as they are.
enum ScenePart: String, CaseIterable, Identifiable, Codable {
    case visuals, colors, screen, glow, source, sound, lights, voice
    var id: String { rawValue }

    var title: String {
        switch self {
        case .visuals: return "Style"
        case .colors: return "Colors"
        case .screen: return "Screen colors"
        case .glow: return "Brightness and glow"
        case .source: return "Listen to"
        case .sound: return "Sensitivity"
        case .lights: return "Lights"
        case .voice: return "Voice"
        }
    }

    var symbol: String {
        switch self {
        case .visuals: return "chart.bar.fill"
        case .colors: return "paintpalette.fill"
        case .screen: return "sparkles.tv"
        case .glow: return "sun.max.fill"
        case .source: return "ear"
        case .sound: return "slider.horizontal.3"
        case .lights: return "lightbulb.2.fill"
        case .voice: return "music.mic"
        }
    }

    var help: String {
        switch self {
        case .visuals: return "Visuals on or off, the style, layout, number of bars, peak hold and spark power"
        case .colors: return "The palette, your Custom colors and color drift"
        case .screen: return "Screen colors on or off, Ambient light or Main colors, following light beams, their strength, and flashing your lights"
        case .glow: return "Brightness, opacity, readable menu bar text, the edge glow (depth and top edge), all displays and full screen"
        case .source: return "What Barbeat listens to: system audio, one app or an input"
        case .sound: return "Sensitivity, auto level, and low, mid and high"
        case .lights: return "Lights on or off, the light show, delay, when to give the lights back, and each device's switch, Mirror and sparkles"
        case .voice: return "Voice on or off, what it listens for, its colors, glow and strength, and where it shows"
        }
    }
}

/// One light device in a scene: whether Barbeat drives it, and its Mirror and sparkles. Matched by ID when the scene
/// is used, so a scene from someone else's Mac leaves your devices alone.
struct SceneLightDevice: Codable, Equatable {
    /// To make exported files readable.
    var name: String?
    var on: Bool?
    var effects: LightEffects?
}

/// A whole look: almost every setting. Nil fields are left as they are when it's applied.
struct SceneLook: Codable, Equatable {
    // Style (`.visuals`)
    var enabled: Bool?
    var style: String?, layout: String?, bandCount: Int?, showPeaks: Bool?, sparkPower: Double?
    // Colors
    var palette: String?, customGradient: CustomGradient?, colorDrift: String?
    // Screen colors
    var screenColors: Bool?, screenColorMode: String?, screenBeams: Bool?, screenBeamStrength: Double?
    var screenBeamsToLights: Bool?
    // Brightness and glow
    var brightness: Double?, opacity: Double?, readableMenuBar: Bool?
    var edgeGlow: Bool?, edgeGlowDepth: Double?, edgeGlowTop: Bool?
    var allDisplays: Bool?, showInFullScreen: Bool?, fullScreenStrip: Bool?
    // Listen to
    var audioSource: String?, sourceAppID: String?, sourceAppName: String?, sourceDeviceUID: String?
    var sourceDeviceName: String?
    // Sensitivity
    var sensitivity: Double?, autoLevel: Bool?, lowGain: Double?, midGain: Double?, highGain: Double?
    // Lights
    var lights: Bool?, lightMode: String?, baseGlow: Double?, beatFlash: Double?, lightBrightness: Double?
    var lightDelayMs: Double?, lightReleaseAfter: Int?
    /// By output ID ("hue:<bridge id>", "artnet:<uuid>").
    var lightDevices: [String: SceneLightDevice]?
    // Voice
    var voice: Bool?, voiceTarget: String?, voiceColorMode: String?, voiceColor: HSB?, voiceGlow: Bool?
    var voiceStrength: Double?, voiceOnMenuBar: Bool?, voiceOnEdgeGlow: Bool?, voiceOnLights: Bool?

    init() {}

    /// A field that can't be read (a hand-edited file, a newer version) is skipped instead of losing the whole scene.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys) -> T? { (try? c.decodeIfPresent(T.self, forKey: key)) ?? nil }
        enabled = v(.enabled); style = v(.style); layout = v(.layout); bandCount = v(.bandCount)
        showPeaks = v(.showPeaks); sparkPower = v(.sparkPower)
        palette = v(.palette); customGradient = v(.customGradient); colorDrift = v(.colorDrift)
        screenColors = v(.screenColors); screenColorMode = v(.screenColorMode); screenBeams = v(.screenBeams)
        screenBeamStrength = v(.screenBeamStrength); screenBeamsToLights = v(.screenBeamsToLights)
        brightness = v(.brightness); opacity = v(.opacity); readableMenuBar = v(.readableMenuBar)
        edgeGlow = v(.edgeGlow); edgeGlowDepth = v(.edgeGlowDepth); edgeGlowTop = v(.edgeGlowTop)
        allDisplays = v(.allDisplays); showInFullScreen = v(.showInFullScreen); fullScreenStrip = v(.fullScreenStrip)
        audioSource = v(.audioSource); sourceAppID = v(.sourceAppID); sourceAppName = v(.sourceAppName)
        sourceDeviceUID = v(.sourceDeviceUID); sourceDeviceName = v(.sourceDeviceName)
        sensitivity = v(.sensitivity); autoLevel = v(.autoLevel); lowGain = v(.lowGain); midGain = v(.midGain)
        highGain = v(.highGain)
        lights = v(.lights); lightMode = v(.lightMode); baseGlow = v(.baseGlow); beatFlash = v(.beatFlash)
        lightBrightness = v(.lightBrightness); lightDelayMs = v(.lightDelayMs); lightReleaseAfter = v(.lightReleaseAfter)
        lightDevices = v(.lightDevices)
        voice = v(.voice); voiceTarget = v(.voiceTarget); voiceColorMode = v(.voiceColorMode); voiceColor = v(.voiceColor)
        voiceGlow = v(.voiceGlow); voiceStrength = v(.voiceStrength); voiceOnMenuBar = v(.voiceOnMenuBar)
        voiceOnEdgeGlow = v(.voiceOnEdgeGlow); voiceOnLights = v(.voiceOnLights)
    }

    /// Everything as it is right now.
    static func current() -> SceneLook {
        let s = Settings.shared, l = LightSettings.shared, v = VoiceSettings.shared
        var look = SceneLook()
        look.enabled = s.enabled
        look.style = s.style.rawValue
        look.layout = s.layout.rawValue
        look.bandCount = s.bandCount
        look.showPeaks = s.showPeaks
        look.sparkPower = s.sparkPower

        look.palette = s.palette.rawValue
        look.customGradient = s.palette == .custom ? s.customGradient : nil
        look.colorDrift = s.colorDrift.rawValue

        look.screenColors = s.screenColors
        look.screenColorMode = s.screenColorMode.rawValue
        look.screenBeams = s.screenBeams
        look.screenBeamStrength = s.screenBeamStrength
        look.screenBeamsToLights = s.screenBeamsToLights

        look.brightness = s.brightness
        look.opacity = s.opacity
        look.readableMenuBar = s.readableMenuBar
        look.edgeGlow = s.edgeGlow
        look.edgeGlowDepth = s.edgeGlowDepth
        look.edgeGlowTop = s.edgeGlowTop
        look.allDisplays = s.allDisplays
        look.showInFullScreen = s.showInFullScreen
        look.fullScreenStrip = s.fullScreenStrip

        look.audioSource = s.audioSource.rawValue
        look.sourceAppID = s.sourceAppID
        look.sourceAppName = s.sourceAppName
        look.sourceDeviceUID = s.sourceDeviceUID
        look.sourceDeviceName = s.sourceDeviceName

        look.sensitivity = s.sensitivity
        look.autoLevel = s.autoLevel
        look.lowGain = s.lowGain
        look.midGain = s.midGain
        look.highGain = s.highGain

        look.lights = l.enabled
        look.lightMode = l.mode.rawValue
        look.baseGlow = l.baseGlow
        look.beatFlash = l.beatFlash
        look.lightBrightness = l.maxBrightness
        look.lightDelayMs = l.delayMs
        look.lightReleaseAfter = l.releaseAfter.rawValue
        var devices: [String: SceneLightDevice] = [:]
        for (id, name) in l.sceneDevices {
            devices[id] = SceneLightDevice(name: name, on: l.isOn(id), effects: l.effects(for: id))
        }
        look.lightDevices = devices.isEmpty ? nil : devices

        look.voice = v.enabled
        look.voiceTarget = v.target.rawValue
        look.voiceColorMode = v.colorMode.rawValue
        look.voiceColor = v.color
        look.voiceGlow = v.glow
        look.voiceStrength = v.strength
        look.voiceOnMenuBar = v.onMenuBar
        look.voiceOnEdgeGlow = v.onEdgeGlow
        look.voiceOnLights = v.onLights
        return look
    }

    /// `interactive`: picked by hand, so turning Screen colors on may explain and ask for permission first.
    /// Automatic switches never put up a dialog: without permission, Screen colors stays as it is.
    func apply(interactive: Bool) {
        cleaned().applyCleaned(interactive: interactive)
    }

    /// Keeps values from a file inside the ranges the settings allow (and drops numbers that aren't numbers).
    func cleaned() -> SceneLook {
        func clamp(_ value: Double?, _ range: ClosedRange<Double>) -> Double? {
            guard let value, value.isFinite else { return nil }
            return min(max(value, range.lowerBound), range.upperBound)
        }
        var c = self
        c.bandCount = bandCount.flatMap { n in Settings.bandChoices.min { abs($0 - n) < abs($1 - n) } }
        c.sparkPower = clamp(sparkPower, 0...1)
        c.customGradient = customGradient.map { g in
            CustomGradient(colors: g.colors.map { HSB(h: $0.h, s: $0.s, b: $0.b) }, byHeight: g.byHeight)
        }
        c.screenBeamStrength = clamp(screenBeamStrength, Settings.screenBeamStrengthRange)
        c.brightness = clamp(brightness, 0.3...2)
        c.opacity = clamp(opacity, 0.15...1)
        c.edgeGlowDepth = clamp(edgeGlowDepth, Settings.edgeGlowDepthRange)
        c.sensitivity = clamp(sensitivity, -12...12)
        c.lowGain = clamp(lowGain, -12...12)
        c.midGain = clamp(midGain, -12...12)
        c.highGain = clamp(highGain, -12...12)
        c.baseGlow = clamp(baseGlow, 0...0.6)
        c.beatFlash = clamp(beatFlash, 0...1)
        c.lightBrightness = clamp(lightBrightness, 0.1...1)
        c.lightDelayMs = clamp(lightDelayMs, 0...2000)
        c.voiceColor = voiceColor.map { HSB(h: $0.h, s: $0.s, b: $0.b) }
        c.voiceStrength = clamp(voiceStrength, 0.1...1)
        return c
    }

    private func applyCleaned(interactive: Bool) {
        let s = Settings.shared, l = LightSettings.shared, v = VoiceSettings.shared
        func put<O: AnyObject, T: Equatable>(_ value: T?, _ object: O, _ path: ReferenceWritableKeyPath<O, T>) {
            if let value, object[keyPath: path] != value { object[keyPath: path] = value }
        }

        put(style.flatMap(EQStyle.init(rawValue:)), s, \.style)
        put(layout.flatMap(EQLayout.init(rawValue:)), s, \.layout)
        put(bandCount, s, \.bandCount)
        put(showPeaks, s, \.showPeaks)
        put(sparkPower, s, \.sparkPower)

        put(customGradient, s, \.customGradient)
        if let palette = palette.flatMap(Palette.init(rawValue:)), palette != .screen { put(palette, s, \.palette) }
        put(colorDrift.flatMap(ColorDrift.init(rawValue:)), s, \.colorDrift)

        put(screenColorMode.flatMap(ScreenColorMode.init(rawValue:)), s, \.screenColorMode)
        put(screenBeams, s, \.screenBeams)
        put(screenBeamStrength, s, \.screenBeamStrength)
        put(screenBeamsToLights, s, \.screenBeamsToLights)

        put(brightness, s, \.brightness)
        put(opacity, s, \.opacity)
        put(readableMenuBar, s, \.readableMenuBar)
        put(edgeGlowDepth, s, \.edgeGlowDepth)
        put(edgeGlowTop, s, \.edgeGlowTop)
        put(edgeGlow, s, \.edgeGlow)
        put(allDisplays, s, \.allDisplays)
        put(fullScreenStrip, s, \.fullScreenStrip)
        put(showInFullScreen, s, \.showInFullScreen)

        // The app and device before the kind, so capture switches straight to the right one.
        if let sourceAppID {
            put(sourceAppName ?? sourceAppID, s, \.sourceAppName)
            put(sourceAppID, s, \.sourceAppID)
        }
        if let sourceDeviceUID {
            put(sourceDeviceName ?? sourceDeviceUID, s, \.sourceDeviceName)
            put(sourceDeviceUID, s, \.sourceDeviceUID)
        }
        put(audioSource.flatMap(AudioSourceKind.init(rawValue:)), s, \.audioSource)

        put(sensitivity, s, \.sensitivity)
        put(autoLevel, s, \.autoLevel)
        put(lowGain, s, \.lowGain)
        put(midGain, s, \.midGain)
        put(highGain, s, \.highGain)

        put(enabled, s, \.enabled)
        if let screenColors, screenColors != s.screenColors {
            if !screenColors {
                s.screenColors = false
            } else if CGPreflightScreenCaptureAccess() {
                s.screenColors = true
            } else if interactive {
                ScreenColorsAccess.turnOn(s)
            }
        }

        put(lightMode.flatMap(LightMode.init(rawValue:)), l, \.mode)
        put(baseGlow, l, \.baseGlow)
        put(beatFlash, l, \.beatFlash)
        put(lightBrightness, l, \.maxBrightness)
        put(lightDelayMs, l, \.delayMs)
        put(lightReleaseAfter.flatMap(ReleaseAfter.init(rawValue:)), l, \.releaseAfter)
        if let lightDevices {
            // Only devices set up on this Mac: a friend's devices are skipped, yours not in the scene are left alone.
            let known = Set(l.sceneDevices.map { $0.id })
            for (id, device) in lightDevices where known.contains(id) {
                if let on = device.on, l.isOn(id) != on { l.setOn(on, id) }
                if let effects = device.effects { l.setEffects(effects, for: id) }
            }
        }
        put(lights, l, \.enabled)

        put(voiceTarget.flatMap(VoiceTarget.init(rawValue:)), v, \.target)
        put(voiceColorMode.flatMap(VoiceColorMode.init(rawValue:)), v, \.colorMode)
        put(voiceColor, v, \.color)
        put(voiceGlow, v, \.glow)
        put(voiceStrength, v, \.strength)
        put(voiceOnMenuBar, v, \.onMenuBar)
        put(voiceOnEdgeGlow, v, \.onEdgeGlow)
        put(voiceOnLights, v, \.onLights)
        put(voice, v, \.enabled)
    }

    // MARK: - Parts

    /// Copies one part's fields from `other`, nils included.
    private mutating func copy(_ part: ScenePart, from o: SceneLook) {
        switch part {
        case .visuals:
            enabled = o.enabled; style = o.style; layout = o.layout; bandCount = o.bandCount
            showPeaks = o.showPeaks; sparkPower = o.sparkPower
        case .colors:
            palette = o.palette; customGradient = o.customGradient; colorDrift = o.colorDrift
        case .screen:
            screenColors = o.screenColors; screenColorMode = o.screenColorMode; screenBeams = o.screenBeams
            screenBeamStrength = o.screenBeamStrength; screenBeamsToLights = o.screenBeamsToLights
        case .glow:
            brightness = o.brightness; opacity = o.opacity; readableMenuBar = o.readableMenuBar
            edgeGlow = o.edgeGlow; edgeGlowDepth = o.edgeGlowDepth; edgeGlowTop = o.edgeGlowTop
            allDisplays = o.allDisplays; showInFullScreen = o.showInFullScreen; fullScreenStrip = o.fullScreenStrip
        case .source:
            audioSource = o.audioSource; sourceAppID = o.sourceAppID; sourceAppName = o.sourceAppName
            sourceDeviceUID = o.sourceDeviceUID; sourceDeviceName = o.sourceDeviceName
        case .sound:
            sensitivity = o.sensitivity; autoLevel = o.autoLevel; lowGain = o.lowGain; midGain = o.midGain
            highGain = o.highGain
        case .lights:
            lights = o.lights; lightMode = o.lightMode; baseGlow = o.baseGlow; beatFlash = o.beatFlash
            lightBrightness = o.lightBrightness; lightDelayMs = o.lightDelayMs; lightReleaseAfter = o.lightReleaseAfter
            lightDevices = o.lightDevices
        case .voice:
            voice = o.voice; voiceTarget = o.voiceTarget; voiceColorMode = o.voiceColorMode; voiceColor = o.voiceColor
            voiceGlow = o.voiceGlow; voiceStrength = o.voiceStrength; voiceOnMenuBar = o.voiceOnMenuBar
            voiceOnEdgeGlow = o.voiceOnEdgeGlow; voiceOnLights = o.voiceOnLights
        }
    }

    /// Whether it sets anything in this part.
    func has(_ part: ScenePart) -> Bool {
        var only = SceneLook()
        only.copy(part, from: self)
        return only != SceneLook()
    }

    /// Just these parts.
    func only(_ parts: [ScenePart]) -> SceneLook {
        var out = SceneLook()
        for part in parts { out.copy(part, from: self) }
        return out
    }

    /// Takes a part from `other` (the current settings, when you tick a part a scene didn't have).
    mutating func take(_ part: ScenePart, from other: SceneLook) { copy(part, from: other) }

    var isEmpty: Bool { self == SceneLook() }

    /// Whether everything it sets is already so in `now`. Names don't count, nor devices that aren't set up here.
    func isSatisfied(by now: SceneLook) -> Bool {
        guard !isEmpty else { return false }
        var mine = cleaned()
        if let devices = mine.lightDevices {
            for (id, device) in devices {
                guard let there = now.lightDevices?[id] else { continue }
                if let on = device.on, on != there.on { return false }
                if let effects = device.effects, effects != there.effects { return false }
            }
        }
        mine.lightDevices = nil
        mine.sourceAppName = nil
        mine.sourceDeviceName = nil
        guard let a = mine.dictionary, let b = now.dictionary else { return false }
        for (key, value) in a {
            guard let other = b[key], (value as AnyObject).isEqual(other) else { return false }
        }
        return true
    }

    private var dictionary: [String: Any]? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A few words about it, for the Scenes page.
    var summary: String {
        var parts: [String] = []
        if enabled == false { parts.append("Visuals off") }
        if let style = style.flatMap(EQStyle.init(rawValue:)), enabled != false { parts.append(style.title) }
        if screenColors == true {
            parts.append(screenColorMode.flatMap(ScreenColorMode.init(rawValue:)).map { "Screen colors (\($0.title))" }
                ?? "Screen colors")
            if screenBeams == true { parts.append("light beams") }
        } else if let palette = palette.flatMap(Palette.init(rawValue:)), palette != .screen {
            parts.append(colorDrift.flatMap(ColorDrift.init(rawValue:)).map { $0 == .off ? palette.title : "\(palette.title), drifting" }
                ?? palette.title)
        }
        if let brightness { parts.append("\(Int((brightness * 100).rounded()))% bright") }
        if edgeGlow == false { parts.append("no edge glow") } else if edgeGlow == true, let edgeGlowDepth {
            parts.append("\(Int(edgeGlowDepth.rounded())) pt glow")
        }
        if let kind = audioSource.flatMap(AudioSourceKind.init(rawValue:)) {
            switch kind {
            case .system: parts.append("system audio")
            case .app: parts.append("listens to \(sourceAppName ?? "one app")")
            case .device: parts.append("listens to \(sourceDeviceName ?? "an input")")
            }
        }
        if let lights { parts.append(lights ? "lights on" : "lights off") }
        let here = Set(LightSettings.shared.sceneDevices.map { $0.id })
        if let off = lightDevices?.filter({ here.contains($0.key) && $0.value.on == false }).count, off > 0, lights != false {
            parts.append(off == 1 ? "1 device off" : "\(off) devices off")
        }
        if let voice { parts.append(voice ? "voice" : "no voice") }
        return parts.joined(separator: " · ")
    }
}

extension LightSettings {
    /// The devices set up here, by output ID, with a name to show.
    var sceneDevices: [(id: String, name: String)] {
        hueBridges.map { ("hue:\($0.id)", $0.areaName ?? $0.name) } + artNetDevices.map { ("artnet:\($0.id.uuidString)", $0.name) }
    }
}

/// An app that switches a scene on when it plays sound.
struct SceneApp: Codable, Hashable {
    var id: String
    var name: String
}

/// A saved look, and when to switch to it on its own.
struct BarbeatScene: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var symbol = "sparkles"
    var look: SceneLook
    /// Parts left out: using the scene leaves them as they are (their saved values are kept, for ticking them again).
    var skipped: [ScenePart] = []
    /// Switch to it while an app uses a microphone (a FaceTime, Zoom or Meet call).
    var onCall = false
    /// Switch to it while one of these apps plays sound.
    var apps: [SceneApp] = []

    var isAutomatic: Bool { onCall || !apps.isEmpty }

    init(name: String, symbol: String = "sparkles", look: SceneLook, onCall: Bool = false, apps: [SceneApp] = []) {
        self.name = name
        self.symbol = symbol
        self.look = look
        self.onCall = onCall
        self.apps = apps
    }

    /// Missing keys keep their defaults, so scenes saved by older and newer versions still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Scene"
        symbol = (try? c.decodeIfPresent(String.self, forKey: .symbol)) ?? "sparkles"
        look = (try? c.decodeIfPresent(SceneLook.self, forKey: .look)) ?? SceneLook()
        skipped = ((try? c.decodeIfPresent([String].self, forKey: .skipped)) ?? []).compactMap(ScenePart.init(rawValue:))
        onCall = (try? c.decodeIfPresent(Bool.self, forKey: .onCall)) ?? false
        apps = (try? c.decodeIfPresent([SceneApp].self, forKey: .apps)) ?? []
    }

    /// What using it sets: the look without the skipped parts.
    var effectiveLook: SceneLook { look.only(ScenePart.allCases.filter { !skipped.contains($0) }) }

    func includes(_ part: ScenePart) -> Bool { look.has(part) && !skipped.contains(part) }

    /// Ticking a part it never had takes that part from `current`.
    mutating func setIncluded(_ part: ScenePart, _ on: Bool, current: SceneLook) {
        if on {
            skipped.removeAll { $0 == part }
            if !look.has(part) { look.take(part, from: current) }
        } else if !skipped.contains(part) {
            skipped.append(part)
            skipped.sort { ScenePart.allCases.firstIndex(of: $0)! < ScenePart.allCases.firstIndex(of: $1)! }
        }
    }

    /// Fixes up a scene read from a file: a name, a symbol that exists, sensible triggers.
    func cleanedUp() -> BarbeatScene {
        var scene = self
        scene.look = look.cleaned()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        scene.name = trimmed.isEmpty ? "Scene" : String(trimmed.prefix(60))
        if NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil { scene.symbol = "sparkles" }
        var seen = Set<String>()
        scene.apps = apps.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }.prefix(20).map { $0 }
        return scene
    }
}

/// The scenes, applying them, and switching on their own.
final class SceneStore: ObservableObject {
    static let shared = SceneStore()
    private let defaults = UserDefaults.standard

    @Published var scenes: [BarbeatScene] { didSet { store() } }
    @Published var autoSwitch: Bool { didSet { defaults.set(autoSwitch, forKey: Key.autoSwitch) } }
    /// The scene last applied (by hand or automatically). Remembered across launches.
    @Published private(set) var activeID: UUID? {
        didSet { defaults.set(activeID?.uuidString, forKey: Key.active) }
    }
    /// Set while a scene was switched on automatically, with why ("Safari is playing").
    @Published private(set) var automaticID: UUID?
    @Published private(set) var automaticReason = ""
    /// A line for the Scenes page after importing or exporting.
    @Published private(set) var message: (text: String, isProblem: Bool)?

    /// How things were before an automatic switch. Saved, so quitting during a call doesn't leave the call's look.
    private var restoreLook: SceneLook? {
        didSet { saveRestore() }
    }
    private var restoreActiveID: UUID?
    /// The scene whose trigger you overrode by picking another one; it waits until its trigger ends.
    private var dismissedID: UUID?
    private var wantedID: UUID?
    private var wantedSince: Double = 0
    private var timer: Timer?
    private var messageClear: DispatchWorkItem?
    private let log = CommandLine.arguments.contains("--verbose")
    /// `--pretend-trigger call:3:12` (or `<bundle id>:3:12`) acts as if a call (or that app playing) ran from 3 s to 12 s
    /// after launch, to test switching without sound or a mic.
    private static let pretend: (what: String, from: Double, to: Double)? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--pretend-trigger"), i + 1 < args.count else { return nil }
        let parts = args[i + 1].split(separator: ":")
        guard parts.count == 3, let from = Double(parts[1]), let to = Double(parts[2]) else { return nil }
        return (String(parts[0]), from, to)
    }()
    private let launched = CACurrentMediaTime()

    private enum Key {
        static let scenes = "scenes", autoSwitch = "scenes.autoSwitch", active = "scenes.active"
        static let restore = "scenes.restore", chameleonAdded = "scenes.chameleonAdded"
    }

    private struct Restore: Codable {
        var look: SceneLook
        var activeID: UUID?
    }

    private init() {
        defaults.register(defaults: [Key.autoSwitch: true])
        autoSwitch = defaults.bool(forKey: Key.autoSwitch)
        activeID = defaults.string(forKey: Key.active).flatMap(UUID.init(uuidString:))
        let saved = defaults.string(forKey: Key.scenes).flatMap { try? JSONDecoder().decode([BarbeatScene].self, from: Data($0.utf8)) }
        scenes = saved ?? Self.starters
        // Chameleon came after the first starters: everyone gets it once, at the top.
        if !defaults.bool(forKey: Key.chameleonAdded) {
            defaults.set(true, forKey: Key.chameleonAdded)
            if !scenes.contains(where: { $0.name == Self.chameleon.name }) {
                scenes.insert(Self.chameleon, at: 0)
                store()
            }
        }
        if let id = activeID, !scenes.contains(where: { $0.id == id }) { activeID = nil }
    }

    /// Ichiro's own setup: the screen's colors with light beams, Center bars, a deep glow, the lights and the voice
    /// (pitch colors). Leaves what Barbeat listens to and each light device as they are.
    static let chameleon: BarbeatScene = {
        var look = SceneLook()
        look.enabled = true; look.style = EQStyle.center.rawValue; look.layout = EQLayout.stereo.rawValue
        look.bandCount = 128; look.showPeaks = false; look.sparkPower = 0.6
        look.palette = Palette.custom.rawValue; look.customGradient = CustomGradient.default
        look.colorDrift = ColorDrift.slow.rawValue
        look.screenColors = true; look.screenColorMode = ScreenColorMode.ambient.rawValue; look.screenBeams = true
        look.screenBeamStrength = 1.06; look.screenBeamsToLights = true
        look.brightness = 2; look.opacity = 0.8; look.readableMenuBar = true
        look.edgeGlow = true; look.edgeGlowDepth = 241; look.edgeGlowTop = true
        look.allDisplays = true; look.showInFullScreen = true; look.fullScreenStrip = false
        look.sensitivity = -2; look.autoLevel = true; look.lowGain = -4; look.midGain = -2; look.highGain = 0
        look.lights = true; look.lightMode = LightMode.auto.rawValue; look.baseGlow = 0.12; look.beatFlash = 0.79
        look.lightBrightness = 1; look.lightDelayMs = 0; look.lightReleaseAfter = ReleaseAfter.thirtySeconds.rawValue
        look.voice = true; look.voiceTarget = VoiceTarget.both.rawValue; look.voiceColorMode = VoiceColorMode.pitch.rawValue
        look.voiceColor = HSB(h: 0.99, s: 0.85, b: 1); look.voiceGlow = true; look.voiceStrength = 1
        look.voiceOnMenuBar = true; look.voiceOnEdgeGlow = true; look.voiceOnLights = true
        return BarbeatScene(name: "Chameleon", symbol: "lizard.fill", look: look)
    }()

    static let starters: [BarbeatScene] = [
        chameleon,
        BarbeatScene(name: "On a call", symbol: "phone.fill",
                     look: { var l = SceneLook(); l.enabled = false; l.lights = false; l.voice = false; return l }(),
                     onCall: true),
        BarbeatScene(name: "Concert", symbol: "music.mic", look: {
            var l = SceneLook()
            l.enabled = true; l.style = "center"; l.layout = "stereo"; l.bandCount = 128
            l.screenColors = true; l.screenColorMode = "ambient"; l.screenBeams = true; l.screenBeamsToLights = true
            l.brightness = 1.4; l.opacity = 0.8; l.edgeGlow = true
            l.lights = true; l.lightMode = "auto"; l.baseGlow = 0.12; l.beatFlash = 0.75; l.lightBrightness = 1
            return l
        }()),
        BarbeatScene(name: "Chill", symbol: "moon.stars.fill", look: {
            var l = SceneLook()
            l.enabled = true; l.style = "glow"; l.colorDrift = "slow"; l.screenColors = false
            l.brightness = 0.9; l.opacity = 0.6; l.edgeGlow = true
            l.lights = true; l.lightMode = "auto"; l.baseGlow = 0.3; l.beatFlash = 0.15; l.lightBrightness = 0.6
            return l
        }()),
        BarbeatScene(name: "Focus", symbol: "laptopcomputer", look: {
            var l = SceneLook()
            l.enabled = true; l.style = "bars"; l.layout = "full"; l.bandCount = 64; l.screenColors = false
            l.brightness = 0.7; l.opacity = 0.35; l.edgeGlow = false; l.lights = false; l.voice = false
            return l
        }()),
    ]

    var active: BarbeatScene? { scenes.first { $0.id == activeID } }

    // MARK: - Using scenes

    /// Picked by hand: also cancels an automatic switch (until its trigger ends).
    func apply(_ scene: BarbeatScene) {
        if automaticID != nil {
            dismissedID = automaticID
            automaticID = nil
            restoreLook = nil
        } else if let wantedID {
            dismissedID = wantedID
        }
        scene.effectiveLook.apply(interactive: true)
        activeID = scene.id
    }

    func apply(named name: String) -> Bool {
        guard let scene = scenes.first(where: { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame })
        else { return false }
        apply(scene)
        return true
    }

    @discardableResult
    func saveCurrent(named name: String) -> BarbeatScene {
        let scene = BarbeatScene(name: name, look: .current())
        scenes.append(scene)
        activeID = scene.id
        return scene
    }

    func updateWithCurrent(_ id: UUID) {
        guard let i = scenes.firstIndex(where: { $0.id == id }) else { return }
        scenes[i].look = .current()
        activeID = id
    }

    func duplicate(_ id: UUID) {
        guard let i = scenes.firstIndex(where: { $0.id == id }) else { return }
        var copy = scenes[i]
        copy.id = UUID()
        copy.name = uniqueName(copy.name)
        // A copy that switched on by itself would fight the original.
        copy.onCall = false
        copy.apps = []
        scenes.insert(copy, at: i + 1)
    }

    func delete(_ id: UUID) {
        scenes.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
        if automaticID == id { automaticID = nil; restoreLook = nil }
    }

    func move(_ id: UUID, by offset: Int) {
        guard let i = scenes.firstIndex(where: { $0.id == id }) else { return }
        let j = min(scenes.count - 1, max(0, i + offset))
        guard i != j else { return }
        scenes.swapAt(i, j)
    }

    /// "Concert" → "Concert 2" when there's already a Concert.
    func uniqueName(_ name: String, among list: [BarbeatScene]? = nil) -> String {
        let list = list ?? scenes
        guard list.contains(where: { $0.name == name }) else { return name }
        var base = name, n = 2
        if let match = name.range(of: #" \d+$"#, options: .regularExpression), let number = Int(name[match].dropFirst()) {
            base = String(name[..<match.lowerBound])
            n = number + 1
        }
        while list.contains(where: { $0.name == "\(base) \(n)" }) { n += 1 }
        return "\(base) \(n)"
    }

    /// Asks for a name, then saves the current look as a new scene.
    static func promptSave() {
        let alert = NSAlert()
        alert.messageText = "Save the current look as a scene"
        alert.informativeText = "Saves almost every setting as it is now: the style, colors, Screen colors, brightness and glow, what Barbeat listens to, sensitivity, lights and voice. You can leave parts out afterwards."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = shared.uniqueName("Scene \(shared.scenes.count + 1)")
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        shared.saveCurrent(named: name.isEmpty ? shared.uniqueName("Scene \(shared.scenes.count + 1)") : name)
    }

    // MARK: - Importing

    enum Conflict { case replace, keepBoth }

    /// Adds scenes read from a file. A scene that's already here (the same scene, from a backup) is replaced or
    /// kept next to the one here. Returns how many were added and replaced.
    @discardableResult
    func add(_ incoming: [BarbeatScene], onConflict: Conflict) -> (added: Int, replaced: Int) {
        var added = 0, replaced = 0
        var list = scenes
        for original in incoming {
            var scene = original.cleanedUp()
            if let i = list.firstIndex(where: { $0.id == scene.id }) {
                if onConflict == .replace {
                    list[i] = scene
                    replaced += 1
                    continue
                }
                scene.id = UUID()
            }
            scene.name = uniqueName(scene.name, among: list)
            list.append(scene)
            added += 1
        }
        scenes = list
        return (added, replaced)
    }

    func say(_ text: String, problem: Bool = false) {
        message = (text, problem)
        messageClear?.cancel()
        let clear = DispatchWorkItem { [weak self] in self?.message = nil }
        messageClear = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: clear)
    }

    // MARK: - Switching on their own

    /// Looks every two seconds at which apps are playing and whether a call is on.
    func start() {
        // Barbeat quit while a scene was switched on by itself: put things back first. If the trigger is still on,
        // it switches again in a moment.
        if let text = defaults.string(forKey: Key.restore),
           let saved = try? JSONDecoder().decode(Restore.self, from: Data(text.utf8)) {
            note("putting back how things were before the last automatic switch")
            saved.look.apply(interactive: false)
            activeID = saved.activeID
            defaults.removeObject(forKey: Key.restore)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.evaluate() }
    }

    private func evaluate() {
        guard autoSwitch, scenes.contains(where: \.isAutomatic) else {
            if automaticID != nil { endAutomatic() }
            return
        }
        let processes = HAL.audioProcesses()
        let own = ProcessInfo.processInfo.processIdentifier
        let settings = Settings.shared
        var onCall = HAL.microphoneInUse(except: settings.audioSource == .device ? settings.sourceDeviceUID : nil)
        let playing = processes.filter { $0.isPlaying && $0.pid != own }
        var pretendApp: String?
        if let p = Self.pretend, (p.from...p.to).contains(CACurrentMediaTime() - launched) {
            if p.what == "call" { onCall = true } else { pretendApp = p.what }
        }

        var wanted: (scene: BarbeatScene, reason: String)?
        if onCall, let scene = scenes.first(where: \.onCall) {
            wanted = (scene, "you're on a call")
        } else {
            outer: for scene in scenes {
                for app in scene.apps {
                    let path = HAL.appPath(app.id)
                    if app.id == pretendApp || playing.contains(where: { HAL.process($0, belongsTo: app.id, appPath: path) }) {
                        wanted = (scene, "\(app.name) is playing")
                        break outer
                    }
                }
            }
        }

        let now = CACurrentMediaTime()
        if wanted?.scene.id != wantedID {
            wantedID = wanted?.scene.id
            wantedSince = now
        }
        // A trigger you overrode stays overridden until it ends.
        if let dismissedID, wanted?.scene.id != dismissedID { self.dismissedID = nil }

        if let wanted {
            if wanted.scene.id == automaticID { automaticReason = wanted.reason; return }
            // Wait a moment, so a notification sound or a quick preview doesn't switch scenes.
            guard wanted.scene.id != dismissedID, now - wantedSince >= 3 else { return }
            if automaticID == nil {
                restoreActiveID = activeID
                restoreLook = .current()
            }
            note("switching to \(wanted.scene.name): \(wanted.reason)")
            wanted.scene.effectiveLook.apply(interactive: false)
            activeID = wanted.scene.id
            automaticID = wanted.scene.id
            automaticReason = wanted.reason
        } else if automaticID != nil, now - wantedSince >= 8 {
            // Back to how things were, after a pause long enough not to flip between songs.
            endAutomatic()
        }
    }

    private func endAutomatic() {
        note("back to how things were")
        restoreLook?.apply(interactive: false)
        restoreLook = nil
        activeID = restoreActiveID
        automaticID = nil
        automaticReason = ""
    }

    private func saveRestore() {
        if let restoreLook, let data = try? JSONEncoder().encode(Restore(look: restoreLook, activeID: restoreActiveID)) {
            defaults.set(String(data: data, encoding: .utf8), forKey: Key.restore)
        } else {
            defaults.removeObject(forKey: Key.restore)
        }
    }

    private func note(_ text: String) {
        if log { print("scenes: \(text)") }
    }

    private func store() {
        guard let data = try? JSONEncoder().encode(scenes), let text = String(data: data, encoding: .utf8) else { return }
        defaults.set(text, forKey: Key.scenes)
    }
}
