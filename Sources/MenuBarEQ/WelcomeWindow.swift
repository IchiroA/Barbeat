import SwiftUI
import AppKit

/// Shown once: what Barbeat does, with Screen colors front and center, and where the settings are.
enum WelcomeWindow {
    private static var window: NSWindow?
    private static let shownKey = "welcome.shown"

    static func showIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: shownKey) else { return }
        show()
    }

    static func show() {
        UserDefaults.standard.set(true, forKey: shownKey)
        if window == nil {
            let host = NSHostingController(rootView: WelcomeView(settings: .shared, close: { WelcomeWindow.close() }))
            let window = NSWindow(contentViewController: host)
            window.title = "Welcome to Barbeat"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func close() { window?.close() }
}

struct WelcomeView: View {
    @ObservedObject var settings: Settings
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                BundledImage(name: "hero")
                    .frame(width: 560, height: 230)
                    .clipped()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your menu bar, as a light show")
                        .font(.title.weight(.bold))
                    Text("Barbeat moves with whatever your Mac plays.")
                        .font(.title3)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 6)
                .padding(20)
            }

            VStack(alignment: .leading, spacing: 16) {
                screenColors
                feature("lightbulb.2", "Lights", "Philips Hue and WLED lights can join in, in the same colors.",
                        button: "Set Up Lights…") { SettingsWindow.show(.lights) }
                feature("music.mic", "Voice", "Colors and a glow that follow the singer.",
                        button: "Voice Options…") { SettingsWindow.show(.voice) }
                Divider()
                HStack {
                    Text("Quick controls are in the menu bar (the bars icon). Everything else is in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button("Open Settings") { SettingsWindow.show(); close() }
                    Button("Get Started") { close() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 560)
    }

    private var screenColors: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles.tv")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Screen colors").font(.title3.weight(.semibold))
                Spacer()
                if settings.screenColors {
                    Label("On", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout.weight(.semibold))
                }
            }
            Text("The menu bar, the glow around your screen and your lights take their colors from what you're watching, like a TV's backlight. At a concert, the stage beams and lasers spill right out of the screen.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if !settings.screenColors {
                    Button("Turn On Screen Colors") { ScreenColorsAccess.turnOn(settings) }
                        .buttonStyle(.borderedProminent)
                }
                Button("How It Works") { SettingsWindow.show(.screen) }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1.5))
    }

    private func feature(_ symbol: String, _ title: String, _ text: String, button: String,
                         action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(button, action: action).controlSize(.small)
        }
    }
}
