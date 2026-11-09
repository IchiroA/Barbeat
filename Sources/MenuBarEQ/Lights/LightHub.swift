import AppKit
import Combine
import QuartzCore

/// Where a device is in taking over and giving back the lights.
enum LightOutputState: Equatable {
    /// Not controlling the lights (they do whatever they did before).
    case idle
    /// Taking over: saving the lights' state, starting the stream.
    case connecting
    case live
    /// Handing the lights back, restoring how they were.
    case givingBack
    case failed(String)
    case needsSetup(String)
}

/// Something that shows the light show: a Hue entertainment area, an Art-Net device, or the preview.
protocol LightOutput: AnyObject {
    var id: String { get }
    var title: String { get }
    var kind: String { get }
    /// A line about the device for the Lights window, e.g. "5 lights · Living room".
    var detail: String { get }
    var slots: [LightSlot] { get }
    /// Most frames a second worth sending.
    var maxRate: Double { get }
    var state: LightOutputState { get }
    var onChange: (() -> Void)? { get set }
    /// The next give-back leaves the lights off instead of how they were (the sleep timer).
    var endWithLightsOff: Bool { get set }
    func takeOver()
    func send(_ colors: [LightColor])
    /// Must work in any state, and call `completion` once the lights are back as they were.
    func giveBack(completion: @escaping () -> Void)
    func identify()
    /// The device was removed.
    func shutdown()
}

/// Shows the light show only in the Lights window: while no device is set up, and for `--lights-virtual N`.
final class PreviewOutput: LightOutput {
    let id: String
    let kind = "Preview"
    var title: String { id == "virtual" ? "Virtual lights" : "Preview" }
    var detail: String { "\(slots.count) \(slots.count == 1 ? "light" : "lights") · no hardware" }
    private(set) var slots: [LightSlot]
    let maxRate = 60.0
    var onChange: (() -> Void)?
    var endWithLightsOff = false
    private(set) var state: LightOutputState = .idle { didSet { if state != oldValue { onChange?() } } }

    init(id: String, count: Int) {
        self.id = id
        slots = LightSlot.row(count)
    }

    func resize(_ count: Int) {
        if count != slots.count { slots = LightSlot.row(count) }
    }

    func takeOver() { state = .live }
    func send(_ colors: [LightColor]) {}
    func giveBack(completion: @escaping () -> Void) { state = .idle; completion() }
    func identify() {}
    func shutdown() {}
}

/// Runs the light show for every device: computes each frame, delays it to match the speakers,
/// and takes the lights over while music plays (giving them back when it stops).
final class LightHub: ObservableObject {
    static let shared = LightHub()

    let settings = LightSettings.shared
    @Published private(set) var outputs: [LightOutput] = []
    /// The latest colors per device, for the Lights window (only updated while it's open).
    @Published private(set) var preview: [String: [LightColor]] = [:]
    /// What each device's show is doing (what Auto picked).
    @Published private(set) var modes: [String: LightMode] = [:]
    /// Hue areas found on each bridge, for the area picker.
    @Published var hueAreas: [String: [HueArea]] = [:]
    /// The Lights window is open: keep the preview coming even while the lights are off.
    var previewWanted = false {
        didSet { if previewWanted != oldValue { onActiveChange?() } }
    }

    /// `--lights-virtual N`: N fake lights, on for this run without touching the saved switch.
    let virtualCount = LightHub.argument("--lights-virtual").flatMap(Int.init).map { min(512, max(1, $0)) }
    let log = CommandLine.arguments.contains("--lights-log")

    /// The lights should run (the Lights switch, or virtual lights for testing).
    var isActive: Bool { settings.enabled || virtualCount != nil }
    var isLive: Bool { outputs.contains { $0.state == .live } }
    /// Barbeat holds (or is busy with) some device's lights.
    var isHoldingLights: Bool { outputs.contains { [.live, .connecting, .givingBack].contains($0.state) } }
    /// Barbeat is quitting: never take the lights over again.
    var closing = false
    /// Sleep timer: when the lights fade out and switch off.
    @Published private(set) var sleepUntil: Date?
    private var sleepLength: TimeInterval = 0
    private var sleepTimer: Timer?
    /// Tells the overlay controller to start or stop listening.
    var onActiveChange: (() -> Void)?

    private var shows: [String: LightShow] = [:]
    private var ring: [(time: Double, frames: [String: [LightColor]])] = []
    private var lastSend: [String: Double] = [:]
    private var lastSent: [String: [LightColor]] = [:]
    private var failedAt: [String: Double] = [:]
    private var identifyUntil: [String: Double] = [:]
    private var silence: Double = .infinity
    private var sleeping = false
    private var lastPreview: Double = 0
    private var lastLog: Double = 0
    private var cancellables = Set<AnyCancellable>()

    private init() {
        rebuildOutputs()
        settings.$hueBridges.combineLatest(settings.$artNetDevices, settings.$previewCount)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildOutputs() }
            .store(in: &cancellables)
        settings.$switchedOff.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                for output in self.outputs where output.kind != "Preview" {
                    self.note("\(output.title): \(self.settings.isOn(output.id) ? "switched on" : "switched off")")
                }
                self.objectWillChange.send()
            }
            .store(in: &cancellables)
        settings.$enabled.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] on in
                guard let self else { return }
                if !on && self.virtualCount == nil { self.giveBackAll() }
                self.note("lights switch \(on ? "on" : "off")")
                self.onActiveChange?()
            }
            .store(in: &cancellables)

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.sleeping = true
            self.note("Mac going to sleep: giving the lights back")
            self.giveBackAll()
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = false
            self?.silence = .infinity   // take over again once music plays
        }
    }

    // MARK: - Devices

    private func rebuildOutputs() {
        var next: [LightOutput] = []
        var existing = Dictionary(uniqueKeysWithValues: outputs.map { ($0.id, $0) })
        func reuse<T: LightOutput>(_ id: String, as type: T.Type, make: () -> T, update: (T) -> Void) {
            if let output = existing.removeValue(forKey: id) as? T {
                update(output)
                next.append(output)
            } else {
                let output = make()
                output.onChange = { [weak self, weak output] in
                    guard let self, let output else { return }
                    self.stateChanged(output)
                }
                next.append(output)
            }
        }
        for bridge in settings.hueBridges {
            reuse("hue:\(bridge.id)", as: HueOutput.self, make: { HueOutput(config: bridge, hub: self) }, update: { $0.update(bridge) })
        }
        for device in settings.artNetDevices {
            reuse("artnet:\(device.id.uuidString)", as: ArtNetOutput.self, make: { ArtNetOutput(device: device) },
                  update: { $0.update(device) })
        }
        if let virtualCount {
            reuse("virtual", as: PreviewOutput.self, make: { PreviewOutput(id: "virtual", count: virtualCount) }, update: { _ in })
        } else if !settings.hasDevices {
            reuse("preview", as: PreviewOutput.self, make: { PreviewOutput(id: "preview", count: settings.previewCount) },
                  update: { $0.resize(self.settings.previewCount) })
        }
        // Removed devices: hand their lights back first.
        for (_, gone) in existing {
            gone.giveBack { gone.shutdown() }
            shows[gone.id] = nil
            preview[gone.id] = nil
            if !settings.isOn(gone.id) { settings.setOn(true, gone.id) }
            if settings.effects[gone.id] != nil { settings.effects[gone.id] = nil }
        }
        outputs = next
    }

    private func stateChanged(_ output: LightOutput) {
        if case .failed = output.state { failedAt[output.id] = CACurrentMediaTime() }
        note("\(output.title): \(Self.describe(output.state))")
        objectWillChange.send()
    }

    /// One white flash on a device, so you can tell which one it is.
    func identify(_ output: LightOutput) {
        if output.state == .live {
            identifyUntil[output.id] = CACurrentMediaTime() + 0.6
        } else {
            output.identify()
        }
    }

    // MARK: - Every frame

    /// Called by the render loop every frame while Barbeat is listening.
    func tick(analyzer: SpectrumAnalyzer, sound: Float, dt: Double, colors: FrameColors, stereoLayout: Bool,
              voice: VoiceFrame, voiceOn: Bool) {
        let now = CACurrentMediaTime()
        silence = sound > 0.0005 ? 0 : silence + dt
        guard isActive || previewWanted, !outputs.isEmpty else { return }

        var signals = LightSignals(analyzer: analyzer, silence: silence, stereoLayout: stereoLayout)
        signals.voice = voiceOn ? voice.level : 0
        signals.word = voiceOn ? voice.word : 0
        var palette = LightPalette(colors)
        let app = Settings.shared
        if app.screenColors, app.screenBeams, app.screenBeamsToLights,
           let screen = ScreenColors.shared.colors(for: NSScreen.screens.first?.displayID) {
            palette.beams = Self.beams(screen)
        }
        var options = settings.showOptions
        options.beamFlash = palette.beams == nil ? 0 : 1
        options.maxBrightness *= sleepFade
        options.reduceFlashing = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if voiceOn, VoiceSettings.shared.onLights {
            options.voiceTint = voice.tint
            options.voiceColor = SIMD3(Float(voice.color.r), Float(voice.color.g), Float(voice.color.b))
        }

        var frames: [String: [LightColor]] = [:]
        for output in outputs {
            let show = shows[output.id] ?? LightShow()
            shows[output.id] = show
            var deviceOptions = options
            deviceOptions.apply(settings.effects(for: output.id), lightCount: output.slots.count, voice: voiceOn)
            var frame = show.frame(slots: output.slots, signals: signals, palette: palette, options: deviceOptions, dt: dt)
            if let until = identifyUntil[output.id] {
                if now < until { frame = frame.map { _ in .white } } else { identifyUntil[output.id] = nil }
            }
            frames[output.id] = frame
            if modes[output.id] != show.mode { modes[output.id] = show.mode }
        }

        if previewWanted, now - lastPreview > 1.0 / 20 {
            lastPreview = now
            preview = frames
        }

        // Delay the lights to line up with speakers that play late.
        var due = frames
        let delay = settings.delayMs / 1000
        if delay > 0.001 {
            ring.append((now, frames))
            ring.removeAll { now - $0.time > 2.5 }
            due = ring.last { $0.time <= now - delay }?.frames ?? ring.first?.frames ?? frames
        } else if !ring.isEmpty {
            ring.removeAll()
        }

        let releaseAfter = settings.releaseAfter.seconds ?? .infinity
        let want = isActive && !sleeping && !closing && silence < releaseAfter
        for output in outputs {
            // A device switched off in the Lights window gets its lights back, like when the music stops.
            drive(output, want: want && settings.isOn(output.id), frame: due[output.id], now: now)
        }
        logFrames(frames, now: now)
    }

    private func drive(_ output: LightOutput, want: Bool, frame: [LightColor]?, now: Double) {
        switch output.state {
        case .idle:
            if want {
                note("\(output.title): music is playing")
                output.takeOver()
            }
        case .failed:
            // Try again every so often while music plays.
            if want, now - (failedAt[output.id] ?? 0) > 15 { output.takeOver() }
        case .live:
            guard want else {
                let why = !settings.isOn(output.id) ? "switched off" : isActive ? "music stopped" : "lights off"
                note("\(output.title): giving back (\(why))")
                // With the sleep timer running, the music ending is bedtime too: the lights end off.
                if sleepUntil != nil {
                    output.endWithLightsOff = true
                    DispatchQueue.main.async { [weak self] in self?.sleepNow() }
                }
                output.giveBack {}
                return
            }
            guard let frame, now - (lastSend[output.id] ?? 0) >= 1 / output.maxRate - 0.002 else { return }
            // Nothing changed: a keep-alive twice a second is enough.
            if frame == lastSent[output.id], now - (lastSend[output.id] ?? 0) < 0.5 { return }
            output.send(frame)
            lastSend[output.id] = now
            lastSent[output.id] = frame
        case .connecting, .givingBack, .needsSetup:
            break
        }
    }

    /// Hands every device's lights back (switch off, sleep, quit). `completion` runs once all are restored.
    func giveBackAll(completion: (() -> Void)? = nil) {
        let busy = outputs.filter { [.live, .connecting, .givingBack].contains($0.state) }
        guard !busy.isEmpty else { completion?(); return }
        var waiting = busy.count
        for output in busy {
            output.giveBack {
                waiting -= 1
                if waiting == 0 { completion?() }
            }
        }
    }

    /// Quitting: hands every device's lights back before returning (Hue waits up to `timeout` for the bridge).
    func giveBackBeforeQuit(timeout: TimeInterval) {
        closing = true
        for output in outputs {
            switch output {
            case let hue as HueOutput: hue.giveBackBeforeQuit(timeout: timeout)
            case let artNet as ArtNetOutput: artNet.giveBackBeforeQuit()
            default: break
            }
        }
    }

    // MARK: - Sleep timer

    /// Fades the lights out over the last minute, then switches Lights off with the lights left off.
    func startSleep(minutes: Double) {
        sleepTimer?.invalidate()
        sleepLength = minutes * 60
        let until = Date().addingTimeInterval(sleepLength)
        sleepUntil = until
        sleepTimer = Timer.scheduledTimer(withTimeInterval: sleepLength, repeats: false) { [weak self] _ in self?.sleepNow() }
        note("sleep timer: lights off in \(Int(minutes)) min")
    }

    func cancelSleep() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepUntil = nil
        note("sleep timer cancelled")
    }

    /// 1, falling to 0 over the last minute (or the last quarter of a short timer).
    private var sleepFade: Float {
        guard let sleepUntil else { return 1 }
        let fade = min(60, sleepLength / 4)
        return Float(min(1, max(0, sleepUntil.timeIntervalSinceNow / max(1, fade))))
    }

    private func sleepNow() {
        guard sleepUntil != nil else { return }
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepUntil = nil
        note("sleep timer: lights off")
        for output in outputs where output.kind != "Preview" { output.endWithLightsOff = true }
        settings.enabled = false
    }

    // MARK: - Status

    /// One line for the menu bar panel.
    var summary: String {
        let all = outputs.filter { $0.kind != "Preview" }
        guard !all.isEmpty else { return "Not set up yet" }
        let devices = all.filter { settings.isOn($0.id) }
        guard !devices.isEmpty else { return all.count == 1 ? "\(all[0].title) is switched off" : "All devices are switched off" }
        if !settings.enabled { return devices.count == 1 ? devices[0].title : "\(devices.count) devices" }
        if let failed = devices.first(where: { if case .failed = $0.state { return true }; return false }),
           case let .failed(message) = failed.state {
            return message
        }
        if let setup = devices.first(where: { if case .needsSetup = $0.state { return true }; return false }),
           case let .needsSetup(message) = setup.state {
            return message
        }
        if devices.contains(where: { $0.state == .live }) {
            let lights = devices.filter { $0.state == .live }.reduce(0) { $0 + $1.slots.count }
            let names = devices.count == 1 ? devices[0].title : "\(devices.count) devices"
            return "\(names) · \(lights) \(lights == 1 ? "light" : "lights")"
        }
        if devices.contains(where: { $0.state == .connecting }) { return "Taking over the lights…" }
        if devices.contains(where: { $0.state == .givingBack }) { return "Putting the lights back…" }
        return "Waiting for music"
    }

    enum Health { case off, waiting, live, problem }

    var health: Health {
        let devices = outputs.filter { $0.kind != "Preview" && settings.isOn($0.id) }
        guard settings.enabled, !devices.isEmpty else { return .off }
        if devices.contains(where: {
            switch $0.state { case .failed, .needsSetup: return true; default: return false }
        }) { return .problem }
        return devices.contains { $0.state == .live } ? .live : .waiting
    }

    static func describe(_ state: LightOutputState) -> String {
        switch state {
        case .idle: return "idle"
        case .connecting: return "taking over"
        case .live: return "live"
        case .givingBack: return "giving back"
        case .failed(let message): return "failed — \(message)"
        case .needsSetup(let message): return "needs setup — \(message)"
        }
    }

    // MARK: - Log (--lights-log)

    func note(_ text: String) {
        if log { print("lights: \(text)") }
    }

    private func logFrames(_ frames: [String: [LightColor]], now: Double) {
        guard log, now - lastLog >= 0.25 else { return }
        lastLog = now
        for output in outputs {
            guard let frame = frames[output.id] else { continue }
            let shown = frame.prefix(12).map { "\($0.hex)@\(Int(($0.brightness * 100).rounded()))" }.joined(separator: " ")
            let more = frame.count > 12 ? " +\(frame.count - 12)" : ""
            print(String(format: "lights: %@ [%@, %@] %@%@ silence=%.1f", output.title, modes[output.id]?.title ?? "?",
                         Self.describe(output.state), shown, more, min(silence, 999)))
        }
    }

    private static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

extension LightHub {
    /// Light beams along the screen, left to right, from the top and bottom edges (whichever is lit more).
    static func beams(_ screen: ScreenColors.Colors) -> [SIMD4<Float>]? {
        let n = screen.top.count
        guard n > 0, screen.beam.count >= 2 * n, screen.bottom.count == n else { return nil }
        var out = [SIMD4<Float>](repeating: .zero, count: n)
        var any = false
        for i in 0..<n {
            let top = screen.beam[i], bottom = screen.beam[n + i]
            let color = top >= bottom ? screen.top[i] : screen.bottom[i]
            let w = max(top, bottom)
            if w > 0.01 { any = true }
            out[i] = SIMD4(Float(color.r), Float(color.g), Float(color.b), w)
        }
        return any ? out : nil
    }
}

extension LightPalette {
    init(_ colors: FrameColors) {
        self.init(stops: colors.gradient.stops.map { (Float($0.0), SIMD3(Float($0.1.r), Float($0.1.g), Float($0.1.b))) },
                  byFrequency: colors.gradient.axis == .horizontal,
                  ambient: colors.ambient?.top.map { SIMD3(Float($0.r), Float($0.g), Float($0.b)) })
    }
}
