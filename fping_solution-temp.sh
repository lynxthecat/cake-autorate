#!/bin/bash

export LC_ALL=C
export TZ=UTC

ping_interval=100

dl_if=veth-lan
ul_if=wan

delay_thr=15000

high_load_thr=50

min_ul_rate=25000
base_ul_rate=30000
max_ul_rate=35000

min_dl_rate=20000
base_dl_rate=30000
max_dl_rate=80000

cur_dl_rate=30000
cur_ul_rate=30000

rate_adjust_OWD_spike=50 # how rapidly to reduce bandwidth upon detection of bufferbloat (integer /1000)
rate_adjust_load_high=10 # how rapidly to increase bandwidth upon high load detected (integer /1000)
rate_adjust_load_low=25 # how rapidly to return to base rate upon low load detected (integer /1000)

bufferbloat_refractory_period=300 # (milliseconds)
decay_refractory_period=5000 # (milliseconds)

last_ul_rate=$cur_ul_rate
last_dl_rate=$cur_dl_rate

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

update_loads()
{
        read -r cur_rx_bytes < "$rx_bytes_path"
        read -r cur_tx_bytes < "$tx_bytes_path"
        t_cur_bytes=${EPOCHREALTIME/./}

        rx_load=$(( ( (8*10**5*($cur_rx_bytes - $prev_rx_bytes)) / ($t_cur_bytes - $t_prev_bytes)) / $cur_dl_rate  ))
        tx_load=$(( ( (8*10**5*($cur_tx_bytes - $prev_tx_bytes)) / ($t_cur_bytes - $t_prev_bytes)) / $cur_ul_rate  ))

        t_prev_bytes=$t_cur_bytes
        prev_rx_bytes=$cur_rx_bytes
        prev_tx_bytes=$cur_tx_bytes

}

get_next_shaper_rate() 
{

    	local cur_rate=$1
	local cur_min_rate=$2
	local cur_base_rate=$3
	local cur_max_rate=$4
	local load_condition=$5
	local t_next_rate=$6
	local -n t_last_bufferbloat=$7
	local -n t_last_decay=$8
    	local -n next_rate=$9

	local cur_rate_decayed_down
 	local cur_rate_decayed_up

	case $load_condition in

 		# in case of supra-threshold OWD spikes decrease the rate providing not inside bufferbloat refractory period
		bufferbloat)
			if (( $t_next_rate > ($t_last_bufferbloat+(10**3)*$bufferbloat_refractory_period) )); then
        			next_rate=$(( $cur_rate*(1000-$rate_adjust_OWD_spike)/1000 ))
				t_last_bufferbloat=${EPOCHREALTIME/./}
			else
				next_rate=$cur_rate
			fi
			;;
           	# ... otherwise determine whether to increase or decrease the rate in dependence on load
            	# high load, so increase rate providing not inside bufferbloat refractory period 
		high_load)	
			if (( $t_next_rate > ($t_last_bufferbloat+(10**3)*$bufferbloat_refractory_period) )); then
                		next_rate=$(($cur_rate*(1000+$rate_adjust_load_high)/1000 ))
			
			else
				next_rate=$cur_rate
			fi
			;;
		# low load, so determine whether to decay down towards base rate, decay up towards base rate, or set as base rate
		low_load)
			if (($t_next_rate > ($t_last_decay+(10**3)*$decay_refractory_period) )); then
		
	                	cur_rate_decayed_down=$(($cur_rate*(1000-$rate_adjust_load_low)/1000))
        	        	cur_rate_decayed_up=$(($cur_rate*(1000+$rate_adjust_load_low)/1000))

                		# gently decrease to steady state rate
	                	if (($cur_rate_decayed_down > $cur_base_rate)); then
        	                	next_rate=$cur_rate_decayed_down
                		# gently increase to steady state rate
	                	elif (($cur_rate_decayed_up < $cur_base_rate)); then
        	                	next_rate=$cur_rate_decayed_up
                		# steady state has been reached
	               		else
					next_rate=$cur_base_rate
				fi
				t_last_decay=${EPOCHREALTIME/./}
			else
				next_rate=$cur_rate
			fi
			;;
	esac
        # make sure to only return rates between cur_min_rate and cur_max_rate
        if (($next_rate < $cur_min_rate)); then
            next_rate=$cur_min_rate;
        fi

        if (($next_rate > $cur_max_rate)); then
            next_rate=$cur_max_rate;
        fi

}

alpha_RTT_increase=1
alpha_RTT_decrease=900

declare -A baseline

baseline[1.1.1.1]=50000
baseline[8.8.8.8]=50000
baseline[1.0.0.1]=50000
baseline[8.8.4.4]=50000

prev_tx_bytes=$(cat $tx_bytes_path)
prev_rx_bytes=$(cat $rx_bytes_path)
t_prev_bytes=${EPOCHREALTIME/./}

delay_period=10
bufferbloat_thr=2

t_ul_last_bufferbloat=$t_prev_bytes
t_ul_last_decay=$t_prev_bytes
t_dl_last_bufferbloat=$t_prev_bytes
t_dl_last_decay=$t_prev_bytes

delays=( $(printf ' 0%.0s' $(seq $delay_period)) )

echo "${delays[*]}"

fping --timestamp --loop -p $ping_interval -t 500 1.1.1.1 8.8.8.8 1.0.0.1 8.8.4.4 | while read -r timestamp reflector _ seq timeout _ RTT _ _
do 
	[[ $timeout -eq "timed" ]] && continue

	t_start=${EPOCHREALTIME/./}

	echo $RTT

	RTT=$(printf %.0f\\n "${RTT}e3")
	
	RTT_delta=$(( $RTT - ${baseline[$reflector]} ))

	unset 'delays[0]'
	
	if (($RTT_delta > $delay_thr)); then 
		delays+=(1)
	else 
		delays+=(0)
	fi	

	delays=(${delays[*]})

	if (( $RTT_delta >= 0 )); then
		baseline[$reflector]=$(( ( (1000-$alpha_RTT_increase)*${baseline[$reflector]}+$alpha_RTT_increase*$RTT )/1000 ))
	else
		baseline[$reflector]=$(( ( (1000-$alpha_RTT_decrease)*${baseline[$reflector]}+$alpha_RTT_decrease*$RTT )/1000 ))
	fi

	update_loads

	ul_load_condition="low_load"
	(($tx_load > $high_load_thr)) && ul_load_condition="high_load"

	dl_load_condition="low_load"
	(($rx_load > $high_load_thr)) && dl_load_condition="high_load"

	sum=$(IFS=+; echo "$((${delays[*]}))")

	(($sum>$bufferbloat_thr)) && ul_load_condition="bufferbloat" && dl_load_condition="bufferbloat"
	
	get_next_shaper_rate $cur_ul_rate $min_ul_rate $base_ul_rate $max_ul_rate $ul_load_condition $t_start t_ul_last_bufferbloat t_ul_last_decay cur_ul_rate

	get_next_shaper_rate $cur_dl_rate $min_dl_rate $base_dl_rate $max_dl_rate $dl_load_condition $t_start t_dl_last_bufferbloat t_dl_last_decay cur_dl_rate


	echo $EPOCHREALTIME $rx_load $tx_load $cur_dl_rate $cur_ul_rate $timestamp $reflector ${baseline[$reflector]} $RTT $RTT_delta $sum $ul_load_condition $dl_load_condition "${delays[@]}"

       	# fire up tc if there are rates to change
        if (( $cur_ul_rate != $last_ul_rate )); then
         	(( $enable_verbose_output )) && echo "tc qdisc change root dev ${ul_if} cake bandwidth ${cur_ul_rate}Kbit"
       		tc qdisc change root dev ${ul_if} cake bandwidth ${cur_ul_rate}Kbit
		t_prev_ul_rate_set=${EPOCHREALTIME/./}
	fi
	if (( $cur_dl_rate != $last_dl_rate)); then
       		(($enable_verbose_output)) && echo "tc qdisc change root dev ${dl_if} cake bandwidth ${cur_dl_rate}Kbit"
       		tc qdisc change root dev ${dl_if} cake bandwidth ${cur_dl_rate}Kbit
		t_prev_dl_rate_set=${EPOCHREALTIME/./}
	fi
	# remember the last rates
        last_ul_rate=$cur_ul_rate
       	last_dl_rate=$cur_dl_rate

done
