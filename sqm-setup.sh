#!/usr/bin/env bash

# sqm-setup.sh — minimal CAKE bring-up for GENERIC LINUX hosts.
#
# On OpenWrt the CAKE qdiscs are created by the SQM package and cake-autorate
# only *adjusts* their bandwidth. A generic Linux router has no SQM, so this
# helper creates exactly the qdiscs that cake-autorate then adjusts:
#
#   - egress CAKE on the WAN interface          (ul_if)
#   - ingress CAKE on an IFB device             (dl_if)
#     fed by a tc ingress redirect from the WAN
#
# Interfaces and the initial (base) shaper rates are read from the SAME instance
# config that cake-autorate.sh uses, so there is a single source of truth. After
# this runs, start cake-autorate normally and it takes over the bandwidth.
#
# Usage:
#   sqm-setup.sh start [CONFIG]   set up the qdiscs   (CONFIG default: ./config.primary.sh)
#   sqm-setup.sh stop  [CONFIG]   tear the qdiscs down
#
# Extra CAKE options (diffserv mode, overhead, rtt, …) may be supplied per
# direction via the optional config variables sqm_dl_cake_opts / sqm_ul_cake_opts.

set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

action=start
case "${1:-}" in
	start | stop)
		action=$1
		shift
		;;
	*) ;; # leave action=start; treat $1 as the config path
esac
config=${1:-${script_dir}/config.primary.sh}

if [[ ! -f ${config} ]]; then
	printf >&2 'sqm-setup.sh: config not found: %s\n' "${config}"
	exit 1
fi

# Pull dl_if / ul_if and the base rates from defaults + instance config.
# shellcheck source=/dev/null
. "${script_dir}/defaults.sh"
# shellcheck source=/dev/null
. "${config}"

: "${dl_if:?sqm-setup.sh: dl_if is not set in the config}"
: "${ul_if:?sqm-setup.sh: ul_if is not set in the config}"
: "${base_dl_shaper_rate_kbps:?sqm-setup.sh: base_dl_shaper_rate_kbps is not set}"
: "${base_ul_shaper_rate_kbps:?sqm-setup.sh: base_ul_shaper_rate_kbps is not set}"

# Optional per-direction extra CAKE keywords. The defaults give full per-host
# fairness on a NAT router, like OpenWrt SQM: "nat" resolves the inside hosts,
# and dual-srchost (egress) / dual-dsthost (ingress) share bandwidth per LAN
# host, so no single host can starve the others. Override in the config if needed.
sqm_dl_cake_opts=${sqm_dl_cake_opts:-nat dual-dsthost ingress}
sqm_ul_cake_opts=${sqm_ul_cake_opts:-nat dual-srchost}

teardown() {
	tc qdisc del root dev "${ul_if}" 2>/dev/null || true
	tc qdisc del dev "${ul_if}" ingress 2>/dev/null || true
	ip link del "${dl_if}" 2>/dev/null || true
}

case ${action} in
	stop)
		teardown
		;;
	start)
		if ! ip link show "${ul_if}" >/dev/null 2>&1; then
			printf >&2 'sqm-setup.sh: WAN interface "%s" (ul_if) not found\n' "${ul_if}"
			exit 1
		fi
		# numifbs=0 so the module doesn't auto-create stray ifb0/ifb1 (which would
		# otherwise pick up IPv4LL 169.254 addresses); we add a named IFB below.
		# (Only takes effect on the module's first load, i.e. a clean boot.)
		modprobe ifb numifbs=0 2>/dev/null || true
		modprobe sch_cake 2>/dev/null || true
		teardown
		trap teardown ERR # roll back a partial setup if any command below fails

		# Upload: shape egress on the WAN interface.
		# shellcheck disable=SC2086
		tc qdisc add root dev "${ul_if}" cake \
			bandwidth "${base_ul_shaper_rate_kbps}kbit" ${sqm_ul_cake_opts}

		# Download: redirect WAN ingress into an IFB and shape that.
		ip link add "${dl_if}" type ifb
		ip link set "${dl_if}" up
		tc qdisc add dev "${ul_if}" handle ffff: ingress
		tc filter add dev "${ul_if}" parent ffff: protocol all \
			u32 match u32 0 0 action mirred egress redirect dev "${dl_if}"
		# shellcheck disable=SC2086
		tc qdisc add root dev "${dl_if}" cake \
			bandwidth "${base_dl_shaper_rate_kbps}kbit" ${sqm_dl_cake_opts}
		trap - ERR
		;;
	*)
		printf >&2 'sqm-setup.sh: unknown action: %s\n' "${action}"
		exit 1
		;;
esac
