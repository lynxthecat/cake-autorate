#!/bin/bash

# *** STANDARD CONFIGURATION OPTIONS ***

### For multihomed setups, it is the responsibility of the user to ensure that the probes
### sent by this instance of cake-autorate actually travel through these interfaces.
### See ping_extra_args and ping_prefix_string

dl_if=ifb4eth0 # download interface
ul_if=eth0     # upload interface

# Set either of the below to 0 to adjust one direction only
# or alternatively set both to 0 to simply use cake-autorate to monitor a connection
adjust_dl_shaper_rate=1 # enable (1) or disable (0) actually changing the dl shaper rate
adjust_ul_shaper_rate=1 # enable (1) or disable (0) actually changing the ul shaper rate

min_dl_shaper_rate_kbps=10000  # minimum bandwidth for download (Kbit/s)
base_dl_shaper_rate_kbps=100000 # steady state bandwidth for download (Kbit/s)
max_dl_shaper_rate_kbps=200000  # maximum bandwidth for download (Kbit/s)

min_ul_shaper_rate_kbps=2000  # minimum bandwidth for upload (Kbit/s)
base_ul_shaper_rate_kbps=10000 # steady state bandwidth for upload (KBit/s)
max_ul_shaper_rate_kbps=30000  # maximum bandwidth for upload (Kbit/s)

# *** OVERRIDES ***

### See defaults.sh for additional configuration options
### that can be set in this configuration file to override the defaults.
### Place any such overrides below this line.

# owd delta threshold in ms is the extent of OWD increase to classify as a delay
# these are automatically adjusted based on maximum on the wire packet size
# (adjustment significant at sub 12Mbit/s rates, else negligible)
dl_owd_delta_thr_ms=40.0 # (milliseconds)
ul_owd_delta_thr_ms=40.0 # (milliseconds)

# average owd delta threshold in ms at which maximum adjust_down_bufferbloat is applied
dl_avg_owd_delta_thr_ms=80.0 # (milliseconds)
ul_avg_owd_delta_thr_ms=80.0 # (milliseconds)

# Starlink satellite switch (sss) compensation options
sss_compensation=1
# satellite switch compensation start times in seconds of each minute
#sss_times_s=("12.0" "27.0" "42.0" "57.0")
#sss_compensation_pre_duration_ms=300
#sss_compensation_post_duration_ms=200
