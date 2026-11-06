import AVFoundation
import CoreImage
import CoreMedia

/// Turns H.264 access units into frames on an AVSampleBufferDisplayLayer.
/// Decoding is done in hardware by the layer; every frame is shown as soon as it is decoded.
public final class H264Renderer: @unchecked Sendable {
    public let displayLayer: AVSampleBufferDisplayLayer = {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        return layer
    }()

    /// Main queue: the first frame of a session reached the screen.
    public var onFirstFrame: (() -> Void)?
    /// Main queue: the visible size of the video changed (rotation, new device).
    public var onVideoSize: ((CGSize) -> Void)?

    private var format: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var awaitingKeyframe = true
    private var droppedWhileWaiting = 0
    private var hasDisplayed = false
    private var lastSize: CGSize = .zero

    private let lock = NSLock()
    private var frameCount = 0
    private var resetRequested = false
    private var smoothFlag = true
    private var pacer = FramePacer()

    public init() {
        // Present against the Mac's host clock so frames can be scheduled ahead of time.
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                        sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        if let timebase {
            CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(timebase, rate: 1)
            displayLayer.controlTimebase = timebase
        }
    }

    /// Thread-safe. true: frames keep the device's rhythm (absorbs Wi-Fi jitter, adds a few ms).
    /// false: every frame is shown the instant it arrives (lowest delay).
    public var smooth: Bool {
        get { lock.withLock { smoothFlag } }
        set { lock.withLock { smoothFlag = newValue } }
    }

    /// Thread-safe. Current extra delay used to smooth playback, in seconds (0 when not smoothing).
    public private(set) var pacingDelay: Double {
        get { lock.withLock { pacingDelayValue } }
        set { lock.withLock { pacingDelayValue = newValue } }
    }
    private var pacingDelayValue = 0.0

    /// Thread-safe. The next frame starts a fresh session.
    public func reset() {
        lock.withLock { resetRequested = true }
    }

    /// Thread-safe. Frames shown since the previous call.
    public func takeFrameCount() -> Int {
        lock.withLock {
            defer { frameCount = 0 }
            return frameCount
        }
    }

    /// Thread-safe. The frame currently on screen, as an image.
    public func snapshot() -> CGImage? {
        guard let pixels = displayLayer.sampleBufferRenderer.displayedPixelBuffer() else { return nil }
        let image = CIImage(cvPixelBuffer: pixels)
        return CIContext().createCGImage(image, from: image.extent)
    }

    /// Call from a single serial queue. `arrival` is the host-clock time the frame was received.
    public func decode(_ unit: AccessUnit, arrival: Double) {
        let nals = unit.nals
        if lock.withLock({ defer { resetRequested = false }; return resetRequested }) {
            pacer.reset()
            format = nil
            sps = nil
            pps = nil
            awaitingKeyframe = true
            droppedWhileWaiting = 0
            hasDisplayed = false
            lastSize = .zero
            displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }

        var slices: [Data] = []
        var isKeyframe = false
        var newSPS: Data?
        var newPPS: Data?
        for nal in nals {
            guard let header = nal.first else { continue }
            switch header & 0x1F {
            case 7: newSPS = nal
            case 8: newPPS = nal
            case 5: isKeyframe = true; slices.append(nal)
            case 1: slices.append(nal)
            default: break
            }
        }
        if newSPS != nil || newPPS != nil {
            let s = newSPS ?? sps
            let p = newPPS ?? pps
            if let s, let p, s != sps || p != pps {
                updateFormat(sps: s, pps: p)
            }
        }
        guard let format, !slices.isEmpty else { return }

        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            awaitingKeyframe = true
        }
        if awaitingKeyframe {
            // AirPlay rarely repeats keyframes. If none shows up, decode anyway: the picture
            // heals itself within a second instead of staying frozen.
            if !isKeyframe {
                droppedWhileWaiting += 1
                if droppedWhileWaiting < 90 { return }
            }
            awaitingKeyframe = false
            droppedWhileWaiting = 0
        }

        let presentation: Double?
        if smooth {
            presentation = pacer.schedule(rtpTimestamp: unit.timestamp, arrival: arrival)
            pacingDelay = pacer.delay
        } else {
            presentation = nil
            pacingDelay = 0
        }
        guard let sample = Self.makeSample(slices: slices, format: format, presentationTime: presentation) else { return }
        renderer.enqueue(sample)
        lock.withLock { frameCount += 1 }

        if !hasDisplayed {
            hasDisplayed = true
            DispatchQueue.main.async { [weak self] in self?.onFirstFrame?() }
        }
        let size = CMVideoFormatDescriptionGetPresentationDimensions(
            format, usePixelAspectRatio: true, useCleanAperture: true)
        if size != lastSize {
            lastSize = size
            DispatchQueue.main.async { [weak self] in self?.onVideoSize?(size) }
        }
    }

    private func updateFormat(sps: Data, pps: Data) {
        var newFormat: CMFormatDescription?
        let status = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &newFormat)
            }
        }
        guard status == noErr, let newFormat else { return }
        self.sps = sps
        self.pps = pps
        if let format, CMFormatDescriptionEqual(format, otherFormatDescription: newFormat) { return }
        format = newFormat
    }

    /// Annex-B NAL units -> one AVCC sample (4-byte big-endian lengths).
    /// `presentationTime` nil = show immediately.
    static func makeSample(slices: [Data], format: CMFormatDescription, presentationTime: Double?) -> CMSampleBuffer? {
        let length = slices.reduce(0) { $0 + 4 + $1.count }
        var avcc = Data(capacity: length)
        for nal in slices {
            var size = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &size) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: length, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
            let block else { return nil }
        let copied = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: presentationTime.map { CMTime(seconds: $0, preferredTimescale: 1_000_000_000) }
                                            ?? CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sampleSize = length
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr,
            let sample else { return nil }

        if presentationTime == nil,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
