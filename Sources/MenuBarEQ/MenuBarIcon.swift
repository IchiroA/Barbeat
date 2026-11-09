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
    private var shown: [Float] = MenuBarIcon.still
    private var last: Double = 0
    private var resting = true

    private init() {
        UserDefaults.standard.register(defaults: [Self.key: true])
        animated = UserDefaults.standard.bool(forKey: Self.key)
    }

    /// Called by the render loop. Redraws about 12 times a second while music plays.
    func update(levels: [Float], playing: Bool, now: Double) {
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            if !resting { settle() }
            return
        }
        guard now - last >= 1.0 / 12 else { return }
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
        var changed = false
        for i in 0..<4 {
            let next = shown[i] + (target[i] - shown[i]) * 0.7
            if abs(next - shown[i]) > 0.04 { changed = true }
            shown[i] = next
        }
        resting = false
        if changed { image = Self.draw(shown) }
    }

    private func settle() {
        resting = true
        shown = Self.still
        image = Self.draw(Self.still)
    }

    /// A template image, so macOS draws it in the menu bar's own color.
    static func draw(_ heights: [Float]) -> NSImage {
        let size = NSSize(width: 16, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let bar: CGFloat = 2.6, gap: CGFloat = 1.6
            let total = CGFloat(heights.count) * bar + CGFloat(heights.count - 1) * gap
            var x = (rect.width - total) / 2
            NSColor.black.setFill()
            for h in heights {
                let height = max(2, CGFloat(h) * (rect.height - 1))
                NSBezierPath(roundedRect: NSRect(x: x, y: 0.5, width: bar, height: height), xRadius: 1, yRadius: 1).fill()
                x += bar + gap
            }
            return true
        }
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
