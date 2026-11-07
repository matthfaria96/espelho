import AppKit

/// User preferences (UserDefaults keys shared with @AppStorage).
enum Prefs {
    static let deviceName = "deviceName"
    static let quality = "quality"
    static let frameRate = "frameRate"
    static let audio = "audio"
    static let requirePin = "requirePin"
    static let keepOnTop = "keepOnTop"
    static let fitWindow = "fitWindow"
    static let onboardingDone = "onboardingDone"
    static let macAddress = "macAddress"
    static let smooth = "smooth"
    static let audioDelay = "audioDelay"
    static let menuBar = "menuBar"
    static let androidAutoConnect = "androidAutoConnect"
    static let androidScreenOff = "androidScreenOff"
    static let welcomeTab = "welcomeTab"

    enum Quality: String, CaseIterable, Identifiable {
        case standard, high
        var id: String { rawValue }
        var title: String {
            switch self {
            case .standard: String(localized: "Padrão · 1080p")
            case .high: String(localized: "Alta · 1440p")
            }
        }
        var size: (width: Int, height: Int) {
            switch self {
            case .standard: (1920, 1080)
            case .high: (2560, 1440)
            }
        }
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            deviceName: "Espelho",
            quality: Quality.standard.rawValue,
            frameRate: 60,
            audio: true,
            requirePin: false,
            keepOnTop: false,
            fitWindow: true,
            onboardingDone: false,
            smooth: true,
            audioDelay: 0,
            menuBar: true,
            androidAutoConnect: true,
            androidScreenOff: false,
            welcomeTab: "apple",
        ])
    }

    static var current: Snapshot {
        let d = UserDefaults.standard
        let name = d.string(forKey: deviceName)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Snapshot(
            name: name.isEmpty ? "Espelho" : name,
            quality: Quality(rawValue: d.string(forKey: quality) ?? "") ?? .standard,
            frameRate: d.integer(forKey: frameRate) == 30 ? 30 : 60,
            audio: d.bool(forKey: audio),
            requirePin: d.bool(forKey: requirePin),
            audioDelay: min(max(d.integer(forKey: audioDelay), -500), 500),
            macAddress: stableMacAddress())
    }

    /// The server settings that require restarting UxPlay when they change.
    struct Snapshot: Equatable {
        var name: String
        var quality: Quality
        var frameRate: Int
        var audio: Bool
        var requirePin: Bool
        var audioDelay: Int // ms, positive = sound later
        var macAddress: String
    }

    /// A fixed identity so iPhones/iPads recognise this Mac between launches.
    private static func stableMacAddress() -> String {
        if let saved = UserDefaults.standard.string(forKey: macAddress) { return saved }
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] & 0xFC) | 0x02 // locally administered, unicast
        let value = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        UserDefaults.standard.set(value, forKey: macAddress)
        return value
    }
}

/// Interface language. "system" follows macOS (System Settings › General › Language & Region,
/// where Espelho can also be set per app); the others override it for Espelho only.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, es, ptBR = "pt-BR"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "Idioma do sistema")
        case .en: "English"
        case .es: "Español"
        case .ptBR: "Português (Brasil)"
        }
    }

    /// macOS reads the app's languages at launch from AppleLanguages in its own domain.
    static var current: AppLanguage {
        guard let list = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String],
              let first = list.first else { return .system }
        if first.hasPrefix("pt") { return .ptBR }
        if first.hasPrefix("es") { return .es }
        return first.hasPrefix("en") ? .en : .system
    }

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }

    @MainActor
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
