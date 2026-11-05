// Offline tuning harness: plays an audio file through SpectrumAnalyzer at 60 fps (silently)
// and prints bar, VU meter and pulse statistics.
//
//   swiftc -O -o .build/tune Sources/MenuBarEQ/SpectrumAnalyzer.swift Sources/MenuBarEQ/SampleRingBuffer.swift \
//       Sources/MenuBarEQ/Lights/LightShow.swift scripts/tune-analyzer/main.swift
//   .build/tune "path/to/song.mp3" [bands=64] [mono|stereo] [sensitivity dB]

import AVFoundation

let args = CommandLine.arguments
let path = args[1]
let bands = args.count > 2 ? Int(args[2])! : 64
let stereo = args.count > 3 && args[3] == "stereo"
let sensitivity = args.count > 4 ? Float(args[4])! : 0

let file = try! AVAudioFile(forReading: URL(fileURLWithPath: path))
let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: file.processingFormat.sampleRate,
                           channels: file.processingFormat.channelCount, interleaved: false)!
let total = AVAudioFrameCount(min(file.length, Int64(format.sampleRate * 90)))
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total)!
try! file.read(into: buffer, frameCount: total)
let frames = Int(buffer.frameLength)
let left = buffer.floatChannelData![0]
let right = buffer.floatChannelData![min(1, Int(format.channelCount) - 1)]

let ring = SampleRingBuffer(capacity: 1 << 15)
let analyzer = SpectrumAnalyzer()
let step = Int(format.sampleRate / 60)
// Both spectra, as in the app while the lights are on.
let options = AnalyzerOptions(bandCount: bands, sensitivityDb: sensitivity, autoLevel: true, mono: true, stereo: true)

// Lights: Pulse (1 light) and Bands (3 lights) with the default settings, watching how often they flash.
struct FlashMeter {
    var low: Float = 1, sum: Float = 0, frames = 0, bright = 0
    var events: [Double] = []
    var worst = 0
    mutating func add(_ b: Float, at t: Double) {
        sum += b; frames += 1; if b > 0.9 { bright += 1 }
        low = min(low, b)
        // A flash: brightness rising 30 points or more above where it last bottomed out.
        if b - low >= 0.3 {
            events.append(t)
            low = b
        }
        events.removeAll { t - $0 > 1 }
        worst = max(worst, events.count)
    }
    var summary: String {
        String(format: "avg %.2f  >0.9: %d%%  flashes/s max %d", sum / Float(max(1, frames)), bright * 100 / max(1, frames), worst)
    }
}
let pulseShow = LightShow(), bandShow = LightShow()
var pulseMeter = FlashMeter()
var bandMeters = [FlashMeter](repeating: FlashMeter(), count: 3)
var bandLines = ["", "", ""]
var flashTotal = [0, 0, 0]
let palette = LightPalette.neon

var barSum: Float = 0, barTop = 0, barCount = 0
var meterSum: Float = 0, meterTop = 0, meterCount = 0
var pulses: [Float] = [], tones: [Float] = []
var pulseLine = "", meterLine = ""
let spark = Array("▁▂▃▄▅▆▇█")
func sparkChar(_ v: Float) -> Character { spark[min(7, max(0, Int(v * 7.99)))] }

var pos = 0, frame = 0
while pos + step < frames {
    ring.write(left: left + pos, right: right + pos, count: step)
    pos += step
    analyzer.process(ring: ring, sampleRate: format.sampleRate, dt: 1 / 60, options: options)
    frame += 1
    guard frame > 120 else { continue }

    let sets = stereo ? [analyzer.left, analyzer.right] : [analyzer.mid]
    for set in sets {
        for level in set.levels { barSum += level; barCount += 1; if level > 0.9 { barTop += 1 } }
    }
    let pulse = stereo ? (analyzer.left.pulse + analyzer.right.pulse) / 2 : analyzer.mid.pulse
    pulses.append(pulse)
    tones.append(stereo ? analyzer.left.tone : analyzer.mid.tone)
    for m in [analyzer.meterLeft, analyzer.meterRight] { meterSum += m; meterCount += 1; if m > 0.9 { meterTop += 1 } }

    let time = Double(frame) / 60
    let signals = LightSignals(analyzer: analyzer, silence: 0, stereoLayout: stereo)
    let one = pulseShow.frame(slots: LightSlot.row(1), signals: signals, palette: palette, options: .init(), dt: 1 / 60)
    pulseMeter.add(one[0].brightness, at: time)
    let three = bandShow.frame(slots: LightSlot.row(3), signals: signals, palette: palette, options: .init(), dt: 1 / 60)
    for i in 0..<3 {
        let before = bandMeters[i].events.count
        bandMeters[i].add(three[i].brightness, at: time)
        if bandMeters[i].events.count > before { flashTotal[i] += 1 }
    }

    // 4 seconds of timeline starting at 20 s, every other frame.
    if frame >= 1200, frame < 1440, frame % 2 == 0 {
        pulseLine.append(sparkChar(pulse))
        meterLine.append(sparkChar(analyzer.meterLeft))
        for i in 0..<3 { bandLines[i].append(sparkChar(three[i].brightness)) }
    }
}

func pct(_ sorted: [Float], _ p: Double) -> String { String(format: "%.2f", sorted[Int(Double(sorted.count - 1) * p)]) }
let sortedPulse = pulses.sorted(), sortedTone = tones.sorted()
print("bars   avg \(String(format: "%.2f", barSum / Float(barCount)))  >0.9: \(barTop * 100 / barCount)%")
print("meter  avg \(String(format: "%.2f", meterSum / Float(meterCount)))  >0.9: \(meterTop * 100 / meterCount)%")
print("pulse  p10 \(pct(sortedPulse, 0.1))  p50 \(pct(sortedPulse, 0.5))  p90 \(pct(sortedPulse, 0.9))")
print("tone   p10 \(pct(sortedTone, 0.1))  p50 \(pct(sortedTone, 0.5))  p90 \(pct(sortedTone, 0.9))")
print("pulse  20-24s \(pulseLine)")
print("meterL 20-24s \(meterLine)")

let minutes = Double(frame - 120) / 3600
print("light  pulse (1 light)  \(pulseMeter.summary)")
for (i, name) in ["low ", "mid ", "high"].enumerated() {
    print("light  bands \(name)      \(bandMeters[i].summary)  flashes/min \(Int(Double(flashTotal[i]) / minutes))")
}
for (i, name) in ["low ", "mid ", "high"].enumerated() { print("bands  \(name) 20-24s \(bandLines[i])") }
