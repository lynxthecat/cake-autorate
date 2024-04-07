#!/usr/bin/env bash

# Simple CPU benchmark for cake-autorate on OpenWrt

test_period_s=${1:-60} # Number of seconds to run CPU usage test

printf "Running CPU benchmark for test period of: %ds.\n...\n" "${test_period_s}"

service cake-autorate stop 2> /dev/null
service cake-autorate start

sleep 10 # Give 10 seconds for CPU usage to settle

tstart=${EPOCHREALTIME/.}
cstart=$(awk 'NR==2,NR==3{sum+=$2};END{print sum;}' /sys/fs/cgroup/services/cake-autorate/cpu.stat)

sleep "${test_period_s}"

tstop=${EPOCHREALTIME/.}
cstop=$(awk 'NR==2,NR==3{sum+=$2};END{print sum;}' /sys/fs/cgroup/services/cake-autorate/cpu.stat)

(( cpu_usage=(100000*(cstop - cstart)) / (tstop - tstart) ))

cpu_usage=000${cpu_usage}

printf "Average CPU usage over test period of %ds was: %.3f%%\n" "${test_period_s}" "${cpu_usage::-3}.${cpu_usage: -3}"

service cake-autorate stop
