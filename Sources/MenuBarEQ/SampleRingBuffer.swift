import Foundation
import CoreAudio
import os

/// Thread-safe stereo sample store. The audio thread writes, the render loop reads the latest window.
final class SampleRingBuffer {
    private let capacity: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var writeIndex = 0
    private var lastWrite: UInt64 = 0
    /// Every sample ever written, so a reader can pick up exactly where it left off.
    private var written: UInt64 = 0

    init(capacity: Int) {
        self.capacity = capacity
        left = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right = .allocate(capacity: capacity)
        right.initialize(repeating: 0, count: capacity)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        left.deallocate()
        right.deallocate()
        lock.deallocate()
    }

    /// Takes the first two channels of any Float32 layout (interleaved or one buffer per channel)
    /// as left and right. Mono input goes to both sides.
    func write(_ bufferList: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        var frames = Int.max
        var lPtr: UnsafeMutablePointer<Float>?, lStride = 0
        var rPtr: UnsafeMutablePointer<Float>?, rStride = 0
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self), buffer.mNumberChannels > 0 else { continue }
            let channels = Int(buffer.mNumberChannels)
            frames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            for channel in 0..<channels {
                if lPtr == nil {
                    lPtr = data + channel; lStride = channels
                } else if rPtr == nil {
                    rPtr = data + channel; rStride = channels
                }
            }
        }
        guard let l = lPtr, frames > 0, frames != .max else { return }
        let r = rPtr ?? l
        if rPtr == nil { rStride = lStride }

        os_unfair_lock_lock(lock)
        for frame in 0..<frames {
            left[writeIndex] = l[frame * lStride]
            right[writeIndex] = r[frame * rStride]
            writeIndex = (writeIndex + 1) % capacity
        }
        written &+= UInt64(frames)
        lastWrite = mach_absolute_time()
        os_unfair_lock_unlock(lock)
    }

    /// Writes separate left/right sample arrays (demo mode and the tuning harness).
    func write(left l: UnsafePointer<Float>, right r: UnsafePointer<Float>, count: Int) {
        os_unfair_lock_lock(lock)
        for i in 0..<count {
            left[writeIndex] = l[i]
            right[writeIndex] = r[i]
            writeIndex = (writeIndex + 1) % capacity
        }
        written &+= UInt64(max(0, count))
        lastWrite = mach_absolute_time()
        os_unfair_lock_unlock(lock)
    }

    /// Copies the most recent `count` samples of each channel, oldest first.
    func readLatest(_ count: Int, left outL: UnsafeMutablePointer<Float>, right outR: UnsafeMutablePointer<Float>) {
        precondition(count <= capacity)
        os_unfair_lock_lock(lock)
        var start = writeIndex - count
        if start < 0 { start += capacity }
        let firstPart = min(count, capacity - start)
        outL.update(from: left + start, count: firstPart)
        outR.update(from: right + start, count: firstPart)
        if firstPart < count {
            (outL + firstPart).update(from: left, count: count - firstPart)
            (outR + firstPart).update(from: right, count: count - firstPart)
        }
        os_unfair_lock_unlock(lock)
    }

    /// Copies the mono mix of everything written since `cursor` (at most `limit` samples, and never more than the
    /// buffer holds) and moves the cursor on. Returns how many were copied and the stream position of the first.
    func readNew(since cursor: inout UInt64, into out: UnsafeMutablePointer<Float>, limit: Int) -> (count: Int, position: UInt64) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let available = written &- cursor
        let count = Int(min(available, UInt64(min(limit, capacity))))
        cursor = written
        guard count > 0 else { return (0, written) }
        var index = writeIndex - count
        if index < 0 { index += capacity }
        for i in 0..<count {
            out[i] = (left[index] + right[index]) * 0.5
            index += 1
            if index == capacity { index = 0 }
        }
        return (count, written &- UInt64(count))
    }

    /// Seconds since the audio thread last delivered samples.
    var secondsSinceLastWrite: Double {
        os_unfair_lock_lock(lock)
        let last = lastWrite
        os_unfair_lock_unlock(lock)
        guard last != 0 else { return .infinity }
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let elapsed = mach_absolute_time() &- last
        return Double(elapsed) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }
}
