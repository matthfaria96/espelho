import AppKit
import EspelhoEngine
import SwiftUI

/// Runs the AirPlay receiver (UxPlay, hidden) and exposes its state to the UI.
@MainActor
final class MirrorService: ObservableObject {
    static let shared = MirrorService()

    enum Phase: Equatable {
        case starting
        case ready
        case connecting
        case mirroring
        case failed(String)
    }

    @Published private(set) var phase: Phase = .starting
    @Published private(set) var deviceName: String?
    @Published private(set) var deviceModel: String?
    @Published private(set) var pin: String?
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var fps = 0
    @Published private(set) var advertisedName = Prefs.current.name
    @Published var showOnboarding = false
    /// Which tutorial track to open (nil = ask which device the person has).
    @Published var tutorialPlatform: OnboardingView.Platform?
    @Published var toast: Toast?
    /// The receiver can't start because Homebrew libraries changed: offer to rebuild.
    @Published private(set) var needsRepair = false
    /// What is on screen: an iPhone/iPad over AirPlay, or an Android over Wi-Fi debugging/cable.
    @Published private(set) var source: Source = .apple
    @Published private(set) var androidIsTablet = false

    enum Source { case apple, android }

    struct Toast: Equatable, Identifiable {
        let id = UUID()
        var text: String
        var symbol: String
        var revealURL: URL?
    }

    let renderer = H264Renderer()
    private let receiver = StreamReceiver()
    private var process: Process?
    private var output: UxPlayOutput?
    private var runningSettings: Prefs.Snapshot?
    private var stopIsIntentional = false
    private var restartWhenStopped = false
    private var crashCount = 0
    private var fpsTimer: Timer?
    private var connectingTimeout: DispatchWorkItem?
    private var toastDismiss: DispatchWorkItem?
    private var keepAwake: NSObjectProtocol?
    private var noNap: NSObjectProtocol?
    private var androidSession: AndroidSession?
    private var androidDevice: AndroidManager.Device?
    /// Read on the AirPlay video queue: drop iPhone frames while an Android is on screen.
    private let androidActive = AtomicFlag()

    static let debug = ProcessInfo.processInfo.environment["ESPELHO_DEBUG"] != nil

    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Espelho.log")

    private init() {
        Prefs.registerDefaults()
        renderer.smooth = UserDefaults.standard.bool(forKey: Prefs.smooth)
        renderer.onFirstFrame = { [weak self] in self?.firstFrameShown() }
        renderer.onVideoSize = { [weak self] size in
            withAnimation(.smooth) { self?.videoSize = size }
        }
        receiver.onAccessUnit = { [renderer, androidActive] unit, arrival in
            guard !androidActive.value else { return }
            renderer.decode(unit, arrival: arrival)
        }
    }

    var isDeviceIPad: Bool { deviceModel?.localizedCaseInsensitiveContains("ipad") == true }
    var deviceSymbol: String {
        if source == .android { return androidIsTablet ? "ipad" : "smartphone" }
        return isDeviceIPad ? "ipad" : "iphone"
    }
    var fallbackDeviceName: String {
        source == .android ? (androidIsTablet ? String(localized: "Tablet Android") : "Android") : (isDeviceIPad ? "iPad" : "iPhone")
    }

    // MARK: Lifecycle

    func start() {
        guard process == nil else { return }
        if source == .apple { phase = .starting }
        needsRepair = false
        Self.killLeftovers()
        if noNap == nil {
            // Stay responsive in the background (no App Nap) so a device can connect any time.
            noNap = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep], reason: "Receptor do Espelhar Tela")
        }
        receiver.start { [weak self] port in
            self?.launch(port: port)
        } onFailure: { [weak self] message in
            self?.phase = .failed(String(localized: "Não foi possível abrir o canal de vídeo (\(message))."))
        }
    }

    /// Applies new settings: restarts the receiver only if something relevant changed.
    func applySettingsIfNeeded() {
        renderer.smooth = UserDefaults.standard.bool(forKey: Prefs.smooth)
        let settings = Prefs.current
        guard settings != runningSettings else { return }
        restart()
    }

    /// Drops the current device and starts fresh.
    func restart() {
        guard let process, process.isRunning else {
            self.process = nil
            start()
            return
        }
        stopIsIntentional = true
        restartWhenStopped = true
        endSession()
        process.terminate()
    }

    func disconnect() {
        guard phase == .mirroring || phase == .connecting else { return }
        if source == .android {
            if let androidDevice { AndroidManager.shared.dismiss(androidDevice) }
            stopAndroid()
            showToast(String(localized: "Android desconectado"), symbol: "bolt.horizontal.circle")
            return
        }
        restart()
        showToast(String(localized: "Aparelho desconectado"), symbol: "bolt.horizontal.circle")
    }

    func shutdown() {
        androidSession?.stop()
        stopIsIntentional = true
        restartWhenStopped = false
        guard let process, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(1.5)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private func launch(port: UInt16) {
        guard let executable = Self.uxplayURL() else {
            phase = .failed(String(localized: "O componente de espelhamento não foi encontrado. Reinstale o Espelho."))
            return
        }
        let settings = Prefs.current
        runningSettings = settings
        advertisedName = settings.name

        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments(settings: settings, port: port)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["GST_DEBUG"] = "0"
        Self.useBundledGStreamer(&environment)
        process.environment = environment

        let output = UxPlayOutput(logURL: Self.logURL) { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
        self.output = output
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                output.consume(data)
            }
        }
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async { self?.processEnded(ended) }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            phase = .failed(String(localized: "Não foi possível iniciar o espelhamento: \(error.localizedDescription)"))
        }
    }

    private func processEnded(_ ended: Process) {
        guard ended === process else { return }
        process = nil
        endSession()
        if stopIsIntentional {
            stopIsIntentional = false
            if restartWhenStopped {
                restartWhenStopped = false
                start()
            }
            return
        }
        crashCount += 1
        let recent = output?.recentLines ?? []
        let dyldAbort = ended.terminationReason == .uncaughtSignal && ended.terminationStatus == SIGABRT && crashCount >= 2
        if dyldAbort || recent.contains(where: { $0.contains("Library not loaded") || $0.contains("dyld") }) {
            if Self.canRebuild {
                needsRepair = true
                phase = .failed(String(localized: "Uma atualização do Homebrew mudou componentes de que o Espelho precisa. Clique em Reparar: ele é recompilado e reaberto sozinho (leva cerca de 1 minuto)."))
            } else {
                phase = .failed(String(localized: "Um componente do Espelho está faltando ou danificado. Baixe-o de novo em witchmymac.com/espelho."))
            }
            return
        }
        if crashCount <= 3 {
            if source == .apple { phase = .starting }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.start() }
        } else {
            let detail = output?.recentLines.last { $0.localizedCaseInsensitiveContains("error") } ?? ""
            let stopped = String(localized: "O espelhamento parou de responder.")
            phase = .failed(detail.isEmpty ? stopped : stopped + "\n" + detail)
        }
    }

    // MARK: Events

    private func handle(_ event: UxPlayEvent) {
        if source == .android {
            switch event {
            case .client, .pin:
                // An iPhone/iPad chose this Mac while an Android is on screen: the newest wins
                // (and the Android isn't reconnected automatically when the iPhone leaves).
                if let androidDevice { AndroidManager.shared.dismiss(androidDevice) }
                stopAndroid()
                showToast(String(localized: "Trocando para o \(Self.appleName(event))"), symbol: "arrow.left.arrow.right")
            case .ready:
                crashCount = 0
                return
            default:
                return
            }
        }
        switch event {
        case .ready:
            crashCount = 0
            if phase != .mirroring { setPhase(.ready) }
        case .client(let model, let name):
            UserDefaults.standard.set("apple", forKey: Prefs.welcomeTab)
            deviceModel = model
            deviceName = name.isEmpty ? nil : name
            if phase != .mirroring { setPhase(.connecting) }
        case .pin(let code):
            pin = code
            if phase != .mirroring { setPhase(.connecting) }
        case .video:
            if phase != .mirroring { setPhase(.connecting) }
        case .stop:
            if phase == .mirroring || phase == .connecting { endSession() }
        case .connections(let count):
            if count == 0 { endSession() }
        case .lost:
            if phase == .mirroring {
                showToast(String(localized: "A conexão com o aparelho caiu"), symbol: "wifi.exclamationmark")
            }
            endSession()
        }
    }

    private func firstFrameShown() {
        if keepAwake == nil {
            // Watching a video from the phone shouldn't let the Mac's screen dim.
            keepAwake = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated, .latencyCritical],
                reason: "Espelhando a tela de um aparelho")
        }
        pin = nil
        crashCount = 0
        setPhase(.mirroring)
        fpsTimer?.invalidate()
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let value = self.renderer.takeFrameCount()
                if value != self.fps { self.fps = value }
                if Self.debug {
                    FileHandle.standardError.write(Data(String(format: "[espelho] %d qps · suavidade %.0f ms\n", value, self.renderer.pacingDelay * 1000).utf8))
                }
            }
        }
    }

    private func endSession() {
        // The AirPlay side restarting must not end an Android session that is on screen.
        if androidSession != nil { return }
        if source == .android {
            source = .apple
            androidActive.value = false
            androidDevice = nil
        }
        if let keepAwake {
            ProcessInfo.processInfo.endActivity(keepAwake)
            self.keepAwake = nil
        }
        fpsTimer?.invalidate()
        fpsTimer = nil
        renderer.reset()
        pin = nil
        fps = 0
        if case .failed = phase { return }
        if process != nil || phase == .mirroring || phase == .connecting {
            setPhase(process == nil ? .starting : .ready)
        }
        videoSize = .zero
    }

    private func setPhase(_ new: Phase) {
        guard new != phase else { return }
        connectingTimeout?.cancel()
        if new == .connecting {
            // Opening the Screen Mirroring list also "connects" briefly; fall back if nothing follows.
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.phase == .connecting, self.pin == nil else { return }
                if self.source == .android {
                    self.stopAndroid(message: String(localized: "O Android não respondeu. Desbloqueie a tela dele e tente de novo."))
                } else {
                    self.setPhase(.ready)
                }
            }
            connectingTimeout = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: item)
        }
        withAnimation(.smooth(duration: 0.45)) { phase = new }
    }

    // MARK: Android

    func startAndroid(_ device: AndroidManager.Device) {
        guard device.isReady, androidSession == nil else { return }
        if source == .apple, phase == .mirroring || phase == .connecting {
            restart() // drop the iPhone/iPad first
        }
        AndroidManager.shared.remember(device)
        UserDefaults.standard.set("android", forKey: Prefs.welcomeTab)
        let settings = Prefs.current
        let config = AndroidSession.Config(
            serial: device.serial,
            maxSize: settings.quality.size.width,
            maxFps: settings.frameRate,
            bitRate: settings.quality == .high ? 16_000_000 : 10_000_000,
            audio: settings.audio,
            screenOff: UserDefaults.standard.bool(forKey: Prefs.androidScreenOff))
        let session = AndroidSession(config: config, renderer: renderer)
        session.onSize = { [weak self] size in
            withAnimation(.smooth) { self?.videoSize = size }
        }
        session.onControlBlocked = { [weak self] in
            self?.showToast(String(localized: "Este Android bloqueia o controle pelo Mac. Em Opções do desenvolvedor, ligue “Depuração USB (configurações de segurança)” e reinicie o aparelho. A imagem continua funcionando."),
                            symbol: "hand.raised.slash", duration: 12)
        }
        session.onEnded = { [weak self] reason in
            guard let self, self.androidSession === session else { return }
            self.stopAndroid(message: reason)
        }
        renderer.reset()
        androidActive.value = true
        androidSession = session
        androidDevice = device
        androidIsTablet = device.isTablet
        source = .android
        deviceName = device.name
        deviceModel = nil
        pin = nil
        setPhase(.connecting)
        session.start()
    }

    private static func appleName(_ event: UxPlayEvent) -> String {
        if case .client(let model, _) = event, model.localizedCaseInsensitiveContains("ipad") { return "iPad" }
        return "iPhone"
    }

    /// Ends the Android session; `message` is shown when it ended on its own.
    func stopAndroid(message: String? = nil) {
        guard let session = androidSession else { return }
        androidSession = nil
        session.stop()
        endSession()
        if let message { showToast(message, symbol: "exclamationmark.triangle") }
    }

    /// Leaves the current device so the welcome screen (and the pairing sheet) can show.
    func disconnectForSwitch() {
        if source == .android {
            if let androidDevice { AndroidManager.shared.dismiss(androidDevice) }
            stopAndroid()
        } else if phase == .mirroring || phase == .connecting {
            restart()
        }
    }

    /// Sends a control message (touch, key, text…) to the Android on screen.
    func sendToAndroid(_ message: Data) {
        androidSession?.send(message)
    }

    /// The Android screen size that touches are expressed in.
    var androidScreenSize: CGSize { androidSession?.videoSize ?? .zero }

    // MARK: Screenshot

    func captureScreenshot(copyOnly: Bool = false) {
        guard let image = renderer.snapshot() else {
            NSSound.beep()
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }

        if copyOnly {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(png, forType: .png)
            showToast(String(localized: "Tela copiada"), symbol: "doc.on.clipboard")
            return
        }
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Espelho", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        // Like macOS's own screenshots: "iPhone 2026-11-07 at 10.12.33".
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = String(localized: "yyyy-MM-dd 'às' HH.mm.ss")
        let device = deviceName ?? fallbackDeviceName
        let url = folder.appendingPathComponent("\(device) \(formatter.string(from: Date())).png")
        do {
            try png.write(to: url)
            NSSound(named: "Grab")?.play()
            showToast(String(localized: "Captura salva em Imagens › Espelho"), symbol: "camera.fill", revealURL: url)
        } catch {
            showToast(String(localized: "Não foi possível salvar a captura"), symbol: "exclamationmark.triangle")
        }
    }

    func showToast(_ text: String, symbol: String, revealURL: URL? = nil, duration: Double = 3.2) {
        toastDismiss?.cancel()
        withAnimation(.spring(duration: 0.4, bounce: 0.25)) {
            toast = Toast(text: text, symbol: symbol, revealURL: revealURL)
        }
        let item = DispatchWorkItem { [weak self] in
            withAnimation(.smooth) { self?.toast = nil }
        }
        toastDismiss = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }

    /// Copies built on this Mac know where their sources are; downloaded copies don't.
    static var canRebuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "EspelhoSourcePath") != nil
    }

    /// Downloaded copies carry their own GStreamer (Contents/PlugIns/gstreamer and Contents/Frameworks):
    /// point it there, so nothing from Homebrew (present or not) is used.
    static func useBundledGStreamer(_ environment: inout [String: String]) {
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
        let plugins = contents.appendingPathComponent("PlugIns/gstreamer")
        guard FileManager.default.fileExists(atPath: plugins.path) else { return }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.matheusfaria.espelho", isDirectory: true)
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        environment["GST_PLUGIN_SYSTEM_PATH_1_0"] = plugins.path
        environment["GST_PLUGIN_PATH_1_0"] = plugins.path
        environment["GST_PLUGIN_SCANNER_1_0"] = contents.appendingPathComponent("Helpers/gst-plugin-scanner").path
        environment["GST_REGISTRY_1_0"] = caches.appendingPathComponent("gst-registry-\(version).bin").path
        environment["GST_REGISTRY_FORK"] = "no"
        environment.removeValue(forKey: "GST_PLUGIN_SYSTEM_PATH")
        environment.removeValue(forKey: "GST_PLUGIN_PATH")
    }

    /// Rebuilds the app from its sources in Terminal; the script reopens it when done.
    func repair() {
        guard let source = Bundle.main.object(forInfoDictionaryKey: "EspelhoSourcePath") as? String else { return }
        let script = URL(fileURLWithPath: source).appendingPathComponent("scripts/make-espelho-app.sh")
        guard FileManager.default.isExecutableFile(atPath: script.path),
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Helpers

    static func arguments(settings: Prefs.Snapshot, port: UInt16) -> [String] {
        let (w, h) = settings.quality.size
        var args = [
            "-n", settings.name, "-nh",
            "-m", settings.macAddress,
            "-s", "\(w)x\(h)@\(settings.frameRate)",
            "-fps", "\(settings.frameRate)",
            // Timestamps on: the app paces frames with them, and the sound follows the same clock.
            "-vsync", "\(settings.audioDelay)",
            "-nohold",
            "-vrtp", "config-interval=-1 mtu=60000 ! rtpstreampay ! tcpclientsink host=127.0.0.1 port=\(port) sync=false",
        ]
        if !settings.audio { args += ["-as", "0"] }
        if settings.requirePin {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Espelho", isDirectory: true)
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            args += ["-pin", "-reg", support.appendingPathComponent("aparelhos-autorizados").path]
        }
        return args
    }

    static func uxplayURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["ESPELHO_UXPLAY"] {
            return URL(fileURLWithPath: override)
        }
        return helperURL("uxplay")
    }

    /// A receiver left behind by a crash would hold the AirPlay name: stop it.
    private static func killLeftovers() {
        guard let path = uxplayURL()?.path else { return }
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", path]
        try? pkill.run()
        pkill.waitUntilExit()
    }
}

/// A Bool readable from any thread.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
