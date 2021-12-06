#!/bin/sh

# automatically adjust bandwidth for CAKE in dependence on detected load and RTT

# inspired by @moeller0 (OpenWrt forum)
# initial sh implementation by @Lynx (OpenWrt forum)
# requires packages: iputils-ping, coreutils-date and coreutils-sleep

debug=1

enable_verbose_output=1 # enable (1) or disable (0) output monitoring lines showing bandwidth changes

ul_if=wan # upload interface
dl_if=veth-lan # download interface

base_ul_rate=30000 # steady state bandwidth for upload

base_dl_rate=30000 # steady state bandwidth for download

tick_duration=0.5 # seconds to wait between ticks

alpha_RTT_increase=0.001 # how rapidly baseline RTT is allowed to increase
alpha_RTT_decrease=0.9 # how rapidly baseline RTT is allowed to decrease

rate_adjust_RTT_spike=0.01 # how rapidly to reduce bandwidth upon detection of bufferbloat
rate_adjust_load_high=0.005 # how rapidly to increase bandwidth upon high load detected
rate_adjust_load_low=0.0025 # how rapidly to return to base rate upon low load detected

load_thresh=0.5 # % of currently set bandwidth for detecting high load

max_delta_RTT=15 # increase from baseline RTT for detection of bufferbloat

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


call_awk() {
  printf '%s' "$(awk 'BEGIN {print '"${1}"'}')"
}

get_next_shaper_rate() {
    local cur_delta_RTT
    local cur_max_delta_RTT
    local cur_rate
    local cur_base_rate
    local cur_load
    local cur_load_thresh
    local cur_rate_adjust_RTT_spike
    local cur_rate_adjust_load_high
    local cur_rate_adjust_load_low

    local next_rate
    local cur_rate_decayed_down
    local cur_rate_decayed_up

    cur_delta_RTT=$1
    cur_max_delta_RTT=$2
    cur_rate=$3
    cur_base_rate=$4
    cur_load=$5
    cur_load_thresh=$6
    cur_rate_adjust_RTT_spike=$7
    cur_rate_adjust_load_high=$8
    cur_rate_adjust_load_low=$9

        # in case of supra-threshold RTT spikes decrease the rate so long as there is a load
        if awk "BEGIN {exit !(($cur_delta_RTT >= $cur_max_delta_RTT))}"; then
            next_rate=$( call_awk "int( ${cur_rate}*(1-${cur_rate_adjust_RTT_spike}) )" )
        else
            # ... otherwise determine whether to increase or decrease the rate in dependence on load
            # high load, so we would like to increase the rate
            if awk "BEGIN {exit !($cur_load >= $cur_load_thresh)}"; then
                next_rate=$( call_awk "int( ${cur_rate}*(1+${cur_rate_adjust_load_high}) )" )
            else
                # low load, so determine whether to decay down towards base rate, decay up towards base rate, or set as base rate
                cur_rate_decayed_down=$( call_awk "int( ${cur_rate}*(1-${cur_rate_adjust_load_low}) )" )
                cur_rate_decayed_up=$( call_awk "int( ${cur_rate}*(1+${cur_rate_adjust_load_low}) )" )

                # gently decrease to steady state rate
                if awk "BEGIN {exit !($cur_rate_decayed_down > $cur_base_rate)}"; then
                        next_rate=$cur_rate_decayed_down
                # gently increase to steady state rate
                elif awk "BEGIN {exit !($cur_rate_decayed_up < $cur_base_rate)}"; then
                        next_rate=$cur_rate_decayed_up
                # steady state has been reached
                else
                        next_rate=$cur_base_rate
        fi
        fi
        fi

        echo "${next_rate}"
}


# update download and upload rates for CAKE
function update_rates {
        cur_rx_bytes=$(cat $rx_bytes_path)
        cur_tx_bytes=$(cat $tx_bytes_path)
        t_cur_bytes=$(date +%s.%N)

        rx_load=$( call_awk "(8/1000)*(${cur_rx_bytes} - ${prev_rx_bytes}) / (${t_cur_bytes} - ${t_prev_bytes}) * (1/${cur_dl_rate}) " )
        tx_load=$( call_awk "(8/1000)*(${cur_tx_bytes} - ${prev_tx_bytes}) / (${t_cur_bytes} - ${t_prev_bytes}) * (1/${cur_ul_rate}) " )

        t_prev_bytes=$t_cur_bytes
        prev_rx_bytes=$cur_rx_bytes
        prev_tx_bytes=$cur_tx_bytes

        # calculate the next rate for dl and ul
        cur_dl_rate=$( get_next_shaper_rate "$delta_RTT" "$max_delta_RTT" "$cur_dl_rate" "$base_dl_rate" "$rx_load" "$load_thresh" "$rate_adjust_RTT_spike" "$rate_adjust_load_high" "$rate_adjust_load_low")
        cur_ul_rate=$( get_next_shaper_rate "$delta_RTT" "$max_delta_RTT" "$cur_ul_rate" "$base_ul_rate" "$tx_load" "$load_thresh" "$rate_adjust_RTT_spike" "$rate_adjust_load_high" "$rate_adjust_load_low")

        if [ $enable_verbose_output -eq 1 ]; then
                printf "%s;%14.2f;%14.2f;%14.2f;%14.2f;%14.2f;%14.2f;%14.2f;\n" $( date "+%Y%m%dT%H%M%S.%N" ) $rx_load $tx_load $baseline_RTT $RTT $delta_RTT $cur_dl_rate $cur_ul_rate
        fi
}

get_baseline_RTT() {
    local cur_RTT
    local cur_delta_RTT
    local last_baseline_RTT
    local cur_alpha_RTT_increase
    local cur_alpha_RTT_decrease

    local cur_baseline_RTT

    cur_RTT=$1
    cur_delta_RTT=$2
    last_baseline_RTT=$3
    cur_alpha_RTT_increase=$4
    cur_alpha_RTT_decrease=$5
        if awk "BEGIN {exit !($cur_delta_RTT >= 0)}"; then
                cur_baseline_RTT=$( call_awk "( 1 - ${cur_alpha_RTT_increase} ) * ${last_baseline_RTT} + ${cur_alpha_RTT_increase} * ${cur_RTT} " )
        else
                cur_baseline_RTT=$( call_awk "( 1 - ${cur_alpha_RTT_decrease} ) * ${last_baseline_RTT} + ${cur_alpha_RTT_decrease} * ${cur_RTT} " )
        fi

    echo "${cur_baseline_RTT}"
}



# set initial values for first run

get_RTT

baseline_RTT=$RTT;

cur_dl_rate=$base_dl_rate
cur_ul_rate=$base_ul_rate
# set the next different from the cur_XX_rates so that on the first round we are guaranteed to call tc
last_dl_rate=0
last_ul_rate=0


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
        get_RTT
        delta_RTT=$( call_awk "${RTT} - ${baseline_RTT}" )
        baseline_RTT=$( get_baseline_RTT "$RTT" "$delta_RTT" "$baseline_RTT" "$alpha_RTT_increase" "$alpha_RTT_decrease" )
        update_rates

        # only fire up tc if there are rates to change...
        if [ "$last_dl_rate" -ne "$cur_dl_rate" ] ; then
            #echo "tc qdisc change root dev ${dl_if} cake bandwidth ${cur_dl_rate}Kbit"
            tc qdisc change root dev ${dl_if} cake bandwidth ${cur_dl_rate}Kbit
        fi
        if [ "$last_ul_rate" -ne "$cur_ul_rate" ] ; then
            #echo "tc qdisc change root dev ${ul_if} cake bandwidth ${cur_ul_rate}Kbit"
            tc qdisc change root dev ${ul_if} cake bandwidth ${cur_ul_rate}Kbit
        fi
        # remember the last rates
        last_dl_rate=$cur_dl_rate
        last_ul_rate=$cur_ul_rate

        t_end=$(date +%s.%N)
        sleep_duration=$( call_awk "${tick_duration} - ${t_end} + ${t_start}" )
        if awk "BEGIN {exit !($sleep_duration > 0)}"; then
                sleep $sleep_duration
        fi
done
