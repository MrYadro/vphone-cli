# Proxy Support Design (http_proxy / https_proxy / all_proxy)

**Date:** 2026-08-27
**Status:** Approved design, pending implementation

## Goal

Give the iOS guest working internet access when the host sits behind an HTTP or
SOCKS5 proxy, using the standard `http_proxy` / `https_proxy` / `all_proxy`
environment variables (or an explicit CLI URL). The feature is strictly opt-in:
without `--proxy`, nothing changes.

## Non-Goals

- Transparently proxying apps that ignore iOS proxy settings (VPN-style capture).
- PAC files, authenticated SOCKS5 beyond user/pass, chained relays.
- Persisting proxy config in the VM manifest (host-runtime concern only).
- Touching variants: works on any variant whose vphoned advertises the `proxy`
  capability.

## Approach: Host Relay (B)

vphone-cli runs a small HTTP CONNECT proxy relay on the host, bound on all
interfaces with a guest-only allowlist. The guest's system-wide HTTP proxy
points at the NAT gateway IP (the host) plus the relay port. The relay chains
each connection to the configured upstream — an HTTP proxy (verbatim forward /
CONNECT) or a SOCKS5 upstream (protocol translation), chosen per target.

This single path covers: corporate network-reachable proxies, localhost-only
proxies (cntlm, mitmproxy), and `ssh -D` SOCKS tunnels. Proxy authentication
stays on the host side.

## Configuration

### CLI

```
vphone-cli boot ... [--proxy env | --proxy <url>]
```

- **Absent** — feature off. No relay, no guest apply, env vars ignored.
  (`--no-proxy` is not a flag; absence is the off state.)
- **`--proxy env`** — upstreams from environment:
  - `https_proxy` / `HTTPS_PROXY` → upstream for CONNECT (HTTPS targets)
  - `http_proxy` / `HTTP_PROXY` → upstream for plain HTTP targets
  - `all_proxy` / `ALL_PROXY` → fallback for either
  - If only one of `http_proxy`/`https_proxy` is set, it serves as fallback
    for the other (mirrors the `all_proxy` fallback rule).
  - `no_proxy` / `NO_PROXY` → exceptions list
  - If no `*_proxy` variable is set: **fatal at startup** with a clear message
    (explicit user intent, fail loud).
- **`--proxy <url>`** — explicit upstream for all traffic. Schemes: `http://`
  (or bare `host:port`) and `socks5://`. Embedded `user:pass@` credentials are
  used for upstream auth (HTTP basic `Proxy-Authorization` / SOCKS5 user-pass).
  `no_proxy` env is still honored for exceptions. Invalid URL → fatal.

### `VPhoneProxyConfig` (new, `sources/VPhoneCore/`)

Pure value type, unit-testable:

```swift
struct VPhoneProxyConfig: Equatable, Sendable {
    enum Upstream: Equatable, Sendable { case http(URL); case socks5(host: String, port: Int) }
    var httpsUpstream: Upstream?   // for CONNECT (port 443 targets)
    var httpUpstream: Upstream?    // for plain HTTP targets
    var exceptions: [String]       // no_proxy entries
}
```

- `VPhoneProxyConfig.resolve(explicit: String?, environment:)` parses the CLI
  value ("env" or URL) plus env vars per the rules above.
- Exceptions matching: exact host, suffix match (`.example.com` / `example.com`
  both match subdomains), and `*` wildcard entries, per common `no_proxy`
  conventions.

## Host Relay

### `VPhoneProxyRelay` (new, `sources/VPhoneCore/`, POSIX sockets)

- Binds `0.0.0.0:0` (ephemeral port), reports assigned port. `start()` / `stop()`.
- Per-connection handling on background queues; blocking reads, blind piping.
- **Allowlist:** accepts client connections only from the guest's IP (from
  `VPhoneControl.guestIP`, updated on every vphoned connect). Not reachable as
  an open proxy from the LAN. Denied connections are closed immediately.
- Client request parsing (read until `\r\n\r\n`):
  - `CONNECT host:port` → resolve upstream: CONNECT targets (any port) →
    `httpsUpstream`; absolute-form plain HTTP → `httpUpstream`. `all_proxy`
    and single-var fallbacks are already folded in at resolve time.
    Establish upstream chain, reply `200 Connection Established`,
    blind-pipe both directions. Upstream failure → `502` to client.
  - Absolute-form plain HTTP (`GET http://host/path ...`) →
    HTTP upstream: forwarded verbatim; SOCKS5 upstream: parse host:port from
    URI, SOCKS-connect, rewrite request line to origin-form, forward head +
    pipe.
  - Origin-form requests (no proxy semantics) → `400`.
- Exception (`no_proxy`) match on target host → dial the target directly,
  bypassing upstreams.
- Upstream dialers:
  - HTTP: TCP connect, send `CONNECT host:port HTTP/1.1` (+ optional
    `Proxy-Authorization: Basic …`), validate `2xx` status line.
  - SOCKS5: TCP connect, methods `\x05\x02\x00` (or `\x05\x01\x00` when no
    credentials), negotiate user/pass auth if requested, CONNECT by domain
    name (`\x03`).

## vsock Protocol Additions

Host → guest requests (standard request/response with `id`):

| Message | Fields | Response |
|---|---|---|
| `proxy_set` | `port: Int`, `exceptions: [String]` | `ok`, `host` (resolved gateway IP) |
| `proxy_clear` | — | `ok` |
| `proxy_get` | — | `enabled`, `host`, `port`, `exceptions` |

vphoned advertises `"proxy"` in hello `caps`. Host treats missing cap as
"guest does not support proxy" (log + disabled menu items). No protocol version
bump needed (additive).

## Guest Handler

### `vphoned_proxy.{m,h}` (new) — Makefile gains `-framework SystemConfiguration`

- Gateway discovery: `SCDynamicStore` pattern
  `State:/Network/Global/IPv4` → `Router` (gateway IP) and `ServiceID`
  (active service). No hardcoded subnet assumptions. Failure → error response.
- `proxy_set`:
  - Router IP becomes the proxy host; guest proxy = `router:port`.
  - Writes `Proxies` dict on `/Setup:/Network/Service/<ServiceID>/Proxies`:
    `HTTPEnable=1`, `HTTPProxy=<router>`, `HTTPPort=<port>`,
    `HTTPSEnable=1`, `HTTPSProxy=<router>`, `HTTPSPort=<port>`,
    `ProxyAutoDiscoveryEnable=0`,
    `ExceptionsList` = host-provided entries merged with iOS defaults
    (`127.0.0.1`, `localhost`, `*.local`, `169.254.0.0/16`, `::1`).
  - `SCPreferencesCommitChanges` + `SCPreferencesApplyChanges`.
  - Proxies apply live to CFNetwork/NSURLSession clients; no reboot needed.
- `proxy_clear`: sets `HTTPEnable=0`, `HTTPSEnable=0`, commit + apply.
- `proxy_get`: reads back current `Proxies` state.

## Host Integration

### `VPhoneCLI.swift` (`VPhoneBootCLI`)

- `@Option var proxy: String?` — help: `"Proxy the guest through: 'env' to use http_proxy/https_proxy/all_proxy, or an upstream URL (http:// | socks5://)"`.
- Validate at parse time: absent or `env` or parseable URL, else `ValidationError`.

### `VPhoneAppDelegate.swift`

- Resolve config at `startVirtualMachine()`: fatal errors for the bad cases
  above; otherwise start relay and keep reference. Log one line:
  `[proxy] relay :8899, upstream socks5://127.0.0.1:1080 (from env)`.
- In `control.onConnect` (GUI **and** headless branches), when relay active:
  update relay allowlist with `guestIP`; if `proxy` cap present, send
  `proxy_set`; log result. Missing cap → single log line.
- On app termination the relay socket closes with the process (guest proxy
  then fails fast; acceptable for a research tool — connections error, nothing
  hangs).

### Connect Menu (`VPhoneMenuConnect.swift`, `VPhoneMenuController.swift`)

- New "Proxy" submenu, enabled when connected + `proxy` cap:
  - Status items (disabled, informational): `Upstream: <desc>`, `Relay: :<port>`,
    `Guest: on/off` (from `proxy_get`).
  - `Apply from Host Config` — re-sends `proxy_set` (same values as boot-time
    auto-apply).
  - `Clear in Guest` — sends `proxy_clear`.
  - Results via the existing `showAlert` pattern.

## Error Handling Summary

| Case | Behavior |
|---|---|
| `--proxy env` with no env vars | fatal at startup |
| `--proxy` invalid URL | `ValidationError` at parse |
| relay bind failure | boot continues, proxy disabled, loud log |
| guest lacks `proxy` cap | log line, menu items disabled |
| gateway/SCPreferences failure in guest | error response → menu alert + log |
| upstream connect/auth failure | per-connection `502`, relay stays up |
| disallowed client (not guest IP) | immediate close |

## Testing

- `VPhoneCoreTests/ProxyConfigTests.swift`: resolution precedence, scheme
  detection, credential extraction, exceptions matching, `env`-mode fatals.
- `VPhoneCoreTests/ProxyRelayTests.swift`: in-process fake upstreams (stub HTTP
  proxy + stub SOCKS5 server on loopback listeners); verify CONNECT tunneling,
  upstream chaining both kinds, `no_proxy` direct dial, allowlist rejection,
  `502` on upstream refusal.
- `make -C scripts/vphoned` build check (cross-compile).
- Manual: `https_proxy=http://127.0.0.1:8888 vphone-cli boot --proxy env` with
  mitmproxy → Safari in guest loads pages; host-side `curl` to the relay port
  is rejected.

## Files Touched

| File | Change |
|---|---|
| `sources/VPhoneCore/VPhoneProxyConfig.swift` | new |
| `sources/VPhoneCore/VPhoneProxyRelay.swift` | new |
| `sources/vphone-cli/VPhoneCLI.swift` | `--proxy` option + validation |
| `sources/vphone-cli/VPhoneAppDelegate.swift` | config resolve, relay lifecycle, auto-apply |
| `sources/vphone-cli/VPhoneControl.swift` | `sendProxySet/Clear/Get` |
| `sources/vphone-cli/VPhoneMenuConnect.swift` | Proxy submenu |
| `sources/vphone-cli/VPhoneMenuController.swift` | menu item references |
| `scripts/vphoned/vphoned_proxy.m`, `vphoned_proxy.h` | new guest handler |
| `scripts/vphoned/vphoned.m` | dispatch + `proxy` cap |
| `scripts/vphoned/Makefile` | SystemConfiguration framework |
| `tests/VPhoneCoreTests/ProxyConfigTests.swift` | new |
| `tests/VPhoneCoreTests/ProxyRelayTests.swift` | new |

## Addendum: vsock transport + guest network bring-up (post-review, validated on a host behind a default-deny corporate pf firewall)

Two issues surfaced during on-hardware validation that the original design
did not cover:

1. **Corporate host firewall (pf, default-deny inbound)**
   silently drops guest→host TCP on the vmnet bridge — the relay was
   unreachable regardless of allowlisting. Fix: the relay now ALSO accepts
   connections over virtio-vsock (port 1338, `VZVirtioSocketListener`).
   vphoned runs a guest-loopback forwarder (127.0.0.1:8899 → vsock:1338) and
   the guest system proxy points at `127.0.0.1:8899`. vsock is VM-private by
   construction, so no IP allowlist applies on that path. `proxy_set` gains a
   `vsock` flag; the host sends it when the vsock listener is attached.

2. **iPhone-based iOS configd does not auto-configure the virtio NIC.**
   No network service exists for `en0`, so no DHCP client runs and no global
   IPv4 entity appears. vphoned now (a) ensures a DHCP service for the first
   `en*` interface in both `/Setup:` and the ACTIVE set (`/Sets/<id>/…`,
   read via `/Set:/CurrentSet`) — /Setup: alone is a template store configd
   does not fully evaluate; (b) falls back to static IPv4
   (`<gateway>.100/24`, router = host-provided NAT gateway from
   `VPhoneProxyRelay.hostBridgeGateway()`, falling back to VZ's fixed
   192.168.64.0/24) when the vmnet DHCP server never answers; (c) reads the
   global entity's `PrimaryService` key (iOS name; macOS uses `ServiceID`).
   Diagnostics: interface summary + raw global dict are included in error
   responses; `proxy_set` responses carry `guest_ip` so the host can refresh
   the relay allowlist after the guest's IP changes.
