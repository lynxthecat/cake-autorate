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
	kill $monitor_achieved_rates_pid
	kill -CONT -- ${ping_pids[@]} 2> /dev/null
	kill -- ${ping_pids[@]} 2> /dev/null
	[ -d "/tmp/CAKE-autorate" ] && rm -r "/tmp/CAKE-autorate"
	exit
}

install_dir="/root/CAKE-autorate/"

. $install_dir"config.sh"

# test if stdout is a tty (terminal)
[[ ! -t 1 ]] &&	exec &> /tmp/cake-autorate.log

get_next_shaper_rate() 
{
	local min_shaper_rate=$1
	local base_shaper_rate=$2
	local max_shaper_rate=$3
	local achieved_rate=$4
	local load_condition=$5
	local t_next_rate=$6
	local -n t_last_bufferbloat=$7
	local -n t_last_decay=$8
    	local -n shaper_rate=$9

	local shaper_rate_decayed_down
 	local shaper_rate_decayed_up

	case $load_condition in

		# in case of supra-threshold RTT spikes decrease the rate providing not inside bufferbloat refractory period
		*delayed)
			if (( $t_next_rate > ($t_last_bufferbloat+$bufferbloat_refractory_period) )); then
				adjusted_achieved_rate=$(( ($achieved_rate*$achieved_rate_adjust_bufferbloat)/1000 )) 
				adjusted_shaper_rate=$(( ($shaper_rate*$shaper_rate_adjust_bufferbloat)/1000 )) 
				shaper_rate=$(( $adjusted_achieved_rate < $adjusted_shaper_rate ? $adjusted_achieved_rate : $adjusted_shaper_rate ))
				t_last_bufferbloat=${EPOCHREALTIME/./}
			fi
			;;
		
            	# high load, so increase rate providing not inside bufferbloat refractory period 
		high)	
			if (( $t_next_rate > ($t_last_bufferbloat+$bufferbloat_refractory_period) )); then
				shaper_rate=$(( ($shaper_rate*$shaper_rate_adjust_load_high)/1000 ))
			fi
			;;
		# low load, so determine whether to decay down towards base rate, decay up towards base rate, or set as base rate
		low|idle)
			if (($t_next_rate > ($t_last_decay+$decay_refractory_period) )); then
	                	if (($shaper_rate > $base_shaper_rate)); then
					decayed_shaper_rate=$(( ($shaper_rate*$shaper_rate_adjust_load_low)/1000 ))
					shaper_rate=$(( $decayed_shaper_rate > $base_shaper_rate ? $decayed_shaper_rate : $base_shaper_rate))
				elif (($shaper_rate < $base_shaper_rate)); then
        	        		decayed_shaper_rate=$(( ((2000-$shaper_rate_adjust_load_low)*$shaper_rate)/1000 ))
					shaper_rate=$(( $decayed_shaper_rate < $base_shaper_rate ? $decayed_shaper_rate : $base_shaper_rate))
                		fi
				# steady state has been reached
				t_last_decay=${EPOCHREALTIME/./}
			fi
			;;
	esac
        # make sure to only return rates between cur_min_rate and cur_max_rate
        (($shaper_rate < $min_shaper_rate)) && shaper_rate=$min_shaper_rate;
        (($shaper_rate > $max_shaper_rate)) && shaper_rate=$max_shaper_rate;
}

# track rx and tx bytes transferred and divide by time since last update
# to determine achieved dl and ul transfer rates
monitor_achieved_rates()
{
	local rx_bytes_path=$1
	local tx_bytes_path=$2
	local monitor_achieved_rates_interval=$3 # (microseconds)

	read -r prev_rx_bytes < "$rx_bytes_path" 
	read -r prev_tx_bytes < "$tx_bytes_path" 
	t_prev_bytes=${EPOCHREALTIME/./}

	while true
	do
        	t_start=${EPOCHREALTIME/./}

		# If rx/tx bytes file exists, read it in, otherwise set to previous reading
		# This addresses interfaces going down and back up
       		[ -f "$rx_bytes_path" ] && read -r rx_bytes < "$rx_bytes_path" || rx_bytes=$prev_rx_bytes
       		[ -f "$tx_bytes_path" ] && read -r tx_bytes < "$tx_bytes_path" || tx_bytes=$prev_tx_bytes

        	dl_achieved_rate=$(( ((8000*($rx_bytes - $prev_rx_bytes)) / $monitor_achieved_rates_interval ) ))
       		ul_achieved_rate=$(( ((8000*($tx_bytes - $prev_tx_bytes)) / $monitor_achieved_rates_interval ) ))
	
		{
			flock -x 200
			printf '%s %s' "$dl_achieved_rate" "$ul_achieved_rate" > /tmp/CAKE-autorate/achieved_rates
		} 200> /tmp/CAKE-autorate/achieved_rates_lock
       		t_prev_bytes=$t_bytes
       		prev_rx_bytes=$rx_bytes
       		prev_tx_bytes=$tx_bytes

		t_end=${EPOCHREALTIME/./}

		sleep_remaining_tick_time $t_start $t_end $monitor_achieved_rates_interval		
	done
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

# Sanity check the rx/tx paths	
{ [ ! -f "$rx_bytes_path" ] || [ ! -f "$tx_bytes_path" ]; } && sleep 10 # Give time for ifb's to come up
[ ! -f "$rx_bytes_path" ] && echo "Error: "$rx_bytes_path "does not exist. Exiting script." && exit
[ ! -f "$tx_bytes_path" ] && echo "Error: "$tx_bytes_path "does not exist. Exiting script." && exit

# Initialize variables

# Convert human readable parameters to values that work with integer arithmetic
printf -v alpha_baseline_increase %.0f\\n "${alpha_baseline_increase}e3"
printf -v alpha_baseline_decrease %.0f\\n "${alpha_baseline_decrease}e3"   
printf -v achieved_rate_adjust_bufferbloat %.0f\\n "${achieved_rate_adjust_bufferbloat}e3"
printf -v shaper_rate_adjust_bufferbloat %.0f\\n "${shaper_rate_adjust_bufferbloat}e3"
printf -v shaper_rate_adjust_load_high %.0f\\n "${shaper_rate_adjust_load_high}e3"
printf -v shaper_rate_adjust_load_low %.0f\\n "${shaper_rate_adjust_load_low}e3"
printf -v high_load_thr %.0f\\n "${high_load_thr}e2"
printf -v medium_load_thr %.0f\\n "${medium_load_thr}e2"
printf -v reflector_ping_interval_us %.0f\\n "${reflector_ping_interval}e6"
printf -v monitor_achieved_rates_interval %.0f\\n "${monitor_achieved_rates_interval}e3"
printf -v sustained_idle_sleep_thr %.0f\\n "${sustained_idle_sleep_thr}e6"
bufferbloat_refractory_period=$(( 1000*$bufferbloat_refractory_period ))
decay_refractory_period=$(( 1000*$decay_refractory_period ))
delay_thr=$(( 1000*$delay_thr ))

no_reflectors=${#reflectors[@]} 

dl_shaper_rate=$base_dl_shaper_rate
ul_shaper_rate=$base_ul_shaper_rate

last_dl_shaper_rate=$dl_shaper_rate
last_ul_shaper_rate=$ul_shaper_rate

tc qdisc change root dev ${dl_if} cake bandwidth ${dl_shaper_rate}Kbit
tc qdisc change root dev ${ul_if} cake bandwidth ${ul_shaper_rate}Kbit

t_start=${EPOCHREALTIME/./}
t_end=${EPOCHREALTIME/./}
t_prev_ul_rate_set=$t_prev_bytes
t_prev_dl_rate_set=$t_prev_bytes
t_ul_last_bufferbloat=$t_prev_bytes
t_ul_last_decay=$t_prev_bytes
t_dl_last_bufferbloat=$t_prev_bytes
t_dl_last_decay=$t_prev_bytes 

t_sustained_connection_idle=0
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

# Initiate achived rate monitor
monitor_achieved_rates $rx_bytes_path $tx_bytes_path $monitor_achieved_rates_interval&
monitor_achieved_rates_pid=$!

sleep 1

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
		delays[$delays_idx]=$(( $rtt_delta > $delay_thr ? 1 : 0 ))
		((delays[$delays_idx])) && ((sum_delays++))
		(( delays_idx=(delays_idx+1)%$bufferbloat_detection_window ))
	
		# read in the dl/ul achived rates and determines the load
		{
			flock -x 200
			read -r dl_achieved_rate ul_achieved_rate < "/tmp/CAKE-autorate/achieved_rates"
		} 200>/tmp/CAKE-autorate/achieved_rates_lock
		dl_load=$(((100*$dl_achieved_rate)/$dl_shaper_rate))
		ul_load=$(((100*$ul_achieved_rate)/$ul_shaper_rate))
		
		(( $dl_load > $high_load_thr )) && dl_load_condition="high"  || { (( $dl_load > $medium_load_thr )) && dl_load_condition="medium"; } || { (( $dl_achieved_rate > $connection_active_thr )) && dl_load_condition="low"; } || dl_load_condition="idle"
		(( $ul_load > $high_load_thr )) && ul_load_condition="high"  || { (( $ul_load > $medium_load_thr )) && ul_load_condition="medium"; } || { (( $ul_achieved_rate > $connection_active_thr )) && ul_load_condition="low"; } || ul_load_condition="idle"
	
		(($sum_delays>=$bufferbloat_detection_thr)) && dl_load_condition=$dl_load_condition"_delayed" && ul_load_condition=$ul_load_condition"_delayed"

		get_next_shaper_rate $min_dl_shaper_rate $base_dl_shaper_rate $max_dl_shaper_rate $dl_achieved_rate $dl_load_condition $t_start t_dl_last_bufferbloat t_dl_last_decay dl_shaper_rate
		get_next_shaper_rate $min_ul_shaper_rate $base_ul_shaper_rate $max_ul_shaper_rate $ul_achieved_rate $ul_load_condition $t_start t_ul_last_bufferbloat t_ul_last_decay ul_shaper_rate

		(($output_processing_stats)) && printf '%s %-6s %-6s %-3s %-3s %s %-15s %-6s %-6s %-6s %-6s %s %-14s %-14s %-6s %-6s\n' $EPOCHREALTIME $dl_achieved_rate $ul_achieved_rate $dl_load $ul_load $timestamp $reflector $seq $rtt_baseline $rtt $rtt_delta $sum_delays $dl_load_condition $ul_load_condition $dl_shaper_rate $ul_shaper_rate

       		# fire up tc if there are rates to change
		if (( $dl_shaper_rate != $last_dl_shaper_rate)); then
       			(($output_cake_changes)) && echo "tc qdisc change root dev ${dl_if} cake bandwidth ${dl_shaper_rate}Kbit"
       			tc qdisc change root dev ${dl_if} cake bandwidth ${dl_shaper_rate}Kbit
			t_prev_dl_rate_set=${EPOCHREALTIME/./}
		fi
       		if (( $ul_shaper_rate != $last_ul_shaper_rate )); then
         		(($output_cake_changes)) && echo "tc qdisc change root dev ${ul_if} cake bandwidth ${ul_shaper_rate}Kbit"
       			tc qdisc change root dev ${ul_if} cake bandwidth ${ul_shaper_rate}Kbit
			t_prev_ul_rate_set=${EPOCHREALTIME/./}
		fi
		
		# If base rate is sustained, increment sustained base rate timer (and break out of processing loop if enough time passes)
		(($enable_sleep_function)) && if [[ "$dl_load_condition" == "idle"* && "$ul_load_condition" == "idle"* ]]; then
			((t_sustained_connection_idle+=$((${EPOCHREALTIME/./}-$t_end))))
			(($t_sustained_connection_idle>$sustained_idle_sleep_thr)) && break
		else
			# reset timer
			t_sustained_connection_idle=0
		fi

		# remember the last rates
       		last_dl_shaper_rate=$dl_shaper_rate
       		last_ul_shaper_rate=$ul_shaper_rate

		t_end=${EPOCHREALTIME/./}

	done</tmp/CAKE-autorate/ping_fifo

	# we broke out of processing loop, so conservatively set hard minimums and wait until there is a load increase again
	dl_shaper_rate=$min_dl_shaper_rate
        tc qdisc change root dev ${dl_if} cake bandwidth ${dl_shaper_rate}Kbit
	ul_shaper_rate=$min_ul_shaper_rate
        tc qdisc change root dev ${ul_if} cake bandwidth ${ul_shaper_rate}Kbit
	# remember the last rates
	last_ul_shaper_rate=$ul_shaper_rate
	last_dl_shaper_rate=$dl_shaper_rate

	# Pause ping processes
	kill -STOP -- ${ping_pids[@]}

	# reset idle timer
	t_sustained_connection_idle=0

	# wait until load increases again
	while true
	do
		t_start=${EPOCHREALTIME/./}	
		{
			flock -x 200
			read -r dl_achieved_rate ul_achieved_rate < /tmp/CAKE-autorate/achieved_rates
		} 200>/tmp/CAKE-autorate/achieved_rates_lock
		dl_load=$(((100*$dl_achieved_rate)/$dl_shaper_rate))
		ul_load=$(((100*$ul_achieved_rate)/$ul_shaper_rate))
		(($dl_load>$medium_load_thr || $ul_load>$medium_load_thr)) && break 
		t_end=${EPOCHREALTIME/./}
		sleep $(($t_end-$t_start))"e-6"
		sleep_remaining_tick_time $t_start $t_end $reflector_ping_interval_us
	done

	# Continue ping processes
	kill -CONT -- ${ping_pids[@]}
done
