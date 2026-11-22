// Barbeat · Ichiro Ashihara (@IchiroA) · MIT License
import SwiftUI
import AppKit
import AVFoundation

/// Turning Screen colors on. The first time, before macOS asks for Screen Recording, Barbeat says what it reads.
enum ScreenColorsAccess {
    static func turnOn(_ settings: Settings = .shared) {
        if CGPreflightScreenCaptureAccess() {
            settings.screenColors = true
            return
        }
        let alert = NSAlert()
        alert.messageText = "Let Barbeat see your screen's colors?"
        alert.informativeText = """
            Screen colors matches the menu bar, the edge glow and your lights to what you're watching, like a TV's backlight.

            To do that, Barbeat looks at tiny frames of your screen (192 pixels wide, a few a second). Each one is analyzed in memory and thrown away: nothing is recorded, saved or sent.

            Next, macOS asks you to allow Barbeat under Screen & System Audio Recording. While it's on, macOS shows a recording icon in the menu bar.
            """
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { settings.screenColors = true }
    }

    /// For a switch: on goes through `turnOn`, off just turns it off.
    static func binding(_ settings: Settings) -> Binding<Bool> {
        Binding(get: { settings.screenColors }, set: { on in
            if on { turnOn(settings) } else { settings.screenColors = false }
        })
    }

    static func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}

/// The colors Screen colors sees along the top of the main screen right now, as a strip.
struct ScreenColorsStrip: View {
    var segments = 24

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let colors = sampled
            HStack(spacing: 0) {
                if colors.isEmpty {
                    Rectangle().fill(Color.primary.opacity(0.08))
                } else {
                    ForEach(colors.indices, id: \.self) { i in Rectangle().fill(colors[i].color) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private var sampled: [RGB] {
        guard let top = ScreenColors.shared.colors(for: NSScreen.screens.first?.displayID)?.top, !top.isEmpty else { return [] }
        return (0..<segments).map { top[min(top.count - 1, $0 * top.count / segments)] }
    }
}

/// What Screen colors is doing: a dot, a line, and what to do about a problem.
struct ScreenColorsStatus: View {
    @ObservedObject var settings: Settings
    @ObservedObject var screen: ScreenColors
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                Text(title).font(.caption)
            }
            if !compact, let detail { caption(detail) }
            if showsButtons {
                HStack {
                    if screen.state == .needsPermission {
                        Button("Open Privacy Settings") { ScreenColorsAccess.openPrivacySettings() }
                    }
                    if screen.state == .needsCameraPermission {
                        Button("Allow Camera Access") { CameraAccess.ask { _ in screen.retry() } }
                    } else {
                        if screen.state == .cameraDenied {
                            Button("Open Privacy Settings") { CameraAccess.openPrivacySettings() }
                        }
                        Button(screen.state == .stoppedByUser ? "Start Again" : "Try Again") { screen.retry() }
                    }
                }
                .controlSize(.small)
            }
        }
    }

    /// Only worth showing in the panel when something needs attention.
    static func needsAttention(_ state: ScreenColors.State) -> Bool {
        switch state {
        case .needsPermission, .stoppedByUser, .failed, .needsCameraPermission, .cameraDenied, .waitingForCamera, .cameraFailed:
            return true
        default:
            return false
        }
    }

    private var title: String {
        switch screen.state {
        case .off, .starting: return "Starting…"
        case .needsPermission: return "Barbeat needs permission to see the screen"
        case .watchingScreen: return "Watching the whole screen"
        case .watchingWindow(let name): return name.isEmpty ? "Watching the app's window" : "Watching \(name)'s window"
        case .dark: return "The picture looks black"
        case .stoppedByUser: return "Stopped from the menu bar"
        case .failed: return "Couldn't watch the screen"
        case .testImage: return "Using a test picture"
        case .watchingCamera(let name): return "Watching \(name)"
        case .needsCameraPermission: return "Barbeat needs permission to use the camera"
        case .cameraDenied: return "Camera access is off"
        case .waitingForCamera(let name): return "Waiting for a picture from \(name)"
        case .cameraFailed: return "Couldn't read the camera"
        }
    }

    private var detail: String? {
        let privacy = "Frames are read live and never saved. macOS shows a recording icon in the menu bar while this is on."
        if let missing = screen.missingCamera, case .watchingScreen = screen.state {
            return "\(missing) isn't connected, so Barbeat watches the screen until it's back. " + privacy
        }
        switch screen.state {
        case .needsPermission:
            return "Allow Barbeat under Privacy & Security › Screen & System Audio Recording, then click Try Again. macOS may ask to reopen Barbeat."
        case .watchingScreen:
            if settings.audioSource == .app, !settings.sourceAppName.isEmpty {
                return "\(settings.sourceAppName) has no window showing, so Barbeat watches the whole screen. " + privacy
            }
            return privacy
        case .watchingCamera:
            return "The colors come from this device instead of the screen. Frames are read live and never saved; its camera light stays on while Barbeat watches it."
        case .needsCameraPermission:
            return "Click Allow Camera Access, then let macOS allow Barbeat."
        case .cameraDenied:
            return "Allow Barbeat under Privacy & Security › Camera, then click Try Again. Or watch the screen instead, under What it watches."
        case .waitingForCamera:
            return "Nothing is coming in. Check that the device is on and its source is playing (an HDMI capture device needs a signal)."
        case .cameraFailed(let message):
            return message
        case .watchingWindow:
            return "Only this window, because it's the app you're listening to. " + privacy
        case .dark:
            return "Copy-protected video (Netflix, Apple TV+, Disney+) shows up black, so the last colors stay."
        case .stoppedByUser:
            return "Screen colors are paused until you start them again."
        case .failed(let message):
            return message
        default:
            return nil
        }
    }

    private var showsButtons: Bool { Self.needsAttention(screen.state) }

    private var dotColor: Color {
        switch screen.state {
        case .watchingScreen, .watchingWindow, .testImage, .watchingCamera: return .green
        case .off, .starting, .dark, .stoppedByUser, .waitingForCamera: return .yellow
        case .needsPermission, .failed, .needsCameraPermission, .cameraDenied, .cameraFailed: return .red
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// The Screen colors card at the top of the menu bar panel.
struct ScreenColorsCard: View {
    @ObservedObject var settings: Settings
    @ObservedObject var screen: ScreenColors

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles.tv")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen colors").font(.callout.weight(.semibold))
                    Text(settings.screenColors ? summary : "Off")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button("More…") { SettingsWindow.show(.screen) }
                    .controlSize(.small)
                Toggle("Screen colors", isOn: ScreenColorsAccess.binding(settings))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
            if settings.screenColors {
                ScreenColorsStrip().frame(height: 10)
                if ScreenColorsStatus.needsAttention(screen.state) {
                    ScreenColorsStatus(settings: settings, screen: screen, compact: true)
                }
            } else {
                Text("The menu bar, edge glow and your lights take their colors from what you're watching, like a TV's backlight.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1.5))
    }

    private var summary: String {
        var text = settings.screenColorMode.title + (settings.screenBeams ? " · following light beams" : "")
        if settings.pictureSource == .camera { text += " · " + (settings.cameraName.isEmpty ? "camera" : settings.cameraName) }
        return text
    }
}

/// Settings › Screen colors › What it watches: the screen, or a camera or capture device.
struct PictureSourcePicker: View {
    @ObservedObject var settings: Settings
    @ObservedObject var cameras: CameraList
    @ObservedObject var inputs: AudioSourceList

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Picture", selection: source) {
                ForEach(PictureSource.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if settings.pictureSource == .camera {
                Picker("Camera", selection: camera) {
                    if settings.cameraUID.isEmpty {
                        Text("Choose a camera…").tag("")
                    } else if chosen == nil {
                        Text("\(settings.cameraName) (not connected)").tag(settings.cameraUID)
                    }
                    ForEach(cameras.devices) { device in
                        Text(device.isContinuity ? "\(device.name) (iPhone)" : device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 360, alignment: .leading)
                caption("An HDMI capture device (a game console, Apple TV or Blu-ray player plugged into your Mac), a webcam, a virtual camera, or your iPhone. The colors come from its picture instead of the screen; if it's unplugged, Barbeat watches the screen until it's back. macOS asks for camera access the first time.")
                if let audio = matchingInput, !(settings.audioSource == .device && settings.sourceDeviceUID == audio.id) {
                    HStack(spacing: 10) {
                        Button("Listen to Its Sound Too") {
                            settings.sourceDeviceName = audio.name
                            settings.sourceDeviceUID = audio.id
                            settings.audioSource = .device
                        }
                        .controlSize(.small)
                        caption("Its sound comes in as the input “\(audio.name)”, so the bars can move with it as well.")
                    }
                } else if settings.audioSource == .device, let audio = matchingInput, settings.sourceDeviceUID == audio.id {
                    caption("Barbeat listens to its sound too (“\(audio.name)”, under Sound › Listen to).")
                }
            } else {
                caption("What's on your screen, or only the window of the app you're listening to.")
            }
        }
        .onAppear { inputs.refreshDevices() }
    }

    private var chosen: CameraDevice? { cameras.devices.first { $0.id == settings.cameraUID } }

    /// The audio input with the same name as the camera (a capture device is usually both).
    private var matchingInput: InputDevice? {
        guard settings.pictureSource == .camera, !settings.cameraName.isEmpty else { return nil }
        return DeviceMatch.audioInput(for: settings.cameraName, among: inputs.devices)
    }

    private var source: Binding<PictureSource> {
        Binding(get: { settings.pictureSource }, set: { choice in
            switch choice {
            case .screen: settings.pictureSource = .screen
            case .camera: CameraAccess.chooseCamera(settings)
            }
        })
    }

    private var camera: Binding<String> {
        Binding(get: { settings.cameraUID }, set: { id in
            if let device = cameras.devices.first(where: { $0.id == id }) { settings.cameraName = device.name }
            settings.cameraUID = id
        })
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Settings › Screen colors: the feature, front and center.
struct ScreenColorsPage: View {
    @ObservedObject var settings: Settings
    @ObservedObject var screen: ScreenColors

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack(alignment: .bottomLeading) {
                BundledImage(name: "hero")
                    .frame(height: 190)
                    .frame(maxWidth: .infinity)
                    .clipped()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Make your Mac glow like your screen")
                        .font(.title2.weight(.bold))
                    Text("The menu bar, the edge glow and your lights take their colors from what you're watching.")
                        .font(.callout)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 6)
                .padding(16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screen colors").font(.headline)
                    Text(settings.screenColors ? "On" : "Off: Barbeat uses the colors you picked under Look.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Screen colors", isOn: ScreenColorsAccess.binding(settings))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if settings.screenColors {
                ScreenColorsStrip(segments: 48).frame(height: 14)
                ScreenColorsStatus(settings: settings, screen: screen)
            }

            SettingsSection("What it watches", caption: "Where the picture comes from. The kaleidoscope mirrors the same picture.") {
                PictureSourcePicker(settings: settings, cameras: .shared, inputs: .shared)
            }

            SettingsSection("How it colors") {
                HStack(alignment: .top, spacing: 10) {
                    modeCard(.ambient, symbol: "rectangle.inset.filled",
                             text: "Each spot of the menu bar, edge glow and lights matches the part of the screen right next to it. Like a TV's backlight.")
                    modeCard(.colors, symbol: "paintpalette",
                             text: "The screen's strongest colors become the palette and flow across the bars, like any other palette.")
                }
            }

            SettingsSection("Follow light beams",
                            caption: "Bright light that sweeps across the picture, like stage beams, lasers and flashes, takes over the glow as it passes, even when the music is quiet.") {
                Toggle("Follow light beams", isOn: $settings.screenBeams)
                    .toggleStyle(.checkbox)
                if settings.screenBeams {
                    SettingsSlider("Strength", value: $settings.screenBeamStrength, in: Settings.screenBeamStrengthRange,
                                   text: "\(Int((settings.screenBeamStrength * 100).rounded()))%")
                    Toggle("Flash your lights too", isOn: $settings.screenBeamsToLights)
                        .toggleStyle(.checkbox)
                        .help("Hue and WLED lights next to a beam light up in its color as it sweeps past, left to right like the screen. Never more than 3 big flashes a second.")
                    Text("Your Hue and WLED lights light up in the beam's color as it sweeps past them, left to right like the screen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
                HStack(spacing: 10) {
                    beamPicture("beam-before", caption: "A laser appears on screen…")
                    beamPicture("beam-after", caption: "…and the glow takes its color.")
                }
            }

            Text("Barbeat reads small frames of your screen (192 pixels wide, up to 15 a second), only the window of the app you're listening to, or a few pixels of each frame from the camera you chose. Each one is analyzed in memory and thrown away; nothing is recorded, saved or sent. Barbeat's own windows are left out.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func modeCard(_ mode: ScreenColorMode, symbol: String, text: String) -> some View {
        let chosen = settings.screenColorMode == mode
        return Button { settings.screenColorMode = mode } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                    Text(mode.title).font(.callout.weight(.semibold))
                    Spacer()
                    if chosen { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                }
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(chosen ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(chosen ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.12), lineWidth: chosen ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func beamPicture(_ name: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            BundledImage(name: name)
                .aspectRatio(1000.0 / 560.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A picture from the app's Resources (the help site's pictures, made smaller).
struct BundledImage: View {
    let name: String

    var body: some View {
        if let image = NSImage(named: name) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            Rectangle().fill(Color.primary.opacity(0.08))
        }
    }
}
