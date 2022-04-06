#!/bin/bash

# config.sh sets up defaults for CAKE-autorate

# config.sh is a part of CAKE-autorate
# CAKE-autorate automatically adjusts bandwidth for CAKE in dependence on detected load and RTT

# Author: @Lynx (OpenWrt forum)
# Inspiration taken from: @moeller0 (OpenWrt forum)

#Delay for interface up (e.g Wireguard/OpenVPN)
sleep 15

# *** OUTPUT OPTIONS ***

output_processing_stats=1 # enable (1) or disable (0) output monitoring lines showing processing stats
output_cake_changes=0     # enable (1) or disable (0) output monitoring lines showing cake bandwidth changes
debug=0			  # enable (1) or disable (0) out of debug lines

# *** STANDARD CONFIGURATION OPTIONS ***

ul_if=wan        # upload interface
dl_if=ifb-wg-pbr # download interface

reflector_ping_interval=0.2 # (seconds)

# list of reflectors to use
reflectors=("1.1.1.1" "1.0.0.1" "8.8.8.8" "8.8.4.4")

delay_thr=25 # extent of RTT increase to classify as a delay

min_dl_shaper_rate=10000 # minimum bandwidth for download
base_dl_shaper_rate=25000 # steady state bandwidth for download
max_dl_shaper_rate=80000 # maximum bandwidth for download

min_ul_shaper_rate=25000 # minimum bandwidth for upload
base_ul_shaper_rate=30000 # steady state bandwidth for upload
max_ul_shaper_rate=35000 # maximum bandwidth for upload

# *** ADVANCED CONFIGURATION OPTIONS ***

bufferbloat_detection_window=4 # number of delay samples to retain in detection window
bufferbloat_detection_thr=2    # number of delayed samples for bufferbloat detection

alpha_baseline_increase=0.001 # how rapidly baseline RTT is allowed to increase
alpha_baseline_decrease=0.9   # how rapidly baseline RTT is allowed to decrease

achieved_rate_adjust_bufferbloat=0.9 # how rapidly to reduce achieved rate upon detection of bufferbloat 
shaper_rate_adjust_bufferbloat=0.9   # how rapidly to reduce shaper rate upon detection of bufferbloat 
shaper_rate_adjust_load_high=1.01    # how rapidly to increase shaper rate upon high load detected 
shaper_rate_adjust_load_low=0.98     # how rapidly to return to base shaper rate upon low load detected 

high_load_thr=0.75 # % of currently set bandwidth for detecting high load

bufferbloat_refractory_period=300 # (milliseconds)
decay_refractory_period=1000 # (milliseconds)

sustained_base_rate_sleep_thr=60 # time threshold to put pingers to sleep on sustained ul and dl base rate (seconds)

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
