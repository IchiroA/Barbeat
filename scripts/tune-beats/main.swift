// Offline check for the beat tracker: plays a song through SpectrumAnalyzer and BeatTracker at 60 fps (silently)
// and prints the tempo over time. With the true beat times (one per line, seconds) it also scores the beats:
// how many true beats got a tracker beat within 60 ms, how many tracker beats were extra, and how early or late
// they fell on average. The kick-driven BeatPulse is scored the same way, for comparison.
//
//   swiftc -O -o .build/tune-beats Sources/MenuBarEQ/SpectrumAnalyzer.swift Sources/MenuBarEQ/SampleRingBuffer.swift \
//       Sources/MenuBarEQ/BeatPulseEngine.swift Sources/MenuBarEQ/BeatTracker.swift scripts/tune-beats/main.swift
//   .build/tune-beats song.mp3 [expected BPM or -] [beat times file] [seconds=60] [--fps 30]

import AVFoundation

var args = CommandLine.arguments
var fps = 60.0
if let i = args.firstIndex(of: "--fps"), i + 1 < args.count { fps = Double(args[i + 1])!; args.removeSubrange(i...(i + 1)) }
let path = args[1]
let expected = args.count > 2 ? Float(args[2]) : nil
let truth: [Double] = args.count > 3 && args[3] != "-"
    ? (try! String(contentsOfFile: args[3], encoding: .utf8)).split(whereSeparator: \.isNewline).compactMap { Double($0) } : []
let limit = args.count > 4 ? Double(args[4])! : 60

let file = try! AVAudioFile(forReading: URL(fileURLWithPath: path))
let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: file.processingFormat.sampleRate,
                           channels: file.processingFormat.channelCount, interleaved: false)!
let total = AVAudioFrameCount(min(file.length, Int64(format.sampleRate * limit)))
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total)!
try! file.read(into: buffer, frameCount: total)
let frames = Int(buffer.frameLength)
let left = buffer.floatChannelData![0]
let right = buffer.floatChannelData![min(1, Int(format.channelCount) - 1)]

let ring = SampleRingBuffer(capacity: 1 << 15)
let analyzer = SpectrumAnalyzer()
let tracker = BeatTracker()
let kicks = BeatPulse()
let options = AnalyzerOptions(bandCount: 64, sensitivityDb: 0, autoLevel: true, mono: true, stereo: false)
let hop = Int(format.sampleRate / fps)
let dt = Double(hop) / format.sampleRate

var pos = 0, time = 0.0, nextPrint = 5.0
var trackerBeats: [Double] = [], kickBeats: [Double] = []
var bpms: [Float] = [], confident = 0, counted = 0
var work = 0.0
while pos + hop < frames {
    ring.write(left: left + pos, right: right + pos, count: hop)
    pos += hop
    time += dt
    analyzer.process(ring: ring, sampleRate: format.sampleRate, dt: Float(dt), options: options)
    let t0 = DispatchTime.now().uptimeNanoseconds
    tracker.update(levels: analyzer.mid.levels, playing: analyzer.rms > 0.0005, dt: dt)
    work += Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
    if tracker.isBeat, tracker.confidence >= 0.4 { trackerBeats.append(time) }
    let before = kicks.beats
    _ = kicks.frame(kick: analyzer.mid.kick, intensity: analyzer.mid.pulse, playing: true, reduceMotion: false, dt: dt)
    if kicks.beats > before { kickBeats.append(time) }
    if time > 8 {
        counted += 1
        if tracker.confidence >= 0.4 { confident += 1; bpms.append(tracker.bpm) }
    }
    if time >= nextPrint {
        nextPrint += 5
        print(String(format: "%5.1fs  %6.1f BPM  confidence %.2f  phase %.2f", time, tracker.bpm, tracker.confidence, tracker.phase))
    }
}

func median(_ v: [Float]) -> Float { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
let bpm = median(bpms)
var line = String(format: "tempo %.1f BPM (median while confident after 8 s), confident %d%% of the time", bpm,
                  counted > 0 ? confident * 100 / counted : 0)
if let expected {
    let ratio = bpm / expected
    let verdict = abs(ratio - 1) < 0.04 ? "right" : abs(ratio - 2) < 0.08 ? "double" : abs(ratio - 0.5) < 0.04 ? "half" : "WRONG"
    line += String(format: ", expected %.0f: %@", expected, verdict)
}
print(line)

/// True beats after the warm-up that got a beat within 60 ms; extra beats; mean offset (ms, + = late).
func score(_ found: [Double], name: String) {
    let real = truth.filter { $0 > 8 && $0 < time - 0.5 }
    guard !real.isEmpty else { return }
    let mine = found.filter { $0 > 8 && $0 < time - 0.5 }
    var hits = 0, offsets: [Double] = []
    var used = Set<Int>()
    for b in real {
        if let (i, f) = mine.enumerated().filter({ !used.contains($0.offset) }).min(by: { abs($0.element - b) < abs($1.element - b) }),
           abs(f - b) <= 0.06 {
            hits += 1; used.insert(i); offsets.append(f - b)
        }
    }
    let extra = mine.count - used.count
    let mean = offsets.isEmpty ? 0 : offsets.reduce(0, +) / Double(offsets.count) * 1000
    print(String(format: "%@ beats: %d%% of %d true beats hit, %d extra, mean offset %+.0f ms", name,
                 hits * 100 / real.count, real.count, extra, mean))
}
score(trackerBeats, name: "tracker")
score(kickBeats, name: "kicks  ")
print(String(format: "%.3f ms per frame for the tracker", work / max(1, time * fps) * 1000))
