import SwiftUI
import AppKit

/// A whole look: visuals, Screen colors, glow, lights and voice. Nil fields are left as they are when it's applied.
struct SceneLook: Codable, Equatable {
    var enabled: Bool?
    var style: String?, layout: String?, bandCount: Int?
    var palette: String?, customGradient: CustomGradient?, colorDrift: String?
    var screenColors: Bool?, screenColorMode: String?, screenBeams: Bool?, screenBeamsToLights: Bool?
    var brightness: Double?, opacity: Double?, edgeGlow: Bool?
    var lights: Bool?, lightMode: String?, baseGlow: Double?, beatFlash: Double?, lightBrightness: Double?
    var voice: Bool?

    /// Everything as it is right now.
    static func current() -> SceneLook {
        let s = Settings.shared, l = LightSettings.shared
        return SceneLook(enabled: s.enabled, style: s.style.rawValue, layout: s.layout.rawValue, bandCount: s.bandCount,
                         palette: s.palette.rawValue, customGradient: s.palette == .custom ? s.customGradient : nil,
                         colorDrift: s.colorDrift.rawValue, screenColors: s.screenColors,
                         screenColorMode: s.screenColorMode.rawValue, screenBeams: s.screenBeams,
                         screenBeamsToLights: s.screenBeamsToLights, brightness: s.brightness, opacity: s.opacity,
                         edgeGlow: s.edgeGlow, lights: l.enabled, lightMode: l.mode.rawValue, baseGlow: l.baseGlow,
                         beatFlash: l.beatFlash, lightBrightness: l.maxBrightness, voice: VoiceSettings.shared.enabled)
    }

    /// `interactive`: picked by hand, so turning Screen colors on may explain and ask for permission first.
    /// Automatic switches never put up a dialog: without permission, Screen colors stays as it is.
    func apply(interactive: Bool) {
        let s = Settings.shared, l = LightSettings.shared
        func set<T: Equatable>(_ value: T?, _ path: ReferenceWritableKeyPath<Settings, T>) {
            if let value, s[keyPath: path] != value { s[keyPath: path] = value }
        }
        func setLight<T: Equatable>(_ value: T?, _ path: ReferenceWritableKeyPath<LightSettings, T>) {
            if let value, l[keyPath: path] != value { l[keyPath: path] = value }
        }
        set(enabled, \.enabled)
        set(style.flatMap(EQStyle.init(rawValue:)), \.style)
        set(layout.flatMap(EQLayout.init(rawValue:)), \.layout)
        set(bandCount, \.bandCount)
        if let customGradient { set(customGradient, \.customGradient) }
        if let palette = palette.flatMap(Palette.init(rawValue:)), palette != .screen { set(palette, \.palette) }
        set(colorDrift.flatMap(ColorDrift.init(rawValue:)), \.colorDrift)
        set(screenColorMode.flatMap(ScreenColorMode.init(rawValue:)), \.screenColorMode)
        set(screenBeams, \.screenBeams)
        set(screenBeamsToLights, \.screenBeamsToLights)
        set(brightness, \.brightness)
        set(opacity, \.opacity)
        set(edgeGlow, \.edgeGlow)
        if let screenColors, screenColors != s.screenColors {
            if !screenColors {
                s.screenColors = false
            } else if CGPreflightScreenCaptureAccess() {
                s.screenColors = true
            } else if interactive {
                ScreenColorsAccess.turnOn(s)
            }
        }
        setLight(lights, \.enabled)
        setLight(lightMode.flatMap(LightMode.init(rawValue:)), \.mode)
        setLight(baseGlow, \.baseGlow)
        setLight(beatFlash, \.beatFlash)
        setLight(lightBrightness, \.maxBrightness)
        if let voice, VoiceSettings.shared.enabled != voice { VoiceSettings.shared.enabled = voice }
    }

    /// A few words about it, for the Scenes page.
    var summary: String {
        var parts: [String] = []
        if enabled == false { parts.append("Visuals off") }
        if let style = style.flatMap(EQStyle.init(rawValue:)), enabled != false { parts.append(style.title) }
        if screenColors == true { parts.append("Screen colors") } else if let palette = palette.flatMap(Palette.init(rawValue:)) {
            parts.append(palette.title)
        }
        if let brightness { parts.append("\(Int((brightness * 100).rounded()))% bright") }
        if edgeGlow == false { parts.append("no edge glow") }
        if let lights { parts.append(lights ? "lights on" : "lights off") }
        if voice == true { parts.append("voice") }
        return parts.joined(separator: " · ")
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
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Scene"
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "sparkles"
        look = (try? c.decodeIfPresent(SceneLook.self, forKey: .look)) ?? SceneLook()
        onCall = try c.decodeIfPresent(Bool.self, forKey: .onCall) ?? false
        apps = (try? c.decodeIfPresent([SceneApp].self, forKey: .apps)) ?? []
    }
}

/// The scenes, applying them, and switching on their own.
final class SceneStore: ObservableObject {
    static let shared = SceneStore()
    private let defaults = UserDefaults.standard

    @Published var scenes: [BarbeatScene] { didSet { store() } }
    @Published var autoSwitch: Bool { didSet { defaults.set(autoSwitch, forKey: Key.autoSwitch) } }
    /// The scene last applied (by hand or automatically).
    @Published private(set) var activeID: UUID?
    /// Set while a scene was switched on automatically, with why ("Safari is playing").
    @Published private(set) var automaticID: UUID?
    @Published private(set) var automaticReason = ""

    private var restoreLook: SceneLook?
    private var restoreActiveID: UUID?
    /// The scene whose trigger you overrode by picking another one; it waits until its trigger ends.
    private var dismissedID: UUID?
    private var wantedID: UUID?
    private var wantedSince: Double = 0
    private var timer: Timer?
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

    private enum Key { static let scenes = "scenes", autoSwitch = "scenes.autoSwitch" }

    private init() {
        defaults.register(defaults: [Key.autoSwitch: true])
        autoSwitch = defaults.bool(forKey: Key.autoSwitch)
        if let text = defaults.string(forKey: Key.scenes), let saved = try? JSONDecoder().decode([BarbeatScene].self, from: Data(text.utf8)) {
            scenes = saved
        } else {
            scenes = Self.starters
        }
    }

    static let starters: [BarbeatScene] = [
        BarbeatScene(name: "On a call", symbol: "phone.fill",
                     look: SceneLook(enabled: false, lights: false, voice: false), onCall: true),
        BarbeatScene(name: "Concert", symbol: "music.mic",
                     look: SceneLook(enabled: true, style: "center", layout: "stereo", bandCount: 128, screenColors: true,
                                     screenColorMode: "ambient", screenBeams: true, screenBeamsToLights: true,
                                     brightness: 1.4, opacity: 0.8, edgeGlow: true, lights: true, lightMode: "auto",
                                     baseGlow: 0.12, beatFlash: 0.75, lightBrightness: 1)),
        BarbeatScene(name: "Chill", symbol: "moon.stars.fill",
                     look: SceneLook(enabled: true, style: "glow", colorDrift: "slow", screenColors: false,
                                     brightness: 0.9, opacity: 0.6, edgeGlow: true, lights: true, lightMode: "auto",
                                     baseGlow: 0.3, beatFlash: 0.15, lightBrightness: 0.6)),
        BarbeatScene(name: "Focus", symbol: "laptopcomputer",
                     look: SceneLook(enabled: true, style: "bars", layout: "full", bandCount: 64, screenColors: false,
                                     brightness: 0.7, opacity: 0.35, edgeGlow: false, lights: false, voice: false)),
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
        scene.look.apply(interactive: true)
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

    /// Asks for a name, then saves the current look as a new scene.
    static func promptSave() {
        let alert = NSAlert()
        alert.messageText = "Save the current look as a scene"
        alert.informativeText = "Saves the style, colors, Screen colors, glow, lights and voice as they are now."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = "Scene \(shared.scenes.count + 1)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        shared.saveCurrent(named: name.isEmpty ? "Scene \(shared.scenes.count + 1)" : name)
    }

    // MARK: - Switching on their own

    /// Looks every two seconds at which apps are playing and whether a call is on.
    func start() {
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
                restoreLook = .current()
                restoreActiveID = activeID
            }
            note("switching to \(wanted.scene.name): \(wanted.reason)")
            wanted.scene.look.apply(interactive: false)
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

    private func note(_ text: String) {
        if log { print("scenes: \(text)") }
    }

    private func store() {
        guard let data = try? JSONEncoder().encode(scenes), let text = String(data: data, encoding: .utf8) else { return }
        defaults.set(text, forKey: Key.scenes)
    }
}

// MARK: - The panel row

/// The Scenes row in the menu bar panel: pick one, save one, or see why it switched.
struct SceneRow: View {
    @ObservedObject var store: SceneStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: store.active?.symbol ?? "theatermasks.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("Scene").font(.callout)
                Text(store.automaticID != nil ? "Switched because \(store.automaticReason)" : "One click for a whole look")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Menu(store.active?.name ?? "Choose") {
                ForEach(store.scenes) { scene in
                    Button { store.apply(scene) } label: {
                        if scene.id == store.activeID { Label(scene.name, systemImage: "checkmark") } else { Text(scene.name) }
                    }
                }
                Divider()
                Button("Save Current Look…") { SceneStore.promptSave() }
                Button("Edit Scenes…") { SettingsWindow.show(.scenes) }
            }
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - The Settings page

struct ScenesPage: View {
    @ObservedObject var store: SceneStore
    @ObservedObject var apps: AudioSourceList

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Switch scenes automatically", isOn: $store.autoSwitch)
                .toggleStyle(.checkbox)
            Text("A scene with a trigger turns on by itself while the trigger lasts, then everything goes back to how it was. If you pick another scene meanwhile, yours wins until the trigger ends.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(store.scenes) { scene in
                card(scene)
            }
            HStack {
                Button("Save Current Look as a New Scene…") { SceneStore.promptSave() }
                Spacer()
                if store.scenes.isEmpty || store.scenes.count < SceneStore.starters.count {
                    Button("Add the Starter Scenes") {
                        for starter in SceneStore.starters where !store.scenes.contains(where: { $0.name == starter.name }) {
                            store.scenes.append(starter)
                        }
                    }
                }
            }
        }
    }

    private func binding(_ id: UUID) -> Binding<BarbeatScene>? {
        guard let scene = store.scenes.first(where: { $0.id == id }) else { return nil }
        return Binding(get: { store.scenes.first { $0.id == id } ?? scene }, set: { value in
            if let i = store.scenes.firstIndex(where: { $0.id == id }), store.scenes[i] != value { store.scenes[i] = value }
        })
    }

    @ViewBuilder
    private func card(_ scene: BarbeatScene) -> some View {
        if let edit = binding(scene.id) {
            let active = store.activeID == scene.id
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: scene.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 22)
                    TextField("Name", text: edit.name)
                        .textFieldStyle(.plain)
                        .font(.headline)
                    if store.automaticID == scene.id {
                        Text("On now: \(store.automaticReason)").font(.caption).foregroundStyle(.green)
                    } else if active {
                        Text("In use").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Use") { store.apply(scene) }
                        .controlSize(.small)
                    Menu {
                        Button("Update with the Current Look") { store.updateWithCurrent(scene.id) }
                        Button("Move Up") { store.move(scene.id, by: -1) }
                        Button("Move Down") { store.move(scene.id, by: 1) }
                        Divider()
                        Button("Delete", role: .destructive) { store.delete(scene.id) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Text(scene.look.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Turns on by itself:").font(.caption.weight(.semibold))
                    Toggle("While you're on a call (an app is using the microphone)", isOn: edit.onCall)
                        .toggleStyle(.checkbox)
                    HStack(spacing: 6) {
                        Text("While one of these plays:").font(.callout)
                        ForEach(scene.apps, id: \.self) { app in
                            HStack(spacing: 3) {
                                Text(app.name)
                                Button { edit.wrappedValue.apps.removeAll { $0 == app } } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                        }
                        Menu("Add App") {
                            ForEach(apps.apps.filter { app in !scene.apps.contains { $0.id == app.id } }) { app in
                                Button(app.isPlaying ? "\(app.name)  ♪" : app.name) {
                                    edit.wrappedValue.apps.append(SceneApp(id: app.id, name: app.name))
                                }
                            }
                        }
                        .controlSize(.small)
                        .fixedSize()
                        .onAppear { apps.refresh() }
                    }
                }
                .padding(.leading, 32)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(active ? 0.07 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(active ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.5))
        }
    }
}
