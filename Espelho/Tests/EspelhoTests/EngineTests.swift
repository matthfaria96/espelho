import Foundation
import Testing
@testable import EspelhoEngine

private func rtp(seq: UInt16, ts: UInt32, marker: Bool, payload: [UInt8]) -> Data {
    var d = Data([0x80, (marker ? 0x80 : 0) | 96, UInt8(seq >> 8), UInt8(seq & 0xFF),
                  UInt8(ts >> 24), UInt8((ts >> 16) & 0xFF), UInt8((ts >> 8) & 0xFF), UInt8(ts & 0xFF),
                  0, 0, 0, 1])
    d.append(contentsOf: payload)
    return d
}

@Test func singleNalWithMarkerCompletesFrame() {
    var dp = H264Depacketizer()
    let out = dp.push(rtp(seq: 1, ts: 100, marker: true, payload: [0x41, 1, 2, 3]))
    #expect(out == [AccessUnit(timestamp: 100, nals: [Data([0x41, 1, 2, 3])])])
}

@Test func stapAAndFuAReassemble() {
    var dp = H264Depacketizer()
    // STAP-A with SPS (2 bytes) and PPS (2 bytes)
    #expect(dp.push(rtp(seq: 1, ts: 9, marker: false, payload: [0x78, 0, 2, 0x67, 0xAA, 0, 2, 0x68, 0xBB])).isEmpty)
    // IDR (type 5, NRI 3) split in three FU-A packets
    #expect(dp.push(rtp(seq: 2, ts: 9, marker: false, payload: [0x7C, 0x85, 1, 2])).isEmpty)
    #expect(dp.push(rtp(seq: 3, ts: 9, marker: false, payload: [0x7C, 0x05, 3])).isEmpty)
    let out = dp.push(rtp(seq: 4, ts: 9, marker: true, payload: [0x7C, 0x45, 4, 5]))
    #expect(out == [AccessUnit(timestamp: 9, nals: [Data([0x67, 0xAA]), Data([0x68, 0xBB]), Data([0x65, 1, 2, 3, 4, 5])])])
}

@Test func lostFragmentIsDropped() {
    var dp = H264Depacketizer()
    _ = dp.push(rtp(seq: 1, ts: 5, marker: false, payload: [0x7C, 0x81, 1]))
    // seq 2 missing
    let out = dp.push(rtp(seq: 3, ts: 5, marker: true, payload: [0x7C, 0x41, 3]))
    #expect(out.isEmpty)
}

@Test func timestampChangeFlushesFrameWithoutMarker() {
    var dp = H264Depacketizer()
    _ = dp.push(rtp(seq: 1, ts: 1, marker: false, payload: [0x41, 9]))
    let out = dp.push(rtp(seq: 2, ts: 2, marker: true, payload: [0x41, 8]))
    #expect(out == [AccessUnit(timestamp: 1, nals: [Data([0x41, 9])]), AccessUnit(timestamp: 2, nals: [Data([0x41, 8])])])
}

@Test func framerSplitsAcrossChunks() {
    var framer = RFC4571Framer()
    var packets: [Data] = []
    framer.append(Data([0, 3, 1, 2])) { packets.append($0) }
    #expect(packets.isEmpty)
    framer.append(Data([3, 0, 1, 9])) { packets.append($0) }
    #expect(packets == [Data([1, 2, 3]), Data([9])])
}

@Test func parsesEvents() {
    #expect(UxPlayEvent.parse("@@PT ready") == .ready)
    #expect(UxPlayEvent.parse("@@PT conns 0") == .connections(0))
    #expect(UxPlayEvent.parse("@@PT client iPhone17,3\tiPhone de Matheus") == .client(model: "iPhone17,3", name: "iPhone de Matheus"))
    #expect(UxPlayEvent.parse("@@PT video 264 1080 1920") == .video(codec: 264, width: 1080, height: 1920))
    #expect(UxPlayEvent.parse("@@PT pin 0420") == .pin("0420"))
    #expect(UxPlayEvent.parse("Initialized server socket(s)") == nil)
}

// MARK: Frame pacing

/// 60 fps frames whose arrival is delayed by `jitter(i)` seconds on top of a fixed 5 ms transit.
private func run(frames: Int, jitter: (Int) -> Double) -> (shown: [Double], pacer: FramePacer) {
    var pacer = FramePacer()
    var shown: [Double] = []
    for i in 0..<frames {
        let capture = Double(i) / 60
        let arrival = 100 + capture + 0.005 + jitter(i)
        let rtp = UInt32(truncatingIfNeeded: 4_000_000_000 &+ UInt32(i * 1500)) // crosses the 32-bit wrap
        let t = pacer.schedule(rtpTimestamp: rtp, arrival: arrival)
        #expect(t >= arrival - 1e-9) // never earlier than it exists
        shown.append(t)
    }
    return (shown, pacer)
}

@Test func steadyNetworkKeepsDelayMinimal() {
    let (shown, pacer) = run(frames: 600) { _ in 0 }
    #expect(pacer.delay < 0.02)
    let gaps = zip(shown.dropFirst(), shown).map { $0 - $1 }
    #expect(gaps.allSatisfy { abs($0 - 1.0 / 60) < 0.001 })
}

@Test func burstyNetworkIsEvenedOut() {
    // Every 4th frame is held up 40 ms, then the rest rush in: the classic Wi-Fi stutter.
    let (shown, pacer) = run(frames: 900) { i in i % 4 == 0 ? 0.040 : Double(i % 4) * 0.002 }
    #expect(pacer.delay > 0.035 && pacer.delay <= 0.120)
    let gaps = zip(shown.dropFirst(), shown).map { $0 - $1 }.suffix(300)
    // Once adapted, frames come out at the device's rhythm.
    #expect(gaps.allSatisfy { abs($0 - 1.0 / 60) < 0.002 })
}

@Test func outputStaysInOrderAndReanchorsOnJump() {
    var pacer = FramePacer()
    var last = -Double.infinity
    for i in 0..<120 {
        let t = pacer.schedule(rtpTimestamp: UInt32(i * 1500), arrival: 10 + Double(i) / 60)
        #expect(t > last)
        last = t
    }
    // Sender restarts its clock: no frozen frames waiting for a time that never comes.
    let t = pacer.schedule(rtpTimestamp: 77, arrival: 13)
    #expect(t >= 13 && t < 13.2)
}

// MARK: Android (scrcpy protocol)

private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
private func be64(_ v: UInt64) -> [UInt8] { be32(UInt32(v >> 32)) + be32(UInt32(v & 0xFFFF_FFFF)) }

@Test func scrcpyVideoStreamParsesInAnyChunking() {
    var bytes: [UInt8] = Array("Pixel 9".utf8) + Array(repeating: 0, count: 64 - 7)
    bytes += be32(ScrcpyStreamParser.codecH264)
    bytes += [0x80, 0, 0, 0] + be32(1080) + be32(2400)                       // session
    bytes += be64(1 << 62) + be32(8) + [0, 0, 0, 1, 0x67, 1, 0, 0]             // config
    bytes += be64((1 << 61) | 16_666) + be32(6) + [0, 0, 1, 0x65, 9, 9]         // key frame
    bytes += [0x80, 0, 0, 1] + be32(2400) + be32(1080)                          // rotation
    for chunk in [1, 5, 13, 1000] {
        var parser = ScrcpyStreamParser(expectsDeviceName: true)
        var events: [ScrcpyStreamParser.Event] = []
        var i = 0
        while i < bytes.count {
            parser.append(Data(bytes[i..<min(i + chunk, bytes.count)])) { events.append($0) }
            i += chunk
        }
        #expect(events == [
            .deviceName("Pixel 9"),
            .codec(ScrcpyStreamParser.codecH264),
            .session(width: 1080, height: 2400),
            .packet(pts: 0, config: true, keyFrame: false, data: Data([0, 0, 0, 1, 0x67, 1, 0, 0])),
            .packet(pts: 16_666, config: false, keyFrame: true, data: Data([0, 0, 1, 0x65, 9, 9])),
            .session(width: 2400, height: 1080),
        ])
    }
}

@Test func scrcpyDisabledAudio() {
    var parser = ScrcpyStreamParser(expectsDeviceName: false)
    var events: [ScrcpyStreamParser.Event] = []
    parser.append(Data([0, 0, 0, 0, 1, 2, 3])) { events.append($0) }
    #expect(events == [.disabled(error: false)])
}

@Test func annexBSplitAndAssembly() {
    var assembler = ScrcpyVideoAssembler()
    #expect(assembler.push(pts: 0, config: true, data: Data([0, 0, 0, 1, 0x67, 0xAA, 0, 0, 1, 0x68, 0xBB])) == nil)
    let unit = assembler.push(pts: 1_000_000, config: false, data: Data([0, 0, 0, 1, 0x65, 1, 0, 2]))
    #expect(unit == AccessUnit(timestamp: 90_000, nals: [Data([0x67, 0xAA]), Data([0x68, 0xBB]), Data([0x65, 1, 0, 2])]))
    #expect(assembler.push(pts: 2_000_000, config: false, data: Data([0, 0, 1, 0x41, 7]))?.nals == [Data([0x41, 7])])
}

@Test func scrcpyControlMessagesMatchTheWireFormat() {
    let touch = ScrcpyControl.touch(.down, x: 100, y: 200, width: 1080, height: 2400)
    #expect(touch.count == 32)
    #expect(Array(touch) == [2, 0] + be64(0xFFFF_FFFF_FFFF_FFFE) + be32(100) + be32(200)
            + [0x04, 0x38, 0x09, 0x60] + [0xFF, 0xFF] + be32(0) + be32(0))
    #expect(ScrcpyControl.scroll(x: 1, y: 2, width: 3, height: 4, h: 0, v: 16).count == 21)
    #expect(Array(ScrcpyControl.key(down: true, 4)) == [0, 0] + be32(4) + be32(0) + be32(0))
    #expect(Array(ScrcpyControl.text("olá")) == [1] + be32(4) + Array("olá".utf8))
    #expect(ScrcpyControl.text(String(repeating: "é", count: 200)).count == 1 + 4 + 300)
    #expect(Array(ScrcpyControl.setClipboard("a", paste: true)) == [9] + be64(0) + [1] + be32(1) + [0x61])
}

@Test func parsesAdbOutput() {
    let devices = ADBText.devices("""
    List of devices attached
    R58N12ABCDE            device usb:1-1 product:a52q model:SM_A525M device:a52q transport_id:1
    adb-R58N12ABCDE-Xy1z._adb-tls-connect._tcp device product:a52q model:SM_A525M transport_id:2
    0123456789ABCDEF       unauthorized usb:1-2 transport_id:3
    """)
    #expect(devices.count == 3)
    #expect(devices[0] == ADBText.Device(serial: "R58N12ABCDE", state: "device", model: "SM A525M"))
    #expect(devices[1].isWireless && !devices[0].isWireless)
    #expect(devices[2].state == "unauthorized")
    let services = ADBText.services("""
    List of discovered mdns services
    espelho-ab12cd\t_adb-tls-pairing._tcp\t192.168.0.20:37115
    adb-R58N12ABCDE-Xy1z\t_adb-tls-connect._tcp\t192.168.0.20:41231
    """)
    #expect(services == [
        ADBText.Service(name: "espelho-ab12cd", type: "_adb-tls-pairing._tcp", address: "192.168.0.20:37115"),
        ADBText.Service(name: "adb-R58N12ABCDE-Xy1z", type: "_adb-tls-connect._tcp", address: "192.168.0.20:41231"),
    ])
}

@Test func mergesServicesFromBothFinders() {
    let bonjour = [ADBText.Service(name: "espelho-ab12cd", type: "_adb-tls-pairing._tcp.", address: "192.168.0.20:37115")]
    let adb = [
        ADBText.Service(name: "espelho-ab12cd", type: "_adb-tls-pairing._tcp", address: "192.168.0.20:37115"),
        ADBText.Service(name: "adb-R58N12ABCDE-Xy1z", type: "_adb-tls-connect._tcp", address: "192.168.0.20:41231"),
    ]
    #expect(ADBText.merge(bonjour, adb) == [bonjour[0], adb[1]])
    #expect(ADBText.merge([], adb) == adb)
}

@Test func findsPhoneWifiAddress() {
    #expect(ADBText.wifiAddress(fromIpRoute: """
    10.0.0.0/8 dev rmnet0 proto kernel scope link src 10.20.30.40
    192.168.0.0/24 dev wlan0 proto kernel scope link src 192.168.0.20
    """) == "192.168.0.20")
    #expect(ADBText.wifiAddress(fromIpRoute: "") == nil)
}
