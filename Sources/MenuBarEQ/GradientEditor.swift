import SwiftUI

/// The Custom palette's editor: four color blocks, the color direction, a picker for the selected block,
/// Shuffle / From Wallpaper / Reset, and four preset slots.
///
/// The picker is built into the panel on purpose: the system color window steals focus,
/// which closes the menu bar panel.
struct CustomGradientEditor: View {
    @ObservedObject var settings: Settings
    // The panel snapshot (a developer aid) shows the color editor open.
    @State private var selected: Int? = PanelSnapshot.isRequested ? 0 : nil
    @State private var wallpaperFailed = false

    private var gradient: CustomGradient { settings.customGradient }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: gradient.colors.map(\.color), startPoint: .leading, endPoint: .trailing))
                    .frame(height: 8)
                HStack(spacing: 6) {
                    ForEach(0..<CustomGradient.colorCount, id: \.self) { i in
                        ColorBlock(color: gradient.colors[i], selected: selected == i) {
                            selected = selected == i ? nil : i
                        }
                    }
                }
                Text(gradient.byHeight ? "Left to right: bottom of the bars to the top."
                                       : "Left to right: bass to treble.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Direction", selection: $settings.customGradient.byHeight) {
                Text("By frequency").tag(false)
                Text("By bar height").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let i = selected {
                ColorEditor(color: $settings.customGradient.colors[i])
            }

            HStack(spacing: 6) {
                Button {
                    settings.customGradient = .shuffled(byHeight: gradient.byHeight)
                } label: { Label("Shuffle", systemImage: "shuffle") }
                    .help("Random colors that go together")
                Button {
                    if let picked = CustomGradient.fromWallpaper(byHeight: gradient.byHeight) {
                        settings.customGradient = picked
                        wallpaperFailed = false
                    } else {
                        wallpaperFailed = true
                    }
                } label: { Label("Wallpaper", systemImage: "photo") }
                    .help("Pick four colors from your desktop picture")
                Spacer()
                Button("Reset") { settings.customGradient = .default }
                    .help("Back to the starting colors: cyan, blue, violet and pink")
            }
            .controlSize(.small)
            if wallpaperFailed {
                Text("Couldn't find colors in the wallpaper.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Presets").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(0..<Settings.presetSlots, id: \.self) { i in
                        PresetSlot(
                            gradient: settings.savedGradients[i],
                            isCurrent: settings.savedGradients[i] == gradient,
                            load: { if let saved = settings.savedGradients[i] { settings.customGradient = saved } },
                            save: { settings.savedGradients[i] = settings.customGradient },
                            delete: { settings.savedGradients[i] = nil })
                    }
                }
                Text("Click + to save these colors. Right-click a preset to replace or delete it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

private struct ColorBlock: View {
    let color: HSB
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.color)
                .frame(height: 30)
                .frame(maxWidth: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(-3)
                        .opacity(selected ? 1 : 0)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(color.hex)
    }
}

/// Hue, saturation and brightness sliders, quick picks and a hex field for one color.
struct ColorEditor: View {
    @Binding var color: HSB
    @State private var hexText = ""
    @FocusState private var hexFocused: Bool

    private static let quickPicks: [HSB] = [
        0.0, 0.05, 0.1, 0.15, 0.25, 0.36, 0.47, 0.52,
        0.56, 0.61, 0.67, 0.72, 0.78, 0.85, 0.93,
    ].map { HSB(h: $0, s: 0.9, b: 1) } + [HSB(h: 0, s: 0, b: 1)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                ForEach(Array(Self.quickPicks.enumerated()), id: \.offset) { _, pick in
                    Button { color = pick } label: {
                        Circle()
                            .fill(pick.color)
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.2)))
                    }
                    .buttonStyle(.plain)
                    .help(pick.hex)
                }
            }

            sliderRow("Hue", value: $color.h,
                      colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { HSB(h: $0, s: 1, b: 1).color })
            sliderRow("Saturation", value: $color.s,
                      colors: [HSB(h: color.h, s: 0, b: color.b).color, HSB(h: color.h, s: 1, b: color.b).color])
            sliderRow("Brightness", value: $color.b,
                      colors: [.black, HSB(h: color.h, s: color.s, b: 1).color])

            HStack(spacing: 8) {
                Text("Hex").font(.caption).foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
                TextField("#RRGGBB", text: $hexText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .frame(width: 84)
                    .focused($hexFocused)
                    .onSubmit(applyHex)
                    .onChange(of: hexFocused) { _, focused in if !focused { applyHex() } }
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.color)
                    .frame(width: 22, height: 18)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.2)))
                Spacer()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .onAppear { hexText = color.hex }
        .onChange(of: color) { _, new in if !hexFocused { hexText = new.hex } }
    }

    private func applyHex() {
        if let parsed = HSB(hex: hexText) {
            if parsed.hex != color.hex { color = parsed }
        }
        hexText = color.hex
    }

    private func sliderRow(_ title: String, value: Binding<Double>, colors: [Color]) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            GradientSlider(value: value, colors: colors)
        }
    }
}

/// A slider whose track shows the colors it moves through.
struct GradientSlider: View {
    @Binding var value: Double
    let colors: [Color]
    private let knob: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let travel = max(1, geo.size.width - knob)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(height: 10)
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15)))
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.3)))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .offset(x: CGFloat(min(1, max(0, value))) * travel)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                value = Double(min(1, max(0, (drag.location.x - knob / 2) / travel)))
            })
        }
        .frame(height: 18)
    }
}

private struct PresetSlot: View {
    let gradient: CustomGradient?
    let isCurrent: Bool
    let load: () -> Void
    let save: () -> Void
    let delete: () -> Void

    var body: some View {
        Button(action: gradient == nil ? save : load) {
            Group {
                if let gradient {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(LinearGradient(colors: gradient.colors.map(\.color), startPoint: .leading, endPoint: .trailing))
                } else {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .overlay(Image(systemName: "plus").font(.caption).foregroundStyle(.secondary))
                }
            }
            .frame(height: 24)
            .frame(maxWidth: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.primary.opacity(0.9), lineWidth: 2)
                    .padding(-3)
                    .opacity(isCurrent ? 1 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(gradient == nil ? "Save the current colors here" : "Use this preset")
        .contextMenu {
            if gradient == nil {
                Button("Save Current Colors Here", action: save)
            } else {
                Button("Use This Preset", action: load)
                Button("Replace with Current Colors", action: save)
                Divider()
                Button("Delete Preset", role: .destructive, action: delete)
            }
        }
    }
}
