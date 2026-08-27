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
            let bare = suffix.hasPrefix(".") ? String(suffix.dropFirst()) : suffix
            if target == bare || target == suffix {
                return true
            }
            guard target.hasSuffix(suffix), target.count > suffix.count else { continue }
            if suffix.hasPrefix(".") || target.dropLast(suffix.count).hasSuffix(".") {
                return true
            }
        }
        return false
    }
}
