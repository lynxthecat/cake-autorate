#!/bin/bash

# CAKE-autorate automatically adjusts bandwidth for CAKE in dependence on detected load and OWD/RTT
# requires packages: bash; and iputils-ping

# Author: @Lynx (OpenWrt forum)
# Inspiration taken from: @moeller0 (OpenWrt forum)

# Possible performance improvement
export LC_ALL=C
export TZ=UTC

trap cleanup_and_killall INT TERM EXIT

cleanup_and_killall()
{
	echo "Killing all background processes and cleaning up /tmp files."
	trap - INT TERM EXIT
	kill $monitor_achieved_rates_pid 2> /dev/null
	kill $maintain_pingers_pid 2> /dev/null
	[[ -d /tmp/CAKE-autorate ]] && rm -r /tmp/CAKE-autorate
	exit
}

install_dir="/root/CAKE-autorate/"

. $install_dir"config.sh"

# test if stdout is a tty (terminal)
[[ ! -t 1 ]] &&	exec &> /tmp/cake-autorate.log

get_next_shaper_rate() 
{
	local min_shaper_rate_kbps=$1
	local base_shaper_rate_kbps=$2
	local max_shaper_rate_kbps=$3
	local achieved_rate_kbps=$4
	local load_condition=$5
	local t_next_rate_us=$6
	local -n t_last_bufferbloat_us=$7
	local -n t_last_decay_us=$8
    	local -n shaper_rate_kbps=$9

	case $load_condition in

		# bufferbloat detected, so decrease the rate providing not inside bufferbloat refractory period
		*delayed)
			if (( $t_next_rate_us > ($t_last_bufferbloat_us+$bufferbloat_refractory_period_us) )); then
				adjusted_achieved_rate_kbps=$(( ($achieved_rate_kbps*$achieved_rate_adjust_bufferbloat)/1000 )) 
				adjusted_shaper_rate_kbps=$(( ($shaper_rate_kbps*$shaper_rate_adjust_bufferbloat)/1000 )) 
				shaper_rate_kbps=$(( $adjusted_achieved_rate_kbps < $adjusted_shaper_rate_kbps ? $adjusted_achieved_rate_kbps : $adjusted_shaper_rate_kbps ))
				t_last_bufferbloat_us=${EPOCHREALTIME/./}
			fi
			;;
		
            	# high load, so increase rate providing not inside bufferbloat refractory period 
		high)	
			if (( $t_next_rate_us > ($t_last_bufferbloat_us+$bufferbloat_refractory_period_us) )); then
				shaper_rate_kbps=$(( ($shaper_rate_kbps*$shaper_rate_adjust_load_high)/1000 ))
			fi
			;;
		# medium load, so just maintain rate as is, i.e. do nothing
		medium)
			:
			;;
		# low or idle load, so determine whether to decay down towards base rate, decay up towards base rate, or set as base rate
		low|idle)
			if (($t_next_rate_us > ($t_last_decay_us+$decay_refractory_period_us) )); then

	                	if (($shaper_rate_kbps > $base_shaper_rate_kbps)); then
					decayed_shaper_rate_kbps=$(( ($shaper_rate_kbps*$shaper_rate_adjust_load_low)/1000 ))
					shaper_rate_kbps=$(( $decayed_shaper_rate_kbps > $base_shaper_rate_kbps ? $decayed_shaper_rate_kbps : $base_shaper_rate_kbps))
				elif (($shaper_rate_kbps < $base_shaper_rate_kbps)); then
        			        decayed_shaper_rate_kbps=$(( ((2000-$shaper_rate_adjust_load_low)*$shaper_rate_kbps)/1000 ))
					shaper_rate_kbps=$(( $decayed_shaper_rate_kbps < $base_shaper_rate_kbps ? $decayed_shaper_rate_kbps : $base_shaper_rate_kbps))
                		fi

				t_last_decay_us=${EPOCHREALTIME/./}
			fi
			;;
	esac
        # make sure to only return rates between cur_min_rate and cur_max_rate
        (($shaper_rate_kbps < $min_shaper_rate_kbps)) && shaper_rate_kbps=$min_shaper_rate_kbps;
        (($shaper_rate_kbps > $max_shaper_rate_kbps)) && shaper_rate_kbps=$max_shaper_rate_kbps;
}

monitor_achieved_rates()
{
	# track rx and tx bytes transfered and divide by time since last update
	# to determine achieved dl and ul transfer rates

	local rx_bytes_path=$1
	local tx_bytes_path=$2
	local monitor_achieved_rates_interval_us=$3 # (microseconds)

	compensated_monitor_achieved_rates_interval_us=$monitor_achieved_rates_interval_us

	[[ -f $rx_bytes_path ]] && { read -r prev_rx_bytes < $rx_bytes_path; } 2> /dev/null || prev_rx_bytes=0
        [[ -f $tx_bytes_path ]] && { read -r prev_tx_bytes < $tx_bytes_path; } 2> /dev/null || prev_tx_bytes=0

	while true
	do
        	t_start_us=${EPOCHREALTIME/./}

		# If rx/tx bytes file exists, read it in, otherwise set to prev_bytes
		# This addresses interfaces going down and back up
       		[[ -f $rx_bytes_path ]] && { read -r rx_bytes < $rx_bytes_path; } 2> /dev/null || rx_bytes=$prev_rx_bytes
       		[[ -f $tx_bytes_path ]] && { read -r tx_bytes < $tx_bytes_path; } 2> /dev/null || tx_bytes=$prev_tx_bytes

        	dl_achieved_rate_kbps=$(( ((8000*($rx_bytes - $prev_rx_bytes)) / $compensated_monitor_achieved_rates_interval_us ) ))
       		ul_achieved_rate_kbps=$(( ((8000*($tx_bytes - $prev_tx_bytes)) / $compensated_monitor_achieved_rates_interval_us ) ))
		
		(($dl_achieved_rate_kbps<0)) && dl_achieved_rate_kbps=0
		(($ul_achieved_rate_kbps<0)) && ul_achieved_rate_kbps=0
	
		printf '%s' "$dl_achieved_rate_kbps" > /tmp/CAKE-autorate/dl_achieved_rate_kbps
		printf '%s' "$ul_achieved_rate_kbps" > /tmp/CAKE-autorate/ul_achieved_rate_kbps

       		prev_rx_bytes=$rx_bytes
       		prev_tx_bytes=$tx_bytes

		# read in the max_wire_packet_rtt_us
		concurrent_read max_wire_packet_rtt_us /tmp/CAKE-autorate/max_wire_packet_rtt_us

		compensated_monitor_achieved_rates_interval_us=$(( (($monitor_achieved_rates_interval_us>(10*$max_wire_packet_rtt_us) )) ? $monitor_achieved_rates_interval_us : $((10*$max_wire_packet_rtt_us)) ))

		sleep_remaining_tick_time $t_start_us $compensated_monitor_achieved_rates_interval_us		
	done
}

get_loads()
{
	# read in the dl/ul achived rates and determine the loads

	concurrent_read dl_achieved_rate_kbps /tmp/CAKE-autorate/dl_achieved_rate_kbps 
	concurrent_read ul_achieved_rate_kbps /tmp/CAKE-autorate/ul_achieved_rate_kbps 

	dl_load_percent=$(((100*10#${dl_achieved_rate_kbps})/$dl_shaper_rate_kbps))
	ul_load_percent=$(((100*10#${ul_achieved_rate_kbps})/$ul_shaper_rate_kbps))
}

classify_load()
{
	# classify the load according to high/low/medium/idle and add _delayed if delayed
	# thus ending up with high_delayed, low_delayed, etc.
	local load_percent=$1
	local achieved_rate_kbps=$2
	local -n load_condition=$3
	
	if (( $load_percent > $high_load_thr_percent )); then
		load_condition="high"  
	elif (( $load_percent > $medium_load_thr_percent )); then
		load_condition="medium"
	elif (( $achieved_rate_kbps > $connection_active_thr_kbps )); then
		load_condition="low"
	else 
		load_condition="idle"
	fi
	
	(($bufferbloat_detected)) && load_condition=$load_condition"_delayed"
}

monitor_reflector_responses() 
{
	# ping reflector, maintain baseline and output deltas to a common fifo

	local pinger=$1
	local rtt_baseline_us=$2

	while read -r  timestamp _ _ _ reflector seq_rtt
	do
		# If no match then skip onto the next one
		[[ $seq_rtt =~ icmp_[s|r]eq=([0-9]+).*time=([0-9]+)\.?([0-9]+)?[[:space:]]ms ]] || continue

		seq=${BASH_REMATCH[1]}

		rtt_us=${BASH_REMATCH[3]}000
		rtt_us=$((${BASH_REMATCH[2]}000+10#${rtt_us:0:3}))

		reflector=${reflector//:/}

		rtt_delta_us=$(( $rtt_us-$rtt_baseline_us ))

		alpha=$(( (( $rtt_delta_us >=0 )) ? $alpha_baseline_increase : $alpha_baseline_decrease ))

		rtt_baseline_us=$(( ( (1000-$alpha)*$rtt_baseline_us+$alpha*$rtt_us )/1000 ))

		printf '%s %s %s %s %s %s\n' "$timestamp" "$reflector" "$seq" "$rtt_baseline_us" "$rtt_us" "$rtt_delta_us" > /tmp/CAKE-autorate/ping_fifo
	
		printf '%s' "${timestamp//[[\[\].]}" > /tmp/CAKE-autorate/reflector_${pinger}_last_timestamp_us

	done</tmp/CAKE-autorate/pinger_${pinger}_fifo
}

kill_pingers()
{
	for (( pinger=0; pinger<$no_pingers; pinger++))
	do
		kill ${pinger_pids[$pinger]} 2> /dev/null
		[[ -p /tmp/CAKE-autorate/pinger_${pinger}_fifo ]] && rm /tmp/CAKE-autorate/pinger_${pinger}_fifo
	done
	exit
}

maintain_pingers()
{
	# this initiates the pingers and monitors reflector health, rotating reflectors as necessary

 	trap kill_pingers TERM

	declare -A pinger_pids
	declare -A rtt_baselines_us

	reflector_offences_idx=0

	# For each pinger: create fifos, get baselines and initialize record of offences
	for ((pinger=0; pinger<$no_pingers; pinger++))
	do
		mkfifo /tmp/CAKE-autorate/pinger_${pinger}_fifo
		[[ $(ping -q -c 5 -i 0.1 ${reflectors[$pinger]} | tail -1) =~ ([0-9.]+)/ ]] && printf -v rtt_baselines_us[$pinger] %.0f\\n "${BASH_REMATCH[1]}e3" || rtt_baselines_us[$pinger]=0
	
		declare -n reflector_offences="reflector_${pinger}_offences"
		for ((i=0; i<$reflector_misbehaving_detection_window; i++)) do reflector_offences[i]=0; done

		sum_reflector_offences[$pinger]=0
	done

	pingers_t_start_us=${EPOCHREALTIME/./}

	# Initiate pingers
	for ((pinger=0; pinger<$no_pingers; pinger++))
	do
		printf '%s' "$pingers_t_start_us" > /tmp/CAKE-autorate/reflector_${pinger}_last_timestamp_us
		start_pinger_next_pinger_time_slot $pinger pid
		pinger_pids[$pinger]=$pid
	done

	# Reflector health check loop - verifies reflectors have not gone stale and rotates reflectors as necessary
	while true
	do
		sleep_s $reflector_health_check_interval_s

		for ((pinger=0; pinger<$no_pingers; pinger++))
		do
			reflector_check_time_us=${EPOCHREALTIME/./}
			concurrent_read reflector_last_timestamp_us /tmp/CAKE-autorate/reflector_${pinger}_last_timestamp_us
			declare -n reflector_offences="reflector_${pinger}_offences"

			(( ${reflector_offences[$reflector_offences_idx]} )) && ((sum_reflector_offences[$pinger]--))
			reflector_offences[$reflector_offences_idx]=$(( (((${EPOCHREALTIME/./}-$reflector_last_timestamp_us) > $reflector_response_deadline_us)) ? 1 : 0 ))
			((reflector_offences[$reflector_offences_idx])) && ((sum_reflector_offences[$pinger]++))

			if ((sum_reflector_offences[$pinger]>=$reflector_misbehaving_detection_thr)); then

				(($debug)) && echo "DEBUG: Warning: reflector: "${reflectors[$pinger]}" seems to be misbehaving."
				
				if(($no_reflectors>$no_pingers)); then

					# pingers always use reflectors[0]..[$no_pingers-1] as the initial set
					# and the additional reflectors are spare reflectors should any from initial set go stale
					# a bad reflector in the initial set is replaced with $reflectors[$no_pingers]
					# $reflectors[$no_pingers] is then unset
					# and the the bad reflector moved to the back of the queue (last element in $reflectors[])
					# and finally the indices for $reflectors are updated to reflect the new order
	
					(($debug)) && echo "DEBUG: Replacing reflector: "${reflectors[$pinger]}" with "${reflectors[$no_pingers]}"."
					kill ${pinger_pids[$pinger]} 2> /dev/null
					bad_reflector=${reflectors[$pinger]}
					# overwrite the bad reflector with the reflector that is next in the queue (the one after 0..$no_pingers-1)
					reflectors[$pinger]=${reflectors[$no_pingers]}
					# remove the new reflector from the list of additional reflectors beginning from $reflectors[$no_pingers]
					unset reflectors[$no_pingers]
					# bad reflector goes to the back of the queue
					reflectors+=($bad_reflector)
					# reset array indices
					reflectors=(${reflectors[*]})
					# set up the new pinger with the new reflector and retain pid
					start_pinger_next_pinger_time_slot $pinger pid
					pinger_pids[$pinger]=$pid
					
				else
					(($debug)) && echo "DEBUG: No additional reflectors specified so just retaining: "${reflectors[$pinger]}"."
					reflector_offences[$pinger]=0
				fi

				for ((i=0; i<$reflector_misbehaving_detection_window; i++)) do reflector_offences[i]=0; done
				sum_reflector_offences[$pinger]=0
			fi		
		done
		((reflector_offences_idx=(reflector_offences_idx+1)%$reflector_misbehaving_detection_window))
	done
}

start_pinger_next_pinger_time_slot()
{
	# wait until next pinger time slot and start pinger in its slot
	# this allows pingers to be stopped and started (e.g. during sleep or reflector rotation)
	# whilst ensuring pings will remain spaced out appropriately to maintain granularity

	local pinger=$1
	local -n pinger_pid=$2
	t_start_us=${EPOCHREALTIME/./}
	time_to_next_time_slot_us=$(( ($reflector_ping_interval_us-($t_start_us-$pingers_t_start_us)%$reflector_ping_interval_us) + $pinger*$ping_response_interval_us ))
	sleep_remaining_tick_time $t_start_us $time_to_next_time_slot_us
	if (($debug)); then
		ping -D -i $reflector_ping_interval_s ${reflectors[$pinger]} > /tmp/CAKE-autorate/pinger_${pinger}_fifo &
		pinger_pid=$!
	else
		ping -D -i $reflector_ping_interval_s ${reflectors[$pinger]} > /tmp/CAKE-autorate/pinger_${pinger}_fifo 2> /dev/null &
		pinger_pid=$!
	fi
	monitor_reflector_responses $pinger ${rtt_baselines_us[$pinger]} &
}

set_cake_rate()
{
	local interface=$1
	local shaper_rate_kbps=$2
	local -n time_rate_set_us=$3
	
	(($output_cake_changes)) && echo "tc qdisc change root dev ${interface} cake bandwidth ${shaper_rate_kbps}Kbit"
	
	if (($debug)); then
		tc qdisc change root dev $interface cake bandwidth ${shaper_rate_kbps}Kbit
	else
		tc qdisc change root dev $interface cake bandwidth ${shaper_rate_kbps}Kbit 2> /dev/null
	fi

	time_rate_set_us=${EPOCHREALTIME/./}
}

set_shaper_rates()
{
	if (( $dl_shaper_rate_kbps != $last_dl_shaper_rate_kbps || $ul_shaper_rate_kbps != $last_ul_shaper_rate_kbps )); then 
     	
		# fire up tc in each direction if there are rates to change, and if rates change in either direction then update max wire calcs
		(( $dl_shaper_rate_kbps != $last_dl_shaper_rate_kbps )) && { set_cake_rate $dl_if $dl_shaper_rate_kbps t_prev_dl_rate_set_us; last_dl_shaper_rate_kbps=$dl_shaper_rate_kbps; } 
		(( $ul_shaper_rate_kbps != $last_ul_shaper_rate_kbps )) && { set_cake_rate $ul_if $ul_shaper_rate_kbps t_prev_ul_rate_set_us; last_ul_shaper_rate_kbps=$ul_shaper_rate_kbps; } 

		update_max_wire_packet_compensation
	fi
}

get_max_wire_packet_size_bits()
{
	local interface=$1
	local -n max_wire_packet_size_bits=$2
 
	read -r max_wire_packet_size_bits < "/sys/class/net/${interface}/mtu" 
	[[ $(tc qdisc show dev $interface) =~ (atm|noatm)[[:space:]]overhead[[:space:]]([0-9]+) ]]
	[[ ! -z "${BASH_REMATCH[2]}" ]] && max_wire_packet_size_bits=$((8*($max_wire_packet_size_bits+${BASH_REMATCH[2]}))) 
	# atm compensation = 53*ceil(X/48) bytes = 8*53*((X+8*(48-1)/(8*48)) bits = 424*((X+376)/384) bits
	[[ "${BASH_REMATCH[1]}" == "atm" ]] && max_wire_packet_size_bits=$(( 424*(($max_wire_packet_size_bits+376)/384) ))
}

update_max_wire_packet_compensation()
{
	# Compensate for delays imposed by active traffic shaper
	# This will serve to increase the delay thr at rates below around 12Mbit/s

	max_wire_packet_rtt_us=$(( (1000*$dl_max_wire_packet_size_bits)/$dl_shaper_rate_kbps + (1000*$ul_max_wire_packet_size_bits)/$ul_shaper_rate_kbps  ))
	compensated_delay_thr_us=$(( $delay_thr_us + $max_wire_packet_rtt_us ))

	# write out max_wire_packet_rtt_us
	printf '%s' "$max_wire_packet_rtt_us" > /tmp/CAKE-autorate/max_wire_packet_rtt_us
}

concurrent_read()
{
	# in the context of separate processes writing using > and reading form file
        # it seems costly calls to the external flock binary can be avoided
	# read either succeeds as expected or occassionally reads in bank value
	# so just test for blank value and re-read until not blank

	local -n value=$1
 	local path=$2
	read -r value < $path
	while [[ -z $value ]]; do
		sleep_us $concurrent_read_interval_us
		read -r value < $path; 
	done
}

verify_ifs_up()
{
	# Check the rx/tx paths exist and give extra time for ifb's to come up if needed
	# This will block if ifs never come up

	while [[ ! -f $rx_bytes_path || ! -f $tx_bytes_path ]]
	do
		(($debug)) && [[ ! -f $rx_bytes_path ]] && echo "DEBUG Warning: $rx_bytes_path does not exist. Waiting "$if_up_check_interval_s" seconds for interface to come up." 
		(($debug)) && [[ ! -f $tx_bytes_path ]] && echo "DEBUG Warning: $tx_bytes_path does not exist. Waiting "$if_up_check_interval_s" seconds for interface to come up." 
		sleep_s $if_up_check_interval_s
	done
}

sleep_s()
{
	# calling external sleep binary is slow
	# bash does have a loadable sleep 
	# but read's timeout can more portably be exploited and this is apparently even faster anyway

	local sleep_duration_s=$1 # (seconds, e.g. 0.5, 1 or 1.5)

	read -t $sleep_duration_s < /tmp/CAKE-autorate/sleep_fifo
}

sleep_us()
{
	# calling external sleep binary is slow
	# bash does have a loadable sleep 
	# but read's timeout can more portably be exploited and this is apparently even fastera anyway

	local sleep_duration_us=$1 # (microseconds)
	
	sleep_duration_s=000000$sleep_duration_us
	sleep_duration_s=${sleep_duration_s::-6}.${sleep_duration_s: -6}
	read -t $sleep_duration_s < /tmp/CAKE-autorate/sleep_fifo
}

sleep_remaining_tick_time()
{
	# sleeps until the end of the tick duration

	local t_start_us=$1 # (microseconds)
	local tick_duration_us=$2 # (microseconds)

	sleep_duration_us=$(( $t_start_us + $tick_duration_us - ${EPOCHREALTIME/./} ))
	
        if (( $sleep_duration_us > 0 )); then
		sleep_us $sleep_duration_us
	fi
}

# Set up tmp directory, sleep fifo and perform various sanity checks

# /tmp/CAKE-autorate/ is used to store temporary files
# it should not exist on startup so if it does exit, else create the directory
if [[ -d /tmp/CAKE-autorate ]]; then 
	echo "Error: /tmp/CAKE-autorate already exists. Is another instance running? Exiting script."
	trap - INT TERM EXIT
	exit
else 
	mkdir /tmp/CAKE-autorate
fi

mkfifo /tmp/CAKE-autorate/sleep_fifo
exec 3<> /tmp/CAKE-autorate/sleep_fifo

no_reflectors=${#reflectors[@]} 

# Check no_pingers <= no_reflectors
(( $no_pingers > $no_reflectors)) && { echo "Error: number of pingers cannot be greater than number of reflectors. Exiting script."; exit; }

# Check dl/if interface not the same
[[ $dl_if == $ul_if ]] && { echo "Error: download interface and upload interface are both set to: '"$dl_if"', but cannot be the same. Exiting script."; exit; }

# Check bufferbloat detection threshold not greater than window length
(( $bufferbloat_detection_thr > $bufferbloat_detection_window )) && { echo "Error: bufferbloat_detection_thr cannot be greater than bufferbloat_detection_window. Exiting script."; exit; }

# Wait if $startup_wait_s > 0
if (($startup_wait_s>0)); then
	(($debug)) && echo "DEBUG Waiting "$startup_wait_s" seconds before startup."
	sleep_s $startup_wait_s
fi

verify_ifs_up

# Initialize variables

# Convert human readable parameters to values that work with integer arithmetic
printf -v alpha_baseline_increase %.0f\\n "${alpha_baseline_increase}e3"
printf -v alpha_baseline_decrease %.0f\\n "${alpha_baseline_decrease}e3"   
printf -v achieved_rate_adjust_bufferbloat %.0f\\n "${achieved_rate_adjust_bufferbloat}e3"
printf -v shaper_rate_adjust_bufferbloat %.0f\\n "${shaper_rate_adjust_bufferbloat}e3"
printf -v shaper_rate_adjust_load_high %.0f\\n "${shaper_rate_adjust_load_high}e3"
printf -v shaper_rate_adjust_load_low %.0f\\n "${shaper_rate_adjust_load_low}e3"
printf -v high_load_thr_percent %.0f\\n "${high_load_thr}e2"
printf -v medium_load_thr_percent %.0f\\n "${medium_load_thr}e2"
printf -v reflector_ping_interval_us %.0f\\n "${reflector_ping_interval_s}e6"
printf -v monitor_achieved_rates_interval_us %.0f\\n "${monitor_achieved_rates_interval_ms}e3"
printf -v sustained_idle_sleep_thr_us %.0f\\n "${sustained_idle_sleep_thr_s}e6"
printf -v reflector_response_deadline_us %.0f\\n "${reflector_response_deadline_s}e6"
bufferbloat_refractory_period_us=$(( 1000*$bufferbloat_refractory_period_ms ))
decay_refractory_period_us=$(( 1000*$decay_refractory_period_ms ))
delay_thr_us=$(( 1000*$delay_thr_ms ))

ping_response_interval_us=$(($reflector_ping_interval_us/$no_pingers))

concurrent_read_interval_us=$(($ping_response_interval_us/4))

dl_shaper_rate_kbps=$base_dl_shaper_rate_kbps
ul_shaper_rate_kbps=$base_ul_shaper_rate_kbps

last_dl_shaper_rate_kbps=$dl_shaper_rate_kbps
last_ul_shaper_rate_kbps=$ul_shaper_rate_kbps

get_max_wire_packet_size_bits $dl_if dl_max_wire_packet_size_bits  
get_max_wire_packet_size_bits $ul_if ul_max_wire_packet_size_bits

set_cake_rate $dl_if $dl_shaper_rate_kbps t_prev_dl_rate_set_us
set_cake_rate $ul_if $ul_shaper_rate_kbps t_prev_ul_rate_set_us

update_max_wire_packet_compensation

t_start_us=${EPOCHREALTIME/./}
t_end_us=${EPOCHREALTIME/./}
t_prev_ul_rate_set_us=$t_start_us
t_prev_dl_rate_set_us=$t_start_us
t_ul_last_bufferbloat_us=$t_start_us
t_ul_last_decay_us=$t_start_us
t_dl_last_bufferbloat_us=$t_start_us
t_dl_last_decay_us=$t_start_us

t_sustained_connection_idle_us=0

declare -a delays=( $(for i in {1..$bufferbloat_detection_window}; do echo 0; done) )
delays_idx=0
sum_delays=0

mkfifo /tmp/CAKE-autorate/ping_fifo
exec 4<> /tmp/CAKE-autorate/ping_fifo

maintain_pingers &
maintain_pingers_pid=$!

# Initiate achived rate monitor
monitor_achieved_rates $rx_bytes_path $tx_bytes_path $monitor_achieved_rates_interval_us&
monitor_achieved_rates_pid=$!

prev_timestamp=0

while true
do
	while read -t $global_ping_response_timeout_s -r timestamp reflector seq rtt_baseline_us rtt_us rtt_delta_us
	do 
		t_start_us=${EPOCHREALTIME/./}
		if ((($t_start_us - "${timestamp//[[\[\].]}")>500000)); then
			(($debug)) && echo "DEBUG processed response from [" $reflector "] that is > 500ms old. Skipping." 
			continue
		fi
		
		# Keep track of number of delays across detection window
		(( ${delays[$delays_idx]} )) && ((sum_delays--))
		delays[$delays_idx]=$(( $rtt_delta_us > $compensated_delay_thr_us ? 1 : 0 ))
		((delays[$delays_idx])) && ((sum_delays++))
		(( delays_idx=(delays_idx+1)%$bufferbloat_detection_window ))

		bufferbloat_detected=$(( (($sum_delays>=$bufferbloat_detection_thr)) ? 1 : 0 ))

		get_loads

		classify_load $dl_load_percent $dl_achieved_rate_kbps dl_load_condition
		classify_load $ul_load_percent $ul_achieved_rate_kbps ul_load_condition
	
		get_next_shaper_rate $min_dl_shaper_rate_kbps $base_dl_shaper_rate_kbps $max_dl_shaper_rate_kbps $dl_achieved_rate_kbps $dl_load_condition $t_start_us t_dl_last_bufferbloat_us t_dl_last_decay_us dl_shaper_rate_kbps
		get_next_shaper_rate $min_ul_shaper_rate_kbps $base_ul_shaper_rate_kbps $max_ul_shaper_rate_kbps $ul_achieved_rate_kbps $ul_load_condition $t_start_us t_ul_last_bufferbloat_us t_ul_last_decay_us ul_shaper_rate_kbps

		(($output_processing_stats)) && printf '%s %-6s %-6s %-3s %-3s %s %-15s %-6s %-6s %-6s %-6s %-6s %s %-14s %-14s %-6s %-6s\n' $EPOCHREALTIME $dl_achieved_rate_kbps $ul_achieved_rate_kbps $dl_load_percent $ul_load_percent $timestamp $reflector $seq $rtt_baseline_us $rtt_us $rtt_delta_us $compensated_delay_thr_us $sum_delays $dl_load_condition $ul_load_condition $dl_shaper_rate_kbps $ul_shaper_rate_kbps

		set_shaper_rates

		# If base rate is sustained, increment sustained base rate timer (and break out of processing loop if enough time passes)
		if (($enable_sleep_function)); then
			if [[ $dl_load_condition == idle* && $ul_load_condition == idle* ]]; then
				((t_sustained_connection_idle_us+=$((${EPOCHREALTIME/./}-$t_end_us))))
				(($t_sustained_connection_idle_us>$sustained_idle_sleep_thr_us)) && break
			else
				# reset timer
				t_sustained_connection_idle_us=0
			fi
		fi
		t_end_us=${EPOCHREALTIME/./}

	done</tmp/CAKE-autorate/ping_fifo

	(($debug)) && {(( ${PIPESTATUS[0]} == 142 )) && echo "DEBUG Warning: global ping response timeout. Enforcing minimum shaper rates." || echo "DEBUG Connection idle. Enforcing minimum shaper rates.";}
	
	# in any case, we broke out of processing loop, so conservatively set hard minimums and wait until there is a load increase again
	dl_shaper_rate_kbps=$min_dl_shaper_rate_kbps
	ul_shaper_rate_kbps=$min_ul_shaper_rate_kbps
	set_shaper_rates

	# Kill off ping processes
	kill $maintain_pingers_pid 2> /dev/null

	# reset idle timer
	t_sustained_connection_idle_us=0

	# verify interfaces are up (e.g. following ping response timeout from interfaces going down)
	verify_ifs_up

	# wait until load increases again
	while true
	do
		t_start_us=${EPOCHREALTIME/./}	
		get_loads
		(($dl_load_percent>$medium_load_thr_percent || $ul_load_percent>$medium_load_thr_percent)) && break 
		sleep_remaining_tick_time $t_start_us $reflector_ping_interval_us
	done

	# Start up ping processes
	maintain_pingers &
	maintain_pingers_pid=$!
done
