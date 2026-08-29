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

cake_autorate_version="3.3.0-PRERELEASE"

## cake-autorate uses multiple asynchronous processes including:
## main - main process
## monitor_achieved_rates - monitor network transfer rates
## maintain_log_file - maintain and rotate log file
## log_file_waker - mark buffered log intervals
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
	terminate "${proc_pids['maintain_log_file']:-}" \
		"${terminate_maintain_log_file_timeout_ms}"
	terminate "${proc_pids['log_file_waker']:-}"

	unset "proc_pids[maintain_log_file]" "proc_pids[log_file_waker]"

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

	for proc_pid in "${!proc_pids[@]}"
	do
		[[ ${proc_pid} == *_pinger ]] && unset "proc_pids[${proc_pid}]"
	done

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
	# send logging message to stdout, log file fifo, log file and/or system logger

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
	((print_to_stdout)) && printf '%s' "${msg}"

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
		header="DATA_HEADER; LOG_DATETIME; LOG_TIMESTAMP; PROC_TIME_US; DL_ACHIEVED_RATE_KBPS; UL_ACHIEVED_RATE_KBPS; DL_LOAD_PERCENT; UL_LOAD_PERCENT; ICMP_TIMESTAMP; REFLECTOR; SEQUENCE; DL_OWD_BASELINE; DL_OWD_US; DL_OWD_DELTA_EWMA_US; DL_OWD_DELTA_US; DL_ADJ_DELAY_THR; UL_OWD_BASELINE; UL_OWD_US; UL_OWD_DELTA_EWMA_US; UL_OWD_DELTA_US; UL_ADJ_DELAY_THR; DL_SUM_DELAYS; DL_AVG_OWD_DELTA_US; DL_ADJ_MAX_ADJUST_UP_THR_US; DL_ADJ_MAX_ADJUST_DOWN_THR_US; UL_SUM_DELAYS; UL_AVG_OWD_DELTA_US; UL_ADJ_MAX_ADJUST_UP_THR_US; UL_ADJ_MAX_ADJUST_DOWN_THR_US; DL_LOAD_CONDITION; UL_LOAD_CONDITION; CAKE_DL_RATE_KBPS; CAKE_UL_RATE_KBPS"
		((log_to_file)) && printf '%s\n' "${header}" >&${log_file_fd}
		((print_to_stdout)) && printf '%s\n' "${header}"
	fi

	if ((output_load_stats))
	then
		header="LOAD_HEADER; LOG_DATETIME; LOG_TIMESTAMP; PROC_TIME_US; DL_ACHIEVED_RATE_KBPS; UL_ACHIEVED_RATE_KBPS; CAKE_DL_RATE_KBPS; CAKE_UL_RATE_KBPS"
		((log_to_file)) && printf '%s\n' "${header}" >&${log_file_fd}
		((print_to_stdout)) && printf '%s\n' "${header}"
	fi

	if ((output_reflector_stats))
	then
		header="REFLECTOR_HEADER; LOG_DATETIME; LOG_TIMESTAMP; PROC_TIME_US; REFLECTOR; MIN_SUM_OWD_BASELINES_US; SUM_OWD_BASELINES_US; SUM_OWD_BASELINES_DELTA_US; SUM_OWD_BASELINES_DELTA_THR_US; MIN_DL_DELTA_EWMA_US; DL_DELTA_EWMA_US; DL_DELTA_EWMA_DELTA_US; DL_DELTA_EWMA_DELTA_THR; MIN_UL_DELTA_EWMA_US; UL_DELTA_EWMA_US; UL_DELTA_EWMA_DELTA_US; UL_DELTA_EWMA_DELTA_THR"
		((log_to_file)) && printf '%s\n' "${header}" >&${log_file_fd}
		((print_to_stdout)) && printf '%s\n' "${header}"
	fi

	if ((output_summary_stats))
	then
		header="SUMMARY_HEADER; LOG_DATETIME; LOG_TIMESTAMP; DL_ACHIEVED_RATE_KBPS; UL_ACHIEVED_RATE_KBPS; DL_SUM_DELAYS; UL_SUM_DELAYS; DL_AVG_OWD_DELTA_US; UL_AVG_OWD_DELTA_US; DL_LOAD_CONDITION; UL_LOAD_CONDITION; CAKE_DL_RATE_KBPS; CAKE_UL_RATE_KBPS"
		((log_to_file)) && printf '%s\n' "${header}" >&${log_file_fd}
		((print_to_stdout)) && printf '%s\n' "${header}"
	fi

	if ((output_cpu_stats))
	then
		header="CPU_HEADER; LOG_DATETIME; LOG_TIMESTAMP; STATS_READ_TIME; ${cpu_ids// /_USAGE; }_USAGE"
		((log_to_file)) && printf '%s\n' "${header}" >&${log_file_fd}
		((print_to_stdout)) && printf '%s\n' "${header}"
	fi

	if ((output_cpu_raw_stats))
	then
		header="CPU_RAW_HEADER; LOG_DATETIME; LOG_TIMESTAMP; STATS_READ_TIME; CPU_ID; USER; NICE; SYSTEM; IDLE; IOWAIT; IRQ; SIRQ; STEAL; GUEST; GUEST_NICE"
		((log_to_file)) && printf '%s\n' "${header}" >&${log_file_fd}
		((print_to_stdout)) && printf '%s\n' "${header}"
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

	rm -f "${run_path}/last_log_file_export"

	if kill -USR1 "${proc_pids['maintain_log_file']}"
	then
		printf "Successfully signalled maintain_log_file process to request log file export.\n"
	else
		printf "ERROR: Failed to signal maintain_log_file process.\n" >&2
		exit 1
	fi

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
	local log_chunk

	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"
	while
		log_chunk=""
		IFS= read -r -d '' -t 0.01 -u "${log_fd}" log_chunk ||
			[[ -n ${log_chunk} ]]
	do
		if [[ -n ${log_chunk} ]]
		then
			printf '%s' "${log_chunk}" >&${log_file_fd}
			((log_file_size_bytes+=${#log_chunk}))
		fi
	done
}

log_file_waker()
{
	trap '' INT
	trap 'exit' TERM

	while sleep_s "${log_file_buffer_timeout_s}"
	do
		kill -0 "${proc_pids['maintain_log_file']}" 2>/dev/null || break
		# Bash variables cannot contain NUL, so write the interval marker directly.
		printf '\0' >&"${log_fd}"
	done
}

maintain_log_file()
{
	local log_chunk
	local -a log_chunks
	signal=""
	trap '' INT
	# Wake a blocked mapfile so it can process the termination request.
	trap 'signal+=KILL; printf "\0" >&"${log_fd}"' TERM
	trap 'signal+=KILL' EXIT
	trap 'signal+=EXPORT' USR1
	trap 'signal+=RESET' USR2

	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	while :
	do
		exec {log_file_fd}> "${log_file_path}"

		print_headers
		log_file_size_bytes=$(wc -c "${log_file_path}" 2>/dev/null | awk '{print $1}')
		log_file_size_bytes=${log_file_size_bytes:-0}

		t_log_file_start_s=${SECONDS}

		while :
		do
			log_chunks=()
			if ! mapfile -d '' -t -n 1 -u "${log_fd}" log_chunks &&
				(( ${#log_chunks[@]} == 0 )) && [[ -z ${signal} ]]
			then
				printf 'ERROR: Buffered log collector failed while reading the log pipe.\n' >&2
				trap - TERM EXIT
				exit 1
			fi
			log_chunk=${log_chunks[0]-}
			if [[ -n ${log_chunk} ]]
			then
				printf '%s' "${log_chunk}" >&${log_file_fd}
				((log_file_size_bytes+=${#log_chunk}))
			fi

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

	printf '%s\n' "${CAKE_AUTORATE_RUN_TOKEN}" > "${run_path}/run_token"
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

	local achieved_dl_rate_kbps achieved_ul_rate_kbps

	while :
	do
		t_start_us=${EPOCHREALTIME/.}

		# read in rx/tx bytes file, and if this fails then set to prev_bytes
		# this addresses interfaces going down and back up
		{ read -r rx_bytes < "${rx_bytes_path}"; } 2> /dev/null || rx_bytes=${prev_rx_bytes}
		{ read -r tx_bytes < "${tx_bytes_path}"; } 2> /dev/null || tx_bytes=${prev_tx_bytes}

		((
			achieved_dl_rate_kbps = 8000*(rx_bytes - prev_rx_bytes) / compensated_monitor_achieved_rates_interval_us,
			achieved_ul_rate_kbps = 8000*(tx_bytes - prev_tx_bytes) / compensated_monitor_achieved_rates_interval_us,

			achieved_dl_rate_kbps<0 && (achieved_dl_rate_kbps=0),
			achieved_ul_rate_kbps<0 && (achieved_ul_rate_kbps=0),

			prev_rx_bytes=rx_bytes,
			prev_tx_bytes=tx_bytes,

			compensated_monitor_achieved_rates_interval_us = monitor_achieved_rates_interval_us>(10*max_wire_packet_rtt_us) ? monitor_achieved_rates_interval_us : 10*max_wire_packet_rtt_us
		))

		printf "SARS %s %s\n" "${achieved_dl_rate_kbps}" "${achieved_ul_rate_kbps}" >&${main_fd}

		sleep_remaining_tick_time "${t_start_us}" "${compensated_monitor_achieved_rates_interval_us}"
	done
}

# GENERIC PINGER START AND STOP FUNCTIONS

start_pinger()
{
	local pinger=${1}

	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	case ${pinger_method} in

		irtt)
			sleep_until_next_pinger_time_slot "${pinger}"

			# shellcheck disable=SC2155
			local pinger_pid=$( (
				set -m
				${ping_prefix_string} gawk -v extra_args="${ping_extra_args}" -v interval_s="${reflector_ping_interval_s}" -v duration_m="${irtt_session_duration_m}" -v reflector="${reflectors[$pinger]}" -f <(cat <<-'EOT'
				@load "time"

				function to_us(val, mult)
				{
					mult = (val ~ /ms$/) ? 1000    : \
						   (val ~ /µs$/) ? 1       : \
						   (val ~ /ns$/) ? 0.001   : \
						   (val ~ /s$/)  ? 1000000 : -1

					if (val ~ /^-/ || mult < 0) return -1
					return sprintf("%.0f", val * mult)
				}

				BEGIN {
					FS = "[= ]+"

					irtt_cmd = sprintf("stdbuf -oL irtt client %s -i '%ss' -d '%sm' '%s'", extra_args, interval_s, duration_m, (reflector ~ /:/ ? "[" reflector "]" : reflector))

					while (1)
					{
						start_time = systime()

						while ((irtt_cmd | getline) > 0)
						{
							if (/seq=/ && /rd=/ && /sd=/)
							{
								ts = gensub(/\./, "", 1, sprintf("%.6f", gettimeofday()))
								seq = $2; dl_owd = to_us($6); ul_owd = to_us($8)

								if (dl_owd >= 0 && ul_owd >= 0)
								{
									printf("%s %s %d %d %d\n", ts, reflector, seq, dl_owd, ul_owd)
									fflush("")
								}
							}
							else if (/WaitForPackets/)
							{
								break
							}
						}

						close(irtt_cmd)
						if (systime() - start_time < 3) system("sleep 1")
					}
				}
				EOT
				) 2> /dev/null >&"${main_fd}" &
				echo $!
			) )

			pinger_pids["${pinger}"]=-${pinger_pid}
			proc_pids["irtt_${pinger}_pinger"]=${pinger_pid}
			;;
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
		fping-ts)
			${ping_prefix_string} fping ${ping_extra_args} --timestamp --loop --period "${reflector_ping_interval_ms}" --interval "${ping_response_interval_ms}" --timeout 10000 --icmp-timestamp "${reflectors[@]:0:${no_pingers}}" 2> /dev/null >&"${main_fd}" &
			pinger_pids[0]=${!}
			proc_pids['fping_pinger']=${pinger_pids[0]}
			;;
		ping)
			sleep_until_next_pinger_time_slot "${pinger}"
			${ping_prefix_string} ping ${ping_extra_args} -D -n -i "${reflector_ping_interval_s}" "${reflectors[pinger]}" 2> /dev/null >&"${main_fd}" &
			pinger_pids[pinger]=${!}
			proc_pids["ping_${pinger}_pinger"]=${pinger_pids[pinger]}
			;;
		*)
			log_msg "ERROR" "Unknown pinger method: ${pinger_method}"
			kill $$ 2>/dev/null
			;;
	esac

	export_proc_pids
}

start_pingers()
{
	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	((pingers_active)) && return
	case ${pinger_method} in

		tsping|fping|fping-ts)
			start_pinger 0
			;;
		ping|irtt)
			for ((pinger=0; pinger < no_pingers; pinger++))
			do
				start_pinger "${pinger}"
			done
			;;
		*)
			log_msg "ERROR" "Unknown pinger method: ${pinger_method}"
			kill $$ 2>/dev/null
			;;
	esac
	pingers_active=1 t_last_start_pingers_us=${EPOCHREALTIME/.}
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

	case ${pinger_method} in
		tsping|fping|fping-ts)
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
	case ${pinger_method} in

		tsping|fping|fping-ts)
			log_msg "DEBUG" "Killing ${pinger_method} instance."
			kill_pinger 0
			;;
		ping|irtt)
			for (( pinger=0; pinger < no_pingers; pinger++))
			do
				log_msg "DEBUG" "Killing pinger instance: ${pinger}"
				kill_pinger "${pinger}"
			done
			;;
		*)
			log_msg "ERROR" "Unknown pinger method: ${pinger_method}"
			kill $$ 2>/dev/null
			;;
	esac
	pingers_active=0
}

handle_global_ping_response_timeout()
{
	(( t_start_us - reflectors_last_timestamp_us >= global_ping_response_timeout_us )) || return

	if ((global_ping_response_timeout == 0))
	then
		global_ping_response_timeout=1
		((min_shaper_rates_enforcement)) && set_min_shaper_rates
		log_msg "SYSLOG" "Warning: Configured global ping response timeout: ${global_ping_response_timeout_s} seconds exceeded."
	fi

	if (( t_start_us - t_last_start_pingers_us >= global_ping_response_timeout_us ))
	then
		log_msg "DEBUG" "Restarting pingers."
		stop_pingers
		start_pingers
	fi
}

replace_pinger_reflector()
{
	# pingers always use reflectors[0]..[no_pingers-1] as the initial set
	# and the additional reflectors are spare reflectors should any from initial set go stale
	# a bad reflector in the initial set is replaced with ${reflectors[no_pingers]}
	# ${reflectors[no_pingers]} is then unset
	# and the the bad reflector moved to the back of the queue (last element in ${reflectors[]})
	# and finally the indices for ${reflectors} are updated to reflect the new order

	local pinger=${1} bad_reflector new_reflector

	log_msg "DEBUG" "Starting: ${FUNCNAME[0]} with PID: ${BASHPID}"

	if ((no_reflectors > no_pingers))
	then
		bad_reflector=${reflectors[pinger]}
		new_reflector=${reflectors[no_pingers]}
		log_msg "DEBUG" "replacing reflector: ${bad_reflector} with ${new_reflector}."
		((pingers_active)) && kill_pinger "${pinger}"

		if ((retain_reflector_stats))
		then
			log_msg "DEBUG" "Retaining reflector stats associated with: ${bad_reflector}"
			retained_dl_owd_baselines_us[${bad_reflector}]=${dl_owd_baselines_us[pinger]}
			retained_ul_owd_baselines_us[${bad_reflector}]=${ul_owd_baselines_us[pinger]}
			retained_dl_owd_delta_ewmas_us[${bad_reflector}]=${dl_owd_delta_ewmas_us[pinger]}
			retained_ul_owd_delta_ewmas_us[${bad_reflector}]=${ul_owd_delta_ewmas_us[pinger]}
		else
			log_msg "DEBUG" "Discarding reflector stats associated with ${bad_reflector}"
			unset "retained_dl_owd_baselines_us[${bad_reflector}]"
			unset "retained_ul_owd_baselines_us[${bad_reflector}]"
			unset "retained_dl_owd_delta_ewmas_us[${bad_reflector}]"
			unset "retained_ul_owd_delta_ewmas_us[${bad_reflector}]"
		fi

		reflectors[pinger]=${new_reflector}
		unset "reflectors[no_pingers]"
		reflectors+=("${bad_reflector}")
		reflectors=("${reflectors[@]}")

		unset "pinger_by_reflector[${bad_reflector}]"
		pinger_by_reflector[${new_reflector}]=${pinger}
		dl_owd_baselines_us[pinger]=${retained_dl_owd_baselines_us[${new_reflector}]:-100000}
		ul_owd_baselines_us[pinger]=${retained_ul_owd_baselines_us[${new_reflector}]:-100000}
		dl_owd_delta_ewmas_us[pinger]=${retained_dl_owd_delta_ewmas_us[${new_reflector}]:-0}
		ul_owd_delta_ewmas_us[pinger]=${retained_ul_owd_delta_ewmas_us[${new_reflector}]:-0}
		last_timestamp_reflectors_us[pinger]=${t_start_us}

		((pingers_active)) && start_pinger "${pinger}"
	else
		log_msg "DEBUG" "No additional reflectors specified so just retaining: ${reflectors[pinger]}."
	fi

	log_msg "DEBUG" "Resetting reflector offences associated with reflector: ${reflectors[pinger]}."
	for ((i=0; i<reflector_misbehaving_detection_window; i++))
	do
		reflector_offences[pinger*reflector_misbehaving_detection_window+i]=0
	done
	sum_reflector_offences[pinger]=0
}

# END OF GENERIC PINGER START AND STOP FUNCTIONS

set_shaper_rates()
{
	local direction changed_direction tc_batch_commands=""
	local rates_changed=0 tc_command_count=0

	for ((direction=DL; direction<=UL; direction++))
	do
		(( shaper_rate_kbps[direction] != last_shaper_rate_kbps[direction] )) || continue
		rates_changed=1

		((output_cake_changes)) && log_msg "SHAPER" "tc qdisc change root dev ${interface[direction]} cake bandwidth ${shaper_rate_kbps[direction]}Kbit"

		if ((adjust_shaper_rate[direction]))
		then
			changed_direction=${direction}
			((++tc_command_count))
			printf -v tc_batch_commands '%sqdisc change root dev %s cake bandwidth %s\n' "${tc_batch_commands}" "${interface[direction]}" "${shaper_rate_kbps[direction]}Kbit"
		else
			((output_cake_changes)) && log_msg "DEBUG" "adjust_${direction_name[direction]}_shaper_rate set to 0 in config, so skipping the corresponding tc qdisc change call."
		fi
	done

	((rates_changed)) || return

	if ((tc_command_count == 2))
	then
		tc -force -batch - 2> /dev/null <<< "${tc_batch_commands}"
	elif ((tc_command_count == 1))
	then
		tc qdisc change root dev "${interface[changed_direction]}" cake bandwidth "${shaper_rate_kbps[changed_direction]}Kbit" 2> /dev/null
	fi

	# Compensate for delays imposed by active traffic shaper
	# This will serve to increase the delay thr at rates below around 12Mbit/s
	((
		dl_compensation_us=(1000*dl_max_wire_packet_size_bits)/shaper_rate_kbps[DL],
		ul_compensation_us=(1000*ul_max_wire_packet_size_bits)/shaper_rate_kbps[UL],

		compensated_avg_owd_delta_max_adjust_up_thr_us[DL]=dl_avg_owd_delta_max_adjust_up_thr_us + dl_compensation_us,
		compensated_avg_owd_delta_max_adjust_up_thr_us[UL]=ul_avg_owd_delta_max_adjust_up_thr_us + ul_compensation_us,

		compensated_owd_delta_delay_thr_us[DL]=dl_owd_delta_delay_thr_us + dl_compensation_us,
		compensated_owd_delta_delay_thr_us[UL]=ul_owd_delta_delay_thr_us + ul_compensation_us,

		compensated_avg_owd_delta_max_adjust_down_thr_us[DL]=dl_avg_owd_delta_max_adjust_down_thr_us + dl_compensation_us,
		compensated_avg_owd_delta_max_adjust_down_thr_us[UL]=ul_avg_owd_delta_max_adjust_down_thr_us + ul_compensation_us,

		max_wire_packet_rtt_us=(1000*dl_max_wire_packet_size_bits)/shaper_rate_kbps[DL] + (1000*ul_max_wire_packet_size_bits)/shaper_rate_kbps[UL],

		last_shaper_rate_kbps[DL]=shaper_rate_kbps[DL],
		last_shaper_rate_kbps[UL]=shaper_rate_kbps[UL]
	))
}

set_min_shaper_rates()
{
	shaper_rate_kbps[DL]=${min_shaper_rate_kbps[DL]} shaper_rate_kbps[UL]=${min_shaper_rate_kbps[UL]}
	set_shaper_rates
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

if [[ -n ${INVOCATION_ID-} ]]
then
	systemd_service=1
	print_to_stdout=1
	log_to_file=0
else
	systemd_service=0
	[[ -t 1 ]] && print_to_stdout=1 || print_to_stdout=0
fi

type logger &> /dev/null && use_logger=1 || use_logger=0 # only perform the test once.
((systemd_service)) && use_logger=0

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

if (( 10#${log_file_buffer_timeout_ms} < 50 ))
then
	printf 'ERROR: log_file_buffer_timeout_ms must be at least 50 milliseconds. Exiting now.\n' >&2
	exit 1
fi

if [[ ${config_path} =~ config\.(.*)\.sh ]]
then
	instance_id=${BASH_REMATCH[1]} run_path="/var/run/cake-autorate/${instance_id}"
else
	log_msg "ERROR" "Instance identifier 'X' set by config.X.sh cannot be empty. Exiting now."
	exit 1
fi

CAKE_AUTORATE_RUN_TOKEN=$(generate_run_token) || {
	log_msg "ERROR" "Failed to generate CAKE_AUTORATE_RUN_TOKEN. Exiting now."
	exit 1
}
export CAKE_AUTORATE_RUN_TOKEN

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

# ${run_path}/ is used to store temporary files
if [[ -d ${run_path} ]]
then
	if running_main_pid=$(get_running_main_pid_for_run_path "${run_path}")
	then
		log_msg "ERROR" "${run_path} already exists and an instance appears to be running with main process pid ${running_main_pid}. Exiting script."
		trap - INT TERM EXIT
		exit 1
	else
		log_msg "DEBUG" "${run_path} already exists but no conflicting instance is running. Removing and recreating."
		rm -r "${run_path}"
		( umask 077 && mkdir -p "${run_path}" )
	fi
else
	( umask 077 && mkdir -p "${run_path}" )
fi

((log_to_file)) && rotate_log_file

exec {original_stderr_fd}>&2 2> >(intercept_stderr)

proc_pids['intercept_stderr']=${!}

log_msg "SYSLOG" "Starting cake-autorate with PID: ${BASHPID} and config: ${config_path}"

proc_pids['main']=${BASHPID}

log_msg "DEBUG" "Local list of reflectors contains ${#reflectors[*]} entries."

if [[ -n ${reflectors_url} ]]
then
	log_msg "DEBUG" "Appending local list of reflectors with remote list of reflectors at: ${reflectors_url}."
	[[ ${reflectors_url} == https://* ]] || log_msg "WARNING" "reflectors_url is not https:// -- the remote reflector list is fetched without TLS and can be tampered with in transit."
	if command -v curl &> /dev/null
	then
		readarray -t -s "${reflectors_url_skip_lines}" -O "${#reflectors[*]}" reflectors < <( curl -fsS "${reflectors_url}" 2>/dev/null | awk -F "," '{ print $1 }' )
	elif command -v wget &> /dev/null
	then
		readarray -t -s "${reflectors_url_skip_lines}" -O "${#reflectors[*]}" reflectors < <( wget -O - "${reflectors_url}" 2>/dev/null | awk -F "," '{ print $1 }' )
	else
		log_msg "ERROR" "reflectors_url is set but neither curl nor wget is available. Exiting script."
		exit 1
	fi
	log_msg "DEBUG" "Local list of reflectors now contains ${#reflectors[*]} entries."
fi

declare -A configured_reflectors
for reflector in "${reflectors[@]}"
do
	[[ ${reflector} =~ ^[0-9A-Za-z:][0-9A-Za-z.:_-]*$ ]] || { log_msg "ERROR" "Invalid reflector '${reflector}': must be an IP address or hostname. Exiting script."; exit 1; }
	[[ -z ${configured_reflectors[${reflector}]:-} ]] || { log_msg "ERROR" "Duplicate reflector '${reflector}' in reflector list. Exiting script."; exit 1; }
	configured_reflectors[${reflector}]=1
done
unset configured_reflectors

no_reflectors=${#reflectors[@]}

# Check ping binary exists
case ${pinger_method} in

	fping-ts)
		command -v "fping" &> /dev/null || { log_msg "ERROR" "ping binary fping does not exist. Exiting script."; exit 1; }
		;;
	irtt)
		command -v "irtt"   &> /dev/null || { log_msg "ERROR" "ping binary irtt does not exist. Exiting script."; exit 1; }
		command -v "gawk"   &> /dev/null || { log_msg "ERROR" "pinger_method=irtt requires gawk. Exiting script."; exit 1; }
		command -v "stdbuf" &> /dev/null || { log_msg "ERROR" "pinger_method=irtt requires stdbuf (coreutils). Exiting script."; exit 1; }
		gawk '@load "time"; BEGIN{exit}' < /dev/null &> /dev/null || { log_msg "ERROR" "pinger_method=irtt requires the gawk 'time' extension (gawk-gawkextra). Exiting script."; exit 1; }
		;;
	*)
		command -v "${pinger_method}" &> /dev/null || { log_msg "ERROR" "ping binary ${pinger_method} does not exist. Exiting script."; exit 1; }
		;;
esac

(( no_pingers < 1 )) && { log_msg "ERROR" "number of pingers must be at least 1. Exiting script."; exit 1; }
(( no_pingers > no_reflectors )) && { log_msg "ERROR" "number of pingers cannot be greater than number of reflectors. Exiting script."; exit 1; }

(( min_dl_shaper_rate_kbps < 1 )) && { log_msg "ERROR" "min_dl_shaper_rate_kbps must be at least 1. Exiting script."; exit 1; }
(( min_ul_shaper_rate_kbps < 1 )) && { log_msg "ERROR" "min_ul_shaper_rate_kbps must be at least 1. Exiting script."; exit 1; }
(( min_dl_shaper_rate_kbps > base_dl_shaper_rate_kbps || base_dl_shaper_rate_kbps > max_dl_shaper_rate_kbps )) && { log_msg "ERROR" "dl shaper rates must satisfy min <= base <= max. Exiting script."; exit 1; }
(( min_ul_shaper_rate_kbps > base_ul_shaper_rate_kbps || base_ul_shaper_rate_kbps > max_ul_shaper_rate_kbps )) && { log_msg "ERROR" "ul shaper rates must satisfy min <= base <= max. Exiting script."; exit 1; }

# Check dl/if interface not the same
[[ "${dl_if}" == "${ul_if}" ]] && { log_msg "ERROR" "download interface and upload interface are both set to: '${dl_if}', but cannot be the same. Exiting script."; exit 1; }

# Check bufferbloat detection threshold not greater than window length
(( bufferbloat_detection_thr > bufferbloat_detection_window )) && { log_msg "ERROR" "bufferbloat_detection_thr cannot be greater than bufferbloat_detection_window. Exiting script."; exit 1; }

# Check if connection_active_thr_kbps is greater than min dl/ul shaper rate
(( connection_active_thr_kbps > min_dl_shaper_rate_kbps )) && { log_msg "ERROR" "connection_active_thr_kbps cannot be greater than min_dl_shaper_rate_kbps. Exiting script."; exit 1; }
(( connection_active_thr_kbps > min_ul_shaper_rate_kbps )) && { log_msg "ERROR" "connection_active_thr_kbps cannot be greater than min_ul_shaper_rate_kbps. Exiting script."; exit 1; }

# Passed error checks

cpu_idx=0
while :
do
	read -r cpu_id _
	case ${cpu_id} in
		cpu*)
			cpu_ids[cpu_idx]=${cpu_id^^}
			((cpu_idx++))
			;;
		*)
			break
			;;
	esac
done</proc/stat
cpu_ids="${cpu_ids[*]}"
((cpu_cores=cpu_idx-1))
log_msg "DEBUG" "Detected ${cpu_cores} CPU cores."
mapfile -t cpu_usage < <(for ((i=0; i <= cpu_cores; i++)); do echo 0; done)
mapfile -t last_cpu_sum < <(for ((i=0; i <= cpu_cores; i++)); do echo 0; done)
mapfile -t last_cpu_idle < <(for ((i=0; i <= cpu_cores; i++)); do echo 0; done)

if ((log_to_file))
then
	((
		log_file_max_time_s=log_file_max_time_mins*60,
		log_file_max_size_bytes=log_file_max_size_KB*1024
	))
	printf -v log_file_buffer_timeout_s %.3f "${log_file_buffer_timeout_ms}e-3"
	exec {log_fd}<> <(:)
	maintain_log_file &
	proc_pids['maintain_log_file']=${!}
	log_file_waker &
	proc_pids['log_file_waker']=${!}
fi

# Redirect stdout to the log pipe when it is not being output directly
if ! ((print_to_stdout))
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
	log_msg "DEBUG" "pinger_method:${pinger_method}"
	log_msg "DEBUG" "download interface: ${dl_if} (${min_dl_shaper_rate_kbps} / ${base_dl_shaper_rate_kbps} / ${max_dl_shaper_rate_kbps})"
	log_msg "DEBUG" "upload interface: ${ul_if} (${min_ul_shaper_rate_kbps} / ${base_ul_shaper_rate_kbps} / ${max_ul_shaper_rate_kbps})"
	log_msg "DEBUG" "rx_bytes_path: ${rx_bytes_path}"
	log_msg "DEBUG" "tx_bytes_path: ${tx_bytes_path}"
fi

# Check interfaces are up and wait if necessary for them to come up
verify_ifs_up

# Initialize variables

# Convert human readable parameters to values that work with integer arithmetic

printf -v dl_avg_owd_delta_max_adjust_up_thr_us %.0f "${dl_avg_owd_delta_max_adjust_up_thr_ms}e3"
printf -v ul_avg_owd_delta_max_adjust_up_thr_us %.0f "${ul_avg_owd_delta_max_adjust_up_thr_ms}e3"
printf -v dl_owd_delta_delay_thr_us %.0f "${dl_owd_delta_delay_thr_ms}e3"
printf -v ul_owd_delta_delay_thr_us %.0f "${ul_owd_delta_delay_thr_ms}e3"
printf -v dl_avg_owd_delta_max_adjust_down_thr_us %.0f "${dl_avg_owd_delta_max_adjust_down_thr_ms}e3"
printf -v ul_avg_owd_delta_max_adjust_down_thr_us %.0f "${ul_avg_owd_delta_max_adjust_down_thr_ms}e3"
printf -v alpha_baseline_increase %.0f "${alpha_baseline_increase}e6"
printf -v alpha_baseline_decrease %.0f "${alpha_baseline_decrease}e6"
printf -v alpha_delta_ewma %.0f "${alpha_delta_ewma}e6"
printf -v shaper_rate_min_adjust_down_bufferbloat %.0f "${shaper_rate_min_adjust_down_bufferbloat}e3"
printf -v shaper_rate_max_adjust_down_bufferbloat %.0f "${shaper_rate_max_adjust_down_bufferbloat}e3"
printf -v shaper_rate_min_adjust_up_load_high %.0f "${shaper_rate_min_adjust_up_load_high}e3"
printf -v shaper_rate_max_adjust_up_load_high %.0f "${shaper_rate_max_adjust_up_load_high}e3"
printf -v shaper_rate_adjust_down_load_low %.0f "${shaper_rate_adjust_down_load_low}e3"
printf -v shaper_rate_adjust_up_load_low %.0f "${shaper_rate_adjust_up_load_low}e3"
printf -v high_load_thr_percent %.0f "${high_load_thr}e2"
printf -v reflector_ping_interval_ms %.0f "${reflector_ping_interval_s}e3"
printf -v reflector_ping_interval_us %.0f "${reflector_ping_interval_s}e6"
printf -v reflector_health_check_interval_us %.0f "${reflector_health_check_interval_s}e6"
printf -v monitor_achieved_rates_interval_us %.0f "${monitor_achieved_rates_interval_ms}e3"
printf -v monitor_cpu_usage_interval_us %.0f "${monitor_cpu_usage_interval_ms}e3"
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

printf -v stall_detection_timeout_s %.2f "${stall_detection_timeout_us}e-6"

DL=0 UL=1
direction_name=(dl ul)

declare -a achieved_rate_kbps \
achieved_rate_updated \
bufferbloat_detected \
load_percent \
load_state \
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
compensated_owd_delta_delay_thr_us \
compensated_avg_owd_delta_max_adjust_up_thr_us \
compensated_avg_owd_delta_max_adjust_down_thr_us

declare -a dl_owd_baselines_us \
ul_owd_baselines_us \
dl_owd_delta_ewmas_us \
ul_owd_delta_ewmas_us \
last_timestamp_reflectors_us

declare -A pinger_by_reflector \
retained_dl_owd_baselines_us \
retained_ul_owd_baselines_us \
retained_dl_owd_delta_ewmas_us \
retained_ul_owd_delta_ewmas_us

base_shaper_rate_kbps[DL]=${base_dl_shaper_rate_kbps} base_shaper_rate_kbps[UL]=${base_ul_shaper_rate_kbps} \
min_shaper_rate_kbps[DL]=${min_dl_shaper_rate_kbps} min_shaper_rate_kbps[UL]=${min_ul_shaper_rate_kbps} \
max_shaper_rate_kbps[DL]=${max_dl_shaper_rate_kbps} max_shaper_rate_kbps[UL]=${max_ul_shaper_rate_kbps} \
shaper_rate_kbps[DL]=${base_dl_shaper_rate_kbps} shaper_rate_kbps[UL]=${base_ul_shaper_rate_kbps} \
achieved_rate_kbps[DL]=0 achieved_rate_kbps[UL]=0 \
achieved_rate_updated[DL]=0 achieved_rate_updated[UL]=0 \
last_shaper_rate_kbps[DL]=0 last_shaper_rate_kbps[UL]=0 \
interface[DL]=${dl_if} interface[UL]=${ul_if} \
adjust_shaper_rate[DL]=${adjust_dl_shaper_rate} adjust_shaper_rate[UL]=${adjust_ul_shaper_rate} \
dl_max_wire_packet_size_bits=0 ul_max_wire_packet_size_bits=0

if ((adjust_dl_shaper_rate == 0))
then
	min_shaper_rate_kbps[DL]=${base_dl_shaper_rate_kbps} max_shaper_rate_kbps[DL]=${base_dl_shaper_rate_kbps}
	log_msg "DEBUG" "adjust_dl_shaper_rate=0 -- dl is monitor-only; load_percent[dl] is referenced to base_dl_shaper_rate_kbps (${base_dl_shaper_rate_kbps}), which should match the fixed download CAKE bandwidth on ${dl_if}."
fi
if ((adjust_ul_shaper_rate == 0))
then
	min_shaper_rate_kbps[UL]=${base_ul_shaper_rate_kbps} max_shaper_rate_kbps[UL]=${base_ul_shaper_rate_kbps}
	log_msg "DEBUG" "adjust_ul_shaper_rate=0 -- ul is monitor-only; load_percent[ul] is referenced to base_ul_shaper_rate_kbps (${base_ul_shaper_rate_kbps}), which should match the fixed upload CAKE bandwidth on ${ul_if}."
fi

get_max_wire_packet_size_bits "${dl_if}" dl_max_wire_packet_size_bits
get_max_wire_packet_size_bits "${ul_if}" ul_max_wire_packet_size_bits

avg_owd_delta_us[DL]=0 avg_owd_delta_us[UL]=0

set_shaper_rates

LOAD_IDLE=0 LOAD_LOW=1 LOAD_HIGH=2
load_state_name=(idle low high)
load_state[DL]=${LOAD_IDLE} load_state[UL]=${LOAD_IDLE}

mapfile -t dl_delays < <(for ((i=0; i < bufferbloat_detection_window; i++)); do echo 0; done)
mapfile -t ul_delays < <(for ((i=0; i < bufferbloat_detection_window; i++)); do echo 0; done)
mapfile -t dl_owd_deltas_us < <(for ((i=0; i < bufferbloat_detection_window; i++)); do echo 0; done)
mapfile -t ul_owd_deltas_us < <(for ((i=0; i < bufferbloat_detection_window; i++)); do echo 0; done)

delays_idx=0 sum_dl_delays=0 sum_ul_delays=0 sum_dl_owd_deltas_us=0 sum_ul_owd_deltas_us=0

# Randomize reflectors array providing randomize_reflectors set to 1
log_msg "DEBUG" "Randomizing reflectors."
((randomize_reflectors)) && randomize_array reflectors

for ((pinger=0; pinger<no_pingers; pinger++))
do
	pinger_by_reflector["${reflectors[pinger]}"]=${pinger}
	dl_owd_baselines_us[pinger]=100000 ul_owd_baselines_us[pinger]=100000 \
	dl_owd_delta_ewmas_us[pinger]=0 ul_owd_delta_ewmas_us[pinger]=0
done

load_percent[DL]=0 load_percent[UL]=0
 
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

sustained_connection_idle=0 reflector_offences_idx=0 pingers_active=0 global_ping_response_timeout=0

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
t_last_cpu_usage_check_us=${t_start_us} \
t_last_bufferbloat_us[DL]=${t_start_us} t_last_bufferbloat_us[UL]=${t_start_us} \
t_last_decay_us[DL]=${t_start_us} t_last_decay_us[UL]=${t_start_us} \
t_last_reflector_health_check_us=${t_start_us} \
t_sustained_connection_idle_us=0 t_last_connection_idle_us=${t_start_us} reflectors_last_timestamp_us=${t_start_us} \
pingers_t_start_us=${t_start_us} t_last_reflector_replacement_us=${t_start_us} t_last_reflector_comparison_us=${t_start_us}

for ((pinger=0; pinger < no_pingers; pinger++))
do
	last_timestamp_reflectors_us[pinger]=${t_start_us}
done

# For each pinger initialize record of offences
for ((pinger=0; pinger < no_pingers; pinger++))
do
	for ((i=0; i<reflector_misbehaving_detection_window; i++))
	do
		reflector_offences[pinger*reflector_misbehaving_detection_window+i]=0
	done
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
				achieved_rate_kbps[DL]=${command[1]} achieved_rate_kbps[UL]=${command[2]} achieved_rate_updated[DL]=1 achieved_rate_updated[UL]=1
				((
					load_percent[DL]=100*achieved_rate_kbps[DL]/shaper_rate_kbps[DL],
					load_percent[UL]=100*achieved_rate_kbps[UL]/shaper_rate_kbps[UL]
				))

				if ((output_load_stats))
				then
					printf -v load_stats '%s; %s; %s; %s; %s' "${EPOCHREALTIME}" "${achieved_rate_kbps[DL]}" "${achieved_rate_kbps[UL]}" "${shaper_rate_kbps[DL]}" "${shaper_rate_kbps[UL]}"
					log_msg "LOAD" "${load_stats}"
				fi

				if (( load_percent[DL] > high_load_thr_percent ))
				then
					load_state[DL]=${LOAD_HIGH}
				elif (( achieved_rate_kbps[DL] > connection_active_thr_kbps ))
				then
					load_state[DL]=${LOAD_LOW}
				else
					load_state[DL]=${LOAD_IDLE}
				fi

				if (( load_percent[UL] > high_load_thr_percent ))
				then
					load_state[UL]=${LOAD_HIGH}
				elif (( achieved_rate_kbps[UL] > connection_active_thr_kbps ))
				then
					load_state[UL]=${LOAD_LOW}
				else
					load_state[UL]=${LOAD_IDLE}
				fi
			fi
			;;
		*)
			case "${pinger_method}" in

				irtt)
					if ((${#command[@]} == 5))
					then
						timestamp=${command[0]} reflector=${command[1]} seq=${command[2]} dl_owd_us=${command[3]} ul_owd_us=${command[4]} reflector_response=1
					fi
					;;
				tsping)
					if ((${#command[@]} == 10))
					then
						timestamp=${command[0]} reflector=${command[1]} seq=${command[2]} dl_owd_ms=${command[8]} ul_owd_ms=${command[9]} reflector_response=1
					fi
					;;
				fping)
					if ((${#command[@]} == 12)) && [[ ${command[6]} != *[!0-9.]* ]]
					then
						timestamp=${command[0]} reflector=${command[1]} seq=${command[3]} rtt_ms=${command[6]} reflector_response=1
					fi
					;;
				fping-ts)
					if ((${#command[@]} == 17))
					then
						timestamp=${command[0]} reflector=${command[1]} seq=${command[3]} originate=${command[13]#Originate=}000 received=${command[14]#Receive=}000 transmit=${command[15]#Transmit=}000 finished=${command[16]#Localreceive=}000 reflector_response=1
					fi
					;;
				ping)
					if ((${#command[@]} == 9)) && [[ ${command[7]} == time=* ]]
					then
						timestamp=${command[0]} reflector=${command[4]%:} seq=${command[5]} rtt_ms=${command[7]} reflector_response=1
					fi
					;;
				*)
					log_msg "ERROR" "Unknown pinger method: ${pinger_method}"
					kill $$ 2>/dev/null
				;;
			esac
			;;
	esac

	t_start_us=${EPOCHREALTIME/.}
	if ((reflector_response))
	then
		pinger=${pinger_by_reflector[${reflector}]:--1}
		((pinger >= 0)) || reflector_response=0
	fi

	case ${main_state} in

		RUNNING)
			if ((reflector_response))
			then
				# ICMP type 13 pings work with timestamps:
				# Originate; Received; Transmit; and Finished,
				#
				# such that:
				#
				# dl_owd_us = Finished - Transmit
				# ul_owd_us = Received - Originate
				#
				# The timestamps are supposed to relate to milliseconds past midnight UTC, albeit implementation varies, and,
				# in any case, timestamps rollover at the local and/or remote ends, and the rollover may not be synchronized.
				#
				# Such an event would result in a huge spike in dl_owd_us or ul_owd_us and a large delta relative to the baseline.
				#
				# So, to compensate, in the event that delta > 50 mins, immediately reset the baselines to the new dl_owd_us and ul_owd_us.
				#
				# Happilly, the sum of dl_owd_baseline_us and ul_owd_baseline_us will roughly equal rtt_baseline_us.
				# And since Transmit is approximately equal to Received, RTT is approximately equal to Finished - Originate.
				# And thus the sum of dl_owd_baseline_us and ul_owd_baseline_us should not be affected by the rollover/compensation.
				# Hence working with this sum, rather than the individual components, is useful for the reflector health check.
				
				# parse pinger response according to pinger method
				case ${pinger_method} in

					irtt)
						((
							dl_alpha = dl_owd_us >= dl_owd_baselines_us[pinger] ? alpha_baseline_increase : alpha_baseline_decrease,
							ul_alpha = ul_owd_us >= ul_owd_baselines_us[pinger] ? alpha_baseline_increase : alpha_baseline_decrease,

							dl_owd_baselines_us[pinger]=(dl_alpha*dl_owd_us+(1000000-dl_alpha)*dl_owd_baselines_us[pinger])/1000000,
							ul_owd_baselines_us[pinger]=(ul_alpha*ul_owd_us+(1000000-ul_alpha)*ul_owd_baselines_us[pinger])/1000000,

							dl_owd_delta_us=dl_owd_us - dl_owd_baselines_us[pinger],
							ul_owd_delta_us=ul_owd_us - ul_owd_baselines_us[pinger]
						))

						if (( load_percent[DL] < high_load_thr_percent && load_percent[UL] < high_load_thr_percent))
						then
							((
								dl_owd_delta_ewmas_us[pinger]=(alpha_delta_ewma*dl_owd_delta_us+(1000000-alpha_delta_ewma)*dl_owd_delta_ewmas_us[pinger])/1000000,
								ul_owd_delta_ewmas_us[pinger]=(alpha_delta_ewma*ul_owd_delta_us+(1000000-alpha_delta_ewma)*ul_owd_delta_ewmas_us[pinger])/1000000
							))
						fi
						
						timestamp_us=${timestamp}
						
						;;
					tsping)
						dl_owd_us=${dl_owd_ms}000 ul_owd_us=${ul_owd_ms}000

						((
							dl_owd_delta_us=dl_owd_us - dl_owd_baselines_us[pinger],
							ul_owd_delta_us=ul_owd_us - ul_owd_baselines_us[pinger]
						))


						if (( (${dl_owd_delta_us#-} + ${ul_owd_delta_us#-}) < 3000000000 ))
						then

							((
								dl_alpha = dl_owd_us >= dl_owd_baselines_us[pinger] ? alpha_baseline_increase : alpha_baseline_decrease,
								ul_alpha = ul_owd_us >= ul_owd_baselines_us[pinger] ? alpha_baseline_increase : alpha_baseline_decrease,

								dl_owd_baselines_us[pinger]=(dl_alpha*dl_owd_us+(1000000-dl_alpha)*dl_owd_baselines_us[pinger])/1000000,
								ul_owd_baselines_us[pinger]=(ul_alpha*ul_owd_us+(1000000-ul_alpha)*ul_owd_baselines_us[pinger])/1000000,

								dl_owd_delta_us=dl_owd_us - dl_owd_baselines_us[pinger],
								ul_owd_delta_us=ul_owd_us - ul_owd_baselines_us[pinger]
							))
						else
							dl_owd_baselines_us[pinger]=${dl_owd_us} ul_owd_baselines_us[pinger]=${ul_owd_us} dl_owd_delta_us=0 ul_owd_delta_us=0
						fi

						if (( load_percent[DL] < high_load_thr_percent && load_percent[UL] < high_load_thr_percent))
						then
							((
								dl_owd_delta_ewmas_us[pinger]=(alpha_delta_ewma*dl_owd_delta_us+(1000000-alpha_delta_ewma)*dl_owd_delta_ewmas_us[pinger])/1000000,
								ul_owd_delta_ewmas_us[pinger]=(alpha_delta_ewma*ul_owd_delta_us+(1000000-alpha_delta_ewma)*ul_owd_delta_ewmas_us[pinger])/1000000
							))
						fi

						timestamp_us=${timestamp//[.]}

						;;
					fping)
						seq=${seq#[} seq=${seq%]}
						printf -v rtt_us %.3f "${rtt_ms}"

						((
							dl_owd_us=10#${rtt_us//.}/2,
							ul_owd_us=dl_owd_us,
							dl_alpha = dl_owd_us >= dl_owd_baselines_us[pinger] ? alpha_baseline_increase : alpha_baseline_decrease,

							dl_owd_baselines_us[pinger]=(dl_alpha*dl_owd_us+(1000000-dl_alpha)*dl_owd_baselines_us[pinger])/1000000,
							ul_owd_baselines_us[pinger]=dl_owd_baselines_us[pinger],

							dl_owd_delta_us=dl_owd_us - dl_owd_baselines_us[pinger],
							ul_owd_delta_us=dl_owd_delta_us
						))

						if (( load_percent[DL] < high_load_thr_percent && load_percent[UL] < high_load_thr_percent))
						then
							((
								dl_owd_delta_ewmas_us[pinger]=(alpha_delta_ewma*dl_owd_delta_us+(1000000-alpha_delta_ewma)*dl_owd_delta_ewmas_us[pinger])/1000000,
								ul_owd_delta_ewmas_us[pinger]=dl_owd_delta_ewmas_us[pinger]
							))
						fi

						timestamp_us=${timestamp#[} timestamp_us=${timestamp_us%]}
						timestamp_us=${timestamp_us//.}0

						;;

					fping-ts)
						seq=${seq#[} seq=${seq%]}

						((
							dl_owd_us=finished-transmit,
							ul_owd_us=received-originate,
							dl_owd_delta_us=dl_owd_us - dl_owd_baselines_us[pinger],
							ul_owd_delta_us=ul_owd_us - ul_owd_baselines_us[pinger]
						))

						if (( (${dl_owd_delta_us#-} + ${ul_owd_delta_us#-}) < 3000000000 ))
						then

							((
								dl_alpha = dl_owd_us >= dl_owd_baselines_us[pinger] ? alpha_baseline_increase : alpha_baseline_decrease,
								ul_alpha = ul_owd_us >= ul_owd_baselines_us[pinger] ? alpha_baseline_increase : alpha_baseline_decrease,

								dl_owd_baselines_us[pinger]=(dl_alpha*dl_owd_us+(1000000-dl_alpha)*dl_owd_baselines_us[pinger])/1000000,
								ul_owd_baselines_us[pinger]=(ul_alpha*ul_owd_us+(1000000-ul_alpha)*ul_owd_baselines_us[pinger])/1000000,

								dl_owd_delta_us=dl_owd_us - dl_owd_baselines_us[pinger],
								ul_owd_delta_us=ul_owd_us - ul_owd_baselines_us[pinger]
							))
						else
							dl_owd_baselines_us[pinger]=${dl_owd_us} ul_owd_baselines_us[pinger]=${ul_owd_us} dl_owd_delta_us=0 ul_owd_delta_us=0
						fi

						if (( load_percent[DL] < high_load_thr_percent && load_percent[UL] < high_load_thr_percent))
						then
							((
								dl_owd_delta_ewmas_us[pinger]=(alpha_delta_ewma*dl_owd_delta_us+(1000000-alpha_delta_ewma)*dl_owd_delta_ewmas_us[pinger])/1000000,
								ul_owd_delta_ewmas_us[pinger]=(alpha_delta_ewma*ul_owd_delta_us+(1000000-alpha_delta_ewma)*ul_owd_delta_ewmas_us[pinger])/1000000
							))
						fi

						timestamp_us=${timestamp#[} timestamp_us=${timestamp_us%]}
						timestamp_us=${timestamp_us//.}0

						;;
					ping)
						seq=${seq//icmp_seq=} rtt_ms=${rtt_ms//time=}

						printf -v rtt_us %.3f "${rtt_ms}"

						((
							dl_owd_us=10#${rtt_us//.}/2,
							ul_owd_us=dl_owd_us,

							dl_alpha = dl_owd_us >= dl_owd_baselines_us[pinger] ? alpha_baseline_increase : alpha_baseline_decrease,

							dl_owd_baselines_us[pinger]=(dl_alpha*dl_owd_us+(1000000-dl_alpha)*dl_owd_baselines_us[pinger])/1000000,
							ul_owd_baselines_us[pinger]=dl_owd_baselines_us[pinger],

							dl_owd_delta_us=dl_owd_us - dl_owd_baselines_us[pinger],
							ul_owd_delta_us=dl_owd_delta_us
						))

						if (( load_percent[DL] < high_load_thr_percent && load_percent[UL] < high_load_thr_percent))
						then
							((
								dl_owd_delta_ewmas_us[pinger]=(alpha_delta_ewma*dl_owd_delta_us+(1000000-alpha_delta_ewma)*dl_owd_delta_ewmas_us[pinger])/1000000,
								ul_owd_delta_ewmas_us[pinger]=dl_owd_delta_ewmas_us[pinger]
							))
						fi

						timestamp_us=${timestamp#[} timestamp_us=${timestamp_us%]}
						timestamp_us=${timestamp_us//.}

						;;
					*)
						log_msg "ERROR" "Unknown pinger method: ${pinger_method}"
						exit 1
						;;
				esac

				last_timestamp_reflectors_us[pinger]=${timestamp_us} reflectors_last_timestamp_us=${timestamp_us}

				if (( (t_start_us - 10#${reflectors_last_timestamp_us})>500000 ))
				then
					log_msg "DEBUG" "processed response from [${reflector}] that is > 500ms old. Skipping."
					continue
				fi
				global_ping_response_timeout=0

				# Keep track of delays across detection window, detect any bufferbloat and determine load percentages
				((
					dl_delays[delays_idx] && (sum_dl_delays--),
					dl_delays[delays_idx] = dl_owd_delta_us > compensated_owd_delta_delay_thr_us[DL] ? 1 : 0,
					dl_delays[delays_idx] && (sum_dl_delays++),

					sum_dl_owd_deltas_us -= dl_owd_deltas_us[delays_idx],
					dl_owd_deltas_us[delays_idx] = dl_owd_delta_us,
					sum_dl_owd_deltas_us += dl_owd_delta_us,

					ul_delays[delays_idx] && (sum_ul_delays--),
					ul_delays[delays_idx] = ul_owd_delta_us > compensated_owd_delta_delay_thr_us[UL] ? 1 : 0,
					ul_delays[delays_idx] && (sum_ul_delays++),

					sum_ul_owd_deltas_us -= ul_owd_deltas_us[delays_idx],
					ul_owd_deltas_us[delays_idx] = ul_owd_delta_us,
					sum_ul_owd_deltas_us += ul_owd_delta_us,

					avg_owd_delta_us[DL] = sum_dl_owd_deltas_us / bufferbloat_detection_window,
					avg_owd_delta_us[UL] = sum_ul_owd_deltas_us / bufferbloat_detection_window,

					bufferbloat_detected[DL] = sum_dl_delays >= bufferbloat_detection_thr ? 1 : 0,
					bufferbloat_detected[UL] = sum_ul_delays >= bufferbloat_detection_thr ? 1 : 0,

					++delays_idx == bufferbloat_detection_window && (delays_idx=0)
				))

				# Update shaper rates
				for ((direction=DL; direction<=UL; direction++))
				do
					# bufferbloat detected, so decrease the rate providing not inside bufferbloat refractory period
					if (( bufferbloat_detected[direction] ))
					then
						if (( t_start_us > (t_last_bufferbloat_us[direction]+bufferbloat_refractory_period_us) ))
						then
							if (( compensated_avg_owd_delta_max_adjust_down_thr_us[direction] <= compensated_owd_delta_delay_thr_us[direction] ))
							then
								shaper_rate_adjust_down_factor=1000
							elif (( (avg_owd_delta_us[direction]-compensated_owd_delta_delay_thr_us[direction]) > 0 ))
							then
								((
									shaper_rate_adjust_down_factor=1000*(avg_owd_delta_us[direction]-compensated_owd_delta_delay_thr_us[direction])/(compensated_avg_owd_delta_max_adjust_down_thr_us[direction]-compensated_owd_delta_delay_thr_us[direction]),
									shaper_rate_adjust_down_factor > 1000 && (shaper_rate_adjust_down_factor=1000)
								))
							else
								shaper_rate_adjust_down_factor=0
							fi
							((
								shaper_rate_adjust_down=1000*shaper_rate_min_adjust_down_bufferbloat-shaper_rate_adjust_down_factor*(shaper_rate_min_adjust_down_bufferbloat-shaper_rate_max_adjust_down_bufferbloat),
								shaper_rate_kbps[direction]=shaper_rate_kbps[direction]*shaper_rate_adjust_down/1000000,
								t_last_bufferbloat_us[direction]=t_start_us,
								t_last_decay_us[direction]=t_start_us
							))
						fi
					# high load, so increase rate providing not inside bufferbloat refractory period
					elif (( load_state[direction] == LOAD_HIGH ))
					then
						if (( achieved_rate_updated[direction] && t_start_us > (t_last_bufferbloat_us[direction]+bufferbloat_refractory_period_us) ))
						then
							if (( compensated_owd_delta_delay_thr_us[direction] <= compensated_avg_owd_delta_max_adjust_up_thr_us[direction] ))
							then
								shaper_rate_adjust_up_factor=1000
							elif (( (compensated_owd_delta_delay_thr_us[direction]-avg_owd_delta_us[direction]) > 0 ))
							then
								((
									shaper_rate_adjust_up_factor=1000*(compensated_owd_delta_delay_thr_us[direction]-avg_owd_delta_us[direction])/(compensated_owd_delta_delay_thr_us[direction]-compensated_avg_owd_delta_max_adjust_up_thr_us[direction]),
									shaper_rate_adjust_up_factor > 1000 && (shaper_rate_adjust_up_factor=1000)
								))
							else
								shaper_rate_adjust_up_factor=0
							fi

							((
								shaper_rate_adjust_up=1000*shaper_rate_min_adjust_up_load_high-shaper_rate_adjust_up_factor*(shaper_rate_min_adjust_up_load_high-shaper_rate_max_adjust_up_load_high),
								shaper_rate_kbps[direction]=shaper_rate_kbps[direction]*shaper_rate_adjust_up/1000000,
								achieved_rate_updated[direction]=0,
								t_last_decay_us[direction]=t_start_us
							))
						fi
					# low or idle load, so determine whether to decay down towards base rate, decay up towards base rate, or set as base rate
					else
						if (( t_start_us > (t_last_decay_us[direction]+decay_refractory_period_us) ))
						then

							if ((shaper_rate_kbps[direction] > base_shaper_rate_kbps[direction]))
							then
								((
									decayed_shaper_rate_kbps=(shaper_rate_kbps[direction]*shaper_rate_adjust_down_load_low)/1000,
									shaper_rate_kbps[direction]=decayed_shaper_rate_kbps > base_shaper_rate_kbps[direction] ? decayed_shaper_rate_kbps : base_shaper_rate_kbps[direction]
								))
							elif ((shaper_rate_kbps[direction] < base_shaper_rate_kbps[direction]))
							then
								((
									decayed_shaper_rate_kbps=(shaper_rate_kbps[direction]*shaper_rate_adjust_up_load_low)/1000,
									shaper_rate_kbps[direction] = decayed_shaper_rate_kbps < base_shaper_rate_kbps[direction] ? decayed_shaper_rate_kbps : base_shaper_rate_kbps[direction]
								))
							fi

							t_last_decay_us[direction]=${t_start_us}
						fi
					fi
				done

				# make sure that updated shaper rates fall between configured minimum and maximum shaper rates
				((
					shaper_rate_kbps[DL] < min_shaper_rate_kbps[DL] && (shaper_rate_kbps[DL]=${min_shaper_rate_kbps[DL]}) ||
					shaper_rate_kbps[DL] > max_shaper_rate_kbps[DL] && (shaper_rate_kbps[DL]=${max_shaper_rate_kbps[DL]}),
					shaper_rate_kbps[UL] < min_shaper_rate_kbps[UL] && (shaper_rate_kbps[UL]=${min_shaper_rate_kbps[UL]}) ||
					shaper_rate_kbps[UL] > max_shaper_rate_kbps[UL] && (shaper_rate_kbps[UL]=${max_shaper_rate_kbps[UL]})
				))

				set_shaper_rates

				# update CPU usage stats if CPU monitoring interval exceeded
				if (( (output_cpu_stats || output_cpu_raw_stats) && t_start_us > t_last_cpu_usage_check_us + monitor_cpu_usage_interval_us ))
				then
					stats_read_time_us=${EPOCHREALTIME}
					for (( cpu_idx=0; cpu_idx<=cpu_cores; cpu_idx++ ))
					do
						read -r -a cpu_stats
						if (( output_cpu_stats ))
						then
							cpu_stats_vals=${cpu_stats[*]:1}
							((
								cpu_sum=${cpu_stats_vals// /+},
								cpu_delta=cpu_sum-last_cpu_sum[cpu_idx],
								cpu_idle=${cpu_stats[4]}-last_cpu_idle[cpu_idx],
								cpu_usage[cpu_idx]=(100*(cpu_delta-cpu_idle)/cpu_delta),
								last_cpu_sum[cpu_idx]=cpu_sum,
								last_cpu_idle[cpu_idx]=${cpu_stats[4]}
							))
						fi
						if (( output_cpu_raw_stats ))
						then
							cpu_raw_stats="${cpu_stats[*]}"	cpu_raw_stats="${stats_read_time_us}; ${cpu_raw_stats// /; }"
							log_msg "CPU_RAW" "${cpu_raw_stats}"
						fi
					done</proc/stat
					if (( output_cpu_stats ))
					then
						cpu_stats="${cpu_usage[*]}" cpu_stats="${stats_read_time_us}; ${cpu_stats// /; }"
						log_msg "CPU" "${cpu_stats}"
					fi
					t_last_cpu_usage_check_us=${t_start_us}
				fi

				if (( output_processing_stats || output_summary_stats ))
				then
					load_condition[DL]="dl_${load_state_name[${load_state[DL]}]}"
					load_condition[UL]="ul_${load_state_name[${load_state[UL]}]}"
					((bufferbloat_detected[DL])) && load_condition[DL]+=_bb
					((bufferbloat_detected[UL])) && load_condition[UL]+=_bb
				fi

				if (( output_processing_stats ))
				then
					printf -v processing_stats '%s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s' "${EPOCHREALTIME}" "${achieved_rate_kbps[DL]}" "${achieved_rate_kbps[UL]}" "${load_percent[DL]}" "${load_percent[UL]}" "${timestamp}" "${reflector}" "${seq}" "${dl_owd_baselines_us[pinger]}" "${dl_owd_us}" "${dl_owd_delta_ewmas_us[pinger]}" "${dl_owd_delta_us}" "${compensated_owd_delta_delay_thr_us[DL]}" "${ul_owd_baselines_us[pinger]}" "${ul_owd_us}" "${ul_owd_delta_ewmas_us[pinger]}" "${ul_owd_delta_us}" "${compensated_owd_delta_delay_thr_us[UL]}" "${sum_dl_delays}" "${avg_owd_delta_us[DL]}" "${compensated_avg_owd_delta_max_adjust_up_thr_us[DL]}" "${compensated_avg_owd_delta_max_adjust_down_thr_us[DL]}" "${sum_ul_delays}" "${avg_owd_delta_us[UL]}" "${compensated_avg_owd_delta_max_adjust_up_thr_us[UL]}" "${compensated_avg_owd_delta_max_adjust_down_thr_us[UL]}" "${load_condition[DL]}" "${load_condition[UL]}" "${shaper_rate_kbps[DL]}" "${shaper_rate_kbps[UL]}"
					log_msg "DATA" "${processing_stats}"
				fi

				if (( output_summary_stats ))
				then
					printf -v summary_stats '%s; %s; %s; %s; %s; %s; %s; %s; %s; %s' "${achieved_rate_kbps[DL]}" "${achieved_rate_kbps[UL]}" "${sum_dl_delays}" "${sum_ul_delays}" "${avg_owd_delta_us[DL]}" "${avg_owd_delta_us[UL]}" "${load_condition[DL]}" "${load_condition[UL]}" "${shaper_rate_kbps[DL]}" "${shaper_rate_kbps[UL]}"
					log_msg "SUMMARY" "${summary_stats}"
				fi

				# If base rate is sustained, increment sustained base rate timer (and break out of processing loop if enough time passes)
				if (( enable_sleep_function ))
				then
					if (( load_state[DL] == LOAD_IDLE && load_state[UL] == LOAD_IDLE ))
					then
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
								set_min_shaper_rates
							fi

							stop_pingers

							t_sustained_connection_idle_us=0 sustained_connection_idle=0
						fi
					else
						t_sustained_connection_idle_us=0 sustained_connection_idle=0
					fi
				fi
			elif (( (t_start_us - reflectors_last_timestamp_us) > stall_detection_timeout_us ))
			then

				log_msg "DEBUG" "Warning: no reflector response within: ${stall_detection_timeout_s} seconds. Checking loads."

				log_msg "DEBUG" "load check is: (( ${achieved_rate_kbps[DL]} kbps > ${connection_stall_thr_kbps} kbps for download && ${achieved_rate_kbps[UL]} kbps > ${connection_stall_thr_kbps} kbps for upload ))"

				handle_global_ping_response_timeout

				# non-zero load so despite no reflector response within stall interval, the connection not considered to have stalled
				# and therefore resume normal operation
				if (( achieved_rate_kbps[DL] > connection_stall_thr_kbps && achieved_rate_kbps[UL] > connection_stall_thr_kbps ))
				then

					log_msg "DEBUG" "load above connection stall threshold so resuming normal operation."
				else
					change_state_main "STALL"
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

					[[ "${dl_owd_baselines_us[0]:-}" && "${dl_owd_delta_ewmas_us[0]:-}" && "${ul_owd_baselines_us[0]:-}" && "${ul_owd_delta_ewmas_us[0]:-}" ]] || continue

					((
						min_sum_owd_baselines_us = dl_owd_baselines_us[0] + ul_owd_baselines_us[0],
						min_dl_owd_delta_ewma_us=dl_owd_delta_ewmas_us[0],
						min_ul_owd_delta_ewma_us=ul_owd_delta_ewmas_us[0]
					))

					for ((pinger=0; pinger < no_pingers; pinger++))
					do
						[[ ${dl_owd_baselines_us[pinger]:-} && ${dl_owd_delta_ewmas_us[pinger]:-} && ${ul_owd_baselines_us[pinger]:-} && ${ul_owd_delta_ewmas_us[pinger]:-} ]] || continue 2

						((
							sum_owd_baselines_us[pinger] = dl_owd_baselines_us[pinger] + ul_owd_baselines_us[pinger],
							sum_owd_baselines_us[pinger] < min_sum_owd_baselines_us && (min_sum_owd_baselines_us=sum_owd_baselines_us[pinger]),
							dl_owd_delta_ewmas_us[pinger] < min_dl_owd_delta_ewma_us && (min_dl_owd_delta_ewma_us=dl_owd_delta_ewmas_us[pinger]),
							ul_owd_delta_ewmas_us[pinger] < min_ul_owd_delta_ewma_us && (min_ul_owd_delta_ewma_us=ul_owd_delta_ewmas_us[pinger])

						))
					done

					for ((pinger=0; pinger < no_pingers; pinger++))
					do

						((
							sum_owd_baselines_delta_us = sum_owd_baselines_us[pinger] - min_sum_owd_baselines_us,
							dl_owd_delta_ewma_delta_us = dl_owd_delta_ewmas_us[pinger] - min_dl_owd_delta_ewma_us,
							ul_owd_delta_ewma_delta_us = ul_owd_delta_ewmas_us[pinger] - min_ul_owd_delta_ewma_us
						))

						if ((output_reflector_stats))
						then
							printf -v reflector_stats '%s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s; %s' "${EPOCHREALTIME}" "${reflectors[pinger]}" "${min_sum_owd_baselines_us}" "${sum_owd_baselines_us[pinger]}" "${sum_owd_baselines_delta_us}" "${reflector_sum_owd_baselines_delta_thr_us}" "${min_dl_owd_delta_ewma_us}" "${dl_owd_delta_ewmas_us[pinger]}" "${dl_owd_delta_ewma_delta_us}" "${reflector_owd_delta_ewma_delta_thr_us}" "${min_ul_owd_delta_ewma_us}" "${ul_owd_delta_ewmas_us[pinger]}" "${ul_owd_delta_ewma_delta_us}" "${reflector_owd_delta_ewma_delta_thr_us}"
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
					((reflector_offence_idx=pinger*reflector_misbehaving_detection_window+reflector_offences_idx))

					((
						reflector_offences[reflector_offence_idx] && (sum_reflector_offences[pinger]--),
						reflector_offences[reflector_offence_idx] = (t_start_us-last_timestamp_reflectors_us[pinger]) > reflector_response_deadline_us ? 1 : 0
					))

					if (( reflector_offences[reflector_offence_idx] ))
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
					++reflector_offences_idx == reflector_misbehaving_detection_window && (reflector_offences_idx=0),
					t_last_reflector_health_check_us=t_start_us
				))
			fi
			;;
		IDLE)
			if (( achieved_rate_kbps[DL] > connection_active_thr_kbps || achieved_rate_kbps[UL] > connection_active_thr_kbps ))
			then
				log_msg "DEBUG" "dl achieved rate: ${achieved_rate_kbps[DL]} kbps or ul achieved rate: ${achieved_rate_kbps[UL]} kbps exceeded connection active threshold: ${connection_active_thr_kbps} kbps. Resuming normal operation."
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

			if (( reflector_response || achieved_rate_kbps[DL] > connection_stall_thr_kbps && achieved_rate_kbps[UL] > connection_stall_thr_kbps ))
			then
				if ((reflector_response))
				then
					log_msg "DEBUG" "Reflector response detected."
				else
					log_msg "DEBUG" "dl achieved rate: ${achieved_rate_kbps[DL]} kbps and ul achieved rate: ${achieved_rate_kbps[UL]} kbps exceeded connection stall threshold: ${connection_stall_thr_kbps} kbps."
				fi
				log_msg "DEBUG" "Connection stall ended. Resuming normal operation."
				change_state_main "RUNNING"
			fi

			handle_global_ping_response_timeout
			;;
		*)
			log_msg "ERROR" "Unrecognized main state: ${main_state}. Exiting now."
			exit 1
			;;
	esac
done
