import CoreMedia
import Foundation
import Network

/// Loopback TCP server that receives the mirrored screen from UxPlay
/// (`rtph264pay ! rtpstreampay ! tcpclientsink`) and outputs H.264 access units.
public final class StreamReceiver: @unchecked Sendable {
    /// Called on the receiver's queue for every complete frame, with its arrival time (host clock, seconds).
    public var onAccessUnit: ((AccessUnit, Double) -> Void)?

    private let queue = DispatchQueue(label: "espelho.stream", qos: .userInteractive)
    private var listener: NWListener?
    private var connection: NWConnection?
    private var framer = RFC4571Framer()
    private var depacketizer = H264Depacketizer()
    public private(set) var port: UInt16?

    public init() {}

    /// Starts listening on 127.0.0.1 with a free port. `onReady` runs on the main queue.
    public func start(onReady: @escaping (UInt16) -> Void, onFailure: @escaping (String) -> Void) {
        if let port {
            DispatchQueue.main.async { onReady(port) }
            return
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            DispatchQueue.main.async { onFailure(error.localizedDescription) }
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard let port = listener.port?.rawValue else { return }
                self?.port = port
                DispatchQueue.main.async { onReady(port) }
            case .failed(let error):
                self?.port = nil
                self?.listener = nil
                DispatchQueue.main.async { onFailure(error.localizedDescription) }
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    private func accept(_ new: NWConnection) {
        // UxPlay reconnects whenever it rebuilds its pipeline: the newest connection wins.
        connection?.cancel()
        connection = new
        framer.reset()
        depacketizer = H264Depacketizer()
        new.start(queue: queue)
        receive(on: new)
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, c === self.connection else { return }
            if let data, !data.isEmpty {
                self.framer.append(data) { packet in
                    let units = self.depacketizer.push(packet)
                    guard !units.isEmpty else { return }
                    let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                    for unit in units { self.onAccessUnit?(unit, now) }
                }
            }
            if isComplete || error != nil {
                c.cancel()
                if self.connection === c { self.connection = nil }
                return
            }
            self.receive(on: c)
        }
    }
}
