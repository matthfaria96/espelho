import Foundation

/// Decides *when* each frame should appear so motion keeps the rhythm it had on the device,
/// even when Wi-Fi delivers frames in bursts (jitter buffer).
///
/// Every frame carries the sender's capture time (RTP, 90 kHz). The pacer learns the fastest
/// observed path from device to Mac (`offset`), measures how late frames arrive on top of that
/// (`jitter`) and schedules frames at `capture time + offset + delay`, where `delay` adapts to the
/// network: small on a clean network, larger when it stutters. Everything in seconds.
public struct FramePacer {
    /// Bounds for the extra delay added to absorb jitter.
    public var minimumDelay = 0.012
    public var maximumDelay = 0.120

    public private(set) var delay: Double
    private var offset: Double?
    private var mediaTime = 0.0
    private var lastTimestamp: UInt32?
    private var lastArrival = 0.0
    private var lastScheduled = -Double.infinity
    private var jitterPeak = 0.0

    public init() { delay = 0.030 }

    public mutating func reset() {
        self = FramePacer(minimumDelay: minimumDelay, maximumDelay: maximumDelay)
    }

    private init(minimumDelay: Double, maximumDelay: Double) {
        self.init()
        self.minimumDelay = minimumDelay
        self.maximumDelay = maximumDelay
    }

    /// Host-clock time at which the frame should be shown.
    public mutating func schedule(rtpTimestamp: UInt32, arrival: Double) -> Double {
        // Unwrap the 32-bit RTP clock into a continuous media time.
        if let last = lastTimestamp {
            let step = Double(Int32(bitPattern: rtpTimestamp &- last)) / 90_000
            let elapsed = arrival - lastArrival
            // A jump that doesn't match the wall clock (new stream, sender reset): re-anchor.
            if step < -0.5 || step - elapsed > 1.0 || elapsed - step > 3.0 {
                offset = nil
                lastScheduled = -Double.infinity
            } else {
                mediaTime += step
            }
        }
        lastTimestamp = rtpTimestamp
        lastArrival = arrival

        let transit = arrival - mediaTime
        if let current = offset {
            // Follow the fastest path down immediately; drift upwards slowly (clocks drift apart).
            offset = min(transit, current + 0.0005)
        } else {
            offset = transit
        }
        let jitter = transit - offset!

        // Peak-hold of recent jitter, decaying over a few seconds.
        jitterPeak = max(jitter, jitterPeak * 0.995)
        let target = min(max(jitterPeak * 1.15 + 0.004, minimumDelay), maximumDelay)
        // Grow fast (avoid stutter now), shrink gently (avoid visible speed-ups).
        delay += (target - delay) * (target > delay ? 0.3 : 0.02)

        var time = mediaTime + offset! + delay
        if time < arrival { time = arrival }             // never wait on a frame that is already late
        if time <= lastScheduled { time = lastScheduled + 0.0005 } // keep order
        lastScheduled = time
        return time
    }
}
