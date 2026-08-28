# luci-app-netifyd

A LuCI dashboard for [netifyd](https://gitlab.com/netify.ai/public/netify-agent),
the nDPI-based deep-packet-inspection agent. It shows live flow
classification (protocol, application, category), top talkers and agent
status, sourced directly from netifyd's own local JSON socket — no
port-number guessing, no `/proc/net/nf_conntrack` scraping.

This repo contains two packages: `luci-app-netifyd` (the live dashboard,
described below) and the optional `luci-app-netifyd-history`
([its own section](#optional-persistent-history-luci-app-netifyd-history))
for persisting traffic history to SQLite.

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

## Optional: persistent history (`luci-app-netifyd-history`)

`luci-app-netifyd`'s live dashboard deliberately keeps no persistent state —
active flows live in tmpfs and are capped at `max_flows`, so nothing
survives a reboot and there's no way to look back at traffic trends.
`luci-app-netifyd-history` is a separate, optional package that adds that:
a second, independent connection to netifyd's socket logs completed flows
and periodic per-protocol/application/category traffic rollups into a
SQLite database, with a new History page to browse them.

It's fully decoupled from the base package — installing it doesn't change
anything about the live dashboard, and it can be removed at any time without
affecting it.

```text
netifyd  ──(2nd independent socket connection)──>  history-collector.sh (procd service)
                                                              │
                                          batched write, every rollup_interval
                                                              │
                                                SQLite db at UCI-configured db_path
                                                              │
                                 /usr/libexec/rpcd/luci.netifyd-history (ubus)
                                                              │
                                              LuCI JS view: History
```

### Setup

There's no settings page for this package yet, so configure it via UCI
directly. `db_path` has **no default** — the service stays idle until you
set one, so writes never land on the router's flash without an explicit
choice. Point it at durable external storage (a mounted USB/SD card) if you
have one; if not, be aware every write goes to the router's own flash:

```sh
uci set netifyd-luci-history.main.db_path=/mnt/usb/netifyd-history.db
uci set netifyd-luci-history.main.enabled=1
uci commit netifyd-luci-history
/etc/init.d/netifyd-history restart
```

The History page appears under **Status → Netifyd** once this package (and
therefore `sqlite3-cli`) is installed.

| Option | Default | Description |
| --- | --- | --- |
| `enabled` | `0` | Enable the history collector service |
| `db_path` | *(empty)* | Path to the SQLite database file; service stays idle until set |
| `retention_days` | `7` | How long completed flows and rollups are kept before being pruned |
| `rollup_interval` | `60` | Seconds between batched database writes, and the bucket size for traffic rollups |

Writes are always batched (once per `rollup_interval`, in a single
transaction), never per-flow-event, to keep this reasonable on flash
storage. Pruning of data older than `retention_days` runs hourly.

## Installing a CI-built package

The GitHub Actions build isn't signed with a key your router trusts, so
`apk` will refuse it by default:

```text
ERROR: ./luci-app-netifyd_1.0.0-1_all.apk: UNTRUSTED signature
```

Install it explicitly as untrusted (fine for a package you built/reviewed
yourself); same for `luci-app-netifyd-history` if you want it too:

```sh
apk add --allow-untrusted ./luci-app-netifyd_1.0.0-1_all.apk
apk add --allow-untrusted ./luci-app-netifyd-history_1.0.0-1_all.apk
```

(On an `opkg`-based release, i.e. 24.10 and earlier, the equivalent is
`opkg install ./luci-app-netifyd_*.ipk`, which doesn't verify signatures for
locally-supplied packages at all.)

## Building

These are standard third-party LuCI application packages, each in its own
top-level directory (`luci-app-netifyd/`, `luci-app-netifyd-history/`). To
build them against the OpenWrt SDK, add this repo as a feed alongside the
official `luci` feed and build normally — the feed scan picks up both
packages automatically:

```sh
echo "src-link luci_app_netifyd $(pwd)" >> feeds.conf.default
./scripts/feeds update luci_app_netifyd luci
./scripts/feeds install -a -p luci_app_netifyd
make package/luci-app-netifyd/compile V=s
make package/luci-app-netifyd-history/compile V=s
```

CI (`.github/workflows/build.yml`) does this automatically on every push/PR
using the official OpenWrt SDK container (currently targeting the 25.12
branch, which builds `.apk` packages — OpenWrt replaced opkg/`.ipk` with the
`apk` package manager as of 25.12), and attaches the built package to GitHub
Releases on tagged commits.

## License

Apache-2.0
