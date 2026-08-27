@testable import VPhoneCore
import Foundation
import Network
import os
import Testing

// MARK: - Test helpers

final class TestTCPServer: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "test.server")
    var onAccept: ((NWConnection) -> Void)?

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.onAccept?(conn)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    var port: UInt16 { UInt16(listener.port?.rawValue ?? 0) }
}

func nwReceiveUpTo(_ conn: NWConnection, max: Int) async throws -> Data {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, any Error>) in
        conn.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                cont.resume(returning: data)
            } else if let error {
                cont.resume(throwing: error)
            } else {
                struct Closed: Error {}
                cont.resume(throwing: Closed())
            }
        }
    }
}

func nwReceiveExact(_ conn: NWConnection, count: Int) async throws -> Data {
    var data = Data()
    while data.count < count {
        let chunk = try await nwReceiveUpTo(conn, max: count - data.count)
        data.append(chunk)
    }
    return data
}

func nwReceiveHead(_ conn: NWConnection) async throws -> String {
    var buffer = Data()
    let separator = Data("\r\n\r\n".utf8)
    while buffer.range(of: separator) == nil {
        buffer.append(try await nwReceiveUpTo(conn, max: 4096))
    }
    return String(decoding: buffer, as: UTF8.self)
}

func nwSend(_ conn: NWConnection, _ data: Data) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
        conn.send(content: data, completion: .contentProcessed { error in
            if let error { cont.resume(throwing: error) } else { cont.resume() }
        })
    }
}

/// Caller must have started `conn` already.
func nwEchoForever(_ conn: NWConnection) async {
    while true {
        guard let chunk = try? await nwReceiveUpTo(conn, max: 65536), !chunk.isEmpty else { return }
        try? await nwSend(conn, chunk)
    }
}

final class TCPClient {
    let conn: NWConnection

    init(port: UInt16) {
        conn = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.withLock({ flag -> Bool in
                        guard !flag else { return false }
                        flag = true
                        return true
                    }) { cont.resume() }
                case let .failed(error):
                    if resumed.withLock({ flag -> Bool in
                        guard !flag else { return false }
                        flag = true
                        return true
                    }) { cont.resume(throwing: error) }
                default:
                    break
                }
            }
            conn.start(queue: .global())
        }
    }

    func send(_ text: String) async throws {
        try await nwSend(conn, Data(text.utf8))
    }

    func receive(count: Int) async throws -> Data {
        try await nwReceiveExact(conn, count: count)
    }

    func receiveHead() async throws -> String {
        try await nwReceiveHead(conn)
    }
}

// MARK: - Fake upstreams

/// Minimal HTTP proxy: answers CONNECT with 200 then echoes bytes.
/// When `serverFirst` is set, it is pipelined with the 200 head — origin
/// bytes the upstream sends before any client data.
final class FakeHTTPProxy: @unchecked Sendable {
    let server: TestTCPServer
    var receivedConnect: String?
    let serverFirst: Data?

    init(serverFirst: Data? = nil) throws {
        self.serverFirst = serverFirst
        server = try TestTCPServer()
        server.onAccept = { conn in
            conn.start(queue: .global())
            Task {
                do {
                    let head = try await nwReceiveHead(conn)
                    self.receivedConnect = head
                    if head.hasPrefix("CONNECT") {
                        var response = Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8)
                        if let serverFirst = self.serverFirst {
                            response.append(serverFirst)
                        }
                        try await nwSend(conn, response)
                        await nwEchoForever(conn)
                    } else {
                        try await nwSend(conn, Data(head.utf8))
                        await nwEchoForever(conn)
                    }
                } catch {}
            }
        }
    }
}

/// Minimal SOCKS5 proxy: no-auth handshake, connect by domain, then echoes.
final class FakeSOCKS5Proxy: @unchecked Sendable {
    let server: TestTCPServer
    var connectedHost: String?
    var connectedPort: UInt16?
    var authUser: String?

    init() throws {
        server = try TestTCPServer()
        server.onAccept = { conn in
            conn.start(queue: .global())
            Task {
                do {
                    var greeting = try await nwReceiveExact(conn, count: 2)
                    let methodCount = Int(greeting[greeting.startIndex + 1])
                    greeting.append(try await nwReceiveExact(conn, count: methodCount))
                    try await nwSend(conn, Data([0x05, 0x00]))
                    let req = try await nwReceiveExact(conn, count: 4)
                    guard req[req.startIndex + 1] == 0x01 else { conn.cancel(); return }
                    let atyp = req[req.startIndex + 3]
                    if atyp == 0x03 {
                        let len = Int((try await nwReceiveExact(conn, count: 1)).first!)
                        let hostData = try await nwReceiveExact(conn, count: len)
                        self.connectedHost = String(decoding: hostData, as: UTF8.self)
                    } else if atyp == 0x01 {
                        _ = try await nwReceiveExact(conn, count: 4)
                        self.connectedHost = "ipv4"
                    } else {
                        conn.cancel(); return
                    }
                    let portData = try await nwReceiveExact(conn, count: 2)
                    self.connectedPort = UInt16(portData[portData.startIndex]) << 8 | UInt16(portData[portData.startIndex + 1])
                    try await nwSend(conn, Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                    await nwEchoForever(conn)
                } catch {}
            }
        }
    }
}

// MARK: - Relay tests

struct ProxyRelayTests {
    private func makeRelay(
        https: VPhoneProxyConfig.Upstream?,
        http: VPhoneProxyConfig.Upstream? = nil,
        exceptions: [String] = []
    ) throws -> VPhoneProxyRelay {
        let relay = VPhoneProxyRelay(
            config: VPhoneProxyConfig(httpsUpstream: https, httpUpstream: http, exceptions: exceptions)
        )
        relay.updateAllowedIPs(["127.0.0.1"])
        try relay.start()
        return relay
    }

    @Test func connectTunnelsThroughHTTPUpstream() async throws {
        let upstream = try FakeHTTPProxy()
        let relay = try makeRelay(https: .http(host: "127.0.0.1", port: Int(upstream.server.port), username: nil, password: nil))
        defer { relay.stop() }

        let client = TCPClient(port: relay.port)
        try await client.connect()
        try await client.send("CONNECT example.com:443 HTTP/1.1\r\n\r\n")
        let head = try await client.receiveHead()
        #expect(head.contains("200"))
        try await client.send("ping")
        let echo = try await client.receive(count: 4)
        #expect(echo == Data("ping".utf8))
        #expect(upstream.receivedConnect?.contains("CONNECT example.com:443") == true)
    }

    @Test func connectTunnelsThroughSOCKS5Upstream() async throws {
        let upstream = try FakeSOCKS5Proxy()
        let relay = try makeRelay(https: .socks5(host: "127.0.0.1", port: Int(upstream.server.port), username: nil, password: nil))
        defer { relay.stop() }

        let client = TCPClient(port: relay.port)
        try await client.connect()
        try await client.send("CONNECT example.com:443 HTTP/1.1\r\n\r\n")
        let head = try await client.receiveHead()
        #expect(head.contains("200"))
        try await client.send("hello")
        let echo = try await client.receive(count: 5)
        #expect(echo == Data("hello".utf8))
        #expect(upstream.connectedHost == "example.com")
        #expect(upstream.connectedPort == 443)
    }

    @Test func connectForwardsEarlyDataAfterHead() async throws {
        let upstream = try FakeHTTPProxy()
        let relay = try makeRelay(https: .http(host: "127.0.0.1", port: Int(upstream.server.port), username: nil, password: nil))
        defer { relay.stop() }

        let client = TCPClient(port: relay.port)
        try await client.connect()
        try await client.send("CONNECT example.com:443 HTTP/1.1\r\n\r\nEARLY")
        let head = try await client.receiveHead()
        #expect(head.contains("200"))
        let echo = try await client.receive(count: 5)
        #expect(echo == Data("EARLY".utf8))
    }

    @Test func connectForwardsUpstreamEarlyData() async throws {
        let payload = Data("SERVER-FIRST".utf8)
        let upstream = try FakeHTTPProxy(serverFirst: payload)
        let relay = try makeRelay(https: .http(host: "127.0.0.1", port: Int(upstream.server.port), username: nil, password: nil))
        defer { relay.stop() }

        let client = TCPClient(port: relay.port)
        try await client.connect()
        try await client.send("CONNECT example.com:443 HTTP/1.1\r\n\r\n")
        let head = try await client.receiveHead()
        #expect(head.contains("200"))
        // The head read may have coalesced part of the payload already.
        let terminator = head.range(of: "\r\n\r\n")!
        var received = Data(head[terminator.upperBound...].utf8)
        if received.count < payload.count {
            received.append(try await client.receive(count: payload.count - received.count))
        }
        #expect(received == payload)
        try await client.send("ping")
        let echo = try await client.receive(count: 4)
        #expect(echo == Data("ping".utf8))
    }

    @Test func plainHTTPForwardsVerbatimToHTTPUpstream() async throws {
        let upstream = try FakeHTTPProxy()
        let relay = try makeRelay(
            https: .socks5(host: "127.0.0.1", port: 1, username: nil, password: nil),
            http: .http(host: "127.0.0.1", port: Int(upstream.server.port), username: nil, password: nil)
        )
        defer { relay.stop() }

        let client = TCPClient(port: relay.port)
        try await client.connect()
        let request = "GET http://example.com:80/foo HTTP/1.1\r\nHost: example.com\r\n\r\n"
        try await client.send(request)
        let echo = try await client.receive(count: request.utf8.count)
        #expect(String(decoding: echo, as: UTF8.self) == request)
        #expect(upstream.receivedConnect == request)
    }

    @Test func plainHTTPThroughSOCKS5IsRewrittenToOriginForm() async throws {
        let upstream = try FakeSOCKS5Proxy()
        let relay = try makeRelay(
            https: .socks5(host: "127.0.0.1", port: 1, username: nil, password: nil),
            http: .socks5(host: "127.0.0.1", port: Int(upstream.server.port), username: nil, password: nil)
        )
        defer { relay.stop() }

        let client = TCPClient(port: relay.port)
        try await client.connect()
        try await client.send("GET http://example.com:80/foo HTTP/1.1\r\nHost: example.com\r\n\r\n")
        let echo = try await client.receive(count: 30)
        #expect(String(decoding: echo, as: UTF8.self).hasPrefix("GET /foo HTTP/1.1"))
        #expect(upstream.connectedHost == "example.com")
    }

    @Test func connectWithExceptionDialsTargetDirectly() async throws {
        let origin = try TestTCPServer()
        origin.onAccept = { conn in conn.start(queue: .global()); Task { await nwEchoForever(conn) } }
        let relay = try makeRelay(
            https: .http(host: "127.0.0.1", port: 1, username: nil, password: nil),
            exceptions: ["127.0.0.1"]
        )
        defer { relay.stop() }

        let client = TCPClient(port: relay.port)
        try await client.connect()
        try await client.send("CONNECT 127.0.0.1:\(origin.port) HTTP/1.1\r\n\r\n")
        let head = try await client.receiveHead()
        #expect(head.contains("200"))
        try await client.send("direct")
        let echo = try await client.receive(count: 6)
        #expect(echo == Data("direct".utf8))
    }

    @Test func disallowedClientIsRejected() async throws {
        let relay = try makeRelay(https: .http(host: "127.0.0.1", port: 1, username: nil, password: nil))
        relay.updateAllowedIPs(["203.0.113.5"])
        defer { relay.stop() }

        let client = TCPClient(port: relay.port)
        try await client.connect()
        try await client.send("CONNECT example.com:443 HTTP/1.1\r\n\r\n")
        await #expect(throws: (any Error).self) {
            _ = try await client.receiveHead()
        }
    }

    @Test func unreachableUpstreamYields502() async throws {
        let relay = try makeRelay(https: .http(host: "127.0.0.1", port: 1, username: nil, password: nil))
        defer { relay.stop() }

        let client = TCPClient(port: relay.port)
        try await client.connect()
        try await client.send("CONNECT example.com:443 HTTP/1.1\r\n\r\n")
        let head = try await client.receiveHead()
        #expect(head.contains("502"))
    }
}
