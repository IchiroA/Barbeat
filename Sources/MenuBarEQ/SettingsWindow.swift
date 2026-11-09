import SwiftUI
import AppKit
import ServiceManagement

/// The pages of the Settings window, in sidebar order.
enum SettingsPage: String, CaseIterable, Identifiable {
    case screen, scenes, look, sound, glow, lights, voice, general
    var id: String { rawValue }

    var title: String {
        switch self {
        case .screen: return "Screen colors"
        case .scenes: return "Scenes"
        case .look: return "Look"
        case .sound: return "Sound"
        case .glow: return "Glow and screens"
        case .lights: return "Lights"
        case .voice: return "Voice"
        case .general: return "General"
        }
    }

    var symbol: String {
        switch self {
        case .screen: return "sparkles.tv"
        case .scenes: return "theatermasks"
        case .look: return "paintpalette"
        case .sound: return "speaker.wave.2"
        case .glow: return "rectangle.dashed"
        case .lights: return "lightbulb.2"
        case .voice: return "music.mic"
        case .general: return "gearshape"
        }
    }

    /// One plain sentence at the top of the page.
    var intro: String {
        switch self {
        case .screen: return ""
        case .scenes: return "Save whole looks and switch with one click, or let Barbeat switch on its own when an app plays or you're on a call."
        case .look: return "How the visuals look: the style, the colors and how many bars."
        case .sound: return "What Barbeat listens to, and how strongly it reacts."
        case .glow: return "How bright the visuals are, the glow around the edges of the screen, and where they show."
        case .lights: return ""
        case .voice: return ""
        case .general: return "Starting up, updates, and help."
        }
    }
}

/// Which page the Settings window shows.
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var page: SettingsPage = .screen
}

enum SettingsWindow {
    private static var window: NSWindow?
    private static let delegate = Delegate()

    static func show(_ page: SettingsPage? = nil) {
        if let page { SettingsRouter.shared.page = page }
        if window == nil {
            let host = NSHostingController(rootView: SettingsWindowView(router: .shared, settings: .shared))
            let window = NSWindow(contentViewController: host)
            window.title = "Barbeat Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 820, height: 680))
            window.center()
            window.delegate = delegate
            self.window = window
        }
        isOpen = true
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The Lights preview and the Voice meter only update while their page is showing.
    private(set) static var isOpen = false {
        didSet { updateLiveViews() }
    }

    static func updateLiveViews() {
        let page = SettingsRouter.shared.page
        LightHub.shared.previewWanted = isOpen && page == .lights
        VoiceMonitor.shared.wanted = isOpen && page == .voice
    }

    private final class Delegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) { SettingsWindow.isOpen = false }
    }
}

struct SettingsWindowView: View {
    @ObservedObject var router: SettingsRouter
    @ObservedObject var settings: Settings
    /// False for offscreen snapshots, which can't measure a scroll view.
    var scrolls = true

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            Group {
                if scrolls {
                    ScrollView(.vertical) { page }
                } else {
                    page
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 720, minHeight: 520)
        .onChange(of: router.page) { _, _ in SettingsWindow.updateLiveViews() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPage.allCases) { page in
                Button { router.page = page } label: {
                    HStack(spacing: 8) {
                        Image(systemName: page.symbol)
                            .frame(width: 18)
                            .foregroundStyle(router.page == page ? Color.white : Color.accentColor)
                        Text(page.title)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .foregroundStyle(router.page == page ? Color.white : Color.primary)
                    .background(RoundedRectangle(cornerRadius: 6).fill(router.page == page ? Color.accentColor : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("Barbeat \(Credits.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .padding(10)
        .frame(width: 190)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.03))
    }

    @ViewBuilder
    private var page: some View {
        switch router.page {
        case .lights:
            LightsView(settings: .shared, hub: .shared, app: settings, scrolls: false)
                .frame(maxWidth: 640, alignment: .leading)
        case .voice:
            VoiceView(settings: .shared, monitor: .shared)
        default:
            VStack(alignment: .leading, spacing: 18) {
                if router.page != .screen {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(router.page.title).font(.title2.weight(.semibold))
                        Text(router.page.intro).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                switch router.page {
                case .screen: ScreenColorsPage(settings: settings, screen: .shared)
                case .scenes: ScenesPage(store: .shared, apps: .shared)
                case .look: LookPage(settings: settings)
                case .sound: SoundPage(settings: settings)
                case .glow: GlowPage(settings: settings)
                default: GeneralPage(updater: .shared)
                }
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
        }
    }
}

// MARK: - Building blocks

/// A titled group of settings, with an optional sentence about it.
struct SettingsSection<Content: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var content: Content

    init(_ title: String, caption: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.caption = caption
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A label, a slider and its value.
struct SettingsSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let text: String

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil, text: String) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.text = text
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 110, alignment: .leading)
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
            Text(text)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }
}

private func dbText(_ value: Double) -> String {
    let db = Int(value.rounded())
    return db == 0 ? "0 dB" : String(format: "%+d dB", db)
}

private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

// MARK: - Look

private struct LookPage: View {
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Style", caption: settings.style.subtitle) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                    ForEach(EQStyle.allCases) { style in
                        StyleTile(style: style, selected: settings.style == style, picture: true) { settings.style = style }
                    }
                }
                if settings.style == .sparks {
                    SettingsSlider("Spark power", value: $settings.sparkPower, in: 0...1, text: percent(settings.sparkPower))
                }
            }

            SettingsSection("Layout", caption: settings.layout == .stereo || !settings.style.supportsLayout
                            ? "Left channel left of the notch (or the middle), right channel to the right."
                            : "One spectrum across the whole menu bar, bass on the left.") {
                Picker("Layout", selection: $settings.layout) {
                    ForEach(EQLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(!settings.style.supportsLayout)
            }

            SettingsSection("Bars", caption: "More bands means thinner bars. On ultrawide screens Barbeat adds bars in between so they don't stretch.") {
                Picker("Bands", selection: $settings.bandCount) {
                    ForEach(Settings.bandChoices, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(!settings.style.usesBands)
                Toggle("Peak hold (little caps that float above the bars)", isOn: $settings.showPeaks)
                    .toggleStyle(.checkbox)
                    .disabled(!settings.style.usesPeaks)
            }

            SettingsSection("Colors · \(settings.palette.title)",
                            caption: settings.screenColors
                                ? "Screen colors is on, so these are used when you turn it off."
                                : "By frequency (bass to treble) or by height, depending on the palette.") {
                HStack(spacing: 8) {
                    ForEach(Palette.allCases.filter { $0 != .screen }) { palette in
                        Button { settings.palette = palette } label: {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(palette == .custom ? settings.customGradient.swatch : palette.swatch)
                                .frame(width: 30, height: 30)
                                .overlay {
                                    if let symbol = palette.badge {
                                        Image(systemName: symbol)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .shadow(color: .black.opacity(0.5), radius: 1)
                                    }
                                }
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.primary.opacity(settings.palette == palette ? 0.9 : 0), lineWidth: 2)
                                    .padding(-4))
                        }
                        .buttonStyle(.plain)
                        .help(palette.help)
                    }
                }
                .padding(4)
                HStack {
                    if settings.palette != .custom {
                        Button("Customize These Colors") { settings.customizeCurrentPalette() }
                            .help("Copy these colors into Custom so you can change them")
                    }
                    if settings.screenColors {
                        Button("Screen Colors…") { SettingsRouter.shared.page = .screen }
                    }
                }
                .controlSize(.small)
                if settings.palette == .custom {
                    CustomGradientEditor(settings: settings)
                        .frame(maxWidth: 320, alignment: .leading)
                }
            }

            SettingsSection("Color drift", caption: "Slowly turns the colors around the color wheel while music plays. Screen colors don't drift.") {
                Picker("Color drift", selection: $settings.colorDrift) {
                    ForEach(ColorDrift.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

// MARK: - Sound

private struct SoundPage: View {
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Listen to") {
                SourcePicker(settings: settings, list: .shared)
                    .frame(maxWidth: 420, alignment: .leading)
            }
            SettingsSection("Sensitivity", caption: "Raise it if the bars barely move, lower it if they stay at the top.") {
                SettingsSlider("Sensitivity", value: $settings.sensitivity, in: -12...12, step: 1, text: dbText(settings.sensitivity))
                Toggle("Auto level (adjusts to the loudness of what's playing)", isOn: $settings.autoLevel)
                    .toggleStyle(.checkbox)
            }
            SettingsSection("Low, mid and high", caption: "Boost or cut parts of the sound in the visuals, for example less bass so the treble shows more.") {
                SettingsSlider("Low", value: $settings.lowGain, in: -12...12, step: 1, text: dbText(settings.lowGain))
                SettingsSlider("Mid", value: $settings.midGain, in: -12...12, step: 1, text: dbText(settings.midGain))
                SettingsSlider("High", value: $settings.highGain, in: -12...12, step: 1, text: dbText(settings.highGain))
                Button("Reset Tuning") { settings.resetTuning() }
                    .controlSize(.small)
                    .help("Brightness, low, mid, high and spark power back to their starting values")
            }
        }
    }
}

// MARK: - Glow and screens

private struct GlowPage: View {
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Brightness") {
                SettingsSlider("Brightness", value: $settings.brightness, in: 0.3...2, text: percent(settings.brightness))
                SettingsSlider("Opacity", value: $settings.opacity, in: 0.15...1, text: percent(settings.opacity))
                Toggle("Keep menu bar text readable", isOn: $settings.readableMenuBar)
                    .toggleStyle(.checkbox)
                    .help("Tones down colors bright enough to wash out the menu bar's text and icons. The edge glow keeps its full colors.")
            }
            SettingsSection("Screen edge glow", caption: "A soft glow around the edges of the screen that moves with the music.") {
                Toggle("Screen edge glow", isOn: $settings.edgeGlow)
                    .toggleStyle(.checkbox)
                if settings.edgeGlow {
                    SettingsSlider("Depth", value: $settings.edgeGlowDepth, in: Settings.edgeGlowDepthRange,
                                   text: "\(Int(settings.edgeGlowDepth.rounded())) pt")
                    Toggle("Top edge too, below the menu bar", isOn: $settings.edgeGlowTop)
                        .toggleStyle(.checkbox)
                }
            }
            SettingsSection("Where it shows") {
                Toggle("Show on all displays", isOn: $settings.allDisplays)
                Toggle("Show over full-screen apps", isOn: $settings.showInFullScreen)
                    .help("Keeps the screen edge glow on over apps in full screen.")
                if settings.showInFullScreen {
                    Toggle("Menu bar visuals too", isOn: $settings.fullScreenStrip)
                        .help("Also draws the bars where the hidden menu bar would be. They step aside while you use the menu bar.")
                        .padding(.leading, 20)
                }
            }
            .toggleStyle(.checkbox)
        }
    }
}

// MARK: - General

private struct GeneralPage: View {
    @ObservedObject var updater: Updater
    @ObservedObject var icon = MenuBarIcon.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection("Starting up") {
                Toggle("Open Barbeat when you log in", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .onChange(of: launchAtLogin) { _, enable in setLaunchAtLogin(enable) }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.secondary) }
                Toggle("Menu bar icon moves with the music", isOn: $icon.animated)
                    .toggleStyle(.checkbox)
                    .help("Four little bars in Barbeat's icon follow bass to treble. They stay still with Reduce motion on.")
                Button("Show the Welcome Window") { WelcomeWindow.show() }
                    .controlSize(.small)
            }
            SettingsSection("Updates", caption: "Barbeat looks for a newer version on GitHub about once a day and asks before installing it.") {
                Toggle("Check for updates automatically", isOn: $updater.automatic)
                    .toggleStyle(.checkbox)
                HStack(spacing: 10) {
                    Button("Check Now") { updater.check(manual: true) }
                        .controlSize(.small)
                        .disabled(updater.state == .checking || updater.state == .downloading || updater.state == .installing)
                    switch updater.state {
                    case .checking: Text("Checking…").font(.caption).foregroundStyle(.secondary)
                    case .downloading: Text("Downloading the update…").font(.caption).foregroundStyle(.secondary)
                    case .installing: Text("Installing…").font(.caption).foregroundStyle(.secondary)
                    case .failed(let message): Text(message).font(.caption).foregroundStyle(.secondary)
                    case .idle: EmptyView()
                    }
                }
            }
            SettingsSection("Help and support") {
                HStack(spacing: 16) {
                    Link("Barbeat guide", destination: Credits.helpURL)
                    Link("♥ Support Barbeat", destination: Credits.supportURL)
                }
            }
            SettingsSection("About") {
                Text("Barbeat \(Credits.version), made by \(Credits.author) (\(Credits.handle)).")
                    .foregroundStyle(.secondary)
                Button("Quit Barbeat") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
        }
    }

    private func setLaunchAtLogin(_ enable: Bool) {
        do {
            if enable { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change the login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
