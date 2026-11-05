import SwiftUI
import AppKit

/// The Lights window: devices, the light show's settings, and a live preview of every light.
enum LightsWindow {
    private static var window: NSWindow?
    private static let delegate = Delegate()

    static func show() {
        if window == nil {
            let host = NSHostingController(rootView: LightsView(settings: .shared, hub: .shared, app: .shared))
            let window = NSWindow(contentViewController: host)
            window.title = "Barbeat Lights"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 500, height: 720))
            window.center()
            window.delegate = delegate
            self.window = window
        }
        LightHub.shared.previewWanted = true
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private final class Delegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            LightHub.shared.previewWanted = false
        }
    }
}

/// The Lights row in the menu bar panel.
struct LightsRow: View {
    @ObservedObject var settings: LightSettings
    @ObservedObject var hub: LightHub

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lightbulb.2.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(settings.enabled ? Color.accentColor : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("Lights").font(.callout)
                HStack(spacing: 5) {
                    Circle().fill(hub.health.color).frame(width: 6, height: 6)
                    Text(hub.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Button("Set Up…") { LightsWindow.show() }
                .controlSize(.small)
            Toggle("Lights", isOn: Binding(get: { settings.enabled }, set: { on in
                settings.enabled = on
                if on && !settings.hasDevices { LightsWindow.show() }
            }))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .help("Hue and Art-Net lights that move with the music, in Barbeat's colors")
    }
}

extension LightHub.Health {
    var color: Color {
        switch self {
        case .off: return .gray
        case .waiting: return .yellow
        case .live: return .green
        case .problem: return .red
        }
    }
}

extension LightOutputState {
    var color: Color {
        switch self {
        case .idle: return .gray
        case .connecting, .givingBack: return .yellow
        case .live: return .green
        case .failed, .needsSetup: return .red
        }
    }

    var text: String {
        switch self {
        case .idle: return "Waiting for music"
        case .connecting: return "Taking over…"
        case .live: return "Playing"
        case .givingBack: return "Putting the lights back…"
        case .failed(let message), .needsSetup(let message): return message
        }
    }
}

struct LightsView: View {
    @ObservedObject var settings: LightSettings
    @ObservedObject var hub: LightHub
    @ObservedObject var app: Settings
    /// False for offscreen snapshots, which can't measure a scroll view.
    var scrolls = true
    @StateObject private var pairing = HuePairing()
    @State private var adding: Adding?
    @State private var manualHost = ""
    @State private var editing: UUID?
    @State private var nodes: [ArtNet.Node] = []
    @State private var findingNodes = false
    @State private var nodeMessage: String?
    @State private var removing: String?

    private enum Adding { case hue, artNet }

    var body: some View {
        Group {
            if scrolls {
                ScrollView(.vertical) { content }
                    .frame(minWidth: 460, idealWidth: 500, minHeight: 480, idealHeight: 720)
            } else {
                content
            }
        }
        .confirmationDialog("Remove this device?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) { if let removing { remove(removing) } }
        } message: {
            Text("Its lights go back to how they were first. A Hue Bridge needs its button pressed again to pair later.")
        }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                showSection
                Divider()
                devicesSection
                addSection
                Text("Barbeat talks to your lights only on your local network. When it lets go (music stops, Lights off, a device switched off, quit or sleep), Hue lights go back to how they were.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "lightbulb.2.fill").foregroundStyle(.tint)
                Text("Lights").font(.title3.weight(.semibold))
                Spacer()
                Toggle("Lights", isOn: $settings.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            HStack(spacing: 6) {
                Circle().fill(hub.health.color).frame(width: 7, height: 7)
                Text(settings.enabled ? hub.summary : "Off").font(.callout)
            }
            caption("The lights use Barbeat's colors (\(app.palette.title) now) and take over when music plays.")
        }
    }

    // MARK: - Light show

    private var showSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Light show")
            Picker("Mode", selection: $settings.mode) {
                ForEach(LightMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            caption(settings.mode.subtitle)
            slider("Base glow", value: $settings.baseGlow, in: 0...0.6, text: percent(settings.baseGlow),
                   help: "How bright the lights stay between beats, so the room never goes dark.")
            slider("Beat flash", value: $settings.beatFlash, in: 0...1, text: percent(settings.beatFlash),
                   help: "How hard beats punch. Never more than 3 big flashes a second.")
            slider("Brightness", value: $settings.maxBrightness, in: 0.1...1, text: percent(settings.maxBrightness),
                   help: "The brightest the lights get.")
            slider("Delay", value: $settings.delayMs, in: 0...2000, text: "\(Int((settings.delayMs / 10).rounded()) * 10) ms",
                   help: "If the lights hit before you hear the beat (AirPlay or Bluetooth speakers), delay them.")
            HStack(spacing: 8) {
                Text("Give back after")
                    .font(.callout)
                    .frame(width: 110, alignment: .leading)
                Picker("Give back after", selection: $settings.releaseAfter) {
                    ForEach(ReleaseAfter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .help("How long it's quiet before Barbeat hands the lights back.")
            caption("Seconds of silence before the lights go back to how they were.")
            Button("Reset Light Show") { settings.resetShow() }
                .controlSize(.small)
        }
    }

    // MARK: - Devices

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Devices")
            ForEach(hub.outputs.map(\.id), id: \.self) { id in
                if let output = hub.outputs.first(where: { $0.id == id }) {
                    deviceCard(output)
                }
            }
        }
    }

    private func deviceCard(_ output: LightOutput) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon(for: output))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(output.title).font(.headline)
                    caption(output.detail)
                    if let mode = hub.modes[output.id] {
                        caption("\(mode.title)\(settings.mode == .auto ? " (Auto)" : "") · \(modeDetail(mode, count: output.slots.count))")
                    }
                }
                Spacer()
                if output.kind != "Preview" {
                    let live = settings.enabled && settings.isOn(output.id)
                    HStack(spacing: 8) {
                        HStack(spacing: 5) {
                            Circle().fill(live ? output.state.color : .gray).frame(width: 7, height: 7)
                            Text(live ? shortState(output.state) : "Off").font(.caption)
                        }
                        Toggle("On", isOn: Binding(get: { settings.isOn(output.id) },
                                                   set: { settings.setOn($0, output.id) }))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                            .help("Turns this device on or off. Off: Barbeat leaves its lights alone, and Hue lights go back to how they were. It stays set up.")
                    }
                }
            }
            let deviceOn = output.kind == "Preview" || settings.isOn(output.id)
            LightStrip(colors: deviceOn ? hub.preview[output.id] ?? [] : [], count: output.slots.count)
                .frame(height: output.slots.count > 24 ? 14 : 22)
            if !deviceOn {
                caption("Switched off. Barbeat leaves these lights alone until you switch it back on.")
            }
            if settings.enabled, deviceOn, case let .failed(message) = output.state { problem(message) }
            if case let .needsSetup(message) = output.state { problem(message) }

            if let hue = output as? HueOutput { hueControls(hue) }
            if let artNet = output as? ArtNetOutput { artNetControls(artNet) }
            if output.kind == "Preview", output.id == "preview" {
                HStack {
                    caption("No lights set up yet. This preview shows what the lights would do.")
                    Spacer()
                    Stepper("\(settings.previewCount) \(settings.previewCount == 1 ? "light" : "lights")",
                            value: $settings.previewCount, in: 1...12)
                        .font(.caption)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private func hueControls(_ hue: HueOutput) -> some View {
        let areas = hub.hueAreas[hue.config.id] ?? []
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Area", selection: Binding(get: { hue.config.areaID ?? "" }, set: { id in
                    guard let i = settings.hueBridges.firstIndex(where: { $0.id == hue.config.id }) else { return }
                    settings.hueBridges[i].areaID = id.isEmpty ? nil : id
                    settings.hueBridges[i].areaName = areas.first { $0.id == id }?.name
                })) {
                    if hue.config.areaID == nil { Text("Choose an area…").tag("") }
                    ForEach(areas) { Text($0.name).tag($0.id) }
                }
                .frame(maxWidth: 260)
                Button("Refresh") { hue.refresh() }
                Spacer()
                Button("Identify") { hub.identify(hue) }
                Button("Remove") { removing = hue.id }
            }
            .controlSize(.small)
            if areas.isEmpty {
                caption("Create an Entertainment area in the Hue app (Settings › Entertainment areas) and place your lights in it. Barbeat uses those positions for left and right.")
            }
        }
    }

    @ViewBuilder
    private func artNetControls(_ output: ArtNetOutput) -> some View {
        let id = output.device.id
        HStack {
            Spacer()
            Button(editing == id ? "Done" : "Edit") { editing = editing == id ? nil : id }
            Button("Identify") { hub.identify(output) }
            Button("Remove") { removing = output.id }
        }
        .controlSize(.small)
        if editing == id, let device = binding(for: id) {
            ArtNetEditor(device: device)
        }
    }

    // MARK: - Adding devices

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { toggleAdding(.hue) } label: { Label("Add Hue Bridge", systemImage: "plus") }
                Button { toggleAdding(.artNet) } label: { Label("Add Art-Net Device", systemImage: "plus") }
            }
            switch adding {
            case .hue: addHue
            case .artNet: addArtNet
            case nil: EmptyView()
            }
        }
    }

    private func toggleAdding(_ kind: Adding) {
        adding = adding == kind ? nil : kind
        if adding == .hue {
            pairing.cancel()
            pairing.search()
        }
    }

    private var addHue: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch pairing.step {
            case .pressButton(let left):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Press the round button on top of your Hue Bridge").font(.callout.weight(.semibold))
                    Spacer()
                    Text("\(left) s").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button("Cancel") { pairing.cancel() }.controlSize(.small)
            case .finishing:
                HStack { ProgressView().controlSize(.small); Text("Paired. Reading entertainment areas…") }
            case .done(let message):
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Done") { adding = nil; pairing.cancel() }.controlSize(.small)
            case .failed(let message):
                problem(message)
                bridgeList
            case .idle:
                bridgeList
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
    }

    private var bridgeList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Bridges on your network").font(.callout.weight(.semibold))
                if pairing.searching { ProgressView().controlSize(.small) }
            }
            if pairing.found.isEmpty && !pairing.searching {
                caption("None found. Make sure the Mac is on the same network, or type the bridge's IP address (in the Hue app: Settings › My Hue system › Bridge).")
            }
            ForEach(pairing.found) { bridge in
                HStack {
                    Text(bridge.name)
                    Text(bridge.host).foregroundStyle(.secondary).font(.caption)
                    Spacer()
                    Button("Pair") { pairing.pair(host: bridge.host) }.controlSize(.small)
                }
            }
            HStack {
                TextField("IP address, e.g. 192.168.1.20", text: $manualHost)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { pairing.pair(host: manualHost) }
                Button("Pair") { pairing.pair(host: manualHost) }
                    .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Search Again") { pairing.search() }
                    .disabled(pairing.searching)
            }
            .controlSize(.small)
            caption("Barbeat plays on a Hue Entertainment area (rooms and zones can't be streamed to). If you don't have one, create it in the Hue app under Settings › Entertainment areas.")
        }
    }

    private var addArtNet: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Find Nodes") {
                    findingNodes = true
                    nodeMessage = nil
                    ArtNet.findNodes { found, error in
                        findingNodes = false
                        nodes = found
                        nodeMessage = error ?? (found.isEmpty ? "No Art-Net nodes answered. You can still add one by its IP address." : nil)
                    }
                }
                .disabled(findingNodes)
                if findingNodes { ProgressView().controlSize(.small) }
                Spacer()
                Button("Add by IP Address") { addArtNetDevice(ArtNetDevice()) }
            }
            .controlSize(.small)
            if let nodeMessage { caption(nodeMessage) }
            ForEach(nodes) { node in
                HStack {
                    Text(node.name)
                    Text("\(node.ip) · universe \(node.universe)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add") {
                        addArtNetDevice(ArtNetDevice(name: node.name, host: node.ip, universe: node.universe))
                    }
                    .controlSize(.small)
                }
            }
            caption("WLED: in WLED, open Config › Sync Interfaces, turn on Receive UDP realtime, set the type to Art-Net and match the start universe. After Barbeat stops, WLED goes back to its own effect.")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
    }

    private func addArtNetDevice(_ device: ArtNetDevice) {
        settings.artNetDevices.append(device)
        editing = device.id
        adding = nil
    }

    private func remove(_ id: String) {
        if id.hasPrefix("hue:") {
            settings.hueBridges.removeAll { "hue:\($0.id)" == id }
        } else {
            settings.artNetDevices.removeAll { "artnet:\($0.id.uuidString)" == id }
        }
        removing = nil
    }

    private func binding(for id: UUID) -> Binding<ArtNetDevice>? {
        guard let device = settings.artNetDevices.first(where: { $0.id == id }) else { return nil }
        return Binding(get: { settings.artNetDevices.first { $0.id == id } ?? device }, set: { value in
            if let i = settings.artNetDevices.firstIndex(where: { $0.id == id }), settings.artNetDevices[i] != value {
                settings.artNetDevices[i] = value
            }
        })
    }

    // MARK: - Bits

    private func icon(for output: LightOutput) -> String {
        switch output.kind {
        case "Hue": return "lightbulb.fill"
        case "Art-Net": return "cable.connector"
        default: return "eye"
        }
    }

    private func modeDetail(_ mode: LightMode, count: Int) -> String {
        switch mode {
        case .auto, .pulse: return "every light pulses together"
        case .stereo: return "left and right channels"
        case .bands:
            return count == 3 ? "low · mid · high, left to right" : "bass on the left → treble on the right"
        case .mirror: return app.layout == .stereo ? "copies the menu bar, bass in the middle" : "copies the menu bar, bass on the left"
        }
    }

    private func shortState(_ state: LightOutputState) -> String {
        switch state {
        case .failed: return "Problem"
        case .needsSetup: return "Needs setup"
        default: return state.text
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func problem(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil,
                        text: String, help: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout)
                .frame(width: 110, alignment: .leading)
            if let step {
                Slider(value: value, in: range, step: step)
            } else {
                Slider(value: value, in: range)
            }
            Text(text)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
        .help(help)
    }
}

/// An Art-Net device's settings.
private struct ArtNetEditor: View {
    @Binding var device: ArtNetDevice
    @State private var detecting = false
    @State private var wledNote: String?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                label("Name")
                TextField("Name", text: $device.name).textFieldStyle(.roundedBorder)
            }
            GridRow {
                label("IP address")
                HStack {
                    TextField("192.168.1.30", text: $device.host).textFieldStyle(.roundedBorder)
                    Button("Detect WLED") { detect() }
                        .disabled(detecting || device.host.trimmingCharacters(in: .whitespaces).isEmpty)
                    if detecting { ProgressView().controlSize(.small) }
                }
            }
            if let wledNote {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Text(wledNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            GridRow {
                label("Universe")
                HStack {
                    TextField("0", value: $device.universe, format: .number).textFieldStyle(.roundedBorder).frame(width: 70)
                    Text("Start address").font(.callout)
                    TextField("1", value: $device.startAddress, format: .number).textFieldStyle(.roundedBorder).frame(width: 60)
                }
            }
            GridRow {
                label("Fixture")
                Picker("Fixture", selection: $device.profile) {
                    ForEach(FixtureProfile.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
            }
            GridRow {
                label("Lights")
                HStack {
                    TextField("1", value: $device.count, format: .number).textFieldStyle(.roundedBorder).frame(width: 70)
                    Text("fixtures or LEDs, \(device.profile.channels) channels each").font(.caption).foregroundStyle(.secondary)
                }
            }
            GridRow {
                label("")
                HStack(spacing: 16) {
                    Toggle("First light on the right", isOn: $device.reversed)
                    Toggle("Gamma correction", isOn: $device.gamma)
                        .help("LEDs are linear; correction makes dim colors look right. Turn off if colors look washed out.")
                }
                .toggleStyle(.checkbox)
            }
            GridRow {
                label("When Barbeat stops")
                VStack(alignment: .leading, spacing: 4) {
                    Picker("When Barbeat stops", selection: $device.onStop) {
                        ForEach(ArtNetStopAction.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                    Text(device.onStop.help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .controlSize(.small)
        .onChange(of: device) { _, value in
            let fixed = clamped(value)
            if fixed != value { device = fixed }
        }
    }

    private func clamped(_ value: ArtNetDevice) -> ArtNetDevice {
        var d = value
        d.universe = min(0x7FFF, max(0, d.universe))
        d.startAddress = min(512, max(1, d.startAddress))
        d.count = min(2048, max(1, d.count))
        return d
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.callout).frame(width: 120, alignment: .leading)
    }

    private func detect() {
        detecting = true
        wledNote = nil
        let host = device.host
        Task { @MainActor in
            let info = await ArtNet.detectWLED(host: host)
            detecting = false
            guard let info else {
                wledNote = "No WLED found at \(host). Other Art-Net devices work too: fill in the details by hand."
                return
            }
            device.name = info.name
            device.count = max(1, info.ledCount)
            device.profile = info.rgbw ? .rgbw : .rgb
            if let universe = info.universe { device.universe = universe }
            if let address = info.startAddress { device.startAddress = max(1, address) }
            var notes = ["Found WLED “\(info.name)” with \(info.ledCount) LEDs."]
            if info.receiverOn == false { notes.append("Turn on Receive UDP realtime in WLED (Config › Sync Interfaces).") }
            if info.usesArtNet == false { notes.append("WLED is set to E1.31: change its realtime type to Art-Net.") }
            wledNote = notes.joined(separator: " ")
        }
    }
}

/// What each light is doing right now: dots for a few lights, a continuous strip for many.
struct LightStrip: View {
    let colors: [LightColor]
    let count: Int

    var body: some View {
        Canvas { context, size in
            let n = max(1, colors.isEmpty ? count : colors.count)
            func fill(_ i: Int) -> Color {
                guard i < colors.count else { return Color.primary.opacity(0.08) }
                let c = colors[i].shown
                return Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z))
            }
            if n > 24 {
                let w = size.width / CGFloat(n)
                for i in 0..<n {
                    context.fill(Path(CGRect(x: CGFloat(i) * w, y: 0, width: w + 0.5, height: size.height)), with: .color(fill(i)))
                }
                context.stroke(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3),
                               with: .color(.primary.opacity(0.15)), lineWidth: 1)
            } else {
                let d = min(size.height, size.width / CGFloat(n) - 6)
                let spacing = (size.width - d * CGFloat(n)) / CGFloat(max(1, n - 1))
                for i in 0..<n {
                    let x = n == 1 ? (size.width - d) / 2 : CGFloat(i) * (d + spacing)
                    let rect = CGRect(x: x, y: (size.height - d) / 2, width: d, height: d)
                    if i < colors.count {
                        let glow = rect.insetBy(dx: -3, dy: -3)
                        context.fill(Path(ellipseIn: glow), with: .color(fill(i).opacity(0.35 * Double(colors[i].brightness))))
                    }
                    context.fill(Path(ellipseIn: rect), with: .color(fill(i)))
                    context.stroke(Path(ellipseIn: rect), with: .color(.primary.opacity(0.15)), lineWidth: 1)
                }
            }
        }
    }
}
