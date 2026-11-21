// Offline check for voice detection: plays a song file through VoiceDetector at 60 fps (silently) and prints
// a timeline: the sound-only voice signal, the recognizer's singing/speech confidence, the gated level,
// words per second and the pitch, plus how long the per-frame work takes.
//
//   swiftc -O -o .build/tune-voice Sources/MenuBarEQ/VoiceDetector.swift Sources/MenuBarEQ/SampleRingBuffer.swift \
//       scripts/tune-voice/main.swift
//   .build/tune-voice "path/to/song.mp3" [singing|speech|both] [seconds=90] [step=0.5] [--dump frames.csv]
//
// --dump writes one line per frame for score.py, which compares them with Demucs vocal references (see README).
// Environment variables V_<name>=value change VoiceDetector.Tuning, e.g. V_gateAt=0.75 V_confident=2.6.

import AVFoundation

var args = CommandLine.arguments
var dumpPath: String?
if let i = args.firstIndex(of: "--dump"), i + 1 < args.count {
    dumpPath = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
let path = args[1]
let target = VoiceTarget(rawValue: args.count > 2 ? args[2] : "singing") ?? .singing
let limit = args.count > 3 ? Double(args[3])! : 90
let step = args.count > 4 ? Double(args[4])! : 0.5

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
let voice = VoiceDetector()
voice.synchronous = true
voice.target = target

// Tuning overrides.
var tuning = VoiceDetector.Tuning()
func set<T>(_ name: String, _ key: WritableKeyPath<VoiceDetector.Tuning, T>, _ parse: (String) -> T?) {
    if let text = ProcessInfo.processInfo.environment["V_" + name], let value = parse(text) { tuning[keyPath: key] = value }
}
set("recognizerWindow", \.recognizerWindow, Double.init)
set("recognizerOverlap", \.recognizerOverlap, Double.init)
set("gateAt", \.gateAt, Float.init)
set("levelRange", \.levelRange, Float.init)
set("levelDecay", \.levelDecay, Float.init)
set("levelRelease", \.levelRelease, Float.init)
set("wordRise", \.wordRise, Float.init)
set("wordFloor", \.wordFloor, Float.init)
set("flatten", \.flatten, Float.init)
set("lowestNote", \.lowestNote, Float.init)
set("highestNote", \.highestNote, Float.init)
set("harmonics", \.harmonics, Int.init)
set("harmonicWeight", \.harmonicWeight, Float.init)
set("lowestHarmonicHz", \.lowestHarmonicHz, Float.init)
set("confident", \.confident, Float.init)
set("noteMedian", \.noteMedian, Int.init)
set("octaveSnap", \.octaveSnap) { $0 == "1" }
set("noteSmoothing", \.noteSmoothing, Float.init)
voice.tuning = tuning

let hop = Int(format.sampleRate / 60)

var pos = 0, frame = 0
var words = 0, wordsInStep = 0
var nextPrint = 0.0
var work: Double = 0
var rawMax: Float = 0, levelMax: Float = 0
var dump = "level,raw,word,pitch,presence,singing,speech,salience,candidate\n"
func bar(_ v: Float) -> String { String(repeating: "█", count: Int(v * 10 + 0.5)).padding(toLength: 10, withPad: "·", startingAt: 0) }
if dumpPath == nil { print(" time   raw         level       sing  talk  words  pitch") }
while pos + hop < frames {
    ring.write(left: left + pos, right: right + pos, count: hop)
    pos += hop
    let t0 = DispatchTime.now().uptimeNanoseconds
    voice.update(ring: ring, sampleRate: format.sampleRate, dt: 1 / 60)
    work += Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
    frame += 1
    if dumpPath != nil {
        let heard = voice.heard
        func note(_ n: Float?) -> String { n.map { String(format: "%.2f", $0) } ?? "nan" }
        dump += String(format: "%.4f,%.4f,%.4f,%@,%.4f,%.3f,%.3f,%.3f,%@\n", voice.level, voice.raw, voice.word, note(voice.pitch),
                       voice.presence, heard.singing, heard.speech, voice.salience, note(voice.candidate))
        continue
    }
    if voice.word > 0 { words += 1; wordsInStep += 1 }
    rawMax = max(rawMax, voice.raw); levelMax = max(levelMax, voice.level)
    let time = Double(frame) / 60
    if time >= nextPrint {
        nextPrint += step
        let heard = voice.heard
        let note = voice.pitch.map { String(format: "%5.1f", $0) } ?? "    -"
        print(String(format: "%5.1fs  %@  %@  %.2f  %.2f  %3d   %@", time, bar(rawMax), bar(levelMax), heard.singing, heard.speech,
                     wordsInStep, note))
        rawMax = 0; levelMax = 0; wordsInStep = 0
    }
}
let seconds = Double(frame) / 60
if let dumpPath {
    try! dump.write(toFile: dumpPath, atomically: true, encoding: .utf8)
    print(String(format: "%.0f s, %.3f ms per frame", seconds, work / Double(frame) * 1000))
    exit(0)
}
print(String(format: "%.0f s, %d words (%.1f/s), %.3f ms per frame including the recognizer (%.2f%% of one core)",
             seconds, words, Double(words) / seconds, work / Double(frame) * 1000, work / seconds * 100))
