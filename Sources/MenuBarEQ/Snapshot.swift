import AppKit
import SwiftUI

/// Developer aid: `MenuBarEQ --demo --snapshot out.png` saves what the first overlay
/// is drawing (over a dark background) after a few seconds, then quits.
/// With edge glow on, the edge windows are saved next to it as out-edge1/2/3/4.png (left, right, bottom, top).
/// `--snapshot-clear` leaves the background transparent (for laying the pictures over a screenshot).
extension OverlayController {
    func saveSnapshot(to path: String) {
        guard let view = windowsForSnapshot.first?.eqView else {
            print("snapshot: no overlay window")
            return
        }
        write(view, to: path)
        let base = (path as NSString).deletingPathExtension
        for window in edgeWindowsForSnapshot.prefix(4) {
            write(window.eqView, to: "\(base)-edge\(window.eqView.edge).png")
        }
    }

    private func write(_ view: EQView, to path: String) {
        guard let frame = view.snapshotImage() else {
            print("snapshot: nothing to capture (Metal unavailable?)")
            return
        }
        let width = frame.width, height = frame.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if !CommandLine.arguments.contains("--snapshot-clear") {
            ctx.setFillColor(CGColor(srgbRed: 0.13, green: 0.15, blue: 0.22, alpha: 1))
            ctx.fill(rect)
        }
        ctx.setAlpha(CGFloat(Settings.shared.opacity))
        ctx.draw(frame, in: rect)

        guard let image = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("snapshot: wrote \(path)")
        } catch {
            print("snapshot: \(error.localizedDescription)")
        }
    }
}

/// Developer aid: `Barbeat --panel-snapshot panel.png` renders the settings panel offscreen and saves it,
/// so layout can be checked without opening the menu. With Custom colors chosen, the first color is selected.
enum PanelSnapshot {
    static var isRequested: Bool { CommandLine.arguments.contains("--panel-snapshot") }

    static func save(to path: String) {
        save(SettingsView(settings: .shared, status: .shared), width: nil, to: path)
    }

    /// The bitmap to draw into: the screen's density, or `--snapshot-scale`'s.
    private static func imageRep(for view: NSView) -> NSBitmapImageRep? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot-scale"), i + 1 < args.count, let scale = Double(args[i + 1]) else {
            return view.bitmapImageRepForCachingDisplay(in: view.bounds)
        }
        let size = view.bounds.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = size
        return rep
    }

    /// Renders any view offscreen (`--lights-snapshot` uses this for the Lights window).
    static func save<V: View>(_ view: V, width: CGFloat?, to path: String) {
        let host = NSHostingView(rootView: view.frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI settle (the panel measures its own height once).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let size = host.fittingSize
            window.setContentSize(size)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            guard let rep = Self.imageRep(for: host) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                print("panel snapshot: wrote \(path) (\(Int(size.width))×\(Int(size.height)) pt)")
            }
        }
    }
}
