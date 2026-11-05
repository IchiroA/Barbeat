import SwiftUI
import AppKit

@main
struct MenuBarEQApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            SettingsView(settings: .shared, status: .shared)
        } label: {
            Image(systemName: "chart.bar.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: OverlayController?
    private var pairing: HuePairing?

    /// Quitting while Barbeat holds the lights: put them back first (at most a few seconds).
    /// Done right here on background threads: the main thread can't run other work while it's quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
