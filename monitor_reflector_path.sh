#!/bin/bash

# monitor_reflector_path.sh compares ping results with a baseline to ascertain whether reflector path is delayed

# monitor_reflector_path.sh is part of CAKE-autorate
# CAKE-autorate automatically adjusts bandwidth for CAKE in dependence on detected load and RTT

# inspired by @moeller0 (OpenWrt forum)
# initial sh implementation by @Lynx (OpenWrt forum)
# requires packages: iputils-ping, coreutils-date and coreutils-sleep

ping_reflector()
{
	local reflector=$1

	exec /usr/bin/ping -i $ping_reflector_interval $reflector > /tmp/CAKE-autorate/${reflector}_ping_output
}

update_OWD_baseline() 
{
	local OWD=$1
	local OWD_delta=$2
	local OWD_baseline=$3

	local OWD_baseline

	if (( $OWD_delta >= 0 )); then
		OWD_baseline=$(( ( (1000-$alpha_OWD_increase)*$OWD_baseline+$alpha_OWD_increase*$OWD )/1000 ))
	else
		OWD_baseline=$(( ( (1000-$alpha_OWD_decrease)*$OWD_baseline+$alpha_OWD_decrease*$OWD )/1000 ))
	fi

	echo $OWD_baseline
}

detect_path_delay()
{
	local -n OWD_deltas=$1
	
	local detection_cnt

	detection_cnt=0

	for delta in "${OWD_deltas[@]}"
	do
		if (( $delta > (1000*$delay_thr) )); then ((detection_cnt+=1)); fi
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

	RTT=$(/usr/bin/ping -c 1 $reflector | awk -Ftime= 'NF>1{print 1000*($2+0)}')
	#convert RTT to microseconds
 	ul_OWD=$(( $RTT / 2 ))
	dl_OWD=$ul_OWD	

        ul_OWD_baseline=$ul_OWD
        dl_OWD_baseline=$dl_OWD

	tail -f /tmp/CAKE-autorate/${reflector}_ping_output | while read ping_line
	do
		RTT=$(echo $ping_line | awk -Ftime= 'NF>1{print 1000*($2+0)}')
		[ -z "$RTT" ] && continue
		
		#echo $ping_line

		#convert RTT to microseconds
 		ul_OWD=$(( $RTT / 2 ))
		dl_OWD=$ul_OWD	
		
		ul_OWD_delta=$(( $ul_OWD-$ul_OWD_baseline ))
		dl_OWD_delta=$(( $dl_OWD-$dl_OWD_baseline ))

		ul_OWD_deltas+=($ul_OWD_delta)
		unset 'ul_OWD_deltas[0]'
		ul_OWD_deltas=(${ul_OWD_deltas[*]})

		dl_OWD_deltas+=($dl_OWD_delta)
		unset 'dl_OWD_deltas[0]'
		dl_OWD_deltas=(${dl_OWD_deltas[*]})

		#echo "ul_OWD_baseline" $ul_OWD_baseline "ul_OWD=" $ul_OWD "ul_OWD_deltas=" ${ul_OWD_deltas[@]}

		ul_OWD_baseline=$(update_OWD_baseline $ul_OWD $ul_OWD_delta $ul_OWD_baseline)
		dl_OWD_baseline=$(update_OWD_baseline $dl_OWD $dl_OWD_delta $dl_OWD_baseline)


		if detect_path_delay ul_OWD_deltas; then
			if [ ! -f $reflector_ul_path_delayed_file ]; then
				touch $reflector_ul_path_delayed_file
			#	echo $reflector "Upload path is delayed! Deltas ="  "${ul_OWD_deltas[@]}"
			fi
		elif [ -f $reflector_ul_path_delayed_file ]; then
			rm $reflector_ul_path_delayed_file
		fi
	
		if detect_path_delay dl_OWD_deltas; then
			if [ ! -f $reflector_dl_path_delayed_file ]; then
				touch $reflector_dl_path_delayed_file
			#	echo $reflector "Download path is delayed! Deltas ="  "${dl_OWD_deltas[@]}"
			fi
		elif [ -f $reflector_dl_path_delayed_file ]; then
			rm $reflector_dl_path_delayed_file
		fi
		> /tmp/CAKE-autorate/${reflector}_ping_output
	done
}
