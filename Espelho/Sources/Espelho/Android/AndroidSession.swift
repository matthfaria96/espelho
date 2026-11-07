import CoreMedia
import EspelhoEngine
import Foundation
import Darwin

/// One Android mirroring session: starts the scrcpy server on the device over adb, receives
/// video (and sound) on local sockets, and sends touches and keys back.
final class AndroidSession: @unchecked Sendable {
    struct Config {
        var serial: String
        var maxSize: Int
        var maxFps: Int
        var bitRate: Int
        var audio: Bool
        var screenOff: Bool
    }

    /// Main queue callbacks.
    var onDeviceName: ((String) -> Void)?
    var onSize: ((CGSize) -> Void)?
    /// nil = stopped on purpose; otherwise a message for the user.
    var onEnded: ((String?) -> Void)?
    /// Main queue: the phone refuses touches and keys (Xiaomi & co. need an extra switch).
    var onControlBlocked: (() -> Void)?
    private var reportedBlocked = false

    let config: Config
    private let renderer: H264Renderer
    private let queue = DispatchQueue(label: "espelho.android", qos: .userInteractive)
    private let scid = UInt32.random(in: 1..<0x7FFF_FFFF)
    private var listenFD: Int32 = -1
    private var socketFDs: [Int32] = []
    private var controlFD: Int32 = -1
    private var server: Process?
    private var videoParser = ScrcpyStreamParser(expectsDeviceName: true)
    private var audioParser = ScrcpyStreamParser(expectsDeviceName: false)
    private var assembler = ScrcpyVideoAssembler()
    private var player: PCMPlayer?
    private var finished = false
    private var gotVideo = false
    private var frames = 0

    private static let debugEnabled = ProcessInfo.processInfo.environment["ESPELHO_DEBUG"] != nil

    static func debug(_ text: String) {
        guard debugEnabled else { return }
        FileHandle.standardError.write(Data("[android] \(text)\n".utf8))
    }

    private let lock = NSLock()
    private var size = CGSize.zero

    private static let devicePath = "/data/local/tmp/espelho-server.jar"

    init(config: Config, renderer: H264Renderer) {
        self.config = config
        self.renderer = renderer
    }

    private var socketName: String { String(format: "scrcpy_%08x", scid) }

    /// Current Android screen size in pixels (touch coordinates are expressed in it).
    var videoSize: CGSize { lock.withLock { size } }

    // MARK: Start / stop

    func start() {
        Task {
            guard let jar = Bundle.main.url(forResource: "scrcpy-server", withExtension: "jar")
                    ?? Self.homebrewServer(),
                  let version = Self.serverVersion else {
                fail(String(localized: "O componente para Android não foi encontrado. Reinstale o Espelho."))
                return
            }
            let push = await ADB.run(["-s", config.serial, "push", jar.path, Self.devicePath], timeout: 30)
            guard push.ok else {
                fail(Self.explain(push.output, fallback: String(localized: "Não foi possível preparar o Android.")))
                return
            }
            guard let port = await openListener() else {
                fail(String(localized: "Não foi possível abrir o canal de vídeo."))
                return
            }
            let reverse = await ADB.run(["-s", config.serial, "reverse", "localabstract:\(socketName)", "tcp:\(port)"])
            guard reverse.ok else {
                fail(Self.explain(reverse.output, fallback: String(localized: "O Android recusou a conexão.")))
                return
            }
            if isFinished { return }
            let process = ADB.launch(serverArguments(version: version), onOutput: { [weak self] text in
                guard let self, text.contains("INJECT_EVENTS") else { return }
                self.queue.async {
                    guard !self.reportedBlocked else { return }
                    self.reportedBlocked = true
                    DispatchQueue.main.async { self.onControlBlocked?() }
                }
            }) { [weak self] in
                self?.fail(String(localized: "O Android encerrou o espelhamento."))
            }
            queue.sync {
                if finished { process?.terminate() } else { server = process }
            }
            if process == nil { fail(String(localized: "Não foi possível iniciar o espelhamento no Android.")) }

            // No picture in 15 s: something is wrong (screen locked behind a dialog, old Android…).
            queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, !self.gotVideo else { return }
                self.finish(String(localized: "O Android não respondeu. Desbloqueie a tela dele e tente de novo."))
            }
        }
    }

    func stop() {
        queue.async { self.finish(nil) }
    }

    private var isFinished: Bool { queue.sync { finished } }

    private func fail(_ reason: String?) {
        queue.async { self.finish(reason) }
    }

    private func serverArguments(version: String) -> [String] {
        var args = ["-s", config.serial, "shell",
                    "CLASSPATH=\(Self.devicePath)", "app_process", "/", "com.genymobile.scrcpy.Server", version,
                    String(format: "scid=%08x", scid),
                    "log_level=info",
                    "video_codec=h264",
                    "max_size=\(config.maxSize)",
                    "max_fps=\(config.maxFps)",
                    "video_bit_rate=\(config.bitRate)",
                    "clipboard_autosync=false"]
        if config.audio {
            args.append("audio_codec=raw")
        } else {
            args.append("audio=false")
        }
        return args
    }

    private func finish(_ reason: String?) {
        guard !finished else { return }
        Self.debug("fim: \(reason ?? "pedido") · quadros \(frames)")
        finished = true
        if listenFD >= 0 { Darwin.shutdown(listenFD, SHUT_RDWR); close(listenFD) }
        listenFD = -1
        for fd in socketFDs { Darwin.shutdown(fd, SHUT_RDWR); close(fd) }
        socketFDs = []
        controlFD = -1
        player?.stop()
        player = nil
        if let server, server.isRunning { server.terminate() }
        server = nil
        let serial = config.serial, name = socketName
        Task.detached { await ADB.run(["-s", serial, "reverse", "--remove", "localabstract:\(name)"], timeout: 5) }
        DispatchQueue.main.async { self.onEnded?(reason) }
    }

    // MARK: Sockets

    private enum Role { case video, audio, control }

    /// The device connects video, then audio, then control. Plain sockets accepted one by one
    /// keep that order guaranteed (it is how each socket is identified).
    private func openListener() async -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(fd, pointer, length) == 0 && listen(fd, 4) == 0 && getsockname(fd, pointer, &length) == 0
            }
        }
        guard bound else { close(fd); return nil }
        let port = UInt16(bigEndian: address.sin_port)
        let roles: [Role] = [.video] + (config.audio ? [.audio] : []) + [.control]
        queue.sync { listenFD = fd }
        Thread.detachNewThread { [weak self] in
            for role in roles {
                let client = accept(fd, nil, nil)
                guard client >= 0, let self else { return }
                self.queue.async { self.connected(client, role: role) }
            }
        }
        return port
    }

    private func connected(_ fd: Int32, role: Role) {
        guard !finished else { close(fd); return }
        Self.debug("conexão \(role)")
        socketFDs.append(fd)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        if role == .control {
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            controlFD = fd
            if listenFD >= 0 { close(listenFD); listenFD = -1 }
            // Everything is connected: the adb tunnel is no longer needed.
            let serial = config.serial, name = socketName
            Task.detached { await ADB.run(["-s", serial, "reverse", "--remove", "localabstract:\(name)"], timeout: 5) }
            if config.screenOff { send(ScrcpyControl.setDisplayPower(on: false)) }
        }
        Thread.detachNewThread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 1 << 18)
            while true {
                let count = read(fd, &buffer, buffer.count)
                guard let self else { return }
                if count <= 0 {
                    if role != .audio { self.fail(String(localized: "A conexão com o Android caiu.")) }
                    return
                }
                let data = Data(buffer[0..<count])
                self.queue.async {
                    guard !self.finished else { return }
                    switch role {
                    case .video: self.handleVideo(data)
                    case .audio: self.handleAudio(data)
                    case .control: break // clipboard/acks from the device: not used
                    }
                }
            }
        }
    }

    private func handleVideo(_ data: Data) {
        videoParser.append(data) { event in
            switch event {
            case .deviceName(let name):
                DispatchQueue.main.async { self.onDeviceName?(name) }
            case .codec(let codec):
                Self.debug("codec \(String(codec, radix: 16))")
                if codec != ScrcpyStreamParser.codecH264 { finish(String(localized: "Formato de vídeo não suportado pelo Android.")) }
            case .disabled:
                finish(String(localized: "O Android não conseguiu capturar a tela."))
            case .session(let width, let height):
                Self.debug("tamanho \(width)x\(height)")
                let newSize = CGSize(width: width, height: height)
                lock.withLock { size = newSize }
                DispatchQueue.main.async { self.onSize?(newSize) }
            case .packet(let pts, let config, _, let payload):
                if let unit = assembler.push(pts: pts, config: config, data: payload) {
                    gotVideo = true
                    frames += 1
                    if frames == 1 { Self.debug("1º quadro: \(unit.nals.map { $0.first.map { $0 & 0x1F } ?? 0 })") }
                    renderer.decode(unit, arrival: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
                }
            }
        }
    }

    private func handleAudio(_ data: Data) {
        audioParser.append(data) { event in
            switch event {
            case .codec(let codec):
                if codec == ScrcpyStreamParser.codecRaw {
                    let player = PCMPlayer()
                    player.start()
                    self.player = player
                }
            case .packet(_, let config, _, let payload):
                if !config { player?.enqueue(payload) }
            default:
                break // sound unavailable (Android 10 or older, or blocked by the app): video continues
            }
        }
    }

    // MARK: Input

    func send(_ message: Data) {
        queue.async {
            guard self.controlFD >= 0 else { return }
            message.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(self.controlFD, raw.baseAddress! + offset, raw.count - offset)
                    if written <= 0 { return }
                    offset += written
                }
            }
        }
    }

    // MARK: Helpers

    static var serverVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "EspelhoScrcpyVersion") as? String
            ?? ProcessInfo.processInfo.environment["ESPELHO_SCRCPY_VERSION"]
    }

    private static func homebrewServer() -> URL? {
        let url = URL(fileURLWithPath: "/opt/homebrew/opt/scrcpy/share/scrcpy/scrcpy-server")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func explain(_ output: String, fallback: String) -> String {
        let text = output.lowercased()
        if text.contains("unauthorized") { return String(localized: "Toque em “Permitir” no Android para autorizar este Mac.") }
        if text.contains("offline") || text.contains("not found") { return String(localized: "O Android se desconectou. Verifique se a Depuração por Wi-Fi continua ligada.") }
        return fallback
    }
}
