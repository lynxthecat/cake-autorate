#!/bin/sh

# Set up the IFB interface and TC

set -eu

wan="${1:-}"

if [ -z "${wan}" ]
then
	echo "No interface name provided"
	exit 1
fi

if ip link show ${wan}
then
	# Upload
	sudo tc qdisc replace dev ${wan} root cake bandwidth 40mbit

	# Download
	if ! ip link show ifb4${wan}
	then
		sudo ip link add name ifb4${wan} type ifb
	fi
	sudo tc qdisc del dev ${wan} ingress 2> /dev/null || :
	sudo tc qdisc add dev ${wan} handle ffff: ingress
	sudo tc qdisc del dev ifb4${wan} root 2> /dev/null || :
	sudo tc qdisc add dev ifb4${wan} root cake bandwidth 40mbit besteffort
	sudo ip link set ifb4${wan} up
	sudo tc filter add dev ${wan} parent ffff: matchall action mirred egress redirect dev ifb4${wan}

else
	exit 1
fi

# vim: noet ts=4
