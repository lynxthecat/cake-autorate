#!/bin/bash

# CAKE-autorate automatically adjusts CAKE bandwidth(s)
# in dependence on: a) receive and transmit transfer rates; and b) latency
# (or can just be used to monitor and log transfer rates and latency)

# requires packages: bash; and one of the supported ping binaries

# each cake-autorate instance must be configured using a corresponding config file 

# Project homepage: https://github.com/lynxthecat/cake-autorate
# Licence details:  https://github.com/lynxthecat/cake-autorate/blob/master/LICENCE.md

# Author: @Lynx (OpenWrt forum)
# Inspiration taken from: @moeller0 (OpenWrt forum)

# Initialize file descriptors
## -1 signifies that the log file fd will not be used and
## that the log file will be written to directly
log_fd=-1
## ping_fd should be open for the duration of the script
## as it's integral to the operation of the script
exec {ping_fd}<> <(:) || true

# Bash correctness options
## Disable globbing (expansion of *).
set -f
## Forbid using unset variables.
set -u
## The exit status of a pipeline is the status of the last
## command to exit with a non-zero status, or zero if no
## command exited with a non-zero status.
set -o pipefail

# Possible performance improvement
export LC_ALL=C

# Set PREFIX
PREFIX=/root/cake-autorate

# shellcheck source=cake-autorate_lib.sh
. "${PREFIX}/cake-autorate_lib.sh"
# shellcheck source=cake-autorate_defaults.sh
. "${PREFIX}/cake-autorate_defaults.sh"

trap cleanup_and_killall INT TERM EXIT

cleanup_and_killall()
{	
	trap true INT TERM EXIT
	
	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"
	
	log_msg "INFO" "Stopping cake-autorate with PID: ${BASHPID} and config: ${config_path}"
	
	log_msg "INFO" "Killing all background processes and cleaning up temporary files."

	proc_man_stop maintain_pingers
	proc_man_stop monitor_achieved_rates
	proc_man_stop maintain_log_file

	[[ -d "${run_path}" ]] && rm -r "${run_path}"
	rmdir /var/run/cake-autorate 2>/dev/null

	log_msg "SYSLOG" "Stopped cake-autorate with PID: ${BASHPID} and config: ${config_path}"

	trap - INT TERM EXIT
	exit
}

log_msg()
{
	# send logging message to terminal, log file fifo, log file and/or system logger

	local type=${1}
	local msg=${2}
	local instance_id=${instance_id:-"unknown"}

	case ${type} in

		DEBUG)
			[[ "${debug}" == "0" ]] && return # skip over DEBUG messages where debug disabled 
			log_timestamp=${EPOCHREALTIME}
			((log_DEBUG_messages_to_syslog)) && ((use_logger)) && logger -t "cake-autorate.${instance_id}" "${type}: ${log_timestamp} ${msg}"
			;;
	
		ERROR)
			log_timestamp=${EPOCHREALTIME}
			((use_logger)) && logger -t "cake-autorate.${instance_id}" "${type}: ${log_timestamp} ${msg}"
			;;

		SYSLOG)
			log_timestamp=${EPOCHREALTIME}
			((use_logger)) && logger -t "cake-autorate.${instance_id}" "INFO: ${log_timestamp} ${msg}"
			;;

		*)
			log_timestamp=${EPOCHREALTIME}
			;;
	esac
			
	# Output to the log file fifo if available (for rotation handling)
	# else output directly to the log file
	if (( log_fd >= 0 )); then
		((log_to_file)) && printf '%s; %(%F-%H:%M:%S)T; %s; %s\n' "${type}" -1 "${log_timestamp}" "${msg}" >&"${log_fd}"
	else
		((log_to_file)) && printf '%s; %(%F-%H:%M:%S)T; %s; %s\n' "${type}" -1 "${log_timestamp}" "${msg}" >> "${log_file_path}"
	fi
        
	((terminal)) && printf '%s; %(%F-%H:%M:%S)T; %s; %s\n' "${type}" -1 "${log_timestamp}" "${msg}"
}

print_headers()
{
	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	header="DATA_HEADER; LOG_DATETIME; LOG_TIMESTAMP; PROC_TIME_US; DL_ACHIEVED_RATE_KBPS; UL_ACHIEVED_RATE_KBPS; DL_LOAD_PERCENT; UL_LOAD_PERCENT; RTT_TIMESTAMP; REFLECTOR; SEQUENCE; DL_OWD_BASELINE; DL_OWD_US; DL_OWD_DELTA_EWMA_US; DL_OWD_DELTA_US; DL_ADJ_DELAY_THR; UL_OWD_BASELINE; UL_OWD_US; UL_OWD_DELTA_EWMA_US; UL_OWD_DELTA_US; UL_ADJ_DELAY_THR; SUM_DL_DELAYS; SUM_UL_DELAYS; DL_LOAD_CONDITION; UL_LOAD_CONDITION; CAKE_DL_RATE_KBPS; CAKE_UL_RATE_KBPS"
 	((log_to_file)) && printf '%s\n' "${header}" >> "${log_file_path}"
 	((terminal)) && printf '%s\n' "${header}"

	header="LOAD_HEADER; LOG_DATETIME; LOG_TIMESTAMP; PROC_TIME_US; DL_ACHIEVED_RATE_KBPS; UL_ACHIEVED_RATE_KBPS; CAKE_DL_RATE_KBPS; CAKE_UL_RATE_KBPS"
 	((log_to_file)) && printf '%s\n' "${header}" >> "${log_file_path}"
 	((terminal)) && printf '%s\n' "${header}"

	header="REFLECTOR_HEADER; LOG_DATETIME; LOG_TIMESTAMP; PROC_TIME_US; REFLECTOR; DL_MIN_BASELINE_US; DL_BASELINE_US; DL_BASELINE_DELTA_US; DL_BASELINE_DELTA_THR_US; DL_MIN_DELTA_EWMA_US; DL_DELTA_EWMA_US; DL_DELTA_EWMA_DELTA_US; DL_DELTA_EWMA_DELTA_THR; UL_MIN_BASELINE_US; UL_BASELINE_US; UL_BASELINE_DELTA_US; UL_BASELINE_DELTA_THR_US; UL_MIN_DELTA_EWMA_US; UL_DELTA_EWMA_US; UL_DELTA_EWMA_DELTA_US; UL_DELTA_EWMA_DELTA_THR"
 	((log_to_file)) && printf '%s\n' "${header}" >> "${log_file_path}"
 	((terminal)) && printf '%s\n' "${header}"
}

# MAINTAIN_LOG_FILE + HELPER FUNCTIONS

rotate_log_file()
{
	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	if [[ -f ${log_file_path} ]]
	then
		cat "${log_file_path}" > "${log_file_path}.old"
		true > "${log_file_path}"
	fi
	((output_processing_stats)) && print_headers
}

generate_log_file_exporter()
{
	cat > "${run_path}/export_log_file" <<- EOT
	#!/bin/bash

	. "${PREFIX}/cake-autorate_lib.sh"
	PROC_STATE_FILE="${run_path}/proc_state"
	PROC_STATE_FILE_LOCK="${run_path}/proc_state.lock"

	timeout_s=\${1:-20}

	if ! proc_man_signal maintain_log_file "USR1"
	then
		printf "ERROR: Failed to signal maintain_log_file process.\n" >&2
		exit 1
	fi
	rm -f "${run_path}/last_log_file_export"

	read_try=0

	while [[ ! -f "${run_path}/last_log_file_export" ]]
	do
		sleep 1
		if (( ++read_try >= \${timeout_s} )); then
			printf "ERROR: Timeout (\${timeout_s}s) reached before new log file export identified.\n" >&2
			exit 1
		fi
	done

	read -r log_file_export_path < "${run_path}/last_log_file_export"
		
	printf "Log file export complete.\n"

	printf "Log file available at location: "
	printf "\${log_file_export_path}\n"
	EOT

	chmod +x "${run_path}/export_log_file"
}

export_log_file()
{
	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	printf -v log_file_export_datetime '%(%Y_%m_%d_%H_%M_%S)T'
	log_file_export_path="${log_file_path/.log/_${log_file_export_datetime}.log}"
	log_msg "DEBUG" "Exporting log file with path: ${log_file_path/.log/_${log_file_export_datetime}.log}"

	# Now export with or without compression to the appropriate export path
	if ((log_file_export_compress)); then
		log_file_export_path="${log_file_export_path}.gz"
		if [[ -f "${log_file_path}.old" ]]; then 
			gzip -c "${log_file_path}.old" > "${log_file_export_path}"
			gzip -c "${log_file_path}" >> "${log_file_export_path}"
		else
			gzip -c "${log_file_path}" > "${log_file_export_path}"
		fi
	else
		if [[ -f "${log_file_path}.old" ]]; then
			cp "${log_file_path}.old" "${log_file_export_path}"
			cat "${log_file_path}" >> "${log_file_export_path}"
		else
			cp "${log_file_path}" "${log_file_export_path}"
		fi
	fi
	
	printf '%s' "${log_file_export_path}" > "${run_path}/last_log_file_export"
}

flush_log_fd()
{
	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"
	while read -r -t 0.01 -u "${log_fd}" log_line
	do
		printf '%s\n' "${log_line}" >> "${log_file_path}"
	done
}

get_log_file_size_bytes()
{
	log_file_size_bytes=$(wc -c "${log_file_path}" 2>/dev/null | awk '{print $1}')
	log_file_size_bytes=${log_file_size_bytes:-0}
}

kill_maintain_log_file()
{
	trap - TERM EXIT
	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"
	flush_log_fd
	exit
}

maintain_log_file()
{
	trap '' INT
	trap 'kill_maintain_log_file' TERM EXIT
	trap 'export_log_file' USR1

	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	t_log_file_start_us=${EPOCHREALTIME/./}

	get_log_file_size_bytes

	while true
	do
		while read -r -u "${log_fd}" log_line
		do

			printf '%s\n' "${log_line}" >> "${log_file_path}"

			# Verify log file size < configured maximum
			# The following two lines with costly call to 'du':
			# 	read log_file_size_bytes< <(du -b ${log_file_path}/cake-autorate.log)
			# 	log_file_size_bytes=${log_file_size_bytes//[!0-9]/}
			# can be more efficiently handled with this line:
			((log_file_size_bytes=log_file_size_bytes+${#log_line}+1))

			# Verify log file time < configured maximum
			if (( (${EPOCHREALTIME/./}-t_log_file_start_us) > log_file_max_time_us )); then
			
				log_msg "DEBUG" "log file maximum time: ${log_file_max_time_mins} minutes has elapsed so rotating log file"
				break
			fi

			if (( log_file_size_bytes > log_file_max_size_bytes )); then

				log_file_size_KB=$((log_file_size_bytes/1024))
				log_msg "DEBUG" "log file size: ${log_file_size_KB} KB has exceeded configured maximum: ${log_file_max_size_KB} KB so rotating log file"
				break
			fi

		done

		flush_log_fd
		rotate_log_file
		t_log_file_start_us=${EPOCHREALTIME/./}
		get_log_file_size_bytes

	done
}

get_next_shaper_rate() 
{
	local min_shaper_rate_kbps=${1}
	local base_shaper_rate_kbps=${2}
	local max_shaper_rate_kbps=${3}
	local achieved_rate_kbps=${4}
	local load_condition=${5}
	local t_next_rate_us=${6}
	local -n t_last_bufferbloat_us=${7}
	local -n t_last_decay_us=${8}
	local -n shaper_rate_kbps=${9}

	case ${load_condition} in

		# upload Starlink satelite switching compensation, so drop down to minimum rate for upload through switching period
		ul*sss)
			shaper_rate_kbps=${min_shaper_rate_kbps}
			;;
		# download Starlink satelite switching compensation, so drop down to base rate for download through switching period
		dl*sss)
			shaper_rate_kbps=$(( shaper_rate_kbps > base_shaper_rate_kbps ? base_shaper_rate_kbps : shaper_rate_kbps ))
			;;
		# bufferbloat detected, so decrease the rate providing not inside bufferbloat refractory period
		*bb*)
			if (( t_next_rate_us > (t_last_bufferbloat_us+bufferbloat_refractory_period_us) )); then
				adjusted_achieved_rate_kbps=$(( (achieved_rate_kbps*achieved_rate_adjust_down_bufferbloat)/1000 )) 
				adjusted_shaper_rate_kbps=$(( (shaper_rate_kbps*shaper_rate_adjust_down_bufferbloat)/1000 )) 
				shaper_rate_kbps=$(( adjusted_achieved_rate_kbps > min_shaper_rate_kbps && adjusted_achieved_rate_kbps < adjusted_shaper_rate_kbps ? adjusted_achieved_rate_kbps : adjusted_shaper_rate_kbps ))
				t_last_bufferbloat_us=${EPOCHREALTIME/./}
			fi
			;;
            	# high load, so increase rate providing not inside bufferbloat refractory period 
		*high*)	
			if (( t_next_rate_us > (t_last_bufferbloat_us+bufferbloat_refractory_period_us) )); then
				shaper_rate_kbps=$(( (shaper_rate_kbps*shaper_rate_adjust_up_load_high)/1000 ))
			fi
			;;
		# low or idle load, so determine whether to decay down towards base rate, decay up towards base rate, or set as base rate
		*low*|*idle*)
			if (( t_next_rate_us > (t_last_decay_us+decay_refractory_period_us) )); then

				if ((shaper_rate_kbps > base_shaper_rate_kbps)); then
					decayed_shaper_rate_kbps=$(( (shaper_rate_kbps*shaper_rate_adjust_down_load_low)/1000 ))
					shaper_rate_kbps=$(( decayed_shaper_rate_kbps > base_shaper_rate_kbps ? decayed_shaper_rate_kbps : base_shaper_rate_kbps))
				elif ((shaper_rate_kbps < base_shaper_rate_kbps)); then
					decayed_shaper_rate_kbps=$(( (shaper_rate_kbps*shaper_rate_adjust_up_load_low)/1000 ))
					shaper_rate_kbps=$(( decayed_shaper_rate_kbps < base_shaper_rate_kbps ? decayed_shaper_rate_kbps : base_shaper_rate_kbps))
				fi

				t_last_decay_us=${EPOCHREALTIME/./}
			fi
			;;
		*)
			log_msg "ERROR" "unknown load condition: ${load_condition} in get_next_shaper_rate"
			exit 1
			;;
	esac
        # make sure to only return rates between cur_min_rate and cur_max_rate
        ((shaper_rate_kbps < min_shaper_rate_kbps)) && shaper_rate_kbps=${min_shaper_rate_kbps}
        ((shaper_rate_kbps > max_shaper_rate_kbps)) && shaper_rate_kbps=${max_shaper_rate_kbps}
}

monitor_achieved_rates()
{
	trap '' INT

	# track rx and tx bytes transfered and divide by time since last update
	# to determine achieved dl and ul transfer rates

	local rx_bytes_path=${1}
	local tx_bytes_path=${2}
	local monitor_achieved_rates_interval_us=${3} # (microseconds)

	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	compensated_monitor_achieved_rates_interval_us=${monitor_achieved_rates_interval_us}

	[[ -f "${rx_bytes_path}" ]] && { read -r prev_rx_bytes < "${rx_bytes_path}"; } 2> /dev/null || prev_rx_bytes=0
	[[ -f "${tx_bytes_path}" ]] && { read -r prev_tx_bytes < "${tx_bytes_path}"; } 2> /dev/null || prev_tx_bytes=0

	while true
	do
		t_start_us=${EPOCHREALTIME/./}

		# If rx/tx bytes file exists, read it in, otherwise set to prev_bytes
		# This addresses interfaces going down and back up
		[[ -f "${rx_bytes_path}" ]] && { read -r rx_bytes < "${rx_bytes_path}"; } 2> /dev/null || rx_bytes=${prev_rx_bytes}
		[[ -f "${tx_bytes_path}" ]] && { read -r tx_bytes < "${tx_bytes_path}"; } 2> /dev/null || tx_bytes=${prev_tx_bytes}

		dl_achieved_rate_kbps=$(( ((8000*(rx_bytes - prev_rx_bytes)) / compensated_monitor_achieved_rates_interval_us ) ))
		ul_achieved_rate_kbps=$(( ((8000*(tx_bytes - prev_tx_bytes)) / compensated_monitor_achieved_rates_interval_us ) ))

		((dl_achieved_rate_kbps<0)) && dl_achieved_rate_kbps=0
		((ul_achieved_rate_kbps<0)) && ul_achieved_rate_kbps=0

		printf '%s' "${dl_achieved_rate_kbps}" > "${run_path}/dl_achieved_rate_kbps"
		printf '%s' "${ul_achieved_rate_kbps}" > "${run_path}/ul_achieved_rate_kbps"

		if ((output_load_stats)); then 

			concurrent_read_integer dl_shaper_rate_kbps "${run_path}/dl_shaper_rate_kbps"
			concurrent_read_integer ul_shaper_rate_kbps "${run_path}/ul_shaper_rate_kbps"
			printf -v load_stats '%s; %s; %s; %s; %s' "${EPOCHREALTIME}" "${dl_achieved_rate_kbps}" "${ul_achieved_rate_kbps}" "${dl_shaper_rate_kbps}" "${ul_shaper_rate_kbps}"
			log_msg "LOAD" "${load_stats}"
		fi

		prev_rx_bytes=${rx_bytes}
		prev_tx_bytes=${tx_bytes}

		# read in the max_wire_packet_rtt_us
		concurrent_read_integer max_wire_packet_rtt_us "${run_path}/max_wire_packet_rtt_us"

		compensated_monitor_achieved_rates_interval_us=$(( ((monitor_achieved_rates_interval_us>(10*max_wire_packet_rtt_us) )) ? monitor_achieved_rates_interval_us : 10*max_wire_packet_rtt_us ))

		sleep_remaining_tick_time "${t_start_us}" "${compensated_monitor_achieved_rates_interval_us}"
	done
}

get_loads()
{
	# read in the dl/ul achieved rates and determine the loads

	concurrent_read_integer dl_achieved_rate_kbps "${run_path}/dl_achieved_rate_kbps"
	concurrent_read_integer ul_achieved_rate_kbps "${run_path}/ul_achieved_rate_kbps"

	dl_load_percent=$(( (100*dl_achieved_rate_kbps)/dl_shaper_rate_kbps ))
	ul_load_percent=$(( (100*ul_achieved_rate_kbps)/ul_shaper_rate_kbps ))

	printf '%s' "${dl_load_percent}" > "${run_path}/dl_load_percent"
	printf '%s' "${ul_load_percent}" > "${run_path}/ul_load_percent"
}

classify_load()
{
	# classify the load according to high/low/idle and add _delayed if delayed
	# thus ending up with high_delayed, low_delayed, etc.
	local load_percent=${1}
	local achieved_rate_kbps=${2}
	local bufferbloat_detected=${3}
	local -n load_condition=${4}

	if (( load_percent > high_load_thr_percent )); then
		load_condition="high"  
	elif (( achieved_rate_kbps > connection_active_thr_kbps )); then
		load_condition="low"
	else 
		load_condition="idle"
	fi
	
	((bufferbloat_detected)) && load_condition=${load_condition}"_bb"

	if ((sss_compensation)); then
		# shellcheck disable=SC2154
		for sss_time_us in "${sss_times_us[@]}"
		do
			((timestamp_usecs_past_minute=${EPOCHREALTIME/./}%60000000))
			if (( (timestamp_usecs_past_minute > (sss_time_us-sss_compensation_pre_duration_us)) && (timestamp_usecs_past_minute < (sss_time_us+sss_compensation_post_duration_us)) )); then
				load_condition=${load_condition}"_sss"
				break
			fi
		done			
	fi
}

# MAINTAIN PINGERS + ASSOCIATED HELPER FUNCTIONS

# TSPING FUNCTIONS #

kill_monitor_reflector_responses_tsping()
{
	trap - TERM EXIT

	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	# Store baselines and ewmas to files ready for next instance (e.g. after sleep)
	for (( reflector=0; reflector<no_reflectors; reflector++ ))
	do
		[[ -n "${dl_owd_baselines_us[${reflectors[reflector]}]}" ]] && printf '%s' "${dl_owd_baselines_us[${reflectors[reflector]}]}" > "${run_path}/reflector_${reflectors[reflector]//./-}_dl_baseline_us"
		[[ -n "${ul_owd_baselines_us[${reflectors[reflector]}]}" ]] && printf '%s' "${ul_owd_baselines_us[${reflectors[reflector]}]}" > "${run_path}/reflector_${reflectors[reflector]//./-}_ul_baseline_us"
		[[ -n "${dl_owd_delta_ewmas_us[${reflectors[reflector]}]}" ]] && printf '%s' "${dl_owd_delta_ewmas_us[${reflectors[reflector]}]}" > "${run_path}/reflector_${reflectors[reflector]//./-}_dl_delta_ewma_us"
		[[ -n "${ul_owd_delta_ewmas_us[${reflectors[reflector]}]}" ]] && printf '%s' "${ul_owd_delta_ewmas_us[${reflectors[reflector]}]}" > "${run_path}/reflector_${reflectors[reflector]//./-}_ul_delta_ewma_us"
	done

	exit
}

monitor_reflector_responses_tsping()
{
	trap '' INT
	trap kill_monitor_reflector_responses_tsping TERM EXIT		

	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	declare -A dl_owd_baselines_us
	declare -A ul_owd_baselines_us
	declare -A dl_owd_delta_ewmas_us
	declare -A ul_owd_delta_ewmas_us

	t_start_us=${EPOCHREALTIME/./}

	# Read in baselines if they exist, else just set them to 1s (rapidly converges downwards on new OWDs)
	for (( reflector=0; reflector < no_reflectors; reflector++ ))
	do
		if [[ -f "${run_path}/reflector_${reflectors[reflector]//./-}_dl_baseline_us" ]]; then
			read -r "dl_owd_baselines_us[${reflectors[reflector]}]" < "${run_path}/reflector_${reflectors[reflector]//./-}_dl_baseline_us"
		else
			dl_owd_baselines_us[${reflectors[reflector]}]=100000
		fi
		if [[ -f "${run_path}/reflector_${reflectors[reflector]//./-}_ul_baseline_us" ]]; then
			read -r "ul_owd_baselines_us[${reflectors[reflector]}]" < "${run_path}/reflector_${reflectors[reflector]//./-}_ul_baseline_us"
		else
			ul_owd_baselines_us[${reflectors[reflector]}]=100000
		fi
		if [[ -f "${run_path}/reflector_${reflectors[reflector]//./-}_dl_delta_ewma_us" ]]; then
			read -r "dl_owd_delta_ewmas_us[${reflectors[reflector]}]" < "${run_path}/reflector_${reflectors[reflector]//./-}_dl_delta_ewma_us"
		else
			dl_owd_delta_ewmas_us[${reflectors[reflector]}]=0
		fi
		if [[ -f "${run_path}/reflector_${reflectors[reflector]//./-}_ul_delta_ewma_us" ]]; then
			read -r "ul_owd_delta_ewmas_us[${reflectors[reflector]}]" < "${run_path}/reflector_${reflectors[reflector]//./-}_ul_delta_ewma_us"
		else
			ul_owd_delta_ewmas_us[${reflectors[reflector]}]=0
		fi
	done

	# shellcheck disable=SC2154
	while read -r -u "${pinger_fds[pinger]}" timestamp reflector seq _ _ _ _ _ dl_owd_ms ul_owd_ms
	do 
		t_start_us=${EPOCHREALTIME/./}

		dl_owd_us=${dl_owd_ms}000
		ul_owd_us=${ul_owd_ms}000
	
		dl_alpha=$(( (( dl_owd_us >= dl_owd_baselines_us[${reflector}] )) ? alpha_baseline_increase : alpha_baseline_decrease ))
		ul_alpha=$(( (( ul_owd_us >= ul_owd_baselines_us[${reflector}] )) ? alpha_baseline_increase : alpha_baseline_decrease ))

		ewma_iteration "${dl_owd_us}" "${dl_alpha}" "dl_owd_baselines_us[${reflector}]"
		ewma_iteration "${ul_owd_us}" "${ul_alpha}" "ul_owd_baselines_us[${reflector}]"

		dl_owd_delta_us=$(( dl_owd_us - dl_owd_baselines_us[${reflector}] ))
		ul_owd_delta_us=$(( ul_owd_us - ul_owd_baselines_us[${reflector}] ))

		concurrent_read_integer dl_load_percent "${run_path}/dl_load_percent"
		concurrent_read_integer ul_load_percent "${run_path}/ul_load_percent"

		if (( dl_load_percent < high_load_thr_percent && ul_load_percent < high_load_thr_percent)); then
			ewma_iteration "${dl_owd_delta_us}" "${alpha_delta_ewma}" "dl_owd_delta_ewmas_us[${reflector}]"
			ewma_iteration "${ul_owd_delta_us}" "${alpha_delta_ewma}" "ul_owd_delta_ewmas_us[${reflector}]"
		fi

		timestamp=${timestamp//[\[\]]}0

		printf '%s %s %s %s %s %s %s %s %s %s %s\n' "${timestamp}" "${reflector}" "${seq}" "${dl_owd_baselines_us[${reflector}]}" "${dl_owd_us}" "${dl_owd_delta_ewmas_us[${reflector}]}" "${dl_owd_delta_us}" "${ul_owd_baselines_us[${reflector}]}" "${ul_owd_us}" "${ul_owd_delta_ewmas_us[${reflector}]}" "${ul_owd_delta_us}" >&"${ping_fd}"

		timestamp_us=${timestamp//[.]}

		printf '%s' "${timestamp_us}" > "${run_path}/reflector_${reflector//./-}_last_timestamp_us"
	
		printf '%s' "${dl_owd_baselines_us[${reflector}]}" > "${run_path}/reflector_${reflector//./-}_dl_owd_baseline_us"
		printf '%s' "${ul_owd_baselines_us[${reflector}]}" > "${run_path}/reflector_${reflector//./-}_ul_owd_baseline_us"
	
		printf '%s' "${dl_owd_delta_ewmas_us[${reflector}]}" > "${run_path}/reflector_${reflector//./-}_dl_owd_delta_ewma_us"
		printf '%s' "${ul_owd_delta_ewmas_us[${reflector}]}" > "${run_path}/reflector_${reflector//./-}_ul_owd_delta_ewma_us"

		printf '%s' "${timestamp_us}" > "${run_path}/reflectors_last_timestamp_us"

	done
}

# FPING FUNCTIONS # 

kill_monitor_reflector_responses_fping()
{
	trap - TERM EXIT

	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	# Store baselines and ewmas to files ready for next instance (e.g. after sleep)
	for (( reflector=0; reflector<no_reflectors; reflector++ ))
	do
		[[ -n "${rtt_baselines_us[${reflectors[reflector]}]}" ]] && printf '%s' "${rtt_baselines_us[${reflectors[reflector]}]}" > "${run_path}/reflector_${reflectors[reflector]//./-}_baseline_us"
		[[ -n "${rtt_delta_ewmas_us[${reflectors[reflector]}]}" ]] && printf '%s' "${rtt_delta_ewmas_us[${reflectors[reflector]}]}" > "${run_path}/reflector_${reflectors[reflector]//./-}_delta_ewma_us"
	done

	exit
}

monitor_reflector_responses_fping()
{
	trap '' INT
	trap kill_monitor_reflector_responses_fping TERM EXIT		

	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	declare -A rtt_baselines_us
	declare -A rtt_delta_ewmas_us

	t_start_us=${EPOCHREALTIME/./}

	# Read in baselines if they exist, else just set them to 1s (rapidly converges downwards on new RTTs)
	for (( reflector=0; reflector < no_reflectors; reflector++ ))
	do
		if [[ -f "${run_path}/reflector_${reflectors[reflector]//./-}_baseline_us" ]]; then
			read -r "rtt_baselines_us[${reflectors[reflector]}]" < "${run_path}/reflector_${reflectors[reflector]//./-}_baseline_us"
		else
			rtt_baselines_us[${reflectors[reflector]}]=100000
		fi
		if [[ -f "${run_path}/reflector_${reflectors[reflector]//./-}_delta_ewma_us" ]]; then
			read -r "rtt_delta_ewmas_us[${reflectors[reflector]}]" < "${run_path}/reflector_${reflectors[reflector]//./-}_delta_ewma_us"
		else
			rtt_delta_ewmas_us[${reflectors[reflector]}]=0
		fi
	done

	# shellcheck disable=SC2154
	while read -r -u "${pinger_fds[pinger]}" timestamp reflector _ seq_rtt 2>/dev/null
	do 
		t_start_us=${EPOCHREALTIME/./}

		[[ ${seq_rtt} =~ \[([0-9]+)\].*[[:space:]]([0-9]+)\.?([0-9]+)?[[:space:]]ms ]] || continue

		seq=${BASH_REMATCH[1]}

		rtt_us=${BASH_REMATCH[3]}000
		rtt_us=$((${BASH_REMATCH[2]}000+10#${rtt_us:0:3}))

		alpha=$(( (( rtt_us >= rtt_baselines_us[${reflector}] )) ? alpha_baseline_increase : alpha_baseline_decrease ))

		ewma_iteration "${rtt_us}" "${alpha}" "rtt_baselines_us[${reflector}]"

		rtt_delta_us=$(( rtt_us-rtt_baselines_us[${reflector}] ))

		concurrent_read_integer dl_load_percent "${run_path}/dl_load_percent"
		concurrent_read_integer ul_load_percent "${run_path}/ul_load_percent"

		if (( dl_load_percent < high_load_thr_percent && ul_load_percent < high_load_thr_percent)); then
			ewma_iteration "${rtt_delta_us}" "${alpha_delta_ewma}" "rtt_delta_ewmas_us[${reflector}]"
		fi

		dl_owd_baseline_us=$((rtt_baselines_us[${reflector}]/2))
		ul_owd_baseline_us=${dl_owd_baseline_us}

		dl_owd_delta_ewma_us=$((rtt_delta_ewmas_us[${reflector}]/2))
		ul_owd_delta_ewma_us=${dl_owd_delta_ewma_us}

		dl_owd_us=$((rtt_us/2))
		ul_owd_us=${dl_owd_us}

		dl_owd_delta_us=$((rtt_delta_us/2))
		ul_owd_delta_us=${dl_owd_delta_us}
	
		timestamp=${timestamp//[\[\]]}0

		printf '%s %s %s %s %s %s %s %s %s %s %s\n' "${timestamp}" "${reflector}" "${seq}" "${dl_owd_baseline_us}" "${dl_owd_us}" "${dl_owd_delta_ewma_us}" "${dl_owd_delta_us}" "${ul_owd_baseline_us}" "${ul_owd_us}" "${ul_owd_delta_ewma_us}" "${ul_owd_delta_us}" >&"${ping_fd}"

		timestamp_us=${timestamp//[.]}

		printf '%s' "${timestamp_us}" > "${run_path}/reflector_${reflector//./-}_last_timestamp_us"
	
		printf '%s' "${dl_owd_baseline_us}" > "${run_path}/reflector_${reflector//./-}_dl_owd_baseline_us"
		printf '%s' "${ul_owd_baseline_us}" > "${run_path}/reflector_${reflector//./-}_ul_owd_baseline_us"
	
		printf '%s' "${dl_owd_delta_ewma_us}" > "${run_path}/reflector_${reflector//./-}_dl_owd_delta_ewma_us"
		printf '%s' "${ul_owd_delta_ewma_us}" > "${run_path}/reflector_${reflector//./-}_ul_owd_delta_ewma_us"

		printf '%s' "${timestamp_us}" > "${run_path}/reflectors_last_timestamp_us"

	done 2>/dev/null
}

# IPUTILS-PING FUNCTIONS

kill_monitor_reflector_responses_ping()
{
	trap - TERM EXIT
	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"
	[[ -n "${rtt_baseline_us:-}" ]] && printf '%s' "${rtt_baseline_us}" > "${run_path}/reflector_${reflectors[pinger]//./-}_baseline_us"
	[[ -n "${rtt_delta_ewma_us:-}" ]] && printf '%s' "${rtt_delta_ewma_us}" > "${run_path}/reflector_${reflectors[pinger]//./-}_delta_ewma_us"
	exit
}

monitor_reflector_responses_ping() 
{
	trap '' INT
	trap kill_monitor_reflector_responses_ping TERM EXIT		

	# ping reflector, maintain baseline and output deltas to a common fifo

	local pinger=${1}
	
	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	if [[ -f "${run_path}/reflector_${reflectors[pinger]//./-}_baseline_us" ]]; then
			read -r rtt_baseline_us < "${run_path}/reflector_${reflectors[pinger]//./-}_baseline_us"
	else
			rtt_baseline_us=100000
	fi

	if [[ -f "${run_path}/reflector_${reflectors[pinger]//./-}_delta_ewma_us" ]]; then
			read -r rtt_delta_ewma_us < "${run_path}/reflector_${reflectors[pinger]//./-}_delta_ewma_us"
	else
			rtt_delta_ewma_us=0
	fi

	while read -r -u "${pinger_fds[pinger]}" timestamp _ _ _ reflector seq_rtt 2>/dev/null
	do
		# If no match then skip onto the next one
		[[ ${seq_rtt} =~ icmp_[s|r]eq=([0-9]+).*time=([0-9]+)\.?([0-9]+)?[[:space:]]ms ]] || continue

		seq=${BASH_REMATCH[1]}

		rtt_us=${BASH_REMATCH[3]}000
		rtt_us=$((${BASH_REMATCH[2]}000+10#${rtt_us:0:3}))

		reflector=${reflector//:/}

		alpha=$(( (( rtt_us >= rtt_baseline_us )) ? alpha_baseline_increase : alpha_baseline_decrease ))

		ewma_iteration "${rtt_us}" "${alpha}" rtt_baseline_us
	
		rtt_delta_us=$(( rtt_us-rtt_baseline_us ))

		concurrent_read_integer dl_load_percent "${run_path}/dl_load_percent"
		concurrent_read_integer ul_load_percent "${run_path}/ul_load_percent"

		if (( dl_load_percent < high_load_thr_percent && ul_load_percent < high_load_thr_percent )); then
			ewma_iteration "${rtt_delta_us}" "${alpha_delta_ewma}" rtt_delta_ewma_us
		fi

		dl_owd_baseline_us=$((rtt_baseline_us/2))
		ul_owd_baseline_us=${dl_owd_baseline_us}

		dl_owd_delta_ewma_us=$((rtt_delta_ewma_us/2))
		ul_owd_delta_ewma_us=${dl_owd_delta_ewma_us}

		dl_owd_us=$((rtt_us/2))
		ul_owd_us=${dl_owd_us}

		dl_owd_delta_us=$((rtt_delta_us/2))
		ul_owd_delta_us=${dl_owd_delta_us}	

		timestamp=${timestamp//[\[\]]}

		printf '%s %s %s %s %s %s %s %s %s %s %s\n' "${timestamp}" "${reflector}" "${seq}" "${dl_owd_baseline_us}" "${dl_owd_us}" "${dl_owd_delta_ewma_us}" "${dl_owd_delta_us}" "${ul_owd_baseline_us}" "${ul_owd_us}" "${ul_owd_delta_ewma_us}" "${ul_owd_delta_us}" >&"${ping_fd}"
	
		timestamp_us=${timestamp//[.]}

		printf '%s' "${timestamp_us}" > "${run_path}/reflector_${reflector//./-}_last_timestamp_us"
	
		printf '%s' "${dl_owd_baseline_us}" > "${run_path}/reflector_${reflector//./-}_dl_owd_baseline_us"
		printf '%s' "${ul_owd_baseline_us}" > "${run_path}/reflector_${reflector//./-}_ul_owd_baseline_us"
	
		printf '%s' "${dl_owd_delta_ewma_us}" > "${run_path}/reflector_${reflector//./-}_dl_owd_delta_ewma_us"
		printf '%s' "${ul_owd_delta_ewma_us}" > "${run_path}/reflector_${reflector//./-}_ul_owd_delta_ewma_us"

		printf '%s' "${timestamp_us}" > "${run_path}/reflectors_last_timestamp_us"

	done 2>/dev/null
}

# END OF IPUTILS-PING FUNCTIONS

# GENERIC PINGER START AND STOP FUNCTIONS

start_pinger()
{
	local pinger=${1}

	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	# shellcheck disable=SC1083,SC2086,SC2261
	case ${pinger_binary} in

		tsping)
			pinger=0
			exec {pinger_fds[pinger]}<> <(:) || true
			proc_man_start "pinger_${pinger}" ${ping_prefix_string} tsping ${ping_extra_args} --print-timestamps --machine-readable=' ' --sleep-time "0" --target-spacing "${ping_response_interval_ms}" "${reflectors[@]:0:${no_pingers}}" 2> /dev/null >&"${pinger_fds[pinger]}"
			;;	
		fping)
			pinger=0
			exec {pinger_fds[pinger]}<> <(:) || true
			proc_man_start "pinger_${pinger}" ${ping_prefix_string} fping ${ping_extra_args} --timestamp --loop --period "${reflector_ping_interval_ms}" --interval "${ping_response_interval_ms}" --timeout 10000 "${reflectors[@]:0:${no_pingers}}" 2> /dev/null >&"${pinger_fds[pinger]}"
			;;
		ping)
			exec {pinger_fds[pinger]}<> <(:) || true
			sleep_until_next_pinger_time_slot "${pinger}"
			proc_man_start "pinger_${pinger}" ${ping_prefix_string} ping ${ping_extra_args} -D -i "${reflector_ping_interval_s}" "${reflectors[pinger]}" 2> /dev/null >&"${pinger_fds[pinger]}"
			;;
		*)
			log_msg "ERROR" "Unknown pinger binary: ${pinger_binary}"
			exit 1
			;;
	esac
	
	proc_man_start "monitor_${pinger}" "monitor_reflector_responses_${pinger_binary}" "${pinger}"
}

start_pingers()
{
	# Initiate pingers
	log_msg "DEBUG" "Starting pingers."
	case ${pinger_binary} in

		tsping|fping)
			start_pinger 0
		;;
		ping)
			for ((pinger=0; pinger < no_pingers; pinger++))
			do
				start_pinger "${pinger}"
			done
		;;
		*)
			log_msg "ERROR" "Unknown pinger binary: ${pinger_binary}"
			exit 1
		;;
	esac
}

sleep_until_next_pinger_time_slot()
{
	# wait until next pinger time slot and start pinger in its slot
	# this allows pingers to be stopped and started (e.g. during sleep or reflector rotation)
	# whilst ensuring pings will remain spaced out appropriately to maintain granularity

	local pinger=${1}
	
	t_start_us=${EPOCHREALTIME/./}
	time_to_next_time_slot_us=$(( (reflector_ping_interval_us-(t_start_us-pingers_t_start_us)%reflector_ping_interval_us) + pinger*ping_response_interval_us ))
	sleep_remaining_tick_time "${t_start_us}" "${time_to_next_time_slot_us}"
}

kill_pinger()
{
	local pinger=${1}
	
	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	case ${pinger_binary} in
		tsping|fping)
			pinger=0
			;;

		*)
			:
			;;
	esac

	proc_man_stop "pinger_${pinger}"
	proc_man_stop "monitor_${pinger}"

	# shellcheck disable=SC1083
	exec {pinger_fds[pinger]}<&-
}

kill_pingers()
{
	case ${pinger_binary} in

		tsping|fping)
			log_msg "DEBUG" "Killing ${pinger_binary} instance."
			kill_pinger 0
			;;
		ping)
			for (( pinger=0; pinger < no_pingers; pinger++))
			do
				log_msg "DEBUG" "Killing pinger instance: ${pinger}"
				kill_pinger "${pinger}"
			done
			;;
		*)
			log_msg "ERROR" "Unknown pinger binary: ${pinger_binary}"
			exit 1
			;;
	esac
}

replace_pinger_reflector()
{
	# pingers always use reflectors[0]..[no_pingers-1] as the initial set
	# and the additional reflectors are spare reflectors should any from initial set go stale
	# a bad reflector in the initial set is replaced with ${reflectors[no_pingers]}
	# ${reflectors[no_pingers]} is then unset
	# and the the bad reflector moved to the back of the queue (last element in ${reflectors[]})
	# and finally the indices for ${reflectors} are updated to reflect the new order
	
	local pinger=${1}
	
	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	lock "${run_path}/replace_pinger_reflector_lock"

	if ((no_reflectors > no_pingers)); then
		log_msg "DEBUG" "replacing reflector: ${reflectors[pinger]} with ${reflectors[no_pingers]}."
		kill_pinger "${pinger}"
		bad_reflector=${reflectors[pinger]}
		# overwrite the bad reflector with the reflector that is next in the queue (the one after 0..${no_pingers}-1)
		reflectors[pinger]=${reflectors[no_pingers]}
		# remove the new reflector from the list of additional reflectors beginning from ${reflectors[no_pingers]}
		unset "reflectors[no_pingers]"
		# bad reflector goes to the back of the queue
		reflectors+=("${bad_reflector}")
		# reset array indices
		mapfile -t reflectors < <(for i in "${reflectors[@]}"; do printf '%s\n' "${i}"; done)
		# set up the new pinger with the new reflector and retain pid	
		start_pinger "${pinger}"
	else
		log_msg "DEBUG" "No additional reflectors specified so just retaining: ${reflectors[pinger]}."
		reflector_offences[pinger]=0
	fi
	
	unlock "${run_path}/replace_pinger_reflector_lock"
}

# END OF GENERIC PINGER START AND STOP FUNCTIONS

kill_maintain_pingers()
{
	trap - TERM EXIT

	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	lock "${run_path}/replace_pinger_reflector_lock"

	log_msg "DEBUG" "Terminating maintain_pingers."

	kill_pingers

	unlock "${run_path}/replace_pinger_reflector_lock"

	exit
}

change_state_maintain_pingers()
{
	local maintain_pingers_next_state=${1:-unset}

	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	if [[ "${maintain_pingers_next_state}" == "unset" ]]; then
		if [[ -f "${run_path}/maintain_pingers_next_state" ]]; then
			for ((read_try=1; read_try<11; read_try++))
			do
				read -r maintain_pingers_next_state < "${run_path}/maintain_pingers_next_state"
				maintain_pingers_next_state=${maintain_pingers_next_state:-unset}
				[[ "${maintain_pingers_next_state}" != "unset" ]] && break
			done
		else
			log_msg "ERROR" "Received change signal but ${run_path}/maintain_pingers_next_state does not exist. Exiting now."
			kill -INT $$
		fi
	fi

	case ${maintain_pingers_next_state} in

		START|STOP|PAUSED|RUNNING)
		
			if [[ "${maintain_pingers_state}" != "${maintain_pingers_next_state}" ]]
			then
				log_msg "DEBUG" "Changing maintain_pingers state from: ${maintain_pingers_state} to: ${maintain_pingers_next_state}"
				maintain_pingers_state=${maintain_pingers_next_state}
				printf "%s" ${maintain_pingers_state} > ${run_path}/maintain_pingers_state
			else
				log_msg "ERROR" "Received request to change maintain_pingers state to existing state."
			fi
			;;

		*)
	
			log_msg "ERROR" "Received unrecognized state change request: ${maintain_pingers_next_state}. Exiting now."
			kill -INT $$
			;;
	esac
}

maintain_pingers()
{
	# this initiates the pingers and monitors reflector health, rotating reflectors as necessary

 	trap '' INT
	trap 'kill_maintain_pingers' TERM EXIT
	
	trap 'change_state_maintain_pingers' USR1

	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	declare -A dl_owd_baselines_us
	declare -A ul_owd_baselines_us
	declare -A dl_owd_delta_ewmas_us
	declare -A ul_owd_delta_ewmas_us

	err_silence=0
	reflector_offences_idx=0
	pingers_active=0

	pingers_t_start_us=${EPOCHREALTIME/./}	
	t_last_reflector_replacement_us=${EPOCHREALTIME/./}	
	t_last_reflector_comparison_us=${EPOCHREALTIME/./}	

	for ((reflector=0; reflector < no_reflectors; reflector++))
	do
		printf '%s' "${pingers_t_start_us}" > "${run_path}/reflector_${reflectors[reflector]//./-}_last_timestamp_us"
	done
	
	printf '%s' "${pingers_t_start_us}" > "${run_path}/reflectors_last_timestamp_us"

	# For each pinger initialize record of offences
	for ((pinger=0; pinger < no_pingers; pinger++))
	do
		# shellcheck disable=SC2178
		declare -n reflector_offences="reflector_${pinger}_offences"
		for ((i=0; i<reflector_misbehaving_detection_window; i++)) do reflector_offences[i]=0; done
		sum_reflector_offences[pinger]=0
	done

	maintain_pingers_state="START"

	# Reflector maintenance loop - verifies reflectors have not gone stale and rotates reflectors as necessary
	while true
	do
		case ${maintain_pingers_state} in

			START)
				if ((pingers_active==0))
				then
					start_pingers
					pingers_active=1
				fi
				change_state_maintain_pingers "RUNNING"
				;;

			STOP)
				if ((pingers_active))
				then
					kill_pingers
					pingers_active=0
				fi
				change_state_maintain_pingers "PAUSED"
				;;
			
			PAUSED)
				;;
			
			RUNNING)
				if (( ${EPOCHREALTIME/./}>(t_last_reflector_replacement_us+reflector_replacement_interval_mins*60*1000000))); then
	
					log_msg "DEBUG" "reflector: ${reflectors[pinger]} randomly selected for replacement."
					replace_pinger_reflector $((RANDOM%no_pingers))
					t_last_reflector_replacement_us=${EPOCHREALTIME/./}	
					continue
				fi

				if (( ${EPOCHREALTIME/./}>(t_last_reflector_comparison_us+reflector_comparison_interval_mins*60*1000000) )); then

					t_last_reflector_comparison_us=${EPOCHREALTIME/./}	

					concurrent_read_integer dl_min_owd_baseline_us "${run_path}/reflector_${reflectors[0]//./-}_dl_owd_baseline_us" 0 || continue
					concurrent_read_integer dl_min_owd_delta_ewma_us "${run_path}/reflector_${reflectors[0]//./-}_dl_owd_delta_ewma_us" 0 || continue
					concurrent_read_integer ul_min_owd_baseline_us "${run_path}/reflector_${reflectors[0]//./-}_ul_owd_baseline_us" 0 || continue
					concurrent_read_integer ul_min_owd_delta_ewma_us "${run_path}/reflector_${reflectors[0]//./-}_ul_owd_delta_ewma_us" 0 || continue
				
					concurrent_read_integer compensated_dl_delay_thr_us "${run_path}/compensated_dl_delay_thr_us"
					concurrent_read_integer compensated_ul_delay_thr_us "${run_path}/compensated_ul_delay_thr_us"

					for ((pinger=0; pinger < no_pingers; pinger++))
					do
						concurrent_read_integer "dl_owd_baselines_us[${reflectors[pinger]}]" "${run_path}/reflector_${reflectors[pinger]//./-}_dl_owd_baseline_us" 0 || continue 2
						concurrent_read_integer "dl_owd_delta_ewmas_us[${reflectors[pinger]}]" "${run_path}/reflector_${reflectors[pinger]//./-}_dl_owd_delta_ewma_us" 0 || continue 2
						concurrent_read_integer "ul_owd_baselines_us[${reflectors[pinger]}]" "${run_path}/reflector_${reflectors[pinger]//./-}_ul_owd_baseline_us" 0 || continue 2
						concurrent_read_integer "ul_owd_delta_ewmas_us[${reflectors[pinger]}]" "${run_path}/reflector_${reflectors[pinger]//./-}_ul_owd_delta_ewma_us" 0 || continue 2
					
						((   dl_owd_baselines_us[${reflectors[pinger]}] < dl_min_owd_baseline_us   )) && dl_min_owd_baseline_us="${dl_owd_baselines_us[${reflectors[pinger]}]}"
						(( dl_owd_delta_ewmas_us[${reflectors[pinger]}] < dl_min_owd_delta_ewma_us )) && dl_min_owd_delta_ewma_us="${dl_owd_delta_ewmas_us[${reflectors[pinger]}]}"
						((   ul_owd_baselines_us[${reflectors[pinger]}] < ul_min_owd_baseline_us   )) && ul_min_owd_baseline_us="${ul_owd_baselines_us[${reflectors[pinger]}]}"
						(( ul_owd_delta_ewmas_us[${reflectors[pinger]}] < ul_min_owd_delta_ewma_us )) && ul_min_owd_delta_ewma_us="${ul_owd_delta_ewmas_us[${reflectors[pinger]}]}"
					done

					for ((pinger=0; pinger < no_pingers; pinger++))
					do

						dl_owd_baseline_delta_us=$((   dl_owd_baselines_us[${reflectors[pinger]}]   - dl_min_owd_baseline_us   ))
						dl_owd_delta_ewma_delta_us=$(( dl_owd_delta_ewmas_us[${reflectors[pinger]}] - dl_min_owd_delta_ewma_us ))
						ul_owd_baseline_delta_us=$((   ul_owd_baselines_us[${reflectors[pinger]}]   - ul_min_owd_baseline_us   ))
						ul_owd_delta_ewma_delta_us=$(( ul_owd_delta_ewmas_us[${reflectors[pinger]}] - ul_min_owd_delta_ewma_us ))

						if ((output_reflector_stats)); then
							printf -v reflector_stats '%s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s' "${EPOCHREALTIME}" "${reflectors[pinger]}" "${dl_min_owd_baseline_us}" "${dl_owd_baselines_us[${reflectors[pinger]}]}" "${dl_owd_baseline_delta_us}" "${reflector_owd_baseline_delta_thr_us}" "${dl_min_owd_delta_ewma_us}" "${dl_owd_delta_ewmas_us[${reflectors[pinger]}]}" "${dl_owd_delta_ewma_delta_us}" "${reflector_owd_delta_ewma_delta_thr_us}" "${ul_min_owd_baseline_us}" "${ul_owd_baselines_us[${reflectors[pinger]}]}" "${ul_owd_baseline_delta_us}" "${reflector_owd_baseline_delta_thr_us}" "${ul_min_owd_delta_ewma_us}" "${ul_owd_delta_ewmas_us[${reflectors[pinger]}]}" "${ul_owd_delta_ewma_delta_us}" "${reflector_owd_delta_ewma_delta_thr_us}"
							log_msg "REFLECTOR" "${reflector_stats}"
						fi
	
						if (( dl_owd_baseline_delta_us > reflector_owd_baseline_delta_thr_us )); then
							log_msg "DEBUG" "Warning: reflector: ${reflectors[pinger]} dl_owd_baseline_us exceeds the minimum by set threshold."
							replace_pinger_reflector "${pinger}"
							continue 2
						fi

						if (( dl_owd_delta_ewma_delta_us > reflector_owd_delta_ewma_delta_thr_us )); then
							log_msg "DEBUG" "Warning: reflector: ${reflectors[pinger]} dl_owd_delta_ewma_us exceeds the minimum by set threshold."
							replace_pinger_reflector "${pinger}"
							continue 2
						fi
				
						if (( ul_owd_baseline_delta_us > reflector_owd_baseline_delta_thr_us )); then
							log_msg "DEBUG" "Warning: reflector: ${reflectors[pinger]} ul_owd_baseline_us exceeds the minimum by set threshold."
							replace_pinger_reflector "${pinger}"
							continue 2
						fi
	
						if (( ul_owd_delta_ewma_delta_us > reflector_owd_delta_ewma_delta_thr_us )); then
							log_msg "DEBUG" "Warning: reflector: ${reflectors[pinger]} ul_owd_delta_ewma_us exceeds the minimum by set threshold."
							replace_pinger_reflector "${pinger}"
							continue 2
						fi
					done

				fi

				enable_replace_pinger_reflector=1

				for ((pinger=0; pinger < no_pingers; pinger++))
				do
					reflector_check_time_us=${EPOCHREALTIME/./}
					concurrent_read_integer reflector_last_timestamp_us "${run_path}/reflector_${reflectors[pinger]//./-}_last_timestamp_us"
					# shellcheck disable=SC2178
					declare -n reflector_offences="reflector_${pinger}_offences"

					(( reflector_offences[reflector_offences_idx] )) && ((sum_reflector_offences[pinger]--))
					# shellcheck disable=SC2154
					reflector_offences[reflector_offences_idx]=$(( (((reflector_check_time_us-reflector_last_timestamp_us) > reflector_response_deadline_us)) ? 1 : 0 ))

					if (( reflector_offences[reflector_offences_idx] )); then 
						((sum_reflector_offences[pinger]++))
						log_msg "DEBUG" "no ping response from reflector: ${reflectors[pinger]} within reflector_response_deadline: ${reflector_response_deadline_s}s"
						log_msg "DEBUG" "reflector=${reflectors[pinger]}, sum_reflector_offences=${sum_reflector_offences[pinger]} and reflector_misbehaving_detection_thr=${reflector_misbehaving_detection_thr}"
					fi

					if (( sum_reflector_offences[pinger] >= reflector_misbehaving_detection_thr )); then

						log_msg "DEBUG" "Warning: reflector: ${reflectors[pinger]} seems to be misbehaving."
						if ((enable_replace_pinger_reflector)); then
							replace_pinger_reflector "${pinger}"
							for ((i=0; i<reflector_misbehaving_detection_window; i++)) do reflector_offences[i]=0; done
							sum_reflector_offences[pinger]=0
							enable_replace_pinger_reflector=0
						else
							log_msg "DEBUG" "Warning: skipping replacement of reflector: ${reflectors[pinger]} given prior replacement within this reflector health check cycle."
						fi
					fi		
				done
				((reflector_offences_idx=(reflector_offences_idx+1)%reflector_misbehaving_detection_window))
				;;
			*)
				log_msg "ERROR" "Unrecognized maintain pingers state: ${maintain_pingers_state}."
				log_msg "ERROR" "Setting state to RUNNING"
				maintain_pingers_next_state="RUNNING"
				change_maintain_pingers_state
			;;
		esac
		
		sleep_s "${reflector_health_check_interval_s}"
	done
}

set_cake_rate()
{
	local interface=${1}
	local shaper_rate_kbps=${2}
	local adjust_shaper_rate=${3}
	
	((output_cake_changes)) && log_msg "SHAPER" "tc qdisc change root dev ${interface} cake bandwidth ${shaper_rate_kbps}Kbit"

	if ((adjust_shaper_rate)); then

		if ((debug)); then
			tc qdisc change root dev "${interface}" cake bandwidth "${shaper_rate_kbps}Kbit"
		else
			tc qdisc change root dev "${interface}" cake bandwidth "${shaper_rate_kbps}Kbit" 2> /dev/null
		fi

	else
		((output_cake_changes)) && log_msg "DEBUG" "adjust_shaper_rate set to 0 in config, so skipping the tc qdisc change call"
	fi
}

set_shaper_rates()
{
	if (( dl_shaper_rate_kbps != last_dl_shaper_rate_kbps || ul_shaper_rate_kbps != last_ul_shaper_rate_kbps )); then 
     	
		# fire up tc in each direction if there are rates to change, and if rates change in either direction then update max wire calcs
		if (( dl_shaper_rate_kbps != last_dl_shaper_rate_kbps )); then 
			set_cake_rate "${dl_if}" "${dl_shaper_rate_kbps}" adjust_dl_shaper_rate
			printf '%s' "${dl_shaper_rate_kbps}" > "${run_path}/dl_shaper_rate_kbps"
		 	last_dl_shaper_rate_kbps=${dl_shaper_rate_kbps}
		fi
		if (( ul_shaper_rate_kbps != last_ul_shaper_rate_kbps )); then 
			set_cake_rate "${ul_if}" "${ul_shaper_rate_kbps}" adjust_ul_shaper_rate
			printf '%s' "${ul_shaper_rate_kbps}" > "${run_path}/ul_shaper_rate_kbps"
			last_ul_shaper_rate_kbps=${ul_shaper_rate_kbps}
		fi

		update_max_wire_packet_compensation
	fi
}

set_min_shaper_rates()
{
	log_msg "DEBUG" "Enforcing minimum shaper rates."
	dl_shaper_rate_kbps=${min_dl_shaper_rate_kbps}
	ul_shaper_rate_kbps=${min_ul_shaper_rate_kbps}
	set_shaper_rates
}

get_max_wire_packet_size_bits()
{
	local interface=${1}
	local -n max_wire_packet_size_bits=${2}
 
	read -r max_wire_packet_size_bits < "/sys/class/net/${interface}/mtu" 
	[[ $(tc qdisc show dev "${interface}" || true) =~ (atm|noatm)[[:space:]]overhead[[:space:]]([0-9]+) ]]
	[[ -n "${BASH_REMATCH[2]:-}" ]] && max_wire_packet_size_bits=$(( 8*(max_wire_packet_size_bits+BASH_REMATCH[2]) )) 
	# atm compensation = 53*ceil(X/48) bytes = 8*53*((X+8*(48-1)/(8*48)) bits = 424*((X+376)/384) bits
	[[ "${BASH_REMATCH[1]:-}" == "atm" ]] && max_wire_packet_size_bits=$(( 424*((max_wire_packet_size_bits+376)/384) ))
}

update_max_wire_packet_compensation()
{
	# Compensate for delays imposed by active traffic shaper
	# This will serve to increase the delay thr at rates below around 12Mbit/s

	# compensated OWD delay thresholds in microseconds
	compensated_dl_delay_thr_us=$(( dl_delay_thr_us + (1000*dl_max_wire_packet_size_bits)/dl_shaper_rate_kbps ))
	compensated_ul_delay_thr_us=$(( ul_delay_thr_us + (1000*ul_max_wire_packet_size_bits)/ul_shaper_rate_kbps ))
	
	printf '%s' "${compensated_dl_delay_thr_us}" > "${run_path}/compensated_dl_delay_thr_us"
	printf '%s' "${compensated_ul_delay_thr_us}" > "${run_path}/compensated_ul_delay_thr_us"

	# determine and write out ${max_wire_packet_rtt_us}
	max_wire_packet_rtt_us=$(( (1000*dl_max_wire_packet_size_bits)/dl_shaper_rate_kbps + (1000*ul_max_wire_packet_size_bits)/ul_shaper_rate_kbps ))
	printf '%s' "${max_wire_packet_rtt_us}" > "${run_path}/max_wire_packet_rtt_us"
}

concurrent_read_integer()
{
	# in the context of a single process that writes to a file and
	# a separate process that reads from the file, costly calls to 
	# the external flock binary can be avoided for the reason that
	# the read either reads in a blank value or the last true value
	# and so it is possible to just read, test and reread if necessary

	local -n value=${1}
 	local path=${2}
	local exit_on_no_file=${3:-1}

	if ! [[ -f ${path} ]]
	then
		if ((exit_on_no_file))
		then
			log_msg "ERROR" "Non-existent file at: ${path} and exit_on_no_file enabled. Exiting now."
			kill -$$ INT
		else
			log_msg "DEBUG" "Non-existent file at: ${path} but exit_on_no_file disabled. Returning 1."
			value=0
			return 1
		fi
	fi

	for ((read_try=1; read_try<11; read_try++))
	do
		read -r value < "${path}"
		value="${value:-unset}"

		# printf '%.0f' is used here to sanitize unsigned integers:
		# - it removes any leading zeros whilst preserving the sign; and
		# - it returns false if ${value} is not a number
		if printf -v sanitized_value '%.0f' "${value}" 2>/dev/null; then

			value=${sanitized_value}
			return 0

		else
			if ((debug)); then
				read -r caller_output< <(caller) || true
				log_msg "DEBUG" "concurrent_read_integer() misfire: ${read_try} of 10, with the following particulars:"
				log_msg "DEBUG" "caller=${caller_output}, value=${value} and path=${path}"
			fi
			sleep_us "${concurrent_read_integer_interval_us}"
			continue
		fi
	done

	if ((debug)); then
		read -r caller_output< <(caller) || true
		log_msg "ERROR" "If you see this, then please report these messages (ideally with log file)" 
		log_msg "ERROR" "at the cake-autorate forum of OpenWrt and/or at github.com/lynxthecat/cake-autorate"
		log_msg "ERROR" "concurrent_read_integer() 10x misfires, with the following particulars:"
		log_msg "ERROR" "caller=${caller_output}, value=${value} and path=${path}"
	fi 
	value=0
	return 1
}

verify_ifs_up()
{
	# Check the rx/tx paths exist and give extra time for ifb's to come up if needed
	# This will block if ifs never come up
	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	while [[ ! -f ${rx_bytes_path} || ! -f ${tx_bytes_path} ]]
	do
		[[ ! -f ${rx_bytes_path} ]] && log_msg "DEBUG" "Warning: The configured download interface: '${dl_if}' does not appear to be present. Waiting ${if_up_check_interval_s} seconds for the interface to come up." 
		[[ ! -f ${tx_bytes_path} ]] && log_msg "DEBUG" "Warning: The configured upload interface: '${ul_if}' does not appear to be present. Waiting ${if_up_check_interval_s} seconds for the interface to come up." 
		sleep_s "${if_up_check_interval_s}"
	done
}

ewma_iteration()
{
	local value=${1}
	local alpha=${2} # alpha must be scaled by factor of 1000000
	local -n ewma=${3}

	prev_ewma=${ewma}
	ewma=$(( (alpha*value+(1000000-alpha)*prev_ewma)/1000000 ))
}

# redirect stderr to log_msg and exit cake-autorate
intercept_stderr() 
{
	exec 2> >(
		while read -r error
		do
			log_msg "ERROR" "${error}"
			kill -INT $$
		done
	)
}

# Debug command wrapper
# Inspired by cmd_wrapper of sqm-script
debug_cmd()
{
	# Usage: debug_cmd debug_msg err_silence cmd arg1 arg2, etc.

	# Error messages are output as log_msg ERROR messages
	# Or set error_silence=1 to output errors as log_msg DEBUG messages

	local debug_msg=${1}
	local err_silence=${2}
	local cmd=${3}

	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	shift 3

	local args=("${@}")

	local caller_id
	local err_type

	local ret
	local stderr

	err_type="ERROR"

	if ((err_silence)); then
		err_type="DEBUG"
	fi

	stderr=$(${cmd} "${args[@]}" 2>&1)
	ret=${?}

	caller_id=$(caller)

	if ((ret==0)); then
		log_msg "DEBUG" "debug_cmd: err_silence=${err_silence}; debug_msg=${debug_msg}; caller_id=${caller_id}; command=${cmd} ${args[*]}; result=SUCCESS"
	else
		[[ "${err_type}" == "DEBUG" && "${debug}" == "0" ]] && return # if debug disabled, then skip on DEBUG but not on ERROR

		log_msg "${err_type}" "debug_cmd: err_silence=${err_silence}; debug_msg=${debug_msg}; caller_id=${caller_id}; command=${cmd} ${args[*]}; result=FAILURE (${ret})"
		log_msg "${err_type}" "debug_cmd: LAST ERROR (${stderr})"

		frame=1
		while caller_output=$(caller "${frame}")
		do
			log_msg "${err_type}" "debug_cmd: CALL CHAIN: ${caller_output}"
			((++frame))
		done
	fi
}

# ======= Start of the Main Routine ========

[[ -t 1 ]] && terminal=1 || terminal=0

type logger &> /dev/null && use_logger=1 || use_logger=0 # only perform the test once.

log_file_path=/var/log/cake-autorate.log

# *** WARNING: take great care if attempting to alter the run_path! ***
# *** cake-autorate issues mkdir -p ${run_path} and rm -r ${run_path} on exit. ***
run_path=/var/run/cake-autorate/

# cake-autorate first argument is config file path
if [[ -n ${1:-} ]]; then
	config_path=${1}
else
	config_path="$PREFIX/cake-autorate_config.primary.sh"
fi

if [[ ! -f "${config_path}" ]]; then
	log_msg "ERROR" "No config file found. Exiting now."
	exit
fi

# shellcheck source=cake-autorate_config.primary.sh
. "${config_path}"

if [[ ${config_file_check} != "cake-autorate" ]]; then
	log_msg "ERROR" "Config file error. Please check config file entries." 
	exit
fi

if [[ ${config_path} =~ cake-autorate_config\.(.*)\.sh ]]; then
	instance_id=${BASH_REMATCH[1]}
	run_path=/var/run/cake-autorate/${instance_id}
else
	log_msg "ERROR" "Instance identifier 'X' set by cake-autorate_config.X.sh cannot be empty. Exiting now."
	exit
fi

PROC_STATE_FILE="${run_path}/proc_state"
PROC_STATE_FILE_LOCK="${run_path}/proc_state.lock"

if [[ -n "${log_file_path_override:-}" ]]; then 
	if [[ ! -d ${log_file_path_override} ]]; then
		broken_log_file_path_override=${log_file_path_override}
		log_file_path=/var/log/cake-autorate${instance_id:+.${instance_id}}.log
		log_msg "ERROR" "Log file path override: '${broken_log_file_path_override}' does not exist. Exiting now."
		exit
	fi
	log_file_path=${log_file_path_override}/cake-autorate${instance_id:+.${instance_id}}.log
else
	log_file_path=/var/log/cake-autorate${instance_id:+.${instance_id}}.log
fi

rotate_log_file # rotate here to force header prints at top of log file

# Intercept stderr, redirect it to log_msg and exit cake-autorate
intercept_stderr

log_msg "SYSLOG" "Starting cake-autorate with PID: ${BASHPID} and config: ${config_path}"

# ${run_path}/ is used to store temporary files
# it should not exist on startup so if it does exit, else create the directory
if [[ -d "${run_path}" ]]; then
	if [[ -f "${run_path}/pid" ]] && [[ -d "/proc/$(<"${run_path}/pid")" ]]; then
		log_msg "ERROR" "${run_path} already exists and an instance may be running. Exiting script."
		trap - INT TERM EXIT
		exit
	else
		log_msg "DEBUG" "${run_path} already exists but no instance is running. Removing and recreating."
		rm -r "${run_path}"
		mkdir -p "${run_path}"
	fi
else
	mkdir -p "${run_path}"
fi

# Initialize proc_man
proc_man_initialize

printf "%s" "${BASHPID}" > "${run_path}/pid"

no_reflectors=${#reflectors[@]} 

# Check ping binary exists
command -v "${pinger_binary}" &> /dev/null || { log_msg "ERROR" "ping binary ${pinger_binary} does not exist. Exiting script."; exit; }

# Check no_pingers <= no_reflectors
(( no_pingers > no_reflectors )) && { log_msg "ERROR" "number of pingers cannot be greater than number of reflectors. Exiting script."; exit; }

# Check dl/if interface not the same
[[ "${dl_if}" == "${ul_if}" ]] && { log_msg "ERROR" "download interface and upload interface are both set to: '${dl_if}', but cannot be the same. Exiting script."; exit; }

# Check bufferbloat detection threshold not greater than window length
(( bufferbloat_detection_thr > bufferbloat_detection_window )) && { log_msg "ERROR" "bufferbloat_detection_thr cannot be greater than bufferbloat_detection_window. Exiting script."; exit; }

# Passed error checks 

if ((log_to_file)); then
	log_file_max_time_us=$((log_file_max_time_mins*60000000))
	log_file_max_size_bytes=$((log_file_max_size_KB*1024))
	exec {log_fd}<> <(:) || true
	proc_man_start "maintain_log_file" maintain_log_file
fi

# test if stdout is a tty (terminal)
if ! ((terminal)); then
	echo "stdout not a terminal so redirecting output to: ${log_file_path}"
	((log_to_file)) && exec 1>&"${log_fd}"
fi

# Initialize rx_bytes_path and tx_bytes_path if not set
if [[ -z "${rx_bytes_path:-}" ]]; then
	case "${dl_if}" in
		veth*)
			rx_bytes_path="/sys/class/net/${dl_if}/statistics/tx_bytes"
			;;
		ifb*)
			rx_bytes_path="/sys/class/net/${dl_if}/statistics/tx_bytes"
			;;
		*)
			rx_bytes_path="/sys/class/net/${dl_if}/statistics/tx_bytes"
			;;
	esac
fi
if [[ -z "${tx_bytes_path:-}" ]]; then
	case "${ul_if}" in
		veth*)
			tx_bytes_path="/sys/class/net/${ul_if}/statistics/rx_bytes"
			;;
		ifb*)
			tx_bytes_path="/sys/class/net/${ul_if}/statistics/rx_bytes"
			;;
		*)
			tx_bytes_path="/sys/class/net/${ul_if}/statistics/tx_bytes"
			;;
	esac
fi

if ((debug)) ; then
	log_msg "DEBUG" "CAKE-autorate version: ${cake_autorate_version}"
	log_msg "DEBUG" "config_path: ${config_path}"
	log_msg "DEBUG" "run_path: ${run_path}"
	log_msg "DEBUG" "log_file_path: ${log_file_path}"
	log_msg "DEBUG" "pinger_binary:${pinger_binary}"
	log_msg "DEBUG" "download interface: ${dl_if} (${min_dl_shaper_rate_kbps} / ${base_dl_shaper_rate_kbps} / ${max_dl_shaper_rate_kbps})"
	log_msg "DEBUG" "upload interface: ${ul_if} (${min_ul_shaper_rate_kbps} / ${base_ul_shaper_rate_kbps} / ${max_ul_shaper_rate_kbps})"
	log_msg "DEBUG" "rx_bytes_path: ${rx_bytes_path}"
	log_msg "DEBUG" "tx_bytes_path: ${tx_bytes_path}"
fi

# Check interfaces are up and wait if necessary for them to come up
verify_ifs_up

# Initialize variables

# Convert human readable parameters to values that work with integer arithmetic

printf -v dl_delay_thr_us %.0f "${dl_delay_thr_ms}e3"
printf -v ul_delay_thr_us %.0f "${ul_delay_thr_ms}e3"
printf -v alpha_baseline_increase %.0f "${alpha_baseline_increase}e6"
printf -v alpha_baseline_decrease %.0f "${alpha_baseline_decrease}e6"   
printf -v alpha_delta_ewma %.0f "${alpha_delta_ewma}e6"   
printf -v achieved_rate_adjust_down_bufferbloat %.0f "${achieved_rate_adjust_down_bufferbloat}e3"
printf -v shaper_rate_adjust_down_bufferbloat %.0f "${shaper_rate_adjust_down_bufferbloat}e3"
printf -v shaper_rate_adjust_up_load_high %.0f "${shaper_rate_adjust_up_load_high}e3"
printf -v shaper_rate_adjust_down_load_low %.0f "${shaper_rate_adjust_down_load_low}e3"
printf -v shaper_rate_adjust_up_load_low %.0f "${shaper_rate_adjust_up_load_low}e3"
printf -v high_load_thr_percent %.0f "${high_load_thr}e2"
printf -v reflector_ping_interval_ms %.0f "${reflector_ping_interval_s}e3"
printf -v reflector_ping_interval_us %.0f "${reflector_ping_interval_s}e6"
printf -v monitor_achieved_rates_interval_us %.0f "${monitor_achieved_rates_interval_ms}e3"
printf -v sustained_idle_sleep_thr_us %.0f "${sustained_idle_sleep_thr_s}e6"
printf -v reflector_response_deadline_us %.0f "${reflector_response_deadline_s}e6"
printf -v reflector_owd_baseline_delta_thr_us %.0f "${reflector_owd_baseline_delta_thr_ms}e3"
printf -v reflector_owd_delta_ewma_delta_thr_us %.0f "${reflector_owd_delta_ewma_delta_thr_ms}e3"
printf -v startup_wait_us %.0f "${startup_wait_s}e6"
printf -v global_ping_response_timeout_us %.0f "${global_ping_response_timeout_s}e6"
printf -v bufferbloat_refractory_period_us %.0f "${bufferbloat_refractory_period_ms}e3"
printf -v decay_refractory_period_us %.0f "${decay_refractory_period_ms}e3"

for (( i=0; i<${#sss_times_s[@]}; i++ ));
do
	printf -v sss_times_us[i] %.0f\\n "${sss_times_s[i]}e6"
done
printf -v sss_compensation_pre_duration_us %.0f "${sss_compensation_pre_duration_ms}e3"
printf -v sss_compensation_post_duration_us %.0f "${sss_compensation_post_duration_ms}e3"

ping_response_interval_us=$(( reflector_ping_interval_us/no_pingers ))
ping_response_interval_ms=$(( ping_response_interval_us/1000 ))

stall_detection_timeout_us=$(( stall_detection_thr*ping_response_interval_us ))
stall_detection_timeout_s=000000${stall_detection_timeout_us}
stall_detection_timeout_s=$(( 10#${stall_detection_timeout_s::-6})).${stall_detection_timeout_s: -6}

concurrent_read_integer_interval_us=$((ping_response_interval_us/4))

dl_shaper_rate_kbps=${base_dl_shaper_rate_kbps}
ul_shaper_rate_kbps=${base_ul_shaper_rate_kbps}

last_dl_shaper_rate_kbps=0
last_ul_shaper_rate_kbps=0

get_max_wire_packet_size_bits "${dl_if}" dl_max_wire_packet_size_bits  
get_max_wire_packet_size_bits "${ul_if}" ul_max_wire_packet_size_bits

set_shaper_rates

update_max_wire_packet_compensation

t_start_us=${EPOCHREALTIME/./}
t_end_us=${EPOCHREALTIME/./}

t_prev_ul_rate_set_us=${t_start_us}
t_prev_dl_rate_set_us=${t_start_us}
t_ul_last_bufferbloat_us=${t_start_us}
t_ul_last_decay_us=${t_start_us}
t_dl_last_bufferbloat_us=${t_start_us}
t_dl_last_decay_us=${t_start_us}

t_sustained_connection_idle_us=0

mapfile -t dl_delays < <(for ((i=1; i <= bufferbloat_detection_window; i++)); do echo 0; done)
mapfile -t ul_delays < <(for ((i=1; i <= bufferbloat_detection_window; i++)); do echo 0; done)

delays_idx=0
sum_dl_delays=0
sum_ul_delays=0

if ((debug)); then
	if (( bufferbloat_refractory_period_us < (bufferbloat_detection_window*ping_response_interval_us) )); then
		log_msg "DEBUG" "Warning: bufferbloat refractory period: ${bufferbloat_refractory_period_us} us."
		log_msg "DEBUG" "Warning: but expected time to overwrite samples in bufferbloat detection window is: $((bufferbloat_detection_window*ping_response_interval_us)) us." 
		log_msg "DEBUG" "Warning: Consider increasing bufferbloat refractory period or decreasing bufferbloat detection window."
	fi
	if (( reflector_response_deadline_us < 2*reflector_ping_interval_us )); then 
		log_msg "DEBUG" "Warning: reflector_response_deadline_s < 2*reflector_ping_interval_s"
		log_msg "DEBUG" "Warning: consider setting an increased reflector_response_deadline."
	fi
fi

# Randomize reflectors array providing randomize_reflectors set to 1
((randomize_reflectors)) && randomize_array reflectors

# Wait if ${startup_wait_s} > 0
if ((startup_wait_us>0)); then
        log_msg "DEBUG" "Waiting ${startup_wait_s} seconds before startup."
        sleep_us "${startup_wait_us}"
fi

# Initiate achieved rate monitor
proc_man_start monitor_achieved_rates monitor_achieved_rates "${rx_bytes_path}" "${tx_bytes_path}" "${monitor_achieved_rates_interval_us}"
	
printf '%s' "0" > "${run_path}/dl_load_percent"
printf '%s' "0" > "${run_path}/ul_load_percent"

proc_man_start maintain_pingers maintain_pingers

generate_log_file_exporter

log_msg "INFO" "Started cake-autorate with PID: ${BASHPID} and config: ${config_path}"

while true
do
	while read -r -t "${stall_detection_timeout_s}" -u "${ping_fd}" timestamp reflector seq dl_owd_baseline_us dl_owd_us dl_owd_delta_ewma_us dl_owd_delta_us ul_owd_baseline_us ul_owd_us ul_owd_delta_ewma_us ul_owd_delta_us
	do 
		t_start_us=${EPOCHREALTIME/./}
		if (( (t_start_us - 10#"${timestamp//[.]}")>500000 )); then
			log_msg "DEBUG" "processed response from [${reflector}] that is > 500ms old. Skipping." 
			continue
		fi

		# Keep track of number of dl delays across detection window
		# .. for download:
		(( dl_delays[delays_idx] )) && ((sum_dl_delays--))
		dl_delays[delays_idx]=$(( dl_owd_delta_us > compensated_dl_delay_thr_us ? 1 : 0 ))
		((dl_delays[delays_idx])) && ((sum_dl_delays++))
		# .. for upload
		(( ul_delays[delays_idx] )) && ((sum_ul_delays--))
		ul_delays[delays_idx]=$(( ul_owd_delta_us > compensated_ul_delay_thr_us ? 1 : 0 ))
		((ul_delays[delays_idx])) && ((sum_ul_delays++))
	 	# .. and move index on	
		(( delays_idx=(delays_idx+1)%bufferbloat_detection_window ))

		dl_bufferbloat_detected=$(( ((sum_dl_delays >= bufferbloat_detection_thr)) ? 1 : 0 ))
		ul_bufferbloat_detected=$(( ((sum_ul_delays >= bufferbloat_detection_thr)) ? 1 : 0 ))

		get_loads

		classify_load "${dl_load_percent}" "${dl_achieved_rate_kbps}" "${dl_bufferbloat_detected}" dl_load_condition
		classify_load "${ul_load_percent}" "${ul_achieved_rate_kbps}" "${ul_bufferbloat_detected}" ul_load_condition

		dl_load_condition="dl_"${dl_load_condition}
		ul_load_condition="ul_"${ul_load_condition}

		get_next_shaper_rate "${min_dl_shaper_rate_kbps}" "${base_dl_shaper_rate_kbps}" "${max_dl_shaper_rate_kbps}" "${dl_achieved_rate_kbps}" "${dl_load_condition}" "${t_start_us}" t_dl_last_bufferbloat_us t_dl_last_decay_us dl_shaper_rate_kbps
		get_next_shaper_rate "${min_ul_shaper_rate_kbps}" "${base_ul_shaper_rate_kbps}" "${max_ul_shaper_rate_kbps}" "${ul_achieved_rate_kbps}" "${ul_load_condition}" "${t_start_us}" t_ul_last_bufferbloat_us t_ul_last_decay_us ul_shaper_rate_kbps

		set_shaper_rates

		if (( output_processing_stats )); then 
			printf -v processing_stats '%s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s' "${EPOCHREALTIME}" "${dl_achieved_rate_kbps}" "${ul_achieved_rate_kbps}" "${dl_load_percent}" "${ul_load_percent}" "${timestamp}" "${reflector}" "${seq}" "${dl_owd_baseline_us}" "${dl_owd_us}" "${dl_owd_delta_ewma_us}" "${dl_owd_delta_us}" "${compensated_dl_delay_thr_us}" "${ul_owd_baseline_us}" "${ul_owd_us}" "${ul_owd_delta_ewma_us}" "${ul_owd_delta_us}" "${compensated_ul_delay_thr_us}" "${sum_dl_delays}" "${sum_ul_delays}" "${dl_load_condition}" "${ul_load_condition}" "${dl_shaper_rate_kbps}" "${ul_shaper_rate_kbps}"
			log_msg "DATA" "${processing_stats}"
		fi

		# If base rate is sustained, increment sustained base rate timer (and break out of processing loop if enough time passes)
		if (( enable_sleep_function )); then
			if [[ ${dl_load_condition} == *idle* && ${ul_load_condition} == *idle* ]]; then
				((t_sustained_connection_idle_us += (${EPOCHREALTIME/./}-t_end_us) ))
				((t_sustained_connection_idle_us > sustained_idle_sleep_thr_us)) && break
			else
				# reset timer
				t_sustained_connection_idle_us=0
			fi
		fi
		
		t_end_us=${EPOCHREALTIME/./}

	done

	# stall handling procedure
	# PIPESTATUS[0] == 142 corresponds with while loop timeout
	# i.e. no reflector responses within ${stall_detection_thr} * ${ping_response_interval_us}
	if (( PIPESTATUS[0] == 142 )); then

		log_msg "DEBUG" "Warning: no reflector response within: ${stall_detection_timeout_s} seconds. Checking for loads."

		get_loads

		log_msg "DEBUG" "load check is: ((${dl_achieved_rate_kbps} kbps > ${connection_stall_thr_kbps} kbps && ${ul_achieved_rate_kbps} kbps > ${connection_stall_thr_kbps} kbps))"

		# non-zero load so despite no reflector response within stall interval, the connection not considered to have stalled
		# and therefore resume normal operation
		if (( dl_achieved_rate_kbps > connection_stall_thr_kbps && ul_achieved_rate_kbps > connection_stall_thr_kbps )); then

			log_msg "DEBUG" "load above connection stall threshold so resuming normal operation."
			continue

		fi

		log_msg "DEBUG" "Warning: connection stall detection. Waiting for new ping or increased load"

		# save intial global reflector timestamp to check against for any new reflector response
		concurrent_read_integer initial_reflectors_last_timestamp_us "${run_path}/reflectors_last_timestamp_us"

		# update maintain_pingers state
		printf "PAUSED" > ${run_path}/maintain_pingers_next_state
		proc_man_signal maintain_pingers "USR1"

		t_connection_stall_time_us=${EPOCHREALTIME/./}

		global_ping_response_timeout=0

		# wait until load resumes or ping response received (or global reflector response timeout)
		while true
		do
			t_start_us=${EPOCHREALTIME/./}
			
			concurrent_read_integer new_reflectors_last_timestamp_us "${run_path}/reflectors_last_timestamp_us"
			get_loads

			# shellcheck disable=SC2154
			if (( new_reflectors_last_timestamp_us != initial_reflectors_last_timestamp_us || ( dl_achieved_rate_kbps > connection_stall_thr_kbps && ul_achieved_rate_kbps > connection_stall_thr_kbps) )); then

				log_msg "DEBUG" "Connection stall ended. Resuming normal operation."

				# update maintain_pingers state
				printf "RUNNING" > ${run_path}/maintain_pingers_next_state
				proc_man_signal maintain_pingers "USR1"

				# continue main loop (i.e. skip idle/global timeout handling below)
				continue 2
			fi

			sleep_remaining_tick_time "${t_start_us}" "${reflector_ping_interval_us}"

			if (( global_ping_response_timeout==0 && t_start_us > (t_connection_stall_time_us + global_ping_response_timeout_us - stall_detection_timeout_us) )); then 
				log_msg "SYSLOG" "Warning: Configured global ping response timeout: ${global_ping_response_timeout_s} seconds exceeded." 
				((min_shaper_rates_enforcement)) && set_min_shaper_rates
				global_ping_response_timeout=1
			fi
		done

	else
		log_msg "DEBUG" "Connection idle. Waiting for minimum load."
		((min_shaper_rates_enforcement)) && set_min_shaper_rates
	fi

	# update maintain_pingers state
	printf "STOP" > ${run_path}/maintain_pingers_next_state
	proc_man_signal maintain_pingers "USR1"

	# reset idle timer
	t_sustained_connection_idle_us=0

	# wait until load increases again
	while true
	do
		t_start_us=${EPOCHREALTIME/./}	
		get_loads

		if (( dl_achieved_rate_kbps > connection_active_thr_kbps || ul_achieved_rate_kbps > connection_active_thr_kbps )); then
			log_msg "DEBUG" "dl achieved rate: ${dl_achieved_rate_kbps} kbps or ul achieved rate: ${ul_achieved_rate_kbps} kbps exceeded connection active threshold: ${connection_active_thr_kbps} kbps. Resuming normal operation."
			break 
		fi
		sleep_remaining_tick_time "${t_start_us}" "${reflector_ping_interval_us}"
	done

	# update maintain_pingers state
	printf "START" > ${run_path}/maintain_pingers_next_state
	proc_man_signal maintain_pingers "USR1"
	
	t_end_us=${EPOCHREALTIME/./}
done
