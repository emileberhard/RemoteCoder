# Relay route

The relay is a second route from the app to each gateway that does not depend
on Tailscale on the phone, the host or the control plane. The app uses it only
when the configured (tailnet) address fails; `docs/system-architecture.md`
(*Relay route*) owns that choice. This file owns the server, the host tunnels
and their security boundary.

```
app ──TLS, pinned relay SPKI──▶ VPS :443 HAProxy ──▶ tinyproxy 127.0.0.1:8888 ──▶ 127.0.0.1:2000x
                                                                                    ║ ssh -R from the host
                                                                    host 127.0.0.1:<lan port> gateway LAN TLS listener
app ═══════════ inner TLS, pinned gateway LAN SPKI, end to end; the VPS sees only ciphertext ═══════════
```

## Pieces

- **VPS.** An operator-provisioned VPS whose reviewed address and port mapping
  live in private topology configuration (see the tracked synthetic example). nftables admits only SSH and
  443, and SSH takes keys only. Unattended upgrades install updates, but automatic
  reboot is disabled. Activating a new kernel requires a separately coordinated
  reboot that preserves active work.
- **Package activation.** Provisioning installs the relay-owned `policy-rc.d`
  before APT runs. Debian's `invoke-rc.d` and `deb-systemd-invoke` then deny
  stop, restart and reload actions for HAProxy, tinyproxy and SSH while still
  permitting package installation and service starts. An existing policy owned
  by something else blocks provisioning instead of being overwritten. Direct
  `systemctl` calls and other helpers bypass this policy. Provisioning records
  changed service configuration until its activation succeeds, so retrying an
  interrupted apply does not silently leave a change unapplied. It still
  directly activates changed configuration; this is not a maintenance fence.
  The operator must verify no client work is interrupted before provisioning
  changed configuration or activating installed packages.
  Package installation alone does not activate new binaries or libraries; the
  future maintenance owner or an explicit supervised operation must activate them.
  A dpkg pre-invoke guard refuses package changes while a maintenance marker
  exists, including after its owner exits. The maintenance owner must hold the
  package-manager locks while creating that marker; the guard alone cannot
  exclude a transaction that has already started.
- **Maintenance ingress.** The checked-in firewall fragment rejects TCP packets
  to port 443 classified as new while keeping tracked existing connections;
  handshakes already in progress can still complete. Provisioning stages the
  fragment and an HAProxy startup guard that applies it whenever the maintenance
  marker exists. These are not a complete maintenance workflow. The future owner
  must establish tracking before admission, persist and recover its fence, account
  for queued and in-flight work, and verify boot before using it. Reloading the
  relay's base firewall replaces only its own table and preserves the fence.
  The staged recovery command reopens only an abandoned `preparing` marker from
  the current boot after taking the provisioning lock; it leaves committed,
  malformed and new-boot markers fenced for verification. A maintenance owner
  that writes the marker and verifies the new boot is still required.
- **HAProxy** terminates TLS 1.3 on 443 with a self-signed P-256 certificate
  whose SPKI the app pins, and passes only streams that begin with `CONNECT `.
- **tinyproxy** requires Basic auth (it answers 407 and closes; URLSession
  retries with the credential), allows `CONNECT` only to the ports in the
  topology, and denies every host name except the relay names, which
  `/etc/hosts` on the VPS maps to loopback. HostUp's cloud-init rewrites
  `/etc/hosts` at boot, so the `remote-coder-relay-hosts` unit adds the names
  back after it.
- **Host tunnels.** Each host runs `/usr/bin/ssh -N` under its supervisor, the
  KeepAlive LaunchAgent `com.remote-coder.relay-tunnel` on macOS and the
  lingering user unit `remote-coder-relay-tunnel.service` on Linux, with its
  own key, config and pinned host key under `~/.remote-coder/relay/`. It forwards its relay port on
  the VPS loopback to its gateway's LAN listener. sshd lets the `relay-tunnel`
  user open only those remote listeners: no shell, no TTY, no local forwarding,
  each key limited to its own port. Client alive probes clear a dead tunnel's
  listener within 30 s so the reconnect can bind it again.
- **Gateway.** `~/.remote-coder/relay/relay.json` is read at startup and served
  on the authorized, uncached `GET /relay`.

No DNS or public CA is on the fallback path: the app and the tunnels dial the
IP literal and pin keys, and the relay names resolve only on the VPS.

## Security boundary

The VPS never holds a gateway credential or sees plaintext: the app's inner
handshake pins the gateway's LAN key before it sends the bearer, exactly as on
the home network. An unauthenticated client gets no byte through tinyproxy, an
authenticated one reaches only the hosts' LAN listeners, and those still require a
bearer or installation credential.

The relay credential, or a compromised VPS, therefore extends what the home
network already allows to the internet: reaching the LAN listeners' TLS
handshake. Such a client can also hold the listener's shared connection slots
and tinyproxy's 64 clients, which degrades the relay and the home LAN route
until the credential changes. Every relay client appears as `127.0.0.1` in the
gateway journal.

Secrets live in one place each. `just relay-provision` on the configured provisioner creates
the relay's TLS key and admission credential once in
`~/.remote-coder/relay/server/` (mode 0600) and installs them on the VPS, so a
rebuilt VPS keeps the pin the apps have. Each host's installer reads the client
copy from the VPS over admin SSH; a host without the admin key, such as Linux,
receives it on stdin from the provisioner (`--record-from-stdin`). Tunnel keys
never leave their host; their public halves are installed from private operator
configuration.

## Operate

Maintainer topology, tunnel keys, provisioning, rotation and probes live in the
private [RemoteCoder-deploy operations entrypoint](https://github.com/emileberhard/RemoteCoder-deploy/blob/main/AGENTS.md).
The public tree contains synthetic examples only; never use an example address
or credential as live configuration.

The provisioner owns the server key and credential. Installing another client
must not silently replace them. A pin rotation needs an already authorized
route for clients to learn the replacement; a client that can reach only the
old relay cannot learn the new pin there. Live probes must separately prove a
valid route, refusal of a wrong relay credential, refusal of an unlisted target,
refusal of a wrong gateway pin and authorized route publication.

## Logs

- Tunnel: on macOS `~/Library/Logs/remote-coder/relay-tunnel.log` (errors
  only) and `launchctl print gui/$(id -u)/com.remote-coder.relay-tunnel`; on
  Linux `journalctl --user -u remote-coder-relay-tunnel`.
- VPS: `journalctl -u haproxy -u tinyproxy -u ssh` over admin SSH.
- App: the `GatewayRoutes` category logs learned routes and every route
  failure that changes the order.
