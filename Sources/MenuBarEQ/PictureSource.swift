// Barbeat · made by Ichiro Ashihara (@IchiroA) · MIT License
import AppKit
import AVFoundation
import CoreMedia
import QuartzCore

/// Where Screen colors (and the kaleidoscope) get their picture.
enum PictureSource: String, CaseIterable, Identifiable {
    case screen, camera
    var id: String { rawValue }

    var title: String {
        switch self {
        case .screen: return "Your screen"
        case .camera: return "Camera or capture device"
        }
    }
}

/// A camera, an HDMI capture device, an iPhone (Continuity Camera) or a virtual camera.
struct CameraDevice: Identifiable, Equatable {
    /// AVFoundation's unique ID. Stable across launches (for a plugged-in device, as long as it stays in the same port).
    let id: String
    let name: String
    /// Plugged in: a capture device, a webcam, or a virtual camera.
    let isExternal: Bool
    /// An iPhone or iPad used as a camera.
    let isContinuity: Bool

    init(_ device: AVCaptureDevice) {
        id = device.uniqueID
        name = device.localizedName
        isExternal = device.deviceType == .external
        isContinuity = device.deviceType == .continuityCamera
    }
}

/// The cameras on offer, kept up to date as devices come and go. Listing them needs no permission.
final class CameraList: ObservableObject {
    static let shared = CameraList()

    @Published private(set) var devices: [CameraDevice] = []
    private var observers: [NSObjectProtocol] = []

    /// Capture devices and webcams first, then iPhones, then the built-in camera and Desk View.
    static let deviceTypes: [AVCaptureDevice.DeviceType] = [.external, .continuityCamera, .builtInWideAngleCamera, .deskViewCamera]

    private init() {
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        refresh()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    static func all() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .unspecified).devices
    }

    func refresh() {
        let now = Self.all().map(CameraDevice.init)
        if now != devices { devices = now }
    }

    /// The device to pick when "Camera" is first chosen: something plugged in (a capture device, usually), else an
    /// iPhone, else the built-in camera.
    var preferredDevice: CameraDevice? {
        devices.first(where: \.isExternal) ?? devices.first(where: \.isContinuity) ?? devices.first
    }

    /// The device with this ID, or failing that (a capture device moved to another port) one with the same name.
    static func device(id: String, name: String) -> AVCaptureDevice? {
        if let device = AVCaptureDevice(uniqueID: id), device.hasMediaType(.video) { return device }
        return all().first { $0.localizedName == name }
    }

    /// One line per camera, with its current format, for `--verbose`.
    static func describeAll() -> String {
        let lines = all().map { device -> String in
            let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let rate = device.activeFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let code = CMFormatDescriptionGetMediaSubType(device.activeFormat.formatDescription)
            let fourcc = String(bytes: withUnsafeBytes(of: code.bigEndian) { Array($0) }, encoding: .ascii) ?? "?"
            return "\(device.localizedName) [\(device.uniqueID)] \(size.width)x\(size.height) \(fourcc) up to \(Int(rate)) fps"
        }
        return lines.isEmpty ? "none" : lines.joined(separator: "; ")
    }
}

/// Finds the audio input that belongs to a camera or capture device, going by their names (a capture device usually
/// shows up as both, with the same name). Nil when nothing clearly matches.
enum DeviceMatch {
    static func audioInput(for cameraName: String, among inputs: [InputDevice]) -> InputDevice? {
        let wanted = words(cameraName)
        guard !wanted.isEmpty else { return nil }
        var best: (device: InputDevice, score: Int)?
        for input in inputs where !input.isBuiltIn {
            let have = words(input.name)
            // Words like "USB" or "HD" alone prove nothing.
            let telling = wanted.intersection(have).subtracting(generic)
            guard !telling.isEmpty else { continue }
            let score = telling.count * 10 + (wanted == have ? 100 : 0)
            if score > (best?.score ?? 0) { best = (input, score) }
        }
        return best?.device
    }

    private static let generic: Set<String> = [
        "usb", "video", "audio", "camera", "microphone", "mic", "hd", "hdmi", "device", "capture", "the", "pro",
        "digital", "webcam", "input", "output", "4k", "uvc", "uac",
    ]

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 2 })
    }
}

/// Which picture Barbeat watches right now: the saved choice, or `--picture screen|camera:<unique id>` (for testing).
enum PictureChoice {
    private enum Override { case screen, camera(CameraCapture.Config) }

    private static let override: Override? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--picture"), i + 1 < args.count else { return nil }
        let value = args[i + 1]
        if value == "screen" { return .screen }
        guard value.hasPrefix("camera:") else { return nil }
        let id = String(value.dropFirst(7))
        let name = CameraList.all().first { $0.uniqueID == id }?.localizedName ?? id
        return .camera(CameraCapture.Config(uid: id, name: name))
    }()

    /// `--picture` is in use (a test run: it may ask for camera access itself).
    static var isOverridden: Bool { override != nil }

    /// The camera to watch, or nil for the screen.
    static func camera(settings: Settings) -> CameraCapture.Config? {
        if let override {
            switch override {
            case .screen: return nil
            case .camera(let config): return config
            }
        }
        guard settings.pictureSource == .camera, !settings.cameraUID.isEmpty else { return nil }
        return CameraCapture.Config(uid: settings.cameraUID, name: settings.cameraName)
    }
}

/// Reads the one camera Barbeat watches (the device chosen under Screen colors): a few frames a second are boiled down
/// to colors for Screen colors, and while the kaleidoscope runs every frame is kept for the GPU. Shared, so Screen
/// colors and the kaleidoscope never open the same camera twice. The device's own format and frame rate are left
/// alone (other apps may be using it too); frames Barbeat doesn't need are simply dropped.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = CameraCapture()

    struct Config: Equatable {
        var uid: String
        var name: String
    }

    /// Who wants the camera.
    enum User: Hashable { case colors, show }

    enum State: Equatable {
        case off
        case starting
        case capturing(String)
        /// The chosen device isn't connected.
        case missing(String)
        case needsPermission
        case denied
        /// It's running, but no picture has come in for a while (a capture device without a signal, say).
        case waiting(String)
        case failed(String)
    }

    private(set) var state: State = .off {
        didSet {
            guard state != oldValue else { return }
            if verbose { print("camera: \(state)") }
            onChange?()
        }
    }
    /// Called on the main thread when `state` changes.
    var onChange: (() -> Void)?
    /// Each analyzed frame's colors, on the main thread.
    var onFrame: ((ScreenAnalysis.Result) -> Void)?

    var isCapturing: Bool {
        if case .capturing = state { return true }
        return false
    }

    /// The newest full frame, for the kaleidoscope (kept only while it wants them).
    var latestFrame: CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return newest
    }

    private var users: [User: Config] = [:]
    private(set) var config: Config?
    private let sessionQueue = DispatchQueue(label: "com.ia.Barbeat.camera", qos: .userInitiated)
    private let frameQueue = DispatchQueue(label: "com.ia.Barbeat.camera.frames", qos: .userInteractive)
    private var session: AVCaptureSession?
    private var device: AVCaptureDevice?
    /// Bumped on every start and stop, so late results from an old session are ignored.
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    private var watchdog: Timer?
    private var restarts: [CFTimeInterval] = []
    private let verbose = CommandLine.arguments.contains("--verbose")

    // Shared with the frame queue.
    private let lock = NSLock()
    private var newest: CVPixelBuffer?
    private var keepFrames = false
    /// Screen colors wants the colors (the kaleidoscope alone only needs the frames).
    private var analysisWanted = false
    private var analysisInterval = 1.0 / 6
    private var tracksBeams = false
    private var lastAnalysis: CFTimeInterval = 0
    private var lastFrame: CFTimeInterval = 0
    private var frameSize = (width: 0, height: 0)
    private var frames = 0, analyzed = 0, lastReport: CFTimeInterval = 0
    /// Follows light beams from frame to frame. Only used on `frameQueue`.
    private let tracker = BeamTracker()

    private override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVCaptureSessionRuntimeError, object: nil, queue: .main) { [weak self] note in
            guard let self, let session = note.object as? AVCaptureSession, session === self.session else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self.broke(error?.localizedDescription ?? "The camera stopped.")
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let gone = note.object as? AVCaptureDevice, gone === self.device, let config = self.config else { return }
            self.generation += 1
            self.closeSession()
            self.state = .missing(config.name)
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let config = self.config, !self.isCapturing, let device = note.object as? AVCaptureDevice,
                  device.hasMediaType(.video), device.uniqueID == config.uid || device.localizedName == config.name else { return }
            // Give it a moment to settle after plugging in.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.config == config, !self.isCapturing else { return }
                self.restart()
            }
        })
    }

    /// Who wants the camera, and which one; nil lets go. It runs while anyone wants it.
    func use(_ user: User, _ config: Config?) {
        users[user] = config
        lock.lock()
        keepFrames = users[.show] != nil
        analysisWanted = users[.colors] != nil
        if !keepFrames { newest = nil }
        lock.unlock()
        let wanted = users[.colors] ?? users[.show]
        if wanted != self.config {
            self.config = wanted
            restart()
        } else if wanted != nil, state == .off {
            restart()
        }
    }

    /// Whether to look for light beams, and how many frames a second to turn into colors.
    func configure(beams: Bool, frameRate: Int) {
        lock.lock()
        let changed = beams != tracksBeams
        tracksBeams = beams
        analysisInterval = 1 / Double(max(1, frameRate))
        lock.unlock()
        if changed { frameQueue.async { [tracker] in tracker.reset() } }
    }

    /// Tries again: after the camera permission changed, or "Try Again" in the panel.
    func retry() {
        guard config != nil else { return }
        restarts.removeAll()
        restart()
    }

    private func restart() {
        generation += 1
        let generation = self.generation
        closeSession()
        guard let config else {
            state = .off
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            // Only the Settings page (and `--picture`, for test runs) asks; a scene or link never puts up the prompt.
            state = .needsPermission
            if PictureChoice.isOverridden {
                AVCaptureDevice.requestAccess(for: .video) { _ in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, generation == self.generation else { return }
                        self.restart()
                    }
                }
            }
            return
        default:
            state = .denied
            return
        }
        state = .starting
        frameQueue.async { [tracker] in tracker.reset() }
        sessionQueue.async { [weak self] in self?.open(config, generation: generation) }
    }

    private func closeSession() {
        watchdog?.invalidate()
        watchdog = nil
        let old = session
        session = nil
        device = nil
        if let old { sessionQueue.async { old.stopRunning() } }
        lock.lock()
        newest = nil
        lastFrame = 0
        lock.unlock()
    }

    private struct Problem: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// On the session queue: starting a session takes a moment and must never hold up the app.
    private func open(_ config: Config, generation: Int) {
        guard let device = CameraList.device(id: config.uid, name: config.name) else {
            finishOpen(generation, nil, nil, .missing(config.name))
            return
        }
        let session = AVCaptureSession()
        session.beginConfiguration()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw Problem("\(config.name) can't be read right now.") }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: frameQueue)
            guard session.canAddOutput(output) else { throw Problem("\(config.name) can't be read right now.") }
            session.addOutput(output)
        } catch {
            session.commitConfiguration()
            finishOpen(generation, nil, nil, .failed(error.localizedDescription))
            return
        }
        session.commitConfiguration()
        session.startRunning()
        guard session.isRunning else {
            finishOpen(generation, nil, nil, .failed("\(config.name) didn't start."))
            return
        }
        finishOpen(generation, session, device, .capturing(config.name))
    }

    private func finishOpen(_ generation: Int, _ session: AVCaptureSession?, _ device: AVCaptureDevice?, _ state: State) {
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.generation else {
                // Stopped or changed meanwhile.
                if let session { self?.sessionQueue.async { session.stopRunning() } }
                return
            }
            self.session = session
            self.device = device
            self.state = state
            if session != nil { self.startWatchdog() }
        }
    }

    /// Looks every few seconds whether frames are still coming. A capture device whose source went away may send
    /// nothing; the session is then started again now and then, in case it helps.
    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.checkFrames() }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func checkFrames() {
        guard let config, session != nil else { return }
        lock.lock()
        let last = lastFrame
        let size = frameSize
        let count = frames, done = analyzed
        frames = 0
        analyzed = 0
        lock.unlock()
        let now = CACurrentMediaTime()
        if verbose, isCapturing {
            print("camera: \(config.name) \(size.width)x\(size.height), \(count) frames in 5 s, \(done) analyzed")
        }
        guard last > 0, now - last > 6 else {
            if case .waiting = state, last > 0 { state = .capturing(config.name) }
            return
        }
        if state == .capturing(config.name) { state = .waiting(config.name) }
        // A fresh start every 20 s or so while nothing comes in.
        if now - (restarts.last ?? 0) > 20 {
            restarts.append(now)
            restart()
            state = .waiting(config.name)
        }
    }

    /// The session reported a problem: start again, unless it keeps happening.
    private func broke(_ message: String) {
        guard let config else { return }
        let now = CACurrentMediaTime()
        restarts = restarts.filter { now - $0 < 60 } + [now]
        if verbose { print("camera: \(message) (\(restarts.count) restarts in a minute)") }
        guard restarts.count <= 4 else {
            generation += 1
            closeSession()
            state = .failed(message)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.config == config else { return }
            self.restart()
        }
    }

    // MARK: - Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = sampleBuffer.imageBuffer else { return }
        let now = CACurrentMediaTime()
        lock.lock()
        lastFrame = now
        frames += 1
        frameSize = (CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels))
        if keepFrames { newest = pixels }
        let due = analysisWanted && now - lastAnalysis >= analysisInterval - 0.004
        if due {
            lastAnalysis = now
            analyzed += 1
        }
        let beams = tracksBeams
        lock.unlock()
        guard due, CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        // Only every n-th pixel is read, so a 4K frame costs the same as a small screen frame.
        let result = ScreenAnalysis.analyze(base, width: width, height: height, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
                                            bgra: true, beams: beams ? tracker : nil,
                                            step: max(1, width / ScreenAnalysis.sampleWidth))
        DispatchQueue.main.async { [weak self] in self?.onFrame?(result) }
    }
}

/// Choosing a camera: explains what Barbeat reads before macOS asks for camera access.
enum CameraAccess {
    static func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }

    /// Explains, lets macOS ask, then calls `completion` on the main thread with whether the camera may be used.
    /// Without a prompt when the answer is already known.
    static func ask(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
            return
        case .notDetermined:
            break
        default:
            completion(false)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Let Barbeat use the camera?"
        alert.informativeText = """
            Barbeat can take its colors from a camera or capture device instead of the screen: a game console, Apple TV or Blu-ray player plugged into an HDMI capture device, a webcam, or your iPhone.

            It reads a few tiny samples of each frame, a few times a second, in memory, and throws them away: nothing is recorded, saved or sent. The camera light stays on while Barbeat watches it.

            Next, macOS asks you to allow Barbeat to use the camera.
            """
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            completion(false)
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { allowed in
            DispatchQueue.main.async { completion(allowed) }
        }
    }

    /// Switches the picture to a camera (`device`, or the one saved, or the best one plugged in), asking for camera
    /// access first when needed. Keeps the screen if the explainer is turned down.
    static func chooseCamera(_ settings: Settings, device: CameraDevice? = nil) {
        if let device {
            settings.cameraName = device.name
            settings.cameraUID = device.id
        } else if settings.cameraUID.isEmpty, let preferred = CameraList.shared.preferredDevice {
            settings.cameraName = preferred.name
            settings.cameraUID = preferred.id
        }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        ask { allowed in
            // Refused in System Settings earlier: switch anyway, so the status says what to do.
            if allowed || status != .notDetermined { settings.pictureSource = .camera }
        }
    }
}
