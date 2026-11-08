import Foundation

// Android mirroring speaks the scrcpy protocol (https://github.com/Genymobile/scrcpy, v5).
// The scrcpy server runs on the phone (started over adb) and connects back to the Mac with
// up to three sockets, in this order: video, audio, control.

/// Incremental parser for a scrcpy media socket (video or audio).
///
/// Video: [64-byte device name] [4-byte codec id] [12-byte session header] then packets.
/// Audio: [4-byte codec id] then packets.
/// Every packet: 8-byte PTS+flags, 4-byte size, payload. A header whose top bit is set is a
/// session header instead (new video size, e.g. after a rotation).
public struct ScrcpyStreamParser {
    public enum Event: Equatable {
        case deviceName(String)
        case codec(UInt32)
        /// The stream was turned off by the device (0) or failed to configure (1).
        case disabled(error: Bool)
        case session(width: Int, height: Int)
        case packet(pts: UInt64, config: Bool, keyFrame: Bool, data: Data)
    }

    public static let codecH264: UInt32 = 0x6832_3634 // "h264"
    public static let codecRaw: UInt32 = 0x0072_6177  // "raw"

    private enum State { case deviceName, codec, header, payload(UInt64, Int), done }
    private var state: State
    private var buffer = Data()

    public init(expectsDeviceName: Bool) {
        state = expectsDeviceName ? .deviceName : .codec
    }

    public mutating func append(_ data: Data, _ emit: (Event) -> Void) {
        buffer.append(data)
        while true {
            switch state {
            case .done:
                buffer.removeAll()
                return
            case .deviceName:
                guard let bytes = take(64) else { return }
                let name = bytes.prefix { $0 != 0 }
                emit(.deviceName(String(decoding: name, as: UTF8.self)))
                state = .codec
            case .codec:
                guard let bytes = take(4) else { return }
                let id = bytes.readUInt32(at: 0)
                if id == 0 || id == 1 {
                    emit(.disabled(error: id == 1))
                    state = .done
                } else {
                    emit(.codec(id))
                    state = .header
                }
            case .header:
                guard let header = take(12) else { return }
                if header[header.startIndex] & 0x80 != 0 {
                    emit(.session(width: Int(header.readUInt32(at: 4)), height: Int(header.readUInt32(at: 8))))
                } else {
                    state = .payload(header.readUInt64(at: 0), Int(header.readUInt32(at: 8)))
                }
            case .payload(let ptsFlags, let size):
                guard let payload = take(size) else { return }
                let config = ptsFlags & (1 << 62) != 0
                let key = ptsFlags & (1 << 61) != 0
                emit(.packet(pts: ptsFlags & ((1 << 61) - 1), config: config, keyFrame: key, data: payload))
                state = .header
            }
        }
    }

    private mutating func take(_ count: Int) -> Data? {
        guard buffer.count >= count else { return nil }
        let chunk = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        if buffer.isEmpty { buffer = Data() } // keep indices at zero
        return chunk
    }
}

/// Turns scrcpy H.264 packets (Annex B) into access units for `H264Renderer`.
public struct ScrcpyVideoAssembler {
    private var pendingConfig: [Data] = []

    public init() {}

    public mutating func push(pts: UInt64, config: Bool, data: Data) -> AccessUnit? {
        let nals = Self.splitAnnexB(data)
        if config {
            // SPS/PPS come alone; they belong to the next frame.
            pendingConfig = nals
            return nil
        }
        defer { pendingConfig = [] }
        // MediaCodec timestamps are in µs; the renderer paces with a 90 kHz clock.
        let ts = UInt32(truncatingIfNeeded: pts &* 9 / 100)
        return AccessUnit(timestamp: ts, nals: pendingConfig + nals)
    }

    /// Splits an Annex B byte stream on 00 00 01 / 00 00 00 01 start codes.
    public static func splitAnnexB(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(code: Int, payload: Int)] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    starts.append((i, i + 3)); i += 3; continue
                }
                if i + 3 < bytes.count, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                    starts.append((i, i + 4)); i += 4; continue
                }
            }
            i += 1
        }
        if starts.isEmpty { return bytes.isEmpty ? [] : [data] }
        var nals: [Data] = []
        for (k, start) in starts.enumerated() {
            let end = k + 1 < starts.count ? starts[k + 1].code : bytes.count
            if end > start.payload { nals.append(Data(bytes[start.payload..<end])) }
        }
        return nals
    }
}

/// Messages the Mac sends on the control socket.
public enum ScrcpyControl {
    public enum TouchAction: UInt8 { case down = 0, up = 1, move = 2 }

    /// Behaves like a finger on the touchscreen (taps, swipes, long presses).
    public static let fingerPointer: UInt64 = 0xFFFF_FFFF_FFFF_FFFE

    /// x, y in video pixels; width, height = current video size (the device ignores stale sizes).
    public static func touch(_ action: TouchAction, x: Int, y: Int, width: Int, height: Int,
                             pointer: UInt64 = fingerPointer) -> Data {
        var d = Data([2, action.rawValue])
        d.appendBE(pointer)
        d.appendPosition(x: x, y: y, width: width, height: height)
        d.appendBE(UInt16(action == .up ? 0 : 0xFFFF)) // pressure
        d.appendBE(UInt32(0)) // action button
        d.appendBE(UInt32(0)) // buttons
        return d
    }

    /// Scroll amounts in [-16, 16] (positive v = up / content moves down).
    public static func scroll(x: Int, y: Int, width: Int, height: Int, h: Double, v: Double) -> Data {
        var d = Data([3])
        d.appendPosition(x: x, y: y, width: width, height: height)
        func fixed(_ value: Double) -> UInt16 {
            let norm = min(max(value / 16, -1), 1)
            return UInt16(bitPattern: Int16(max(min(norm * 32768, 32767), -32768)))
        }
        d.appendBE(fixed(h))
        d.appendBE(fixed(v))
        d.appendBE(UInt32(0))
        return d
    }

    /// One key press (down + up) with an Android key code.
    public static func keyPress(_ keycode: UInt32, meta: UInt32 = 0) -> Data {
        key(down: true, keycode, meta: meta) + key(down: false, keycode, meta: meta)
    }

    public static func key(down: Bool, _ keycode: UInt32, meta: UInt32 = 0) -> Data {
        var d = Data([0, down ? 0 : 1])
        d.appendBE(keycode)
        d.appendBE(UInt32(0)) // repeat
        d.appendBE(meta)
        return d
    }

    /// Types text as if from a keyboard (max 300 bytes per message).
    public static func text(_ string: String) -> Data {
        var utf8: [UInt8] = []
        for character in string { // whole characters only
            let bytes = Array(character.utf8)
            if utf8.count + bytes.count > 300 { break }
            utf8 += bytes
        }
        var d = Data([1])
        d.appendBE(UInt32(utf8.count))
        d.append(contentsOf: utf8)
        return d
    }

    /// Back, or wakes the screen if it is off.
    public static func backOrScreenOn() -> Data { Data([4, 0, 4, 1]) }

    /// Puts text on the device clipboard; `paste` also pastes it into the focused field.
    public static func setClipboard(_ string: String, paste: Bool, sequence: UInt64 = 0) -> Data {
        var d = Data([9])
        d.appendBE(sequence)
        d.append(paste ? 1 : 0)
        let utf8 = Array(string.utf8.prefix(100_000))
        d.appendBE(UInt32(utf8.count))
        d.append(contentsOf: utf8)
        return d
    }

    /// Turns the phone's own screen off (or on) while mirroring continues.
    public static func setDisplayPower(on: Bool) -> Data { Data([10, on ? 1 : 0]) }

    public static func rotate() -> Data { Data([11]) }

    public enum Key {
        public static let home: UInt32 = 3
        public static let back: UInt32 = 4
        public static let up: UInt32 = 19
        public static let down: UInt32 = 20
        public static let left: UInt32 = 21
        public static let right: UInt32 = 22
        public static let volumeUp: UInt32 = 24
        public static let volumeDown: UInt32 = 25
        public static let power: UInt32 = 26
        public static let tab: UInt32 = 61
        public static let enter: UInt32 = 66
        public static let delete: UInt32 = 67
        public static let pageUp: UInt32 = 92
        public static let pageDown: UInt32 = 93
        public static let forwardDelete: UInt32 = 112
        public static let moveHome: UInt32 = 122
        public static let moveEnd: UInt32 = 123
        public static let appSwitch: UInt32 = 187
    }
}

// MARK: - Byte helpers

extension Data {
    func readUInt32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }

    func readUInt64(at offset: Int) -> UInt64 {
        UInt64(readUInt32(at: offset)) << 32 | UInt64(readUInt32(at: offset + 4))
    }

    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    mutating func appendPosition(x: Int, y: Int, width: Int, height: Int) {
        appendBE(Int32(clamping: x))
        appendBE(Int32(clamping: y))
        appendBE(UInt16(clamping: width))
        appendBE(UInt16(clamping: height))
    }
}

/// Parsing helpers for adb's text output.
public enum ADBText {
    public struct Device: Equatable, Identifiable, Sendable {
        public var serial: String
        public var state: String          // "device", "unauthorized", "offline"…
        public var model: String?
        public var id: String { serial }
        public var isWireless: Bool { serial.contains("._adb-tls-connect.") || serial.contains(":") }
        public init(serial: String, state: String, model: String?) {
            self.serial = serial; self.state = state; self.model = model
        }
    }

    /// `adb devices -l`
    public static func devices(_ output: String) -> [Device] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2, !line.hasPrefix("List of"), !line.hasPrefix("*") else { return nil }
            let model = parts.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") }
            return Device(serial: parts[0], state: parts[1], model: model)
        }
    }

    public struct Service: Equatable, Sendable {
        public var name: String
        public var type: String
        public var address: String
        public init(name: String, type: String, address: String) {
            self.name = name; self.type = type; self.address = address
        }
    }

    /// The same services seen by several finders (macOS's Bonjour, adb's own mDNS): one per name
    /// and type, the first list winning. Types compare without the final dot ("_tcp." = "_tcp").
    public static func merge(_ lists: [Service]...) -> [Service] {
        var seen = Set<String>()
        return lists.joined().filter { service in
            let type = service.type.hasSuffix(".") ? String(service.type.dropLast()) : service.type
            return seen.insert(service.name + "\t" + type).inserted
        }
    }

    /// `adb shell ip route`: the phone's Wi-Fi address ("... dev wlan0 ... src 192.168.0.20").
    public static func wifiAddress(fromIpRoute output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.split(separator: " ").map(String.init) }
        let preferred = lines.filter { $0.contains { $0.hasPrefix("wlan") } } + lines
        for tokens in preferred {
            if let i = tokens.firstIndex(of: "src"), i + 1 < tokens.count, tokens[i + 1].split(separator: ".").count == 4 {
                return tokens[i + 1]
            }
        }
        return nil
    }

    /// `adb mdns services`: "<name>\t<type>\t<ip:port>" per line.
    public static func services(_ output: String) -> [Service] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 3, let type = parts.first(where: { $0.hasPrefix("_adb") }),
                  let address = parts.last, address.contains(":") else { return nil }
            return Service(name: parts[0], type: type, address: address)
        }
    }
}
