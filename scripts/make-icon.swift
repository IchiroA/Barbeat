// Draws the app icon (stereo LED EQ split around a notch) and writes Resources/AppIcon.icns.
//   swift scripts/make-icon.swift
import AppKit

let colors: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [   // position, r, g, b (Classic palette)
    (0, 0.10, 0.85, 0.30), (0.55, 0.45, 0.95, 0.20), (0.78, 1.00, 0.85, 0.10), (1, 1.00, 0.22, 0.15),
]
func classic(_ t: CGFloat) -> CGColor {
    var prev = colors[0]
    for stop in colors.dropFirst() {
        if t <= stop.0 {
            let f = (t - prev.0) / (stop.0 - prev.0)
            return CGColor(srgbRed: prev.1 + (stop.1 - prev.1) * f, green: prev.2 + (stop.2 - prev.2) * f,
                           blue: prev.3 + (stop.3 - prev.3) * f, alpha: 1)
        }
        prev = stop
    }
    return CGColor(srgbRed: prev.1, green: prev.2, blue: prev.3, alpha: 1)
}

func drawIcon(_ ctx: CGContext) {
    // Everything is laid out on a 1024 canvas (origin bottom-left).
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Background: deep navy gradient with a soft drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(tilePath)
    ctx.setFillColor(CGColor(srgbRed: 0.07, green: 0.08, blue: 0.12, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                        colors: [CGColor(srgbRed: 0.05, green: 0.06, blue: 0.10, alpha: 1),
                                 CGColor(srgbRed: 0.13, green: 0.15, blue: 0.24, alpha: 1)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])

    // The menu bar strip along the top, with the notch in the middle.
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06))
    ctx.fill(CGRect(x: 100, y: 840, width: 824, height: 84))
    let notch = CGMutablePath()
    notch.addRoundedRect(in: CGRect(x: 412, y: 820, width: 200, height: 140), cornerWidth: 34, cornerHeight: 34)
    ctx.addPath(notch)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()

    // LED bars: left channel left of the notch, right channel right; bass hugs the middle.
    let left: [CGFloat] = [0.92, 0.74, 0.86, 0.55, 0.66, 0.38]   // from the center outward
    let right: [CGFloat] = [0.84, 0.97, 0.62, 0.72, 0.44, 0.52]
    let peaks: [Int: CGFloat] = [1: 0.86, 3: 0.68, 7: 1.0, 9: 0.83]
    let baseline: CGFloat = 196, maxHeight: CGFloat = 600
    let segment: CGFloat = 24, gap: CGFloat = 9, rows = Int(maxHeight / (segment + gap))
    let barWidth: CGFloat = 40, slot: CGFloat = 50
    var bars: [(x: CGFloat, level: CGFloat, peak: CGFloat?)] = []
    for i in 0..<6 {
        bars.append((x: 452 - CGFloat(i + 1) * slot + (slot - barWidth) / 2, level: left[i], peak: peaks[i]))
        bars.append((x: 572 + CGFloat(i) * slot + (slot - barWidth) / 2, level: right[i], peak: peaks[i + 6]))
    }
    ctx.setShadow(offset: .zero, blur: 26, color: CGColor(srgbRed: 0.2, green: 0.95, blue: 0.4, alpha: 0.45))
    for bar in bars {
        let lit = Int((bar.level * CGFloat(rows)).rounded())
        for row in 0..<lit {
            ctx.setFillColor(classic((CGFloat(row) + 0.5) / CGFloat(rows)))
            let rect = CGRect(x: bar.x, y: baseline + CGFloat(row) * (segment + gap), width: barWidth, height: segment)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.fillPath()
        }
        if let peak = bar.peak {
            let row = min(rows - 1, Int((peak * CGFloat(rows)).rounded()) + 1)
            let rect = CGRect(x: bar.x, y: baseline + CGFloat(row) * (segment + gap), width: barWidth, height: segment)
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0.95, blue: 0.85, alpha: 0.95))
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.fillPath()
        }
    }
    ctx.restoreGState()

    // A thin highlight around the edge.
    ctx.addPath(tilePath)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12))
    ctx.setLineWidth(3)
    ctx.strokePath()
}

func png(size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(ctx)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! png(size: 1024).write(to: root.appendingPathComponent("Resources/AppIcon-1024.png"))
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
