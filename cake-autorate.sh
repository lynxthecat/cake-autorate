#!/usr/bin/env bash

# cake-autorate automatically adjusts CAKE bandwidth(s)
# in dependence on: a) receive and transmit transfer rates; and b) latency
# (or can just be used to monitor and log transfer rates and latency)

# requires: bash; and one of the supported ping binaries

# each cake-autorate instance must be configured using a corresponding config file

# Project homepage: https://github.com/lynxthecat/cake-autorate
# Licence details:  https://github.com/lynxthecat/cake-autorate/blob/master/LICENCE.md

# Author and maintainer: lynxthecat
# Contributors:  rany2; moeller0; richb-hanover

cake_autorate_version=3.2.0-PRERELEASE

## cake-autorate uses multiple asynchronous processes including:
## main - main process
## monitor_achieved_rates - monitor network transfer rates
## maintain_log_file - maintain and rotate log file
##
## IPC is facilitated via FIFOs in the form of anonymous pipes
## thereby to enable transferring data between processes

# Set the IFS to space and comma
IFS=" ,"

# Initialize file descriptors
## -1 signifies that the log file fd will not be used and
## that the log file will be written to directly
log_fd=-1
exec {main_fd}<> <(:)

# process pids are stored below in the form
# proc_pids['process_identifier']=${!}
declare -A proc_pids

# Bash correctness options
## Disable globbing (expansion of *).
set -f
## Forbid using unset variables.
set -u
## The exit status of a pipeline is the status of the last
## command to exit with a non-zero status, or zero if no
## command exited with a non-zero status.
set -o pipefail

## Errors are intercepted via intercept_stderr below
## and sent to the log file and system log

# Possible performance improvement
export LC_ALL=C

# Set SCRIPT_PREFIX and CONFIG_PREFIX
POSSIBLE_SCRIPT_PREFIXES=(
	"${CAKE_AUTORATE_SCRIPT_PREFIX:-}"   # User defined
	"/jffs/scripts/cake-autorate"        # Asuswrt-Merlin
	"/opt/cake-autorate"
	"/usr/lib/cake-autorate"
	"/root/cake-autorate"
)
for SCRIPT_PREFIX in "${POSSIBLE_SCRIPT_PREFIXES[@]}"
do
	[[ -d ${SCRIPT_PREFIX} ]] && break
done
if [[ -z ${SCRIPT_PREFIX} || ! -d ${SCRIPT_PREFIX} ]]
then
	printf "ERROR: Unable to find a working SCRIPT_PREFIX for cake-autorate. Exiting now.\n" >&2
	printf "ERROR: Please set the CAKE_AUTORATE_SCRIPT_PREFIX environment variable to the correct path.\n" >&2
	exit 1
fi
POSSIBLE_CONFIG_PREFIXES=(
	"${CAKE_AUTORATE_CONFIG_PREFIX:-}"   # User defined
	"/jffs/configs/cake-autorate"        # Asuswrt-Merlin
	"${SCRIPT_PREFIX}"                   # Default
)
for CONFIG_PREFIX in "${POSSIBLE_CONFIG_PREFIXES[@]}"
do
	[[ -d ${CONFIG_PREFIX} ]] && break
done
if [[ -z ${CONFIG_PREFIX} || ! -d ${CONFIG_PREFIX} ]]
then
	printf "ERROR: Unable to find a working CONFIG_PREFIX for cake-autorate. Exiting now.\n" >&2
	printf "ERROR: Please set the CAKE_AUTORATE_CONFIG_PREFIX environment variable to the correct path.\n" >&2
	exit 1
fi

# shellcheck source=lib.sh
. "${SCRIPT_PREFIX}/lib.sh"
# shellcheck source=defaults.sh
. "${SCRIPT_PREFIX}/defaults.sh"
# get valid config overrides
mapfile -t valid_config_entries < <(grep -E '^[^(#| )].*=' "${SCRIPT_PREFIX}/defaults.sh" | sed -e 's/[\t ]*\#.*//g' -e 's/=.*//g')

trap cleanup_and_killall INT TERM EXIT

cleanup_and_killall()
{	
	# Do not fail on error for this critical cleanup code
	set +e

	trap : INT TERM EXIT
	
	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"
	
	log_msg "INFO" "Stopping cake-autorate with PID: ${BASHPID} and config: ${config_path}"
	
	log_msg "INFO" "Killing all background processes and cleaning up temporary files."

	terminate "${proc_pids['monitor_achieved_rates']:-}"

	terminate "${pinger_pids[*]}"

	((terminate_maintain_log_file_timeout_ms=log_file_buffer_timeout_ms+500))
	terminate "${proc_pids['maintain_log_file']}" "${terminate_maintain_log_file_timeout_ms}"

	[[ -d ${run_path} ]] && rm -r "${run_path}"
	rmdir /var/run/cake-autorate 2>/dev/null

	# give some time for processes to gracefully exit
	sleep_s 1

	# terminate any processes that remain, save for main and intercept_stderr
	unset "proc_pids[main]"
	intercept_stderr_pid=${proc_pids[intercept_stderr]:-}
	if [[ -n ${intercept_stderr_pid} ]]
	then
		unset "proc_pids[intercept_stderr]"
	fi
	terminate "${proc_pids[*]}"

	# restore original stderr, and terminate intercept_stderr
	if [[ -n ${intercept_stderr_pid} ]]
	then
		exec 2>&"${original_stderr_fd}"
		terminate "${intercept_stderr_pid}"
	fi

	log_msg "SYSLOG" "Stopped cake-autorate with PID: ${BASHPID} and config: ${config_path}"

	trap - INT TERM EXIT
	exit
}

log_msg()
{
	# send logging message to terminal, log file fifo, log file and/or system logger

	local type=${1} msg=${2} instance_id=${instance_id:-"unknown"} log_timestamp=${EPOCHREALTIME}

	case ${type} in

		DEBUG)
			((debug == 0)) && return # skip over DEBUG messages where debug disabled
			((log_DEBUG_messages_to_syslog && use_logger)) && \
				logger -t "cake-autorate.${instance_id}" "${type}: ${log_timestamp} ${msg}"
			;;

		ERROR)
			((use_logger)) && \
				logger -t "cake-autorate.${instance_id}" "${type}: ${log_timestamp} ${msg}"
			;;

		SYSLOG)
			((use_logger)) && \
				logger -t "cake-autorate.${instance_id}" "INFO: ${log_timestamp} ${msg}"
			;;

		*)
			;;
	esac

	printf -v msg '%s; %(%F-%H:%M:%S)T; %s; %s\n' "${type}" -1 "${log_timestamp}" "${msg}"
	((terminal)) && printf '%s' "${msg}"

	# Output to the log file fifo if available (for rotation handling)
	# else output directly to the log file
	((log_to_file)) || return
	if (( log_fd >= 0 ))
	then
		printf '%s' "${msg}" >&"${log_fd}"
	else
		printf '%s' "${msg}" >> "${log_file_path}"
	fi
}

print_headers()
{
	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	if ((output_processing_stats))
	then
		header="DATA_HEADER; LOG_DATETIME; LOG_TIMESTAMP; PROC_TIME_US; DL_ACHIEVED_RATE_KBPS; UL_ACHIEVED_RATE_KBPS; DL_LOAD_PERCENT; UL_LOAD_PERCENT; ICMP_TIMESTAMP; REFLECTOR; SEQUENCE; DL_OWD_BASELINE; DL_OWD_US; DL_OWD_DELTA_EWMA_US; DL_OWD_DELTA_US; DL_ADJ_DELAY_THR; UL_OWD_BASELINE; UL_OWD_US; UL_OWD_DELTA_EWMA_US; UL_OWD_DELTA_US; UL_ADJ_DELAY_THR; DL_SUM_DELAYS; DL_AVG_OWD_DELTA_US; DL_ADJ_AVG_OWD_DELTA_THR_US; UL_SUM_DELAYS; UL_AVG_OWD_DELTA_US; UL_ADJ_AVG_OWD_DELTA_THR_US; DL_LOAD_CONDITION; UL_LOAD_CONDITION; CAKE_DL_RATE_KBPS; CAKE_UL_RATE_KBPS"
		((log_to_file)) && printf '%s\n' "${header}" >&${log_file_fd}
		((terminal)) && printf '%s\n' "${header}"
	fi

	if ((output_load_stats))
	then
		header="LOAD_HEADER; LOG_DATETIME; LOG_TIMESTAMP; PROC_TIME_US; DL_ACHIEVED_RATE_KBPS; UL_ACHIEVED_RATE_KBPS; CAKE_DL_RATE_KBPS; CAKE_UL_RATE_KBPS"
		((log_to_file)) && printf '%s\n' "${header}" >&${log_file_fd}
		((terminal)) && printf '%s\n' "${header}"
	fi

	if ((output_reflector_stats))
	then
		header="REFLECTOR_HEADER; LOG_DATETIME; LOG_TIMESTAMP; PROC_TIME_US; REFLECTOR; MIN_SUM_OWD_BASELINES_US; SUM_OWD_BASELINES_US; SUM_OWD_BASELINES_DELTA_US; SUM_OWD_BASELINES_DELTA_THR_US; MIN_DL_DELTA_EWMA_US; DL_DELTA_EWMA_US; DL_DELTA_EWMA_DELTA_US; DL_DELTA_EWMA_DELTA_THR; MIN_UL_DELTA_EWMA_US; UL_DELTA_EWMA_US; UL_DELTA_EWMA_DELTA_US; UL_DELTA_EWMA_DELTA_THR"
		((log_to_file)) && printf '%s\n' "${header}" >&${log_file_fd}
		((terminal)) && printf '%s\n' "${header}"
	fi

	if ((output_summary_stats))
	then
		header="SUMMARY_HEADER; LOG_DATETIME; LOG_TIMESTAMP; DL_ACHIEVED_RATE_KBPS; UL_ACHIEVED_RATE_KBPS; DL_SUM_DELAYS; UL_SUM_DELAYS; DL_AVG_OWD_DELTA_US; UL_AVG_OWD_DELTA_US; DL_LOAD_CONDITION; UL_LOAD_CONDITION; CAKE_DL_RATE_KBPS; CAKE_UL_RATE_KBPS"
		((log_to_file)) && printf '%s\n' "${header}" >&${log_file_fd}
		((terminal)) && printf '%s\n' "${header}"
	fi
}

# MAINTAIN_LOG_FILE + HELPER FUNCTIONS

rotate_log_file()
{
	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	[[ -f ${log_file_path} ]] || return
	cat "${log_file_path}" > "${log_file_path}.old"
	: > "${log_file_path}"
}

reset_log_file()
{
	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	rm -f "${log_file_path}.old"
	: > "${log_file_path}"
}

generate_log_file_scripts()
{
	cat > "${run_path}/log_file_export" <<- EOT
	#!${BASH}

	timeout_s=\${1:-20}

	if kill -USR1 "${proc_pids['maintain_log_file']}"
	then
		printf "Successfully signalled maintain_log_file process to request log file export.\n"
	else
		printf "ERROR: Failed to signal maintain_log_file process.\n" >&2
		exit 1
	fi
	rm -f "${run_path}/last_log_file_export"

	read_try=0

	while [[ ! -f "${run_path}/last_log_file_export" ]]
	do
		sleep 1
		if (( ++read_try >= \${timeout_s} ))
		then
			printf "ERROR: Timeout (\${timeout_s}s) reached before new log file export identified.\n" >&2
			exit 1
		fi
	done

	read -r log_file_export_path < "${run_path}/last_log_file_export"

	printf "Log file export complete.\n"

	printf "Log file available at location: "
	printf "\${log_file_export_path}\n"
	EOT

	cat > "${run_path}/log_file_reset" <<- EOT
	#!${BASH}

	if kill -USR2 "${proc_pids['maintain_log_file']}"
	then
		printf "Successfully signalled maintain_log_file process to request log file reset.\n"
	else
		printf "ERROR: Failed to signal maintain_log_file process.\n" >&2
		exit 1
	fi
	EOT

	chmod +x "${run_path}/log_file_export" "${run_path}/log_file_reset"
}

export_log_file()
{
	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	printf -v log_file_export_datetime '%(%Y_%m_%d_%H_%M_%S)T'
	log_file_export_path="${log_file_path/.log/_${log_file_export_datetime}.log}"
	log_msg "DEBUG" "Exporting log file with path: ${log_file_path/.log/_${log_file_export_datetime}.log}"

	flush_log_pipe

	# Now export with or without compression to the appropriate export path
	if ((log_file_export_compress))
	then
		log_file_export_path="${log_file_export_path}.gz"
		export_cmd=("gzip" "-c")
	else
		export_cmd=("cat")
	fi

	if [[ -f ${log_file_path}.old ]]
	then
		"${export_cmd[@]}" "${log_file_path}.old" > "${log_file_export_path}"
		"${export_cmd[@]}" "${log_file_path}" >> "${log_file_export_path}"
	else
		"${export_cmd[@]}" "${log_file_path}" > "${log_file_export_path}"
	fi
	printf '%s' "${log_file_export_path}" > "${run_path}/last_log_file_export"
}

flush_log_pipe()
{
	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"
	while read -r -t 0 -u "${log_fd}"
	do
		read -r -u "${log_fd}" log_line
		printf '%s\n' "${log_line}" >&${log_file_fd}
		((log_file_size_bytes+=${#log_line}))
	done
}

maintain_log_file()
{
	signal=""
	trap '' INT
	trap 'signal+=KILL' TERM EXIT
	trap 'signal+=EXPORT' USR1
	trap 'signal+=RESET' USR2

	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	printf -v log_file_buffer_timeout_s %.1f "${log_file_buffer_timeout_ms}e-3"

	while :
	do
		exec {log_file_fd}> "${log_file_path}"

		print_headers
		log_file_size_bytes=$(wc -c "${log_file_path}" 2>/dev/null | awk '{print $1}')
		log_file_size_bytes=${log_file_size_bytes:-0}

		t_log_file_start_s=${SECONDS}

		while :
		do
			read -r -N "${log_file_buffer_size_B}" -t "${log_file_buffer_timeout_s}" -u "${log_fd}" log_chunk
		
			printf '%s' "${log_chunk}" >&${log_file_fd}

			((log_file_size_bytes+=${#log_chunk}))

			# Verify log file time < configured maximum
			if (( SECONDS - t_log_file_start_s > log_file_max_time_s ))
			then
				log_msg "DEBUG" "log file maximum time: ${log_file_max_time_mins} minutes has elapsed so flushing and rotating log file."
				flush_log_pipe
				rotate_log_file
				break
			# Verify log file size < configured maximum
			elif (( log_file_size_bytes > log_file_max_size_bytes ))
			then
				((log_file_size_KB=log_file_size_bytes/1024))
				log_msg "DEBUG" "log file size: ${log_file_size_KB} KB has exceeded configured maximum: ${log_file_max_size_KB} KB so flushing and rotating log file."
				flush_log_pipe
				rotate_log_file
				break
			fi

			# Check for signals
			case ${signal-} in

				"")
					;;
				*KILL*)
					log_msg "DEBUG" "received log file kill signal so flushing log and exiting."
					flush_log_pipe
					trap - TERM EXIT
					exit
					;;
				*EXPORT*)
					log_msg "DEBUG" "received log file export signal so exporting log file."
					export_log_file
					signal="${signal//EXPORT}"
					;;
				*RESET*)
					log_msg "DEBUG" "received log file reset signal so flushing log and resetting log file."
					flush_log_pipe
					reset_log_file
					signal="${signal//RESET}"
					break
					;;
				*)
					signal=""
					log_msg "ERROR" "processed unknown signal(s): ${signal}."
					;;
			esac
		done

		exec {log_file_fd}>&-
	done
}

export_proc_pids()
{
	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	: > "${run_path}/proc_pids"
	for proc_pid in "${!proc_pids[@]}"
	do
		printf "%s=%s\n" "${proc_pid}" "${proc_pids[${proc_pid}]}" >> "${run_path}/proc_pids"
	done
}

monitor_achieved_rates()
{
	trap '' INT

	# track rx and tx bytes transfered and divide by time since last update
	# to determine achieved dl and ul transfer rates

	local rx_bytes_path=${1} tx_bytes_path=${2} monitor_achieved_rates_interval_us=${3}

	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	compensated_monitor_achieved_rates_interval_us=${monitor_achieved_rates_interval_us}

	{ read -r prev_rx_bytes < "${rx_bytes_path}"; } 2> /dev/null || prev_rx_bytes=0
	{ read -r prev_tx_bytes < "${tx_bytes_path}"; } 2> /dev/null || prev_tx_bytes=0

	sleep_duration_s=0 t_start_us=0

	declare -A achieved_rate_kbps load_percent

	while :
	do
		t_start_us=${EPOCHREALTIME/.}

		# read in rx/tx bytes file, and if this fails then set to prev_bytes
		# this addresses interfaces going down and back up
		{ read -r rx_bytes < "${rx_bytes_path}"; } 2> /dev/null || rx_bytes=${prev_rx_bytes}
		{ read -r tx_bytes < "${tx_bytes_path}"; } 2> /dev/null || tx_bytes=${prev_tx_bytes}

		((
			achieved_rate_kbps[dl] = 8000*(rx_bytes - prev_rx_bytes) / compensated_monitor_achieved_rates_interval_us,
			achieved_rate_kbps[ul] = 8000*(tx_bytes - prev_tx_bytes) / compensated_monitor_achieved_rates_interval_us,

			achieved_rate_kbps[dl]<0 && (achieved_rate_kbps[dl]=0),
			achieved_rate_kbps[ul]<0 && (achieved_rate_kbps[ul]=0),

			prev_rx_bytes=rx_bytes,
			prev_tx_bytes=tx_bytes,

			compensated_monitor_achieved_rates_interval_us = monitor_achieved_rates_interval_us>(10*max_wire_packet_rtt_us) ? monitor_achieved_rates_interval_us : 10*max_wire_packet_rtt_us
		))

		printf "SARS %s %s\n" "${achieved_rate_kbps[dl]}" "${achieved_rate_kbps[ul]}" >&${main_fd}

		sleep_remaining_tick_time "${t_start_us}" "${compensated_monitor_achieved_rates_interval_us}"
	done
}

# GENERIC PINGER START AND STOP FUNCTIONS

start_pinger()
{
	local pinger=${1}

	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	case ${pinger_binary} in

		tsping)
			# accommodate present tsping interval/sleep handling to prevent ping flood with only one pinger
			(( tsping_sleep_time = no_pingers == 1 ? ping_response_interval_ms : 0 ))
			${ping_prefix_string} tsping ${ping_extra_args} --print-timestamps --machine-readable=, --sleep-time "${tsping_sleep_time}" --target-spacing "${ping_response_interval_ms}" "${reflectors[@]:0:${no_pingers}}" 2>/dev/null >&"${main_fd}" &
			pinger_pids[0]=${!}
			proc_pids['tsping_pinger']=${pinger_pids[0]}
			;;
		fping)
			${ping_prefix_string} fping ${ping_extra_args} --timestamp --loop --period "${reflector_ping_interval_ms}" --interval "${ping_response_interval_ms}" --timeout 10000 "${reflectors[@]:0:${no_pingers}}" 2> /dev/null >&"${main_fd}" &
			pinger_pids[0]=${!}
			proc_pids['fping_pinger']=${pinger_pids[0]}
			;;
		ping)
			sleep_until_next_pinger_time_slot "${pinger}"
			${ping_prefix_string} ping ${ping_extra_args} -D -i "${reflector_ping_interval_s}" "${reflectors[pinger]}" 2> /dev/null >&"${main_fd}" &
			pinger_pids[pinger]=${!}
			proc_pids["ping_${pinger}_pinger"]=${pinger_pids[0]}
			;;
		*)
			log_msg "ERROR" "Unknown pinger binary: ${pinger_binary}"
			kill $$ 2>/dev/null
			;;
	esac

	export_proc_pids
}

start_pingers()
{
	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	((pingers_active)) && return
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
			kill $$ 2>/dev/null
			;;
	esac
	pingers_active=1
}

sleep_until_next_pinger_time_slot()
{
	# wait until next pinger time slot and start pinger in its slot
	# this allows pingers to be stopped and started (e.g. during sleep or reflector rotation)
	# whilst ensuring pings will remain spaced out appropriately to maintain granularity

	local pinger=${1}

	t_start_us=${EPOCHREALTIME/.}
	(( time_to_next_time_slot_us = (reflector_ping_interval_us-(t_start_us-pingers_t_start_us)%reflector_ping_interval_us) + pinger*ping_response_interval_us ))
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
			;;
	esac
	
	terminate "${pinger_pids[pinger]}"
}

stop_pingers()
{
	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	((pingers_active)) || return
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
			kill $$ 2>/dev/null
			;;
	esac
	pingers_active=0
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

	if ((no_reflectors > no_pingers))
	then
		log_msg "DEBUG" "replacing reflector: ${reflectors[pinger]} with ${reflectors[no_pingers]}."
		kill_pinger "${pinger}"
		bad_reflector=${reflectors[pinger]}
		# overwrite the bad reflector with the reflector that is next in the queue (the one after 0..${no_pingers}-1)
		reflectors[pinger]=${reflectors[no_pingers]}
		# remove the new reflector from the list of additional reflectors beginning from ${reflectors[no_pingers]}
		unset "reflectors[no_pingers]"
		# bad reflector goes to the back of the queue
		# shellcheck disable=SC2206
		reflectors+=(${bad_reflector})
		# reset array indices
		mapfile -t reflectors < <(for i in "${reflectors[@]}"; do printf '%s\n' "${i}"; done)
		# set up the new pinger with the new reflector and retain pid
		dl_owd_baselines_us[${reflectors[pinger]}]=${dl_owd_baselines_us[${reflectors[pinger]}]:-100000} \
		ul_owd_baselines_us[${reflectors[pinger]}]=${ul_owd_baselines_us[${reflectors[pinger]}]:-100000} \
		dl_owd_delta_ewmas_us[${reflectors[pinger]}]=${dl_owd_delta_ewmas_us[${reflectors[pinger]}]:-0} \
		ul_owd_delta_ewmas_us[${reflectors[pinger]}]=${ul_owd_delta_ewmas_us[${reflectors[pinger]}]:-0} \
		last_timestamp_reflectors_us[${reflectors[pinger]}]=${t_start_us}

		start_pinger "${pinger}"
	else
		log_msg "DEBUG" "No additional reflectors specified so just retaining: ${reflectors[pinger]}."
	fi

	log_msg "DEBUG" "Resetting reflector offences associated with reflector: ${reflectors[pinger]}."
	declare -n reflector_offences="reflector_${pinger}_offences"
	for ((i=0; i<reflector_misbehaving_detection_window; i++)) do reflector_offences[i]=0; done
	sum_reflector_offences[pinger]=0
}

# END OF GENERIC PINGER START AND STOP FUNCTIONS

set_shaper_rate()
{
	# Fire up tc and update max_wire_packet_compensation if there are rates to change for the given direction

	local direction=${1} # 'dl' or 'ul'

	(( shaper_rate_kbps[${direction}] != last_shaper_rate_kbps[${direction}] )) || return

	((output_cake_changes)) && log_msg "SHAPER" "tc qdisc change root dev ${interface[${direction}]} cake bandwidth ${shaper_rate_kbps[${direction}]}Kbit"

	if ((adjust_shaper_rate[${direction}]))
	then
		tc qdisc change root dev "${interface[${direction}]}" cake bandwidth "${shaper_rate_kbps[${direction}]}Kbit" 2> /dev/null
	else
		((output_cake_changes)) && log_msg "DEBUG" "adjust_${direction}_shaper_rate set to 0 in config, so skipping the corresponding tc qdisc change call."
	fi

	# Compensate for delays imposed by active traffic shaper
	# This will serve to increase the delay thr at rates below around 12Mbit/s
	((
		dl_compensation_us=(1000*dl_max_wire_packet_size_bits)/shaper_rate_kbps[dl],
		ul_compensation_us=(1000*ul_max_wire_packet_size_bits)/shaper_rate_kbps[ul],

		compensated_owd_delta_thr_us[dl]=dl_owd_delta_thr_us + dl_compensation_us,
		compensated_owd_delta_thr_us[ul]=ul_owd_delta_thr_us + ul_compensation_us,

		compensated_avg_owd_delta_thr_us[dl]=dl_avg_owd_delta_thr_us + dl_compensation_us,
		compensated_avg_owd_delta_thr_us[ul]=ul_avg_owd_delta_thr_us + ul_compensation_us,

		max_wire_packet_rtt_us=(1000*dl_max_wire_packet_size_bits)/shaper_rate_kbps[dl] + (1000*ul_max_wire_packet_size_bits)/shaper_rate_kbps[ul],

		last_shaper_rate_kbps[${direction}]=${shaper_rate_kbps[${direction}]}
	))
}

get_max_wire_packet_size_bits()
{
	local interface=${1}
	local -n max_wire_packet_size_bits=${2}

	read -r max_wire_packet_size_bits < "/sys/class/net/${interface:?}/mtu"
	[[ $(tc qdisc show dev "${interface}") =~ (atm|noatm)[[:space:]]overhead[[:space:]]([0-9]+) ]]
	(( max_wire_packet_size_bits=8*(max_wire_packet_size_bits+BASH_REMATCH[2]) ))
	# atm compensation = 53*ceil(X/48) bytes = 8*53*((X+8*(48-1)/(8*48)) bits = 424*((X+376)/384) bits
	[[ ${BASH_REMATCH[1]:-} == "atm" ]] && (( max_wire_packet_size_bits=424*((max_wire_packet_size_bits+376)/384) ))
}

verify_ifs_up()
{
	# Check the rx/tx paths exist and give extra time for ifb's to come up if needed
	# This will block if ifs never come up
	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	while [[ ! -f ${rx_bytes_path} || ! -f ${tx_bytes_path} ]]
	do
		[[ -f ${rx_bytes_path} ]] || log_msg "DEBUG" "Warning: The configured download interface: '${dl_if}' does not appear to be present. Waiting ${if_up_check_interval_s} seconds for the interface to come up."
		[[ -f ${tx_bytes_path} ]] || log_msg "DEBUG" "Warning: The configured upload interface: '${ul_if}' does not appear to be present. Waiting ${if_up_check_interval_s} seconds for the interface to come up."
		sleep_s "${if_up_check_interval_s}"
	done
}

change_state_main()
{
	local main_next_state=${1}

	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	case ${main_next_state} in

		${main_state})
			log_msg "ERROR" "Received request to change main state to existing state."
			;;

		RUNNING|IDLE|STALL)

			log_msg "DEBUG" "Changing main state from: ${main_state} to: ${main_next_state}"
			main_state=${main_next_state}
			;;

		*)

			log_msg "ERROR" "Received unrecognized main state change request: ${main_next_state}. Exiting now."
			kill $$ 2>/dev/null
			;;
	esac
}

intercept_stderr()
{
	# send stderr to log_msg and exit cake-autorate
	# use with redirection: exec 2> >(intercept_stderr)

	while read -r error
	do
		log_msg "ERROR" "${error}"
		kill $$ 2>/dev/null
	done
}

# shellcheck disable=SC1090,SC2311
validate_config_entry() {
	# Must be called before loading config_path into the global scope.
	#
	# When the entry is invalid, two types are returned with the first type
	# being the invalid user type and second type is the default type with
	# the user needing to adapt the config file so that the entry uses the
	# default type.
	#
	# When the entry is valid, one type is returned and it will be the
	# the type of either the default or user type. However because in that
	# case they are both valid. It doesn't matter as they'd both have the
	# same type.

	local config_path=${1}

	local user_type
	local valid_type

	user_type=$(unset "${2}" && . "${config_path}" && typeof "${2}")
	valid_type=$(typeof "${2}")

	if [[ ${user_type} != "${valid_type}" ]]
	then
		printf '%s' "${user_type} ${valid_type}"
		return
	elif [[ ${user_type} != "string" ]]
	then
		printf '%s' "${valid_type}"
		return
	fi

	# extra validation for string, check for empty string
	local -n default_value=${2}
	local user_value
	user_value=$(. "${config_path}" && local -n x="${2}" && printf '%s' "${x}")

	# if user is empty but default is not, invalid entry
	if [[ -z ${user_value} && -n ${default_value} ]]
	then
		printf '%s' "${user_type} ${valid_type}"
	else
		printf '%s' "${valid_type}"
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
if [[ -n ${1-} ]]
then
	config_path="${1}"
else
	config_path="${CONFIG_PREFIX}/config.primary.sh"
fi

if [[ ! -f ${config_path} ]]
then
	log_msg "ERROR" "No config file found. Exiting now."
	exit 1
fi

# validate config entries before loading
mapfile -t user_config < <(grep -E '^[^(#| )].*=' "${config_path}" | sed -e 's/[\t ]*\#.*//g' -e 's/=.*//g')
config_error_count=0
for key in "${user_config[@]}"
do
	# Despite the fact that config_file_check is no longer required,
	# we make an exemption just in this case as that variable in
	# particular does not have any real impact to the operation
	# of the script.
	[[ ${key} == "config_file_check" ]] && continue

	# shellcheck disable=SC2076
	if [[ ! " ${valid_config_entries[*]} " =~ " ${key} " ]]
	then
		((config_error_count++))
		log_msg "ERROR" "The key: '${key}' in config file: '${config_path}' is not a valid config entry."
	else
		# shellcheck disable=SC2311
		read -r user supposed <<< "$(validate_config_entry "${config_path}" "${key}")"
		if [[ -n "${supposed}" ]]
		then
			error_msg="The value of '${key}' in config file: '${config_path}' is not a valid value of type: '${supposed}'."

			case ${user} in
				negative-*) error_msg="${error_msg} Also, negative numbers are not supported." ;;
				*) ;;
			esac

			log_msg "ERROR" "${error_msg}"
			unset error_msg

			((config_error_count++))
		fi
		unset user supposed
	fi
done
if ((config_error_count))
then
	log_msg "ERROR" "The config file: '${config_path}' contains ${config_error_count} error(s). Exiting now."
	exit 1
fi
unset valid_config_entries user_config config_error_count key

# shellcheck source=config.primary.sh
. "${config_path}"

if [[ ${config_path} =~ config\.(.*)\.sh ]]
then
	instance_id=${BASH_REMATCH[1]} run_path="/var/run/cake-autorate/${instance_id}"
else
	log_msg "ERROR" "Instance identifier 'X' set by config.X.sh cannot be empty. Exiting now."
	exit 1
fi

if [[ -n ${log_file_path_override-} ]]
then
	if [[ ! -d ${log_file_path_override} ]]
	then
		broken_log_file_path_override="${log_file_path_override}"
		log_file_path="/var/log/cake-autorate${instance_id:+.${instance_id}}.log"
		log_msg "ERROR" "Log file path override: '${broken_log_file_path_override}' does not exist. Exiting now."
		exit 1
	fi
	log_file_path="${log_file_path_override}/cake-autorate${instance_id:+.${instance_id}}.log"
else
	log_file_path="/var/log/cake-autorate${instance_id:+.${instance_id}}.log"
fi

rotate_log_file

# save stderr fd, redirect stderr to intercept_stderr
# intercept_stderr sends stderr to log_msg and exits cake-autorate
exec {original_stderr_fd}>&2 2> >(intercept_stderr)

proc_pids['intercept_stderr']=${!}

log_msg "SYSLOG" "Starting cake-autorate with PID: ${BASHPID} and config: ${config_path}"

# ${run_path}/ is used to store temporary files
# it should not exist on startup so if it does exit, else create the directory
if [[ -d ${run_path} ]]
then
	if [[ -f ${run_path}/proc_pids ]] && running_main_pid=$(awk -F= '/^main=/ {print $2}' "${run_path}/proc_pids") && [[ -d /proc/${running_main_pid} ]]
	then
		log_msg "ERROR" "${run_path} already exists and an instance appears to be running with main process pid ${running_main_pid}. Exiting script."
		trap - INT TERM EXIT
		exit 1
	else
		log_msg "DEBUG" "${run_path} already exists but no instance is running. Removing and recreating."
		rm -r "${run_path}"
		mkdir -p "${run_path}"
	fi
else
	mkdir -p "${run_path}"
fi

proc_pids['main']=${BASHPID}

no_reflectors=${#reflectors[@]}

# Check ping binary exists
command -v "${pinger_binary}" &> /dev/null || { log_msg "ERROR" "ping binary ${pinger_binary} does not exist. Exiting script."; exit 1; }

# Check no_pingers <= no_reflectors
(( no_pingers > no_reflectors )) && { log_msg "ERROR" "number of pingers cannot be greater than number of reflectors. Exiting script."; exit 1; }

# Check dl/if interface not the same
[[ "${dl_if}" == "${ul_if}" ]] && { log_msg "ERROR" "download interface and upload interface are both set to: '${dl_if}', but cannot be the same. Exiting script."; exit 1; }

# Check bufferbloat detection threshold not greater than window length
(( bufferbloat_detection_thr > bufferbloat_detection_window )) && { log_msg "ERROR" "bufferbloat_detection_thr cannot be greater than bufferbloat_detection_window. Exiting script."; exit 1; }

# Check if connection_active_thr_kbps is greater than min dl/ul shaper rate
(( connection_active_thr_kbps > min_dl_shaper_rate_kbps )) && { log_msg "ERROR" "connection_active_thr_kbps cannot be greater than min_dl_shaper_rate_kbps. Exiting script."; exit 1; }
(( connection_active_thr_kbps > min_ul_shaper_rate_kbps )) && { log_msg "ERROR" "connection_active_thr_kbps cannot be greater than min_ul_shaper_rate_kbps. Exiting script."; exit 1; }

# Passed error checks

if ((log_to_file))
then
	((
		log_file_max_time_s=log_file_max_time_mins*60,
		log_file_max_size_bytes=log_file_max_size_KB*1024
	))
	exec {log_fd}<> <(:)
	maintain_log_file &
	proc_pids['maintain_log_file']=${!}
fi

# test if stdout is a tty (terminal)
if ! ((terminal))
then
	echo "stdout not a terminal so redirecting output to: ${log_file_path}"
	((log_to_file)) && exec 1>&${log_fd}
fi

# Initialize rx_bytes_path and tx_bytes_path if not set
if [[ -z ${rx_bytes_path-} ]]
then
	case ${dl_if} in
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
if [[ -z ${tx_bytes_path-} ]]
then
	case ${ul_if} in
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

if ((debug))
then
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

printf -v dl_owd_delta_thr_us %.0f "${dl_owd_delta_thr_ms}e3"
printf -v ul_owd_delta_thr_us %.0f "${ul_owd_delta_thr_ms}e3"
printf -v dl_avg_owd_delta_thr_us %.0f "${dl_avg_owd_delta_thr_ms}e3"
printf -v ul_avg_owd_delta_thr_us %.0f "${ul_avg_owd_delta_thr_ms}e3"
printf -v alpha_baseline_increase %.0f "${alpha_baseline_increase}e6"
printf -v alpha_baseline_decrease %.0f "${alpha_baseline_decrease}e6"
printf -v alpha_delta_ewma %.0f "${alpha_delta_ewma}e6"
printf -v shaper_rate_min_adjust_down_bufferbloat %.0f "${shaper_rate_min_adjust_down_bufferbloat}e3"
printf -v shaper_rate_max_adjust_down_bufferbloat %.0f "${shaper_rate_max_adjust_down_bufferbloat}e3"
printf -v shaper_rate_adjust_up_load_high %.0f "${shaper_rate_adjust_up_load_high}e3"
printf -v shaper_rate_adjust_down_load_low %.0f "${shaper_rate_adjust_down_load_low}e3"
printf -v shaper_rate_adjust_up_load_low %.0f "${shaper_rate_adjust_up_load_low}e3"
printf -v high_load_thr_percent %.0f "${high_load_thr}e2"
printf -v reflector_ping_interval_ms %.0f "${reflector_ping_interval_s}e3"
printf -v reflector_ping_interval_us %.0f "${reflector_ping_interval_s}e6"
printf -v reflector_health_check_interval_us %.0f "${reflector_health_check_interval_s}e6"
printf -v monitor_achieved_rates_interval_us %.0f "${monitor_achieved_rates_interval_ms}e3"
printf -v sustained_idle_sleep_thr_us %.0f "${sustained_idle_sleep_thr_s}e6"
printf -v reflector_response_deadline_us %.0f "${reflector_response_deadline_s}e6"
printf -v reflector_sum_owd_baselines_delta_thr_us %.0f "${reflector_sum_owd_baselines_delta_thr_ms}e3"
printf -v reflector_owd_delta_ewma_delta_thr_us %.0f "${reflector_owd_delta_ewma_delta_thr_ms}e3"
printf -v startup_wait_us %.0f "${startup_wait_s}e6"
printf -v global_ping_response_timeout_us %.0f "${global_ping_response_timeout_s}e6"
printf -v bufferbloat_refractory_period_us %.0f "${bufferbloat_refractory_period_ms}e3"
printf -v decay_refractory_period_us %.0f "${decay_refractory_period_ms}e3"

((
	reflector_replacement_interval_us=reflector_replacement_interval_mins*60*1000000,
	reflector_comparison_interval_us=reflector_comparison_interval_mins*60*1000000,

	ping_response_interval_us=reflector_ping_interval_us/no_pingers,
	ping_response_interval_ms=ping_response_interval_us/1000,

	stall_detection_timeout_us=stall_detection_thr*ping_response_interval_us
))

printf -v stall_detection_timeout_s %.1f "${stall_detection_timeout_us}"

declare -A achieved_rate_kbps \
achieved_rate_updated \
bufferbloat_detected \
load_percent \
load_condition \
t_last_bufferbloat_us \
t_last_decay_us \
shaper_rate_kbps \
last_shaper_rate_kbps \
base_shaper_rate_kbps \
min_shaper_rate_kbps \
max_shaper_rate_kbps \
interface \
adjust_shaper_rate \
avg_owd_delta_us \
avg_owd_delta_thr_us \
compensated_owd_delta_thr_us \
compensated_avg_owd_delta_thr_us \
dl_owd_baselines_us \
ul_owd_baselines_us \
dl_owd_delta_ewmas_us \
ul_owd_delta_ewmas_us \
last_timestamp_reflectors_us

base_shaper_rate_kbps[dl]=${base_dl_shaper_rate_kbps} base_shaper_rate_kbps[ul]=${base_ul_shaper_rate_kbps} \
min_shaper_rate_kbps[dl]=${min_dl_shaper_rate_kbps} min_shaper_rate_kbps[ul]=${min_ul_shaper_rate_kbps} \
max_shaper_rate_kbps[dl]=${max_dl_shaper_rate_kbps} max_shaper_rate_kbps[ul]=${max_ul_shaper_rate_kbps} \
shaper_rate_kbps[dl]=${base_dl_shaper_rate_kbps} shaper_rate_kbps[ul]=${base_ul_shaper_rate_kbps} \
achieved_rate_kbps[dl]=0 achieved_rate_kbps[ul]=0 \
achieved_rate_updated[dl]=0 achieved_rate_updated[ul]=0 \
last_shaper_rate_kbps[dl]=0 last_shaper_rate_kbps[ul]=0 \
interface[dl]=${dl_if} interface[ul]=${ul_if} \
adjust_shaper_rate[dl]=${adjust_dl_shaper_rate} adjust_shaper_rate[ul]=${adjust_ul_shaper_rate} \
dl_max_wire_packet_size_bits=0 ul_max_wire_packet_size_bits=0

get_max_wire_packet_size_bits "${dl_if}" dl_max_wire_packet_size_bits
get_max_wire_packet_size_bits "${ul_if}" ul_max_wire_packet_size_bits

avg_owd_delta_us[dl]=0 avg_owd_delta_us[ul]=0

# shellcheck disable=SC2034
avg_owd_delta_thr_us[dl]=${dl_avg_owd_delta_thr_us} avg_owd_delta_thr_us[ul]=${ul_avg_owd_delta_thr_us}

set_shaper_rate "dl"
set_shaper_rate "ul"

dl_rate_load_condition="idle" ul_rate_load_condition="idle"

mapfile -t dl_delays < <(for ((i=0; i < bufferbloat_detection_window; i++)); do echo 0; done)
mapfile -t ul_delays < <(for ((i=0; i < bufferbloat_detection_window; i++)); do echo 0; done)
mapfile -t dl_owd_deltas_us < <(for ((i=0; i < bufferbloat_detection_window; i++)); do echo 0; done)
mapfile -t ul_owd_deltas_us < <(for ((i=0; i < bufferbloat_detection_window; i++)); do echo 0; done)

delays_idx=0 sum_dl_delays=0 sum_ul_delays=0 sum_dl_owd_deltas_us=0 sum_ul_owd_deltas_us=0

# Randomize reflectors array providing randomize_reflectors set to 1
((randomize_reflectors)) && randomize_array reflectors

for (( reflector=0; reflector<no_pingers; reflector++ ))
do
	dl_owd_baselines_us["${reflectors[reflector]}"]=100000 ul_owd_baselines_us["${reflectors[reflector]}"]=100000 \
	dl_owd_delta_ewmas_us["${reflectors[reflector]}"]=0 ul_owd_delta_ewmas_us["${reflectors[reflector]}"]=0
done

load_percent[dl]=0 load_percent[ul]=0
 
if ((debug))
then
	if (( bufferbloat_refractory_period_us < (bufferbloat_detection_window*ping_response_interval_us) ))
	then
		log_msg "DEBUG" "Warning: bufferbloat refractory period: ${bufferbloat_refractory_period_us} us."
		log_msg "DEBUG" "Warning: but expected time to overwrite samples in bufferbloat detection window is: $((bufferbloat_detection_window*ping_response_interval_us)) us."
		log_msg "DEBUG" "Warning: Consider increasing bufferbloat refractory period or decreasing bufferbloat detection window."
	fi
	if (( reflector_response_deadline_us < 2*reflector_ping_interval_us ))
	then
		log_msg "DEBUG" "Warning: reflector_response_deadline_s < 2*reflector_ping_interval_s"
		log_msg "DEBUG" "Warning: consider setting an increased reflector_response_deadline."
	fi
fi

sustained_connection_idle=0 reflector_offences_idx=0 pingers_active=0

monitor_achieved_rates "${rx_bytes_path}" "${tx_bytes_path}" "${monitor_achieved_rates_interval_us}" &
proc_pids['monitor_achieved_rates']=${!}

export_proc_pids

((log_to_file)) && generate_log_file_scripts

# Wait if ${startup_wait_s} > 0
if ((startup_wait_us>0))
then
	log_msg "DEBUG" "Waiting ${startup_wait_s} seconds before startup."
	sleep_us "${startup_wait_us}"
fi

t_start_us=${EPOCHREALTIME/.} \
t_last_bufferbloat_us[dl]=${t_start_us} t_last_bufferbloat_us[ul]=${t_start_us} \
t_last_decay_us[dl]=${t_start_us} t_last_decay_us[ul]=${t_start_us} \
t_last_reflector_health_check_us=${t_start_us} \
t_sustained_connection_idle_us=0 t_last_connection_idle_us=${t_start_us} reflectors_last_timestamp_us=${t_start_us} \
pingers_t_start_us=${t_start_us} t_last_reflector_replacement_us=${t_start_us} t_last_reflector_comparison_us=${t_start_us}

for ((reflector=0; reflector < no_reflectors; reflector++))
do
	last_timestamp_reflectors_us[${reflectors[reflector]}]=${t_start_us}
done

# For each pinger initialize record of offences
for ((pinger=0; pinger < no_pingers; pinger++))
do
	# shellcheck disable=SC2178
	declare -n reflector_offences=reflector_${pinger}_offences
	for ((i=0; i<reflector_misbehaving_detection_window; i++)) do reflector_offences[i]=0; done
	sum_reflector_offences[pinger]=0
done

main_state="RUNNING"

start_pingers

log_msg "INFO" "Started cake-autorate with PID: ${BASHPID} and config: ${config_path}"

while :
do
	unset command
	reflector_response=0
	read -r -u "${main_fd}" -a command
	((${#command[@]})) || continue

	case ${command[0]} in

		# Set download and upload achieved rates
		SARS)
			if ((${#command[@]} == 3))
			then
				achieved_rate_kbps[dl]=${command[1]} achieved_rate_kbps[ul]=${command[2]} achieved_rate_updated[dl]=1 achieved_rate_updated[ul]=1

				if ((output_load_stats))
				then
					printf -v load_stats '%s; %s; %s; %s; %s' "${EPOCHREALTIME}" "${achieved_rate_kbps[dl]}" "${achieved_rate_kbps[ul]}" "${shaper_rate_kbps[dl]}" "${shaper_rate_kbps[ul]}"
					log_msg "LOAD" "${load_stats}"
				fi

				if (( load_percent[dl] > high_load_thr_percent ))
				then
					dl_rate_load_condition="dl_high"
				elif (( achieved_rate_kbps[dl] > connection_active_thr_kbps ))
				then
					dl_rate_load_condition="dl_low"
				else
					dl_rate_load_condition="dl_idle"
				fi

				if (( load_percent[ul] > high_load_thr_percent ))
				then
					ul_rate_load_condition="ul_high"
				elif (( achieved_rate_kbps[ul] > connection_active_thr_kbps ))
				then
					ul_rate_load_condition="ul_low"
				else
					ul_rate_load_condition="ul_idle"
				fi
			fi
			;;
		*)
			case "${pinger_binary}" in

				tsping)
					if ((${#command[@]} == 10))
					then
						timestamp=${command[0]} reflector=${command[1]} seq=${command[2]} dl_owd_ms=${command[8]} ul_owd_ms=${command[9]} reflector_response=1
					fi
					;;
				fping)
					if ((${#command[@]} == 12))
					then
						timestamp=${command[0]} reflector=${command[1]} seq=${command[3]} rtt_ms=${command[6]} reflector_response=1
					fi
					;;
				ping)
					if ((${#command[@]} == 9))
					then
						timestamp=${command[0]} reflector=${command[4]} seq=${command[5]} rtt_ms=${command[7]} reflector_response=1
					fi
					;;
				*)
					log_msg "ERROR" "Unknown pinger binary: ${pinger_binary}"
					kill $$ 2>/dev/null
				;;
			esac
			;;
	esac

	t_start_us=${EPOCHREALTIME/.}

	case ${main_state} in

		RUNNING)
			if ((reflector_response))
			then
				# parse pinger response according to pinger binary
				case ${pinger_binary} in
					tsping)
						dl_owd_us=${dl_owd_ms}000 ul_owd_us=${ul_owd_ms}000

						((
							dl_owd_delta_us=dl_owd_us - dl_owd_baselines_us[${reflector}],
							ul_owd_delta_us=ul_owd_us - ul_owd_baselines_us[${reflector}]
						))

						# tsping employs ICMP type 13 and works with timestamps: Originate; Received; Transmit; and Finished, such that:
						#
						# dl_owd_us = Finished - Transmit
						# ul_owd_us = Received - Originate
						#
						# The timestamps are supposed to relate to milliseconds past midnight UTC, albeit implementation varies, and,
						# in any case, timestamps rollover at the local and/or remote ends, and the rollover may not be synchronized.
						#
						# Such an event would result in a huge spike in dl_owd_us or ul_owd_us and a lare delta relative to the baseline.
						#
						# So, to compensate, in the event that delta > 50 mins, immediately reset the baselines to the new dl_owd_us and ul_owd_us.
						#
						# Happilly, the sum of dl_owd_baseline_us and ul_owd_baseline_us will roughly equal rtt_baseline_us.
						# And since Transmit is approximately equal to Received, RTT is approximately equal to Finished - Originate.
						# And thus the sum of dl_owd_baseline_us and ul_owd_baseline_us should not be affected by the rollover/compensation.
						# Hence working with this sum, rather than the individual components, is useful for the reflector health check.

						if (( (${dl_owd_delta_us#-} + ${ul_owd_delta_us#-}) < 3000000000 ))
						then

							((
								dl_alpha = dl_owd_us >= dl_owd_baselines_us[${reflector}] ? alpha_baseline_increase : alpha_baseline_decrease,
								ul_alpha = ul_owd_us >= ul_owd_baselines_us[${reflector}] ? alpha_baseline_increase : alpha_baseline_decrease,

								dl_owd_baselines_us[${reflector}]=(dl_alpha*dl_owd_us+(1000000-dl_alpha)*dl_owd_baselines_us[${reflector}])/1000000,
								ul_owd_baselines_us[${reflector}]=(ul_alpha*ul_owd_us+(1000000-ul_alpha)*ul_owd_baselines_us[${reflector}])/1000000,

								dl_owd_delta_us=dl_owd_us - dl_owd_baselines_us[${reflector}],
								ul_owd_delta_us=ul_owd_us - ul_owd_baselines_us[${reflector}]
							))
						else
							dl_owd_baselines_us[${reflector}]=${dl_owd_us} ul_owd_baselines_us[${reflector}]=${ul_owd_us} dl_owd_delta_us=0 ul_owd_delta_us=0
						fi

						if (( load_percent[dl] < high_load_thr_percent && load_percent[ul] < high_load_thr_percent))
						then
							((
								dl_owd_delta_ewmas_us[${reflector}]=(alpha_delta_ewma*dl_owd_delta_us+(1000000-alpha_delta_ewma)*dl_owd_delta_ewmas_us[${reflector}])/1000000,
								ul_owd_delta_ewmas_us[${reflector}]=(alpha_delta_ewma*ul_owd_delta_us+(1000000-alpha_delta_ewma)*ul_owd_delta_ewmas_us[${reflector}])/1000000
							))
						fi

						timestamp_us=${timestamp//[.]}

						;;
					fping)
						seq=${seq//[\[\]]}
						printf -v rtt_us %.3f "${rtt_ms}"

						((
							dl_owd_us=10#${rtt_us//.}/2,
							ul_owd_us=dl_owd_us,
							dl_alpha = dl_owd_us >= dl_owd_baselines_us[${reflector}] ? alpha_baseline_increase : alpha_baseline_decrease,

							dl_owd_baselines_us[${reflector}]=(dl_alpha*dl_owd_us+(1000000-dl_alpha)*dl_owd_baselines_us[${reflector}])/1000000,
							ul_owd_baselines_us[${reflector}]=dl_owd_baselines_us[${reflector}],

							dl_owd_delta_us=dl_owd_us - dl_owd_baselines_us[${reflector}],
							ul_owd_delta_us=dl_owd_delta_us
						))

						if (( load_percent[dl] < high_load_thr_percent && load_percent[ul] < high_load_thr_percent))
						then
							((
								dl_owd_delta_ewmas_us[${reflector}]=(alpha_delta_ewma*dl_owd_delta_us+(1000000-alpha_delta_ewma)*dl_owd_delta_ewmas_us[${reflector}])/1000000,
								ul_owd_delta_ewmas_us[${reflector}]=dl_owd_delta_ewmas_us[${reflector}]
							))
						fi

						timestamp_us=${timestamp//[\[\].]}0

						;;
					ping)
						reflector=${reflector//:/} seq=${seq//icmp_seq=} rtt_ms=${rtt_ms//time=}

						printf -v rtt_us %.3f "${rtt_ms}"

						((
							dl_owd_us=10#${rtt_us//.}/2,
							ul_owd_us=dl_owd_us,

							dl_alpha = dl_owd_us >= dl_owd_baselines_us[${reflector}] ? alpha_baseline_increase : alpha_baseline_decrease,

							dl_owd_baselines_us[${reflector}]=(dl_alpha*dl_owd_us+(1000000-dl_alpha)*dl_owd_baselines_us[${reflector}])/1000000,
							ul_owd_baselines_us[${reflector}]=dl_owd_baselines_us[${reflector}],

							dl_owd_delta_us=dl_owd_us - dl_owd_baselines_us[${reflector}],
							ul_owd_delta_us=dl_owd_delta_us
						))

						if (( load_percent[dl] < high_load_thr_percent && load_percent[ul] < high_load_thr_percent))
						then
							((
								dl_owd_delta_ewmas_us[${reflector}]=(alpha_delta_ewma*dl_owd_delta_us+(1000000-alpha_delta_ewma)*dl_owd_delta_ewmas_us[${reflector}])/1000000,
								ul_owd_delta_ewmas_us[${reflector}]=dl_owd_delta_ewmas_us[${reflector}]
							))
						fi

						timestamp_us=${timestamp//[\[\].]}

						;;
					*)
						log_msg "ERROR" "Unknown pinger binary: ${pinger_binary}"
						exit 1
						;;
				esac

				last_timestamp_reflectors_us[${reflector}]=${timestamp_us} reflectors_last_timestamp_us=${timestamp_us}

				if (( (t_start_us - 10#${reflectors_last_timestamp_us})>500000 ))
				then
					log_msg "DEBUG" "processed response from [${reflector}] that is > 500ms old. Skipping."
					continue
				fi

				# Keep track of delays across detection window, detect any bufferbloat and determine load percentages
				((
					dl_delays[delays_idx] && (sum_dl_delays--),
					dl_delays[delays_idx] = dl_owd_delta_us > compensated_owd_delta_thr_us[dl] ? 1 : 0,
					dl_delays[delays_idx] && (sum_dl_delays++),

					sum_dl_owd_deltas_us -= dl_owd_deltas_us[delays_idx],
					dl_owd_deltas_us[delays_idx] = dl_owd_delta_us,
					sum_dl_owd_deltas_us += dl_owd_delta_us,

					ul_delays[delays_idx] && (sum_ul_delays--),
					ul_delays[delays_idx] = ul_owd_delta_us > compensated_owd_delta_thr_us[ul] ? 1 : 0,
					ul_delays[delays_idx] && (sum_ul_delays++),

					sum_ul_owd_deltas_us -= ul_owd_deltas_us[delays_idx],
					ul_owd_deltas_us[delays_idx] = ul_owd_delta_us,
					sum_ul_owd_deltas_us += ul_owd_delta_us,

					delays_idx=(delays_idx+1)%bufferbloat_detection_window,

					avg_owd_delta_us[dl] = sum_dl_owd_deltas_us / bufferbloat_detection_window,
					avg_owd_delta_us[ul] = sum_ul_owd_deltas_us / bufferbloat_detection_window,

					bufferbloat_detected[dl] = sum_dl_delays >= bufferbloat_detection_thr ? 1 : 0,
					bufferbloat_detected[ul] = sum_ul_delays >= bufferbloat_detection_thr ? 1 : 0,

					load_percent[dl]=100*achieved_rate_kbps[dl]/shaper_rate_kbps[dl],
					load_percent[ul]=100*achieved_rate_kbps[ul]/shaper_rate_kbps[ul]
				))

				load_condition[dl]=${dl_rate_load_condition} load_condition[ul]=${ul_rate_load_condition}

				((bufferbloat_detected[dl])) && load_condition[dl]+=_bb
				((bufferbloat_detected[ul])) && load_condition[ul]+=_bb

				# Update shaper rates
				for direction in dl ul
				do
					case ${load_condition[${direction}]} in

						# bufferbloat detected, so decrease the rate providing not inside bufferbloat refractory period
						*bb*)
							if (( t_start_us > (t_last_bufferbloat_us[${direction}]+bufferbloat_refractory_period_us) ))
							then
								if (( compensated_avg_owd_delta_thr_us[${direction}] <= compensated_owd_delta_thr_us[${direction}] ))
								then
									shaper_rate_adjust_down_bufferbloat_factor=1000
								elif (( (avg_owd_delta_us[${direction}]-compensated_owd_delta_thr_us[${direction}]) > 0 ))
								then
									((
										shaper_rate_adjust_down_bufferbloat_factor=1000*(avg_owd_delta_us[${direction}]-compensated_owd_delta_thr_us[${direction}])/(compensated_avg_owd_delta_thr_us[${direction}]-compensated_owd_delta_thr_us[${direction}]),
										shaper_rate_adjust_down_bufferbloat_factor > 1000 && (shaper_rate_adjust_down_bufferbloat_factor=1000)
									))
								else
									shaper_rate_adjust_down_bufferbloat_factor=0
								fi
								((
									shaper_rate_adjust_down_bufferbloat=1000*shaper_rate_min_adjust_down_bufferbloat-shaper_rate_adjust_down_bufferbloat_factor*(shaper_rate_min_adjust_down_bufferbloat-shaper_rate_max_adjust_down_bufferbloat),
									shaper_rate_kbps[${direction}]=shaper_rate_kbps[${direction}]*shaper_rate_adjust_down_bufferbloat/1000000,
									t_last_bufferbloat_us[${direction}]=t_start_us,
									t_last_decay_us[${direction}]=t_start_us
								))
							fi
							;;
						# high load, so increase rate providing not inside bufferbloat refractory period
						*high*)
							if (( achieved_rate_updated[${direction}] && t_start_us > (t_last_bufferbloat_us[${direction}]+bufferbloat_refractory_period_us) ))
							then
								((
									shaper_rate_kbps[${direction}]=(shaper_rate_kbps[${direction}]*shaper_rate_adjust_up_load_high)/1000,
									achieved_rate_updated[${direction}]=0,
									t_last_decay_us[${direction}]=t_start_us
								))
							fi
							;;
						# low or idle load, so determine whether to decay down towards base rate, decay up towards base rate, or set as base rate
						*low*|*idle*)
							if (( t_start_us > (t_last_decay_us[${direction}]+decay_refractory_period_us) ))
							then

								if ((shaper_rate_kbps[${direction}] > base_shaper_rate_kbps[${direction}]))
								then
									((
										decayed_shaper_rate_kbps=(shaper_rate_kbps[${direction}]*shaper_rate_adjust_down_load_low)/1000,
										shaper_rate_kbps[${direction}]=decayed_shaper_rate_kbps > base_shaper_rate_kbps[${direction}] ? decayed_shaper_rate_kbps : base_shaper_rate_kbps[${direction}]
									))
								elif ((shaper_rate_kbps[${direction}] < base_shaper_rate_kbps[${direction}]))
								then
									((
										decayed_shaper_rate_kbps=(shaper_rate_kbps[${direction}]*shaper_rate_adjust_up_load_low)/1000,
										shaper_rate_kbps[${direction}] = decayed_shaper_rate_kbps < base_shaper_rate_kbps[${direction}] ? decayed_shaper_rate_kbps : base_shaper_rate_kbps[${direction}]
									))
								fi

								t_last_decay_us[${direction}]=${t_start_us}
							fi
							;;
						*)
							log_msg "ERROR" "unknown load condition: ${load_condition[${direction}]}"
							kill $$ 2>/dev/null
							;;
					esac
				done

				# make sure that updated shaper rates fall between configured minimum and maximum shaper rates
				((
					shaper_rate_kbps[dl] < min_shaper_rate_kbps[dl] && (shaper_rate_kbps[dl]=${min_shaper_rate_kbps[dl]}) ||
					shaper_rate_kbps[dl] > max_shaper_rate_kbps[dl] && (shaper_rate_kbps[dl]=${max_shaper_rate_kbps[dl]}),
					shaper_rate_kbps[ul] < min_shaper_rate_kbps[ul] && (shaper_rate_kbps[ul]=${min_shaper_rate_kbps[ul]}) ||
					shaper_rate_kbps[ul] > max_shaper_rate_kbps[ul] && (shaper_rate_kbps[ul]=${max_shaper_rate_kbps[ul]})
				))

				set_shaper_rate "dl"
				set_shaper_rate "ul"

				if (( output_processing_stats ))
				then
					printf -v processing_stats '%s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s' "${EPOCHREALTIME}" "${achieved_rate_kbps[dl]}" "${achieved_rate_kbps[ul]}" "${load_percent[dl]}" "${load_percent[ul]}" "${timestamp}" "${reflector}" "${seq}" "${dl_owd_baselines_us[${reflector}]}" "${dl_owd_us}" "${dl_owd_delta_ewmas_us[${reflector}]}" "${dl_owd_delta_us}" "${compensated_owd_delta_thr_us[dl]}" "${ul_owd_baselines_us[${reflector}]}" "${ul_owd_us}" "${ul_owd_delta_ewmas_us[${reflector}]}" "${ul_owd_delta_us}" "${compensated_owd_delta_thr_us[ul]}" "${sum_dl_delays}" "${avg_owd_delta_us[dl]}" "${compensated_avg_owd_delta_thr_us[dl]}" "${sum_ul_delays}" "${avg_owd_delta_us[ul]}" "${compensated_avg_owd_delta_thr_us[ul]}" "${load_condition[dl]}" "${load_condition[ul]}" "${shaper_rate_kbps[dl]}" "${shaper_rate_kbps[ul]}"
					log_msg "DATA" "${processing_stats}"
				fi

				if (( output_summary_stats ))
				then
					printf -v summary_stats '%s; %s; %s; %s; %s; %s; %s; %s; %s; %s' "${achieved_rate_kbps[dl]}" "${achieved_rate_kbps[ul]}" "${sum_dl_delays}" "${sum_ul_delays}" "${avg_owd_delta_us[dl]}" "${avg_owd_delta_us[ul]}" "${load_condition[dl]}" "${load_condition[ul]}" "${shaper_rate_kbps[dl]}" "${shaper_rate_kbps[ul]}"
					log_msg "SUMMARY" "${summary_stats}"
				fi

				# If base rate is sustained, increment sustained base rate timer (and break out of processing loop if enough time passes)
				if (( enable_sleep_function ))
				then
					case ${load_condition[dl]}${load_condition[ul]} in
						*idle*idle*)
							if ((sustained_connection_idle))
							then
								((
									t_sustained_connection_idle_us += (t_start_us-t_last_connection_idle_us),
									t_last_connection_idle_us=t_start_us
								))
							else
								sustained_connection_idle=1 t_last_connection_idle_us=t_start_us
							fi
							if ((t_sustained_connection_idle_us > sustained_idle_sleep_thr_us))
							then
								change_state_main "IDLE"

								log_msg "DEBUG" "Connection idle. Waiting for minimum load."

								if ((min_shaper_rates_enforcement))
								then
									log_msg "DEBUG" "Enforcing minimum shaper rates."
									shaper_rate_kbps[dl]=${min_dl_shaper_rate_kbps} shaper_rate_kbps[ul]=${min_ul_shaper_rate_kbps}
									set_shaper_rate "dl"
									set_shaper_rate "ul"
								fi

								stop_pingers

								t_sustained_connection_idle_us=0 sustained_connection_idle=0
							fi
							;;
						*)
							t_sustained_connection_idle_us=0 sustained_connection_idle=0
							;;
					esac
				fi
			elif (( (t_start_us - reflectors_last_timestamp_us) > stall_detection_timeout_us ))
			then

				log_msg "DEBUG" "Warning: no reflector response within: ${stall_detection_timeout_s} seconds. Checking loads."

				log_msg "DEBUG" "load check is: (( ${achieved_rate_kbps[dl]} kbps > ${connection_stall_thr_kbps} kbps for download && ${achieved_rate_kbps[ul]} kbps > ${connection_stall_thr_kbps} kbps for upload ))"

				# non-zero load so despite no reflector response within stall interval, the connection not considered to have stalled
				# and therefore resume normal operation
				if (( achieved_rate_kbps[dl] > connection_stall_thr_kbps && achieved_rate_kbps[ul] > connection_stall_thr_kbps ))
				then

					log_msg "DEBUG" "load above connection stall threshold so resuming normal operation."
				else
					change_state_main "STALL"

					t_connection_stall_time_us=${t_start_us} global_ping_response_timeout=0
				fi

			fi

			if (( t_start_us > t_last_reflector_health_check_us + reflector_health_check_interval_us ))
			then
				if (( t_start_us>(t_last_reflector_replacement_us+reflector_replacement_interval_us) ))
				then
					((pinger=RANDOM%no_pingers))
					log_msg "DEBUG" "reflector: ${reflectors[pinger]} randomly selected for replacement."
					replace_pinger_reflector "${pinger}"
					t_last_reflector_replacement_us=${t_start_us}
					continue
				fi

				if (( t_start_us>(t_last_reflector_comparison_us+reflector_comparison_interval_us) ))
				then

					t_last_reflector_comparison_us=${t_start_us}

					[[ "${dl_owd_baselines_us[${reflectors[0]}]:-}" && "${dl_owd_baselines_us[${reflectors[0]}]:-}" && "${ul_owd_baselines_us[${reflectors[0]}]:-}" && "${ul_owd_baselines_us[${reflectors[0]}]:-}" ]] || continue

					((
						min_sum_owd_baselines_us = dl_owd_baselines_us[${reflectors[0]}] + ul_owd_baselines_us[${reflectors[0]}],
						min_dl_owd_delta_ewma_us=dl_owd_delta_ewmas_us[${reflectors[0]}],
						min_ul_owd_delta_ewma_us=ul_owd_delta_ewmas_us[${reflectors[0]}]
					))

					for ((pinger=0; pinger < no_pingers; pinger++))
					do
						[[ ${dl_owd_baselines_us[${reflectors[pinger]}]:-} && ${dl_owd_delta_ewmas_us[${reflectors[pinger]}]:-} && ${ul_owd_baselines_us[${reflectors[pinger]}]:-} && ${ul_owd_delta_ewmas_us[${reflectors[pinger]}]:-} ]] || continue 2

						((
							sum_owd_baselines_us[pinger] = dl_owd_baselines_us[${reflectors[pinger]}] + ul_owd_baselines_us[${reflectors[pinger]}],
							sum_owd_baselines_us[pinger] < min_sum_owd_baselines_us && (min_sum_owd_baselines_us=sum_owd_baselines_us[pinger]),
							dl_owd_delta_ewmas_us[${reflectors[pinger]}] < min_dl_owd_delta_ewma_us && (min_dl_owd_delta_ewma_us=dl_owd_delta_ewmas_us[${reflectors[pinger]}]),
							ul_owd_delta_ewmas_us[${reflectors[pinger]}] < min_ul_owd_delta_ewma_us && (min_ul_owd_delta_ewma_us=ul_owd_delta_ewmas_us[${reflectors[pinger]}])

						))
					done

					for ((pinger=0; pinger < no_pingers; pinger++))
					do

						((
							sum_owd_baselines_delta_us = sum_owd_baselines_us[pinger] - min_sum_owd_baselines_us,
							dl_owd_delta_ewma_delta_us = dl_owd_delta_ewmas_us[${reflectors[pinger]}] - min_dl_owd_delta_ewma_us,
							ul_owd_delta_ewma_delta_us = ul_owd_delta_ewmas_us[${reflectors[pinger]}] - min_ul_owd_delta_ewma_us
						))

						if ((output_reflector_stats))
						then
							printf -v reflector_stats '%s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s' "${EPOCHREALTIME}" "${reflectors[pinger]}" "${min_sum_owd_baselines_us}" "${sum_owd_baselines_us[pinger]}" "${sum_owd_baselines_delta_us}" "${reflector_sum_owd_baselines_delta_thr_us}" "${min_dl_owd_delta_ewma_us}" "${dl_owd_delta_ewmas_us[${reflectors[pinger]}]}" "${dl_owd_delta_ewma_delta_us}" "${reflector_owd_delta_ewma_delta_thr_us}" "${min_ul_owd_delta_ewma_us}" "${ul_owd_delta_ewmas_us[${reflectors[pinger]}]}" "${ul_owd_delta_ewma_delta_us}" "${reflector_owd_delta_ewma_delta_thr_us}"
							log_msg "REFLECTOR" "${reflector_stats}"
						fi

						if (( sum_owd_baselines_delta_us > reflector_sum_owd_baselines_delta_thr_us ))
						then
							log_msg "DEBUG" "Warning: reflector: ${reflectors[pinger]} sum_owd_baselines_us exceeds the minimum by set threshold."
							replace_pinger_reflector "${pinger}"
							continue 2
						fi

						if (( dl_owd_delta_ewma_delta_us > reflector_owd_delta_ewma_delta_thr_us ))
						then
							log_msg "DEBUG" "Warning: reflector: ${reflectors[pinger]} dl_owd_delta_ewma_us exceeds the minimum by set threshold."
							replace_pinger_reflector "${pinger}"
							continue 2
						fi

						if (( ul_owd_delta_ewma_delta_us > reflector_owd_delta_ewma_delta_thr_us ))
						then
							log_msg "DEBUG" "Warning: reflector: ${reflectors[pinger]} ul_owd_delta_ewma_us exceeds the minimum by set threshold."
							replace_pinger_reflector "${pinger}"
							continue 2
						fi
					done

				fi

				replace_pinger_reflector_enabled=1

				for ((pinger=0; pinger < no_pingers; pinger++))
				do
					# shellcheck disable=SC2178
					declare -n reflector_offences="reflector_${pinger}_offences"

					((
						reflector_offences[reflector_offences_idx] && (sum_reflector_offences[pinger]--),
						reflector_offences[reflector_offences_idx] = (t_start_us-last_timestamp_reflectors_us[${reflectors[pinger]}]) > reflector_response_deadline_us ? 1 : 0
					))

					if (( reflector_offences[reflector_offences_idx] ))
					then
						((sum_reflector_offences[pinger]++))
						log_msg "DEBUG" "no ping response from reflector: ${reflectors[pinger]} within reflector_response_deadline: ${reflector_response_deadline_s}s"
						log_msg "DEBUG" "reflector=${reflectors[pinger]}, sum_reflector_offences=${sum_reflector_offences[pinger]} and reflector_misbehaving_detection_thr=${reflector_misbehaving_detection_thr}"
					fi

					if (( sum_reflector_offences[pinger] >= reflector_misbehaving_detection_thr ))
					then

						log_msg "DEBUG" "Warning: reflector: ${reflectors[pinger]} seems to be misbehaving."
						if ((replace_pinger_reflector_enabled))
						then
							replace_pinger_reflector "${pinger}"
							replace_pinger_reflector_enabled=0
						else
							log_msg "DEBUG" "Warning: skipping replacement of reflector: ${reflectors[pinger]} given prior replacement within this reflector health check cycle."
						fi
					fi
				done
				((
					reflector_offences_idx=(reflector_offences_idx+1)%reflector_misbehaving_detection_window,
					t_last_reflector_health_check_us=t_start_us
				))
			fi
			;;
		IDLE)
			if (( achieved_rate_kbps[dl] > connection_active_thr_kbps || achieved_rate_kbps[ul] > connection_active_thr_kbps ))
			then
				log_msg "DEBUG" "dl achieved rate: ${achieved_rate_kbps[dl]} kbps or ul achieved rate: ${achieved_rate_kbps[ul]} kbps exceeded connection active threshold: ${connection_active_thr_kbps} kbps. Resuming normal operation."
				change_state_main "RUNNING"
				start_pingers
				t_sustained_connection_idle_us=0
				# Give some time to enable pingers to get set up
				((
					reflectors_last_timestamp_us = t_start_us + 2*reflector_ping_interval_us,
					t_last_reflector_health_check_us=reflectors_last_timestamp_us
				))
			fi
			;;
		STALL)
			((reflector_response)) && reflectors_last_timestamp_us=${t_start_us}

			if (( reflector_response || achieved_rate_kbps[dl] > connection_stall_thr_kbps && achieved_rate_kbps[ul] > connection_stall_thr_kbps ))
			then

				log_msg "DEBUG" "Connection stall ended. Resuming normal operation."
				change_state_main "RUNNING"
			fi

			if (( global_ping_response_timeout==0 && t_start_us > (t_connection_stall_time_us + global_ping_response_timeout_us - stall_detection_timeout_us) ))
			then
				global_ping_response_timeout=1
				((min_shaper_rates_enforcement)) && set_min_shaper_rates
				log_msg "SYSLOG" "Warning: Configured global ping response timeout: ${global_ping_response_timeout_s} seconds exceeded."
				log_msg "DEBUG" "Restarting pingers."
				stop_pingers
				start_pingers
			fi
			;;
		*)
			log_msg "ERROR" "Unrecognized main state: ${main_state}. Exiting now."
			exit 1
			;;
	esac
done
