#!/bin/bash
# cake-autorate_lib.sh -- common functions for use by cake-autorate.sh
# This file is part of cake-autorate.

__set_e=0
if [[ ! ${-} =~ e ]]; then
    set -e
    __set_e=1
fi

exec {__sleep_fd}<> <(:) || true

sleep_s()
{
	# Calling the external sleep binary could be rather slow,
	# especially as it is called very frequently and typically on mediocre hardware.
	#
	# bash's loadable sleep module is not typically available
	# in OpenWRT and most embedded systems, and use of the bash
	# read command with a timeout offers performance that is
	# at least on a par with bash's sleep module.
	#
	# For benchmarks, check the following links:
	# - https://github.com/lynxthecat/cake-autorate/issues/174#issuecomment-1460057382
	# - https://github.com/lynxthecat/cake-autorate/issues/174#issuecomment-1460074498

	local sleep_duration_s=${1} # (seconds, e.g. 0.5, 1 or 1.5)
	read -r -t "${sleep_duration_s}" -u "${__sleep_fd}" || : 
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

	# shellcheck disable=SC2154
	sleep_duration_us=$(( t_start_us + tick_duration_us - ${EPOCHREALTIME/./} ))

	if (( sleep_duration_us > 0 )); then
		sleep_us "${sleep_duration_us}"
	fi
}

get_remaining_tick_time()
{
	# updates sleep_duration_s remaining to end of tick duration

	local t_start_us=${1} # (microseconds)
	local tick_duration_us=${2} # (microseconds)

	sleep_duration_us=$(( t_start_us + tick_duration_us - ${EPOCHREALTIME/./} ))
	((sleep_duration_us<0)) && sleep_duration_us=0
	sleep_duration_s=000000${sleep_duration_us}
	sleep_duration_s=$((10#${sleep_duration_s::-6})).${sleep_duration_s: -6}
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

terminate()
{
	# Send regular kill to processes and monitor terminations;
	# return as soon as all of the active processes terminate;
	# if any processes remain active after one second, kill with fire using kill -9;
	# and, finally, call wait on all processes to reap any zombie processes.

	local pids=("${@:-}")
	
	kill "${pids[@]}" 2> /dev/null

	for((i=0; i<10; i++))
	do
		for process in "${!pids[@]}"
		do
			kill -0 "${pids[${process}]}" 2> /dev/null || unset "pids[${process}]"
		done
		[[ "${pids[*]}" ]] || return
		sleep_s 0.1
	done

	kill -9 "${pids[@]}" 2> /dev/null
}


if (( __set_e == 1 )); then
    set +e
fi
unset __set_e
