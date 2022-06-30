#!/bin/bash

# config.sh sets up defaults for CAKE-autorate

# config.sh is a part of CAKE-autorate
# CAKE-autorate automatically adjusts bandwidth for CAKE in dependence on detected load and RTT

# Author: @Lynx (OpenWrt forum)
# Inspiration taken from: @moeller0 (OpenWrt forum)

# *** OUTPUT OPTIONS ***

output_processing_stats=1 # enable (1) or disable (0) output monitoring lines showing processing stats
output_cake_changes=0     # enable (1) or disable (0) output monitoring lines showing cake bandwidth changes
debug=0			  # enable (1) or disable (0) out of debug lines

# *** STANDARD CONFIGURATION OPTIONS ***

dl_if=ifb-wg-pbr # download interface
ul_if=wan        # upload interface

reflector_ping_interval_s=0.2 # (seconds, e.g. 0.2s or 2s)

# list of reflectors to use and number of pingers to initiate
# pingers will be initiated with reflectors in the order specified in the list 
# additional reflectors will be used to replace any reflectors that go stale
# so e.g. if 6 reflectors are specified and the number of pingers is set to 4, the first 4 reflectors will be used initially
# and the remaining 2 reflectors in the list will be used in the event any of the first 4 go bad
# a bad reflector will go to the back of the queue on reflector rotation
reflectors=("1.1.1.1" "1.0.0.1" "8.8.8.8" "8.8.4.4" "9.9.9.9" "9.9.9.10")
no_pingers=4

# delay threshold in ms is the extent of RTT increase to classify as a delay
# this is automatically adjusted based on maximum on the wire packet size
# (adjustment significant at sub 12Mbit/s rates, else negligible)  
delay_thr_ms=25 # (milliseconds)

min_dl_shaper_rate_kbps=10000  # minimum bandwidth for download (Kbit/s)
base_dl_shaper_rate_kbps=25000 # steady state bandwidth for download (Kbit/s)
max_dl_shaper_rate_kbps=80000  # maximum bandwidth for download (Kbit/s)

min_ul_shaper_rate_kbps=25000  # minimum bandwidth for upload (Kbit/s)
base_ul_shaper_rate_kbps=30000 # steady state bandwidth for upload (KBit/s)
max_ul_shaper_rate_kbps=35000  # maximum bandwidth for upload (Kbit/s)

# sleep functionality saves unecessary pings and CPU cycles by
# pausing all active pingers when connection is not in active use
enable_sleep_function=1 # enable (1) or disable (0) sleep functonality 
connection_active_thr_kbps=500 # threshold in Kbit/s below which dl/ul is considered idle
sustained_idle_sleep_thr_s=60  # time threshold to put pingers to sleep on sustained dl/ul achieved rate < idle_thr (seconds)

startup_wait_s=0 # number of seconds to wait on startup (e.g. to wait for things to settle on router reboot)

# *** ADVANCED CONFIGURATION OPTIONS ***

# interval in ms for monitoring achieved rx/tx rates
# this is automatically adjusted based on maximum on the wire packet size
# (adjustment significant at sub 12Mbit/s rates, else negligible)  
monitor_achieved_rates_interval_ms=100 # (milliseconds) 

# bufferbloat is detected when (bufferbloat_detection_thr) samples
# out of the last (bufferbloat detection window) samples are delayed
bufferbloat_detection_window=4  # number of samples to retain in detection window
bufferbloat_detection_thr=2     # number of delayed samples for bufferbloat detection

# RTT baseline against which to measure delays
# the idea is that the baseline is allowed to increase slowly to allow for path changes
# and slowly enough such that bufferbloat will be corrected well before the baseline increases,
# but it will decrease very rapidly to ensure delays are measured against the shortest path
alpha_baseline_increase=0.001 # how rapidly baseline RTT is allowed to increase
alpha_baseline_decrease=0.9   # how rapidly baseline RTT is allowed to decrease

# rate adjustment parameters 
# bufferbloat adjustment works with the lower of the adjusted achieved rate and adjusted shaper rate
# to exploit that transfer rates during bufferbloat provide an indication of line capacity
# otherwise shaper rate is adjusted up on load high, and down on load idle or low
# and held the same on load medium
achieved_rate_adjust_down_bufferbloat=0.9 # how rapidly to reduce achieved rate upon detection of bufferbloat 
shaper_rate_adjust_down_bufferbloat=0.9   # how rapidly to reduce shaper rate upon detection of bufferbloat 
shaper_rate_adjust_up_load_high=1.01      # how rapidly to increase shaper rate upon high load detected 
shaper_rate_adjust_down_load_low=0.9      # how rapidly to return down to base shaper rate upon idle or low load detected 
shaper_rate_adjust_up_load_low=1.01       # how rapidly to return up to base shaper rate upon idle or low load detected 

# the load is categoried as low if < medium_load_thr, medium if > medium_load_thr and high if > high_load_thr relative to the current shaper rate
medium_load_thr=0.50 # % of currently set bandwidth for detecting medium load
high_load_thr=0.75   # % of currently set bandwidth for detecting high load

# refractory periods between successive bufferbloat/decay rate changes
# the bufferbloat refractory period should be greater than the 
# average time it would take to replace the bufferbloat
# detection window with new samples upon a bufferbloat event
bufferbloat_refractory_period_ms=300 # (milliseconds)
decay_refractory_period_ms=1000 # (milliseconds)

# interval for checking reflector health
reflector_health_check_interval_s=1 # (seconds)
# deadline for reflector response not to be classified as an offence against reflector
reflector_response_deadline_s=1 # (seconds)

# reflector misbehaving is detected when $reflector_misbehaving_detection_thr samples
# out of the last (reflector misbehaving detection window) samples are offences
# thus with a 1s interval, window 60 and detection_thr 3, this is tantamount to
# 3 offences within the last 60s 
reflector_misbehaving_detection_window=60
reflector_misbehaving_detection_thr=3

global_ping_response_timeout_s=10 # timeout to set shaper rates to min on no ping response whatsoever (seconds)

if_up_check_interval_s=10 # time to wait before re-checking if rx/tx bytes files exist (e.g. from boot state)


# Starlink options
starlink_connection=1 # enable (1) or disable (0) Starlink handling
# satelite switch compensation start times in seconds of each minute
starlink_sat_switch_compensation_times_s=("11.5" "26.5" "41.5" "56.5")
starlink_sat_switch_compensation_period_ms=1000

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
    echo "DEBUG: rx_bytes_path: $rx_bytes_path"
    echo "DEBUG: tx_bytes_path: $tx_bytes_path"
fi
