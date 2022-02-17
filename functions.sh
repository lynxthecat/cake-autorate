#!/bin/bash

# helper functions for CAKE-autorate

# functions.sh is part of CAKE-autorate
# CAKE-autorate automatically adjusts bandwidth for CAKE in dependence on detected load and RTT

# inspired by @moeller0 (OpenWrt forum)
# initial sh implementation by @Lynx (OpenWrt forum)
# requires packages: iputils-ping, coreutils-date and coreutils-sleep

x1000()
{
        local value=$1
        echo $(printf %.0f\\n "${value}e3")
}

sleep_remaining_tick_time()
{
	local t_start=$1
	local t_end=$2
	local tick_duration=$3

	sleep_duration=$(( $(x1000 $tick_duration)*(10**6) - $t_end + $t_start))
        if (($sleep_duration > 0 )); then
                sleep $sleep_duration"e-9"
        fi
}
