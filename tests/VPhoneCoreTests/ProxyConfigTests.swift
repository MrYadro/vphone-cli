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
