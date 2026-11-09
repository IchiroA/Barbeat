import SwiftUI
import AppKit
import Combine

/// How the voice colors things.
enum VoiceColorMode: String, CaseIterable, Identifiable {
    case off, voice, pitch
    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .voice: return "Voice color"
        case .pitch: return "Pitch color"
        }
    }

    var help: String {
        switch self {
        case .off: return "The voice doesn't change the colors (the glow and lights can still follow it)."
        case .voice: return "While someone sings, the voice color spreads out from the middle, further with louder singing."
        case .pitch: return "The color spreading from the middle follows the singer's notes: blue for low notes, through green and yellow, to orange for high ones."
        }
    }
}

/// The Voice preferences, saved to UserDefaults as they change.
final class VoiceSettings: ObservableObject {
    static let shared = VoiceSettings()
    private let defaults = UserDefaults.standard

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Key.enabled) } }
    @Published var target: VoiceTarget { didSet { defaults.set(target.rawValue, forKey: Key.target) } }
    @Published var colorMode: VoiceColorMode { didSet { defaults.set(colorMode.rawValue, forKey: Key.colorMode) } }
    @Published var color: HSB { didSet { store(color, Key.color) } }
    /// A soft glow in the middle of the menu bar that swells with the voice.
    @Published var glow: Bool { didSet { defaults.set(glow, forKey: Key.glow) } }
    /// How far the voice's color can spread out from the middle (and how bright the glow gets), 0.1...1.
    @Published var strength: Double { didSet { defaults.set(strength, forKey: Key.strength) } }
    @Published var onMenuBar: Bool { didSet { defaults.set(onMenuBar, forKey: Key.onMenuBar) } }
    @Published var onEdgeGlow: Bool { didSet { defaults.set(onEdgeGlow, forKey: Key.onEdgeGlow) } }
    @Published var onLights: Bool { didSet { defaults.set(onLights, forKey: Key.onLights) } }

    /// Warm gold.
    static let defaultColor = HSB(h: 0.095, s: 0.78, b: 1)
    static let swatches: [(name: String, color: HSB)] = [
        ("Gold", defaultColor), ("White", HSB(h: 0, s: 0, b: 1)), ("Rose", HSB(h: 0.93, s: 0.6, b: 1)),
        ("Red", HSB(h: 0.99, s: 0.85, b: 1)), ("Violet", HSB(h: 0.76, s: 0.65, b: 1)), ("Cyan", HSB(h: 0.52, s: 0.8, b: 1)),
    ]

    /// Something to say about the settings in one line, for the panel.
    var summary: String {
        guard enabled else { return "Follow the singer" }
        var parts = [target == .both ? "Singing and speech" : target.title]
        if colorMode != .off { parts.append(colorMode.title) }
        if glow { parts.append("Glow") }
        return parts.joined(separator: " · ")
    }

    private enum Key {
        static let enabled = "voice.enabled", target = "voice.target", colorMode = "voice.colorMode", color = "voice.color"
        static let glow = "voice.glow", strength = "voice.strength", onMenuBar = "voice.onMenuBar"
        static let onEdgeGlow = "voice.onEdgeGlow", onLights = "voice.onLights"
    }

    private func store<T: Encodable>(_ value: T, _ key: String) {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return }
        defaults.set(text, forKey: key)
    }

    private init() {
        defaults.register(defaults: [
            Key.enabled: false, Key.target: VoiceTarget.singing.rawValue, Key.colorMode: VoiceColorMode.voice.rawValue,
            Key.glow: false, Key.strength: 0.6, Key.onMenuBar: true, Key.onEdgeGlow: true, Key.onLights: true,
        ])
        enabled = defaults.bool(forKey: Key.enabled)
        target = VoiceTarget(rawValue: defaults.string(forKey: Key.target) ?? "") ?? .singing
        colorMode = VoiceColorMode(rawValue: defaults.string(forKey: Key.colorMode) ?? "") ?? .voice
        color = defaults.string(forKey: Key.color).flatMap { try? JSONDecoder().decode(HSB.self, from: Data($0.utf8)) }
            ?? Self.defaultColor
        glow = defaults.bool(forKey: Key.glow)
        strength = min(1, max(0.1, defaults.double(forKey: Key.strength)))
        onMenuBar = defaults.bool(forKey: Key.onMenuBar)
        onEdgeGlow = defaults.bool(forKey: Key.onEdgeGlow)
        onLights = defaults.bool(forKey: Key.onLights)
    }
}

/// This frame's voice effect, shared by every window and the lights. Updated by the render loop.
struct VoiceFrame {
    /// The voice right now, 0...1.
    var level: Float = 0
    /// A word or syllable starts this frame (its strength), else 0.
    var word: Float = 0
    /// The voice color, or the pitch color.
    var color = RGB(r: 1, g: 0.8, b: 0.3)
    /// How far the voice color spreads out from the middle, 0...1 (Strength included). 0 when the color mode is Off.
    var tint: Float = 0
    /// The menu bar glow's strength, 0...1. 0 when the glow is off.
    var glow: Float = 0

    static var current = VoiceFrame()
}

/// Turns what the detector hears into the frame's effect, smoothed so colors don't flicker word to word.
final class VoiceEffect {
    private var tintLevel: Float = 0
    private var glowLevel: Float = 0
    private var shownColor: RGB?

    func frame(from voice: VoiceDetector, settings s: VoiceSettings, dt: Float) -> VoiceFrame {
        let level = voice.level
        // Color: leans in quickly when the singer starts, lets go over half a second.
        tintLevel += (level - tintLevel) * (1 - exp(-dt / (level > tintLevel ? 0.08 : 0.5)))
        // Glow: breathes with each word.
        glowLevel += (level - glowLevel) * (1 - exp(-dt / (level > glowLevel ? 0.05 : 0.25)))

        let wanted: RGB
        if s.colorMode == .pitch {
            wanted = voice.pitch.map(Self.pitchColor) ?? shownColor ?? Self.pitchColor(60)
        } else {
            wanted = s.color.rgb
        }
        let current = shownColor ?? wanted
        shownColor = current.mixed(with: wanted, CGFloat(1 - exp(-dt / 0.15)))

        let strength = Float(s.strength)
        return VoiceFrame(level: level, word: voice.word, color: shownColor ?? wanted,
                          tint: s.colorMode == .off ? 0 : min(1, tintLevel * strength),
                          glow: s.glow ? min(1, glowLevel * (0.35 + 0.65 * strength)) : 0)
    }

    /// Low notes blue, through cyan, green and yellow, to orange-red for high notes (C3 to F#5).
    static func pitchColor(_ note: Float) -> RGB {
        let t = min(1, max(0, (note - 48) / 30))
        return HSB(h: Double(0.62 - 0.58 * t), s: 0.85, b: 1).rgb
    }
}

/// Live readings for the Voice window (only updated while it's open).
final class VoiceMonitor: ObservableObject {
    static let shared = VoiceMonitor()
    @Published private(set) var level: Float = 0
    @Published private(set) var singing: Float = 0
    @Published private(set) var speech: Float = 0
    @Published private(set) var color = RGB(r: 1, g: 0.8, b: 0.3)
    var wanted = false
    private var last: Double = 0

    func update(_ voice: VoiceDetector, frame: VoiceFrame, now: Double) {
        guard wanted, now - last > 0.1 else { return }
        last = now
        let heard = voice.heard
        level = voice.level
        singing = heard.singing
        speech = heard.speech
        color = frame.color
    }

    func clear() {
        level = 0; singing = 0; speech = 0
    }
}

// MARK: - The panel row

/// The Voice row in the menu bar panel.
struct VoiceRow: View {
    @ObservedObject var settings: VoiceSettings

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.mic")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(settings.enabled ? Color.accentColor : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("Voice").font(.callout)
                Text(settings.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("Options…") { VoiceWindow.show() }
                .controlSize(.small)
            Toggle("Voice", isOn: $settings.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .help("Colors, a glow and lights that follow the singer")
    }
}

// MARK: - The Voice page

/// The Voice settings live in the Settings window, as a page.
enum VoiceWindow {
    static func show() { SettingsWindow.show(.voice) }
}

struct VoiceView: View {
    @ObservedObject var settings: VoiceSettings
    @ObservedObject var monitor: VoiceMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                row("Listen for") {
                    Picker("Listen for", selection: $settings.target) {
                        ForEach(VoiceTarget.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                row("Color") {
                    Picker("Color", selection: $settings.colorMode) {
                        ForEach(VoiceColorMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                caption(settings.colorMode.help).padding(.leading, 98)
                if settings.colorMode == .pitch {
                    pitchScale.padding(.leading, 98)
                } else {
                    swatches.padding(.leading, 98)
                }
                row("") {
                    Toggle("Voice glow in the middle of the menu bar", isOn: $settings.glow)
                        .toggleStyle(.checkbox)
                        .help("A soft glow around the notch (or the middle) that swells with each word.")
                }
                row("Strength") {
                    HStack {
                        Slider(value: $settings.strength, in: 0.1...1)
                        Text("\(Int((settings.strength * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .help("How far the voice color can spread out from the middle, and how bright the glow gets.")
                row("Show on") {
                    HStack(spacing: 14) {
                        Toggle("Menu bar", isOn: $settings.onMenuBar)
                        Toggle("Edge glow", isOn: $settings.onEdgeGlow)
                        Toggle("Lights", isOn: $settings.onLights)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .disabled(!settings.enabled)
            .opacity(settings.enabled ? 1 : 0.55)
            Divider()
            caption("Each light device also has its own Voice option on the Lights page: lights that follow the singer, or sparkles on words.")
            caption("Barbeat listens for voices on your Mac with Apple's built-in sound recognizer; nothing leaves your Mac. It hears voices in the mix best when they're panned to the middle, as most singers are. It uses about 1% of one processor core while on.")
        }
        .padding(20)
        .frame(maxWidth: 640, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "music.mic").foregroundStyle(.tint)
                Text("Voice").font(.title3.weight(.semibold))
                Spacer()
                Toggle("Voice", isOn: $settings.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            HStack(spacing: 10) {
                meter
                Text(hearing).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// The voice right now, in its color.
    private var meter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(monitor.color.color)
                    .frame(width: max(0, geo.size.width * CGFloat(settings.enabled ? monitor.level : 0)))
            }
        }
        .frame(width: 140, height: 8)
    }

    private var hearing: String {
        guard settings.enabled else { return "Off" }
        let singing = monitor.singing > 0.35, speech = monitor.speech > 0.35
        switch (singing, speech) {
        case (true, true): return "Hearing singing and speech"
        case (true, false): return "Hearing singing"
        case (false, true): return "Hearing speech"
        default: return "No voice right now"
        }
    }

    private var swatches: some View {
        HStack(spacing: 8) {
            ForEach(VoiceSettings.swatches, id: \.name) { swatch in
                Button { settings.color = swatch.color } label: {
                    Circle()
                        .fill(swatch.color.color)
                        .frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(isChosen(swatch.color) ? 0.9 : 0.15),
                                                       lineWidth: isChosen(swatch.color) ? 2 : 1))
                }
                .buttonStyle(.plain)
                .help(swatch.name)
            }
            ColorPicker("Custom", selection: Binding(get: { settings.color.color }, set: { color in
                if let c = NSColor(color).usingColorSpace(.sRGB) {
                    settings.color = HSB(RGB(r: c.redComponent, g: c.greenComponent, b: c.blueComponent))
                }
            }), supportsOpacity: false)
            .labelsHidden()
            .help("Any color")
        }
    }

    private func isChosen(_ color: HSB) -> Bool {
        abs(color.h - settings.color.h) < 0.005 && abs(color.s - settings.color.s) < 0.01 && abs(color.b - settings.color.b) < 0.01
    }

    /// Low notes on the left, high ones on the right.
    private var pitchScale: some View {
        VStack(alignment: .leading, spacing: 3) {
            LinearGradient(colors: stride(from: 48, through: 78, by: 5).map { VoiceEffect.pitchColor(Float($0)).color },
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 220, height: 10)
                .clipShape(Capsule())
            HStack {
                Text("Low notes")
                Spacer()
                Text("High notes")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(width: 220)
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.callout).frame(width: 90, alignment: .leading)
            content()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
