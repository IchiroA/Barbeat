import SwiftUI

/// The menu bar panel: quick controls. Everything else is in the Settings window.
struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var status: AudioStatus
    @State private var contentHeight: CGFloat = 600

    var body: some View {
        // Scrolls only when the panel is taller than the screen (small displays).
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

            ScreenColorsCard(settings: settings, screen: .shared)
            SceneRow(store: .shared)

            Group {
                labeled("Style") {
                    VStack(alignment: .leading, spacing: 6) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                            ForEach(EQStyle.allCases) { style in
                                StyleTile(style: style, selected: settings.style == style, compact: true) {
                                    settings.style = style
                                }
                            }
                        }
                        Text(settings.style.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !settings.screenColors {
                    labeled("Colors · \(settings.palette.title)") {
                        HStack(spacing: 6) {
                            ForEach(Palette.allCases.filter { $0 != .screen }) { palette in
                                Button { settings.palette = palette } label: {
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(palette == .custom ? settings.customGradient.swatch : palette.swatch)
                                        .frame(width: 21, height: 21)
                                        .overlay {
                                            if let symbol = palette.badge {
                                                Image(systemName: symbol)
                                                    .font(.system(size: 9, weight: .semibold))
                                                    .foregroundStyle(.white)
                                                    .shadow(color: .black.opacity(0.5), radius: 1)
                                            }
                                        }
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 7)
                                                .strokeBorder(Color.primary.opacity(settings.palette == palette ? 0.9 : 0), lineWidth: 2)
                                                .padding(-3)
                                        )
                                }
                                .buttonStyle(.plain)
                                .help(palette.help)
                            }
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 3)
                    }
                }

                labeled("Brightness · \(Int((settings.brightness * 100).rounded()))%") {
                    Slider(value: $settings.brightness, in: 0.3...2)
                }
            }
            .disabled(!settings.enabled)

            LightsRow(settings: .shared, hub: .shared)
            VoiceRow(settings: .shared)

            Divider()

            HStack {
                Button("Settings…") { SettingsWindow.show() }
                    .keyboardShortcut(",", modifiers: .command)
                    .help("Every setting: Screen colors, look, sound, glow, lights, voice and more")
                Spacer()
                HStack(spacing: 10) {
                    Link("Help", destination: Credits.helpURL)
                        .help("Opens Barbeat's guide in your browser")
                    Link("♥ Support", destination: Credits.supportURL)
                        .help("Ways to support Barbeat")
                }
                .font(.caption)
                Button("Quit") { NSApp.terminate(nil) }
            }

            Text("Made by \(Credits.author) · \(Credits.handle) · v\(Credits.version)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(16)
        .frame(width: 320)
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            content()
        }
    }
}

struct StyleTile: View {
    let style: EQStyle
    let selected: Bool
    var compact = false
    /// Settings › Look: a picture of the style in the menu bar instead of its symbol.
    var picture = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: compact ? 3 : 4) {
                if picture {
                    BundledImage(name: "style-\(style.rawValue)")
                        .aspectRatio(400.0 / 72.6, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(.horizontal, 6)
                } else {
                    Image(systemName: style.symbol)
                        .font(.system(size: compact ? 13 : 15, weight: .semibold))
                        .frame(height: compact ? 15 : 18)
                }
                Text(style.title)
                    .font(compact ? .system(size: 9.5) : .caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, compact ? 6 : 8)
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

extension Palette {
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

private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// System audio, one app, or an input device.
struct SourcePicker: View {
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

struct StatusLine: View {
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

/// "Check for Updates…" in the panel footer; says what it's doing while busy.
struct UpdateLink: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Group {
            switch updater.state {
            case .checking: Text("Checking for updates…")
            case .downloading: Text("Downloading the update…")
            case .installing: Text("Installing…")
            case .idle, .failed:
                Button("Check for Updates…") { updater.check(manual: true) }
                    .buttonStyle(.link)
                    .help("Looks for a newer Barbeat on GitHub")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
