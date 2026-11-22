// Barbeat · Ichiro Ashihara (@IchiroA) · MIT License
import SwiftUI
import AppKit

/// Barbeat's menu bar icon: four little bars that move with the music (bass to treble), or sit still.
final class MenuBarIcon: ObservableObject {
    static let shared = MenuBarIcon()

    @Published private(set) var image = MenuBarIcon.draw([0.45, 0.75, 1, 0.6])
    @Published var animated: Bool {
        didSet {
            UserDefaults.standard.set(animated, forKey: Self.key)
            if !animated { settle() }
        }
    }

    private static let key = "menuBarIcon.animated"
    private static let still: [Float] = [0.45, 0.75, 1, 0.6]
    /// A point and a half of the 13-point bars.
    private static let smallestMove: Float = 1.5 / 13
    private static let redrawsPerSecond: Double = {
        if let i = CommandLine.arguments.firstIndex(of: "--icon-rate"), i + 1 < CommandLine.arguments.count,
           let rate = Double(CommandLine.arguments[i + 1]) { return max(1, min(30, rate)) }
        return 6
    }()
    private var shown: [Float] = MenuBarIcon.still
    private var last: Double = 0
    private var resting = true
    /// `--verbose`: how many times the icon was redrawn lately (each redraw costs macOS a snapshot of the menu bar
    /// item, about as much as a frame of the visuals).
    private let verbose = CommandLine.arguments.contains("--verbose")
    private var redraws = 0
    private var countSince: Double = 0

    private init() {
        UserDefaults.standard.register(defaults: [Self.key: true])
        animated = UserDefaults.standard.bool(forKey: Self.key)
    }

    /// Called by the render loop. Redraws at most 6 times a second while music plays, and only when a bar has
    /// moved by a point and a half or more: every change makes macOS re-render the menu bar item, which is costly.
    func update(levels: [Float], playing: Bool, now: Double) {
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            if !resting { settle() }
            return
        }
        guard now - last >= 1.0 / Self.redrawsPerSecond else { return }
        last = now
        guard playing, levels.count >= 8 else {
            if !resting { settle() }
            return
        }
        // Four groups, bass to treble (the low end is where most of the motion is, so it gets narrower groups).
        let n = levels.count
        let edges = [0, n / 10, n / 4, n / 2, n]
        var target = [Float]()
        for g in 0..<4 {
            let slice = levels[edges[g]..<max(edges[g] + 1, edges[g + 1])]
            target.append(min(1, max(0.12, slice.max() ?? 0)))
        }
        var next = shown
        var changed = false
        for i in 0..<4 {
            next[i] = shown[i] + (target[i] - shown[i]) * 0.8
            if abs(next[i] - shown[i]) >= Self.smallestMove { changed = true }
        }
        resting = false
        guard changed else { return }
        shown = next
        image = Self.draw(shown)
        if verbose {
            redraws += 1
            if now - countSince >= 5 {
                print(String(format: "icon: %d redraws in %.0f s", redraws, now - countSince))
                redraws = 0
                countSince = now
            }
        }
    }

    private func settle() {
        resting = true
        shown = Self.still
        image = Self.draw(Self.still)
    }

    /// A template image, so macOS draws it in the menu bar's own color. Drawn once into a bitmap (2x): macOS
    /// draws the icon several times per change (the menu bar item and its snapshots), and a bitmap is the
    /// cheapest thing for it to draw.
    static func draw(_ heights: [Float]) -> NSImage {
        let size = NSSize(width: 16, height: 14), scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return NSImage(size: size) }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let bar: CGFloat = 2.6, gap: CGFloat = 1.6
        let total = CGFloat(heights.count) * bar + CGFloat(heights.count - 1) * gap
        var x = (size.width - total) / 2
        NSColor.black.setFill()
        for h in heights {
            let height = max(2, CGFloat(h) * (size.height - 1))
            NSBezierPath(roundedRect: NSRect(x: x, y: 0.5, width: bar, height: height), xRadius: 1, yRadius: 1).fill()
            x += bar + gap
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }
}

struct MenuBarIconView: View {
    @ObservedObject var icon: MenuBarIcon

    var body: some View {
        Image(nsImage: icon.image)
    }
}
