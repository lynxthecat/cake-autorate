#!/bin/bash

# defaults.sh sets up defaults for CAKE-autorate

# config.sh is a part of CAKE-autorate
# CAKE-autorate automatically adjusts bandwidth for CAKE in dependence on detected load and RTT

# inspired by @moeller0 (OpenWrt forum)
# initial sh implementation by @Lynx (OpenWrt forum)
# requires packages: iputils-ping, coreutils-date and coreutils-sleep

output_processing_stats=0 # enable (1) or disable (0) output monitoring lines showing processing stats
output_cake_changes=0     # enable (1) or disable (0) output monitoring lines showing cake bandwidth changes

ul_if=wan # upload interface
dl_if=veth-lan # download interface

# *** STANDARD CONFIGURATION OPTIONS ***

reflector_ping_interval=0.1 # (seconds)

# list of reflectors to use
reflectors=("1.1.1.1" "1.0.0.1" "8.8.8.8" "8.8.4.4")
no_reflectors=${#reflectors[@]}

delay_thr=15 # extent of RTT increase to classify as a delay

min_dl_rate=20000 # minimum bandwidth for download
base_dl_rate=25000 # steady state bandwidth for download
max_dl_rate=80000 # maximum bandwidth for download

min_ul_rate=25000 # minimum bandwidth for upload
base_ul_rate=30000 # steady state bandwidth for upload
max_ul_rate=35000 # maximum bandwidth for upload

# *** ADVANCED CONFIGURATION OPTIONS ***

bufferbloat_detection_window=4 # number of delay samples to retain in detection window
bufferbloat_detection_thr=2    # number of delayed samples for bufferbloat detection

alpha_baseline_increase=1 # how rapidly baseline RTT is allowed to increase (integer /1000)
alpha_baseline_decrease=900 # how rapidly baseline RTT is allowed to decrease (integer /1000)

rate_adjust_bufferbloat=150 # how rapidly to reduce bandwidth upon detection of bufferbloat (integer /1000)
rate_adjust_load_high=10 # how rapidly to increase bandwidth upon high load detected (integer /1000)
rate_adjust_load_low=25 # how rapidly to return to base rate upon low load detected (integer /1000)

high_load_thr=50 # % of currently set bandwidth for detecting high load (integer /100)

bufferbloat_refractory_period=300 # (milliseconds)
decay_refractory_period=5000 # (milliseconds)

sustained_base_rate_sleep_thr=1000 # time threshold to put pingers to sleep on sustained ul and dl base rate (seconds)

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

if (( $debug )) ; then
    echo "rx_bytes_path: $rx_bytes_path"
    echo "tx_bytes_path: $tx_bytes_path"
fi


