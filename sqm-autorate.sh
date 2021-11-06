#!/bin/sh

# automatically adjust bandwidth for CAKE in dependence on detected load and RTT

# inspired by @moeller0 (OpenWrt forum)
# initial sh implementation by @Lynx (OpenWrt forum)
# requires packages: bc, iputils-ping, coreutils-date and coreutils-sleep

debug=1

enable_verbose_output=1 # enable (1) or disable (0) output monitoring lines showing bandwidth changes

ul_if=pppoe-wan # upload interface
dl_if=ifb4pppoe-wan # download interface

max_ul_rate=36000 # maximum bandwidth for upload
min_ul_rate=10000 # minimum bandwidth for upload

max_dl_rate=100000 # maximum bandwidth for download
min_dl_rate=33000 # minimum bandwidth for download

tick_duration=1 # seconds to wait between ticks

alpha_RTT_increase=0.01 # how rapidly baseline RTT is allowed to increase
alpha_RTT_decrease=0.9 # how rapidly baseline RTT is allowed to decrease

rate_adjust_RTT_spike=0.05 # how rapidly to reduce bandwidth upon detection of bufferbloat
rate_adjust_load_high=0.01 # how rapidly to increase bandwidth upon high load detected
rate_adjust_load_low=0.005 # how rapidly to decrease bandwidth upon low load detected

load_thresh=0.5 # % of currently set bandwidth for detecting high load

max_delta_RTT=10 # increase from baseline RTT for detection of bufferbloat

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
read -d '' reflectors << EOF
1.1.1.1
8.8.8.8
EOF

no_reflectors=$(echo "$reflectors" | wc -l)

RTTs=$(mktemp)

# get minimum RTT across entire set of reflectors
get_RTT() {

for reflector in $reflectors;
do
        echo $(/usr/bin/ping -i 0.00 -c 10 $reflector | tail -1 | awk '{print $4}' | cut -d '/' -f 2) >> $RTTs&
done
wait
RTT=$(echo $(cat $RTTs) | awk 'min=="" || $1 < min {min=$1} END {print min}')
> $RTTs
}


get_next_shaper_rate() {
    local cur_delta_RTT
    local cur_max_delta_RTT
    local cur_rate
    local cur_rate_adjust_RTT_spike
    local cur_max_rate
    local cur_min_rate
    local cur_load
    local cur_load_thresh
    local cur_rate_adjust_load_high
    local cur_rate_adjust_load_low
    
    local next_rate
    
    cur_delta_RTT=$1
    cur_max_delta_RTT=$2
    cur_rate=$3
    cur_rate_adjust_RTT_spike=$4
    cur_max_rate=$5
    cur_min_rate=$6
    cur_load=$7
    cur_load_thresh=$8
    cur_rate_adjust_load_high=$9
    cur_rate_adjust_load_low=$10


	# in case of supra-threshold RTT spikes decrease the rate unconditionally
        if [ $( echo "$cur_delta_RTT >= $cur_max_delta_RTT" | bc -l ) -eq 1 ] ; then
            next_rate=$( echo "scale=10; $cur_rate - $cur_rate_adjust_RTT_spike * ($cur_max_rate - $cur_min_rate)" | bc )
        else
	    # ... otherwise take the current load into account
	    # high load, so we would like to increase the rate
    	    if [ $( echo "$cur_load >= $cur_load_thresh" | bc ) -eq 1 ] ; then
        	next_rate=$( echo "scale=10; $cur_rate + $cur_rate_adjust_load_high * ($cur_max_rate - $cur_min_rate )" | bc )
    	    fi

	    # low load gently decrease the rate again
    	    if [ $( echo "$cur_load < $cur_load_thresh" | bc ) -eq 1 ] ; then
    	        next_rate=$( echo "scale=10; $cur_rate - $cur_rate_adjust_load_low * ($cur_max_rate - $cur_min_rate)" | bc )
    	    fi
	fi

	# make sure to only return rates between cur_min_rate and cur_max_rate
        if [ $( echo "$next_rate < $cur_min_rate" | bc ) -eq 1 ]; then
            next_rate=$cur_min_rate;
        fi

        if [ $( echo "$next_rate > $cur_max_rate" | bc ) -eq 1 ]; then
            next_rate=$cur_max_rate;
        fi
        
        echo "$next_rate"
}


# update download and upload rates for CAKE
function update_rates {
        get_RTT
        delta_RTT=$(echo "scale=10; $RTT - $baseline_RTT" | bc)

        if [ $(echo "$delta_RTT>=0" | bc) -eq 1 ]; then
                baseline_RTT=$(echo "scale=4; (1-$alpha_RTT_increase)*$baseline_RTT+$alpha_RTT_increase*$RTT" | bc)
        else
                baseline_RTT=$(echo "scale=4; (1-$alpha_RTT_decrease)*$baseline_RTT+$alpha_RTT_decrease*$RTT" | bc)
        fi

        cur_rx_bytes=$(cat $rx_bytes_path)
        cur_tx_bytes=$(cat $tx_bytes_path)
        t_cur_bytes=$(date +%s.%N)
        
        rx_load=$(echo "scale=10; (8/1000)*(($cur_rx_bytes-$prev_rx_bytes)/($t_cur_bytes-$t_prev_bytes)*(1/$cur_dl_rate))"|bc)
        tx_load=$(echo "scale=10; (8/1000)*(($cur_tx_bytes-$prev_tx_bytes)/($t_cur_bytes-$t_prev_bytes)*(1/$cur_ul_rate))"|bc)

        t_prev_bytes=$t_cur_bytes
        prev_rx_bytes=$cur_rx_bytes
        prev_tx_bytes=$cur_tx_bytes

	# calculte the next rate for dl and ul
	cur_dl_rate=$( get_next_shaper_rate "$delta_RTT" "$max_delta_RTT" "$cur_dl_rate" "$rate_adjust_RTT_spike" "$max_dl_rate" "$min_dl_rate" "$rx_load" "$load_thresh" "$rate_adjust_load_high" "$rate_adjust_load_low" )
	cur_ul_rate=$( get_next_shaper_rate "$delta_RTT" "$max_delta_RTT" "$cur_ul_rate" "$rate_adjust_RTT_spike" "$max_ul_rate" "$min_ul_rate" "$tx_load" "$load_thresh" "$rate_adjust_load_high" "$rate_adjust_load_low" )



        if [ $enable_verbose_output -eq 1 ]; then
                printf "%s;%14.2f;%14.2f;%14.2f;%14.2f;%14.2f;%14.2f;%14.2f;\n" $( date "+%Y%m%dT%H%M%S.%N" ) $rx_load $tx_load $baseline_RTT $RTT $delta_RTT $cur_dl_rate $cur_ul_rate
        fi
}

# set initial values for first run

get_RTT

baseline_RTT=$RTT;

cur_dl_rate=$min_dl_rate
cur_ul_rate=$min_ul_rate

t_prev_bytes=$(date +%s.%N)

prev_rx_bytes=$(cat $rx_bytes_path)
prev_tx_bytes=$(cat $tx_bytes_path)

if [ $enable_verbose_output -eq 1 ]; then
        printf "%25s;%14s;%14s;%14s;%14s;%14s;%14s;%14s;\n" "log_time" "rx_load" "tx_load" "baseline_RTT" "RTT" "delta_RTT" "cur_dl_rate" "cur_ul_rate"
fi

# main loop runs every tick_duration seconds
while true
do
        t_start=$(date +%s.%N)
        update_rates
        tc qdisc change root dev $ul_if cake bandwidth "$cur_ul_rate"Kbit
        tc qdisc change root dev $dl_if cake bandwidth "$cur_dl_rate"Kbit
        t_end=$(date +%s.%N)
        sleep_duration=$(echo "$tick_duration-($t_end-$t_start)"|bc)
        if [ $(echo "$sleep_duration > 0" |bc) -eq 1 ]; then
                sleep $sleep_duration
        fi
done
