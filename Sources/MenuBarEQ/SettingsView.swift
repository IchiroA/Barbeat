import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var status: AudioStatus
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var contentHeight: CGFloat = 700

    var body: some View {
        // Scrolls only when the panel is taller than the screen (small displays, the custom color editor open).
        ScrollView(.vertical) {
            panel.background(GeometryReader { geo in
                Color.clear.preference(key: PanelHeightKey.self, value: geo.size.height)
            })
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 320, height: min(contentHeight, maxPanelHeight))
        .onPreferenceChange(PanelHeightKey.self) { contentHeight = $0 }
    }

    private var maxPanelHeight: CGFloat {
        let screen = NSScreen.main ?? NSScreen.screens.first
        return max(360, (screen?.visibleFrame.height ?? 800) - 24)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(.tint)
                Text("Barbeat")
                    .font(.headline)
                Spacer()
                Toggle("Enabled", isOn: $settings.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }

            StatusLine(status: status)

            LightsRow(settings: .shared, hub: .shared)

            Divider()

            Group {
                labeled("Listen to") {
                    SourcePicker(settings: settings, list: .shared)
                }

                labeled("Style") {
                    VStack(alignment: .leading, spacing: 8) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                            ForEach(EQStyle.allCases) { style in
                                StyleTile(style: style, selected: settings.style == style) {
                                    settings.style = style
                                }
                            }
                        }
                        Text(settings.style.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                labeled("Layout") {
                    Picker("Layout", selection: $settings.layout) {
                        ForEach(EQLayout.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(!settings.style.supportsLayout)
                    if settings.layout == .stereo || !settings.style.supportsLayout {
                        Text("Left channel left of the notch, right channel to the right.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                labeled("Colors · \(settings.palette.title)", accessory: {
                    if settings.palette != .custom {
                        Button("Customize") { settings.customizeCurrentPalette() }
                            .buttonStyle(.link)
                            .font(.caption)
                            .help("Copy these colors into Custom so you can change them")
                    }
                }) {
                    HStack(spacing: 6) {
                        ForEach(Palette.allCases) { palette in
                            Button { settings.palette = palette } label: {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(palette == .custom ? settings.customGradient.swatch : palette.swatch)
                                    .frame(width: 22, height: 22)
                                    .overlay {
                                        if let symbol = palette.badge {
                                            Image(systemName: symbol)
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(.white)
                                                .shadow(color: .black.opacity(0.5), radius: 1)
                                        }
                                    }
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7)
                                            .strokeBorder(Color.primary.opacity(settings.palette == palette ? 0.9 : 0), lineWidth: 2)
                                            .padding(-4)
                                    )
                            }
                            .buttonStyle(.plain)
                            .help(palette.help)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
                    if settings.palette == .custom {
                        CustomGradientEditor(settings: settings)
                    }
                    if settings.palette == .screen {
                        ScreenColorOptions(settings: settings, screen: .shared)
                    }
                }

                labeled("Color drift") {
                    Picker("Color drift", selection: $settings.colorDrift) {
                        ForEach(ColorDrift.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(settings.palette == .screen)
                    .help(settings.palette == .screen ? "Screen colors follow the screen, so they don't drift"
                                                      : "Slowly turns the colors around the color wheel while music plays")
                }

                labeled("Bands") {
                    Picker("Bands", selection: $settings.bandCount) {
                        ForEach(Settings.bandChoices, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(!settings.style.usesBands)
                }

                labeled("Opacity · \(Int((settings.opacity * 100).rounded()))%") {
                    Slider(value: $settings.opacity, in: 0.15...1)
                }

                labeled("Sensitivity · \(sensitivityText)") {
                    Slider(value: $settings.sensitivity, in: -12...12, step: 1)
                }

                VStack(alignment: .leading, spacing: 10) {
                    labeled("Brightness · \(Int((settings.brightness * 100).rounded()))%") {
                        Slider(value: $settings.brightness, in: 0.3...2)
                    }
                    labeled("Low · Mid · High") {
                        VStack(spacing: 2) {
                            gainRow("Low", $settings.lowGain)
                            gainRow("Mid", $settings.midGain)
                            gainRow("High", $settings.highGain)
                        }
                    }
                    if settings.style == .sparks {
                        labeled("Spark power · \(Int((settings.sparkPower * 100).rounded()))%") {
                            Slider(value: $settings.sparkPower, in: 0...1)
                        }
                    }
                    Button("Reset Tuning") { settings.resetTuning() }
                        .controlSize(.small)
                }
            }
            .disabled(!settings.enabled)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Auto level", isOn: $settings.autoLevel)
                    .help("Adjusts to the loudness of what's playing so the bars always fill the menu bar.")
                Toggle("Peak hold", isOn: $settings.showPeaks)
                    .disabled(!settings.style.usesPeaks)
                Toggle("Keep menu bar text readable", isOn: $settings.readableMenuBar)
                    .help("Tones down bar colors bright enough to wash out the menu bar's text and icons (white bars behind white text). Only the menu bar changes; the edge glow keeps its full colors.")
                Toggle("Screen edge glow", isOn: $settings.edgeGlow)
                    .help("A soft glow along the edges of the screen.")
                if settings.edgeGlow {
                    HStack(spacing: 8) {
                        Text("Depth")
                            .font(.caption)
                        Slider(value: $settings.edgeGlowDepth, in: Settings.edgeGlowDepthRange)
                            .help("How far the glow reaches into the screen.")
                        Text("\(Int(settings.edgeGlowDepth.rounded())) pt")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                    .padding(.leading, 20)
                    Toggle("Top edge too, below the menu bar", isOn: $settings.edgeGlowTop)
                        .help("Also glows along the top of the screen, fading down from the menu bar.")
                        .padding(.leading, 20)
                }
                Toggle("Show on all displays", isOn: $settings.allDisplays)
                Toggle("Show over full-screen apps", isOn: $settings.showInFullScreen)
                    .help("Keeps the screen edge glow on over apps in full screen.")
                if settings.showInFullScreen {
                    Toggle("Menu bar visuals too", isOn: $settings.fullScreenStrip)
                        .help("In full screen, also draws the bars along the top, where the hidden menu bar would be. They step aside while you use the menu bar. Off: just the edge glow, on all sides.")
                        .padding(.leading, 20)
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enable in setLaunchAtLogin(enable) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            Divider()

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Quit Barbeat") { NSApp.terminate(nil) }
                    HStack(spacing: 12) {
                        Link("Help", destination: Credits.helpURL)
                            .help("Opens Barbeat's guide in your browser")
                        Link("♥ Support", destination: Credits.supportURL)
                            .help("Ways to support Barbeat")
                    }
                    .font(.caption)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Made by \(Credits.author)")
                    Text("\(Credits.handle) · v\(Credits.version)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var sensitivityText: String { dbText(settings.sensitivity) }

    private func dbText(_ value: Double) -> String {
        let db = Int(value.rounded())
        return db == 0 ? "0 dB" : String(format: "%+d dB", db)
    }

    private func gainRow(_ name: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.caption)
                .frame(width: 30, alignment: .leading)
            Slider(value: value, in: -12...12, step: 1)
            Text(dbText(value.wrappedValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        labeled(title, accessory: { EmptyView() }, content: content)
    }

    private func labeled<Content: View, Accessory: View>(
        _ title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                accessory()
            }
            content()
        }
    }

    private func setLaunchAtLogin(_ enable: Bool) {
        do {
            if enable { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct StyleTile: View {
    let style: EQStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: style.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(height: 18)
                Text(style.title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.8) : .clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(style.subtitle)
    }
}

/// Who made Barbeat, shown at the bottom of the panel.
enum Credits {
    static let author = "Ichiro Ashihara"
    static let handle = "@IchiroA"
    /// The guide (GitHub Pages, from the repository's docs folder) and its support section.
    static let helpURL = URL(string: "https://ichiroa.github.io/Barbeat/")!
    static let supportURL = URL(string: "https://ichiroa.github.io/Barbeat/#support")!
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
}

private extension Palette {
    /// A symbol drawn on the swatch for palettes that aren't fixed colors.
    var badge: String? {
        switch self {
        case .custom: return "paintbrush.pointed.fill"
        case .screen: return "display"
        default: return nil
        }
    }

    var help: String {
        switch self {
        case .custom: return "Custom: your own four colors"
        case .screen: return "Screen: colors from what's on screen"
        default: return title
        }
    }
}

/// The Screen palette's options, and what it's looking at.
private struct ScreenColorOptions: View {
    @ObservedObject var settings: Settings
    @ObservedObject var screen: ScreenColors

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Screen colors", selection: $settings.screenColorMode) {
                ForEach(ScreenColorMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            caption(settings.screenColorMode.subtitle)
            Toggle("Follow light beams", isOn: $settings.screenBeams)
                .toggleStyle(.checkbox)
                .padding(.top, 2)
                .help("Bright light that sweeps across the picture, like stage beams and flashes, takes over the colors as it passes.")
            if settings.screenBeams {
                HStack(spacing: 8) {
                    Text("Strength")
                        .font(.caption)
                    Slider(value: $settings.screenBeamStrength, in: Settings.screenBeamStrengthRange)
                        .help("How much of the glow a beam takes over, and how bright it gets.")
                    Text("\(Int((settings.screenBeamStrength * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
                .padding(.leading, 20)
                caption(settings.screenColorMode == .ambient
                        ? "Stage beams and flashes that sweep across the picture spill out of the screen in their own color."
                        : "Stage beams and flashes that sweep across the picture tint the colors as they pass.")
                    .padding(.leading, 20)
            }
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                Text(title).font(.caption)
            }
            .padding(.top, 2)
            if let detail { caption(detail) }
            if showsButtons {
                HStack {
                    if screen.state == .needsPermission {
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                    }
                    Button(screen.state == .stoppedByUser ? "Start Again" : "Try Again") { screen.retry() }
                }
                .controlSize(.small)
            }
        }
        .padding(.top, 4)
    }

    private var title: String {
        switch screen.state {
        case .off, .starting: return "Starting…"
        case .needsPermission: return "Barbeat needs permission to see the screen"
        case .watchingScreen: return "Watching the whole screen"
        case .watchingWindow(let name): return name.isEmpty ? "Watching the app's window" : "Watching \(name)'s window"
        case .dark: return "The screen looks black"
        case .stoppedByUser: return "Stopped from the menu bar"
        case .failed: return "Couldn't watch the screen"
        case .testImage: return "Using a test picture"
        }
    }

    private var detail: String? {
        let privacy = "Frames are read live and never saved. macOS shows a recording icon in the menu bar while this is on."
        switch screen.state {
        case .needsPermission:
            return "Allow Barbeat under Privacy & Security › Screen & System Audio Recording, then click Try Again. macOS may ask to reopen Barbeat."
        case .watchingScreen:
            if settings.audioSource == .app, !settings.sourceAppName.isEmpty {
                return "\(settings.sourceAppName) has no window showing, so Barbeat watches the whole screen. " + privacy
            }
            return privacy
        case .watchingWindow:
            return "Only this window, because it's what you're listening to. " + privacy
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

    private var showsButtons: Bool {
        switch screen.state {
        case .needsPermission, .stoppedByUser, .failed: return true
        default: return false
        }
    }

    private var dotColor: Color {
        switch screen.state {
        case .watchingScreen, .watchingWindow, .testImage: return .green
        case .off, .starting, .dark, .stoppedByUser: return .yellow
        case .needsPermission, .failed: return .red
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// System audio, one app, or an input device.
private struct SourcePicker: View {
    @ObservedObject var settings: Settings
    @ObservedObject var list: AudioSourceList

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Listen to", selection: kind) {
                ForEach(AudioSourceKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch settings.audioSource {
            case .system:
                caption("Everything your Mac plays.")
            case .app:
                Picker("App", selection: app) {
                    if settings.sourceAppID.isEmpty {
                        Text("Choose an app…").tag("")
                    } else if !list.apps.contains(where: { $0.id == settings.sourceAppID }) {
                        Text("\(settings.sourceAppName) (not open)").tag(settings.sourceAppID)
                    }
                    ForEach(list.apps) { app in
                        Label {
                            Text(app.isPlaying ? "\(app.name)  ♪" : app.name)
                        } icon: {
                            if let icon = app.icon { Image(nsImage: icon) }
                        }
                        .tag(app.id)
                    }
                }
                .labelsHidden()
                caption("Only this app moves the bars, so calls, alerts and other apps don't. ♪ marks apps playing sound right now.")
            case .device:
                Picker("Input", selection: device) {
                    if settings.sourceDeviceUID.isEmpty {
                        Text("Choose an input…").tag("")
                    } else if selectedDevice == nil {
                        Text("\(settings.sourceDeviceName) (not connected)").tag(settings.sourceDeviceUID)
                    }
                    ForEach(list.devices) { device in
                        Text(device.isBluetooth ? "\(device.name) (Bluetooth)" : device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                if selectedDevice?.isBluetooth == true {
                    Label("Using a Bluetooth headset's mic switches it to call mode, which makes what you hear sound worse.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                caption("Reacts to live sound: a mic, an audio interface, or a loopback device. macOS shows an orange dot in the menu bar while a mic is in use.")
            }
        }
    }

    private var selectedDevice: InputDevice? { list.devices.first { $0.id == settings.sourceDeviceUID } }

    private var kind: Binding<AudioSourceKind> {
        Binding(get: { settings.audioSource }, set: { kind in
            list.refresh()
            // Pick something sensible the first time: an app that's playing, or the built-in mic.
            if kind == .app, settings.sourceAppID.isEmpty, let playing = list.apps.first(where: \.isPlaying) {
                settings.sourceAppName = playing.name
                settings.sourceAppID = playing.id
            }
            if kind == .device, settings.sourceDeviceUID.isEmpty, let preferred = list.preferredDevice {
                settings.sourceDeviceName = preferred.name
                settings.sourceDeviceUID = preferred.id
            }
            settings.audioSource = kind
        })
    }

    private var app: Binding<String> {
        Binding(get: { settings.sourceAppID }, set: { id in
            if let app = list.apps.first(where: { $0.id == id }) { settings.sourceAppName = app.name }
            settings.sourceAppID = id
        })
    }

    private var device: Binding<String> {
        Binding(get: { settings.sourceDeviceUID }, set: { uid in
            if let device = list.devices.first(where: { $0.id == uid }) { settings.sourceDeviceName = device.name }
            settings.sourceDeviceUID = uid
        })
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StatusLine: View {
    @ObservedObject var status: AudioStatus

    private var state: AudioStatus.State { status.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.callout)
            }
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsPrivacyButton {
                HStack {
                    Button("Open Privacy Settings") {
                        let pane = usesMicrophone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                    }
                    Button("Try Again") {
                        NotificationCenter.default.post(name: OverlayController.restartAudioNotification, object: nil)
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private var usesMicrophone: Bool { status.sourceKind == .device || state == .microphoneDenied }

    private var title: String {
        switch state {
        case .off: return "Off"
        case .starting: return "Starting…"
        case .listening: return "Listening to \(status.sourceName)"
        case .silent: return "Waiting for sound"
        case .demo: return "Demo mode"
        case .noMenuBar: return "No visible menu bar"
        case .failed: return "Couldn't capture audio"
        case .waitingForApp: return status.sourceName.isEmpty ? "Choose an app to listen to" : "Waiting for \(status.sourceName)"
        case .askingForMicrophone: return "Asking for microphone access…"
        case .microphoneDenied: return "Microphone access is off"
        }
    }

    private var detail: String? {
        if let missing = status.missingDevice, state == .listening || state == .silent || state == .starting {
            return "\(missing) isn't connected, so Barbeat listens to system audio until it's back."
        }
        switch state {
        case .silent:
            switch status.sourceKind {
            case .system:
                return "Play something. If music is playing and the bars stay still, allow Barbeat under Privacy & Security › Screen & System Audio Recording."
            case .app:
                return "Play something in \(status.sourceName). If it's playing and the bars stay still, allow Barbeat under Privacy & Security › Screen & System Audio Recording."
            case .device:
                return "Nothing heard from \(status.sourceName). Make some noise, or check that Barbeat is allowed under Privacy & Security › Microphone."
            }
        case .waitingForApp:
            return status.sourceName.isEmpty ? "Pick one under Listen to." : "The bars move when \(status.sourceName) plays sound."
        case .microphoneDenied:
            return "Allow Barbeat under Privacy & Security › Microphone, then click Try Again."
        case .noMenuBar:
            return "The menu bar is set to hide automatically, so there's nothing to draw behind."
        case .failed(let message):
            return message
        default:
            return nil
        }
    }

    private var showsPrivacyButton: Bool {
        switch state {
        case .silent, .failed, .microphoneDenied: return true
        default: return false
        }
    }

    private var color: Color {
        switch state {
        case .listening, .demo: return .green
        case .starting, .silent, .waitingForApp, .askingForMicrophone: return .yellow
        case .off, .noMenuBar: return .gray
        case .failed, .microphoneDenied: return .red
        }
    }
}
