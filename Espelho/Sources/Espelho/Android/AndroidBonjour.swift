import dnssd
import EspelhoEngine
import Foundation

/// Finds Android devices on the Wi‑Fi with macOS's own Bonjour (mDNSResponder), inside the app.
///
/// adb has an mDNS client of its own, but macOS may never deliver the multicast answers to it
/// (a helper process of an app opened from the Finder, under Local Network privacy): the phone
/// scans the QR code, offers itself on the network, and nothing happens. The system's Bonjour is
/// the path the Local Network permission is built around (the service types are declared in
/// NSBonjourServices), and it says so when the permission was refused.
///
/// Everything runs on `queue`; dns_sd calls back on it too.
final class AndroidBonjour: @unchecked Sendable {
    static let shared = AndroidBonjour()

    private static let types = ["_adb-tls-pairing._tcp", "_adb-tls-connect._tcp"]
    private static let noError = DNSServiceErrorType(kDNSServiceErr_NoError)
    /// kDNSServiceErr_PolicyDenied: Local Network access refused (System Settings › Privacy & Security).
    private static let policyDenied: DNSServiceErrorType = -65570

    private let queue = DispatchQueue(label: "espelho.android.bonjour")
    private var browsers: [String: DNSServiceRef] = [:]   // service type -> browse
    private var browsingSince: [String: Date] = [:]
    private var lookups: [String: Lookup] = [:]           // "name|type|interface" -> address lookup
    private var denied = false

    private init() {}

    /// Starts browsing, or tries again after a browse that failed. Cheap: call it as often as needed.
    func start() {
        queue.async { [self] in
            for type in Self.types where browsers[type] == nil {
                var ref: DNSServiceRef?
                let error = DNSServiceBrowse(&ref, 0, 0, type, "local.", Self.browseReply,
                                             Unmanaged.passUnretained(self).toOpaque())
                guard error == Self.noError, let ref else {
                    failed(error, "browse \(type)")
                    continue
                }
                guard DNSServiceSetDispatchQueue(ref, queue) == Self.noError else {
                    DNSServiceRefDeallocate(ref)
                    continue
                }
                browsers[type] = ref
                browsingSince[type] = Date()
            }
            // Browsing for a while without being refused: Local Network access is allowed now.
            if denied, browsers.count == Self.types.count,
               let newest = browsingSince.values.max(), Date().timeIntervalSince(newest) > 10 {
                denied = false
            }
        }
    }

    func stop() {
        queue.async { [self] in
            lookups.values.forEach { $0.cancel() }
            lookups.removeAll()
            browsers.values.forEach { DNSServiceRefDeallocate($0) }
            browsers.removeAll()
            browsingSince.removeAll()
        }
    }

    /// Services found and resolved so far: name, type ("_adb-tls-pairing._tcp"…) and "ip:port".
    func services() -> [ADBText.Service] {
        queue.sync {
            ADBText.merge(lookups.values.compactMap { lookup in
                lookup.address.map { ADBText.Service(name: lookup.name, type: lookup.type, address: $0) }
            })
        }
    }

    /// macOS refused Local Network access to Espelho.
    var isDenied: Bool { queue.sync { denied } }

    // MARK: Browse

    private static let browseReply: DNSServiceBrowseReply = { sdRef, flags, interface, error, name, regtype, domain, context in
        guard let me: AndroidBonjour = AndroidBonjour.object(context) else { return }
        me.browsed(sdRef, flags: flags, interface: interface, error: error,
                   name: AndroidBonjour.text(name) ?? "", type: AndroidBonjour.text(regtype) ?? "",
                   domain: AndroidBonjour.text(domain) ?? "local.")
    }

    private func browsed(_ sdRef: DNSServiceRef?, flags: DNSServiceFlags, interface: UInt32,
                         error: DNSServiceErrorType, name: String, type: String, domain: String) {
        guard error == Self.noError else {
            // This browse is over; the next start() opens a new one.
            if let failedType = browsers.first(where: { $0.value == sdRef })?.key {
                if let ref = browsers.removeValue(forKey: failedType) { DNSServiceRefDeallocate(ref) }
                browsingSince[failedType] = nil
                for (key, lookup) in lookups where lookup.type == failedType {
                    lookup.cancel()
                    lookups[key] = nil
                }
            }
            failed(error, "browse")
            return
        }
        let type = type.hasSuffix(".") ? String(type.dropLast()) : type
        let key = "\(name)|\(type)|\(interface)"
        if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 {
            guard lookups[key] == nil else { return }
            let lookup = Lookup(name: name, type: type, interface: interface)
            lookups[key] = lookup
            resolve(lookup, domain: domain)
        } else {
            lookups.removeValue(forKey: key)?.cancel()
        }
    }

    private func failed(_ error: DNSServiceErrorType, _ what: String) {
        if error == Self.policyDenied {
            if !denied { ADB.note("Bonjour: o macOS negou o acesso à Rede Local (\(what))") }
            denied = true
        } else {
            ADB.note("Bonjour: erro \(error) (\(what))")
        }
    }

    // MARK: Resolve (service -> host and port -> IPv4 address)

    private final class Lookup {
        let name: String
        let type: String
        let interface: UInt32
        var port: UInt16 = 0
        var address: String?
        var resolveRef: DNSServiceRef?
        var addressRef: DNSServiceRef?

        init(name: String, type: String, interface: UInt32) {
            self.name = name; self.type = type; self.interface = interface
        }

        /// Stops asking (on the queue; dns_sd calls nothing back after this).
        func cancel() {
            if let resolveRef { DNSServiceRefDeallocate(resolveRef) }
            if let addressRef { DNSServiceRefDeallocate(addressRef) }
            resolveRef = nil
            addressRef = nil
        }
    }

    private func resolve(_ lookup: Lookup, domain: String) {
        var ref: DNSServiceRef?
        guard DNSServiceResolve(&ref, 0, lookup.interface, lookup.name, lookup.type, domain, Self.resolveReply,
                                Unmanaged.passUnretained(lookup).toOpaque()) == Self.noError, let ref else { return }
        guard DNSServiceSetDispatchQueue(ref, queue) == Self.noError else {
            DNSServiceRefDeallocate(ref)
            return
        }
        lookup.resolveRef = ref
    }

    private static let resolveReply: DNSServiceResolveReply = { _, _, interface, error, _, host, port, _, _, context in
        guard error == AndroidBonjour.noError, let lookup: Lookup = AndroidBonjour.object(context),
              let host = AndroidBonjour.text(host) else { return }
        AndroidBonjour.shared.resolved(lookup, host: host, port: UInt16(bigEndian: port), interface: interface)
    }

    private func resolved(_ lookup: Lookup, host: String, port: UInt16, interface: UInt32) {
        lookup.port = port
        guard lookup.addressRef == nil else { return }
        var ref: DNSServiceRef?
        guard DNSServiceGetAddrInfo(&ref, 0, interface, DNSServiceProtocol(kDNSServiceProtocol_IPv4), host,
                                    Self.addressReply, Unmanaged.passUnretained(lookup).toOpaque()) == Self.noError,
              let ref else { return }
        guard DNSServiceSetDispatchQueue(ref, queue) == Self.noError else {
            DNSServiceRefDeallocate(ref)
            return
        }
        lookup.addressRef = ref
    }

    private static let addressReply: DNSServiceGetAddrInfoReply = { _, flags, _, error, _, address, _, context in
        guard error == AndroidBonjour.noError, flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0,
              let lookup: Lookup = AndroidBonjour.object(context), let ip = AndroidBonjour.ipv4(address) else { return }
        let endpoint = "\(ip):\(lookup.port)"
        if lookup.address == nil { ADB.note("Bonjour: \(lookup.name) \(lookup.type) \(endpoint)") }
        lookup.address = endpoint
        lookup.cancel() // one address is enough; a phone that changes it announces itself again
    }

    // MARK: C helpers (dns_sd hands over raw pointers)

    private static func object<T: AnyObject>(_ context: UnsafeMutableRawPointer?) -> T? {
        context.map { Unmanaged<T>.fromOpaque($0).takeUnretainedValue() }
    }

    private static func text(_ pointer: UnsafePointer<CChar>?) -> String? {
        pointer.map { String(cString: $0) }
    }

    /// "192.168.0.20" from an IPv4 socket address.
    private static func ipv4(_ address: UnsafePointer<sockaddr>?) -> String? {
        guard let address, address.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
        var ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &ip, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
