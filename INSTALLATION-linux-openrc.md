# Installation on a generic Linux router with OpenRC

cake-autorate was written for OpenWrt, where the [SQM](https://openwrt.org/docs/guide-user/network/traffic-shaping/sqm)
package creates the CAKE qdiscs and cake-autorate only *adjusts* their bandwidth.

This adds first-class support for a **generic Linux router running OpenRC**
(Alpine, Gentoo, Artix, …), which has no SQM package: a small helper,
`sqm-setup.sh`, brings the CAKE qdiscs up, and an OpenRC service wires it all
together. The core (`cake-autorate.sh`) is unchanged.

## Requirements

- `bash`, `iproute2` (`tc`), `fping`
- kernel modules `sch_cake` and `ifb`
- OpenRC (`rc-update`, `rc-service`)

On Alpine: `apk add bash iproute2 fping`.

## Install

```sh
sh -c "$(wget -qO- https://raw.githubusercontent.com/lynxthecat/cake-autorate/master/setup.sh)"
```

`setup.sh` detects OpenRC and installs into `/root/cake-autorate`, generating
(but **not** enabling) an OpenRC service at `/etc/init.d/cake-autorate`.

## Configure

Edit `/root/cake-autorate/config.primary.sh`:

| variable | meaning | example |
| --- | --- | --- |
| `ul_if` | WAN interface (upload egress) | `eth0` |
| `dl_if` | IFB device for ingress shaping (created by `sqm-setup.sh`) | `ifb-eth0` |
| `min_/base_/max_dl_shaper_rate_kbps` | download rate bounds | — |
| `min_/base_/max_ul_shaper_rate_kbps` | upload rate bounds | — |

Optional, to pass extra CAKE keywords per direction. The defaults give full
per-host fairness on a NAT router (like OpenWrt SQM) — `nat` resolves the inside
hosts and `dual-srchost`/`dual-dsthost` share bandwidth per LAN host, so no
single host can starve the others:

| variable | default |
| --- | --- |
| `sqm_ul_cake_opts` | `nat dual-srchost` |
| `sqm_dl_cake_opts` | `nat dual-dsthost ingress` |

## Run

```sh
rc-update add cake-autorate default
rc-service cake-autorate start
```

The service runs `sqm-setup.sh start` (creates the qdiscs), then the launcher
runs the cake-autorate instance(s). `rc-service cake-autorate stop` tears the
qdiscs back down.

## How it works

`sqm-setup.sh` reproduces, on a generic Linux host, what SQM does on OpenWrt:

- CAKE on `ul_if` egress (upload shaping);
- an IFB (`dl_if`) fed by a `tc` ingress redirect from `ul_if`, with CAKE on the
  IFB (download shaping).

It reads `ul_if`/`dl_if` and the base rates from the **same** instance config
that `cake-autorate.sh` uses, so there is a single source of truth. cake-autorate
then adjusts the CAKE bandwidth in real time — ideal for highly variable links
(Starlink, LTE/5G).
