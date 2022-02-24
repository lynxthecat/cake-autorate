#!/bin/bash

# defaults.sh sets up defaults for CAKE-autorate

# defaults.sh is a part of CAKE-autorate
# CAKE-autorate automatically adjusts bandwidth for CAKE in dependence on detected load and RTT

# inspired by @moeller0 (OpenWrt forum)
# initial sh implementation by @Lynx (OpenWrt forum)
# requires packages: iputils-ping, coreutils-date and coreutils-sleep

alpha_OWD_increase=0.001 # how rapidly baseline OWD is allowed to increase
alpha_OWD_decrease=0.9 # how rapidly baseline OWD is allowed to decrease

debug=0

enable_verbose_output=0 # enable (1) or disable (0) output monitoring lines showing bandwidth changes

ul_if=wan # upload interface
dl_if=veth-lan # download interface

min_dl_rate=25000 # minimum bandwidth for download
base_dl_rate=30000 # steady state bandwidth for download
max_dl_rate=80000 # maximum bandwidth for download

min_ul_rate=25000 # minimum bandwidth for upload
base_ul_rate=30000 # steady state bandwidth for upload
max_ul_rate=35000 # maximum bandwidth for upload

alpha_RTT_increase=0.001 # how rapidly baseline RTT is allowed to increase
alpha_RTT_decrease=0.9 # how rapidly baseline RTT is allowed to decrease

rate_adjust_OWD_spike=0.05 # how rapidly to reduce bandwidth upon detection of bufferbloat
rate_adjust_load_high=0.01 # how rapidly to increase bandwidth upon high load detected
rate_adjust_load_low=0.0025 # how rapidly to return to base rate upon low load detected

high_load_thr=75 # % of currently set bandwidth for detecting high load

delay_buffer_len=4 # Size of delay detection window
delay_thr=10 # Extent of delay to classify as an offence
detection_thr=2 # Number of offences within window to classify reflector path delayed
reflector_thr=2 # Number of reflectors that need to be delayed to classify bufferbloat

monitor_reflector_path_tick_duration=0.1
main_loop_tick_duration=0.5

rate_down_bufferbloat_refractory_period=0.5
rate_down_decay_refractory_period=0.5

# verify these are correct using 'cat /sys/class/...'
case "${dl_if}" in
    \veth*)
        rx_bytes_path="/sys/class/net/${dl_if}/statistics/tx_bytes"
        ;;
    \ifb*)
        rx_bytes_path="/sys/class/net/${dl_if}/statistics/tx_bytes"
        ;;
    *)
        rx_bytes_path="/sys/class/net/${dl_if}/statistics/rx_bytes"
        ;;
esac

case "${ul_if}" in
    \veth*)
        tx_bytes_path="/sys/class/net/${ul_if}/statistics/rx_bytes"
        ;;
    \ifb*)
        tx_bytes_path="/sys/class/net/${ul_if}/statistics/rx_bytes"
        ;;
    *)
        tx_bytes_path="/sys/class/net/${ul_if}/statistics/tx_bytes"
        ;;
esac

if [ "$debug" ] ; then
    echo "rx_bytes_path: $rx_bytes_path"
    echo "tx_bytes_path: $tx_bytes_path"
fi

# list of reflectors to use
reflectors=("1.1.1.1" "1.0.0.1" "8.8.8.8" "8.8.8.4")

