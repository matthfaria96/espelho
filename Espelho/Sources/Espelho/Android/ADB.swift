import Foundation

/// Runs the bundled Android Debug Bridge (adb). Every call is off the main thread.
enum ADB {
    static var url: URL? {
        if let override = ProcessInfo.processInfo.environment["ESPELHO_ADB"] {
            return URL(fileURLWithPath: override)
        }
        if let bundled = helperURL("adb") { return bundled }
        return ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var available: Bool { url != nil }

    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Espelho-Android.log")

    /// The log, opened for appending (started over past 2 MB).
    private static func openLog() -> FileHandle? {
        if let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 2_000_000 {
            try? FileManager.default.removeItem(at: logURL)
        }
        let fd = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        return fd < 0 ? nil : FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static let logQueue = DispatchQueue(label: "espelho.android.log")

    /// One line in the log: what pairing and discovery saw, for when something doesn't connect.
    static func note(_ text: String) {
        let line = "\(Date().formatted(.iso8601)) \(text)\n"
        logQueue.async { openLog()?.write(Data(line.utf8)) }
    }

    /// The adb daemon is started on its own first, with no pipes attached: a daemon that
    /// inherits our pipes would keep them open forever.
    static func startServer() async {
        guard let url else { return }
        await Task.detached {
            let p = Process()
            p.executableURL = url
            p.arguments = ["start-server"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let deadline = Date().addingTimeInterval(10)
            while p.isRunning, Date() < deadline { usleep(20_000) }
            if p.isRunning { p.terminate() }
        }.value
    }

    /// Runs `adb <args>` and returns its combined output.
    @discardableResult
    static func run(_ args: [String], timeout: Double = 20) async -> (ok: Bool, output: String) {
        guard let url else { return (false, String(localized: "adb não encontrado")) }
        return await Task.detached {
            let p = Process()
            p.executableURL = url
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return (false, error.localizedDescription) }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self))
        }.value
    }

    /// Starts a long-running `adb <args>` (the mirroring server). Its output goes to the log,
    /// and each chunk is also handed to `onOutput` (to spot known problems).
    static func launch(_ args: [String], onOutput: @escaping @Sendable (String) -> Void = { _ in },
                       onExit: @escaping @Sendable () -> Void) -> Process? {
        guard let url else { return nil }
        let p = Process()
        p.executableURL = url
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let log = openLog()
        log?.write(Data("\(Date().formatted(.iso8601)) adb \(args.joined(separator: " "))\n".utf8))
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil // releases `log`, which closes it
                return
            }
            log?.write(data)
            onOutput(String(decoding: data, as: UTF8.self))
        }
        p.terminationHandler = { _ in onExit() }
        do { try p.run() } catch { return nil }
        return p
    }
}

/// A command-line helper shipped inside the app (Contents/Helpers).
func helperURL(_ name: String) -> URL? {
    let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)")
    if FileManager.default.isExecutableFile(atPath: url.path) { return url }
    return Bundle.main.url(forAuxiliaryExecutable: name) // older layout
}
