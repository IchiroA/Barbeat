import AppKit
import AVFoundation
import CoreMedia
import ImageIO
import ScreenCaptureKit

/// The colors of what's on screen, for the Screen palette. ScreenCaptureKit hands over a few tiny frames a second
/// (scaled down by macOS on the GPU), and each one is boiled down to a three-color palette ("Main colors") and the
/// colors along each edge of the screen ("Ambient light"). Barbeat's own windows are left out of the picture.
/// When listening to one app, its biggest window is watched instead of the whole screen.
/// With light beams on, bright light that sweeps across the picture (stage beams, flashes) is followed too,
/// and spills its own color out of the screen next to it, like TV backlighting does.
final class ScreenColors: NSObject, ObservableObject {
    static let shared = ScreenColors()

    /// Ambient light samples along the top and bottom edges, and up the left and right edges.
    static let columns = 32, rows = 20
    /// Edge spots in all: top and bottom, then left and right (the shader's ambient buffer has the same layout).
    static let edgeCount = columns * 2 + rows * 2
    /// How quickly new light turns into a full beam: along the edges, and over the whole picture (Main colors).
    static let beamGain: Float = 5, overallBeamGain: Float = 15
    /// Until the first frame arrives (or without permission), the Screen palette looks like Accent.
    static var fallbackStops: GradientStops { Palette.accent.stops }

    struct Colors {
        /// Three colors, darkest first.
        var palette: [RGB]
        /// What the screen shows along each edge: top and bottom left to right, left and right bottom to top.
        var top: [RGB], bottom: [RGB], left: [RGB], right: [RGB]
        /// How strongly a light beam lights each edge spot right now (0...1), top, bottom, left, right.
        /// Empty when light beams are off.
        var beam: [Float] = []

        var paletteStops: GradientStops { GradientMath.evenlySpaced(palette) }

        /// The average color along part of the top edge (0...1 of the width), for one-color styles like Pulse.
        func topAverage(from u0: CGFloat, to u1: CGFloat) -> RGB {
            let n = top.count
            let i0 = max(0, min(n - 1, Int(u0 * CGFloat(n))))
            let i1 = max(i0 + 1, min(n, Int((u1 * CGFloat(n)).rounded(.up))))
            let picked = top[i0..<i1]
            let count = CGFloat(picked.count)
            return RGB(r: picked.reduce(0) { $0 + $1.r } / count, g: picked.reduce(0) { $0 + $1.g } / count,
                       b: picked.reduce(0) { $0 + $1.b } / count)
        }
    }

    /// Light beams in one frame: bright light that stands out from the picture and has just appeared or moved.
    struct Beams {
        /// For each edge spot (top, bottom, left, right): the color of the new light next to it (rgb)
        /// and how much of the screen there it lights (w, 0...1).
        var edges: [SIMD4<Float>]
        /// The same for the whole picture (Main colors).
        var overall: SIMD4<Float>

        static let none = Beams(edges: Array(repeating: .zero, count: ScreenColors.edgeCount), overall: .zero)
    }

    enum State: Equatable {
        case off
        case starting
        case needsPermission
        case watchingScreen
        case watchingWindow(String)
        /// Every frame is black: a blank screen, a fade, or copy-protected video.
        case dark
        /// Stopped with macOS's screen recording indicator in the menu bar.
        case stoppedByUser
        case failed(String)
        case testImage
    }

    @Published private(set) var state: State = .off

    fileprivate var displays: Set<CGDirectDisplayID> = []
    private var followingApp: String?
    private var watchers: [CGDirectDisplayID: Watcher] = [:]
    private var target: [CGDirectDisplayID: Colors] = [:]
    private var current: [CGDirectDisplayID: Colors] = [:]
    private var darkDisplays: Set<CGDirectDisplayID> = []
    /// What's being watched, shown unless the picture is black.
    fileprivate var watching: State = .starting
    private var timer: Timer?
    private var generation = 0
    private var askedForPermission = false
    private var stoppedByUser = false

    // Light beams: each display's latest beams and when they came, and what's showing now (rgb color, w strength).
    private var beamTarget: [CGDirectDisplayID: Beams] = [:]
    private var beamArrived: [CGDirectDisplayID: Double] = [:]
    private var beamShown: [CGDirectDisplayID: [SIMD4<Float>]] = [:]
    private var overallShown: [CGDirectDisplayID: SIMD4<Float>] = [:]
    /// The colors handed out: `current` with the light beams laid over it.
    private var shown: [CGDirectDisplayID: Colors] = [:]
    /// A light beam is lit or still fading somewhere, so the visuals keep drawing while the music is quiet.
    private(set) var beamsShowing = false
    private var followBeams = false
    private var frameRate = 6
    /// A test picture never changes, so its beams stay instead of fading.
    private var holdBeams = false

    fileprivate let verbose = CommandLine.arguments.contains("--verbose")
    /// `--screen-image photo.png` uses that picture instead of the screen (for testing without permission).
    private let testImage = ScreenColors.loadTestImage()
    /// `--screen-video clip.mp4` plays a video's frames instead of the screen, looping (for testing light beams).
    private let testVideo = ScreenColors.argument("--screen-video").map { URL(fileURLWithPath: $0) }
    fileprivate var videoTimer: Timer?
    /// Snapshot runs never start a real capture, so they can't put up the permission prompt.
    private let liveAllowed = !CommandLine.arguments.contains { $0 == "--snapshot" || $0.hasSuffix("-snapshot") }

    // MARK: - Colors for the renderer

    /// This display's colors, or the main display's when it has none yet. Nil until a frame has arrived.
    func colors(for display: CGDirectDisplayID?) -> Colors? {
        if let display, let colors = shown[display] ?? current[display] { return colors }
        if let main = NSScreen.screens.first?.displayID, let colors = shown[main] ?? current[main] { return colors }
        return shown.values.first ?? current.values.first
    }

    /// For the swatch and Customize: the current colors (along the top edge, for Ambient light), or the fallback.
    var previewStops: GradientStops {
        guard let colors = colors(for: nil) else { return Self.fallbackStops }
        if Settings.shared.screenColorMode == .ambient {
            return GradientMath.evenlySpaced(stride(from: 0, to: colors.top.count, by: 6).map { colors.top[$0] })
        }
        return colors.paletteStops
    }

    /// Glides the colors toward the latest frame. Called every display frame.
    func advance(dt: Double) {
        let ambientStep = CGFloat(1 - exp(-dt / 0.35)), paletteStep = CGFloat(1 - exp(-dt / 0.6))
        for (id, goal) in target {
            guard var now = current[id] else {
                current[id] = goal
                continue
            }
            func glide(_ list: inout [RGB], _ goal: [RGB], _ step: CGFloat) {
                guard list.count == goal.count else { list = goal; return }
                for i in list.indices { list[i] = list[i].mixed(with: goal[i], step) }
            }
            glide(&now.palette, goal.palette, paletteStep)
            glide(&now.top, goal.top, ambientStep)
            glide(&now.bottom, goal.bottom, ambientStep)
            glide(&now.left, goal.left, ambientStep)
            glide(&now.right, goal.right, ambientStep)
            current[id] = now
        }
        layBeams(dt: dt)
    }

    /// Lays the light beams over the colors. Each edge spot leans toward the color of a beam next to it and lights up
    /// within a few hundredths of a second, then fades over about half a second, so a sweep leaves a short trail.
    private func layBeams(dt: Double) {
        let settings = Settings.shared
        guard settings.screenBeams else {
            shown = current
            beamShown.removeAll()
            overallShown.removeAll()
            beamsShowing = false
            return
        }
        let now = CACurrentMediaTime()
        let strength = Float(settings.screenBeamStrength)
        let rise = Float(1 - exp(-dt / 0.04)), fall = Float(1 - exp(-dt / 0.5)), tint = Float(1 - exp(-dt / 0.08))
        var showing = false
        for (id, base) in current {
            let target = beamTarget[id] ?? .none
            // Frames stop coming when the picture stops changing: then the beams fade out.
            let live = holdBeams || now - (beamArrived[id] ?? -1) < 0.35
            func follow(_ shown: inout SIMD4<Float>, _ goal: SIMD4<Float>, _ gain: Float) {
                let lit = live ? 1 - exp(-goal.w * gain * strength) : 0
                if lit > 0.02 {
                    // A new beam takes its color at once; one that's already lit glides to the new color.
                    let color = shown.w < 0.02 ? goal : shown + (goal - shown) * tint
                    shown = SIMD4(color.x, color.y, color.z, shown.w)
                }
                shown.w += (lit - shown.w) * (lit > shown.w ? rise : fall)
            }
            var beams = beamShown[id] ?? Array(repeating: .zero, count: Self.edgeCount)
            for i in beams.indices where i < target.edges.count { follow(&beams[i], target.edges[i], Self.beamGain) }
            var overall = overallShown[id] ?? .zero
            follow(&overall, target.overall, Self.overallBeamGain)
            beamShown[id] = beams
            overallShown[id] = overall

            var colors = base
            var lit = [Float](repeating: 0, count: Self.edgeCount)
            var offset = 0
            func lay(_ list: inout [RGB]) {
                for i in list.indices where offset + i < beams.count {
                    let beam = beams[offset + i]
                    lit[offset + i] = beam.w
                    if beam.w > 0.002 { list[i] = list[i].mixed(with: RGB(beam), CGFloat(min(1, beam.w * 1.25))) }
                }
                offset += list.count
            }
            lay(&colors.top)
            lay(&colors.bottom)
            lay(&colors.left)
            lay(&colors.right)
            colors.beam = lit
            // Main colors: the brightest colors lean toward the beam.
            let n = colors.palette.count
            if overall.w > 0.002, n >= 2 {
                colors.palette[n - 1] = colors.palette[n - 1].mixed(with: RGB(overall), CGFloat(overall.w))
                colors.palette[n - 2] = colors.palette[n - 2].mixed(with: RGB(overall), CGFloat(overall.w * 0.5))
            }
            shown[id] = colors
            showing = showing || overall.w > 0.01 || lit.contains { $0 > 0.01 }
        }
        beamsShowing = showing
    }

    /// Light beams need quicker frames: 15 a second (10 on battery) instead of 6.
    func configure(beams: Bool, onBattery: Bool) {
        let rate = beams ? (onBattery ? 10 : 15) : 6
        guard beams != followBeams || rate != frameRate else { return }
        followBeams = beams
        frameRate = rate
        watchers.values.forEach { $0.configure(beams: beams, frameRate: rate) }
        if verbose { print("screen colors: \(rate) frames a second, light beams \(beams ? "on" : "off")") }
    }

    // MARK: - What to watch

    /// Watches these displays (none stops everything). With an app's bundle ID, its biggest window is watched instead.
    func watch(displays: Set<CGDirectDisplayID>, followingApp app: String?) {
        guard displays != self.displays || app != followingApp else { return }
        self.displays = displays
        followingApp = app
        stoppedByUser = false
        if displays.isEmpty {
            stopAll()
            return
        }
        if let testImage {
            useTestImage(testImage)
            return
        }
        if let testVideo {
            playTestVideo(testVideo)
            return
        }
        guard liveAllowed else { return }
        if timer == nil {
            // Windows come and go and move between screens: look again every few seconds.
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        }
        if state == .off {
            watching = .starting
            publish()
        }
        refresh()
    }

    /// "Try Again" in the panel: after the user changes the permission, or stopped it from the menu bar.
    func retry() {
        stoppedByUser = false
        refresh(userAsked: true)
    }

    private func stopAll() {
        timer?.invalidate()
        timer = nil
        videoTimer?.invalidate()
        videoTimer = nil
        generation += 1
        watchers.values.forEach { $0.stop() }
        watchers.removeAll()
        darkDisplays.removeAll()
        // The last colors stay, so coming back to the Screen palette doesn't flash the fallback.
        watching = .off
        publish()
    }

    private func refresh(userAsked: Bool = false) {
        guard !displays.isEmpty, testImage == nil, testVideo == nil, liveAllowed, !stoppedByUser else { return }
        // Watching whole screens and all running: nothing to look up until something changes.
        if !userAsked, followingApp == nil, displays.allSatisfy({ watchers[$0]?.isWatchingWholeDisplay == true }) { return }
        if !CGPreflightScreenCaptureAccess() {
            if !askedForPermission {
                askedForPermission = true
                CGRequestScreenCaptureAccess()   // macOS's own prompt, once per launch
            }
            // The permission check can lag behind System Settings; only "Try Again" looks anyway.
            if !userAsked {
                watching = .needsPermission
                publish()
                return
            }
        }
        generation += 1
        let generation = self.generation
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self, generation == self.generation, !self.displays.isEmpty else { return }
                guard let content else {
                    self.failed(error)
                    return
                }
                self.apply(content)
            }
        }
    }

    private func apply(_ content: SCShareableContent) {
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var followed: SCWindow?
        if let app = followingApp {
            followed = content.windows
                .filter {
                    $0.owningApplication?.bundleIdentifier == app && $0.windowLayer == 0 && $0.isOnScreen
                        && $0.frame.width >= 200 && $0.frame.height >= 120
                }
                .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        }

        var watchingWindow = false
        for id in displays {
            guard let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let watcher = watchers[id] ?? makeWatcher(for: id)
            if let window = followed, display.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY)) {
                watchingWindow = true
                watcher.show(SCContentFilter(desktopIndependentWindow: window), key: UInt64(window.windowID),
                             size: window.frame.size)
            } else {
                watcher.show(SCContentFilter(display: display, excludingApplications: me, exceptingWindows: []),
                             key: 0, size: display.frame.size)
            }
        }
        for id in Array(watchers.keys) where !displays.contains(id) {
            watchers.removeValue(forKey: id)?.stop()
        }
        let appName = followed?.owningApplication?.applicationName ?? ""
        watching = watchingWindow ? .watchingWindow(appName) : .watchingScreen
        publish()
    }

    private func makeWatcher(for id: CGDirectDisplayID) -> Watcher {
        let watcher = Watcher(
            onFrame: { [weak self] result in self?.received(result, from: id) },
            onStop: { [weak self] error in self?.failed(error) })
        watcher.configure(beams: followBeams, frameRate: frameRate)
        watchers[id] = watcher
        return watcher
    }

    fileprivate func received(_ result: ScreenAnalysis.Result, from id: CGDirectDisplayID) {
        guard displays.contains(id) else { return }
        if let beams = result.beams {
            beamTarget[id] = beams
            beamArrived[id] = CACurrentMediaTime()
        }
        if result.isDark {
            // Keep the last colors through fades and black (or protected) video.
            darkDisplays.insert(id)
        } else {
            darkDisplays.remove(id)
            target[id] = result.colors
            if current[id] == nil { current[id] = result.colors }
        }
        publish()
    }

    private func failed(_ error: Error?) {
        let code = (error as NSError?)?.code
        if code == SCStreamError.userStopped.rawValue {
            // Stopped from macOS's recording indicator: don't start again behind the user's back.
            stoppedByUser = true
            watchers.values.forEach { $0.stop() }
            watching = .stoppedByUser
        } else if code == SCStreamError.userDeclined.rawValue || !CGPreflightScreenCaptureAccess() {
            watching = .needsPermission
        } else {
            watching = .failed(error?.localizedDescription ?? "Screen capture stopped.")
        }
        if verbose { print("screen colors: \(watching) \(error.map { "\($0)" } ?? "")") }
        publish()
    }

    fileprivate func publish() {
        let isWatching: Bool
        switch watching {
        case .watchingScreen, .watchingWindow, .testImage: isWatching = true
        default: isWatching = false
        }
        let next: State = isWatching && !darkDisplays.isEmpty && darkDisplays.isSuperset(of: displays) ? .dark : watching
        if state != next {
            state = next
            if verbose { print("screen colors: \(next)") }
        }
    }

    // MARK: - Test image

    private static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func loadTestImage() -> CGImage? {
        guard let path = argument("--screen-image") else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            print("screen colors: couldn't read \(url.path)")
            return nil
        }
        return image
    }

    private func useTestImage(_ image: CGImage) {
        // Everything in a test picture is new, so any light beams in it show (and stay: it never changes).
        let beams = Settings.shared.screenBeams
        guard let result = ScreenAnalysis.analyze(image, beams: beams ? BeamTracker(firstFrameIsNew: true) : nil)
        else { return }
        holdBeams = true
        for id in displays {
            if let beams = result.beams {
                beamTarget[id] = beams
                beamArrived[id] = CACurrentMediaTime()
            }
            if result.isDark {
                darkDisplays.insert(id)
            } else {
                target[id] = result.colors
                current[id] = result.colors
            }
        }
        watching = .testImage
        publish()
        guard verbose else { return }
        func time(_ beams: Bool) -> Double {
            let start = CACurrentMediaTime()
            let runs = 200
            for _ in 0..<runs { _ = ScreenAnalysis.analyze(image, beams: beams ? BeamTracker(firstFrameIsNew: true) : nil) }
            return (CACurrentMediaTime() - start) / Double(runs) * 1000
        }
        func hex(_ list: [RGB]) -> String { list.map { HSB($0).hex }.joined(separator: " ") }
        let c = result.colors
        print(String(format: "screen colors: test image, %.3f ms per frame (incl. scaling), %.3f ms with light beams",
                     time(false), time(true)))
        if let beams = result.beams { print("screen colors: beams " + Self.describe(beams)) }
        print("screen colors: palette \(hex(c.palette)) dark=\(result.isDark)")
        print("screen colors: top \(hex(stride(from: 0, to: c.top.count, by: 4).map { c.top[$0] }))")
        print("screen colors: bottom \(hex(stride(from: 0, to: c.bottom.count, by: 4).map { c.bottom[$0] }))")
        print("screen colors: left \(hex(stride(from: 0, to: c.left.count, by: 4).map { c.left[$0] }))")
        print("screen colors: right \(hex(stride(from: 0, to: c.right.count, by: 4).map { c.right[$0] }))")
    }
}

extension ScreenColors {
    /// Plays a video's frames through the analysis, as if they were the screen (`--screen-video`).
    fileprivate func playTestVideo(_ url: URL) {
        guard videoTimer == nil else { return }
        watching = .testImage
        publish()
        let rate = 15.0
        Task { @MainActor [weak self] in
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = CGSize(width: 384, height: 384)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.appliesPreferredTrackTransform = true
            var frames: [CGImage] = []
            do {
                let duration = try await asset.load(.duration).seconds
                var t = 0.0
                while t < duration {
                    frames.append(try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image)
                    t += 1 / rate
                }
            } catch {
                print("screen colors: couldn't read \(url.path): \(error.localizedDescription)")
            }
            self?.startTestVideo(frames, rate: rate)
        }
    }

    private func startTestVideo(_ frames: [CGImage], rate: Double) {
        guard !frames.isEmpty, videoTimer == nil else { return }
        if verbose { print("screen colors: test video, \(frames.count) frames at \(Int(rate)) a second, looping") }
        let tracker = BeamTracker()
        var index = 0
        videoTimer = Timer.scheduledTimer(withTimeInterval: 1 / rate, repeats: true) { [weak self] _ in
            guard let self else { return }
            let beams = Settings.shared.screenBeams ? tracker : nil
            guard let result = ScreenAnalysis.analyze(frames[index % frames.count], beams: beams) else { return }
            if self.verbose, let found = result.beams {
                print(String(format: "beams %5.2fs ", Double(index % frames.count) / rate) + Self.describe(found))
            }
            index += 1
            for id in self.displays { self.received(result, from: id) }
        }
    }

    /// One line per frame for `--verbose`: how lit each edge spot is (0-9) and the whole picture's beam.
    fileprivate static func describe(_ beams: Beams) -> String {
        let strength = Float(Settings.shared.screenBeamStrength)
        func strip(_ range: Range<Int>) -> String {
            beams.edges[range].map { beam in
                let lit = 1 - exp(-beam.w * beamGain * strength)
                return lit < 0.05 ? "." : String(min(9, Int(lit * 10)))
            }.joined()
        }
        let c = columns, r = rows, o = beams.overall
        let overall = 1 - exp(-o.w * overallBeamGain * strength)
        return "top \(strip(0..<c)) bottom \(strip(c..<2 * c)) left \(strip(2 * c..<2 * c + r)) "
            + "right \(strip(2 * c + r..<2 * c + 2 * r)) "
            + String(format: "overall %.2f %@", overall, HSB(RGB(o)).hex)
    }
}

extension RGB {
    /// The color in the first three values of a SIMD4 (light beams keep their strength in the fourth).
    init(_ v: SIMD4<Float>) { self.init(r: CGFloat(v.x), g: CGFloat(v.y), b: CGFloat(v.z)) }
}

/// One display's capture stream.
private final class Watcher: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    /// What's being captured: a window ID, or 0 for the whole display.
    private var key: UInt64?
    private let queue = DispatchQueue(label: "com.ia.Barbeat.screen-colors", qos: .utility)
    private let onFrame: (ScreenAnalysis.Result) -> Void
    private let onStop: (Error) -> Void
    /// Follows light beams from frame to frame. Only used on `queue`, like `tracksBeams`.
    private let tracker = BeamTracker()
    private var tracksBeams = false
    private var frameRate = 6
    private var size = CGSize.zero

    var isWatchingWholeDisplay: Bool { stream != nil && key == 0 }

    init(onFrame: @escaping (ScreenAnalysis.Result) -> Void, onStop: @escaping (Error) -> Void) {
        self.onFrame = onFrame
        self.onStop = onStop
    }

    /// Whether to look for light beams, and how many frames a second to ask for.
    func configure(beams: Bool, frameRate: Int) {
        queue.async { [self] in
            tracksBeams = beams
            tracker.reset()
        }
        guard frameRate != self.frameRate else { return }
        self.frameRate = frameRate
        if let stream, key != nil {
            stream.updateConfiguration(Self.configuration(for: size, frameRate: frameRate)) { _ in }
        }
    }

    func show(_ filter: SCContentFilter, key: UInt64, size: CGSize) {
        guard key != self.key || stream == nil else { return }
        self.key = key
        self.size = size
        // A different picture: start over with what's in it.
        queue.async { [tracker] in tracker.reset() }
        let config = Self.configuration(for: size, frameRate: frameRate)
        if let stream {
            stream.updateConfiguration(config) { _ in }
            stream.updateContentFilter(filter) { _ in }
            return
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        } catch {
            self.key = nil
            onStop(error)
            return
        }
        self.stream = stream
        stream.startCapture { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                guard let self, self.stream === stream else { return }
                self.stream = nil
                self.key = nil
                self.onStop(error)
            }
        }
    }

    func stop() {
        let stream = self.stream
        stream?.stopCapture { _ in withExtendedLifetime(stream) {} }
        self.stream = nil
        key = nil
    }

    private static func configuration(for size: CGSize, frameRate: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        // Tiny frames are plenty for colors; macOS scales them down on the GPU before handing them over.
        let width = 192
        let height = max(16, min(240, Int((CGFloat(width) * size.height / max(1, size.width)).rounded())))
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))   // 6, or 15 for light beams
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.scalesToFit = true
        return config
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Frames only arrive when something on screen changed; "idle" ones carry no picture.
        guard type == .screen, sampleBuffer.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = sampleBuffer.imageBuffer else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let result = ScreenAnalysis.analyze(base, width: CVPixelBufferGetWidth(pixels),
                                            height: CVPixelBufferGetHeight(pixels),
                                            bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), bgra: true,
                                            beams: tracksBeams ? tracker : nil)
        DispatchQueue.main.async { [weak self] in self?.onFrame(result) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            self.key = nil
            self.onStop(error)
        }
    }
}

/// Turns one small frame into the Screen palette's colors.
enum ScreenAnalysis {
    struct Result {
        var colors: ScreenColors.Colors
        /// Nothing but black: a blank screen, a fade, or copy-protected video.
        var isDark: Bool
        /// Light beams, when they're being followed.
        var beams: ScreenColors.Beams?
    }

    /// Analyzes a picture the way a screen frame would be (for `--screen-image` and `--screen-video`).
    static func analyze(_ image: CGImage, beams tracker: BeamTracker? = nil) -> Result? {
        let width = 192
        let height = max(16, min(240, Int((CGFloat(width) * CGFloat(image.height) / CGFloat(max(1, image.width))).rounded())))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue   // BGRA
        return pixels.withUnsafeMutableBytes { buffer -> Result? in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: info) else { return nil }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return analyze(buffer.baseAddress!, width: width, height: height, bytesPerRow: width * 4, bgra: true,
                           beams: tracker)
        }
    }

    /// `base` holds 8-bit pixels, BGRA or RGBA, first row at the top of the screen.
    /// With a beam tracker, light beams are looked for too (it remembers the frames before).
    static func analyze(_ base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int, bgra: Bool,
                        beams tracker: BeamTracker? = nil) -> Result {
        let cols = ScreenColors.columns, rows = ScreenColors.rows
        // Each cell of a coarse grid sums its pixels' colors, weighted so bright, colorful pixels count most
        // and black counts for nothing (stage lights against a dark stage, video inside letterbox bars).
        var cells = [SIMD4<Float>](repeating: .zero, count: cols * rows)   // r·w, g·w, b·w, w
        var counts = [Float](repeating: 0, count: cols * rows)
        var dominant = DominantColors()
        // Light beams: how bright each pixel looks, and how much of the picture is how bright.
        let tracking = tracker != nil
        var glow = [Float](repeating: 0, count: tracking ? width * height : 0)
        var histogram = [Int](repeating: 0, count: tracking ? glowBins : 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let (ri, bi) = bgra ? (2, 0) : (0, 2)
        for y in 0..<height {
            let row = bytes + y * bytesPerRow
            let cellRow = min(rows - 1, y * rows / height) * cols
            for x in 0..<width {
                let p = row + x * 4
                let r = Float(p[ri]) / 255, g = Float(p[1]) / 255, b = Float(p[bi]) / 255
                let hi = max(r, g, b), lo = min(r, g, b)
                let s: Float = hi > 0 ? (hi - lo) / hi : 0
                let w = hi * hi * (0.08 + s)
                let cell = cellRow + min(cols - 1, x * cols / width)
                cells[cell] += SIMD4(r * w, g * w, b * w, w)
                counts[cell] += 1
                dominant.add(r: r, g: g, b: b)
                if tracking {
                    // Halfway between the brightest channel and luminance: white light counts most,
                    // and a pure blue or red beam still counts.
                    let v = 0.5 * hi + 0.5 * (0.2126 * r + 0.7152 * g + 0.0722 * b)
                    glow[y * width + x] = v
                    histogram[min(glowBins - 1, Int(v * Float(glowBins)))] += 1
                }
            }
        }

        var total = SIMD4<Float>.zero, totalCount: Float = 0
        for i in cells.indices {
            total += cells[i]
            totalCount += counts[i]
        }
        // Average pixel weight: 0 for black, 0.08 for white, about 1 for vivid colors.
        let isDark = total.w / max(1, totalCount) < 0.002
        let overall = total.w > 0 ? vivid(total) : .white

        typealias Slice = (sum: SIMD4<Float>, count: Float)
        func slice(_ picks: [(cell: Int, weight: Float)]) -> Slice {
            var sum = SIMD4<Float>.zero, count: Float = 0
            for pick in picks {
                sum += cells[pick.cell] * pick.weight
                count += counts[pick.cell] * pick.weight
            }
            return (sum, count)
        }
        let slices = edgePicks.map(slice)
        let top = Array(slices[0..<cols]), bottom = Array(slices[cols..<2 * cols])
        let left = Array(slices[2 * cols..<2 * cols + rows]), right = Array(slices[2 * cols + rows..<2 * cols + 2 * rows])

        /// Each sample looks mostly at its own spot and a little further along the edge, so the colors flow,
        /// and a dark gap between two lights takes their colors. Only where there's nothing nearby at all
        /// does it lean toward the whole screen's color.
        func spread(_ slices: [Slice]) -> [RGB] {
            slices.indices.map { i in
                var sum = SIMD4<Float>.zero, count: Float = 0
                for j in slices.indices {
                    let d = Float(i - j)
                    let k = exp(-d * d / 3) + 0.2 * exp(-d * d / 72)
                    sum += slices[j].sum * k
                    count += slices[j].count * k
                }
                guard sum.w > 1e-6 else { return overall }
                let confidence = sum.w / max(1, count)
                let t = CGFloat(min(1, max(0, (confidence - 0.002) / 0.018)))
                return overall.mixed(with: vivid(sum), t * t * (3 - 2 * t))
            }
        }

        let palette = dominant.colors(count: 3)
            ?? [overall.mixed(with: .black, 0.35), overall, overall.mixed(with: .white, 0.4)]
        let colors = ScreenColors.Colors(palette: palette, top: spread(top), bottom: spread(bottom),
                                         left: spread(left), right: spread(right))
        let beams = tracker.map {
            findBeams($0, base: base, width: width, height: height, bytesPerRow: bytesPerRow, bgra: bgra,
                      glow: glow, histogram: histogram, counts: counts)
        }
        return Result(colors: colors, isDark: isDark, beams: beams)
    }

    /// For each edge spot (top and bottom left to right, left and right bottom to top): the grid cells it looks at,
    /// and how much each counts. Top and bottom look at the half of the screen next to them, the sides at the
    /// outer third, counting the parts nearest the edge most.
    private static let edgePicks: [[(cell: Int, weight: Float)]] = {
        let cols = ScreenColors.columns, rows = ScreenColors.rows
        let half = rows / 2, side = cols * 5 / 16
        func nearness(_ d: Int, _ span: Int) -> Float { 1 - 0.7 * Float(d) / Float(span) }
        var picks: [[(cell: Int, weight: Float)]] = []
        for c in 0..<cols { picks.append((0..<half).map { (cell: $0 * cols + c, weight: nearness($0, half)) }) }
        for c in 0..<cols { picks.append((0..<half).map { (cell: (rows - 1 - $0) * cols + c, weight: nearness($0, half)) }) }
        for r in 0..<rows {   // the sides run bottom to top
            picks.append((0..<side).map { (cell: (rows - 1 - r) * cols + $0, weight: nearness($0, side)) })
        }
        for r in 0..<rows {
            picks.append((0..<side).map { (cell: (rows - 1 - r) * cols + cols - 1 - $0, weight: nearness($0, side)) })
        }
        return picks
    }()

    private static let glowBins = 64

    /// Light beams: light well above the picture's own level (stage beams, flashes, spotlights) that has just
    /// appeared or moved. Each edge spot gets the color of the new light next to it, and how much of its area it lights.
    private static func findBeams(_ tracker: BeamTracker, base: UnsafeRawPointer, width: Int, height: Int,
                                  bytesPerRow: Int, bgra: Bool, glow: [Float], histogram: [Int],
                                  counts: [Float]) -> ScreenColors.Beams {
        let cols = ScreenColors.columns, rows = ScreenColors.rows
        // The picture's own level is where its darkest 30% ends. Light has to stand well clear of that to count,
        // so a bright web page or a daylight scene isn't one big beam.
        let darkest = width * height * 3 / 10
        var seen = 0, bin = 0
        while bin < glowBins - 1 {
            seen += histogram[bin]
            if seen >= darkest { break }
            bin += 1
        }
        let low = max(0.5, Float(bin) / Float(glowBins) + 0.3), high = low + 0.25
        var lit = [SIMD4<Float>](repeating: .zero, count: cols * rows)   // r·h, g·h, b·h, h
        if low < 0.97 {
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let (ri, bi) = bgra ? (2, 0) : (0, 2)
            for y in 0..<height {
                let row = bytes + y * bytesPerRow
                let cellRow = min(rows - 1, y * rows / height) * cols
                for x in 0..<width {
                    let v = glow[y * width + x]
                    guard v > low else { continue }
                    let t = min(1, (v - low) / (high - low))
                    let h = t * t * (3 - 2 * t)
                    let p = row + x * 4
                    lit[cellRow + min(cols - 1, x * cols / width)] +=
                        SIMD4(Float(p[ri]) / 255 * h, Float(p[1]) / 255 * h, Float(p[bi]) / 255 * h, h)
                }
            }
        }
        let density = lit.indices.map { counts[$0] > 0 ? lit[$0].w / counts[$0] : 0 }
        let fresh = tracker.update(density, now: CACurrentMediaTime())

        // Only the new part of each cell's light counts: its area, and its color.
        var area = [Float](repeating: 0, count: lit.count)
        var color = [SIMD4<Float>](repeating: .zero, count: lit.count)
        for i in lit.indices where fresh[i] > 0 {
            area[i] = fresh[i] * counts[i]
            color[i] = lit[i] * (fresh[i] / max(density[i], 1e-4))
        }
        func beam(_ picks: [(cell: Int, weight: Float)]) -> SIMD4<Float> {
            var total: Float = 0, covered: Float = 0, sum = SIMD4<Float>.zero
            for pick in picks {
                total += counts[pick.cell] * pick.weight
                covered += area[pick.cell] * pick.weight
                sum += color[pick.cell] * pick.weight
            }
            let rgb = beamColor(sum)
            return SIMD4(rgb.x, rgb.y, rgb.z, total > 0 ? covered / total : 0)
        }
        var edges = edgePicks.map(beam)
        // Soften each edge a little along its length, so a beam doesn't step from spot to spot.
        for range in [0..<cols, cols..<2 * cols, 2 * cols..<2 * cols + rows, 2 * cols + rows..<2 * cols + 2 * rows] {
            let w = range.map { edges[$0].w }
            for (k, i) in range.enumerated() {
                edges[i].w = 0.25 * w[max(0, k - 1)] + 0.5 * w[k] + 0.25 * w[min(w.count - 1, k + 1)]
            }
        }
        let overall = beam(lit.indices.map { (cell: $0, weight: 1) })
        return ScreenColors.Beams(edges: edges, overall: overall)
    }

    /// A beam's color from its weighted sum: full brightness, and a little more saturated so a pale beam keeps its tint.
    private static func beamColor(_ sum: SIMD4<Float>) -> SIMD3<Float> {
        guard sum.w > 1e-5 else { return .zero }
        let hsb = HSB(RGB(r: CGFloat(sum.x / sum.w), g: CGFloat(sum.y / sum.w), b: CGFloat(sum.z / sum.w)))
        let c = HSB(h: hsb.h, s: min(1, hsb.s * 1.4), b: max(0.85, hsb.b)).rgb
        return SIMD3(Float(c.r), Float(c.g), Float(c.b))
    }

    /// A weighted color sum as a light-friendly color: brighter, and a little more saturated.
    private static func vivid(_ sum: SIMD4<Float>) -> RGB {
        let c = RGB(r: CGFloat(sum.x / sum.w), g: CGFloat(sum.y / sum.w), b: CGFloat(sum.z / sum.w))
        let hsb = HSB(c)
        return HSB(h: hsb.h, s: min(1, hsb.s * 1.25), b: max(0.82, hsb.b)).rgb
    }
}

/// Remembers how much bright light each part of the picture usually has, so only light that just appeared or moved
/// counts as a beam. Steady bright things (a white window, a logo, a spotlight that holds still) fade out of it over
/// a few seconds; light that leaves and comes back counts as new again.
final class BeamTracker {
    private var usual: [Float] = []
    private var lastTime: Double = 0
    private let firstFrameIsNew: Bool

    /// Live capture starts from what's already on screen; a test picture counts as all new.
    init(firstFrameIsNew: Bool = false) {
        self.firstFrameIsNew = firstFrameIsNew
    }

    /// Forgets the picture (the stream switched to something else, or beams were turned off and on).
    func reset() {
        usual = []
    }

    /// Each cell's new light (0...1 of the cell), given how much of it is lit now.
    func update(_ density: [Float], now: Double) -> [Float] {
        if usual.count != density.count {
            usual = firstFrameIsNew ? Array(repeating: 0, count: density.count) : density
            lastTime = now
        }
        let dt = Float(max(0, now - lastTime))
        lastTime = now
        // Gets used to light over about 2.5 s, and lets go of it in under half a second.
        let learn = 1 - exp(-dt / 2.5), forget = 1 - exp(-dt / 0.4)
        var fresh = [Float](repeating: 0, count: density.count)
        for i in density.indices {
            fresh[i] = max(0, density[i] - usual[i] - 0.02)
            usual[i] += (density[i] - usual[i]) * (density[i] > usual[i] ? learn : forget)
        }
        return fresh
    }
}

/// Finds the few strongest colors in a picture with a hue histogram (Wallpaper and Screen palettes).
struct DominantColors {
    private static let bins = 12
    private var weight = [Float](repeating: 0, count: DominantColors.bins)
    private var sums = [SIMD3<Float>](repeating: .zero, count: DominantColors.bins)

    /// Adds one pixel (sRGB, 0...1). Grayish and dark pixels are skipped.
    mutating func add(r: Float, g: Float, b: Float) {
        let hi = max(r, g, b), lo = min(r, g, b)
        guard hi > 0 else { return }
        let delta = hi - lo
        let wgt = delta   // saturation × brightness
        guard wgt > 0.05 else { return }
        var hue: Float
        if hi == r { hue = (g - b) / delta } else if hi == g { hue = (b - r) / delta + 2 } else { hue = (r - g) / delta + 4 }
        hue /= 6
        if hue < 0 { hue += 1 }
        let bin = min(Self.bins - 1, Int(hue * Float(Self.bins)))
        weight[bin] += wgt
        sums[bin] += SIMD3(r, g, b) * wgt
    }

    /// Up to `count` vivid colors, darkest first, padded to at least three. Nil if the picture has no color.
    func colors(count: Int) -> [RGB]? {
        let top = weight.indices.sorted { weight[$0] > weight[$1] }.prefix(count).filter { weight[$0] > 0 }
        guard !top.isEmpty else { return nil }
        var colors: [RGB] = top.map { bin in
            let mean = sums[bin] / weight[bin]
            let hsb = HSB(RGB(r: CGFloat(mean.x), g: CGFloat(mean.y), b: CGFloat(mean.z)))
            // Vivid enough to read as light.
            return HSB(h: hsb.h, s: max(0.55, hsb.s), b: max(0.8, hsb.b)).rgb
        }
        colors.sort { $0.luminance < $1.luminance }
        if colors.count == 1 { colors = [colors[0].mixed(with: .black, 0.35), colors[0], colors[0].mixed(with: .white, 0.4)] }
        if colors.count == 2 { colors.append(colors[1].mixed(with: .white, 0.4)) }
        return colors
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
