# Proxy Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the iOS guest internet access through host HTTP/SOCKS5 proxies, strictly opt-in via `--proxy env` or `--proxy <url>`, using a host-side relay and guest system-wide HTTP proxy.

**Architecture:** vphone-cli runs an HTTP CONNECT relay on the host (allowlisted to the guest IP). Once vphoned connects over vsock, the host sends `proxy_set`; the guest daemon writes the proxy (gateway IP + relay port) into the active network service via SCPreferences. The relay chains each connection to the configured upstream (HTTP proxy verbatim/CONNECT or SOCKS5 with protocol translation), honoring `no_proxy` exceptions by dialing directly.

**Tech Stack:** Swift 6.0 (strict concurrency), POSIX sockets, swift-testing; ObjC + SystemConfiguration for the guest daemon; existing vsock length-prefixed JSON protocol (version stays 1).

**Spec:** `docs/superpowers/specs/2026-08-27-proxy-support-design.md`

## Global Constraints

- Swift 6.0 strict concurrency; package floor macOS 15; `VPhoneCore` must not depend on AppKit.
- Tests use `swift-testing` (`@testable import VPhoneCore`, `import Testing`, `struct XTests { @Test func ... }`).
- vphoned is ObjC, cross-compiled `xcrun -sdk iphoneos clang -arch arm64`, built with `make -C scripts/vphoned`.
- vsock protocol version stays `1` — additive message types only (`proxy_set` / `proxy_clear` / `proxy_get`).
- Feature is strictly opt-in: absent `--proxy` → no relay, no guest writes, env vars ignored.
- Env var lookup: lowercase preferred over uppercase (`http_proxy` before `HTTP_PROXY`); `all_proxy` is fallback for either side; if only one of http/https is set it falls back for the other; `no_proxy` is always read when proxy is enabled.
- Invalid `--proxy` value → `ValidationError` at parse time; `--proxy env` with no `*_proxy` vars → fatal at startup; relay bind failure → boot continues with proxy disabled (loud log).
- Code style: `// MARK: -` section markers and doc comments matching neighboring files; no other comments.
- Every task ends with `git commit`; never commit without the tests passing first.
- Run commands from repo root `/Users/y.yadrushnikov/Dev/vphone-cli`.

---

### Task 1: VPhoneProxyConfig (pure parsing + exceptions matching)

**Files:**
- Create: `sources/VPhoneCore/VPhoneProxyConfig.swift`
- Test: `tests/VPhoneCoreTests/ProxyConfigTests.swift`

**Interfaces:**
- Consumes: nothing (leaf type).
- Produces (used by Tasks 2, 5, 6):
  - `public struct VPhoneProxyConfig: Equatable, Sendable` with `var httpsUpstream: Upstream?`, `var httpUpstream: Upstream?`, `var exceptions: [String]`
  - `public enum Upstream: Equatable, Sendable { case http(host: String, port: Int, username: String?, password: String?); case socks5(host: String, port: Int, username: String?, password: String?) }`
  - `public enum ProxyConfigError: Error, Equatable, CustomStringConvertible { case noProxyVariables; case invalidUpstream(String) }`
  - `public static func parseUpstream(_ string: String) throws -> Upstream`
  - `public static func resolve(cliValue: String?, environment: [String: String]) throws -> VPhoneProxyConfig?`
  - `public static func matchesExceptions(_ host: String, exceptions: [String]) -> Bool`
  - `public var summary: String` (e.g. `"https=socks5://127.0.0.1:1080 http=http://proxy.corp:8080"`; `nil` upstream renders as `"-"`)

- [ ] **Step 1: Write the failing tests**

Create `tests/VPhoneCoreTests/ProxyConfigTests.swift`:

```swift
@testable import VPhoneCore
import Testing

struct ProxyConfigTests {
    typealias Upstream = VPhoneProxyConfig.Upstream

    // MARK: - resolve

    @Test func resolveAbsentCLIReturnsNil() throws {
        let config = try VPhoneProxyConfig.resolve(cliValue: nil, environment: ["https_proxy": "http://p:8080"])
        #expect(config == nil)
    }

    @Test func resolveEnvThrowsWhenNoVariables() {
        #expect(throws: ProxyConfigError.noProxyVariables) {
            _ = try VPhoneProxyConfig.resolve(cliValue: "env", environment: [:])
        }
    }

    @Test func resolveEnvSplitsHttpAndHttps() throws {
        let config = try VPhoneProxyConfig.resolve(
            cliValue: "env",
            environment: [
                "https_proxy": "socks5://127.0.0.1:1080",
                "http_proxy": "http://proxy.corp:8080",
                "no_proxy": "example.com, .internal",
            ]
        )
        #expect(config?.httpsUpstream == .socks5(host: "127.0.0.1", port: 1080, username: nil, password: nil))
        #expect(config?.httpUpstream == .http(host: "proxy.corp", port: 8080, username: nil, password: nil))
        #expect(config?.exceptions == ["example.com", ".internal"])
    }

    @Test func resolveEnvFallsBackToAllProxy() throws {
        let config = try VPhoneProxyConfig.resolve(cliValue: "env", environment: ["all_proxy": "socks5://h:1080"])
        #expect(config?.httpsUpstream == .socks5(host: "h", port: 1080, username: nil, password: nil))
        #expect(config?.httpUpstream == .socks5(host: "h", port: 1080, username: nil, password: nil))
    }

    @Test func resolveEnvSingleVarFallsBackForOther() throws {
        let config = try VPhoneProxyConfig.resolve(cliValue: "env", environment: ["https_proxy": "http://p:3128"])
        #expect(config?.httpUpstream == .http(host: "p", port: 3128, username: nil, password: nil))
    }

    @Test func resolveEnvPrefersLowercase() throws {
        let config = try VPhoneProxyConfig.resolve(
            cliValue: "env",
            environment: ["https_proxy": "http://lower:1", "HTTPS_PROXY": "http://upper:2"]
        )
        #expect(config?.httpsUpstream == .http(host: "lower", port: 1, username: nil, password: nil))
    }

    @Test func resolveExplicitURLUsedForBoth() throws {
        let config = try VPhoneProxyConfig.resolve(cliValue: "socks5://127.0.0.1:1080", environment: [:])
        #expect(config?.httpsUpstream == .socks5(host: "127.0.0.1", port: 1080, username: nil, password: nil))
        #expect(config?.httpUpstream == config?.httpsUpstream)
    }

    @Test func resolveExplicitURLStillReadsNoProxy() throws {
        let config = try VPhoneProxyConfig.resolve(cliValue: "http://p:8080", environment: ["no_proxy": "a.com"])
        #expect(config?.exceptions == ["a.com"])
    }

    @Test func resolveInvalidEnvUpstreamThrows() {
        #expect(throws: ProxyConfigError.self) {
            _ = try VPhoneProxyConfig.resolve(cliValue: "env", environment: ["https_proxy": "://bad"])
        }
    }

    // MARK: - parseUpstream

    @Test func parseBareHostPortDefaultsToHTTP() throws {
        let up = try VPhoneProxyConfig.parseUpstream("proxy.corp:8080")
        #expect(up == .http(host: "proxy.corp", port: 8080, username: nil, password: nil))
    }

    @Test func parseHTTPDefaultsPort80() throws {
        let up = try VPhoneProxyConfig.parseUpstream("http://proxy.corp")
        #expect(up == .http(host: "proxy.corp", port: 80, username: nil, password: nil))
    }

    @Test func parseSocks5DefaultsPort1080() throws {
        let up = try VPhoneProxyConfig.parseUpstream("socks5://localhost")
        #expect(up == .socks5(host: "localhost", port: 1080, username: nil, password: nil))
    }

    @Test func parseExtractsCredentials() throws {
        let up = try VPhoneProxyConfig.parseUpstream("http://user:pass@proxy.corp:8080")
        #expect(up == .http(host: "proxy.corp", port: 8080, username: "user", password: "pass"))
    }

    @Test func parseRejectsGarbage() {
        #expect(throws: ProxyConfigError.invalidUpstream("://bad")) {
            _ = try VPhoneProxyConfig.parseUpstream("://bad")
        }
        #expect(throws: ProxyConfigError.self) {
            _ = try VPhoneProxyConfig.parseUpstream("http://")
        }
    }

    // MARK: - exceptions matching

    @Test func exceptionExactMatch() {
        #expect(VPhoneProxyConfig.matchesExceptions("example.com", exceptions: ["example.com"]))
        #expect(!VPhoneProxyConfig.matchesExceptions("api.example.com", exceptions: ["api.example.comx"]))
    }

    @Test func exceptionSuffixMatchesSubdomains() {
        #expect(VPhoneProxyConfig.matchesExceptions("api.example.com", exceptions: ["example.com"]))
        #expect(VPhoneProxyConfig.matchesExceptions("api.example.com", exceptions: [".example.com"]))
        #expect(VPhoneProxyConfig.matchesExceptions("api.example.com", exceptions: ["*.example.com"]))
        #expect(!VPhoneProxyConfig.matchesExceptions("notexample.com", exceptions: ["example.com"]))
    }

    @Test func exceptionWildcardMatchesEverything() {
        #expect(VPhoneProxyConfig.matchesExceptions("anything.net", exceptions: ["*"]))
    }

    @Test func exceptionMatchingIsCaseInsensitive() {
        #expect(VPhoneProxyConfig.matchesExceptions("API.Example.COM", exceptions: ["example.com"]))
    }

    // MARK: - summary

    @Test func summaryRendersBothUpstreams() throws {
        let config = try VPhoneProxyConfig.resolve(
            cliValue: "env",
            environment: ["https_proxy": "socks5://h:1080", "http_proxy": "http://p:8080"]
        )
        #expect(config?.summary == "https=socks5://h:1080 http=http://p:8080")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProxyConfigTests`
Expected: FAIL — cannot find `VPhoneProxyConfig` in scope.

- [ ] **Step 3: Write the implementation**

Create `sources/VPhoneCore/VPhoneProxyConfig.swift`:

```swift
import Foundation

/// Error raised while resolving the proxy configuration.
public enum ProxyConfigError: Error, Equatable, CustomStringConvertible {
    case noProxyVariables
    case invalidUpstream(String)

    public var description: String {
        switch self {
        case .noProxyVariables:
            "--proxy env but none of http_proxy/https_proxy/all_proxy are set"
        case let .invalidUpstream(raw):
            "invalid proxy URL: \(raw)"
        }
    }
}

/// Resolved proxy configuration for the host relay.
public struct VPhoneProxyConfig: Equatable, Sendable {
    public enum Upstream: Equatable, Sendable {
        case http(host: String, port: Int, username: String?, password: String?)
        case socks5(host: String, port: Int, username: String?, password: String?)

        var summary: String {
            switch self {
            case let .http(host, port, username, _):
                "http://\(username.map { "\($0)@" } ?? "")\(host):\(port)"
            case let .socks5(host, port, username, _):
                "socks5://\(username.map { "\($0)@" } ?? "")\(host):\(port)"
            }
        }
    }

    /// Upstream used for CONNECT requests (HTTPS targets).
    public var httpsUpstream: Upstream?
    /// Upstream used for absolute-form plain HTTP requests.
    public var httpUpstream: Upstream?
    /// `no_proxy` entries; hosts matching these bypass the upstream.
    public var exceptions: [String]

    public init(httpsUpstream: Upstream?, httpUpstream: Upstream?, exceptions: [String]) {
        self.httpsUpstream = httpsUpstream
        self.httpUpstream = httpUpstream
        self.exceptions = exceptions
    }

    public var summary: String {
        func desc(_ up: Upstream?) -> String { up?.summary ?? "-" }
        return "https=\(desc(httpsUpstream)) http=\(desc(httpUpstream))"
    }

    // MARK: - Resolution

    /// Resolve the effective proxy config. Returns nil when the feature is off
    /// (no CLI value). `cliValue` is either "env" or an upstream URL.
    public static func resolve(cliValue: String?, environment: [String: String]) throws -> VPhoneProxyConfig? {
        guard let cliValue, !cliValue.isEmpty else { return nil }

        let exceptions = parseExceptions(environment["no_proxy"] ?? environment["NO_PROXY"] ?? "")

        func env(_ names: String...) -> String? {
            for name in names {
                if let value = environment[name], !value.isEmpty { return value }
            }
            return nil
        }

        if cliValue == "env" {
            let httpRaw = env("http_proxy", "HTTP_PROXY")
            let httpsRaw = env("https_proxy", "HTTPS_PROXY")
            let allRaw = env("all_proxy", "ALL_PROXY")
            guard httpRaw != nil || httpsRaw != nil || allRaw != nil else {
                throw ProxyConfigError.noProxyVariables
            }
            func up(_ raw: String?) throws -> Upstream? {
                guard let raw else { return nil }
                return try parseUpstream(raw)
            }
            let httpsUpstream = try up(httpsRaw) ?? up(allRaw) ?? up(httpRaw)
            let httpUpstream = try up(httpRaw) ?? up(allRaw) ?? up(httpsRaw)
            return VPhoneProxyConfig(httpsUpstream: httpsUpstream, httpUpstream: httpUpstream, exceptions: exceptions)
        }

        let upstream = try parseUpstream(cliValue)
        return VPhoneProxyConfig(httpsUpstream: upstream, httpUpstream: upstream, exceptions: exceptions)
    }

    // MARK: - Upstream Parsing

    /// Parse an upstream URL: `http://[user:pass@]host[:port]`, `socks5://…`,
    /// or bare `host:port` (treated as HTTP). Default ports: http 80, socks5 1080.
    public static func parseUpstream(_ string: String) throws -> Upstream {
        var raw = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "http://" + raw }
        guard let url = URL(string: raw), let host = url.host, !host.isEmpty else {
            throw ProxyConfigError.invalidUpstream(string)
        }
        let username = url.user?.removingPercentEncoding
        let password = url.password?.removingPercentEncoding
        switch url.scheme?.lowercased() {
        case "http", "https":
            return .http(host: host, port: url.port ?? 80, username: username, password: password)
        case "socks5", "socks5h":
            return .socks5(host: host, port: url.port ?? 1080, username: username, password: password)
        default:
            throw ProxyConfigError.invalidUpstream(string)
        }
    }

    static func parseExceptions(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    // MARK: - Exceptions Matching

    /// Common `no_proxy` conventions: `*` matches everything; `example.com`,
    /// `.example.com`, and `*.example.com` match the host and its subdomains.
    public static func matchesExceptions(_ host: String, exceptions: [String]) -> Bool {
        let target = host.lowercased()
        for raw in exceptions {
            let entry = raw.lowercased()
            if entry.isEmpty { continue }
            if entry == "*" { return true }
            let suffix = entry.hasPrefix("*.") ? String(entry.dropFirst(1)) : entry
            if target == entry || target == entry.replacingOccurrences(of: "*.", with: "") {
                return true
            }
            if target.hasSuffix(suffix), target.count > suffix.count,
               target.dropLast(suffix.count).hasSuffix(".") {
                return true
            }
        }
        return false
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ProxyConfigTests`
Expected: PASS (all ProxyConfigTests).

Note: `exceptionExactMatch` second line and `exceptionSuffixMatchesSubdomains` fourth line pin down that `notexample.com` must NOT match `example.com` — if a step above makes them fail, fix `matchesExceptions`, not the test.

- [ ] **Step 5: Commit**

```bash
git add sources/VPhoneCore/VPhoneProxyConfig.swift tests/VPhoneCoreTests/ProxyConfigTests.swift
git commit -m "feat(proxy): add VPhoneProxyConfig upstream and no_proxy resolution"
```

---

### Task 2: VPhoneProxyRelay (host-side HTTP CONNECT relay)

**Files:**
- Create: `sources/VPhoneCore/VPhoneProxyRelay.swift`
- Test: `tests/VPhoneCoreTests/ProxyRelayTests.swift`

**Interfaces:**
- Consumes: `VPhoneProxyConfig` (Task 1) — `Upstream`, `exceptions`, `matchesExceptions`.
- Produces (used by Tasks 5, 6):
  - `public final class VPhoneProxyRelay: @unchecked Sendable`
  - `public init(config: VPhoneProxyConfig)`
  - `public func start() throws` — binds `0.0.0.0:0`, listens, spawns accept thread
  - `public func stop()`
  - `public private(set) var port: UInt16` — assigned port after `start()`
  - `public func updateAllowedIPs(_ ips: Set<String>)` — peer-IP allowlist; empty set rejects everyone

- [ ] **Step 1: Write the failing tests**

Create `tests/VPhoneCoreTests/ProxyRelayTests.swift` (test helpers use Network.framework listeners as in-process fake upstreams / origins):

```swift
@testable import VPhoneCore
import Foundation
import Network
import Testing

// MARK: - Test helpers

final class TestTCPServer {
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
            conn.stateUpdateHandler = { state in
                if case .ready = state { cont.resume() }
                if case let .failed(error) = state { cont.resume(throwing: error) }
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
final class FakeHTTPProxy {
    let server: TestTCPServer
    var receivedConnect: String?

    init() throws {
        server = try TestTCPServer()
        server.onAccept = { conn in
            conn.start(queue: .global())
            Task {
                do {
                    let head = try await nwReceiveHead(conn)
                    self.receivedConnect = head
                    if head.hasPrefix("CONNECT") {
                        try await nwSend(conn, Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8))
                        await nwEchoForever(conn)
                    } else {
                        await nwEchoForever(conn)
                    }
                } catch {}
            }
        }
    }
}

/// Minimal SOCKS5 proxy: no-auth handshake, connect by domain, then echoes.
final class FakeSOCKS5Proxy {
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
        #expect(throws: (any Error).self) {
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProxyRelayTests`
Expected: FAIL — cannot find `VPhoneProxyRelay` in scope.

- [ ] **Step 3: Write the implementation**

Create `sources/VPhoneCore/VPhoneProxyRelay.swift`:

```swift
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

    public func updateAllowedIPs(_ ips: Set<String>) {
        lock.lock()
        allowedIPs = ips
        lock.unlock()
    }

    public func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RelayError.bindFailed("socket") }
        let one: Int32 = 1
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
        withUnsafeMutablePointer(to: &sin) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                if getsockname(fd, $0, &len) == 0 {
                    actualPort = sin.sin_port.byteSwapped
                }
            }
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
            withUnsafeMutablePointer(to: &peer) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    if getpeername(client, $0, &peerLen) == 0 {
                        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        if inet_ntop(AF_INET, &peer.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                            peerIP = String(cString: buf)
                        }
                    }
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

    static func handle(clientFD: Int32, config: VPhoneProxyConfig) {
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
            handleConnect(clientFD: clientFD, host: host, port: port, config: config)
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
            do {
                let originFD = try dialTCP(host: host, port: port)
                _ = writeAll(fd: originFD, data: rewrittenHead)
                runTunnels(clientFD, originFD)
                return
            } catch {
                writeSimpleResponse(fd: clientFD, status: "502 Bad Gateway")
                close(clientFD)
                return
            }
        }

        switch config.httpUpstream {
        case let .http(upHost, upPort, user, pass):
            do {
                let upFD = try dialTCP(host: upHost, port: UInt16(upPort))
                try httpConnectUpstream(fd: upFD, host: host, port: port, username: user, password: pass, connectOnly: false)
                _ = writeAll(fd: upFD, data: head)
                runTunnels(clientFD, upFD)
            } catch {
                writeSimpleResponse(fd: clientFD, status: "502 Bad Gateway")
                close(clientFD)
            }
        case let .socks5(upHost, upPort, user, pass):
            do {
                let upFD = try dialTCP(host: upHost, port: UInt16(upPort))
                try socks5Connect(fd: upFD, host: host, port: port, username: user, password: pass)
                _ = writeAll(fd: upFD, data: rewrittenHead)
                runTunnels(clientFD, upFD)
            } catch {
                writeSimpleResponse(fd: clientFD, status: "502 Bad Gateway")
                close(clientFD)
            }
        case nil:
            writeSimpleResponse(fd: clientFD, status: "502 Bad Gateway")
            close(clientFD)
        }
    }

    static func handleConnect(clientFD: Int32, host: String, port: UInt16, config: VPhoneProxyConfig) {
        if VPhoneProxyConfig.matchesExceptions(host, exceptions: config.exceptions) {
            do {
                let targetFD = try dialTCP(host: host, port: port)
                writeSimpleResponse(fd: clientFD, status: "200 Connection Established")
                runTunnels(clientFD, targetFD)
                return
            } catch {
                writeSimpleResponse(fd: clientFD, status: "502 Bad Gateway")
                close(clientFD)
                return
            }
        }

        let upstream = config.httpsUpstream ?? config.httpUpstream
        switch upstream {
        case let .http(upHost, upPort, user, pass):
            do {
                let upFD = try dialTCP(host: upHost, port: UInt16(upPort))
                try httpConnectUpstream(fd: upFD, host: host, port: port, username: user, password: pass, connectOnly: true)
                writeSimpleResponse(fd: clientFD, status: "200 Connection Established")
                runTunnels(clientFD, upFD)
            } catch {
                writeSimpleResponse(fd: clientFD, status: "502 Bad Gateway")
                close(clientFD)
            }
        case let .socks5(upHost, upPort, user, pass):
            do {
                let upFD = try dialTCP(host: upHost, port: UInt16(upPort))
                try socks5Connect(fd: upFD, host: host, port: port, username: user, password: pass)
                writeSimpleResponse(fd: clientFD, status: "200 Connection Established")
                runTunnels(clientFD, upFD)
            } catch {
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

    static func httpConnectUpstream(
        fd: Int32, host: String, port: UInt16,
        username: String?, password: String?, connectOnly: Bool
    ) throws {
        if !connectOnly { return }
        var request = "CONNECT \(host):\(port) HTTP/1.1\r\nHost: \(host):\(port)\r\n"
        if let username, let password {
            let raw = Data("\(username):\(password)".utf8)
            request += "Proxy-Authorization: Basic \(raw.base64EncodedString())\r\n"
        }
        request += "\r\n"
        try writeAllChecked(fd: fd, data: Data(request.utf8))
        guard let response = readHead(fd: fd), let text = String(
            decoding: response, as: UTF8.self
        ).split(separator: "\r\n").first else {
            throw RelayError.upstreamFailed("no CONNECT response")
        }
        let code = text.split(separator: " ").dropFirst().first.map { Int($0.prefix(3)) ?? 0 } ?? 0
        guard (200..<300).contains(code) else {
            throw RelayError.upstreamFailed("CONNECT rejected: \(text)")
        }
    }

    static func socks5Connect(
        fd: Int32, host: String, port: UInt16, username: String?, password: String?
    ) throws {
        let hasAuth = username != nil && password != nil
        try writeAllChecked(fd: fd, data: hasAuth ? Data([0x05, 0x02, 0x00, 0x02]) : Data([0x05, 0x01, 0x00]))
        guard let method = try readExact(fd: fd, count: 2), method.count == 2,
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
            guard let authResp = try readExact(fd: fd, count: 2), authResp[authResp.startIndex + 1] == 0x00 else {
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

        guard let reply = try readExact(fd: fd, count: 4), reply[reply.startIndex] == 0x05,
              reply[reply.startIndex + 1] == 0x00 else {
            throw RelayError.upstreamFailed("socks5 connect rejected")
        }
        let atyp = reply[reply.startIndex + 3]
        let skip: Int
        switch atyp {
        case 0x01: skip = 4
        case 0x03:
            guard let lenByte = try readExact(fd: fd, count: 1) else {
                throw RelayError.upstreamFailed("socks5 reply truncated")
            }
            skip = Int(lenByte[lenByte.startIndex])
        case 0x04: skip = 16
        default: throw RelayError.upstreamFailed("socks5 reply atyp")
        }
        guard let _ = try readExact(fd: fd, count: skip + 2) else {
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

    static func pipe(_ from: Int32, to: Int32) {
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
    static func runTunnels(_ a: Int32, _ b: Int32) {
        let counter = OSAllocatedUnfairLock(initialState: 2)
        Thread.detachNewThread {
            Self.pipe(a, b)
            shutdown(a, SHUT_RDWR)
            shutdown(b, SHUT_RDWR)
            if counter.withLock({ $0 -= 1; return $0 }) == 0 {
                close(a)
                close(b)
            }
        }
        Self.pipe(b, a)
        shutdown(a, SHUT_RDWR)
        shutdown(b, SHUT_RDWR)
        if counter.withLock({ $0 -= 1; return $0 }) == 0 {
            close(a)
            close(b)
        }
    }
}
```

Implementation notes for the implementer:
- `addr.sin_port.byteSwapped` — `sin_port` is network byte order on Darwin; `byteSwapped` converts to host order.
- `httpConnectUpstream(connectOnly:)` — the `connectOnly` flag exists so the same dialer serves CONNECT (speaks CONNECT to the upstream) and plain-HTTP verbatim forwarding (returns immediately; the raw head is then written by the caller).
- If `connectTunnelsThroughHTTPUpstream` flakes because the fake proxy echoes only after reading the head, re-check `nwEchoForever` starts after `nwSend` of the 200 — ordering is intentional.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ProxyRelayTests`
Expected: PASS (all 7 relay tests). If `unreachableUpstreamYields502` is flaky, port 1 on loopback must refuse — it does on macOS (`connection refused`).

- [ ] **Step 5: Run the whole VPhoneCore test suite**

Run: `swift test --filter VPhoneCoreTests`
Expected: PASS — no regressions in NetworkingTests / ManifestTests / BundleReportTests.

- [ ] **Step 6: Commit**

```bash
git add sources/VPhoneCore/VPhoneProxyRelay.swift tests/VPhoneCoreTests/ProxyRelayTests.swift
git commit -m "feat(proxy): add guest-allowlisted HTTP CONNECT relay with HTTP/SOCKS5 chaining"
```

---

### Task 3: VPhoneControl proxy requests

**Files:**
- Modify: `sources/vphone-cli/VPhoneControl.swift`

**Interfaces:**
- Consumes: existing `sendRequest(_:)` machinery.
- Produces (used by Tasks 5, 6):
  - `struct ProxyGuestState { let enabled: Bool; let host: String?; let port: Int?; let exceptions: [String] }`
  - `func sendProxySet(port: Int, exceptions: [String]) async throws -> String` — returns guest-side proxy host (gateway IP)
  - `func sendProxyClear() async throws`
  - `func sendProxyGet() async throws -> ProxyGuestState`

No unit tests: `VPhoneControl` is `@MainActor` and requires a live `VZVirtioSocketDevice`; these are thin wrappers over the already-tested `sendRequest` framing (guest side is covered in Task 4 and manual verification). Verification for this task is compilation of the target.

- [ ] **Step 1: Add the request/response methods**

In `sources/vphone-cli/VPhoneControl.swift`, add a new section after the `// MARK: - Settings` section (after the `lowPowerMode` function, before `// MARK: - Accessibility`):

```swift
    // MARK: - Proxy

    struct ProxyGuestState {
        let enabled: Bool
        let host: String?
        let port: Int?
        let exceptions: [String]
    }

    /// Configure the guest system-wide HTTP proxy to point at `port` on the
    /// guest's default-route gateway (the host relay). Returns the gateway IP.
    func sendProxySet(port: Int, exceptions: [String]) async throws -> String {
        let (resp, _) = try await sendRequest(["t": "proxy_set", "port": port, "exceptions": exceptions] as [String: Any])
        guard resp["ok"] as? Bool == true, let host = resp["host"] as? String else {
            throw ControlError.guestError(resp["msg"] as? String ?? "proxy_set failed")
        }
        return host
    }

    func sendProxyClear() async throws {
        let (resp, _) = try await sendRequest(["t": "proxy_clear"] as [String: Any])
        guard resp["ok"] as? Bool == true else {
            throw ControlError.guestError(resp["msg"] as? String ?? "proxy_clear failed")
        }
    }

    func sendProxyGet() async throws -> ProxyGuestState {
        let (resp, _) = try await sendRequest(["t": "proxy_get"] as [String: Any])
        return ProxyGuestState(
            enabled: resp["enabled"] as? Bool ?? false,
            host: resp["host"] as? String,
            port: resp["port"] as? Int,
            exceptions: resp["exceptions"] as? [String] ?? []
        )
    }
```

- [ ] **Step 2: Add proxy requests to the slow timeout class**

In the same file, in `timeoutForRequest(type:)`, change the slow-request case to include the proxy types:

```swift
        case "devmode", "file_list", "file_delete", "file_rename", "file_mkdir", "keychain_list",
             "app_list", "app_launch", "open_url", "accessibility_tree", "proxy_set", "proxy_clear",
             "proxy_get":
            slowRequestTimeout
```

(SCPreferences commit/apply on the guest can take a few seconds — 30s budget.)

- [ ] **Step 3: Verify compilation**

Run: `swift build 2>&1 | tail -5`
Expected: build succeeds with no errors.

- [ ] **Step 4: Commit**

```bash
git add sources/vphone-cli/VPhoneControl.swift
git commit -m "feat(proxy): add proxy_set/clear/get vsock requests to VPhoneControl"
```

---

### Task 4: vphoned guest handler (proxy capability)

**Files:**
- Create: `scripts/vphoned/vphoned_proxy.h`
- Create: `scripts/vphoned/vphoned_proxy.m`
- Modify: `scripts/vphoned/vphoned.m` (dispatch + caps)
- Modify: `scripts/vphoned/Makefile` (SystemConfiguration framework)

**Interfaces:**
- Consumes: `vp_make_response` from `vphoned_protocol.h`; message fields from Task 3 (`t`, `id`, `port`, `exceptions`).
- Produces: guest handles `proxy_set` / `proxy_clear` / `proxy_get`; hello caps gain `"proxy"`; responses carry `ok`, `host`, `enabled`, `port`, `exceptions`, `msg` on errors.

No unit tests (guest iOS code); verification is the cross-compile build check plus manual boot test.

- [ ] **Step 1: Create the header**

Create `scripts/vphoned/vphoned_proxy.h`:

```objc
/*
 * vphoned_proxy — System-wide HTTP proxy configuration via SCPreferences.
 */

#pragma once
#import <Foundation/Foundation.h>

/// Handle proxy_* commands: proxy_set / proxy_clear / proxy_get.
NSDictionary *vp_handle_proxy_command(NSDictionary *msg);
```

- [ ] **Step 2: Create the implementation**

Create `scripts/vphoned/vphoned_proxy.m`:

```objc
#import "vphoned_proxy.h"
#import "vphoned_protocol.h"
#import <SystemConfiguration/SystemConfiguration.h>

// MARK: - Helpers

/// Active global IPv4 entity: { Router, ServiceID, Addresses, ... } or nil.
static NSDictionary *global_ipv4(void) {
  SCDynamicStoreRef store =
      SCDynamicStoreCreate(NULL, CFSTR("vphoned"), NULL, NULL);
  if (!store)
    return nil;
  CFPropertyListRef value =
      SCDynamicStoreCopyValue(store, CFSTR("State:/Network/Global/IPv4"),
                              NULL, NULL);
  CFRelease(store);
  if (!value)
    return nil;
  return (NSDictionary *)CFBridgingRelease(value);
}

static NSString *service_proxies_path(NSString *serviceID) {
  return [NSString stringWithFormat:@"/Setup:/Network/Service/%@/Proxies",
                                    serviceID];
}

static NSMutableDictionary *read_proxies(SCPreferencesRef prefs,
                                         NSString *serviceID) {
  CFPropertyListRef v = SCPreferencesPathGetValue(
      prefs, (__bridge CFStringRef)service_proxies_path(serviceID));
  if (!v)
    return [NSMutableDictionary dictionary];
  return [NSMutableDictionary dictionaryWithDictionary:(__bridge id)v];
}

static BOOL write_proxies(SCPreferencesRef prefs, NSString *serviceID,
                          NSDictionary *proxies) {
  return SCPreferencesPathSetValue(
             prefs, (__bridge CFStringRef)service_proxies_path(serviceID),
             (__bridge CFPropertyListRef)proxies) &&
         SCPreferencesCommitChanges(prefs) &&
         SCPreferencesApplyChanges(prefs);
}

// MARK: - Command Handler

NSDictionary *vp_handle_proxy_command(NSDictionary *msg) {
  NSString *type = msg[@"t"];
  id reqId = msg[@"id"];

  NSDictionary *global = global_ipv4();
  NSString *router = global[@"Router"];
  NSString *serviceID = global[@"ServiceID"];

  // -- proxy_set --
  if ([type isEqualToString:@"proxy_set"]) {
    if (router.length == 0 || serviceID.length == 0) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"no global IPv4 route (network down?)";
      return r;
    }
    int port = [msg[@"port"] intValue];
    if (port <= 0 || port > 65535) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"missing or invalid port";
      return r;
    }

    NSArray *incoming = msg[@"exceptions"];
    NSMutableArray *exceptions = [@[ @"127.0.0.1", @"localhost", @"*.local",
                                     @"169.254.0.0/16", @"::1" ] mutableCopy];
    for (id entry in incoming) {
      if ([entry isKindOfClass:[NSString class]] &&
          ![exceptions containsObject:entry])
        [exceptions addObject:entry];
    }

    NSDictionary *proxies = @{
      @"HTTPEnable" : @1,
      @"HTTPProxy" : router,
      @"HTTPPort" : @(port),
      @"HTTPSEnable" : @1,
      @"HTTPSProxy" : router,
      @"HTTPSPort" : @(port),
      @"ProxyAutoDiscoveryEnable" : @0,
      @"ExceptionsList" : exceptions,
    };

    SCPreferencesRef prefs =
        SCPreferencesCreate(NULL, CFSTR("vphoned"), NULL);
    if (!prefs) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"SCPreferencesCreate failed";
      return r;
    }
    BOOL ok = write_proxies(prefs, serviceID, proxies);
    CFRelease(prefs);
    if (!ok) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"SCPreferences commit/apply failed";
      return r;
    }

    NSMutableDictionary *r = vp_make_response(@"proxy_set", reqId);
    r[@"ok"] = @YES;
    r[@"host"] = router;
    return r;
  }

  // -- proxy_clear --
  if ([type isEqualToString:@"proxy_clear"]) {
    if (serviceID.length == 0) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"no global IPv4 route (network down?)";
      return r;
    }
    NSDictionary *proxies = @{
      @"HTTPEnable" : @0,
      @"HTTPSEnable" : @0,
      @"ProxyAutoDiscoveryEnable" : @0,
    };
    SCPreferencesRef prefs =
        SCPreferencesCreate(NULL, CFSTR("vphoned"), NULL);
    if (!prefs) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"SCPreferencesCreate failed";
      return r;
    }
    BOOL ok = write_proxies(prefs, serviceID, proxies);
    CFRelease(prefs);
    if (!ok) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"SCPreferences commit/apply failed";
      return r;
    }
    NSMutableDictionary *r = vp_make_response(@"proxy_clear", reqId);
    r[@"ok"] = @YES;
    return r;
  }

  // -- proxy_get --
  if ([type isEqualToString:@"proxy_get"]) {
    if (serviceID.length == 0) {
      NSMutableDictionary *r = vp_make_response(@"proxy_get", reqId);
      r[@"enabled"] = @NO;
      return r;
    }
    SCPreferencesRef prefs =
        SCPreferencesCreate(NULL, CFSTR("vphoned"), NULL);
    if (!prefs) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"SCPreferencesCreate failed";
      return r;
    }
    NSDictionary *proxies = read_proxies(prefs, serviceID);
    CFRelease(prefs);
    BOOL enabled = [proxies[@"HTTPEnable"] boolValue] ||
                   [proxies[@"HTTPSEnable"] boolValue];
    NSMutableDictionary *r = vp_make_response(@"proxy_get", reqId);
    r[@"enabled"] = @(enabled);
    r[@"host"] = proxies[@"HTTPProxy"];
    r[@"port"] = proxies[@"HTTPPort"];
    r[@"exceptions"] = proxies[@"ExceptionsList"] ?: @[];
    return r;
  }

  NSMutableDictionary *r = vp_make_response(@"err", reqId);
  r[@"msg"] = [NSString stringWithFormat:@"unknown proxy command: %@", type];
  return r;
}
```

- [ ] **Step 3: Wire dispatch and capability in vphoned.m**

In `scripts/vphoned/vphoned.m`:

1. Add the import next to the other `vphoned_*.h` imports:

```objc
#import "vphoned_proxy.h"
```

2. In `handle_client`, in the capabilities block (after `[caps addObject:@"settings"];` and before `[caps addObject:@"touch"];`), add:

```objc
    [caps addObject:@"proxy"];
```

3. In the command dispatch loop, add a block after the Settings block (`if ([t hasPrefix:@"settings_"] { ... }`) and before the Accessibility block:

```objc
        // Proxy configuration
        if ([t hasPrefix:@"proxy_"]) {
          NSDictionary *resp = vp_handle_proxy_command(msg);
          if (resp && !vp_write_message(fd, resp))
            break;
          continue;
        }
```

- [ ] **Step 4: Link SystemConfiguration in the Makefile**

In `scripts/vphoned/Makefile`, extend the link line (after `-framework CoreServices`):

```makefile
		-framework SystemConfiguration
```

Full link line becomes:

```makefile
	xcrun -sdk iphoneos clang -arch arm64 -Os -fobjc-arc \
		-I. \
		-Ivendor/libarchive \
		-DVPHONED_BUILD_HASH='"$(GIT_HASH)"' \
		-o $@ $(SRCS) \
		-larchive \
		-lsqlite3 \
		-framework Foundation \
		-framework Security \
		-framework CoreServices \
		-framework SystemConfiguration
```

- [ ] **Step 5: Verify the cross-compile build**

Run: `make -C scripts/vphoned`
Expected: `built OK`. Fix any ObjC compile errors before committing.

- [ ] **Step 6: Commit**

```bash
git add scripts/vphoned/vphoned_proxy.h scripts/vphoned/vphoned_proxy.m scripts/vphoned/vphoned.m scripts/vphoned/Makefile
git commit -m "feat(proxy): vphoned proxy_set/clear/get via SCPreferences + proxy capability"
```

---

### Task 5: CLI flag + AppDelegate integration

**Files:**
- Modify: `sources/vphone-cli/VPhoneCLI.swift` (`VPhoneBootCLI`)
- Modify: `sources/vphone-cli/VPhoneAppDelegate.swift`

**Interfaces:**
- Consumes: `VPhoneProxyConfig.resolve/parseUpstream` (Task 1), `VPhoneProxyRelay` (Task 2), `VPhoneControl.sendProxySet` (Task 3).
- Produces: `vphone-cli boot --proxy env|--proxy <url>`; relay started pre-boot; guest auto-apply on vphoned connect (GUI and headless); `VPhoneAppDelegate.proxyRelay` / `proxyConfig` properties consumed by Task 6.

No unit tests (AppKit application object); verification is build + CLI validation runs.

- [ ] **Step 1: Add the --proxy option**

In `sources/vphone-cli/VPhoneCLI.swift`, in `VPhoneBootCLI`, add after the `noVphoned` flag declaration:

```swift
    @Option(
        help: """
        Proxy the guest through a host-side relay. Use 'env' to read \
        http_proxy/https_proxy/all_proxy (and no_proxy) from the environment, \
        or an upstream URL like http://proxy.corp:8080 or socks5://127.0.0.1:1080. \
        Omit to leave the guest network untouched.
        """
    )
    var proxy: String?
```

- [ ] **Step 2: Validate the value at parse time**

In the same struct, extend `validate()` — add before the final closing brace of the method (after the `installIPA` checks):

```swift
        if let proxy, proxy != "env" {
            do {
                _ = try VPhoneProxyConfig.parseUpstream(proxy)
            } catch {
                throw ValidationError(
                    "`--proxy` must be 'env' or a URL (http:// or socks5://), got: \(proxy)")
            }
        }
```

- [ ] **Step 3: Add relay state + startup in VPhoneAppDelegate**

In `sources/vphone-cli/VPhoneAppDelegate.swift`:

1. Add stored properties after `private var sigintSource: DispatchSourceSignal?`:

```swift
    private var proxyRelay: VPhoneProxyRelay?
    private var proxyConfig: VPhoneProxyConfig?
```

2. In `startVirtualMachine()`, immediately before `let vm = try VPhoneVirtualMachine(options: options)`, add:

```swift
        try startProxyIfNeeded()
```

3. Add the two methods after `startVirtualMachine()` (before `installPackageIfRequested`):

```swift
    @MainActor
    private func startProxyIfNeeded() throws {
        guard let cliProxy = cli.proxy else { return }
        guard let config = try VPhoneProxyConfig.resolve(
            cliValue: cliProxy, environment: ProcessInfo.processInfo.environment
        ) else { return }

        let relay = VPhoneProxyRelay(config: config)
        do {
            try relay.start()
        } catch {
            print("[proxy] relay failed to start (\(error)) — proxy disabled")
            return
        }
        print("[proxy] relay :\(relay.port), upstream \(config.summary)")
        proxyConfig = config
        proxyRelay = relay
    }

    @MainActor
    private func applyProxyToGuest(caps: [String]) async {
        guard let relay = proxyRelay, let config = proxyConfig, let control else { return }
        if let ip = control.guestIP {
            relay.updateAllowedIPs([ip])
        }
        guard caps.contains("proxy") else {
            print("[proxy] guest does not support proxy capability")
            return
        }
        do {
            let host = try await control.sendProxySet(port: Int(relay.port), exceptions: config.exceptions)
            print("[proxy] guest proxy -> \(host):\(relay.port) via \(config.summary)")
        } catch {
            print("[proxy] failed to apply guest proxy: \(error)")
        }
    }
```

- [ ] **Step 4: Auto-apply on vphoned connect (both branches)**

In `startVirtualMachine()`:

1. GUI branch — in `control.onConnect`, extend the existing trailing Task so it reads:

```swift
                Task { @MainActor [weak self] in
                    await self?.installPackageIfRequested(caps: caps)
                    await self?.applyProxyToGuest(caps: caps)
                }
```

2. Headless branch — extend its trailing Task the same way:

```swift
                Task { @MainActor [weak self] in
                    await self?.installPackageIfRequested(caps: caps)
                    await self?.applyProxyToGuest(caps: caps)
                }
```

3. Stop the relay on terminate — in `applicationWillTerminate(_:)`, after `hostControl?.stop()`:

```swift
        proxyRelay?.stop()
```

4. Hand the relay/config to the menu controller (Task 6 consumes these) — in the GUI branch, after `menuController = mc`:

```swift
            mc.proxyRelay = proxyRelay
            mc.proxyConfig = proxyConfig
            mc.refreshProxyInfo()
```

(The menu is built during `VPhoneMenuController.init`, which runs before this assignment — `refreshProxyInfo()` rewrites the info-item titles with the now-known relay/config.)

- [ ] **Step 5: Build and verify CLI validation**

Run: `make build 2>&1 | tail -5`
Expected: build succeeds (signed binary via the Makefile wrapper — never plain `swift build` for runtime use). Note the built binary path from the Makefile output (`BINARY`, e.g. `.build/debug/vphone-cli`).

Run (using that binary path, `$BIN` below): `$BIN boot --config /nonexistent.plist --proxy garbage://x 2>&1; echo "exit=$?"`
Expected: `ValidationError` message about `--proxy`, non-zero exit — validation fires before the config file is loaded.

Run: `$BIN boot --help 2>&1 | grep -A4 "proxy"`
Expected: the `--proxy` help text appears (note: it is a subcommand option — `boot --help`, not the top-level `--help`).

- [ ] **Step 6: Commit**

```bash
git add sources/vphone-cli/VPhoneCLI.swift sources/vphone-cli/VPhoneAppDelegate.swift
git commit -m "feat(proxy): --proxy option with host relay lifecycle and guest auto-apply"
```

---

### Task 6: Connect menu — Proxy submenu

**Files:**
- Modify: `sources/vphone-cli/VPhoneMenuController.swift`
- Modify: `sources/vphone-cli/VPhoneMenuConnect.swift`
- Modify: `sources/vphone-cli/VPhoneAppDelegate.swift` (availability wiring)

**Interfaces:**
- Consumes: `VPhoneControl.sendProxySet/sendProxyClear/sendProxyGet` (Task 3), `mc.proxyRelay` / `mc.proxyConfig` (Task 5), existing `makeItem` / `showAlert` patterns.
- Produces: `VPhoneMenuController.updateProxyAvailability(available:)` called from AppDelegate; menu items `proxyApplyItem`, `proxyClearItem`, `proxyGuestStatusItem`.

- [ ] **Step 1: Add stored properties**

1. Add stored properties after the `settingsSetItem` property:

```swift
    var proxyRelay: VPhoneProxyRelay?
    var proxyConfig: VPhoneProxyConfig?
    var proxyUpstreamItem: NSMenuItem?
    var proxyRelayItem: NSMenuItem?
    var proxyGuestStatusItem: NSMenuItem?
    var proxyApplyItem: NSMenuItem?
    var proxyClearItem: NSMenuItem?
```

- [ ] **Step 2: Build the submenu and actions**

In `sources/vphone-cli/VPhoneMenuConnect.swift`:

1. In `buildConnectMenu()`, after `menu.addItem(buildCameraSubmenu())`, add:

```swift
        menu.addItem(buildProxySubmenu())
```

2. Add the submenu builder and actions at the end of the extension:

```swift
    // MARK: - Proxy

    func buildProxySubmenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Proxy")
        menu.autoenablesItems = false

        let upstream = NSMenuItem(
            title: "Upstream: \(proxyConfig?.summary ?? "off")", action: nil, keyEquivalent: "")
        upstream.isEnabled = false
        proxyUpstreamItem = upstream
        menu.addItem(upstream)

        let relayItem = NSMenuItem(
            title: proxyRelay.map { "Relay: :\($0.port)" } ?? "Relay: off", action: nil,
            keyEquivalent: "")
        relayItem.isEnabled = false
        proxyRelayItem = relayItem
        menu.addItem(relayItem)

        let status = makeItem("Guest: unknown", action: #selector(proxyGuestStatus))
        status.isEnabled = false
        proxyGuestStatusItem = status
        menu.addItem(status)

        menu.addItem(NSMenuItem.separator())

        let apply = makeItem("Apply from Host Config", action: #selector(proxyApply))
        apply.isEnabled = false
        proxyApplyItem = apply
        menu.addItem(apply)

        let clear = makeItem("Clear in Guest", action: #selector(proxyClear))
        clear.isEnabled = false
        proxyClearItem = clear
        menu.addItem(clear)

        item.submenu = menu
        return item
    }

    func refreshProxyInfo() {
        proxyUpstreamItem?.title = "Upstream: \(proxyConfig?.summary ?? "off")"
        proxyRelayItem?.title = proxyRelay.map { "Relay: :\($0.port)" } ?? "Relay: off"
    }

    func updateProxyAvailability(available: Bool) {
        refreshProxyInfo()
        proxyGuestStatusItem?.isEnabled = available
        proxyApplyItem?.isEnabled = available && proxyRelay != nil
        proxyClearItem?.isEnabled = available
    }

    @objc func proxyGuestStatus() {
        Task { @MainActor in
            do {
                let state = try await control.sendProxyGet()
                let detail = state.enabled
                    ? "on (\(state.host ?? "?"):\(state.port.map(String.init) ?? "?"))"
                    : "off"
                proxyGuestStatusItem?.title = "Guest: \(detail)"
                showAlert(title: "Guest Proxy", message: "Guest proxy is \(detail).", style: .informational)
            } catch {
                showAlert(title: "Guest Proxy", message: "\(error)", style: .warning)
            }
        }
    }

    @objc func proxyApply() {
        Task { @MainActor in
            guard let relay = proxyRelay, let config = proxyConfig else {
                showAlert(title: "Proxy", message: "No host proxy config (start with --proxy).", style: .warning)
                return
            }
            do {
                let host = try await control.sendProxySet(
                    port: Int(relay.port), exceptions: config.exceptions)
                proxyGuestStatusItem?.title = "Guest: on (\(host):\(relay.port))"
                showAlert(
                    title: "Proxy",
                    message: "Guest proxy set to \(host):\(relay.port) via \(config.summary).",
                    style: .informational)
            } catch {
                showAlert(title: "Proxy", message: "\(error)", style: .warning)
            }
        }
    }

    @objc func proxyClear() {
        Task { @MainActor in
            do {
                try await control.sendProxyClear()
                proxyGuestStatusItem?.title = "Guest: off"
                showAlert(title: "Proxy", message: "Guest proxy cleared.", style: .informational)
            } catch {
                showAlert(title: "Proxy", message: "\(error)", style: .warning)
            }
        }
    }
```

- [ ] **Step 3: Wire availability from AppDelegate**

In `sources/vphone-cli/VPhoneAppDelegate.swift`, in the GUI branch:

1. In `control.onConnect`, after `mc?.updateSettingsAvailability(available: true)`:

```swift
                mc?.updateProxyAvailability(available: caps.contains("proxy"))
```

2. In `control.onDisconnect`, after `mc?.updateSettingsAvailability(available: false)`:

```swift
                mc?.updateProxyAvailability(available: false)
```

- [ ] **Step 4: Build and run the full verification**

Run: `make build 2>&1 | tail -5`
Expected: build succeeds.

Run: `swift test --filter VPhoneCoreTests 2>&1 | tail -5`
Expected: PASS (all suites, no regressions).

Run: `make -C scripts/vphoned`
Expected: `built OK`.

- [ ] **Step 5: Manual verification checklist (documented for the user, requires SIP/AMFI-disabled host + a prepared VM)**

1. Start mitmproxy on the host: `mitmproxy --listen-port 8888` (or `mitmdump`).
2. Boot with env proxy: `https_proxy=http://127.0.0.1:8888 http_proxy=http://127.0.0.1:8888 make boot -- --proxy env` (or export vars then run the boot target).
3. Expect log lines: `[proxy] relay :<port>, upstream https=http://127.0.0.1:8888 ...` and `[proxy] guest proxy -> 192.168.x.1:<port> ...`.
4. In the guest, open Safari and load an HTTPS page — expect it to load and the request to appear in mitmproxy.
5. Host-side allowlist check: `curl -x http://127.0.0.1:<relay-port> http://example.com` — expect immediate rejection (connection reset), proving the relay is not an open proxy.
6. Menu check: Connect → Proxy → Guest status shows on; Clear in Guest → Safari loses internet; Apply from Host Config → restored.
7. Old-guest check: without rebuilding/patching the guest firmware, boot with `--proxy env` — expect `[proxy] guest does not support proxy capability` (graceful).

- [ ] **Step 6: Commit**

```bash
git add sources/vphone-cli/VPhoneMenuController.swift sources/vphone-cli/VPhoneMenuConnect.swift sources/vphone-cli/VPhoneAppDelegate.swift
git commit -m "feat(proxy): Connect menu Proxy submenu with status, apply, and clear"
```

---

## Final verification (after all tasks)

- [ ] `swift test --filter VPhoneCoreTests` — all pass
- [ ] `make build` — signed binary builds
- [ ] `make -C scripts/vphoned` — guest daemon cross-compiles
- [ ] `git log --oneline` shows one commit per task, working tree clean

## Notes for executors

- The guest gets the new vphoned via the existing hash-based auto-update on next connect (`.vphoned.signed` is rebuilt by `make vphoned` / `make boot`); alternatively re-patch/reinstall firmware.
- No firmware patches are applied by this feature, so `research/0_binary_patch_comparison.md` does not need updating (per AGENTS.md it tracks binary patches only).
- Do not run `swift build` alone for runtime verification — the binary requires entitlements; always `make build`.
