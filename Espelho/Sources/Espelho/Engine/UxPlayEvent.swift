import Foundation

/// The "@@PT ..." lines added to UxPlay by scripts/patch-uxplay.py.
public enum UxPlayEvent: Equatable {
    case ready
    case connections(Int)
    case client(model: String, name: String)
    case pin(String)
    case video(codec: Int, width: Int, height: Int)
    case stop
    case lost

    public static func parse(_ line: Substring) -> UxPlayEvent? {
        guard line.hasPrefix("@@PT ") else { return nil }
        let body = line.dropFirst(5)
        let word = body.prefix { $0 != " " }
        let rest = body.dropFirst(word.count).drop { $0 == " " }
        switch word {
        case "ready": return .ready
        case "stop": return .stop
        case "lost": return .lost
        case "conns": return Int(rest).map(UxPlayEvent.connections)
        case "pin": return .pin(String(rest))
        case "client":
            let fields = rest.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            return .client(model: fields.first.map(String.init) ?? "",
                           name: fields.count > 1 ? String(fields[1]) : "")
        case "video":
            let n = rest.split(separator: " ").compactMap { Int($0) }
            guard n.count == 3 else { return nil }
            return .video(codec: n[0], width: n[1], height: n[2])
        default: return nil
        }
    }
}

/// Splits a byte stream into lines, keeps a log file and reports UxPlay events. Thread-safe.
public final class UxPlayOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private let log: FileHandle?
    private var recent: [String] = []
    private let onEvent: (UxPlayEvent) -> Void

    public init(logURL: URL?, onEvent: @escaping (UxPlayEvent) -> Void) {
        self.onEvent = onEvent
        if let logURL {
            try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            // Start a fresh log each launch so it never grows without bound.
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            log = try? FileHandle(forWritingTo: logURL)
        } else {
            log = nil
        }
    }

    /// The last meaningful lines (for error messages).
    public var recentLines: [String] { lock.withLock { recent } }

    public func consume(_ data: Data) {
        var events: [UxPlayEvent] = []
        lock.withLock {
            log?.write(data)
            pending.append(data)
            while let newline = pending.firstIndex(of: 0x0A) {
                let lineData = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                if let event = UxPlayEvent.parse(Substring(line)) {
                    events.append(event)
                } else if Self.isMeaningful(line) {
                    recent.append(line)
                    if recent.count > 12 { recent.removeFirst() }
                }
            }
        }
        events.forEach(onEvent)
    }

    private static func isMeaningful(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && !t.contains("GLib-GIRepository") && !t.hasPrefix("objc[")
            && !t.contains("gi.repository")
    }
}
