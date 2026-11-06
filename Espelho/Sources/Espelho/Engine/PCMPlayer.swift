import AVFoundation

/// Plays the Android's sound: 48 kHz stereo 16-bit PCM arriving in network-sized chunks.
/// A small ring buffer absorbs Wi-Fi jitter; if it fills up (clock drift, a hiccup), the
/// oldest audio is dropped so the sound never drifts behind the picture.
public final class PCMPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode!
    private let lock = NSLock()
    private var ring: [Float]
    private var readIndex = 0
    private var count = 0
    private var started = false
    private var primed = false

    private static let rate = 48_000.0
    private static let startLevel = Int(rate * 0.06) * 2   // begin after 60 ms
    private static let maxLevel = Int(rate * 0.22) * 2     // never more than 220 ms behind
    private static let trimLevel = Int(rate * 0.08) * 2

    public init() {
        ring = Array(repeating: 0, count: Int(Self.rate) * 2) // 1 s of interleaved stereo
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2)!
        source = AVAudioSourceNode(format: format) { [unowned self] _, _, frames, buffers in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            let left = list[0].mData!.assumingMemoryBound(to: Float.self)
            let right = list[1].mData!.assumingMemoryBound(to: Float.self)
            self.render(left: left, right: right, frames: Int(frames))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
    }

    public func start() {
        lock.withLock { readIndex = 0; count = 0; primed = false }
        guard !started else { return }
        do {
            try engine.start()
            started = true
        } catch {
            started = false
        }
    }

    public func stop() {
        guard started else { return }
        engine.stop()
        started = false
    }

    /// Interleaved little-endian Int16 stereo.
    public func enqueue(_ data: Data) {
        let samples = data.count / 2
        guard samples > 0 else { return }
        lock.withLock {
            data.withUnsafeBytes { raw in
                let capacity = ring.count
                for i in 0..<samples {
                    let value = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                    let write = (readIndex + count) % capacity
                    ring[write] = Float(value) / 32768
                    if count < capacity { count += 1 } else { readIndex = (readIndex + 1) % capacity }
                }
            }
            if count > Self.maxLevel {
                let drop = (count - Self.trimLevel) & ~1
                readIndex = (readIndex + drop) % ring.count
                count -= drop
            }
            if !primed, count >= Self.startLevel { primed = true }
        }
    }

    private func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        lock.withLock {
            for f in 0..<frames {
                if primed, count >= 2 {
                    left[f] = ring[readIndex]
                    right[f] = ring[(readIndex + 1) % ring.count]
                    readIndex = (readIndex + 2) % ring.count
                    count -= 2
                } else {
                    left[f] = 0
                    right[f] = 0
                    if primed { primed = false } // underrun: refill a little before resuming
                }
            }
        }
    }
}
