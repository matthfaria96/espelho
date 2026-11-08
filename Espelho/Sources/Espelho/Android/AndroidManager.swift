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
    /// macOS keeps Espelho off the local network (Privacy & Security › Local Network).
    @Published private(set) var localNetworkBlocked = false
    /// The QR code has been up for a while and no phone showed up on the network.
    @Published private(set) var pairingSlow = false

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
            if pairingTask == nil { AndroidBonjour.shared.stop() }
        }
    }

    /// Android services on the network (pairing codes waiting, phones with Wireless debugging on).
    /// macOS's own Bonjour first: adb's mDNS client often hears nothing when the app is opened
    /// from the Finder. adb's list still counts, for whatever it does see.
    private func networkServices() async -> [ADBText.Service] {
        AndroidBonjour.shared.start()
        let fromADB = ADBText.services(await ADB.run(["mdns", "services"], timeout: 5).output)
        updateLocalNetworkBlocked()
        return ADBText.merge(AndroidBonjour.shared.services(), fromADB)
    }

    /// adb itself was refused a connection to a phone that had just announced itself.
    private var adbRefused = false

    private func updateLocalNetworkBlocked() {
        let blocked = AndroidBonjour.shared.isDenied || adbRefused
        if blocked != localNetworkBlocked { localNetworkBlocked = blocked }
    }

    /// When macOS keeps Espelho off the local network, `adb pair` to a phone that has just
    /// announced itself fails with "No route to host" or "protocol fault (couldn't read status
    /// message)". A server started by another app (Terminal, Android Studio) carries that app's
    /// permission instead, so the next attempt starts Espelho's own.
    private func isNetworkRefusal(_ output: String) async -> Bool {
        guard output.contains("No route to host") || output.contains("protocol fault") else { return false }
        adbRefused = true
        updateLocalNetworkBlocked()
        await ADB.run(["kill-server"], timeout: 5)
        await ADB.startServer()
        return true
    }

    static func openLocalNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
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
        let services = await networkServices()
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
        ADB.note("Pareamento: QR code \(name) na tela")
        pairingTask = Task { [weak self] in
            await ADB.startServer()
            let started = Date()
            var seen: [String] = []
            while !Task.isCancelled, Date().timeIntervalSince(started) < 300 {
                guard let self else { return }
                let services = await self.networkServices()
                if let target = services.first(where: { $0.type.contains("adb-tls-pairing") && $0.name == name }) {
                    ADB.note("Pareamento: \(name) apareceu em \(target.address)")
                    await self.pair(address: target.address, secret: password)
                    return
                }
                let now = services.map { "\($0.name) \($0.type) \($0.address)" }.sorted()
                if now != seen {
                    seen = now
                    ADB.note("Pareamento: na rede, \(now.isEmpty ? "nenhum Android" : now.joined(separator: ", "))")
                }
                // Scanned and nothing showed up? Usually the Local Network permission or the Wi‑Fi.
                if !self.pairingSlow, Date().timeIntervalSince(started) > 30 { self.pairingSlow = true }
                try? await Task.sleep(for: .seconds(1))
            }
            if !Task.isCancelled { self?.pairing = .failed(String(localized: "O código expirou. Gere um novo e tente de novo.")) }
        }
    }

    /// Fallback: the 6-digit code shown under “Parear dispositivo com código de pareamento”.
    func pair(code: String) {
        pairingTask?.cancel()
        pairing = .pairing
        pairingSlow = false
        adbRefused = false
        updateLocalNetworkBlocked()
        ADB.note("Pareamento: com código de 6 números")
        pairingTask = Task { [weak self] in
            await ADB.startServer()
            for _ in 0..<15 {
                guard let self else { return }
                if let target = await self.networkServices().first(where: { $0.type.contains("adb-tls-pairing") }) {
                    await self.pair(address: target.address, secret: code)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
            ADB.note("Pareamento: nenhum Android com o código aberto foi encontrado")
            self?.pairing = .failed(String(localized: "O Android não foi encontrado na rede. Deixe a janela do código aberta nele e confira se os dois estão no mesmo Wi-Fi."))
        }
    }

    func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        pairing = .idle
        pairingSlow = false
        adbRefused = false
        updateLocalNetworkBlocked()
        if pollTask == nil { AndroidBonjour.shared.stop() }
    }

    func closePairing() {
        cancelPairing()
        showPairing = false
        updatePolling()
    }

    private func pair(address: String, secret: String) async {
        pairing = .pairing
        pairingSlow = false
        let result = await ADB.run(["pair", address, secret], timeout: 20)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        ADB.note("adb pair \(address): \(output)")
        guard output.contains("Successfully paired") else {
            let lowered = output.lowercased()
            if await isNetworkRefusal(output) {
                pairing = .failed(String(localized: "O Android apareceu, mas o macOS não deixou o Espelho falar com ele."))
            } else {
                pairing = .failed(lowered.contains("wrong password") || lowered.contains("failed")
                                  ? String(localized: "O código não confere. Tente de novo.")
                                  : String(localized: "Não foi possível parear. Tente de novo."))
            }
            return
        }
        pairing = .connecting
        // "Successfully paired to 192.168.0.20:37115 [guid=adb-R58N12ABCDE-Xy1z]"
        let guid = output.range(of: #"guid=([^\]\s]+)"#, options: .regularExpression)
            .map { String(output[$0].dropFirst(5)) }
        let host = address.split(separator: ":").first.map(String.init) ?? address

        let deadline = Date().addingTimeInterval(25)
        var tried = Set<String>()
        while !Task.isCancelled, Date() < deadline {
            let services = await networkServices()
            if let connect = services.first(where: {
                $0.type.contains("adb-tls-connect") && (guid.map($0.name.contains) ?? $0.address.hasPrefix(host + ":"))
            }) {
                let result = await ADB.run(["connect", connect.address], timeout: 10)
                if tried.insert(connect.address).inserted {
                    ADB.note("adb connect \(connect.address): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
            await refresh()
            if let device = devices.first(where: {
                $0.isReady && $0.isWireless && ($0.serial.hasPrefix(host + ":") || guid.map($0.serial.contains) == true)
            }) {
                ADB.note("Pareamento: conectado (\(device.serial))")
                remember(device)
                closePairing()
                MirrorService.shared.startAndroid(device)
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        ADB.note("Pareamento: pareado, mas o serviço de conexão não apareceu (guid \(guid ?? "?"))")
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
