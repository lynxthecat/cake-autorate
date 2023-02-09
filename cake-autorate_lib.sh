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
	read -r -u "${__sleep_fd}" || :
}

sleep_s()
{
	# calling external sleep binary is slow
	# bash does have a loadable sleep
	# but read's timeout can more portably be exploited and this is apparently even faster anyway

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

if (( __set_e == 1 )); then
    set +e
fi
unset __set_e
