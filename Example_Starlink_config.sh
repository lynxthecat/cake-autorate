#!/bin/bash

# *** STANDARD CONFIGURATION OPTIONS ***

dl_if=ifb4eth0 # download interface
ul_if=eth0     # upload interface

# list of reflectors to use and number of pingers to initiate
# pingers will be initiated with reflectors in the order specified in the list
# additional reflectors will be used to replace any reflectors that go stale
# so e.g. if 6 reflectors are specified and the number of pingers is set to 4, the first 4 reflectors will be used initially
# and the remaining 2 reflectors in the list will be used in the event any of the first 4 go bad
# a bad reflector will go to the back of the queue on reflector rotation
reflectors=("1.1.1.1" "1.0.0.1" "8.8.8.8" "8.8.4.4" "9.9.9.9" "9.9.9.10")

# Think carefully about the following settings
# to avoid excessive CPU use (proportional with ping interval / number of pingers)
# and to avoid abusive network activity (excessive ICMP frequency to one reflector)
# The author has found an ICMP rate of 1/(0.2/4) = 20 Hz to give satisfactory performance on 4G
no_pingers=6 # number of pingers to maintain
reflector_ping_interval_s=0.15 # (seconds, e.g. 0.2s or 2s)

# delay threshold in ms is the extent of RTT increase to classify as a delay
# this is automatically adjusted based on maximum on the wire packet size
# (adjustment significant at sub 12Mbit/s rates, else negligible)
dl_delay_thr_ms=75 # (milliseconds)
ul_delay_thr_ms=75 # (milliseconds)

min_dl_shaper_rate_kbps=10000  # minimum bandwidth for download (Kbit/s)
base_dl_shaper_rate_kbps=50000 # steady state bandwidth for download (Kbit/s)
max_dl_shaper_rate_kbps=200000  # maximum bandwidth for download (Kbit/s)

min_ul_shaper_rate_kbps=2000  # minimum bandwidth for upload (Kbit/s)
base_ul_shaper_rate_kbps=10000 # steady state bandwidth for upload (KBit/s)
max_ul_shaper_rate_kbps=30000  # maximum bandwidth for upload (Kbit/s)

# *** ADVANCED CONFIGURATION OPTIONS ***

# bufferbloat is detected when (bufferbloat_detection_thr) samples
# out of the last (bufferbloat detection window) samples are delayed
bufferbloat_detection_window=6  # number of samples to retain in detection window
bufferbloat_detection_thr=2     # number of delayed samples for bufferbloat detection

# rate adjustment parameters
# bufferbloat adjustment works with the lower of the adjusted achieved rate and adjusted shaper rate
# to exploit that transfer rates during bufferbloat provide an indication of line capacity
# otherwise shaper rate is adjusted up on load high, and down on load idle or low
# and held the same on load medium
achieved_rate_adjust_down_bufferbloat=0.85 # how rapidly to reduce achieved rate upon detection of bufferbloat
shaper_rate_adjust_down_bufferbloat=0.85   # how rapidly to reduce shaper rate upon detection of bufferbloat
shaper_rate_adjust_up_load_high=1.02       # how rapidly to increase shaper rate upon high load detected
shaper_rate_adjust_down_load_low=0.8       # how rapidly to return down to base shaper rate upon idle or low load detected
shaper_rate_adjust_up_load_low=1.01        # how rapidly to return up to base shaper rate upon idle or low load detected

# Starlink satellite switch (sss) compensation options
sss_compensation=1 # enable (1) or disable (0) Starlink handling
# satellite switch compensation start times in seconds of each minute
sss_times_s=("12.0" "27.0" "42.0" "57.0")
sss_compensation_pre_duration_ms=300
sss_compensation_post_duration_ms=200

config_file_check="cake-autorate"
