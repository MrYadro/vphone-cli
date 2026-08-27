# Proxy Support — Implementation Notes & Debugging Journal

> Goal: guest internet through host HTTP/SOCKS5 proxies, opt-in via
> `--proxy env` / `--proxy <url>`. Written as a porting guide: if this branch
> is not merged upstream, use this file to re-apply the work to a new base.

## Final architecture (what actually works)

```
iOS app (Safari, NSURLSession clients)
  └─ system HTTP proxy → 127.0.0.1:8899            (guest loopback)
       └─ vphoned_fwd: TCP 8899 → vsock port 1338   (guest→host virtio-vsock)
            └─ VPhoneProxyVsockListener → VPhoneProxyRelay (host)
                 └─ upstream: http_proxy / https_proxy / all_proxy
                     (HTTP CONNECT chaining, basic auth, or SOCKS5 RFC1928/1929)
```

- The IP path (guest → gateway:relayPort over the vmnet bridge) is also
  implemented, but many managed hosts run a default-deny inbound pf ruleset
  that silently drops it. The vsock path bypasses host firewalls entirely and
  is the default whenever the vsock listener is attached.
- vsock connections are VM-private by construction — the relay's IP allowlist
  only applies to the TCP listener path.

## Files (all additive except the noted integration points)

| File | Role |
|---|---|
| `sources/VPhoneCore/VPhoneProxyConfig.swift` | env/URL resolution, Upstream parsing (http/socks5 + creds), no_proxy matching, `summary` |
| `sources/VPhoneCore/VPhoneProxyRelay.swift` | CONNECT relay: guest-allowlisted TCP listener + `handleExternalConnection(fd:)` for vsock fds; HTTP/SOCKS5 upstream dialers; early-data forwarding both directions; `hostBridgeGateway()` |
| `sources/vphone-cli/VPhoneProxyVsockListener.swift` | `VZVirtioSocketListener` on port 1338; retains `VZVirtioSocketConnection` objects (they own their fds) |
| `scripts/vphoned/vphoned_proxy.{h,m}` | `proxy_set` / `proxy_clear` / `proxy_get`; SCPreferences writes (see bring-up below); `"proxy"` capability |
| `scripts/vphoned/vphoned_fwd.{h,m}` | guest loopback forwarder 127.0.0.1:8899 → vsock 1338 (VMADDR_CID_HOST=2) |
| `tests/VPhoneCoreTests/ProxyConfigTests.swift`, `ProxyRelayTests.swift` | 27 tests incl. in-process fake HTTP/SOCKS5 upstreams |

Integration points in existing files (re-apply on a new base):

- `VPhoneCLI.swift` (`VPhoneBootCLI`): `--proxy` option + `validate()` (must
  run BEFORE the `--install-ipa` early `return` in `validate()`).
- `VPhoneVMLaunchCLI.swift`: same option, forwarded in the child `args`.
- `VPhoneAppDelegate.swift`: `startProxyIfNeeded()` before VM creation;
  `applyProxyToGuest(caps:)` in BOTH `onConnect` branches; vsock listener
  attach where `control.connect(device:)` happens; `proxyRelay?.stop()` in
  `applicationWillTerminate`; menu gets relay/config + `refreshProxyInfo()`.
- `VPhoneControl.swift`: `sendProxySet(port:exceptions:gateway:vsock:)`
  (returns `(host, guestIP)`), `sendProxyClear`, `sendProxyGet`; all three in
  the 30s slow-timeout class.
- `VPhoneMenuConnect.swift` / `VPhoneMenuController.swift`: Proxy submenu
  (parent `NSMenuItem` MUST have a title — untitled parents trigger an
  AppKit warning on macOS 26), `refreshProxyInfo()`,
  `updateProxyAvailability(available:)`.
- `scripts/vphoned/Makefile` **and the inline clang invocations in
  `scripts/cfw_install.sh` + `scripts/cfw_install_dev.sh`**: add
  `-framework SystemConfiguration` — the CFW installer rebuilds vphoned
  itself when the staged binary is missing/stale, and its own link line
  must carry the framework too.
- vphoned protocol stays version 1 — purely additive message types.

## Root causes found while validating (each was a real bug to fix)

Ordered roughly by discovery; each entry is what to check if a port to a new
base misbehaves the same way.

1. **Stale vphoned in the guest.** Auto-update only pushes on hash mismatch;
   deploying a new `.vphoned.signed` into an app that the VM host doesn't
   actually run (there were two app copies: `/Applications` and repo
   `.build/`) means the guest keeps the old daemon and the host sees no
   `proxy` capability. `vm launch` stages vphoned from the RUNNING app's
   `Contents/Resources` — deploy the whole `.app`, both copies, and verify
   `shasum` remotely. Also: `scp -r` into an existing remote dir nests the
   source dir one level deeper; always `rm -rf` the remote staging path first.

2. **CF over-release crash.** `SCPreferencesPathGetValue` is a *borrowed*
   reference (Get, not Copy). Wrapping it in `CFBridgingRelease` hands it to
   ARC and the daemon SIGSEGVs later; the host's auto-retry then crash-loops
   vphoned ("Connection reset by peer" forever). Correct pattern:
   `[NSDictionary dictionaryWithDictionary:(__bridge id)v]`. Same rule for
   everything except `SCDynamicStoreCopyValue` (that one IS a Copy).

3. **`/Setup:` is a template store.** configd does not fully evaluate service
   changes written only under `/Setup:/Network/Service/...`. The ACTIVE
   configuration is the current set: read `/Set:/CurrentSet`
   (fallback: first `/Sets/*` entry with a `Network` dict), write the service
   dict (and its `Network/Global/IPv4.ServiceOrder`) there, mirror to
   `/Setup:`. Symptom without this: service created, DHCP client even runs,
   but later changes (e.g. Manual IPv4) never apply to the interface.

4. **iPhone-iOS configd never auto-configures the virtio NIC.** No network
   service exists for `en0`, so no DHCP client runs and no global IPv4
   entity appears ("no global IPv4 route"). Fix: `ensure_dhcp_service()`
   creates a DHCP service bound to the first up `en*` interface in both
   trees (Interface: DeviceName/Hardware/Type = Ethernet), then commit +
   apply.

5. **vmnet's NAT DHCP server can be dead on SIP/amfidont hosts.** Guest
   DISCOVERs hit bridge100 and nothing answers; interfaces fall back to
   169.254.x (IPv4LL — which is also how you know the DHCP client did run).
   Fix: static fallback. Host sends its NAT gateway
   (`VPhoneProxyRelay.hostBridgeGateway()`: first bridge*/vmenet* IPv4, else
   VZ's fixed `192.168.64.1`); guest writes `ConfigMethod: Manual`,
   `<gateway-base>.100/24`, `Router: gateway` on the service. Proxied traffic
   carries hostnames, so the guest needs no DNS.

6. **iOS key naming.** The dynamic-store global IPv4 entity
   (`State:/Network/Global/IPv4`) contains `PrimaryService` / `Router` /
   `PrimaryInterface` on iOS — NOT `ServiceID`. Read
   `ServiceID ?: PrimaryService`.

7. **Host firewall drops guest→host bridge TCP.** Symptom: guest SYNs to the
   relay reach the host (tcpdump on bridge100) and nothing answers; relay
   listens fine on loopback; app firewall off; `pfctl -sr` shows a
   third-party default-deny anchor. Fix (chosen over touching the firewall):
   the vsock transport — host `VZVirtioSocketDevice.setSocketListener(_:,
   forPort: 1338)`, guest `AF_VSOCK` connect to `VMADDR_CID_HOST` (2).
   `VZVirtioSocketConnection` owns its fd: retain the objects forever and
   pass `ownsClientFD: false` into the relay (shutdown, never close).

8. **Stale relay allowlist.** The allowlist snapshot is taken at vphoned
   connect time; if the guest's IP changes right after (static config), the
   relay rejects everything. `proxy_set` responses carry `guest_ip`
   (current primary en* IPv4); the host refreshes the allowlist from it.

9. **Proxies only propagate from an ACTIVE primary service.** Writing
   `Proxies` to a service that exists but has no IPv4 (never became primary)
   does nothing — apps never see the proxy (symptom: zero traffic anywhere,
   `proxy_set` succeeds). The vsock path initially skipped network bring-up
   entirely; it must run the SAME bring-up (DHCP service + static fallback)
   as the TCP path, and the host must always send `gateway` — the forwarder
   removes the need for guest→host IP reachability, not for an active
   service.

## Deploy & verify recipe

1. `make -C scripts/vphoned` + ldid sign (or `./scripts/build.sh` for the
   whole app; it embeds a fresh `.vphoned.signed`).
2. Copy the whole `.app` to the target host (all locations it is run from).
   Verify `shasum -a 256` of the binary AND `Resources/vphoned.signed`.
3. Boot: `vphone-cli vm launch <vm> --proxy env 2>&1 | grep -E "\[proxy\]"`.
   Note: piping the app's stdout makes it block-buffered — late log lines can
   sit unflushed until exit; capture to a file with `> log 2>&1` and grep
   afterwards, or lose the tail on Ctrl+C.
4. Expect `[proxy] relay :PORT, upstream ...` then
   `[proxy] guest proxy -> 127.0.0.1:8899 ...` (vsock mode).
5. In-guest failures are reported through the same log via vsock error
   messages (interface summary, raw global dict) — keep that instrumentation
   when porting; it found 6 of the 8 bugs above.

## Tests

`swift test --filter VPhoneCoreTests` — 158 tests / 18 suites, including 9
relay end-to-end tests (fake HTTP/SOCKS5 upstreams on loopback listeners:
tunneling, chaining, no_proxy direct dial, allowlist rejection, 502s,
early-data both directions).
