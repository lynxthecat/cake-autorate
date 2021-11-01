#!/bin/sh

# inspired by @moeller0 (OpenWrt forum)
# initial sh implementation by @Lynx (OpenWrt forum)
# requires packages: bc, iputils-ping, coreutils-date and coreutils-sleep

ul_if=wan
dl_if=veth-lan

max_ul_rate=35000
min_ul_rate=25000

max_dl_rate=70000
min_dl_rate=20000

tick_duration=1

alpha_RTT_increase=0.01
alpha_RTT_decrease=0.9

rate_adjust_RTT_spike=0.05
rate_adjust_load_high=0.01
rate_adjust_load_low=0.005

load_thresh=0.5

max_delta_RTT=10

rx_bytes_path="/sys/class/net/${dl_if}/statistics/rx_bytes"
tx_bytes_path="/sys/class/net/${ul_if}/statistics/tx_bytes"

read -d '' reflectors << EOF
1.1.1.1
8.8.8.8
EOF

no_reflectors=$(echo "$reflectors" | wc -l)

RTTs=$(mktemp)

function get_RTT {

for reflector in $reflectors;
do
        echo $(/usr/bin/ping -i 0.00 -c 10 $reflector | tail -1 | awk '{print $4}' | cut -d '/' -f 2) >> $RTTs&
done
wait
RTT=$(echo $(cat $RTTs) | awk 'min=="" || $1 < min {min=$1} END {print min}')
> $RTTs
}

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

        printf "%14.2f;%14.2f;%14.2f;%14.2f;%14.2f;%14.2f;%14.2f;\n" $rx_load $tx_load $baseline_RTT $RTT $delta_RTT $cur_dl_rate $cur_ul_rate
}


get_RTT

baseline_RTT=$RTT;

cur_dl_rate=$min_dl_rate
cur_ul_rate=$min_ul_rate

t_prev_bytes=$(date +%s.%N)

prev_rx_bytes=$(cat $rx_bytes_path)
prev_tx_bytes=$(cat $tx_bytes_path)

printf "%14s;%14s;%14s;%14s;%14s;%14s;%14s;\n" "rx_load" "tx_load" "baseline_RTT" "RTT" "delta_RTT" "cur_dl_rate" "cur_ul_rate"

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
