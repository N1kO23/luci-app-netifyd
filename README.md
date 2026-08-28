# luci-app-netifyd

A LuCI dashboard for [netifyd](https://gitlab.com/netify.ai/public/netify-agent),
the nDPI-based deep-packet-inspection agent. It shows live flow
classification (protocol, application, category), top talkers and agent
status, sourced directly from netifyd's own local JSON socket — no
port-number guessing, no `/proc/net/nf_conntrack` scraping.

## How it works

```text
netifyd  ──(UNIX socket, streaming JSON)──>  netifyd-luci collector (procd service)
                                                      │
                                              snapshot.json (tmpfs)
                                                      │
                                     /usr/libexec/rpcd/luci.netifyd (ubus)
                                                      │
                                  LuCI JS views: Overview / Flows / Settings
```

netifyd streams a continuous, newline-delimited JSON event feed rather than
answering simple status requests, so a small background collector
(`/usr/libexec/netifyd-luci/collector.sh`, run by the `netifyd-luci` init
script) stays connected to it, keeps one file per active flow in
`/var/run/netifyd-luci/flows/`, and periodically aggregates them into
`/var/run/netifyd-luci/snapshot.json`. The `luci.netifyd` rpcd backend just
reads that snapshot and UCI — cheap, stateless, well suited to being called
on every LuCI page poll.

## Requirements

- `netifyd` itself, already installed and configured to capture your
  interfaces.
- `rpcd`, `socat`, `jq` (pulled in automatically as package dependencies).

### Enabling netifyd's local socket

This app does **not** modify netifyd's own configuration — that's a
separate package's concern. You need to add a `[socket]` section to
`/etc/netifyd.conf` once, enabling the socket and the established/unknown
flow dump on connect:

```ini
[socket]
dump_established_flows = yes
dump_unknown_flows = yes
listen_path[0] = /var/run/netifyd/netifyd.sock
```

Restart netifyd (`/etc/init.d/netifyd restart`) after editing, then restart
`netifyd-luci` (either `/etc/init.d/netifyd-luci restart` or the "Restart
service" button on the Settings page). If the socket path doesn't match
what's configured under **Status → Netifyd → Settings**, update it there.

## UCI configuration (`/etc/config/netifyd-luci`)

| Option | Default | Description |
| --- | --- | --- |
| `enabled` | `1` | Enable the collector service |
| `socket_path` | `/var/run/netifyd/netifyd.sock` | Path to netifyd's local JSON socket |
| `poll_interval` | `5` | Seconds between snapshot rebuilds |
| `idle_ttl` | `300` | Seconds of inactivity before a flow is dropped |
| `max_flows` | `500` | Max flows returned to the UI per request |

## Building

This is a standard third-party LuCI application package. To build it against
the OpenWrt SDK, add it as a feed alongside the official `luci` feed and
build normally:

```sh
echo "src-link luci_app_netifyd $(pwd)" >> feeds.conf.default
./scripts/feeds update luci_app_netifyd luci
./scripts/feeds install -a -p luci_app_netifyd
make package/luci-app-netifyd/compile V=s
```

CI (`.github/workflows/build.yml`) does this automatically on every push/PR
using the official OpenWrt SDK container (currently targeting the 25.12
branch, which builds `.apk` packages — OpenWrt replaced opkg/`.ipk` with the
`apk` package manager as of 25.12), and attaches the built package to GitHub
Releases on tagged commits.

## License

Apache-2.0
