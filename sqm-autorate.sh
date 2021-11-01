#!/bin/sh

# automatically adjust bandwidth for CAKE in dependence on detected load and RTT

# inspired by @moeller0 (OpenWrt forum)
# initial sh implementation by @Lynx (OpenWrt forum)
# requires packages: bc, iputils-ping, coreutils-date and coreutils-sleep

enable_verbose_output=1 # enable (1) or disable (0) output monitoring lines showing bandwidth changes

ul_if=wan # upload interface
dl_if=veth-lan # download interface

max_ul_rate=35000 # maximum bandwidth for upload
min_ul_rate=25000 # minimum bandwidth for upload

max_dl_rate=70000 # maximum bandwidth for download
min_dl_rate=20000 # minimum bandwidth for download

tick_duration=1 # seconds to wait between ticks

alpha_RTT_increase=0.01 # how rapidly baseline RTT is allowed to increase
alpha_RTT_decrease=0.9 # how rapidly baseline RTT is allowed to decrease

rate_adjust_RTT_spike=0.05 # how rapidly to reduce bandwidth upon detection of bufferbloat
rate_adjust_load_high=0.01 # how rapidly to increase bandwidth upon high load detected
rate_adjust_load_low=0.005 # how rapidly to decrease bandwidth upon low load detected

load_thresh=0.5 # % of currently set bandwidth for detecting high load

max_delta_RTT=10 # increase from baseline RTT for detection of bufferbloat

# verify these are correct using 'cat /sys/class/...'
rx_bytes_path="/sys/class/net/${dl_if}/statistics/rx_bytes"
tx_bytes_path="/sys/class/net/${ul_if}/statistics/tx_bytes"

# if using veth-lan then for download switch from rx_byte to tx_bytes
if [ $dl_if = "veth-lan" ]; then 
        rx_bytes_path="/sys/class/net/${dl_if}/statistics/tx_bytes"
fi

# list of reflectors to use
read -d '' reflectors << EOF
1.1.1.1
8.8.8.8
EOF

no_reflectors=$(echo "$reflectors" | wc -l)

RTTs=$(mktemp)

# get minimum RTT across entire set of reflectors
function get_RTT {

for reflector in $reflectors;
do
        echo $(/usr/bin/ping -i 0.00 -c 10 $reflector | tail -1 | awk '{print $4}' | cut -d '/' -f 2) >> $RTTs&
done
wait
RTT=$(echo $(cat $RTTs) | awk 'min=="" || $1 < min {min=$1} END {print min}')
> $RTTs
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

        if [ $(echo "$delta_RTT > $max_delta_RTT" | bc -l) -eq 1 ]; then
                cur_dl_rate=$(echo "scale=10; $cur_dl_rate-$rate_adjust_RTT_spike*($max_dl_rate-$min_dl_rate)" | bc)
                cur_ul_rate=$(echo "scale=10; $cur_ul_rate-$rate_adjust_RTT_spike*($max_ul_rate-$min_ul_rate)" | bc)
        fi

        if [ $(echo "$delta_RTT < $max_delta_RTT && $rx_load > $load_thresh" |bc) -eq 1 ]; then
                cur_dl_rate=$(echo "scale=10; $cur_dl_rate + $rate_adjust_load_high*($max_dl_rate-$min_dl_rate)"|bc)
        fi

        if [ $(echo "$delta_RTT < $max_delta_RTT && $tx_load > $load_thresh" |bc) -eq 1 ]; then
                cur_ul_rate=$(echo "scale=10; $cur_ul_rate + $rate_adjust_load_high*($max_ul_rate-$min_ul_rate)"|bc)
        fi

        if [ $(echo "$delta_RTT < $max_delta_RTT && $rx_load < $load_thresh" |bc) -eq 1 ]; then
                cur_dl_rate=$(echo "scale=10; $cur_dl_rate - $rate_adjust_load_low*($max_dl_rate-$min_dl_rate)"|bc)
        fi

        if [ $(echo "$delta_RTT < $max_delta_RTT && $tx_load < $load_thresh" |bc) -eq 1 ]; then
                cur_ul_rate=$(echo "scale=10; $cur_ul_rate - $rate_adjust_load_low*($max_ul_rate-$min_ul_rate)"|bc)
        fi

        if [ $(echo "$cur_dl_rate<$min_dl_rate" | bc) -eq 1 ]; then
                cur_dl_rate=$min_dl_rate;
        fi

        if [ $(echo "$cur_ul_rate<$min_ul_rate" | bc) -eq 1 ]; then
                cur_ul_rate=$min_ul_rate;
        fi

        if [ $(echo "$cur_dl_rate>$max_dl_rate" | bc) -eq 1 ]; then
                cur_dl_rate=$max_dl_rate;
        fi

        if [ $(echo "$cur_ul_rate>$max_ul_rate" | bc) -eq 1 ]; then
                cur_ul_rate=$max_ul_rate;
        fi

        if [ $enable_verbose_output -eq 1 ]; then
                printf "%14.2f;%14.2f;%14.2f;%14.2f;%14.2f;%14.2f;%14.2f;\n" $rx_load $tx_load $baseline_RTT $RTT $delta_RTT $cur_dl_rate $cur_ul_rate
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
        printf "%14s;%14s;%14s;%14s;%14s;%14s;%14s;\n" "rx_load" "tx_load" "baseline_RTT" "RTT" "delta_RTT" "cur_dl_rate" "cur_ul_rate"
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
