#!/bin/bash

# CAKE-autorate automatically adjusts bandwidth for CAKE in dependence on detected load and OWD/RTT
# requires packages: bash; and iputils-ping

# cake-autorate must be configured using config file in $install_dir

# Project homepage: https://github.com/lynxthecat/cake-autorate
# Licence details:  https://github.com/lynxthecat/cake-autorate/blob/main/LICENCE.md

# Author: @Lynx (OpenWrt forum)
# Inspiration taken from: @moeller0 (OpenWrt forum)

install_dir="/root/cake-autorate/"

# Possible performance improvement
export LC_ALL=C

trap cleanup_and_killall INT TERM EXIT

cleanup_and_killall()
{
	trap - INT TERM EXIT

	log_msg "INFO" ""
	log_msg "INFO" "Killing all background processes and cleaning up /tmp files."

	[[ ! -t 1 ]] && kill $maintain_log_file_pid 2> /dev/null
	kill $monitor_achieved_rates_pid 2> /dev/null
	wait $monitor_achieved_rates_pid
	# Initiate termination of ping processes and wait until complete
	kill -CONT $maintain_pingers_pid 2> /dev/null
	kill $maintain_pingers_pid 2> /dev/null
	wait $maintain_pingers_pid
	[[ -d /tmp/cake-autorate ]] && rm -r /tmp/cake-autorate
	exit
}

# Format log entries
log_msg()
{
	local type=$1
	local msg=$2

	echo $msg > /tmp/try3

	if [[ ! -t 1 ]]; then
	        printf '%s; %(%F-%H:%M:%S)T; %s; %s\n' "$type" -1 "$EPOCHREALTIME" "$msg" > /tmp/cake-autorate/log_fifo
	else
	        printf '%s; %(%F-%H:%M:%S)T; %s; %s\n' "$type" -1 "$EPOCHREALTIME" "$msg"
	fi
}

print_header()
{
	if [[ ! -t 1 ]]; then
		printf '%s\n' "HEADER; LOG_DATETIME; LOG_TIMESTAMP; PROC_TIME_US; DL_ACHIEVED_RATE_KBPS; UL_ACHIEVED_RATE_KBPS; DL_LOAD_PERCENT; UL_LOAD_PERCENT; RTT_TIMESTAMP; REFLECTOR; SEQUENCE; RTT_BASELINE; RTT_US; RTT_DELTA_US; ADJ_DELAY_THR; SUM_DELAYS; DL_LOAD_CONDITION; UL_LOAD_CONDITION; CAKE_DL_RATE_KBPS; CAKE_UL_RATE_KBPS" > /tmp/cake-autorate/log_fifo
	else
		printf '%s\n' "HEADER; LOG_DATETIME; LOG_TIMESTAMP; PROC_TIME_US; DL_ACHIEVED_RATE_KBPS; UL_ACHIEVED_RATE_KBPS; DL_LOAD_PERCENT; UL_LOAD_PERCENT; RTT_TIMESTAMP; REFLECTOR; SEQUENCE; RTT_BASELINE; RTT_US; RTT_DELTA_US; ADJ_DELAY_THR; SUM_DELAYS; DL_LOAD_CONDITION; UL_LOAD_CONDITION; CAKE_DL_RATE_KBPS; CAKE_UL_RATE_KBPS"
	fi
}

rotate_log_file()
{
	mv /tmp/cake-autorate.log /tmp/cake-autorate.log.old
	(($output_processing_stats)) && print_header
}

kill_maintain_log_file()
{
	while read -t 0.1 log_line
	do
		printf '%s\n' "$log_line" >> /tmp/cake-autorate.log		
	done
	exit
}

maintain_log_file()
{
	trap "kill_maintian_log_file" TERM

	t_log_file_start_us=${EPOCHREALTIME/./}

	while read log_line
	do

		printf '%s\n' "$log_line" >> /tmp/cake-autorate.log		

		# Verify log file size < configured maximum
		read log_file_size_KB< <(du -bk /tmp/cake-autorate.log)
		log_file_size_KB=${log_file_size_KB//[!0-9]/}

		if (( $log_file_size_KB > $log_file_max_size_KB )); then
			(($debug)) && echo "DEBUG; log file size: $log_file_size_KB KB has exceeded configured maximum: $log_file_max_size_KB KB so rotating log file" > /tmp/cake-autorate.log
			rotate_log_file
		fi
		if (( (${EPOCHREALTIME/./}-$t_log_file_start_us) > $log_file_max_time_us )); then

			(($debug)) && echo "DEBUG; log file maximum time: $log_file_max_time_mins minutes has elapsed so rotating log file" > /tmp/cake-autorate.log
			rotate_log_file
			t_log_file_start_us=${EPOCHREALTIME/./}
		fi

	done</tmp/cake-autorate/log_fifo
}

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

		# upload Starlink satelite switching compensation, so drop down to minimum rate for upload through switching period
		ul*sss)
				shaper_rate_kbps=$min_shaper_rate_kbps
			;;
		# download Starlink satelite switching compensation, so drop down to base rate for download through switching period
		dl*sss)
				shaper_rate_kbps=$(( $shaper_rate_kbps > $base_shaper_rate_kbps ? $base_shaper_rate_kbps : $shaper_rate_kbps))
			;;
		# bufferbloat detected, so decrease the rate providing not inside bufferbloat refractory period
		*bb*)
			if (( $t_next_rate_us > ($t_last_bufferbloat_us+$bufferbloat_refractory_period_us) )); then
				adjusted_achieved_rate_kbps=$(( ($achieved_rate_kbps*$achieved_rate_adjust_down_bufferbloat)/1000 )) 
				adjusted_shaper_rate_kbps=$(( ($shaper_rate_kbps*$shaper_rate_adjust_down_bufferbloat)/1000 )) 
				shaper_rate_kbps=$(( $adjusted_achieved_rate_kbps > $min_shaper_rate_kbps && $adjusted_achieved_rate_kbps < $adjusted_shaper_rate_kbps ? $adjusted_achieved_rate_kbps : $adjusted_shaper_rate_kbps ))
				t_last_bufferbloat_us=${EPOCHREALTIME/./}
			fi
			;;
            	# high load, so increase rate providing not inside bufferbloat refractory period 
		*high*)	
			if (( $t_next_rate_us > ($t_last_bufferbloat_us+$bufferbloat_refractory_period_us) )); then
				shaper_rate_kbps=$(( ($shaper_rate_kbps*$shaper_rate_adjust_up_load_high)/1000 ))
			fi
			;;
		# medium load, so just maintain rate as is, i.e. do nothing
		*med*)
			:
			;;
		# low or idle load, so determine whether to decay down towards base rate, decay up towards base rate, or set as base rate
		*low*|*idle*)
			if (($t_next_rate_us > ($t_last_decay_us+$decay_refractory_period_us) )); then

	                	if (($shaper_rate_kbps > $base_shaper_rate_kbps)); then
					decayed_shaper_rate_kbps=$(( ($shaper_rate_kbps*$shaper_rate_adjust_down_load_low)/1000 ))
					shaper_rate_kbps=$(( $decayed_shaper_rate_kbps > $base_shaper_rate_kbps ? $decayed_shaper_rate_kbps : $base_shaper_rate_kbps))
				elif (($shaper_rate_kbps < $base_shaper_rate_kbps)); then
        			        decayed_shaper_rate_kbps=$(( ($shaper_rate_kbps*$shaper_rate_adjust_up_load_low)/1000 ))
					shaper_rate_kbps=$(( $decayed_shaper_rate_kbps < $base_shaper_rate_kbps ? $decayed_shaper_rate_kbps : $base_shaper_rate_kbps))
                		fi

				t_last_decay_us=${EPOCHREALTIME/./}
			fi
			;;
	esac
        # make sure to only return rates between cur_min_rate and cur_max_rate
        (($shaper_rate_kbps < $min_shaper_rate_kbps)) && shaper_rate_kbps=$min_shaper_rate_kbps
        (($shaper_rate_kbps > $max_shaper_rate_kbps)) && shaper_rate_kbps=$max_shaper_rate_kbps
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
	
		printf '%s' "$dl_achieved_rate_kbps" > /tmp/cake-autorate/dl_achieved_rate_kbps
		printf '%s' "$ul_achieved_rate_kbps" > /tmp/cake-autorate/ul_achieved_rate_kbps

		prev_rx_bytes=$rx_bytes
       		prev_tx_bytes=$tx_bytes

		# read in the max_wire_packet_rtt_us
		concurrent_read_positive_integer max_wire_packet_rtt_us /tmp/cake-autorate/max_wire_packet_rtt_us

		compensated_monitor_achieved_rates_interval_us=$(( (($monitor_achieved_rates_interval_us>(10*$max_wire_packet_rtt_us) )) ? $monitor_achieved_rates_interval_us : $((10*$max_wire_packet_rtt_us)) ))

		sleep_remaining_tick_time $t_start_us $compensated_monitor_achieved_rates_interval_us		
	done
}

get_loads()
{
	# read in the dl/ul achived rates and determine the loads

	concurrent_read_positive_integer dl_achieved_rate_kbps /tmp/cake-autorate/dl_achieved_rate_kbps 
	concurrent_read_positive_integer ul_achieved_rate_kbps /tmp/cake-autorate/ul_achieved_rate_kbps 

	dl_load_percent=$(((100*10#${dl_achieved_rate_kbps})/$dl_shaper_rate_kbps))
	ul_load_percent=$(((100*10#${ul_achieved_rate_kbps})/$ul_shaper_rate_kbps))
}

classify_load()
{
	# classify the load according to high/low/medium/idle and add _delayed if delayed
	# thus ending up with high_delayed, low_delayed, etc.
	local load_percent=$1
	local achieved_rate_kbps=$2
	local bufferbloat_detected=$3
	local -n load_condition=$4
	
	if (( $load_percent > $high_load_thr_percent )); then
		load_condition="high"  
	elif (( $load_percent > $medium_load_thr_percent )); then
		load_condition="med"
	elif (( 10#${achieved_rate_kbps} > $connection_active_thr_kbps )); then
		load_condition="low"
	else 
		load_condition="idle"
	fi
	
	(($bufferbloat_detected)) && load_condition=$load_condition"_bb"
		
	if ((sss_compensation)); then
		for sss_time_us in "${sss_times_us[@]}"
		do
			((timestamp_usecs_past_minute=${EPOCHREALTIME/./}%60000000))
			if (( ($timestamp_usecs_past_minute > ($sss_time_us-$sss_compensation_pre_duration_us)) && ($timestamp_usecs_past_minute < ($sss_time_us+$sss_compensation_post_duration_us)) )); then
				load_condition=$load_condition"_sss"
				break
			fi
		done			
	fi
}

# MAINTAIN PINGERS + ASSOCIATED HELPER FUNCTIONS

monitor_reflector_responses_fping()
{
		
	declare -A rtt_baselines_us

	for (( reflector=0; reflector<$no_reflectors; reflector++ ))
	do
		if [[ -f /tmp/cake-autorate/reflector_${reflectors[$reflector]//./-}_baseline_us ]]; then
			read rtt_baselines_us[${reflectors[$reflector]}] < /tmp/cake-autorate/reflector_${reflectors[$reflector]//./-}_baseline_us
		else
			rtt_baselines_us[${reflectors[$reflector]}]=1000000
		fi
	done
	
	while read timestamp reflector _ seq_rtt
	do 
		t_start_us=${EPOCHREALTIME/./}

		[[ $seq_rtt =~ \[([0-9]+)\].*[[:space:]]([0-9]+)\.?([0-9]+)?[[:space:]]ms ]] || continue

		timestamp=${timestamp//[\[\]]}

		seq=${BASH_REMATCH[1]}

		rtt_us=${BASH_REMATCH[3]}000
		rtt_us=$((${BASH_REMATCH[2]}000+10#${rtt_us:0:3}))

		rtt_delta_us=$(( $rtt_us-${rtt_baselines_us[$reflector]} ))

		alpha=$(( (( $rtt_delta_us >=0 )) ? $alpha_baseline_increase : $alpha_baseline_decrease ))

		rtt_baselines_us[$reflector]=$(( ( (1000-$alpha)*${rtt_baselines_us[$reflector]}+$alpha*$rtt_us )/1000 ))

		dl_owd_baseline_us=$((${rtt_baselines_us[$reflector]}/2))
		ul_owd_baseline_us=$dl_owd_baseline_us

		dl_owd_us=$(($rtt_us/2))
		ul_owd_us=$dl_owd_us

		dl_owd_delta_us=$(($rtt_delta_us/2))
		ul_owd_delta_us=$dl_owd_delta_us		
		
		timestamp_us=${timestamp//[\[\]]}0

		printf '%s %s %s %s %s %s %s %s %s %s\n' "$timestamp" "$reflector" "$seq" "$dl_owd_baseline_us" "$dl_owd_us" "$dl_owd_delta_us" "$ul_owd_baseline_us" "$ul_owd_us" "$ul_owd_delta_us" > /tmp/cake-autorate/ping_fifo

		timestamp_us=${timestamp_us//[.]}

		printf '%s' "$timestamp_us" > /tmp/cake-autorate/reflector_${reflector//./-}_last_timestamp_us
		
		printf '%s' "$timestamp_us" > /tmp/cake-autorate/reflectors_last_timestamp_us

	done</tmp/cake-autorate/fping_fifo

	for (( reflector=0; reflector<$no_reflectors; reflector++))
	do
		printf '%s' ${rtt_baselines_us[${reflectors[$reflector]}]} > /tmp/cake-autorate/reflector_${reflector//./-}_baseline_us
	done
}

start_pinger_fping()
{
	fping $ping_extra_args --timestamp --loop --period $reflector_ping_interval_ms --interval $ping_response_interval_ms --timeout 10000 ${reflectors[@]:0:$no_pingers} 2> /dev/null > /tmp/cake-autorate/fping_fifo&
	pinger_pids[0]=$!
	monitor_reflector_responses_fping &
}

kill_pinger_fping()
{
	kill "${pinger_pids[@]}" 2> /dev/null
}

start_pingers_fping()
{
	mkfifo /tmp/cake-autorate/fping_fifo
	fping $ping_extra_args --timestamp --loop --period $reflector_ping_interval_ms --interval $ping_response_interval_ms --timeout 10000 ${reflectors[@]:0:$no_pingers} 2> /dev/null > /tmp/cake-autorate/fping_fifo&
	pinger_pids[0]=$!
	monitor_reflector_responses_fping &
}

kill_pingers_fping()
{
	echo "SHIT"
	echo "${pinger_pids[@]}"
	kill "${pinger_pids[@]}" 2> /dev/null
	exit
}

maintain_pingers()
{
	# this initiates the pingers and monitors reflector health, rotating reflectors as necessary

 	trap 'kill_pingers_$pinger_binary' TERM

	trap 'pause_reflector_health_check=1' USR1

	pause_reflector_health_check=0

	reflector_offences_idx=0

	pingers_t_start_us=${EPOCHREALTIME/./}	

	for ((reflector=0; reflector<$no_reflectors; reflector++))
	do
		printf '%s' "$pingers_t_start_us" > /tmp/cake-autorate/reflector_${reflectors[$reflector]//./-}_last_timestamp_us
	done
	
	printf '%s' "$pingers_t_start_us" > /tmp/cake-autorate/reflectors_last_timestamp_us

        # For each pinger initialize record of offences
        for ((pinger=0; pinger<$no_pingers; pinger++))                           
	do
		declare -n reflector_offences="reflector_${pinger}_offences"                                                                                                               
		for ((i=0; i<$reflector_misbehaving_detection_window; i++)) do reflector_offences[i]=0; done
                sum_reflector_offences[$pinger]=0
        done

	start_pingers_$pinger_binary
	
	# Reflector health check loop - verifies reflectors have not gone stale and rotates reflectors as necessary
	while true
	do
		sleep_s $reflector_health_check_interval_s

		# ensure that we do not pause right in the middle of replacing a reflector
		if (($pause_reflector_health_check)); then
			(($debug)) && log_msg "DEBUG" "Pausing reflector health check."
			kill -STOP $BASHPID
			(($debug)) && log_msg "DEBUG" "Resuming reflector health check."
			pause_reflector_health_check=0
		fi

		for ((pinger=0; pinger<$no_pingers; pinger++))
		do
			reflector_check_time_us=${EPOCHREALTIME/./}
			concurrent_read_positive_integer reflector_last_timestamp_us /tmp/cake-autorate/reflector_${reflectors[$pinger]//./-}_last_timestamp_us
			declare -n reflector_offences="reflector_${pinger}_offences"

			(( ${reflector_offences[$reflector_offences_idx]} )) && ((sum_reflector_offences[$pinger]--))
			reflector_offences[$reflector_offences_idx]=$(( (((${EPOCHREALTIME/./}-$reflector_last_timestamp_us) > $reflector_response_deadline_us)) ? 1 : 0 ))
			((reflector_offences[$reflector_offences_idx])) && ((sum_reflector_offences[$pinger]++))

			if ((sum_reflector_offences[$pinger]>=$reflector_misbehaving_detection_thr)); then

				(($debug)) && log_msg "DEBUG" "Warning: reflector: ${reflectors[$pinger]} seems to be misbehaving."
				
				if(($no_reflectors>$no_pingers)); then

					# pingers always use reflectors[0]..[$no_pingers-1] as the initial set
					# and the additional reflectors are spare reflectors should any from initial set go stale
					# a bad reflector in the initial set is replaced with $reflectors[$no_pingers]
					# $reflectors[$no_pingers] is then unset
					# and the the bad reflector moved to the back of the queue (last element in $reflectors[])
					# and finally the indices for $reflectors are updated to reflect the new order
	
					(($debug)) && log_msg "DEBUG" "replacing reflector: ${reflectors[$pinger]} with ${reflectors[$no_pingers]}."
					kill_pinger_$pinger_binary $pinger
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
					start_pinger_$pinger_binary $pinger
					
				else
					(($debug)) && log_msg "DEBUG" "No additional reflectors specified so just retaining: ${reflectors[$pinger]}."
					reflector_offences[$pinger]=0
				fi

				for ((i=0; i<$reflector_misbehaving_detection_window; i++)) do reflector_offences[i]=0; done
				sum_reflector_offences[$pinger]=0
			fi		
		done
		((reflector_offences_idx=(reflector_offences_idx+1)%$reflector_misbehaving_detection_window))
	done
}

set_cake_rate()
{
	local interface=$1
	local shaper_rate_kbps=$2
	local -n time_rate_set_us=$3
	
	(($output_cake_changes)) && log_msg "CAKE-CHANGE" "tc qdisc change root dev ${interface} cake bandwidth ${shaper_rate_kbps}Kbit"
	
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
	
	# compensated OWD delay threshold in microseconds
	compensated_delay_thr_us=$(( ($delay_thr_us + $max_wire_packet_rtt_us)/2 ))

	# write out max_wire_packet_rtt_us
	printf '%s' "$max_wire_packet_rtt_us" > /tmp/cake-autorate/max_wire_packet_rtt_us
}

concurrent_read_positive_integer()
{
	# in the context of separate processes writing using > and reading form file
        # it seems costly calls to the external flock binary can be avoided
	# read either succeeds as expected or occassionally reads in bank value
	# so just test for blank value and re-read until not blank

	local -n value=$1
 	local path=$2
	while true 
	do
		read -r value < $path; 
		if [[ -z "${value##*[!0-9]*}" ]]; then
			if (($debug)); then
				read -r caller_output< <(caller)
				log_msg "DEBUG" "concurrent_read_positive_integer() misfire with the following particulars:"
				log_msg "DEBUG" "caller=$caller_output; value=$value; and path=$path"
			fi 
			sleep_us $concurrent_read_positive_integer_interval_us
			continue
		else
			break
		fi
	done
}

verify_ifs_up()
{
	# Check the rx/tx paths exist and give extra time for ifb's to come up if needed
	# This will block if ifs never come up

	while [[ ! -f $rx_bytes_path || ! -f $tx_bytes_path ]]
	do
		(($debug)) && [[ ! -f $rx_bytes_path ]] && log_msg "DEBUG" "Warning: The configured download interface: '$dl_if' does not appear to be present. Waiting $if_up_check_interval_s seconds for the interface to come up." 
		(($debug)) && [[ ! -f $tx_bytes_path ]] && log_msg "DEBUG" "Warning: The configured upload interface: '$ul_if' does not appear to be present. Waiting $if_up_check_interval_s seconds for the interface to come up." 
		sleep_s $if_up_check_interval_s
	done
}

sleep_s()
{
	# calling external sleep binary is slow
	# bash does have a loadable sleep 
	# but read's timeout can more portably be exploited and this is apparently even faster anyway

	local sleep_duration_s=$1 # (seconds, e.g. 0.5, 1 or 1.5)

	read -t $sleep_duration_s < /tmp/cake-autorate/sleep_fifo
}

sleep_us()
{
	# calling external sleep binary is slow
	# bash does have a loadable sleep 
	# but read's timeout can more portably be exploited and this is apparently even fastera anyway

	local sleep_duration_us=$1 # (microseconds)
	
	sleep_duration_s=000000$sleep_duration_us
	sleep_duration_s=$((10#${sleep_duration_s::-6})).${sleep_duration_s: -6}
	read -t $sleep_duration_s < /tmp/cake-autorate/sleep_fifo
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

log_file()
{
	if [[ ! -t 1 ]]; then
		if (( (${EPOCHREALTIME/./}-$t_log_file_start_us) > $log_file_rotation_check_interval_us )); then

			(($debug)) && log_msg "DEBUG" "configured log file rotation check interval time: $log_file_rotation_check_interval_mins minute(s) has elapsed. Checking log file size."
			read log_file_size_KB< <(du -bk /tmp/cake-autorate.log)
			log_file_size_KB=${log_file_size_KB//[!0-9]/}
			if (( $log_file_size_KB > $log_file_max_size_KB )); then
				(($debug)) && log_msg "DEBUG" "log file size: $log_file_size_KB KB has exceeded configured maximum: $log_file_max_size_KB KB so rotating log file"
				mv /tmp/cake-autorate.log /tmp/cake-autorate.log.old
				(($output_processing_stats)) && print_header
			else
					(($debug)) && log_msg "DEBUG" "log file size: $log_file_size_KB KB has not exceeded configured maximum: $log_file_max_size_KB KB so not rotating log file"
			fi
				t_log_file_start_us=${EPOCHREALTIME/./}
		fi
	fi
}

# ======= Start of the Main Routine ========

trap ":" USR1

[[ ! -f $install_dir"cake-autorate-config.sh" ]] && echo "ERROR; No config file found. Exiting now." && exit
. $install_dir"cake-autorate-config.sh"
[[ $config_file_check != "cake-autorate" ]] && echo "ERROR; Config file error. Please check config file entries." && exit

# /tmp/cake-autorate/ is used to store temporary files
# it should not exist on startup so if it does exit, else create the directory
if [[ -d /tmp/cake-autorate ]]; then
        echo "ERROR; /tmp/cake-autorate already exists. Is another instance running? Exiting script."
        trap - INT TERM EXIT
        exit
else
        mkdir /tmp/cake-autorate
fi

mkfifo /tmp/cake-autorate/sleep_fifo
exec 3<> /tmp/cake-autorate/sleep_fifo

no_reflectors=${#reflectors[@]} 

# Check no_pingers <= no_reflectors
(( $no_pingers > $no_reflectors)) && { echo "ERROR; number of pingers cannot be greater than number of reflectors. Exiting script."; exit; }

# Check dl/if interface not the same
[[ $dl_if == $ul_if ]] && { echo "ERROR; download interface and upload interface are both set to: '$dl_if', but cannot be the same. Exiting script."; exit; }

# Check bufferbloat detection threshold not greater than window length
(( $bufferbloat_detection_thr > $bufferbloat_detection_window )) && { echo "ERROR; bufferbloat_detection_thr cannot be greater than bufferbloat_detection_window. Exiting script."; exit; }

# Passed error checks 

# test if stdout is a tty (terminal)
if [[ ! -t 1 ]]; then 
	echo "stdout not a terminal so redirecting output to: /tmp/cake-autorate.log"
	>/tmp/cake-autorate.log # reset log file on startup
	log_file_max_time_us=$(($log_file_max_time_mins*60000000))
	mkfifo /tmp/cake-autorate/log_fifo
	exec 5<> /tmp/cake-autorate/log_fifo
	maintain_log_file&
	maintain_log_file_pid=$!
fi

sleep 2

if (( $debug )) ; then
	log_msg "DEBUG" "Starting CAKE-autorate $cake_autorate_version"
	log_msg "DEBUG" "Down interface: $dl_if ($min_dl_shaper_rate_kbps / $base_dl_shaper_rate_kbps / $max_dl_shaper_rate_kbps)"
	log_msg "DEBUG" "Up interface: $ul_if ($min_ul_shaper_rate_kbps / $base_ul_shaper_rate_kbps / $max_ul_shaper_rate_kbps)"
	log_msg "DEBUG" "rx_bytes_path: $rx_bytes_path"
	log_msg "DEBUG" "tx_bytes_path: $tx_bytes_path"
fi

# Wait if $startup_wait_s > 0
if (($startup_wait_s>0)); then
        (($debug)) && log_msg "DEBUG" "Waiting $startup_wait_s seconds before startup."
        sleep_s $startup_wait_s
fi

# Check interfaces are up and wait if necessary for them to come up
verify_ifs_up

# Initialize variables

# Convert human readable parameters to values that work with integer arithmetic
printf -v alpha_baseline_increase %.0f\\n "${alpha_baseline_increase}e3"
printf -v alpha_baseline_decrease %.0f\\n "${alpha_baseline_decrease}e3"   
printf -v achieved_rate_adjust_down_bufferbloat %.0f\\n "${achieved_rate_adjust_down_bufferbloat}e3"
printf -v shaper_rate_adjust_down_bufferbloat %.0f\\n "${shaper_rate_adjust_down_bufferbloat}e3"
printf -v shaper_rate_adjust_up_load_high %.0f\\n "${shaper_rate_adjust_up_load_high}e3"
printf -v shaper_rate_adjust_down_load_low %.0f\\n "${shaper_rate_adjust_down_load_low}e3"
printf -v shaper_rate_adjust_up_load_low %.0f\\n "${shaper_rate_adjust_up_load_low}e3"
printf -v high_load_thr_percent %.0f\\n "${high_load_thr}e2"
printf -v medium_load_thr_percent %.0f\\n "${medium_load_thr}e2"
printf -v reflector_ping_interval_ms %.0f\\n "${reflector_ping_interval_s}e3"
printf -v reflector_ping_interval_us %.0f\\n "${reflector_ping_interval_s}e6"
printf -v monitor_achieved_rates_interval_us %.0f\\n "${monitor_achieved_rates_interval_ms}e3"
printf -v sustained_idle_sleep_thr_us %.0f\\n "${sustained_idle_sleep_thr_s}e6"
printf -v reflector_response_deadline_us %.0f\\n "${reflector_response_deadline_s}e6"

global_ping_response_timeout_us=$(( 1000000*$global_ping_response_timeout_s ))
bufferbloat_refractory_period_us=$(( 1000*$bufferbloat_refractory_period_ms ))
decay_refractory_period_us=$(( 1000*$decay_refractory_period_ms ))
delay_thr_us=$(( 1000*$delay_thr_ms ))


for (( i=0; i<${#sss_times_s[@]}; i++ ));
do
	printf -v sss_times_us[i] %.0f\\n "${sss_times_s[i]}e6"
done
printf -v sss_compensation_pre_duration_us %.0f\\n "${sss_compensation_pre_duration_ms}e3"
printf -v sss_compensation_post_duration_us %.0f\\n "${sss_compensation_post_duration_ms}e3"

ping_response_interval_us=$(($reflector_ping_interval_us/$no_pingers))
ping_response_interval_ms=$(($ping_response_interval_us/1000))

stall_detection_timeout_us=$(( $stall_detection_thr*$ping_response_interval_us ))
stall_detection_timeout_s=000000$stall_detection_timeout_us
stall_detection_timeout_s=$((10#${stall_detection_timeout_s::-6})).${stall_detection_timeout_s: -6}

concurrent_read_positive_integer_interval_us=$(($ping_response_interval_us/4))

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

declare -a dl_delays=( $(for i in {1..$bufferbloat_detection_window}; do echo 0; done) )
declare -a ul_delays=( $(for i in {1..$bufferbloat_detection_window}; do echo 0; done) )

delays_idx=0
sum_dl_delays=0
sum_ul_delays=0

mkfifo /tmp/cake-autorate/ping_fifo
exec 4<> /tmp/cake-autorate/ping_fifo

# Initiate achived rate monitor
monitor_achieved_rates $rx_bytes_path $tx_bytes_path $monitor_achieved_rates_interval_us&
monitor_achieved_rates_pid=$!

maintain_pingers&
maintain_pingers_pid=$!

if (($debug)); then
	if (( $bufferbloat_refractory_period_us <= ($bufferbloat_detection_window*$ping_response_interval_us) )); then
		log_msg "DEBUG" "Warning: bufferbloat refractory period: $bufferbloat_refractory_period_us us."
		log_msg "DEBUG" "Warning: but expected time to overwrite samples in bufferbloat detection window is: $(($bufferbloat_detection_window*$ping_response_interval_us)) us." 
		log_msg "DEBUG" "Warning: Consider increasing bufferbloat refractory period or decreasing bufferbloat detection window."
	fi
fi

(($output_processing_stats)) && print_header

while true
do
	while read -t $stall_detection_timeout_s timestamp reflector seq dl_owd_baseline_us dl_owd_us dl_owd_delta_us ul_owd_baseline_us ul_owd_us ul_owd_delta_us
	do 
	
		t_start_us=${EPOCHREALTIME/./}
		if ((($t_start_us - 10#"${timestamp//[.]}"0)>500000)); then
			(($debug)) && log_msg "DEBUG" "processed response from [$reflector] that is > 500ms old. Skipping." 
			continue
		fi

		# Keep track of number of dl delays across detection window
		# .. for download:
		(( ${dl_delays[$delays_idx]} )) && ((sum_dl_delays--))
		dl_delays[$delays_idx]=$(( $dl_owd_delta_us > $compensated_delay_thr_us ? 1 : 0 ))
		((dl_delays[$delays_idx])) && ((sum_dl_delays++))
		# .. for upload
		(( ${ul_delays[$delays_idx]} )) && ((sum_ul_delays--))
		ul_delays[$delays_idx]=$(( $ul_owd_delta_us > $compensated_delay_thr_us ? 1 : 0 ))
		((ul_delays[$delays_idx])) && ((sum_ul_delays++))
	 	# .. and move index on	
		(( delays_idx=(delays_idx+1)%$bufferbloat_detection_window ))

		dl_bufferbloat_detected=$(( (($sum_dl_delays>=$bufferbloat_detection_thr)) ? 1 : 0 ))
		ul_bufferbloat_detected=$(( (($sum_ul_delays>=$bufferbloat_detection_thr)) ? 1 : 0 ))

		get_loads

		classify_load $dl_load_percent $dl_achieved_rate_kbps $dl_bufferbloat_detected dl_load_condition
		classify_load $ul_load_percent $ul_achieved_rate_kbps $ul_bufferbloat_detected ul_load_condition
	
		dl_load_condition="dl_"$dl_load_condition
		ul_load_condition="ul_"$ul_load_condition

		get_next_shaper_rate $min_dl_shaper_rate_kbps $base_dl_shaper_rate_kbps $max_dl_shaper_rate_kbps $dl_achieved_rate_kbps $dl_load_condition $t_start_us t_dl_last_bufferbloat_us t_dl_last_decay_us dl_shaper_rate_kbps
		get_next_shaper_rate $min_ul_shaper_rate_kbps $base_ul_shaper_rate_kbps $max_ul_shaper_rate_kbps $ul_achieved_rate_kbps $ul_load_condition $t_start_us t_ul_last_bufferbloat_us t_ul_last_decay_us ul_shaper_rate_kbps

		set_shaper_rates

		if (($output_processing_stats)); then 
			printf -v processing_stats '%s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s' $EPOCHREALTIME $dl_achieved_rate_kbps $ul_achieved_rate_kbps $dl_load_percent $ul_load_percent $timestamp $reflector $seq $dl_owd_baseline_us $dl_owd_us $dl_owd_delta_us $ul_owd_baseline_us $ul_owd_us $ul_owd_delta_us $compensated_delay_thr_us $sum_dl_delays $sum_ul_delays $dl_load_condition $ul_load_condition $dl_shaper_rate_kbps $ul_shaper_rate_kbps
			log_msg "DATA" "$processing_stats"
		fi

		# If base rate is sustained, increment sustained base rate timer (and break out of processing loop if enough time passes)
		if (($enable_sleep_function)); then
			if [[ $dl_load_condition == *idle* && $ul_load_condition == *idle* ]]; then
				((t_sustained_connection_idle_us+=$((${EPOCHREALTIME/./}-$t_end_us))))
				(($t_sustained_connection_idle_us>$sustained_idle_sleep_thr_us)) && break
			else
				# reset timer
				t_sustained_connection_idle_us=0
			fi
		fi
		
		t_end_us=${EPOCHREALTIME/./}

	done</tmp/cake-autorate/ping_fifo

	# stall handling procedure
	# PIPESTATUS[0] == 142 corresponds with while loop timeout
	# i.e. no reflector responses within $stall_detection_thr * $ping_response_interval_us
	if (( ${PIPESTATUS[0]} == 142 )); then


		(($debug)) && log_msg "DEBUG" "Warning: no reflector response within: $stall_detection_timeout_s seconds. Checking for loads."

		get_loads

		(($debug)) && log_msg "DEBUG" "load check is: (($dl_achieved_rate_kbps kbps > $connection_stall_thr_kbps kbps && $ul_achieved_rate_kbps kbps > $connection_stall_thr_kbps kbps))"

		# non-zero load so despite no reflector response within stall interval, the connection not considered to have stalled
		# and therefore resume normal operation
		if (($dl_achieved_rate_kbps > $connection_stall_thr_kbps && $ul_achieved_rate_kbps > $connection_stall_thr_kbps )); then

			(($debug)) && log_msg "DEBUG" "load above connection stall threshold so resuming normal operation."
			continue

		fi

		(($debug)) && log_msg "DEBUG" "Warning: connection stall detection. Waiting for new ping or increased load"

		# save intial global reflector timestamp to check against for any new reflector response
		concurrent_read_positive_integer initial_reflectors_last_timestamp_us /tmp/cake-autorate/reflectors_last_timestamp_us

		# send signal USR1 to pause reflector health monitoring to prevent reflector rotation
		kill -USR1 $maintain_pingers_pid

		t_connection_stall_time_us=${EPOCHREALTIME/./}

	        # wait until load resumes or ping response received (or global reflector response timeout)
	        while true
	        do
        	        t_start_us=${EPOCHREALTIME/./}
			
			concurrent_read_positive_integer new_reflectors_last_timestamp_us /tmp/cake-autorate/reflectors_last_timestamp_us
	                get_loads

			if (( $new_reflectors_last_timestamp_us != $initial_reflectors_last_timestamp_us || ( $dl_achieved_rate_kbps > $connection_stall_thr_kbps && $ul_achieved_rate_kbps > $connection_stall_thr_kbps) )); then

				(($debug)) && log_msg "DEBUG" "Connection stall ended. Resuming normal operation."

				# resume reflector health monitoring
				kill -CONT $maintain_pingers_pid

				# continue main loop (i.e. skip idle/global timeout handling beloow)
				continue 2
			fi

        	        sleep_remaining_tick_time $t_start_us $reflector_ping_interval_us

			if (( $t_start_us > ($t_connection_stall_time_us + $global_ping_response_timeout_us - $stall_detection_timeout_us) )); then 
		
				(($debug)) && log_msg "DEBUG" "Warning: Global ping response timeout. Enforcing minimum shaper rate and waiting for minimum load." 
				break
			fi
	        done	

	else
		(($debug)) && log_msg "DEBUG" "Connection idle. Enforcing minimum shaper rates and waiting for minimum load."
	fi
	
	# conservatively set hard minimums and wait until there is a load increase again
	dl_shaper_rate_kbps=$min_dl_shaper_rate_kbps
	ul_shaper_rate_kbps=$min_ul_shaper_rate_kbps
	set_shaper_rates

	# Initiate termination of ping processes and wait until complete
	kill -CONT $maintain_pingers_pid
	kill $maintain_pingers_pid 2> /dev/null
	wait $maintain_pingers_pid

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
	maintain_pingers&
	maintain_pingers_pid=$!
done
