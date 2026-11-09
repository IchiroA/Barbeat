import Foundation

/// `barbeat://` links, for Shortcuts ("Open URL"), Stream Deck, Raycast or a browser:
///
///     barbeat://on  ·  barbeat://off  ·  barbeat://toggle
///     barbeat://scene/Concert
///     barbeat://style/center
///     barbeat://screen-colors/on|off|toggle   barbeat://lights/on|off|toggle   barbeat://voice/on|off|toggle
///     barbeat://sleep/30   (minutes)   ·   barbeat://sleep/off
///     barbeat://settings   ·   barbeat://settings/lights
enum LinkCommands {
    /// Returns false for a link it doesn't understand.
    @discardableResult
    static func run(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "barbeat" else { return false }
        let command = (url.host ?? "").lowercased()
        let argument = url.pathComponents.dropFirst().joined(separator: "/").removingPercentEncoding ?? ""
        let settings = Settings.shared

        func flip(_ current: Bool) -> Bool? {
            switch argument.lowercased() {
            case "on", "": return command == "toggle" ? !current : true
            case "off": return false
            case "toggle": return !current
            default: return nil
            }
        }

        switch command {
        case "on": settings.enabled = true
        case "off": settings.enabled = false
        case "toggle": settings.enabled.toggle()
        case "scene":
            return SceneStore.shared.apply(named: argument)
        case "style":
            guard let style = EQStyle.allCases.first(where: { $0.rawValue == argument.lowercased() || $0.title.lowercased() == argument.lowercased() })
            else { return false }
            settings.style = style
        case "screen-colors":
            guard let on = flip(settings.screenColors) else { return false }
            if on { ScreenColorsAccess.turnOn(settings) } else { settings.screenColors = false }
        case "lights":
            guard let on = flip(LightSettings.shared.enabled) else { return false }
            LightSettings.shared.enabled = on
        case "voice":
            guard let on = flip(VoiceSettings.shared.enabled) else { return false }
            VoiceSettings.shared.enabled = on
        case "sleep":
            if argument.lowercased() == "off" {
                LightHub.shared.cancelSleep()
            } else if let minutes = Double(argument), minutes > 0, minutes <= 24 * 60 {
                LightHub.shared.startSleep(minutes: minutes)
            } else {
                return false
            }
        case "settings":
            SettingsWindow.show(SettingsPage(rawValue: argument.lowercased()))
        default:
            return false
        }
        return true
    }
}
