import SwiftUI
import AppKit

@main
struct MenuBarEQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            SettingsView(settings: .shared, status: .shared)
        } label: {
            MenuBarIconView(icon: .shared)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: OverlayController?
    private var pairing: HuePairing?

    /// Quitting while Barbeat holds the lights: put them back first (at most a few seconds).
    /// Done right here on background threads: the main thread can't run other work while it's quitting.
    /// `barbeat://…` links (Shortcuts, Stream Deck, Raycast, a browser).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { _ = LinkCommands.run(url) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        PulseController.restoreDisplays()
        let hub = LightHub.shared
        hub.closing = true
        guard hub.isHoldingLights else { return .terminateNow }
        hub.note("quitting: giving the lights back")
        hub.giveBackBeforeQuit(timeout: 4.5)
        return .terminateNow
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--demo` animates a built-in test signal instead of listening to system audio.
        let demo = CommandLine.arguments.contains("--demo")
        setlinebuf(stdout) // so --verbose / --snapshot output shows up immediately in log files
        controller = OverlayController(settings: .shared, status: .shared, demo: demo)
        controller?.start()

        let args = CommandLine.arguments
        // Looks for a newer Barbeat on GitHub (not in test runs, unless testing the updater itself).
        let testRun = demo || args.contains { $0.hasSuffix("-snapshot") || $0 == "--snapshot" || $0 == "--lights-virtual" }
            || args.contains("--update-test")
        if !testRun || Updater.shared.testing { Updater.shared.start() }
        // `--open-url barbeat://…` runs a link as if it were opened (to test them without LaunchServices).
        if let i = args.firstIndex(of: "--open-url"), i + 1 < args.count, let url = URL(string: args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { print("open-url: \(LinkCommands.run(url) ? "done" : "not understood")") }
        }
        // `--sleep-in N` starts the lights' sleep timer for N seconds (to test it).
        if let i = args.firstIndex(of: "--sleep-in"), i + 1 < args.count, let seconds = Double(args[i + 1]) {
            LightHub.shared.startSleep(minutes: seconds / 60)
        }
        // `--scenes-import <file>` adds a scene file's scenes (keeping both on duplicates, no questions);
        // `--scenes-export <file>` saves all scenes. To test scene files without the open and save panels.
        if let i = args.firstIndex(of: "--scenes-import"), i + 1 < args.count {
            SceneFiles.importFiles([URL(fileURLWithPath: args[i + 1])], ask: false)
            print("scenes-import: \(SceneStore.shared.message?.text ?? "nothing")")
        }
        if let i = args.firstIndex(of: "--scenes-export"), i + 1 < args.count {
            do {
                try SceneFiles.data(for: SceneStore.shared.scenes).write(to: URL(fileURLWithPath: args[i + 1]))
                print("scenes-export: wrote \(SceneStore.shared.scenes.count) scenes to \(args[i + 1])")
            } catch {
                print("scenes-export: \(error.localizedDescription)")
            }
        }
        // Scenes switch on their own when an app plays or a call starts.
        if !testRun || args.contains("--scenes-auto") { SceneStore.shared.start() }
        // Once: what Barbeat does, Screen colors first, and where the settings went.
        if !testRun, !Updater.shared.testing {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { WelcomeWindow.showIfNeeded() }
        }
        // `--settings-snapshot out.png [page]` and `--welcome-snapshot out.png` render those windows offscreen.
        if let i = args.firstIndex(of: "--settings-snapshot"), i + 1 < args.count {
            let path = args[i + 1]
            if i + 2 < args.count, let page = SettingsPage(rawValue: args[i + 2]) { SettingsRouter.shared.page = page }
            LightHub.shared.previewWanted = SettingsRouter.shared.page == .lights
            VoiceMonitor.shared.wanted = SettingsRouter.shared.page == .voice
            // `--snapshot-delay N`: wait N seconds instead of 2.5 (say, for the beat clock to lock on in demo mode).
            let delay = args.firstIndex(of: "--snapshot-delay").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 2.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                PanelSnapshot.save(SettingsWindowView(router: .shared, settings: .shared, scrolls: false), width: 820, to: path)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
            }
        }
        if let i = args.firstIndex(of: "--icon-snapshot"), i + 1 < args.count {
            let path = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let samples: [[Float]] = [[0.45, 0.75, 1, 0.6], [1, 0.4, 0.7, 0.2], [0.2, 0.9, 0.5, 1]]
                PanelSnapshot.save(HStack(spacing: 12) {
                    ForEach(samples.indices, id: \.self) { Image(nsImage: MenuBarIcon.draw(samples[$0])).scaleEffect(3).frame(width: 60, height: 50) }
                }.padding(10), width: nil, to: path)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
            }
        }
        if let i = args.firstIndex(of: "--welcome-snapshot"), i + 1 < args.count {
            let path = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                PanelSnapshot.save(WelcomeView(settings: .shared), width: 560, to: path)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
            }
        }
        if let i = args.firstIndex(of: "--panel-snapshot"), i + 1 < args.count {
            let path = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                PanelSnapshot.save(to: path)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
            }
        }
        if let i = args.firstIndex(of: "--lights-snapshot"), i + 1 < args.count {
            let path = args[i + 1]
            LightHub.shared.previewWanted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                PanelSnapshot.save(LightsView(settings: .shared, hub: .shared, app: .shared, scrolls: false), width: 500, to: path)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
            }
        }
        // `--pulse-snapshot out.png` draws the beat pulse's two glow looks over a grey screen, then quits.
        if let i = args.firstIndex(of: "--pulse-snapshot"), i + 1 < args.count {
            PulseArt.writeSnapshot(to: args[i + 1])
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        // `--kaleidoscope-image picture.png out.png [mirrors] [mirror|crystal|tunnel]` draws the kaleidoscope of a picture
        // offscreen, then quits.
        if let i = args.firstIndex(of: "--kaleidoscope-image"), i + 2 < args.count {
            let mirrors = i + 3 < args.count ? Int(args[i + 3]) ?? 8 : 8
            let pattern = i + 4 < args.count ? KaleidoscopePattern(rawValue: args[i + 4]) ?? .crystal : .crystal
            KaleidoscopeRenderer.writeSnapshot(from: args[i + 1], to: args[i + 2], segments: mirrors, pattern: pattern)
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        // `--kaleidoscope-start` starts the show a second after launch (to test it; Esc or a click stops it). Only
        // with Screen Recording already allowed: a test run never asks.
        if args.contains("--kaleidoscope-start") {
            if CGPreflightScreenCaptureAccess() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { KaleidoscopeController.shared.start() }
            } else {
                print("kaleidoscope: no Screen Recording permission for this copy, not starting")
            }
        }
        if let i = args.firstIndex(of: "--voice-snapshot"), i + 1 < args.count {
            let path = args[i + 1]
            VoiceMonitor.shared.wanted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                PanelSnapshot.save(VoiceView(settings: .shared, monitor: .shared), width: 480, to: path)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
            }
        }
        // `--hue-pair <address>` pairs with a Hue Bridge at launch (press its button), printing the progress.
        if let i = args.firstIndex(of: "--hue-pair"), i + 1 < args.count {
            pairing = HuePairing(printing: true)
            pairing?.pair(host: args[i + 1])
        }
        // `--quit-after N` quits the normal way after N seconds (so the lights get put back, as on a real quit).
        if let i = args.firstIndex(of: "--quit-after"), i + 1 < args.count, let seconds = Double(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let path = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
                self?.controller?.saveSnapshot(to: path)
                NSApp.terminate(nil)
            }
        }
    }
}
