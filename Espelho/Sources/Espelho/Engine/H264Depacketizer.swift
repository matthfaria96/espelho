import Foundation

/// One video frame: its NAL units and the RTP timestamp (90 kHz) given by the sender.
public struct AccessUnit: Equatable {
    public var timestamp: UInt32
    public var nals: [Data]
    public init(timestamp: UInt32, nals: [Data]) {
        self.timestamp = timestamp
        self.nals = nals
    }
}

/// Rebuilds H.264 access units (one frame = list of NAL units) from RTP packets (RFC 6184).
/// Handles single NAL units, STAP-A aggregates and FU-A fragments.
public struct H264Depacketizer {
    private var nals: [Data] = []
    private var fragment: Data?
    private var timestamp: UInt32?
    private var lastSequence: UInt16?

    public init() {}

    /// Feeds one RTP packet; returns the access units completed by it (usually zero or one).
    public mutating func push(_ packet: Data) -> [AccessUnit] {
        let p = packet
        let base = p.startIndex
        guard p.count >= 12, p[base] >> 6 == 2 else { return [] }

        let hasPadding = p[base] & 0x20 != 0
        let hasExtension = p[base] & 0x10 != 0
        let csrcCount = Int(p[base] & 0x0F)
        let marker = p[base + 1] & 0x80 != 0
        let sequence = UInt16(p[base + 2]) << 8 | UInt16(p[base + 3])
        let ts = UInt32(p[base + 4]) << 24 | UInt32(p[base + 5]) << 16 | UInt32(p[base + 6]) << 8 | UInt32(p[base + 7])

        var start = base + 12 + 4 * csrcCount
        if hasExtension {
            guard p.endIndex >= start + 4 else { return [] }
            let words = Int(p[start + 2]) << 8 | Int(p[start + 3])
            start += 4 + 4 * words
        }
        var end = p.endIndex
        if hasPadding, let pad = p.last { end -= Int(pad) }
        guard end > start else { return [] }

        var completed: [AccessUnit] = []

        // A new timestamp means a new frame, even if the previous one never got its marker bit.
        if let current = timestamp, current != ts, !nals.isEmpty {
            completed.append(AccessUnit(timestamp: current, nals: nals))
            nals = []
            fragment = nil
        }
        if let last = lastSequence, sequence != last &+ 1 {
            fragment = nil // a fragment lost a piece: drop it rather than decode garbage
        }
        lastSequence = sequence
        timestamp = ts

        let payload = p[start..<end]
        let header = payload[payload.startIndex]
        switch header & 0x1F {
        case 1...23:
            nals.append(Data(payload))
        case 24: // STAP-A
            var i = payload.startIndex + 1
            while i + 2 <= payload.endIndex {
                let size = Int(payload[i]) << 8 | Int(payload[i + 1])
                i += 2
                guard size > 0, i + size <= payload.endIndex else { break }
                nals.append(Data(payload[i..<(i + size)]))
                i += size
            }
        case 28: // FU-A
            guard payload.count >= 2 else { break }
            let fu = payload[payload.startIndex + 1]
            let body = payload[(payload.startIndex + 2)...]
            if fu & 0x80 != 0 {
                var d = Data(capacity: body.count * 8)
                d.append((header & 0xE0) | (fu & 0x1F))
                d.append(contentsOf: body)
                fragment = d
            } else if fragment != nil {
                fragment!.append(contentsOf: body)
            }
            if fu & 0x40 != 0, let f = fragment {
                nals.append(f)
                fragment = nil
            }
        default:
            break
        }

        if marker, !nals.isEmpty {
            completed.append(AccessUnit(timestamp: ts, nals: nals))
            nals = []
            fragment = nil
        }
        return completed
    }
}

/// Splits an RFC 4571 stream (2-byte big-endian length + RTP packet) into packets.
public struct RFC4571Framer {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data, packet: (Data) -> Void) {
        buffer.append(data)
        var offset = buffer.startIndex
        while buffer.endIndex - offset >= 2 {
            let length = Int(buffer[offset]) << 8 | Int(buffer[offset + 1])
            guard buffer.endIndex - offset - 2 >= length else { break }
            packet(buffer.subdata(in: (offset + 2)..<(offset + 2 + length)))
            offset += 2 + length
        }
        if offset > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<offset)
        }
    }

    public mutating func reset() { buffer.removeAll(keepingCapacity: true) }
}
