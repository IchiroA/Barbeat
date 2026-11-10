import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - The panel row

/// The Scenes button in the menu bar panel: shows the scene in use and opens Settings › Scenes.
struct SceneRow: View {
    @ObservedObject var store: SceneStore
    // Watched so "changed since" stays up to date.
    @ObservedObject var settings = Settings.shared
    @ObservedObject var lights = LightSettings.shared
    @ObservedObject var voice = VoiceSettings.shared
    @State private var hovering = false

    var body: some View {
        let active = store.active
        Button { SettingsWindow.show(.scenes) } label: {
            HStack(spacing: 10) {
                Image(systemName: active?.symbol ?? "theatermasks.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scenes").font(.callout)
                    Text(subtitle(active))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Text(active?.name ?? "Choose")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(active == nil ? Color.secondary : Color.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.1 : 0.05)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Pick a scene, edit them, or import and export them")
    }

    private func subtitle(_ active: BarbeatScene?) -> String {
        if store.automaticID != nil { return "Switched because \(store.automaticReason)" }
        if let active, !active.effectiveLook.isSatisfied(by: .current()) { return "Changed since you picked it" }
        return "One click for a whole look"
    }
}

// MARK: - The Settings page

struct ScenesPage: View {
    @ObservedObject var store: SceneStore
    @ObservedObject var apps: AudioSourceList
    @ObservedObject var settings = Settings.shared
    @ObservedObject var lights = LightSettings.shared
    @ObservedObject var voice = VoiceSettings.shared
    /// Scenes showing their details. `--scenes-expand` opens the first one (for snapshots).
    @State private var editing: Set<UUID> = CommandLine.arguments.contains("--scenes-expand")
        ? Set(SceneStore.shared.scenes.prefix(1).map(\.id)) : []
    @State private var dropping = false

    var body: some View {
        let now = SceneLook.current()
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Button { SceneStore.promptSave() } label: { Label("Save Current Look…", systemImage: "plus") }
                    .help("Saves almost every setting as it is now as a new scene")
                Spacer()
                Button { SceneFiles.importWithPanel() } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                    .help("Adds scenes from a file: a backup, or a scene a friend sent you")
                Button { SceneFiles.export(store.scenes) } label: { Label("Export All…", systemImage: "square.and.arrow.up") }
                    .help("Saves all your scenes in one file, to back up or share")
                    .disabled(store.scenes.isEmpty)
            }
            if let message = store.message {
                Label(message.text, systemImage: message.isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(message.isProblem ? Color.orange : Color.green)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(store.scenes) { scene in
                card(scene, now: now)
            }
            if store.scenes.isEmpty {
                Text("No scenes yet. Save your current look, import a file, or add the starter scenes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if SceneStore.starters.contains(where: { starter in !store.scenes.contains { $0.name == starter.name } }) {
                Button("Add the Missing Starter Scenes") {
                    for starter in SceneStore.starters where !store.scenes.contains(where: { $0.name == starter.name }) {
                        var copy = starter
                        copy.id = UUID()
                        store.scenes.append(copy)
                    }
                }
                .controlSize(.small)
            }

            SettingsSection("Switching on their own",
                            caption: "A scene with a trigger turns on by itself while the trigger lasts, then everything goes back to how it was. If you pick another scene meanwhile, yours wins until the trigger ends.") {
                Toggle("Switch scenes automatically", isOn: $store.autoSwitch)
                    .toggleStyle(.checkbox)
            }

            SettingsSection("Backing up and sharing",
                            caption: "Scene files are plain JSON. Export one scene (from its ⋯ menu) or all of them to keep a backup or send to a friend, and import a file, or drop it on this page, to add its scenes. Light devices are matched by ID, so a friend's scene leaves your own lights' switches and sparkles alone.") {
                EmptyView()
            }
        }
        .padding(dropping ? 6 : 0)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.06)))
                    .overlay(Label("Drop to import scenes", systemImage: "square.and.arrow.down").font(.headline))
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.isFileURL }
            guard !files.isEmpty else { return false }
            DispatchQueue.main.async { SceneFiles.importFiles(files) }
            return true
        } isTargeted: { dropping = $0 }
    }

    private func binding(_ id: UUID) -> Binding<BarbeatScene>? {
        guard let scene = store.scenes.first(where: { $0.id == id }) else { return nil }
        return Binding(get: { store.scenes.first { $0.id == id } ?? scene }, set: { value in
            if let i = store.scenes.firstIndex(where: { $0.id == id }), store.scenes[i] != value { store.scenes[i] = value }
        })
    }

    @ViewBuilder
    private func card(_ scene: BarbeatScene, now: SceneLook) -> some View {
        if let edit = binding(scene.id) {
            let active = store.activeID == scene.id
            let isEditing = editing.contains(scene.id)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    symbolMenu(scene, edit: edit)
                    TextField("Name", text: edit.name)
                        .textFieldStyle(.plain)
                        .font(.headline)
                    badge(scene, active: active, now: now)
                    Button("Use") { store.apply(scene) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .help("Switch to this scene now")
                    Menu {
                        Button("Update with the Current Look") { store.updateWithCurrent(scene.id) }
                        Button("Duplicate") { store.duplicate(scene.id) }
                        Button("Export…") { SceneFiles.export([scene]) }
                        Divider()
                        Button("Move Up") { store.move(scene.id, by: -1) }
                        Button("Move Down") { store.move(scene.id, by: 1) }
                        Divider()
                        Button("Delete", role: .destructive) { store.delete(scene.id) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(scene.effectiveLook.isEmpty ? "Doesn't change anything yet: tick a part below." : scene.effectiveLook.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        if isEditing { editing.remove(scene.id) } else { editing.insert(scene.id) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isEditing ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 10)
                            Text(overview(scene))
                                .lineLimit(1)
                        }
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isEditing ? "Hide the details" : "Choose what this scene sets and when it turns on by itself")
                }
                .padding(.leading, 32)

                if isEditing {
                    details(scene, edit: edit, now: now)
                        .padding(.leading, 32)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(active ? 0.07 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(active ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.5))
        }
    }

    @ViewBuilder
    private func badge(_ scene: BarbeatScene, active: Bool, now: SceneLook) -> some View {
        if store.automaticID == scene.id {
            Text("On now: \(store.automaticReason)").font(.caption).foregroundStyle(.green)
        } else if active {
            if scene.effectiveLook.isSatisfied(by: now) {
                Text("In use").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("In use · changed since")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("You've changed settings since you picked it. Use it again to go back, or choose Update with the Current Look in its ⋯ menu to keep the changes.")
            }
        }
    }

    /// "Sets 7 of 8 parts · turns on during calls"
    private func overview(_ scene: BarbeatScene) -> String {
        let count = ScenePart.allCases.filter(scene.includes).count
        var text = count == ScenePart.allCases.count ? "Sets every part" : "Sets \(count) of \(ScenePart.allCases.count) parts"
        var triggers: [String] = []
        if scene.onCall { triggers.append("during calls") }
        if !scene.apps.isEmpty { triggers.append("while \(scene.apps.map(\.name).joined(separator: " or ")) plays") }
        if !triggers.isEmpty { text += " · turns on " + triggers.joined(separator: " and ") }
        return text
    }

    private func details(_ scene: BarbeatScene, edit: Binding<BarbeatScene>, now: SceneLook) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What it sets").font(.caption.weight(.semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(ScenePart.allCases) { part in
                        partChip(part, scene: scene, edit: edit, now: now)
                    }
                }
                Text("Unticked parts stay as they are when you use the scene. Ticking a part the scene doesn't have yet takes it from your settings right now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Turns on by itself").font(.caption.weight(.semibold))
                Toggle("While you're on a call (an app is using the microphone)", isOn: edit.onCall)
                    .toggleStyle(.checkbox)
                HStack(spacing: 6) {
                    Text("While one of these plays:").font(.callout)
                    ForEach(scene.apps, id: \.self) { app in
                        HStack(spacing: 3) {
                            Text(app.name)
                            Button { edit.wrappedValue.apps.removeAll { $0 == app } } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    Menu("Add App") {
                        ForEach(apps.apps.filter { app in !scene.apps.contains { $0.id == app.id } }) { app in
                            Button(app.isPlaying ? "\(app.name)  ♪" : app.name) {
                                edit.wrappedValue.apps.append(SceneApp(id: app.id, name: app.name))
                            }
                        }
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .onAppear { apps.refresh() }
                }
            }
        }
    }

    private func partChip(_ part: ScenePart, scene: BarbeatScene, edit: Binding<BarbeatScene>, now: SceneLook) -> some View {
        let on = scene.includes(part)
        return Button { edit.wrappedValue.setIncluded(part, !on, current: now) } label: {
            HStack(spacing: 6) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                Image(systemName: part.symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(part.title)
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(part.help + (on ? "" : scene.look.has(part) ? ". Left out: tick to set it again." : ". Not in this scene: tick to take it from your settings now."))
    }

    private func symbolMenu(_ scene: BarbeatScene, edit: Binding<BarbeatScene>) -> some View {
        Menu {
            ForEach(SceneSymbols.all, id: \.symbol) { choice in
                Button { edit.wrappedValue.symbol = choice.symbol } label: { Label(choice.name, systemImage: choice.symbol) }
            }
        } label: {
            Image(systemName: scene.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // A fixed slot, so names line up whatever the icon's width.
        .frame(width: 24)
        .help("Choose an icon")
    }
}

/// Icons to pick for a scene.
enum SceneSymbols {
    static let all: [(symbol: String, name: String)] = [
        ("sparkles", "Sparkles"), ("lizard.fill", "Chameleon"), ("music.mic", "Concert"), ("figure.dance", "Dance"),
        ("party.popper.fill", "Party"), ("headphones", "Headphones"), ("guitars.fill", "Guitars"), ("popcorn.fill", "Movie"),
        ("tv.fill", "TV"), ("gamecontroller.fill", "Games"), ("moon.stars.fill", "Night"), ("bed.double.fill", "Bedtime"),
        ("sunset.fill", "Sunset"), ("leaf.fill", "Calm"), ("flame.fill", "Fire"), ("bolt.fill", "Energy"),
        ("heart.fill", "Heart"), ("cup.and.saucer.fill", "Coffee"), ("laptopcomputer", "Work"), ("phone.fill", "Call"),
    ]
}

// MARK: - Files

/// Scene files: plain JSON, for backups and for sharing with friends.
enum SceneFiles {
    /// What an exported file holds. `scenes` is all Barbeat needs; the rest says what the file is.
    private struct Exported: Encodable {
        var barbeat = "scenes"
        var version = 1
        var app: String
        var exported: Date
        var scenes: [BarbeatScene]
    }

    private struct Incoming: Decodable {
        var scenes: [BarbeatScene]
    }

    enum ReadError: LocalizedError {
        case tooBig, noScenes

        var errorDescription: String? {
            switch self {
            case .tooBig: return "The file is too big to be a scene file."
            case .noScenes: return "There are no Barbeat scenes in it."
            }
        }
    }

    static func data(for scenes: [BarbeatScene]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Exported(app: "Barbeat \(Credits.version)", exported: Date(), scenes: scenes))
    }

    /// Reads an exported file, a list of scenes, or a single scene.
    static func scenes(in data: Data) throws -> [BarbeatScene] {
        guard data.count <= 4_000_000 else { throw ReadError.tooBig }
        let object = try JSONSerialization.jsonObject(with: data)
        let decoder = JSONDecoder()
        let found: [BarbeatScene]
        if let dict = object as? [String: Any], dict["scenes"] is [Any] {
            found = try decoder.decode(Incoming.self, from: data).scenes
        } else if object is [Any] {
            found = try decoder.decode([BarbeatScene].self, from: data)
        } else if let dict = object as? [String: Any], dict["look"] is [String: Any] {
            found = [try decoder.decode(BarbeatScene.self, from: data)]
        } else {
            throw ReadError.noScenes
        }
        guard !found.isEmpty else { throw ReadError.noScenes }
        return found
    }

    /// A file name from a scene's name.
    private static func fileName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Barbeat Scene" : cleaned
    }

    private static var settingsWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.title == "Barbeat Settings" }
    }

    static func export(_ scenes: [BarbeatScene]) {
        guard !scenes.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (scenes.count == 1 ? fileName(scenes[0].name) + " (Barbeat scene)" : "Barbeat Scenes") + ".json"
        panel.message = scenes.count == 1
            ? "Save “\(scenes[0].name)” as a file you can keep as a backup or send to a friend."
            : "Save your \(scenes.count) scenes as a file you can keep as a backup or send to a friend."
        let write: (URL) -> Void = { url in
            do {
                try data(for: scenes).write(to: url, options: .atomic)
                SceneStore.shared.say("Saved \(scenes.count == 1 ? "“\(scenes[0].name)”" : "\(scenes.count) scenes") to \(url.lastPathComponent)")
            } catch {
                SceneStore.shared.say("Couldn't save the file: \(error.localizedDescription)", problem: true)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = settingsWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { write(url) }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            write(url)
        }
    }

    static func importWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose scene files exported from Barbeat."
        panel.prompt = "Import"
        NSApp.activate(ignoringOtherApps: true)
        if let window = settingsWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK else { return }
                let urls = panel.urls
                // After the sheet is gone, so a question about duplicates can show.
                DispatchQueue.main.async { importFiles(urls) }
            }
        } else if panel.runModal() == .OK {
            importFiles(panel.urls)
        }
    }

    /// Reads the files and adds their scenes, asking first when some of them are already here.
    static func importFiles(_ urls: [URL], ask: Bool = true) {
        var found: [BarbeatScene] = []
        var problems: [String] = []
        for url in urls {
            do {
                found += try scenes(in: Data(contentsOf: url))
            } catch let error as ReadError {
                problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
            } catch {
                problems.append("\(url.lastPathComponent): it isn't a scene file Barbeat can read.")
            }
        }
        let store = SceneStore.shared
        guard !found.isEmpty else {
            store.say(problems.isEmpty ? "Nothing to import." : "Couldn't import " + problems.joined(separator: " "), problem: true)
            return
        }

        var choice = SceneStore.Conflict.keepBoth
        let already = found.filter { scene in store.scenes.contains { $0.id == scene.id } }
        if ask, !already.isEmpty {
            let alert = NSAlert()
            alert.messageText = already.count == 1
                ? "“\(already[0].name)” is already in Barbeat"
                : "\(already.count) of these scenes are already in Barbeat"
            alert.informativeText = "Replace them with the ones in the file (for example to restore a backup), or keep both?"
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Keep Both")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn: choice = .replace
            case .alertSecondButtonReturn: choice = .keepBoth
            default: return
            }
        }
        let result = store.add(found, onConflict: choice)
        var parts: [String] = []
        if result.added > 0 { parts.append(result.added == 1 ? "Added 1 scene" : "Added \(result.added) scenes") }
        if result.replaced > 0 { parts.append(parts.isEmpty ? "Replaced \(result.replaced)" : "replaced \(result.replaced)") }
        let from = urls.count == 1 ? " from \(urls[0].lastPathComponent)" : ""
        var text = parts.joined(separator: " and ") + from + "."
        if !problems.isEmpty { text += " Skipped " + problems.joined(separator: " ") }
        store.say(text, problem: !problems.isEmpty)
    }
}
