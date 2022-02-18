#!/bin/bash

# monitor_reflector_path.sh compares ping results with a baseline to ascertain whether reflector path is delayed

# monitor_reflector_path.sh is part of CAKE-autorate
# CAKE-autorate automatically adjusts bandwidth for CAKE in dependence on detected load and RTT

# inspired by @moeller0 (OpenWrt forum)
# initial sh implementation by @Lynx (OpenWrt forum)
# requires packages: iputils-ping, coreutils-date and coreutils-sleep

get_OWDs()
{
	local reflector
	reflector=$1

	RTT=$(/usr/bin/ping -c 1 $reflector | tail -1 | awk '{print $4}' | cut -d '/' -f 1)

	# If no response whatsoever, just set RTT=0
	re='^[0-9]+([.][0-9]+)?$'
	if ! [[ $RTT =~ $re ]] ; then
		RTT=0
	fi
	
	#convert RTT to microseconds
	RTT=$(x1000 $RTT)
 	ul_OWD=$(( $RTT / 2 ))
	dl_OWD=$ul_OWD	

	echo $ul_OWD $dl_OWD
}

update_OWD_baseline() 
{
	local OWD=$1
	local OWD_delta=$2
	local OWD_baseline=$3
	local alpha_OWD_increase=$4
	local alpha_OWD_decrease=$5

	local OWD_baseline

	if (( $OWD_delta >= 0 )); then
		OWD_baseline=$(( ( (1000-$(x1000 $alpha_OWD_increase))*$OWD_baseline+$(x1000 $alpha_OWD_increase)*$OWD )/1000 ))
	else
		OWD_baseline=$(( ( (1000-$(x1000 $alpha_OWD_decrease))*$OWD_baseline+$(x1000 $alpha_OWD_decrease)*$OWD )/1000 ))
	fi

	echo $OWD_baseline
}

detect_path_delay()
{
	local -n OWD_deltas=$1
	local delay_thr=$2
	local detection_thr=$3

	detection_cnt=0

	for delta in "${OWD_deltas[@]}"
	do
		if (( $delta > $(x1000 $delay_thr) )); then ((detection_cnt+=1)); fi
	done

	(( $detection_cnt >= $detection_thr ))
	return
}

monitor_reflector_path() 
{
	local reflector=$1

	ul_OWD_deltas=( $(printf ' 0%.0s' $(seq $delay_buffer_len)) )
	dl_OWD_deltas=( $(printf ' 0%.0s' $(seq $delay_buffer_len)) )

	reflector_ul_path_delayed_file="/tmp/CAKE-autorate/${reflector}_ul_path_delayed"
	reflector_dl_path_delayed_file="/tmp/CAKE-autorate/${reflector}_dl_path_delayed"

	[ ! -d "/tmp/CAKE-autorate" ] && mkdir "/tmp/CAKE-autorate"

        OWDs=$(get_OWDs 8.8.8.8)

        ul_OWD=$(echo $OWDs | awk '{print $1}')
        dl_OWD=$(echo $OWDs | awk '{print $2}')

        ul_OWD_baseline=$ul_OWD
        dl_OWD_baseline=$dl_OWD

	while true; do
		
		t_start=$(date +%s%N)

		OWDs=$(get_OWDs $reflector)
	
		ul_OWD=$(echo $OWDs | awk '{print $1}')
		dl_OWD=$(echo $OWDs | awk '{print $2}')

		if (($ul_OWD==0 || $dl_OWD==0)); then
			t_end=$(date +%s%N)
			sleep_remaining_tick_time $t_start $t_end $monitor_reflector_path_tick_duration
			continue
		fi	

		ul_OWD_delta=$(( $ul_OWD-$ul_OWD_baseline ))
		dl_OWD_delta=$(( $dl_OWD-$dl_OWD_baseline ))

		ul_OWD_deltas+=($ul_OWD_delta)
		unset 'ul_OWD_deltas[0]'
		ul_OWD_deltas=(${ul_OWD_deltas[*]})

		dl_OWD_deltas+=($dl_OWD_delta)
		unset 'dl_OWD_deltas[0]'
		dl_OWD_deltas=(${dl_OWD_deltas[*]})

		#echo "ul_OWD_baseline" $ul_OWD_baseline "ul_OWD=" $ul_OWD "ul_OWD_deltas=" ${ul_OWD_deltas[@]}

		ul_OWD_baseline=$(update_OWD_baseline $ul_OWD $ul_OWD_delta $ul_OWD_baseline 0.001 0.9)
		dl_OWD_baseline=$(update_OWD_baseline $dl_OWD $dl_OWD_delta $dl_OWD_baseline 0.001 0.9)

		if detect_path_delay ul_OWD_deltas $delay_thr $detection_thr; then
			touch $reflector_ul_path_delayed_file
		elif [ -f $reflector_ul_path_delayed_file ]; then
			rm $reflector_ul_path_delayed_file
		fi
	
		if detect_path_delay dl_OWD_deltas $delay_thr $detection_thr; then
			touch $reflector_dl_path_delayed_file
		elif [ -f $reflector_dl_path_delayed_file ]; then
			rm $reflector_dl_path_delayed_file
		fi
	
		t_end=$(date +%s%N)
		sleep_remaining_tick_time $t_start $t_end $monitor_reflector_path_tick_duration
done
}
