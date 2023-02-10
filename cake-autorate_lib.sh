#!/bin/bash
# lib.sh -- common functions for use by cake-autorate.sh
# This file is part of cake-autorate.

__set_e=0
if [[ ! ${-} =~ e ]]; then
    set -e
    __set_e=1
fi

exec {__sleep_fd}<> <(:)

sleep_inf()
{
	# sleeps forever
	read -r <&${__sleep_fd:?} || true
}

sleep_s()
{
	# calling external sleep binary is slow
	# bash does have a loadable sleep
	# but read's timeout can more portably be exploited and this is apparently even faster anyway

	local sleep_duration_s=${1} # (seconds, e.g. 0.5, 1 or 1.5)
	read -r -t "${sleep_duration_s}" <&${__sleep_fd:?} || true
}

sleep_us()
{
	local sleep_duration_us=${1} # (microseconds)

	sleep_duration_s=000000${sleep_duration_us}
	sleep_duration_s=$((10#${sleep_duration_s::-6})).${sleep_duration_s: -6}
	sleep_s "${sleep_duration_s}"
}

sleep_remaining_tick_time()
{
	# sleeps until the end of the tick duration

	local t_start_us=${1} # (microseconds)
	local tick_duration_us=${2} # (microseconds)

	sleep_duration_us=$(( t_start_us + tick_duration_us - ${EPOCHREALTIME/./} ))

	if (( sleep_duration_us > 0 )); then
		sleep_us ${sleep_duration_us}
	fi
}

randomize_array()
{
	local -n array=${1}

	subset=("${array[@]}")
	array=()
	for ((set=${#subset[@]}; set>0; set--))
	do
		idx=$((RANDOM%set))
		array+=("${subset[idx]}")
		unset "subset[idx]"
		subset=("${subset[@]}")
	done
}

lock()
{
	local path=${1}

	while true; do
		( set -o noclobber; echo "$$" > "${path:?}" ) 2> /dev/null && return 0
		sleep_us 100000
	done
}

unlock()
{
	local path=${1}

	rm -f "${path:?}"
}

proc_man_set_key()
{
	local key=${1}
	local value=${2}

	local entered=0
	while read -r line; do
		if [[ ${line} =~ ^${key}= ]]; then
			printf '%s\n' "${key}=${value}"
			entered=1
		else
			printf '%s\n' "${line}"
		fi
	done < "${proc_state_file:?}" > "${proc_state_file:?}.tmp"
	if (( entered == 0 )); then
		printf '%s\n' "${key}=${value}" >> "${proc_state_file:?}.tmp"
	fi
	mv "${proc_state_file:?}.tmp" "${proc_state_file:?}"
	return 0
}

proc_man_get_key_value()
{
	local key=${1}

	while read -r line; do
		if [[ ${line} =~ ^${key}= ]]; then
			printf '%s\n' "${line#*=}"
			return 0
		fi
	done < "${proc_state_file:?}"
	return 1
}

proc_man()
{
	local proc_state_file="${proc_state_file:-${run_path}/proc_state}"
	local proc_state_file_lock="${proc_state_file_lock:-${proc_state_file}.lock}"
	local name=${1}
	local action=${2}
	shift 2

	lock "${proc_state_file_lock:?}"
	trap 'unlock "${proc_state_file_lock:?}"' RETURN

	if [[ ! -f "${proc_state_file:?}" ]]; then
		true > "${proc_state_file:?}"
	fi

	case "${action}" in
		"start")
			pid=$(proc_man_get_key_value "${name}" "${proc_state_file:?}")
			if (( pid && pid > 0 )) && kill -0 "${pid}" 2> /dev/null; then
				return 1;
			fi

			"${@}" &
			local pid=${!}
			proc_man_set_key "${name}" "${pid}" "${proc_state_file:?}"
			;;
		"stop")
			local pid
			pid=$(proc_man_get_key_value "${name}" "${proc_state_file:?}")
			if ! (( pid && pid > 0 )); then
				return 0;
			fi

			kill "${pid}"

			# wait for process to die
			killed=0
			for ((i=0; i<10; i++));
			do
				if kill -0 "${pid}" 2> /dev/null; then
					sleep_us 100000
				else
					killed=1
					break
				fi
			done

			# if process still alive, kill it with fire
			if (( killed == 0 )); then
				kill -9 "${pid}"
			fi

			proc_man_set_key "${name}" "-1" "${proc_state_file:?}"
			;;
		"status")
			local pid
			pid=$(proc_man_get_key_value "${name}" "${proc_state_file:?}")
			if (( pid && pid > 0 )); then
				if kill -0 "${pid}" 2> /dev/null; then
					printf '%s\n' "running"
				else
					printf '%s\n' "dead"
				fi
			else
				printf '%s\n' "stopped"
			fi
			;;
		"wait")
			local pid
			pid=$(proc_man_get_key_value "${name}" "${proc_state_file:?}")
			if (( pid && pid > 0 )); then
				wait "${pid}"
			fi
			;;
		"signal")
			shift 3

			local pid
			pid=$(proc_man_get_key_value "${name}" "${proc_state_file:?}")
			if (( pid && pid > 0 )) && kill -0 "${pid}" 2> /dev/null; then
				kill -s "${1}" "${pid}"
			else
				return 1
			fi
			;;
		*)
			printf '%s\n' "unknown action: ${action}" >&2
			return 1
			;;
	esac

	return 0
}

if (( __set_e == 1 )); then
    set +e
fi
unset __set_e
