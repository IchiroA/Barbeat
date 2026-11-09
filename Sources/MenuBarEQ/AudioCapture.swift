import Foundation
import AppKit
import AVFoundation
import CoreAudio
import AudioToolbox
import Darwin

enum AudioTapError: LocalizedError {
    case coreAudio(String, OSStatus)
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case let .coreAudio(step, status): return "\(step) failed (error \(status))"
        case .unsupportedFormat: return "Unsupported audio format"
        }
    }
}

/// What to listen to. Names are only for display: two sources are equal when their IDs match.
enum CaptureSource: Equatable, CustomStringConvertible {
    case system
    /// One app's sound, including its helper processes. An empty ID means no app is picked yet.
    case app(bundleID: String, name: String)
    /// A microphone or other input device, by Core Audio UID.
    case device(uid: String, name: String)

    static func == (a: CaptureSource, b: CaptureSource) -> Bool {
        switch (a, b) {
        case (.system, .system): return true
        case let (.app(x, _), .app(y, _)): return x == y
        case let (.device(x, _), .device(y, _)): return x == y
        default: return false
        }
    }

    var description: String {
        switch self {
        case .system: return "system audio"
        case let .app(id, _): return "app \(id.isEmpty ? "(none)" : id)"
        case let .device(uid, name): return "device \(name) [\(uid)]"
        }
    }
}

/// Captures system audio, one app, or an input device into `ring`.
///
/// System and app audio use a Core Audio process tap (macOS 14.2+) inside a private aggregate device; the tap is
/// unmuted, so sound keeps playing normally. Input devices are read directly and need microphone permission.
final class AudioCapture {
    enum Event {
        case started
        case stopped
        case failed(Error)
        /// The chosen app has no sound running yet (or no app is chosen). Capture starts when it does.
        case waitingForApp
        case askingForMicrophone
        case microphoneDenied
    }

    let ring = SampleRingBuffer(capacity: 1 << 15)
    private(set) var sampleRate: Double = 48_000
    /// True between start() and stop(), including while waiting for an app or for permission.
    private(set) var isRunning = false
    /// True while sound is actually being read from a tap or device.
    private(set) var isCapturing = false
    /// True while the chosen input device is missing and system audio is captured instead.
    private(set) var usingFallback = false

    var source: CaptureSource = .system {
        didSet { if source != oldValue { restartIfRunning(after: 0.05) } }
    }

    /// Called on the main queue.
    var onEvent: ((Event) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    /// The device the IO proc runs on: the aggregate (taps) or the input device itself.
    private var ioDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tappedProcesses: Set<AudioObjectID> = []
    private let ioQueue = DispatchQueue(label: "MenuBarEQ.audio", qos: .userInteractive)
    private var listeners: [HAL.Listener] = []
    private var deviceListeners: [HAL.Listener] = []
    private var wakeObserver: NSObjectProtocol?
    private var pendingRestart: DispatchWorkItem?

    init() {
        listeners = [
            // Taps are clocked by the output device, so rebuild them when it changes (e.g. headphones plugged in).
            HAL.listen(HAL.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
                guard let self, self.aggregateID != kAudioObjectUnknown else { return }
                self.restartIfRunning()
            },
            HAL.listen(HAL.system, kAudioHardwarePropertyProcessObjectList) { [weak self] in self?.processesChanged() },
            HAL.listen(HAL.system, kAudioHardwarePropertyDevices) { [weak self] in self?.devicesChanged() },
        ]
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.restartIfRunning() }
    }

    deinit {
        stop()
        listeners.forEach { $0.cancel() }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        begin()
    }

    func stop() {
        guard isRunning else { return }
        pendingRestart?.cancel()
        teardown()
        isRunning = false
        usingFallback = false
        onEvent?(.stopped)
    }

    private func restartIfRunning(after delay: Double = 0.5) {
        guard isRunning else { return }
        teardown()
        pendingRestart?.cancel()
        // Give Core Audio a moment to settle (new device, app launching, waking from sleep).
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.begin()
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func begin() {
        teardown()
        usingFallback = false
        do {
            switch source {
            case .system:
                try startTap(processes: nil)

            case let .app(bundleID, _):
                let processes = bundleID.isEmpty ? [] : HAL.processObjects(forApp: bundleID)
                tappedProcesses = Set(processes)
                if processes.isEmpty {
                    onEvent?(.waitingForApp)
                    return
                }
                try startTap(processes: processes)

            case let .device(uid, _):
                if let device = HAL.inputDevices().first(where: { $0.id == uid }) {
                    switch AVCaptureDevice.authorizationStatus(for: .audio) {
                    case .authorized:
                        try startDevice(device.objectID)
                    case .notDetermined:
                        onEvent?(.askingForMicrophone)
                        AVCaptureDevice.requestAccess(for: .audio) { _ in
                            DispatchQueue.main.async { [weak self] in self?.restartIfRunning(after: 0) }
                        }
                        return
                    default:
                        onEvent?(.microphoneDenied)
                        return
                    }
                } else {
                    // Unplugged: listen to system audio until it comes back.
                    usingFallback = true
                    try startTap(processes: nil)
                }
            }
            isCapturing = true
            onEvent?(.started)
        } catch {
            teardown()
            onEvent?(.failed(error))
        }
    }

    private func processesChanged() {
        guard isRunning, case let .app(bundleID, _) = source, !bundleID.isEmpty else { return }
        // Restart when the app (or one of its helpers) starts or stops using audio.
        if Set(HAL.processObjects(forApp: bundleID)) != tappedProcesses {
            restartIfRunning(after: 0.3)
        }
    }

    private func devicesChanged() {
        guard isRunning, case let .device(uid, _) = source else { return }
        let present = HAL.inputDevices().contains { $0.id == uid }
        // Switch to system audio when the device goes away, and back when it returns.
        if present == usingFallback { restartIfRunning() }
    }

    // MARK: - Core Audio plumbing

    /// A tap of every process (`processes` nil) or just the given ones, inside a private aggregate device.
    private func startTap(processes: [AudioObjectID]?) throws {
        let description = processes.map { CATapDescription(stereoMixdownOfProcesses: $0) }
            ?? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Barbeat"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &newTap), "Creating audio tap")
        tapID = newTap

        guard let format = HAL.value(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()) else {
            throw AudioTapError.coreAudio("Reading tap format", -1)
        }
        guard Self.isFloat32(format) else { throw AudioTapError.unsupportedFormat }
        sampleRate = format.mSampleRate

        // Clocked by the current output device.
        let outputUID = try Self.defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Barbeat Tap",
            kAudioAggregateDeviceUIDKey: "com.ia.MenuBarEQ.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregate), "Creating aggregate device")
        aggregateID = newAggregate

        try startIO(on: aggregateID)
    }

    /// Reads a microphone or other input device directly.
    private func startDevice(_ device: AudioObjectID) throws {
        let streams = HAL.objectList(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        if let stream = streams.first,
           let format = HAL.value(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription()),
           !Self.isFloat32(format) {
            throw AudioTapError.unsupportedFormat
        }
        let rate = HAL.value(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) ?? 0
        sampleRate = rate > 0 ? rate : 48_000

        deviceListeners = [
            // Bluetooth headsets change rate when their mic turns on. Follow it rather than restarting,
            // which would flip the headset back and forth.
            HAL.listen(device, kAudioDevicePropertyNominalSampleRate) { [weak self] in
                if let rate = HAL.value(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)), rate > 0 {
                    self?.sampleRate = rate
                }
            },
            HAL.listen(device, kAudioDevicePropertyDeviceIsAlive) { [weak self] in self?.restartIfRunning() },
        ]
        try startIO(on: device)
    }

    private func startIO(on device: AudioObjectID) throws {
        // Keep this block tiny: it just copies samples into the ring buffer.
        let ring = self.ring
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, device, ioQueue) { _, inputData, _, _, _ in
            ring.write(inputData)
        }, "Creating audio callback")
        ioDeviceID = device
        try check(AudioDeviceStart(device, procID), "Starting audio capture")
    }

    private func teardown() {
        if ioDeviceID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(ioDeviceID, procID)
            AudioDeviceDestroyIOProcID(ioDeviceID, procID)
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        ioDeviceID = AudioObjectID(kAudioObjectUnknown)
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        deviceListeners.forEach { $0.cancel() }
        deviceListeners = []
        tappedProcesses = []
        isCapturing = false
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw AudioTapError.coreAudio(step, status) }
    }

    private static func isFloat32(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
    }

    private static func defaultOutputDeviceUID() throws -> String {
        guard let device = HAL.value(HAL.system, kAudioHardwarePropertyDefaultOutputDevice,
                                     initial: AudioObjectID(kAudioObjectUnknown)),
              device != kAudioObjectUnknown else {
            throw AudioTapError.coreAudio("Finding output device", -1)
        }
        guard let uid = HAL.string(device, kAudioDevicePropertyDeviceUID) else {
            throw AudioTapError.coreAudio("Reading output device", -1)
        }
        return uid
    }
}

// MARK: - Core Audio helpers

struct InputDevice: Identifiable, Equatable {
    /// Core Audio UID, stable across launches.
    let id: String
    let objectID: AudioObjectID
    let name: String
    let transport: UInt32

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
}

struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let path: String
    let isPlaying: Bool
    /// Recording from an input (a mic): a call, a voice memo, dictation.
    var isRecording = false
}

/// Small typed wrappers around the Core Audio property API.
enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> T? {
        var address = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    /// Every device with at least one input stream, except Barbeat's own tap devices.
    static func inputDevices() -> [InputDevice] {
        objectList(system, kAudioHardwarePropertyDevices).compactMap { id in
            guard !objectList(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).isEmpty,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.hasPrefix("com.ia.MenuBarEQ"),
                  let name = string(id, kAudioObjectPropertyName), !name.hasPrefix("CADefaultDeviceAggregate")
            else { return nil }
            let transport = value(id, kAudioDevicePropertyTransportType, initial: UInt32(0)) ?? 0
            return InputDevice(id: uid, objectID: id, name: name, transport: transport)
        }
    }

    /// A real input (a mic, a headset, an audio interface) is in use by some app: a call, usually. Barbeat's own
    /// capture devices, aggregate and virtual devices don't count (screen recorders and loopback tools use those),
    /// and neither does `except`, the input Barbeat itself listens to.
    static func microphoneInUse(except uid: String?) -> Bool {
        inputDevices().contains { device in
            device.id != uid
                && device.transport != kAudioDeviceTransportTypeAggregate
                && device.transport != kAudioDeviceTransportTypeVirtual
                && (value(device.objectID, kAudioDevicePropertyDeviceIsRunningSomewhere, initial: UInt32(0)) ?? 0) != 0
        }
    }

    /// Every process Core Audio knows about (anything that has opened audio).
    static func audioProcesses() -> [AudioProcess] {
        objectList(system, kAudioHardwarePropertyProcessObjectList).map { id in
            let pid = value(id, kAudioProcessPropertyPID, initial: pid_t(-1)) ?? -1
            return AudioProcess(
                objectID: id,
                pid: pid,
                bundleID: string(id, kAudioProcessPropertyBundleID) ?? "",
                path: executablePath(pid),
                isPlaying: (value(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0,
                isRecording: (value(id, kAudioProcessPropertyIsRunningInput, initial: UInt32(0)) ?? 0) != 0)
        }
    }

    /// The audio processes that belong to an app, for its tap.
    static func processObjects(forApp bundleID: String) -> [AudioObjectID] {
        let path = appPath(bundleID)
        return audioProcesses().filter { process($0, belongsTo: bundleID, appPath: path) }.map(\.objectID)
    }

    static func appPath(_ bundleID: String) -> String? {
        (NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID))?.path
    }

    /// Whether an audio process is the app itself or works for it: helpers inside its bundle
    /// (Chrome, Spotify, Electron apps) or, for Safari, WebKit's shared media process.
    static func process(_ p: AudioProcess, belongsTo bundleID: String, appPath: String?) -> Bool {
        if p.bundleID == bundleID || p.bundleID.hasPrefix(bundleID + ".") { return true }
        if let appPath, !p.path.isEmpty, p.path.hasPrefix(appPath + "/") { return true }
        if bundleID.hasPrefix("com.apple.Safari"), p.bundleID.hasPrefix("com.apple.WebKit.GPU") { return true }
        return false
    }

    private static func executablePath(_ pid: pid_t) -> String {
        guard pid > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : ""
    }

    /// A property listener that's removed by `cancel()` (or when released).
    final class Listener {
        private var remove: (() -> Void)?
        init(remove: @escaping () -> Void) { self.remove = remove }
        func cancel() {
            remove?()
            remove = nil
        }
        deinit { cancel() }
    }

    static func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       _ handler: @escaping () -> Void) -> Listener {
        var address = address(selector, scope)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(object, &address, .main, block)
        return Listener {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
    }
}

/// The apps and input devices the settings panel offers under "Listen to".
final class AudioSourceList: ObservableObject {
    static let shared = AudioSourceList()

    struct App: Identifiable, Equatable {
        let id: String
        let name: String
        let isPlaying: Bool
        let icon: NSImage?

        static func == (a: App, b: App) -> Bool { a.id == b.id && a.name == b.name && a.isPlaying == b.isPlaying }
    }

    @Published private(set) var apps: [App] = []
    @Published private(set) var devices: [InputDevice] = []

    private var deviceListener: HAL.Listener?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var icons: [String: NSImage] = [:]

    private init() {
        deviceListener = HAL.listen(HAL.system, kAudioHardwarePropertyDevices) { [weak self] in self?.refreshDevices() }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshApps()
            }))
        }
        // The settings panel becomes key when it opens: a good moment to see who's playing.
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }))
        refresh()
    }

    func refresh() {
        refreshApps()
        refreshDevices()
    }

    func refreshDevices() {
        let now = HAL.inputDevices()
        if now != devices { devices = now }
    }

    func refreshApps() {
        let processes = HAL.audioProcesses().filter(\.isPlaying)
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var list: [App] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != own,
                  seen.insert(id).inserted else { return nil }
            let path = app.bundleURL?.path
            return App(id: id, name: app.localizedName ?? id,
                       isPlaying: processes.contains { HAL.process($0, belongsTo: id, appPath: path) },
                       icon: icon(for: app))
        }
        list.sort { a, b in
            if a.isPlaying != b.isPlaying { return a.isPlaying }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        if list != apps { apps = list }
    }

    /// The device to pick when "Input" is first chosen: the built-in mic, else anything that isn't Bluetooth
    /// (a Bluetooth mic switches the headset into low-quality call mode).
    var preferredDevice: InputDevice? {
        devices.first(where: \.isBuiltIn) ?? devices.first { !$0.isBluetooth } ?? devices.first
    }

    private func icon(for app: NSRunningApplication) -> NSImage? {
        guard let id = app.bundleIdentifier else { return nil }
        if let cached = icons[id] { return cached }
        guard let image = app.icon?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 16, height: 16)
        icons[id] = image
        return image
    }

    deinit {
        observers.forEach { $0.0.removeObserver($0.1) }
    }
}
