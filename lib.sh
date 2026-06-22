#!/usr/bin/env bash

# lib.sh -- common functions for use by cake-autorate.sh
#
# This file is part of cake-autorate.

__set_e=0
if [[ ! ${-} =~ e ]]
then
    set -e
    __set_e=1
fi

if [[ -z ${__sleep_fd:-} ]]
then
	exec {__sleep_fd}<> <(:)
fi

typeof() 
{
	# typeof -- returns the type of a variable

	local type_sig
	type_sig=$(declare -p "${1}" 2>/dev/null)
	if [[ "${type_sig}" =~ "declare --" ]]
	then
		str_type "${1}"
	elif [[ "${type_sig}" =~ "declare -a" ]]
	then
		printf "array"
	elif [[ "${type_sig}" =~ "declare -A" ]]
	then
		printf "map"
	else
		printf "none"
	fi
}

str_type() 
{
	# str_type -- returns the type of a string

	local -n str=${1}

	if [[ "${str}" =~ ^[0-9]+$ ]]
	then
		printf "integer"
	elif [[ "${str}" =~ ^[0-9]*\.[0-9]+$ ]]
	then
		printf "float"
	elif [[ "${str}" =~ ^-[0-9]+$ ]]
	then
		printf "negative-integer"
	elif [[ "${str}" =~ ^-[0-9]*\.[0-9]+$ ]]
	then
		printf "negative-float"
	else
		# technically not validated, user is just trusted to call
		# this function with valid strings
		printf "string"
	fi
}

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

	# ${1} = sleep_duration_s (seconds, e.g. 0.5, 1 or 1.5)

	read -r -t "${1}" -u "${__sleep_fd}" || :
}

sleep_us()
{
	# ${1} = sleep_duration_us (microseconds)

	printf -v sleep_duration_s %.1f "${1}e-6"
	read -r -t "${sleep_duration_s}" -u "${__sleep_fd}" || :
}

sleep_remaining_tick_time()
{
	# sleeps until the end of the tick duration

	# ${1} = t_start_us (microseconds)
	# ${2} = tick_duration_us (microseconds)

	# shellcheck disable=SC2154
	((
		sleep_duration_us=${1} + ${2} - ${EPOCHREALTIME/.},
		sleep_duration_us < 0 && (sleep_duration_us=0)
	))

	printf -v sleep_duration_s %.1f "${sleep_duration_us}e-6"
	read -r -t "${sleep_duration_s}" -u "${__sleep_fd}" || :
}

randomize_array()
{
	# randomize the order of the elements of an array
	# see: https://en.wikipedia.org/wiki/Fisher%E2%80%93Yates_shuffle

	local -n array=${1}

	for ((set=${#array[@]}-1; set>0; set--))
	do
		# j must be uniform in [0, set] INCLUSIVE for an unbiased Fisher-Yates.
		# RANDOM%set gives [0, set-1], excluding the current index -> that is
		# Sattolo's algorithm (only cyclic permutations; an element can never
		# stay put), which biases the startup reflector shuffle.
		idx=$((RANDOM%(set+1)))
		temp=${array[set]}
		array[set]=${array[idx]}
		array[idx]=${temp}
	done
}

generate_run_token()
{
	local run_token

	run_token=$(head -c 32 /dev/urandom 2>/dev/null | hexdump -v -e '/1 "%02x"') || return 1
	[[ ${#run_token} -eq 64 ]] || return 1

	printf '%s\n' "${run_token}"
}

running_process_matches_run_token()
{
	local pid=${1} run_token=${2}

	[[ ${pid} =~ ^[0-9]+$ && -n ${run_token} && -r /proc/${pid}/environ ]] || return 1
	tr '\0' '\n' < "/proc/${pid}/environ" 2>/dev/null | grep -Fxq "CAKE_AUTORATE_RUN_TOKEN=${run_token}"
}

get_running_main_pid_for_run_path()
{
	local run_path=${1} running_main_pid running_run_token

	[[ -f ${run_path}/proc_pids ]] || return 1
	[[ -f ${run_path}/run_token ]] || return 1
	running_main_pid=$(awk -F= '/^main=/ {print $2}' "${run_path}/proc_pids") || return 1
	[[ ${running_main_pid} =~ ^[0-9]+$ && -d /proc/${running_main_pid} ]] || return 1
	read -r running_run_token < "${run_path}/run_token" || return 1
	running_process_matches_run_token "${running_main_pid}" "${running_run_token}" || return 1

	printf '%s\n' "${running_main_pid}"
}

terminate()
{
	# Send regular kill to processes and monitor terminations;
	# return as soon as all of the active processes terminate;
	# if any processes remain active after timeout (defaults to one second),
	# then kill with fire using kill -9;
	# and, finally, call wait on all processes to reap any zombie processes.

	local pids=${1} timeout_ms=${2:-1000}

	read -r -a pids <<< "${pids}"

	# `--` is required: for the irtt pinger method pids are negated pgids (set -m),
	# and `kill -123` parses the leading dash as a signal spec ("invalid signal
	# specification") and delivers nothing -- so the graceful TERM (and, with >1
	# pinger, the -9 fallback too) silently no-op and irtt children leak.
	kill -TERM -- "${pids[@]}" 2> /dev/null

	for ((i=0; i<timeout_ms; i+=100))
	do
		for process in "${!pids[@]}"
		do
			kill -0 "${pids[${process}]}" 2> /dev/null || unset "pids[${process}]"
		done
		[[ "${pids[*]}" ]] || return
		sleep_s 0.1
	done

	kill -KILL -- "${pids[@]}" 2> /dev/null
}

if (( __set_e == 1 ))
then
    set +e
fi
unset __set_e
