#!/bin/bash

# CAKE-autorate automatically adjusts bandwidth for CAKE in dependence on detected load and OWD/RTT
# requires packages: bash, iputils-ping and coreutils-sleep

# Author: @Lynx (OpenWrt forum)
# Inspiration taken from: @moeller0 (OpenWrt forum)

# Possible performance improvement
export LC_ALL=C
export TZ=UTC

trap cleanup_and_killall INT TERM EXIT

cleanup_and_killall()
{
	echo "Killing all background processes and cleaning up /tmp files."
	# Resume pingers in case they are sleeping so they can be killed off
	trap - INT && trap - TERM && trap - EXIT
	kill -CONT -- ${ping_pids[@]} 2> /dev/null
	kill -- ${ping_pids[@]} 
	[ -d "/tmp/CAKE-autorate" ] && rm -r "/tmp/CAKE-autorate"
	exit
}

install_dir="/root/CAKE-autorate/"

. $install_dir"config.sh"

# test if stdout is a tty (terminal)
[[ ! -t 1 ]] &&	exec &> /tmp/cake-autorate.log

get_next_shaper_rate() 
{
	local rate=$1
	local cur_min_rate=$2
	local cur_base_rate=$3
	local cur_max_rate=$4
	local load_condition=$5
	local t_next_rate=$6
	local -n t_last_bufferbloat=$7
	local -n t_last_decay=$8
    	local -n cur_rate=$9

	local cur_rate_decayed_down
 	local cur_rate_decayed_up

	case $load_condition in

 		# in case of supra-threshold OWD spikes decrease the rate providing not inside bufferbloat refractory period
		bufferbloat)
			(( $t_next_rate > ($t_last_bufferbloat+$bufferbloat_refractory_period) )) && 
				cur_rate=$(( ($rate*$rate_adjust_bufferbloat)/1000 )) && 
				t_last_bufferbloat=${EPOCHREALTIME/./}
			;;
           	# ... otherwise determine whether to increase or decrease the rate in dependence on load
            	# high load, so increase rate providing not inside bufferbloat refractory period 
		high_load)	
			(( $t_next_rate > ($t_last_bufferbloat+$bufferbloat_refractory_period) )) && 
				cur_rate=$(( ($cur_rate*$rate_adjust_load_high)/1000 ))
			;;
		# low load, so determine whether to decay down towards base rate, decay up towards base rate, or set as base rate
		low_load)
			if (($t_next_rate > ($t_last_decay+$decay_refractory_period) )); then
		
	                	cur_rate_decayed_down=$(( ($cur_rate*$rate_adjust_load_low)/1000 ))
        	        	cur_rate_decayed_up=$(( ((2000-$rate_adjust_load_low)*$cur_rate)/1000 ))

				# Default to base rate
				cur_rate=$cur_base_rate

                		# If base rate not reached, gently decrease to steady state rate
	                	(($cur_rate_decayed_down > $cur_base_rate)) && cur_rate=$cur_rate_decayed_down
                		# If base rate not reached, gently increase to steady state rate
	                	(($cur_rate_decayed_up < $cur_base_rate)) && cur_rate=$cur_rate_decayed_up
                		# steady state has been reached
				t_last_decay=${EPOCHREALTIME/./}
			fi
			;;
	esac
        # make sure to only return rates between cur_min_rate and cur_max_rate
        (($cur_rate < $cur_min_rate)) && cur_rate=$cur_min_rate;
        (($cur_rate > $cur_max_rate)) && cur_rate=$cur_max_rate;
}

# update download and upload rates for CAKE
update_loads()
{
        read -r cur_rx_bytes < "$rx_bytes_path"
        read -r cur_tx_bytes < "$tx_bytes_path"
        t_cur_bytes=${EPOCHREALTIME/./}

	t_diff_bytes=$(($t_cur_bytes - $t_prev_bytes))

        rx_rate=$(( ((8000*($cur_rx_bytes - $prev_rx_bytes)) / $t_diff_bytes ) ))
        tx_rate=$(( ((8000*($cur_tx_bytes - $prev_tx_bytes)) / $t_diff_bytes ) ))

	rx_load=$(((100*$rx_rate)/$cur_dl_rate))
	tx_load=$(((100*$tx_rate)/$cur_ul_rate))

        t_prev_bytes=$t_cur_bytes
        prev_rx_bytes=$cur_rx_bytes
        prev_tx_bytes=$cur_tx_bytes
}

# ping reflector, maintain baseline and output deltas to a common fifo
monitor_reflector_path() 
{
	local reflector=$1
	local rtt_baseline=$2

	while read -r  timestamp _ _ _ reflector seq_rtt
	do
		# If no match then skip onto the next one
		[[ $seq_rtt =~ icmp_seq=([0-9]+).*time=([0-9]+)\.?([0-9]+)?[[:space:]]ms ]] || continue

		seq=${BASH_REMATCH[1]}

		rtt=${BASH_REMATCH[3]}000

		rtt=$((${BASH_REMATCH[2]}000+${rtt:0:3}))
		
		reflector=${reflector//:/}

		rtt_delta=$(( $rtt-$rtt_baseline ))

		alpha=$alpha_baseline_decrease
		(( $rtt_delta >=0 )) && alpha=$alpha_baseline_increase

		rtt_baseline=$(( ( (1000-$alpha)*$rtt_baseline+$alpha*$rtt )/1000 ))

		printf '%s %s %s %s %s %s\n' "$timestamp" "$reflector" "$seq" "$rtt_baseline" "$rtt" "$rtt_delta" > /tmp/CAKE-autorate/ping_fifo

	done< <(ping -D -i $reflector_ping_interval $reflector & echo $! >/tmp/CAKE-autorate/${reflector}_ping_pid)
}

sleep_remaining_tick_time()
{
	local t_start=$1 # (microseconds)
	local t_end=$2 # (microseconds)
	local tick_duration=$3 # (microseconds)

	sleep_duration=$(( $tick_duration - $t_end + $t_start))
        # echo $(($sleep_duration/(10**6)))
        (($sleep_duration > 0 )) && sleep $sleep_duration"e-6"
}


# Initialize variables

# Convert human readable parameters to values that work with integer arithmetic
printf -v alpha_baseline_increase %.0f\\n "${alpha_baseline_increase}e3"
printf -v alpha_baseline_decrease %.0f\\n "${alpha_baseline_decrease}e3"   
printf -v rate_adjust_bufferbloat %.0f\\n "${rate_adjust_bufferbloat}e3"
printf -v rate_adjust_load_high %.0f\\n "${rate_adjust_load_high}e3"
printf -v rate_adjust_load_low %.0f\\n "${rate_adjust_load_low}e3"
printf -v high_load_thr %.0f\\n "${high_load_thr}e2"
printf -v reflector_ping_interval_us %.0f\\n "${reflector_ping_interval}e6"
bufferbloat_refractory_period=$(( 1000*$bufferbloat_refractory_period ))
decay_refractory_period=$(( 1000*$decay_refractory_period ))
delay_thr=$(( 1000*$delay_thr ))

no_reflectors=${#reflectors[@]} 

cur_ul_rate=$base_ul_rate
cur_dl_rate=$base_dl_rate

last_ul_rate=$cur_ul_rate
last_dl_rate=$cur_dl_rate

tc qdisc change root dev ${ul_if} cake bandwidth ${cur_ul_rate}Kbit
tc qdisc change root dev ${dl_if} cake bandwidth ${cur_dl_rate}Kbit

prev_tx_bytes=$(cat $tx_bytes_path)
prev_rx_bytes=$(cat $rx_bytes_path)
t_prev_bytes=${EPOCHREALTIME/./}

t_start=${EPOCHREALTIME/./}
t_end=${EPOCHREALTIME/./}
t_prev_ul_rate_set=$t_prev_bytes
t_prev_dl_rate_set=$t_prev_bytes
t_ul_last_bufferbloat=$t_prev_bytes
t_ul_last_decay=$t_prev_bytes
t_dl_last_bufferbloat=$t_prev_bytes
t_dl_last_decay=$t_prev_bytes 

t_sustained_base_rate=0
ping_sleep=0

declare -a delays=( $(for i in {1..$bufferbloat_detection_window}; do echo 0; done) )
delays_idx=0
sum_delays=0

[ ! -d "/tmp/CAKE-autorate" ] && mkdir "/tmp/CAKE-autorate"

mkfifo /tmp/CAKE-autorate/ping_fifo

exec 3<> /tmp/CAKE-autorate/ping_fifo

declare -A rtt_baseline

# Get initial rtt_baselines for each reflector
for reflector in "${reflectors[@]}"
do
	[[ $(ping -q -c 10 -i 0.1 $reflector | tail -1) =~ ([0-9.]+)/ ]];
	printf -v rtt_baseline[$reflector] %.0f\\n "${BASH_REMATCH[1]}e3"
done

# Initiate pingers
for reflector in "${reflectors[@]}"
do
	t_start=${EPOCHREALTIME/./}
	$cur_base_rate
	monitor_reflector_path $reflector ${rtt_baseline[$reflector]}&
	t_end=${EPOCHREALTIME/./}
	# Space out pings by ping interval / number of reflectors
	sleep_remaining_tick_time $t_start $t_end $(( $reflector_ping_interval_us / $no_reflectors ))
done

for reflector in "${reflectors[@]}"
do
	read ping_pid < /tmp/CAKE-autorate/${reflector}_ping_pid
	ping_pids+=($ping_pid)
done

while true
do
	while read -r timestamp reflector seq rtt_baseline rtt rtt_delta
	do 
		t_start=${EPOCHREALTIME/./}
		if ((($t_start - "${timestamp//[[\[\].]}")>500000)); then
			(($debug)) && echo "WARNING: encountered response from [" $reflector "] that is > 500ms old. Skipping." 
			continue
		fi

		(( ${delays[$delays_idx]} )) && ((sum_delays--))
		delay=0
		(($rtt_delta > $delay_thr)) && delay=1 && ((sum_delays++))
		delays[$delays_idx]=$delay
		(( delays_idx=(delays_idx+1)%$bufferbloat_detection_window ))
	
		update_loads

		dl_load_condition="low_load"
		(($rx_load > $high_load_thr)) && dl_load_condition="high_load"

		ul_load_condition="low_load"
		(($tx_load > $high_load_thr)) && ul_load_condition="high_load"
	
		(($sum_delays>=$bufferbloat_detection_thr)) && ul_load_condition="bufferbloat" && dl_load_condition="bufferbloat"

		get_next_shaper_rate $rx_rate $min_dl_rate $base_dl_rate $max_dl_rate $dl_load_condition $t_start t_dl_last_bufferbloat t_dl_last_decay cur_dl_rate
		get_next_shaper_rate $tx_rate $min_ul_rate $base_ul_rate $max_ul_rate $ul_load_condition $t_start t_ul_last_bufferbloat t_ul_last_decay cur_ul_rate

		(($output_processing_stats)) && printf '%s %s %s %s %s %s %s %s %s %s %s %s %s %s %s %s\n' $EPOCHREALTIME $rx_rate $tx_rate $rx_load $tx_load $timestamp $reflector $seq $rtt_baseline $rtt $rtt_delta $sum_delays $dl_load_condition $ul_load_condition $cur_dl_rate $cur_ul_rate

       		# fire up tc if there are rates to change
		if (( $cur_dl_rate != $last_dl_rate)); then
       			(($output_cake_changes)) && echo "tc qdisc change root dev ${dl_if} cake bandwidth ${cur_dl_rate}Kbit"
       			tc qdisc change root dev ${dl_if} cake bandwidth ${cur_dl_rate}Kbit
			t_prev_dl_rate_set=${EPOCHREALTIME/./}
		fi
       		if (( $cur_ul_rate != $last_ul_rate )); then
         		(($output_cake_changes)) && echo "tc qdisc change root dev ${ul_if} cake bandwidth ${cur_ul_rate}Kbit"
       			tc qdisc change root dev ${ul_if} cake bandwidth ${cur_ul_rate}Kbit
			t_prev_ul_rate_set=${EPOCHREALTIME/./}
		fi
		
		# If base rate is sustained, increment sustained base rate timer (and break out of processing loop if enough time passes)
		if (( $cur_ul_rate == $base_ul_rate && $last_ul_rate == $base_ul_rate && $cur_dl_rate == $base_dl_rate && $last_dl_rate == $base_dl_rate )); then
			((t_sustained_base_rate+=$((${EPOCHREALTIME/./}-$t_end))))
			(($t_sustained_base_rate>(10**6*$sustained_base_rate_sleep_thr))) && break
		else
			# reset timer
			t_sustained_base_rate=0
		fi

		# remember the last rates
       		last_dl_rate=$cur_dl_rate
       		last_ul_rate=$cur_ul_rate

		t_end=${EPOCHREALTIME/./}

	done</tmp/CAKE-autorate/ping_fifo

	# we broke out of processing loop, so conservatively set hard minimums and wait until there is a load increase again
	cur_dl_rate=$min_dl_rate
        tc qdisc change root dev ${dl_if} cake bandwidth ${cur_dl_rate}Kbit
	cur_ul_rate=$min_ul_rate
        tc qdisc change root dev ${ul_if} cake bandwidth ${cur_ul_rate}Kbit
	# remember the last rates
	last_ul_rate=$cur_ul_rate
	last_dl_rate=$cur_dl_rate

	# Pause ping processes
	kill -STOP -- ${ping_pids[@]}

	# wait until load increases again
	while true
	do
		t_start=${EPOCHREALTIME/./}	
		update_loads
		(($rx_load>$high_load_thr || $tx_load>$high_load_thr)) && break 
		t_end=${EPOCHREALTIME/./}
		sleep $(($t_end-$t_start))"e-6"
		sleep_remaining_tick_time $t_start $t_end $reflector_ping_interval_us
	done

	# Continue ping processes
	kill -CONT -- ${ping_pids[@]}
done
