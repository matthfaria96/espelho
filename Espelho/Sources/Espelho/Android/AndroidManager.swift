import CoreImage
import CoreImage.CIFilterBuiltins
import EspelhoEngine
import SwiftUI

/// Finds Android devices (Wi-Fi or cable), pairs new ones, and reconnects known ones.
@MainActor
final class AndroidManager: ObservableObject {
    static let shared = AndroidManager()

    struct Device: Identifiable, Equatable {
        var serial: String        // adb serial (changes with the connection)
        var state: String
        var hardwareID: String?   // ro.serialno: stable across connections
        var name: String
        var isTablet: Bool
        var isWireless: Bool
        var id: String { serial }
        var isReady: Bool { state == "device" }
        var symbol: String { isTablet ? "ipad" : "smartphone" }
    }

    enum Pairing: Equatable {
        case idle
        case waiting(qr: String)     // QR code shown, waiting for the phone to scan it
        case pairing                 // talking to the phone
        case connecting
        case failed(String)
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var pairing: Pairing = .idle
    @Published var showPairing = false
    /// Serial of the cable-connected device being switched to Wi-Fi.
    @Published private(set) var goingWireless: String?

    /// Whether to look for devices continuously (Android tab open, or known devices exist).
    var wantsDiscovery = false { didSet { if wantsDiscovery != oldValue { updatePolling() } } }

    private var info: [String: (id: String?, name: String, tablet: Bool)] = [:]
    private var pollTask: Task<Void, Never>?
    private var pairingTask: Task<Void, Never>?
    private var pairingName = ""
    private var pairingPassword = ""
    private var serverStarted = false
    private var connectAttempts: [String: Date] = [:]
    /// Devices the user just disconnected: not reconnected automatically until they go away.
    private var dismissed: Set<String> = []

    private init() {
        updatePolling()
    }

    // MARK: Known devices

    static let knownKey = "androidKnownDevices"

    var knownIDs: [String] { UserDefaults.standard.stringArray(forKey: Self.knownKey) ?? [] }

    func remember(_ device: Device) {
        guard let id = device.hardwareID else { return }
        var known = knownIDs
        if !known.contains(id) {
            known.append(id)
            UserDefaults.standard.set(known, forKey: Self.knownKey)
            updatePolling()
        }
    }

    func forgetAll() {
        UserDefaults.standard.removeObject(forKey: Self.knownKey)
        UserDefaults.standard.removeObject(forKey: Self.endpointsKey)
        updatePolling()
    }

    func dismiss(_ device: Device) {
        if let id = device.hardwareID { dismissed.insert(id) }
    }

    // MARK: Discovery

    private func updatePolling() {
        let should = ADB.available && (wantsDiscovery || showPairing || !knownIDs.isEmpty)
        if should, pollTask == nil {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    let fast = self?.wantsDiscovery == true || self?.showPairing == true
                    try? await Task.sleep(for: .seconds(fast ? 1.5 : 4))
                }
            }
        } else if !should {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    func refresh() async {
        if !serverStarted {
            await ADB.startServer()
            serverStarted = true
        }
        let listed = ADBText.devices(await ADB.run(["devices", "-l"], timeout: 8).output)
        var result: [Device] = []
        for entry in listed {
            if entry.state == "device", info[entry.serial] == nil {
                info[entry.serial] = await Self.describe(entry.serial, model: entry.model)
            }
            let details = info[entry.serial]
            result.append(Device(serial: entry.serial, state: entry.state, hardwareID: details?.id,
                                 name: details?.name ?? entry.model ?? "Android",
                                 isTablet: details?.tablet ?? false, isWireless: entry.isWireless))
        }
        // The same phone on cable and Wi-Fi: show it once (cable first, it's faster).
        var seen = Set<String>()
        result = result.sorted { !$0.isWireless && $1.isWireless }.filter { device in
            guard let id = device.hardwareID else { return true }
            return seen.insert(id).inserted
        }
        let present = Set(result.compactMap(\.hardwareID))
        dismissed.formIntersection(present)
        if result != devices { withAnimation(.smooth) { devices = result } }

        await reconnectKnownDevices(present: present)
        autoStartIfPossible()
    }

    /// Paired phones announce themselves on the network when Wireless debugging is on.
    private func reconnectKnownDevices(present: Set<String>) async {
        let known = knownIDs
        guard !known.isEmpty else { return }
        // Phones switched to Wi-Fi from the cable (any Android version) listen on a fixed address.
        let connected = Set(devices.map(\.serial))
        for endpoint in endpoints where !connected.contains(endpoint) {
            if let last = connectAttempts[endpoint], Date().timeIntervalSince(last) < 15 { continue }
            connectAttempts[endpoint] = Date()
            await ADB.run(["connect", endpoint], timeout: 4)
        }
        let services = ADBText.services(await ADB.run(["mdns", "services"], timeout: 5).output)
        for service in services where service.type.contains("adb-tls-connect") {
            guard let id = known.first(where: { service.name.contains($0) }), !present.contains(id) else { continue }
            if let last = connectAttempts[service.address], Date().timeIntervalSince(last) < 15 { continue }
            connectAttempts[service.address] = Date()
            await ADB.run(["connect", service.address], timeout: 8)
        }
    }

    private func autoStartIfPossible() {
        let service = MirrorService.shared
        guard UserDefaults.standard.bool(forKey: Prefs.androidAutoConnect), service.phase == .ready else { return }
        let known = Set(knownIDs)
        guard let device = devices.first(where: {
            $0.isReady && $0.hardwareID.map { known.contains($0) && !dismissed.contains($0) } == true
        }) else { return }
        service.startAndroid(device)
    }

    // MARK: Cable -> Wi-Fi (works on every Android version, until the phone restarts)

    static let endpointsKey = "androidWifiEndpoints"
    private var endpoints: [String] { UserDefaults.standard.stringArray(forKey: Self.endpointsKey) ?? [] }

    func makeWireless(_ device: Device) {
        guard goingWireless == nil else { return }
        goingWireless = device.serial
        Task {
            defer { goingWireless = nil }
            let route = await ADB.run(["-s", device.serial, "shell", "ip route"], timeout: 8).output
            guard let ip = ADBText.wifiAddress(fromIpRoute: route) else {
                MirrorService.shared.showToast(String(localized: "Ligue o Wi-Fi do Android (na mesma rede do Mac) e tente de novo."),
                                               symbol: "wifi.exclamationmark", duration: 6)
                return
            }
            await ADB.run(["-s", device.serial, "tcpip", "5555"], timeout: 10)
            try? await Task.sleep(for: .seconds(2))
            let endpoint = "\(ip):5555"
            var connectedOK = false
            for _ in 0..<5 {
                let result = await ADB.run(["connect", endpoint], timeout: 8)
                if result.output.contains("connected to") { connectedOK = true; break }
                try? await Task.sleep(for: .seconds(1))
            }
            guard connectedOK else {
                MirrorService.shared.showToast(String(localized: "Não foi possível conectar pelo Wi-Fi. Confira se o Android e o Mac estão na mesma rede."),
                                               symbol: "wifi.exclamationmark", duration: 6)
                return
            }
            var saved = endpoints
            if !saved.contains(endpoint) { saved.append(endpoint) }
            UserDefaults.standard.set(saved, forKey: Self.endpointsKey)
            remember(device)
            await refresh()
            MirrorService.shared.showToast(String(localized: "Pronto! Pode tirar o cabo. Vale até o Android reiniciar."),
                                           symbol: "wifi", duration: 6)
        }
    }

    private static func describe(_ serial: String, model: String?) async -> (id: String?, name: String, tablet: Bool) {
        let out = await ADB.run(["-s", serial, "shell",
                                 "getprop ro.serialno; settings get global device_name; getprop ro.build.characteristics"],
                                timeout: 8).output
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let id = lines.first.flatMap { $0.isEmpty || $0 == "unknown" ? nil : $0 }
        var name = lines.count > 1 ? lines[1] : ""
        if name.isEmpty || name == "null" { name = model ?? "Android" }
        let tablet = lines.count > 2 && lines[2].contains("tablet")
        return (id, name, tablet)
    }

    // MARK: Pairing (Wireless debugging, Android 11+)

    /// `showSheet: false` when the tutorial shows the code itself.
    func beginPairing(showSheet: Bool = true) {
        cancelPairing()
        if showSheet { showPairing = true }
        updatePolling()
        let letters = Array("abcdefghjkmnpqrstuvwxyz23456789")
        pairingName = "espelho-" + String((0..<6).map { _ in letters.randomElement()! })
        pairingPassword = String((0..<10).map { _ in letters.randomElement()! })
        pairing = .waiting(qr: "WIFI:T:ADB;S:\(pairingName);P:\(pairingPassword);;")
        let name = pairingName, password = pairingPassword
        pairingTask = Task { [weak self] in
            await ADB.startServer()
            let deadline = Date().addingTimeInterval(300)
            while !Task.isCancelled, Date() < deadline {
                let services = ADBText.services(await ADB.run(["mdns", "services"], timeout: 5).output)
                if let target = services.first(where: { $0.type.contains("adb-tls-pairing") && $0.name == name }) {
                    await self?.pair(address: target.address, secret: password)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
            if !Task.isCancelled { self?.pairing = .failed(String(localized: "O código expirou. Gere um novo e tente de novo.")) }
        }
    }

    /// Fallback: the 6-digit code shown under “Parear dispositivo com código de pareamento”.
    func pair(code: String) {
        pairingTask?.cancel()
        pairing = .pairing
        pairingTask = Task { [weak self] in
            await ADB.startServer()
            for _ in 0..<10 {
                let services = ADBText.services(await ADB.run(["mdns", "services"], timeout: 5).output)
                if let target = services.first(where: { $0.type.contains("adb-tls-pairing") }) {
                    await self?.pair(address: target.address, secret: code)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
            self?.pairing = .failed(String(localized: "O Android não foi encontrado na rede. Deixe a janela do código aberta nele e confira se os dois estão no mesmo Wi-Fi."))
        }
    }

    func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        pairing = .idle
    }

    func closePairing() {
        cancelPairing()
        showPairing = false
        updatePolling()
    }

    private func pair(address: String, secret: String) async {
        pairing = .pairing
        let result = await ADB.run(["pair", address, secret], timeout: 20)
        guard result.output.contains("Successfully paired") else {
            pairing = .failed(result.output.lowercased().contains("wrong password") || result.output.lowercased().contains("failed")
                              ? String(localized: "O código não confere. Tente de novo.")
                              : String(localized: "Não foi possível parear. Tente de novo."))
            return
        }
        pairing = .connecting
        // "Successfully paired to 192.168.0.20:37115 [guid=adb-R58N12ABCDE-Xy1z]"
        let guid = result.output.range(of: #"guid=([^\]\s]+)"#, options: .regularExpression)
            .map { String(result.output[$0].dropFirst(5)) }
        let host = address.split(separator: ":").first.map(String.init) ?? address

        let deadline = Date().addingTimeInterval(25)
        while !Task.isCancelled, Date() < deadline {
            let services = ADBText.services(await ADB.run(["mdns", "services"], timeout: 5).output)
            if let connect = services.first(where: {
                $0.type.contains("adb-tls-connect") && (guid.map($0.name.contains) ?? $0.address.hasPrefix(host + ":"))
            }) {
                await ADB.run(["connect", connect.address], timeout: 10)
            }
            await refresh()
            if let device = devices.first(where: {
                $0.isReady && $0.isWireless && ($0.serial.hasPrefix(host + ":") || guid.map($0.serial.contains) == true)
            }) {
                remember(device)
                closePairing()
                MirrorService.shared.startAndroid(device)
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        pairing = .failed(String(localized: "Pareado, mas o Android não se conectou. Confira se a Depuração por Wi-Fi continua ligada."))
    }

    // MARK: QR code

    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width / 2, height: output.extent.height / 2))
    }
}
