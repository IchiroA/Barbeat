import Foundation
import Combine
import Security

/// When Barbeat gives the lights back after the music stops.
enum ReleaseAfter: Int, CaseIterable, Identifiable, Codable {
    case tenSeconds = 10, thirtySeconds = 30, twoMinutes = 120, never = 0
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .tenSeconds: return "10 s"
        case .thirtySeconds: return "30 s"
        case .twoMinutes: return "2 min"
        case .never: return "Never"
        }
    }

    var seconds: Double? { self == .never ? nil : Double(rawValue) }
}

/// A Hue Bridge Barbeat is paired with, and the entertainment area it plays on.
/// The bridge's keys are kept in the Keychain, not here.
struct HueBridgeConfig: Codable, Identifiable, Equatable {
    /// The bridge ID (from the bridge itself), e.g. "001788fffe123456".
    var id: String
    /// IP address, or "address:port" (for testing).
    var host: String
    var name: String
    var areaID: String?
    var areaName: String?
    /// SHA-256 of the bridge's certificate, remembered the first time Barbeat talks to it.
    var certificateSHA256: String?
}

/// How an Art-Net fixture uses its DMX channels.
enum FixtureProfile: String, CaseIterable, Identifiable, Codable {
    case rgb, grb, rgbw, dimmerRGB, rgbDimmer, dimmerRGBW
    var id: String { rawValue }

    var title: String {
        switch self {
        case .rgb: return "RGB"
        case .grb: return "GRB"
        case .rgbw: return "RGBW"
        case .dimmerRGB: return "Dimmer + RGB"
        case .rgbDimmer: return "RGB + Dimmer"
        case .dimmerRGBW: return "Dimmer + RGBW"
        }
    }

    var channels: Int {
        switch self {
        case .rgb, .grb: return 3
        case .rgbw, .dimmerRGB, .rgbDimmer: return 4
        case .dimmerRGBW: return 5
        }
    }
}

/// What an Art-Net device does when Barbeat gives the lights back.
enum ArtNetStopAction: String, CaseIterable, Identifiable, Codable {
    case handBack, fadeOut, hold
    var id: String { rawValue }

    var title: String {
        switch self {
        case .handBack: return "Hand back"
        case .fadeOut: return "Fade to black"
        case .hold: return "Hold last color"
        }
    }

    var help: String {
        switch self {
        case .handBack: return "Barbeat stops sending. WLED goes back to its own effect after its realtime timeout."
        case .fadeOut: return "The lights fade out over a second."
        case .hold: return "The lights keep the last color (most DMX nodes hold the last frame)."
        }
    }
}

/// An Art-Net node: a WLED strip, a DMX interface, or a fixture that speaks Art-Net.
struct ArtNetDevice: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "Art-Net device"
    var host = ""
    /// 15-bit Art-Net port address (net, sub-net and universe together).
    var universe = 0
    /// DMX address of the first fixture, 1...512.
    var startAddress = 1
    var profile = FixtureProfile.rgb
    /// Number of fixtures, or pixels on a strip.
    var count = 1
    /// The first fixture is on the right.
    var reversed = false
    /// LEDs are linear: correct so dim colors look right.
    var gamma = true
    var onStop = ArtNetStopAction.handBack
}

/// What a device's lights do with the voice (when Voice is on).
enum LightVoiceMode: String, CaseIterable, Identifiable, Codable {
    case off, follow, words
    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .follow: return "Follow the singer"
        case .words: return "Sparkles on words"
        }
    }
}

/// A device's own extras on top of the light show: Mirror, white sparkles on the beat, and the voice.
struct LightEffects: Codable, Equatable {
    /// The two halves match, mirrored around the middle.
    var mirror = false
    /// Mirror with bass at both ends (else bass in the middle).
    var mirrorFromEnds = false
    var sparkles = false
    /// The most sparkles showing at once. Nil: picked from the number of lights.
    var maxSparkles: Int?
    /// Seconds a sparkle takes to fade out.
    var sparkleFade = LightEffects.defaultFade
    var voice = LightVoiceMode.off

    /// Shows the Max sparkles and Fade settings (sparkles on the beat or on words).
    var usesSparkles: Bool { sparkles || voice == .words }

    static let defaultFade = 0.4, fadeRange = 0.1...2.0

    init() {}

    /// Missing keys keep their defaults, so saves from older and newer versions still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mirror = try c.decodeIfPresent(Bool.self, forKey: .mirror) ?? false
        mirrorFromEnds = try c.decodeIfPresent(Bool.self, forKey: .mirrorFromEnds) ?? false
        sparkles = try c.decodeIfPresent(Bool.self, forKey: .sparkles) ?? false
        maxSparkles = try c.decodeIfPresent(Int.self, forKey: .maxSparkles)
        sparkleFade = try c.decodeIfPresent(Double.self, forKey: .sparkleFade) ?? Self.defaultFade
        voice = (try? c.decodeIfPresent(LightVoiceMode.self, forKey: .voice)) ?? .off
    }

    /// How many lights can sparkle at once on a device with `lightCount` lights (a mirrored pair counts as one).
    func sparkleLimit(lightCount: Int) -> Int {
        let places = max(1, mirror ? (lightCount + 1) / 2 : lightCount)
        return min(places, max(1, maxSparkles ?? max(1, min(24, (places + 2) / 4))))
    }
}

extension LightShow.Options {
    /// `voice`: Voice is on, so the device's voice option counts.
    mutating func apply(_ effects: LightEffects, lightCount: Int, voice: Bool) {
        followVoice = voice && effects.voice == .follow
        wordSparkles = voice && effects.voice == .words
        mirror = effects.mirror
        mirrorFromEnds = effects.mirrorFromEnds
        sparkles = effects.sparkles
        maxSparkles = effects.sparkleLimit(lightCount: lightCount)
        sparkleFade = Float(min(LightEffects.fadeRange.upperBound, max(LightEffects.fadeRange.lowerBound, effects.sparkleFade)))
    }
}

/// The lights' preferences, saved to UserDefaults as they change.
final class LightSettings: ObservableObject {
    static let shared = LightSettings()

    private let defaults = UserDefaults.standard

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Key.enabled) } }
    @Published var mode: LightMode { didSet { defaults.set(mode.rawValue, forKey: Key.mode) } }
    @Published var baseGlow: Double { didSet { defaults.set(baseGlow, forKey: Key.baseGlow) } }
    @Published var beatFlash: Double { didSet { defaults.set(beatFlash, forKey: Key.beatFlash) } }
    @Published var maxBrightness: Double { didSet { defaults.set(maxBrightness, forKey: Key.maxBrightness) } }
    /// Delays the lights, for speakers that play late (AirPlay, Bluetooth), in milliseconds.
    @Published var delayMs: Double { didSet { defaults.set(delayMs, forKey: Key.delayMs) } }
    @Published var releaseAfter: ReleaseAfter { didSet { defaults.set(releaseAfter.rawValue, forKey: Key.releaseAfter) } }
    @Published var hueBridges: [HueBridgeConfig] { didSet { store(hueBridges, Key.hueBridges) } }
    @Published var artNetDevices: [ArtNetDevice] { didSet { store(artNetDevices, Key.artNetDevices) } }
    /// How many lights the preview shows while no device is set up.
    @Published var previewCount: Int { didSet { defaults.set(previewCount, forKey: Key.previewCount) } }
    /// Devices switched off in the Lights window, by output ID ("hue:<bridge id>", "artnet:<uuid>"). They stay set up,
    /// but Barbeat leaves their lights alone. Kept apart from the device lists so older saved devices still load.
    @Published var switchedOff: Set<String> { didSet { defaults.set(switchedOff.sorted(), forKey: Key.switchedOff) } }
    /// Each device's Mirror and sparkles, by output ID (the preview and virtual lights too). Devices left
    /// at the defaults have no entry. Kept apart from the device lists, like `switchedOff`.
    @Published var effects: [String: LightEffects] { didSet { store(effects, Key.effects) } }

    static let defaultBaseGlow = 0.16, defaultBeatFlash = 0.64, defaultMaxBrightness = 1.0

    var hasDevices: Bool { !hueBridges.isEmpty || !artNetDevices.isEmpty }

    /// Whether Barbeat drives this device (output ID). The preview and virtual lights are always on.
    func isOn(_ id: String) -> Bool { !switchedOff.contains(id) }

    func setOn(_ on: Bool, _ id: String) {
        if on { switchedOff.remove(id) } else { switchedOff.insert(id) }
    }

    func effects(for id: String) -> LightEffects { effects[id] ?? LightEffects() }

    func setEffects(_ value: LightEffects, for id: String) {
        let next: LightEffects? = value == LightEffects() ? nil : value
        if effects[id] != next { effects[id] = next }
    }

    func resetShow() {
        mode = .auto
        baseGlow = Self.defaultBaseGlow
        beatFlash = Self.defaultBeatFlash
        maxBrightness = Self.defaultMaxBrightness
        delayMs = 0
    }

    var showOptions: LightShow.Options {
        LightShow.Options(mode: mode, baseGlow: Float(baseGlow), beatFlash: Float(beatFlash),
                          maxBrightness: Float(maxBrightness), reduceFlashing: false)
    }

    private enum Key {
        static let enabled = "lights.enabled", mode = "lights.mode", baseGlow = "lights.baseGlow"
        static let beatFlash = "lights.beatFlash", maxBrightness = "lights.maxBrightness", delayMs = "lights.delayMs"
        static let releaseAfter = "lights.releaseAfter", hueBridges = "lights.hueBridges"
        static let artNetDevices = "lights.artNetDevices", previewCount = "lights.previewCount"
        static let switchedOff = "lights.switchedOff", effects = "lights.effects"
    }

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
            Key.enabled: false,
            Key.mode: LightMode.auto.rawValue,
            Key.baseGlow: Self.defaultBaseGlow,
            Key.beatFlash: Self.defaultBeatFlash,
            Key.maxBrightness: Self.defaultMaxBrightness,
            Key.delayMs: 0.0,
            Key.releaseAfter: ReleaseAfter.thirtySeconds.rawValue,
            Key.previewCount: 3,
        ])
        enabled = defaults.bool(forKey: Key.enabled)
        mode = LightMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .auto
        baseGlow = min(0.6, max(0, defaults.double(forKey: Key.baseGlow)))
        beatFlash = min(1, max(0, defaults.double(forKey: Key.beatFlash)))
        maxBrightness = min(1, max(0.1, defaults.double(forKey: Key.maxBrightness)))
        delayMs = min(2000, max(0, defaults.double(forKey: Key.delayMs)))
        releaseAfter = ReleaseAfter(rawValue: defaults.integer(forKey: Key.releaseAfter)) ?? .thirtySeconds
        previewCount = min(12, max(1, defaults.integer(forKey: Key.previewCount)))
        hueBridges = []
        artNetDevices = []
        switchedOff = Set(defaults.stringArray(forKey: Key.switchedOff) ?? [])
        effects = [:]
        if let saved = load([String: LightEffects].self, Key.effects) { effects = saved }
        if let saved = load([HueBridgeConfig].self, Key.hueBridges) { hueBridges = saved }
        if let saved = load([ArtNetDevice].self, Key.artNetDevices) { artNetDevices = saved }
    }
}

/// Small wrapper around the login keychain, for the Hue bridges' keys.
enum Keychain {
    /// Separate per bundle ID, so test copies never touch the real app's keys.
    private static var service: String { (Bundle.main.bundleIdentifier ?? "com.ia.MenuBarEQ") + ".hue" }

    /// `--hue-keys-file <path>` keeps the keys in that JSON file instead (for testing without touching the Keychain).
    private static let testFile: URL? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--hue-keys-file"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }()

    private static func readTestFile(_ url: URL) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
    }

    static func set(_ value: String, account: String) {
        if let testFile {
            var all = readTestFile(testFile)
            all[account] = value
            try? JSONEncoder().encode(all).write(to: testFile)
            return
        }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        let data = Data(value.utf8)
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Barbeat Hue Bridge \(account)"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func get(account: String) -> String? {
        if let testFile { return readTestFile(testFile)[account] }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        if let testFile {
            var all = readTestFile(testFile)
            all[account] = nil
            try? JSONEncoder().encode(all).write(to: testFile)
            return
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
