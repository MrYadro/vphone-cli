import Foundation
import os

/// HTTP CONNECT relay for the iOS guest.
///
/// Listens on all interfaces (ephemeral port) and only accepts connections
/// from allowlisted peer IPs (the guest). CONNECT requests are chained to the
/// configured upstream (HTTP proxy or SOCKS5); absolute-form plain HTTP is
/// forwarded verbatim (HTTP upstream) or rewritten to origin-form (SOCKS5
/// upstream). Hosts matching `no_proxy` exceptions are dialed directly.
public final class VPhoneProxyRelay: @unchecked Sendable {
    public enum RelayError: Error, CustomStringConvertible {
        case bindFailed(String)
        case upstreamFailed(String)

        public var description: String {
            switch self {
            case let .bindFailed(detail): "relay bind failed: \(detail)"
            case let .upstreamFailed(detail): "upstream connection failed: \(detail)"
            }
        }
    }

    private let config: VPhoneProxyConfig
    private let lock = NSLock()
    private nonisolated(unsafe) var listenFD: Int32 = -1
    private nonisolated(unsafe) var allowedIPs: Set<String> = []
    public private(set) var port: UInt16 = 0

    public init(config: VPhoneProxyConfig) {
        self.config = config
    }

    deinit {
        stop()
    }

    /// IPv4 address of the host's vmnet NAT gateway (e.g. bridge100 →
    /// 192.168.64.1) while the VM runs. Falls back to VZ's fixed shared
    /// subnet gateway when no bridge interface is listed yet.
    public static func hostBridgeGateway() -> String? {
        var ifap: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifap) == 0 else { return nil }
        defer { freeifaddrs(ifap) }
        var current = ifap
        while let node = current {
            defer { current = node.pointee.ifa_next }
            let info = node.pointee
            guard let ifaName = info.ifa_name else { continue }
            let name = String(cString: ifaName)
            guard name.hasPrefix("bridge") || name.hasPrefix("vmenet"),
                  info.ifa_addr?.pointee.sa_family == UInt8(AF_INET),
                  (info.ifa_flags & UInt32(IFF_LOOPBACK)) == 0
            else { continue }
            var addr = sockaddr_in()
            memcpy(&addr, info.ifa_addr, min(Int(info.ifa_addr.pointee.sa_len), MemoryLayout<sockaddr_in>.size))
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let ip = String(cString: buf)
            if ip != "0.0.0.0" { return ip }
        }
        return "192.168.64.1"
    }

    public func updateAllowedIPs(_ ips: Set<String>) {
        lock.lock()
        allowedIPs = ips
        lock.unlock()
    }

    public func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RelayError.bindFailed("socket") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        addr.sin_port = 0

        var boundOK = false
        withUnsafePointer(to: &addr) { ptr in
            boundOK = ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard boundOK else {
            let detail = String(cString: strerror(errno))
            close(fd)
            throw RelayError.bindFailed(detail)
        }
        guard listen(fd, 16) == 0 else {
            let detail = String(cString: strerror(errno))
            close(fd)
            throw RelayError.bindFailed(detail)
        }

        var sin = addr
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var actualPort: UInt16 = 0
        var gotName = false
        withUnsafeMutablePointer(to: &sin) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                gotName = getsockname(fd, $0, &len) == 0
            }
        }
        if gotName {
            actualPort = sin.sin_port.byteSwapped
        }
        guard actualPort > 0 else {
            close(fd)
            throw RelayError.bindFailed("getsockname")
        }

        lock.lock()
        listenFD = fd
        lock.unlock()
        port = actualPort

        Thread.detachNewThread { [weak self] in
            self?.acceptLoop(listenFD: fd)
        }
    }

    public func stop() {
        lock.lock()
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
    }

    // MARK: - Accept

    private func acceptLoop(listenFD: Int32) {
        while true {
            let client = accept(listenFD, nil, nil)
            lock.lock()
            let alive = self.listenFD >= 0
            lock.unlock()
            if client < 0 { if !alive { return }; continue }

            var peer = sockaddr_in()
            var peerLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            var peerIP: String? = nil
            var gotPeer = false
            withUnsafeMutablePointer(to: &peer) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    gotPeer = getpeername(client, $0, &peerLen) == 0
                }
            }
            if gotPeer {
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &peer.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                    peerIP = String(decoding: buf.prefix(Int(strlen(buf))).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
            }

            lock.lock()
            let allowed = peerIP.map { allowedIPs.contains($0) } ?? false
            lock.unlock()
            guard allowed else {
                close(client)
                continue
            }

            let config = self.config
            Thread.detachNewThread {
                Self.handle(clientFD: client, config: config)
            }
        }
    }

    // MARK: - Request handling

    /// Entry point for externally-owned connections (vsock): the fd's
    /// lifecycle belongs to the caller, so it is shut down but never closed.
    public func handleExternalConnection(fd: Int32) {
        let config = self.config
        Thread.detachNewThread {
            Self.handle(clientFD: fd, config: config, ownsClientFD: false)
        }
    }

    static func handle(clientFD: Int32, config: VPhoneProxyConfig, ownsClientFD: Bool = true) {
        guard let head = readHead(fd: clientFD),
              let lineEnd = head.range(of: Data("\r\n".utf8)) else {
            writeSimpleResponse(fd: clientFD, status: "400 Bad Request")
            close(clientFD)
            return
        }
        let requestLine = String(decoding: head[head.startIndex..<lineEnd.lowerBound], as: UTF8.self)
        let remainder = head[lineEnd.upperBound...]
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            writeSimpleResponse(fd: clientFD, status: "400 Bad Request")
            close(clientFD)
            return
        }
        let method = parts[0]
        let target = String(parts[1])
        let version = parts.count > 2 ? String(parts[2]) : "HTTP/1.1"

        if method == "CONNECT" {
            guard let (host, port) = splitHostPort(target) else {
                writeSimpleResponse(fd: clientFD, status: "400 Bad Request")
                close(clientFD)
                return
            }
            let earlyData = head.range(of: Data("\r\n\r\n".utf8))
                .map { Data(head[$0.upperBound...]) } ?? Data()
            handleConnect(
                clientFD: clientFD, host: host, port: port, config: config,
                earlyData: earlyData, ownsClientFD: ownsClientFD)
            return
        }

        guard let url = URL(string: target), let host = url.host else {
            writeSimpleResponse(fd: clientFD, status: "400 Bad Request")
            close(clientFD)
            return
        }
        let port = UInt16(url.port ?? 80)
        let originPath = (url.path.isEmpty ? "/" : url.path) + (url.query.map { "?\($0)" } ?? "")
        let rewrittenHead = Data("\(method) \(originPath) \(version)\r\n".utf8) + remainder

        if VPhoneProxyConfig.matchesExceptions(host, exceptions: config.exceptions) {
            var originFD: Int32 = -1
            do {
                originFD = try dialTCP(host: host, port: port)
                _ = writeAll(fd: originFD, data: rewrittenHead)
                runTunnels(clientFD, originFD, closeA: ownsClientFD)
                return
            } catch {
                if originFD >= 0 { close(originFD) }
                writeSimpleResponse(fd: clientFD, status: "502 Bad Gateway")
                close(clientFD)
                return
            }
        }

        switch config.httpUpstream {
        case let .http(upHost, upPort, user, pass):
            var upFD: Int32 = -1
            do {
                upFD = try dialTCP(host: upHost, port: UInt16(upPort))
                try httpConnectUpstream(fd: upFD, host: host, port: port, username: user, password: pass, connectOnly: false)
                _ = writeAll(fd: upFD, data: head)
                runTunnels(clientFD, upFD, closeA: ownsClientFD)
            } catch {
                if upFD >= 0 { close(upFD) }
                writeSimpleResponse(fd: clientFD, status: "502 Bad Gateway")
                close(clientFD)
            }
        case let .socks5(upHost, upPort, user, pass):
            var upFD: Int32 = -1
            do {
                upFD = try dialTCP(host: upHost, port: UInt16(upPort))
                try socks5Connect(fd: upFD, host: host, port: port, username: user, password: pass)
                _ = writeAll(fd: upFD, data: rewrittenHead)
                runTunnels(clientFD, upFD, closeA: ownsClientFD)
            } catch {
                if upFD >= 0 { close(upFD) }
                writeSimpleResponse(fd: clientFD, status: "502 Bad Gateway")
                close(clientFD)
            }
        case nil:
            writeSimpleResponse(fd: clientFD, status: "502 Bad Gateway")
            close(clientFD)
        }
    }

    static func handleConnect(clientFD: Int32, host: String, port: UInt16, config: VPhoneProxyConfig, earlyData: Data, ownsClientFD: Bool) {
        if VPhoneProxyConfig.matchesExceptions(host, exceptions: config.exceptions) {
            var targetFD: Int32 = -1
            do {
                targetFD = try dialTCP(host: host, port: port)
                writeSimpleResponse(fd: clientFD, status: "200 Connection Established")
                _ = writeAll(fd: targetFD, data: earlyData)
                runTunnels(clientFD, targetFD, closeA: ownsClientFD)
                return
            } catch {
                if targetFD >= 0 { close(targetFD) }
                writeSimpleResponse(fd: clientFD, status: "502 Bad Gateway")
                close(clientFD)
                return
            }
        }

        let upstream = config.httpsUpstream ?? config.httpUpstream
        switch upstream {
        case let .http(upHost, upPort, user, pass):
            var upFD: Int32 = -1
            do {
                upFD = try dialTCP(host: upHost, port: UInt16(upPort))
                let upstreamEarly = try httpConnectUpstream(fd: upFD, host: host, port: port, username: user, password: pass, connectOnly: true)
                writeSimpleResponse(fd: clientFD, status: "200 Connection Established")
                _ = writeAll(fd: clientFD, data: upstreamEarly)
                _ = writeAll(fd: upFD, data: earlyData)
                runTunnels(clientFD, upFD, closeA: ownsClientFD)
            } catch {
                if upFD >= 0 { close(upFD) }
                writeSimpleResponse(fd: clientFD, status: "502 Bad Gateway")
                close(clientFD)
            }
        case let .socks5(upHost, upPort, user, pass):
            var upFD: Int32 = -1
            do {
                upFD = try dialTCP(host: upHost, port: UInt16(upPort))
                try socks5Connect(fd: upFD, host: host, port: port, username: user, password: pass)
                writeSimpleResponse(fd: clientFD, status: "200 Connection Established")
                _ = writeAll(fd: upFD, data: earlyData)
                runTunnels(clientFD, upFD, closeA: ownsClientFD)
            } catch {
                if upFD >= 0 { close(upFD) }
                writeSimpleResponse(fd: clientFD, status: "502 Bad Gateway")
                close(clientFD)
            }
        case nil:
            writeSimpleResponse(fd: clientFD, status: "502 Bad Gateway")
            close(clientFD)
        }
    }

    // MARK: - Upstream dialers

    static func dialTCP(host: String, port: UInt16) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>? = nil
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let first = result else {
            throw RelayError.upstreamFailed("resolve \(host):\(port)")
        }
        defer { freeaddrinfo(result) }

        var current: UnsafeMutablePointer<addrinfo>? = first
        while let node = current {
            let info = node.pointee
            let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            if fd >= 0 {
                var connected = false
                info.ai_addr!.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    if Darwin.connect(fd, $0, info.ai_addrlen) == 0 { connected = true }
                }
                if connected { return fd }
                close(fd)
            }
            current = info.ai_next
        }
        throw RelayError.upstreamFailed("connect \(host):\(port)")
    }

    @discardableResult
    static func httpConnectUpstream(
        fd: Int32, host: String, port: UInt16,
        username: String?, password: String?, connectOnly: Bool
    ) throws -> Data {
        if !connectOnly { return Data() }
        var request = "CONNECT \(host):\(port) HTTP/1.1\r\nHost: \(host):\(port)\r\n"
        if let username, let password {
            let raw = Data("\(username):\(password)".utf8)
            request += "Proxy-Authorization: Basic \(raw.base64EncodedString())\r\n"
        }
        request += "\r\n"
        try writeAllChecked(fd: fd, data: Data(request.utf8))
        guard let response = readHead(fd: fd),
              let terminator = response.range(of: Data("\r\n\r\n".utf8)),
              let text = String(
                decoding: response[response.startIndex..<terminator.lowerBound], as: UTF8.self
              ).split(separator: "\r\n").first else {
            throw RelayError.upstreamFailed("no CONNECT response")
        }
        let code = text.split(separator: " ").dropFirst().first.map { Int($0.prefix(3)) ?? 0 } ?? 0
        guard (200..<300).contains(code) else {
            throw RelayError.upstreamFailed("CONNECT rejected: \(text)")
        }
        return Data(response[terminator.upperBound...])
    }

    static func socks5Connect(
        fd: Int32, host: String, port: UInt16, username: String?, password: String?
    ) throws {
        let hasAuth = username != nil && password != nil
        try writeAllChecked(fd: fd, data: hasAuth ? Data([0x05, 0x02, 0x00, 0x02]) : Data([0x05, 0x01, 0x00]))
        guard let method = readExact(fd: fd, count: 2), method.count == 2,
              method[method.startIndex] == 0x05 else {
            throw RelayError.upstreamFailed("socks5 greeting")
        }
        let selected = method[method.startIndex + 1]
        if selected == 0x02 {
            guard let user = username?.data(using: .utf8), let pass = password?.data(using: .utf8),
                  user.count < 256, pass.count < 256 else {
                throw RelayError.upstreamFailed("socks5 credentials required but invalid")
            }
            var auth = Data([0x01, UInt8(user.count)])
            auth.append(user)
            auth.append(UInt8(pass.count))
            auth.append(pass)
            try writeAllChecked(fd: fd, data: auth)
            guard let authResp = readExact(fd: fd, count: 2), authResp[authResp.startIndex + 1] == 0x00 else {
                throw RelayError.upstreamFailed("socks5 auth rejected")
            }
        } else if selected != 0x00 {
            throw RelayError.upstreamFailed("socks5 no acceptable method")
        }

        let hostBytes = Data(host.utf8)
        guard hostBytes.count < 256 else { throw RelayError.upstreamFailed("socks5 host too long") }
        var request = Data([0x05, 0x01, 0x00, 0x03, UInt8(hostBytes.count)])
        request.append(hostBytes)
        request.append(UInt8(port >> 8))
        request.append(UInt8(port & 0xFF))
        try writeAllChecked(fd: fd, data: request)

        guard let reply = readExact(fd: fd, count: 4), reply[reply.startIndex] == 0x05,
              reply[reply.startIndex + 1] == 0x00 else {
            throw RelayError.upstreamFailed("socks5 connect rejected")
        }
        let atyp = reply[reply.startIndex + 3]
        let skip: Int
        switch atyp {
        case 0x01: skip = 4
        case 0x03:
            guard let lenByte = readExact(fd: fd, count: 1) else {
                throw RelayError.upstreamFailed("socks5 reply truncated")
            }
            skip = Int(lenByte[lenByte.startIndex])
        case 0x04: skip = 16
        default: throw RelayError.upstreamFailed("socks5 reply atyp")
        }
        guard readExact(fd: fd, count: skip + 2) != nil else {
            throw RelayError.upstreamFailed("socks5 reply truncated")
        }
    }

    // MARK: - I/O helpers

    static func splitHostPort(_ target: String) -> (String, UInt16)? {
        if target.hasPrefix("[") {
            guard let close = target.firstIndex(of: "]") else { return nil }
            let host = String(target[target.index(after: target.startIndex)..<close])
            let rest = target[target.index(after: close)...]
            guard rest.hasPrefix(":"),
                  let port = UInt16(rest.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let colon = target.lastIndex(of: ":"),
              let port = UInt16(target[target.index(after: colon)...]) else { return nil }
        let host = String(target[target.startIndex..<colon])
        guard !host.isEmpty else { return nil }
        return (host, port)
    }

    static func readHead(fd: Int32, maxBytes: Int = 65536) -> Data? {
        let separator = Data("\r\n\r\n".utf8)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while buffer.count < maxBytes {
            if buffer.range(of: separator) != nil { return buffer }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buffer.append(chunk, count: n)
        }
        return nil
    }

    static func readExact(fd: Int32, count: Int) -> Data? {
        var data = Data(capacity: count)
        var chunk = [UInt8](repeating: 0, count: count)
        var remaining = count
        while remaining > 0 {
            let n = read(fd, &chunk, remaining)
            if n <= 0 { return nil }
            data.append(chunk, count: n)
            remaining -= n
        }
        return data
    }

    @discardableResult
    static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < data.count {
                let n = write(fd, base + offset, data.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    static func writeAllChecked(fd: Int32, data: Data) throws {
        guard writeAll(fd: fd, data: data) else {
            throw RelayError.upstreamFailed("write")
        }
    }

    static func writeSimpleResponse(fd: Int32, status: String) {
        _ = writeAll(fd: fd, data: Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
    }

    static func pipe(_ from: Int32, _ to: Int32) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(from, &chunk, chunk.count)
            if n <= 0 { break }
            if !writeAll(fd: to, data: Data(chunk[0..<n])) { break }
        }
        shutdown(from, SHUT_RDWR)
        shutdown(to, SHUT_RDWR)
    }

    /// Blind-pipe both directions; closes both fds once both directions end.
    /// `closeA` false when the a-side fd is owned by the caller (vsock).
    static func runTunnels(_ a: Int32, _ b: Int32, closeA: Bool = true) {
        let counter = OSAllocatedUnfairLock(initialState: 2)
        func finish() {
            if counter.withLock({ $0 -= 1; return $0 }) == 0 {
                if closeA { close(a) }
                close(b)
            }
        }
        Thread.detachNewThread {
            Self.pipe(a, b)
            shutdown(a, SHUT_RDWR)
            shutdown(b, SHUT_RDWR)
            finish()
        }
        Self.pipe(b, a)
        shutdown(a, SHUT_RDWR)
        shutdown(b, SHUT_RDWR)
        finish()
    }
}
