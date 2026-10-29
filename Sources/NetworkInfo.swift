import Foundation
import SystemConfiguration

enum NetworkInfo {
    /// mDNS .local hostname, e.g. "my-macbook.local". Stable across IP changes.
    static func localHostName() -> String? {
        guard let cf = SCDynamicStoreCopyLocalHostName(nil) else { return nil }
        let name = (cf as String).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : "\(name).local"
    }

    /// Every up, non-loopback IPv4 address on the machine.
    static func allLocalIPv4() -> [String] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }

        var result: [(iface: String, ip: String)] = []
        var pointer = ifaddr
        while let ptr = pointer {
            defer { pointer = ptr.pointee.ifa_next }

            let flags = Int32(ptr.pointee.ifa_flags)
            guard let addr = ptr.pointee.ifa_addr,
                  (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                        &host, socklen_t(host.count),
                        nil, 0, NI_NUMERICHOST)
            result.append((String(cString: ptr.pointee.ifa_name), String(cString: host)))
        }

        // Wi-Fi first — that's the address the phone will reach.
        let preferred = ["en0", "en1"]
        return result.sorted { a, b in
            let ia = preferred.firstIndex(of: a.iface) ?? Int.max
            let ib = preferred.firstIndex(of: b.iface) ?? Int.max
            return ia < ib
        }.map(\.ip)
    }

    /// The address to show the user. Prefers the .local name so it survives DHCP.
    static func primaryIPv4() -> String? { allLocalIPv4().first }

    /// Whether a hostname resolves on this machine right now.
    ///
    /// `.local` names depend on mDNS, which some networks block and some
    /// configurations never advertise. Showing the user a `.local` URL that
    /// cannot be resolved is worse than showing a plain IP, so this is checked
    /// rather than assumed. Blocking — call it off the main thread.
    static func resolves(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        if let result { freeaddrinfo(result) }
        return status == 0
    }

    /// Host header values this server will answer to.
    ///
    /// Validating Host is what prevents DNS rebinding: an attacker's domain
    /// resolving to this Mac's LAN address still sends `Host: evil.example`,
    /// which is not in this set.
    static func acceptableHosts(httpPort: UInt16) -> Set<String> {
        var names = ["localhost", "127.0.0.1", "[::1]", "::1"]
        if let local = localHostName() { names.append(local) }
        names.append(contentsOf: allLocalIPv4())

        var hosts = Set<String>()
        for name in names {
            hosts.insert(name.lowercased())                  // Host may omit the port
            hosts.insert("\(name.lowercased()):\(httpPort)")
        }
        return hosts
    }

    /// Origin values accepted on the WebSocket upgrade.
    ///
    /// The page is served from the HTTP port, so a legitimate WebSocket handshake
    /// always carries exactly one of these. Anything else — a random web page, an
    /// ad iframe, a `file://` document (Origin `null`) — is rejected.
    ///
    /// `secure` must match how the page is actually served. Accepting both
    /// schemes would let a plaintext page drive a TLS socket, which is the
    /// downgrade this is meant to prevent.
    static func acceptableOrigins(httpPort: UInt16, secure: Bool = false) -> Set<String> {
        var names = ["localhost", "127.0.0.1"]
        if let local = localHostName() { names.append(local) }
        names.append(contentsOf: allLocalIPv4())
        let scheme = secure ? "https" : "http"
        return Set(names.map { "\(scheme)://\($0.lowercased()):\(httpPort)" })
    }
}
