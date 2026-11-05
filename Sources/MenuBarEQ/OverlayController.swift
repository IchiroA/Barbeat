import AppKit
import Combine
import QuartzCore
import AVFoundation
import IOKit.ps

/// Owns audio capture, analysis, the overlay windows, and the render loop.
final class OverlayController: NSObject {
    private let settings: Settings
    private let status: AudioStatus
    private let tap = AudioCapture()
    private let analyzer = SpectrumAnalyzer()
    private let sparks = SparkSystem()
    private let demo: DemoSignal?
    private let lights = LightHub.shared

    private var windows: [OverlayWindow] = []
    private var edgeWindows: [OverlayWindow] = []
    var windowsForSnapshot: [OverlayWindow] { windows }
    var edgeWindowsForSnapshot: [OverlayWindow] { edgeWindows }
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var wasAtRest = false
    private var cancellables = Set<AnyCancellable>()
    /// Each screen's menu bar height when last seen, for full-screen apps (where the menu bar hides).
    private var menuBarHeights: [CGDirectDisplayID: CGFloat] = [:]
    /// On battery the visuals draw at 30 fps instead of 60, to save power.
    private let power = PowerSource()
    /// The waterfall scrolls one column per 1/60 s whatever the frame rate.
    private var waterfallClock: Double = 0
    /// Keeps the lights going when the display sleeps (the display link stops then).
    private var lightsTimer: Timer?
    private var lastStep: CFTimeInterval = 0
    /// Watches for the frontmost app entering or leaving full screen.
    private var presentationObserver: NSKeyValueObservation?
    /// When the strip over a full-screen app last looked for open menus.
    private var lastMenuCheck: CFTimeInterval = 0
    /// What the menu bar's text looks like, for "Keep menu bar text readable" (checked every couple of seconds).
    private var lastTextCheck: CFTimeInterval = 0

    // For the "listening / silent" status line.
    private var loudnessWindow: Float = 0
    private var statusTimer: Double = 0
    /// `--verbose` prints the audio status to stdout every 1.5 s.
    private let verbose = CommandLine.arguments.contains("--verbose")
    /// `--source system|app:<bundle id>|device:<uid>` listens to that instead of the saved choice (for testing).
    private let sourceOverride = OverlayController.sourceArgument()

    init(settings: Settings, status: AudioStatus, demo: Bool) {
        self.settings = settings
        self.status = status
        self.demo = demo ? DemoSignal() : nil
        super.init()
    }

    func start() {
        tap.onEvent = { [weak self] event in self?.handle(event) }
        tap.source = currentSource()
        settings.$audioSource.combineLatest(settings.$sourceAppID, settings.$sourceDeviceUID)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.tap.source = self.currentSource()
                self.updateSourceStatus()
            }.store(in: &cancellables)
        if verbose {
            print("inputs: " + HAL.inputDevices().map { "\($0.name) [\($0.id)]\($0.isBluetooth ? " bluetooth" : "")" }
                .joined(separator: ", "))
            let playing = HAL.audioProcesses().filter(\.isPlaying).map { $0.bundleID.isEmpty ? "pid \($0.pid)" : $0.bundleID }
            print("playing now: " + (playing.isEmpty ? "nothing" : playing.joined(separator: ", ")))
            let mic = AVCaptureDevice.authorizationStatus(for: .audio)
            print("microphone permission: " + [.authorized: "allowed", .denied: "denied", .restricted: "restricted"][mic, default: "not asked yet"])
        }

        settings.$enabled.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyRunning() }.store(in: &cancellables)
        lights.onActiveChange = { [weak self] in self?.applyRunning() }
        settings.$allDisplays.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildWindows() }.store(in: &cancellables)
        settings.$edgeGlow.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildWindows() }.store(in: &cancellables)
        settings.$edgeGlowDepth.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildWindows() }.store(in: &cancellables)
        settings.$edgeGlowTop.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildWindows() }.store(in: &cancellables)
        settings.$showInFullScreen.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildWindows() }.store(in: &cancellables)
        settings.$fullScreenStrip.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildWindows() }.store(in: &cancellables)
        settings.$palette.combineLatest(settings.$audioSource, settings.$sourceAppID)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateScreenWatching() }.store(in: &cancellables)
        settings.$screenBeams.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateScreenCapture() }.store(in: &cancellables)
        updateScreenCapture()
        settings.$opacity.receive(on: RunLoop.main)
            .sink { [weak self] value in
                guard let self else { return }
                (self.windows + self.edgeWindows).forEach { $0.alphaValue = value }
            }.store(in: &cancellables)
        // Any setting change: repaint once, even if the bars are currently at rest.
        settings.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] in self?.redraw() }.store(in: &cancellables)

        power.onChange = { [weak self] in self?.applyFrameRate() }
        power.start()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(restartAudio),
            name: OverlayController.restartAudioNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(screensChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        // An app going into or out of full screen changes the system's presentation options.
        presentationObserver = NSApp.observe(\.currentSystemPresentationOptions) { [weak self] _, _ in
            DispatchQueue.main.async { self?.screensChanged() }
        }
        // The menu bar icon's look settles a moment after launch: first look after two seconds.
        lastTextCheck = CACurrentMediaTime()

        applyRunning()
    }

    /// Barbeat listens while the menu bar visuals or the lights are on (or the Lights window shows a preview).
    private var isListening: Bool { settings.enabled || lights.isActive || lights.previewWanted }

    /// The menu bar visuals and the lights have their own switches; audio and the render loop run for either.
    private func applyRunning() {
        if isListening {
            if demo != nil {
                status.state = .demo
            } else {
                tap.start()
            }
            startDisplayLink()
            startLightsTimer()
        } else {
            tap.stop()
            stopDisplayLink()
            lightsTimer?.invalidate()
            lightsTimer = nil
            status.state = .off
        }
        if settings.enabled {
            rebuildWindows()
        } else {
            (windows + edgeWindows).forEach { $0.orderOut(nil) }
            windows.removeAll()
            edgeWindows.removeAll()
            updateScreenWatching()
        }
    }

    static let restartAudioNotification = Notification.Name("MenuBarEQ.restartAudio")

    // MARK: - Audio source

    private func currentSource() -> CaptureSource {
        if let sourceOverride { return sourceOverride }
        switch settings.audioSource {
        case .system: return .system
        case .app: return .app(bundleID: settings.sourceAppID, name: settings.sourceAppName)
        case .device: return .device(uid: settings.sourceDeviceUID, name: settings.sourceDeviceName)
        }
    }

    private func handle(_ event: AudioCapture.Event) {
        updateSourceStatus()
        switch event {
        case .started: status.state = .starting
        case .stopped: status.state = .off
        case .failed(let error): status.state = .failed(error.localizedDescription)
        case .waitingForApp: status.state = .waitingForApp
        case .askingForMicrophone: status.state = .askingForMicrophone
        case .microphoneDenied: status.state = .microphoneDenied
        }
        if verbose {
            let detail: String
            if case .failed(let error) = event { detail = "failed — \(error.localizedDescription)" } else { detail = "\(event)" }
            print("audio: \(detail), source: \(tap.source)\(tap.usingFallback ? " (not connected, using system audio)" : "")")
        }
    }

    /// Tells the panel what's being listened to.
    private func updateSourceStatus() {
        switch tap.source {
        case .system:
            status.sourceKind = .system
            status.sourceName = "system audio"
            status.missingDevice = nil
        case let .app(_, name):
            status.sourceKind = .app
            status.sourceName = name
            status.missingDevice = nil
        case let .device(_, name):
            status.sourceKind = tap.usingFallback ? .system : .device
            status.sourceName = tap.usingFallback ? "system audio" : name
            status.missingDevice = tap.usingFallback ? name : nil
        }
    }

    private static func sourceArgument() -> CaptureSource? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--source"), i + 1 < args.count else { return nil }
        let value = args[i + 1]
        if value == "system" { return .system }
        if value.hasPrefix("app:") {
            let id = String(value.dropFirst(4))
            let name = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName ?? id
            return .app(bundleID: id, name: name)
        }
        if value.hasPrefix("device:") {
            let uid = String(value.dropFirst(7))
            return .device(uid: uid, name: HAL.inputDevices().first { $0.id == uid }?.name ?? uid)
        }
        return nil
    }

    /// Recreates the tap, e.g. after the user grants audio permission.
    @objc private func restartAudio() {
        guard isListening, demo == nil else { return }
        tap.stop()
        tap.start()
    }

    @objc private func screensChanged() {
        guard isListening else { return }
        // Screen geometry can settle a beat after the notification, and an app going full screen
        // is still animating then, so look again a little later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isListening else { return }
            self.rebuildWindows()
            self.stopDisplayLink()
            self.startDisplayLink()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.settings.enabled else { return }
            self.rebuildWindows()
        }
    }

    /// What one screen gets: the strip's height (nil = no strip), how far below the screen's top the edge glow
    /// starts, and whether an app is in full screen there.
    private struct ScreenPlan {
        var strip: CGFloat?
        var glowTop: CGFloat
        var fullScreen: Bool
    }

    /// On a regular desktop the strip covers the menu bar and the glow starts below it. Over a full-screen app
    /// (where the menu bar hides) the strip is optional: it goes where the menu bar would be, at the height it had;
    /// without it the glow starts right at the top of the picture (below the black band around a notch).
    private func plan(for screen: NSScreen) -> ScreenPlan {
        // (`--pretend-full-screen` tests this layout on a regular desktop, so it ignores the real menu bar.)
        let menuBar = OverlayWindow.pretendFullScreenGap != nil ? nil : OverlayWindow.menuBarHeight(on: screen)
        let gap = OverlayWindow.coveringWindowGap(on: screen)
        // A window covering the screen with the menu bar hidden is a full-screen app. (If the menu bar still shows,
        // it's a maximized window, unless the frontmost app says it's in full screen.)
        let fullScreen = gap != nil && (menuBar == nil || NSApp.currentSystemPresentationOptions.contains(.fullScreen))
        guard fullScreen, let gap else {
            if let menuBar { menuBarHeights[screen.displayID] = menuBar }
            // No menu bar here (it hides itself): no strip, and the glow runs to the top.
            return ScreenPlan(strip: menuBar, glowTop: menuBar ?? 0, fullScreen: false)
        }
        let band = max(gap, menuBar ?? 0)
        guard settings.fullScreenStrip else { return ScreenPlan(strip: nil, glowTop: band, fullScreen: true) }
        let height = menuBarHeights[screen.displayID] ?? menuBar
            ?? max(screen.safeAreaInsets.top.rounded(.up), NSStatusBar.system.thickness)
        return ScreenPlan(strip: height, glowTop: max(height, band), fullScreen: true)
    }

    private func rebuildWindows() {
        guard settings.enabled else { return }
        let screens = settings.allDisplays ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        let plans = screens.map { (screen: $0, plan: plan(for: $0)) }
        if verbose {
            for (screen, plan) in plans {
                print("layout: display \(screen.displayID) full screen=\(plan.fullScreen) strip=\(plan.strip.map { "\($0) pt" } ?? "none") glow top=\(plan.glowTop) pt")
            }
        }
        let targets: [(screen: NSScreen, frame: NSRect, fullScreen: Bool)] = plans.compactMap { item in
            guard let height = item.plan.strip else { return nil }
            let f = item.screen.frame
            return (item.screen, NSRect(x: f.minX, y: f.maxY - height, width: f.width, height: height), item.plan.fullScreen)
        }

        while windows.count > targets.count { windows.removeLast().orderOut(nil) }
        while windows.count < targets.count { windows.append(OverlayWindow(settings: settings)) }

        for (window, (screen, frame, fullScreen)) in zip(windows, targets) {
            window.showInFullScreen(settings.showInFullScreen)
            window.overFullScreenApp = fullScreen
            window.alphaValue = settings.opacity
            window.setFrame(frame, display: false)
            window.eqView.analyzer = analyzer
            window.eqView.sparks = sparks
            window.eqView.notch = OverlayWindow.notchSpan(on: screen)
            window.orderFrontRegardless()
        }

        // Screen-edge glow: windows along the left, right and bottom of each screen (and the top, just below the
        // menu bar), as deep as the setting. The side windows run between the bottom and top ones,
        // which draw the corners themselves.
        var edgeFrames: [(edge: Int, frame: NSRect, run: CGFloat)] = []
        if settings.edgeGlow {
            for (screen, plan) in plans {
                let f = screen.frame
                // At most a third of the screen, so the left and right glows never overlap.
                let thickness = min(CGFloat(settings.edgeGlowDepth), min(f.width, f.height) / 3).rounded()
                let top = f.maxY - plan.glowTop
                let sideTop = settings.edgeGlowTop ? top - thickness : top
                let sideHeight = max(1, sideTop - f.minY - thickness)
                // The sides' bands run on through the top corners, up to the menu bar.
                let run = top - f.minY - thickness
                edgeFrames += [
                    (1, NSRect(x: f.minX, y: f.minY + thickness, width: thickness, height: sideHeight), run),
                    (2, NSRect(x: f.maxX - thickness, y: f.minY + thickness, width: thickness, height: sideHeight), run),
                    (3, NSRect(x: f.minX, y: f.minY, width: f.width, height: thickness), run),
                ]
                if settings.edgeGlowTop {
                    edgeFrames.append((4, NSRect(x: f.minX, y: top - thickness, width: f.width, height: thickness), run))
                }
            }
        }
        // Reuse the existing windows when the layout matches (e.g. after a space switch).
        if edgeWindows.map(\.eqView.edge) != edgeFrames.map(\.edge) {
            edgeWindows.forEach { $0.orderOut(nil) }
            edgeWindows = edgeFrames.map { OverlayWindow(settings: settings, edge: $0.edge) }
        }
        for (window, target) in zip(edgeWindows, edgeFrames) {
            window.showInFullScreen(settings.showInFullScreen)
            window.alphaValue = settings.opacity
            window.setFrame(target.frame, display: false)
            window.eqView.edgeRun = target.run
            window.eqView.analyzer = analyzer
            window.orderFrontRegardless()
        }
        // "No visible menu bar" only when there's no strip anywhere and no full-screen app explains it.
        if targets.isEmpty, !plans.contains(where: \.plan.fullScreen), demo == nil, status.state != .off {
            status.state = .noMenuBar
        } else if status.state == .noMenuBar {
            status.state = .starting
        }
        updateScreenWatching()
        redraw()
    }

    /// Screen palette: watch the screens Barbeat draws on, or the window of the app it listens to.
    /// With only the lights on, the main screen.
    private func updateScreenWatching() {
        let on = settings.palette == .screen && (settings.enabled || lights.isActive)
        var displays = on ? Set((windows + edgeWindows).compactMap { $0.screen?.displayID }) : []
        if on, lights.isActive, displays.isEmpty, let main = NSScreen.screens.first?.displayID { displays.insert(main) }
        let app = settings.audioSource == .app && !settings.sourceAppID.isEmpty ? settings.sourceAppID : nil
        ScreenColors.shared.watch(displays: displays, followingApp: app)
    }

    // MARK: - Render loop

    private func startDisplayLink() {
        guard displayLink == nil, let screen = NSScreen.screens.first else { return }
        let link = screen.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTimestamp = 0
        applyFrameRate()
    }

    /// 60 fps when plugged in, 30 on battery. Everything that moves is timed in seconds, so only smoothness changes.
    private func applyFrameRate() {
        displayLink?.preferredFrameRateRange = power.onBattery
            ? CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
            : CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        if verbose { print("frame rate: \(power.onBattery ? "30 fps (on battery)" : "60 fps")") }
        updateScreenCapture()
    }

    /// Light beams need quicker screen frames (fewer on battery).
    private func updateScreenCapture() {
        ScreenColors.shared.configure(beams: settings.screenBeams, onBattery: power.onBattery)
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func startLightsTimer() {
        guard lightsTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self, self.lights.isActive, CACurrentMediaTime() - self.lastStep > 0.2 else { return }
            self.advance(now: CACurrentMediaTime())
        }
        RunLoop.main.add(timer, forMode: .common)
        lightsTimer = timer
    }

    @objc private func step(_ link: CADisplayLink) {
        advance(now: link.timestamp)
    }

    /// Over a full-screen app the strip sits above the hidden menu bar. When the pointer goes up there (or a menu
    /// is open) the menu bar shows, and the strip drops below it so the menus stay readable.
    private func updateFullScreenStrips(now: CFTimeInterval) {
        let strips = windows.filter(\.overFullScreenApp)
        guard !strips.isEmpty else { return }
        let pointer = NSEvent.mouseLocation
        var menuOpen: Bool?
        for window in strips {
            let f = window.frame
            if pointer.x >= f.minX, pointer.x <= f.maxX, pointer.y >= f.minY - 2, pointer.y <= f.maxY + 1 {
                window.menuBarShowingUntil = now + 1.0
            } else if now < window.menuBarShowingUntil, now - lastMenuCheck > 0.25 {
                // Still showing: keep it while a menu is open (looked up a few times a second, not every frame).
                if menuOpen == nil {
                    lastMenuCheck = now
                    menuOpen = OverlayWindow.otherAppMenuIsOpen()
                }
                if menuOpen == true { window.menuBarShowingUntil = now + 0.5 }
            }
            window.menuBarShowing = now < window.menuBarShowingUntil
        }
    }

    private func advance(now: CFTimeInterval) {
        lastStep = CACurrentMediaTime()
        updateFullScreenStrips(now: lastStep)
        if lastStep - lastTextCheck > 2 {
            lastTextCheck = lastStep
            MenuBarText.update()
        }
        let dt = lastTimestamp == 0 ? 1.0 / 60 : min(0.1, max(0.001, now - lastTimestamp))
        lastTimestamp = now

        let ring = tap.ring
        let sampleRate: Double
        if let demo {
            demo.render(seconds: dt, into: ring)
            sampleRate = demo.sampleRate
        } else {
            sampleRate = tap.sampleRate
        }

        let fresh = ring.secondsSinceLastWrite < 0.3
        let style = settings.style
        let stereoStrip = style.alwaysStereo || settings.layout == .stereo
        analyzer.process(
            ring: fresh ? ring : nil,
            sampleRate: sampleRate,
            dt: Float(dt),
            options: AnalyzerOptions(
                bandCount: settings.bandCount,
                sensitivityDb: Float(settings.sensitivity),
                autoLevel: settings.autoLevel,
                // VU only needs the raw left/right levels; the lights use both mid and left/right.
                mono: (!stereoStrip && style != .vu) || lights.isActive || lights.previewWanted,
                stereo: (stereoStrip && style != .vu) || settings.edgeGlow || lights.isActive || lights.previewWanted,
                scope: style == .scope,
                lowGainDb: Float(settings.lowGain),
                midGainDb: Float(settings.midGain),
                highGainDb: Float(settings.highGain)))

        sparks.update(dt: Float(dt), left: analyzer.left, right: analyzer.right,
                      spawning: style == .sparks, power: Float(settings.sparkPower))
        let history = MetalRenderer.shared?.history
        if style == .waterfall, let history, !(analyzer.isAtRest && history.isEmpty) {
            waterfallClock = min(waterfallClock + dt, 4.0 / 60)
            while waterfallClock >= 1.0 / 60 {
                history.push(analyzer)
                waterfallClock -= 1.0 / 60
            }
        }
        updateStatus(dt: dt, fresh: fresh)
        if settings.palette == .screen { ScreenColors.shared.advance(dt: dt) }
        lights.tick(analyzer: analyzer, sound: fresh ? analyzer.rms : 0, dt: dt,
                    colors: FrameColors.current(settings: settings, display: NSScreen.screens.first?.displayID,
                                                time: CACurrentMediaTime()),
                    stereoLayout: stereoStrip)

        // Skip redraws while nothing is moving, to save energy. Light beams light up even when the music is quiet.
        let beams = settings.palette == .screen && ScreenColors.shared.beamsShowing
        let atRest = analyzer.isAtRest && sparks.isEmpty && (style != .waterfall || history?.isEmpty ?? true) && !beams
        if atRest && wasAtRest { return }
        wasAtRest = atRest
        redraw()
    }

    private func redraw() {
        for window in windows + edgeWindows {
            window.eqView.render()
        }
    }

    private func updateStatus(dt: Double, fresh: Bool) {
        guard demo == nil, tap.isCapturing, !(windows + edgeWindows).isEmpty || lights.isActive,
              [.starting, .listening, .silent].contains(status.state) else { return }
        loudnessWindow = max(loudnessWindow, fresh ? analyzer.rms : 0)
        statusTimer += dt
        guard statusTimer >= 1.5 else { return }
        let next: AudioStatus.State = loudnessWindow > 0.0005 ? .listening : .silent
        if status.state != next { status.state = next }
        if verbose {
            print(String(format: "audio: %@ rms=%.5f rate=%.0f windows=%d source=%@", "\(next)", loudnessWindow,
                         tap.sampleRate, windows.count, "\(tap.source)"))
        }
        loudnessWindow = 0
        statusTimer = 0
    }
}

/// Whether the Mac is running on battery, with a callback when that changes.
final class PowerSource {
    private(set) var onBattery = PowerSource.isOnBattery()
    var onChange: (() -> Void)?
    private var source: CFRunLoopSource?

    func start() {
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let power = Unmanaged<PowerSource>.fromOpaque(context).takeUnretainedValue()
            let now = PowerSource.isOnBattery()
            guard now != power.onBattery else { return }
            power.onBattery = now
            power.onChange?()
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    static func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }
}
