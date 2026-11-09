import Foundation
import Combine

/// Plays the light show on one Hue entertainment area, and puts the lights back afterwards.
final class HueOutput: LightOutput {
    private(set) var config: HueBridgeConfig
    let id: String
    let kind = "Hue"
    var title: String { config.areaName ?? config.name }
    var detail: String {
        guard let area else { return config.name }
        let lights = area.lightIDs.count
        let channels = area.channels.count
        let extra = channels > lights && lights > 0 ? " (\(channels) segments)" : ""
        return "\(config.name) · \(lights) \(lights == 1 ? "light" : "lights")\(extra)"
    }
    private(set) var slots: [LightSlot] = []
    let maxRate = 50.0
    var onChange: (() -> Void)?
    var endWithLightsOff = false
    private(set) var state: LightOutputState = .idle { didSet { if state != oldValue { onChange?() } } }

    private weak var hub: LightHub?
    private var client: HueClient
    private var credentials: HueCredentials?
    private var applicationID: String?
    private var area: HueArea?
    private var stream: HueStream?
    /// How the lights were before Barbeat took over (also on disk until they're restored).
    private var snapshot: HueSnapshot?
    /// Bumped whenever a take-over or give-back starts, so stale async work stops.
    private var generation = 0

    init(config: HueBridgeConfig, hub: LightHub) {
        self.config = config
        self.hub = hub
        id = "hue:\(config.id)"
        client = HueClient(host: config.host, pin: config.certificateSHA256)
        credentials = HueCredentials.load(bridge: config.id)
        snapshot = HueSnapshot.load(bridge: config.id)
        area = hub.hueAreas[config.id]?.first { $0.id == config.areaID }
        slots = area?.slots ?? []
        refresh()
        if snapshot != nil { putBackLeftovers() }
    }

    private var key: String? { credentials?.username }

    func update(_ new: HueBridgeConfig) {
        let old = config
        config = new
        if new.host != old.host {
            client.invalidate()
            client = HueClient(host: new.host, pin: new.certificateSHA256)
        }
        guard new.areaID != old.areaID || new.host != old.host else { return }
        // A different area: hand the old one's lights back first; the hub takes the new one over.
        if [.live, .connecting].contains(state) { giveBack {} }
        area = hub?.hueAreas[config.id]?.first { $0.id == config.areaID }
        slots = area?.slots ?? []
        refresh()
    }

    /// Reads the bridge's entertainment areas (for the picker and the light positions).
    func refresh() {
        guard let key else {
            state = .needsSetup("Pair \(config.name) again.")
            return
        }
        Task { @MainActor in
            do {
                let areas = try await client.areas(key: key)
                hub?.hueAreas[config.id] = areas
                rememberCertificate()
                apply(areas)
            } catch {
                hub?.note("hue: \(error.localizedDescription)")
                if case .idle = state, case HueError.unauthorized = error { state = .needsSetup(error.localizedDescription) }
            }
        }
    }

    private func apply(_ areas: [HueArea]) {
        if config.areaID == nil, areas.count == 1 {
            edit { $0.areaID = areas[0].id; $0.areaName = areas[0].name }
            config.areaID = areas[0].id
            config.areaName = areas[0].name
        }
        area = areas.first { $0.id == config.areaID }
        if let area, area.name != config.areaName { edit { $0.areaName = area.name } }
        slots = area?.slots ?? []
        switch state {
        case .idle, .needsSetup:
            state = area == nil ? .needsSetup(areas.isEmpty
                ? "Create an entertainment area in the Hue app (Settings › Entertainment areas), then click Refresh."
                : "Choose an entertainment area.") : .idle
        default:
            break
        }
    }

    /// Saves the bridge's certificate fingerprint the first time it's seen.
    private func rememberCertificate() {
        guard config.certificateSHA256 == nil, let pin = client.pin else { return }
        config.certificateSHA256 = pin
        edit { $0.certificateSHA256 = pin }
    }

    private func edit(_ change: (inout HueBridgeConfig) -> Void) {
        let settings = LightSettings.shared
        guard let i = settings.hueBridges.firstIndex(where: { $0.id == config.id }) else { return }
        var copy = settings.hueBridges[i]
        change(&copy)
        if copy != settings.hueBridges[i] { settings.hueBridges[i] = copy }
    }

    // MARK: - Taking over

    func takeOver() {
        guard let credentials else {
            state = .needsSetup("Pair \(config.name) again.")
            return
        }
        generation += 1
        let generation = self.generation
        state = .connecting
        Task { @MainActor in
            do {
                let key = credentials.username
                if applicationID == nil { applicationID = try await client.applicationID(key: key) }
                let areas = try await client.areas(key: key)
                hub?.hueAreas[config.id] = areas
                rememberCertificate()
                guard generation == self.generation else { return }
                apply(areas)
                guard let area else {
                    state = .needsSetup(areas.isEmpty ? "Create an entertainment area in the Hue app." : "Choose an entertainment area.")
                    return
                }
                if area.active, area.streamer != applicationID {
                    state = .failed("\(area.name) is in use by another app (like Hue Sync).")
                    return
                }
                // Save how the lights are now. A snapshot left over from a failed try is older and still right.
                if snapshot == nil {
                    let snap = try await takeSnapshot(of: area, key: key)
                    guard generation == self.generation else { return }
                    snapshot = snap
                    snap.save()
                    hub?.note("hue: saved \(snap.lights.count) lights\(snap.scenes.isEmpty ? "" : " and \(snap.scenes.count) scene(s)") of \(area.name)")
                }
                try await client.setStreaming(true, area: area.id, key: key)
                guard generation == self.generation else { return }
                openStream(to: area, generation: generation)
            } catch {
                guard generation == self.generation else { return }
                failAndRestore(error.localizedDescription)
            }
        }
    }

    private func takeSnapshot(of area: HueArea, key: String) async throws -> HueSnapshot {
        let all = try await client.lights(key: key)
        let lights = area.lightIDs.compactMap { all[$0] }
        let scenes = (try? await client.activeScenes(lights: Set(area.lightIDs), key: key)) ?? []
        return HueSnapshot(bridge: config.id, area: area.id, lights: lights, scenes: scenes, taken: Date())
    }

    private func openStream(to area: HueArea, generation: Int) {
        guard let credentials, let applicationID,
              let stream = HueStream(host: config.host, identity: applicationID, clientKey: credentials.clientKey, areaID: area.id) else {
            failAndRestore("The bridge's keys don't work for streaming. Remove the bridge and pair again.")
            return
        }
        stream.onReady = { [weak self] in
            guard let self, generation == self.generation else { return }
            self.state = .live
            self.hub?.note("hue: streaming to \(area.name) (\(area.channels.count) channels)")
        }
        stream.onFailure = { [weak self] message in
            guard let self, generation == self.generation else { return }
            self.failAndRestore(message)
        }
        self.stream = stream
        stream.start()
    }

    func send(_ colors: [LightColor]) {
        guard state == .live, let stream else { return }
        stream.send(zip(slots, colors).map { (id: $0.channel, color: $1) })
    }

    /// Something went wrong while holding the lights: stop, put them back, and let the hub try again later.
    private func failAndRestore(_ message: String) {
        let generation = self.generation
        stream?.cancel()
        stream = nil
        state = .failed(message)
        Task { @MainActor in
            if let key, let areaID = area?.id ?? snapshot?.area {
                try? await client.setStreaming(false, area: areaID, key: key)
            }
            await restoreSnapshot(generation: generation)
        }
    }

    // MARK: - Giving back

    func giveBack(completion: @escaping () -> Void) {
        generation += 1
        let generation = self.generation
        let streaming = stream != nil || state == .connecting || state == .live
        stream?.cancel()
        stream = nil
        guard streaming || snapshot != nil else {
            if case .givingBack = state { state = .idle }
            completion()
            return
        }
        state = .givingBack
        Task { @MainActor in
            if streaming, let key, let areaID = area?.id ?? snapshot?.area {
                try? await client.setStreaming(false, area: areaID, key: key)
            }
            await restoreSnapshot(generation: generation)
            if generation == self.generation { state = area == nil ? .needsSetup("Choose an entertainment area.") : .idle }
            completion()
        }
    }

    /// Puts the saved state back, then forgets it (unless a new take-over started meanwhile).
    private func restoreSnapshot(generation: Int) async {
        guard var snap = snapshot, let key else { return }
        if endWithLightsOff {
            // Sleep timer: the same careful put-back, with every light off and no scenes recalled.
            endWithLightsOff = false
            snap.scenes = []
            snap.lights = snap.lights.map { var light = $0; light.on = false; return light }
        }
        let summary = await Self.putBack(snap, client: client, key: key)
        hub?.note(summary)
        // A new take-over started meanwhile keeps the snapshot: the lights still show the stream's colors.
        if generation == self.generation {
            snapshot = nil
            HueSnapshot.delete(bridge: config.id)
        }
    }

    /// Quitting: stops the stream and puts the lights back without needing the main thread, which is busy
    /// waiting for the quit. If it runs out of time, the snapshot stays on disk for the next launch.
    func giveBackBeforeQuit(timeout: TimeInterval) {
        generation += 1
        let streaming = stream != nil || state == .connecting || state == .live
        stream?.cancel()
        stream = nil
        guard let key, let snap = snapshot ?? HueSnapshot.load(bridge: config.id) else { return }
        let client = self.client, areaID = area?.id ?? snap.area
        let done = DispatchSemaphore(value: 0)
        let box = SummaryBox()
        Task.detached {
            if streaming { try? await client.setStreaming(false, area: areaID, key: key) }
            box.text = await HueOutput.putBack(snap, client: client, key: key)
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .success {
            hub?.note(box.text)
            snapshot = nil
            HueSnapshot.delete(bridge: config.id)
        } else {
            hub?.note("hue: ran out of time; the lights will be put back next time Barbeat opens")
        }
        state = .idle
    }

    private final class SummaryBox: @unchecked Sendable { var text = "" }

    /// The bridge applies its own "after syncing" state a moment after the stream stops, so wait for that,
    /// restore, then look again and redo anything the bridge changed. Returns a line for the log.
    private static func putBack(_ snap: HueSnapshot, client: HueClient, key: String) async -> String {
        func pause() async { try? await Task.sleep(nanoseconds: 110_000_000) }
        try? await Task.sleep(nanoseconds: 700_000_000)
        var covered = Set<String>()
        for scene in snap.scenes {
            if (try? await client.recall(scene, key: key)) != nil { covered.formUnion(scene.lights) }
            await pause()
        }
        let lights = snap.lights.filter { !covered.contains($0.id) }
        for light in lights {
            try? await client.restore(light, key: key)
            await pause()
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        var good = snap.lights.count, redone = 0
        if let now = try? await client.lights(key: key) {
            let wrong = lights.filter { saved in now[saved.id].map { !$0.matches(saved) } ?? false }
            redone = wrong.count
            for light in wrong {
                try? await client.restore(light, key: key)
                await pause()
            }
            if !wrong.isEmpty, let again = try? await client.lights(key: key) {
                good -= wrong.filter { saved in again[saved.id].map { !$0.matches(saved) } ?? false }.count
            }
        } else {
            good = 0
        }
        return "hue: restored \(good)/\(snap.lights.count) lights"
            + (covered.isEmpty ? "" : " (\(snap.scenes.count) scene(s) recalled)")
            + (redone > 0 ? ", re-applied \(redone) after the bridge's own update" : "")
    }

    /// Hue asks apps to keep to about 10 light commands a second.
    private func pause() async { try? await Task.sleep(nanoseconds: 110_000_000) }

    /// Barbeat quit or crashed while holding the lights last time: put them back now.
    private func putBackLeftovers() {
        guard let snap = snapshot else { return }
        guard Date().timeIntervalSince(snap.taken) < 6 * 3600 else {
            snapshot = nil
            HueSnapshot.delete(bridge: config.id)
            return
        }
        hub?.note("hue: putting back the lights from last time")
        generation += 1
        let generation = self.generation
        state = .givingBack
        Task { @MainActor in
            if let key {
                if applicationID == nil { applicationID = try? await client.applicationID(key: key) }
                if let areas = try? await client.areas(key: key), let left = areas.first(where: { $0.id == snap.area }),
                   left.active, left.streamer == applicationID {
                    try? await client.setStreaming(false, area: left.id, key: key)
                }
            }
            await restoreSnapshot(generation: generation)
            if generation == self.generation {
                state = .idle
                refresh()
            }
        }
    }

    // MARK: - Other

    func identify() {
        guard let key, let area else { return }
        Task { @MainActor in
            for light in area.lightIDs {
                try? await client.identify(light: light, key: key)
                await pause()
            }
        }
    }

    /// The bridge was removed: forget its keys (after its lights are back).
    func shutdown() {
        generation += 1
        stream?.cancel()
        stream = nil
        client.invalidate()
        HueCredentials.delete(bridge: config.id)
    }
}

/// Pairing with a bridge: find it, wait for its button, get the keys and the entertainment areas.
final class HuePairing: ObservableObject {
    enum Step: Equatable {
        case idle
        case pressButton(secondsLeft: Int)
        case finishing
        case done(String)
        case failed(String)
    }

    @Published private(set) var step: Step = .idle
    @Published private(set) var found: [HueDiscovery.Bridge] = []
    @Published private(set) var searching = false

    private let discovery = HueDiscovery()
    private var task: Task<Void, Never>?
    private var printing = false

    init(printing: Bool = false) {
        self.printing = printing
        discovery.onUpdate = { [weak self] in self?.found = $0 }
    }

    func search() {
        searching = true
        discovery.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.searching = false
            self?.discovery.stop()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        step = .idle
    }

    func pair(host rawHost: String) {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        task?.cancel()
        task = Task { @MainActor in
            let client = HueClient(host: host, pin: nil)
            defer { client.invalidate() }
            do {
                let info = try await client.bridgeInfo()
                let device = String((Host.current().localizedName ?? "Mac").prefix(19))
                var credentials: HueCredentials?
                for second in 0..<30 {
                    try Task.checkCancellation()
                    set(.pressButton(secondsLeft: 30 - second))
                    if let found = try await client.pair(deviceType: "barbeat#\(device)") {
                        credentials = found
                        break
                    }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                guard let credentials else {
                    set(.failed("The bridge's button wasn't pressed in time. Try again."))
                    return
                }
                set(.finishing)
                credentials.save(bridge: info.id)
                let areas = (try? await client.areas(key: credentials.username)) ?? []
                LightHub.shared.hueAreas[info.id] = areas
                let settings = LightSettings.shared
                var config = HueBridgeConfig(id: info.id, host: host, name: info.name, certificateSHA256: client.pin)
                if let old = settings.hueBridges.first(where: { $0.id == info.id }), areas.contains(where: { $0.id == old.areaID }) {
                    config.areaID = old.areaID
                    config.areaName = old.areaName
                } else if areas.count == 1 {
                    config.areaID = areas[0].id
                    config.areaName = areas[0].name
                }
                if let i = settings.hueBridges.firstIndex(where: { $0.id == info.id }) {
                    settings.hueBridges[i] = config
                } else {
                    settings.hueBridges.append(config)
                }
                if areas.isEmpty {
                    set(.done("Paired with \(info.name). Now create an entertainment area in the Hue app (Settings › Entertainment areas)."))
                } else if let name = config.areaName {
                    set(.done("Paired with \(info.name) · \(name)."))
                } else {
                    set(.done("Paired with \(info.name). Choose an entertainment area below."))
                }
            } catch is CancellationError {
                set(.idle)
            } catch {
                set(.failed(error.localizedDescription))
            }
        }
    }

    private func set(_ next: Step) {
        guard step != next else { return }
        step = next
        guard printing else { return }
        switch next {
        case .idle: break
        case .pressButton(let left): if left % 5 == 0 || left == 30 { print("hue pairing: press the button on the bridge (\(left) s left)") }
        case .finishing: print("hue pairing: got the keys, reading entertainment areas")
        case .done(let text): print("hue pairing: \(text)")
        case .failed(let text): print("hue pairing: failed — \(text)")
        }
    }
}
