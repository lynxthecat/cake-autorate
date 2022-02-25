#!/bin/bash

# CAKE-autorate automatically adjusts bandwidth for CAKE in dependence on detected load and OWD/RTT

# inspired by @moeller0 (OpenWrt forum)
# initial sh implementation by @Lynx (OpenWrt forum)
# requires packages: bash, iputils-ping, coreutils-date, coreutils-sleep, inotifywait

trap cleanup_and_killall INT TERM EXIT

cleanup_and_killall()
{
	echo "Killing all background processes and cleaning up /tmp files."
	trap - INT && trap - TERM && trap - EXIT && kill -- ${bg_PIDs[@]}
	[ -d "/tmp/CAKE-autorate" ] && rm -r "/tmp/CAKE-autorate"
	exit
}

install_dir="/root/CAKE-autorate/"

. $install_dir"defaults.sh"
. $install_dir"functions.sh"
. $install_dir"monitor_reflector_path.sh"


# test if stdout is a tty (terminal)
[[ ! -t 1 ]] &&	exec &> /tmp/cake-autorate.log

get_next_shaper_rate() 
{
    	local cur_rate=$1
	local cur_min_rate=$2
	local cur_base_rate=$3
	local cur_max_rate=$4
    	local high_load=$5
	local bufferbloat_detected=$6
	local t_elapsed_rate_set=$7

    	local next_rate
	local cur_rate_decayed_down
 	local cur_rate_decayed_up

 	# in case of supra-threshold OWD spikes decrease the rate so long as there is a load and elapsed time > refractory period
        if (( bufferbloat_detected )); then
		if (($t_elapsed_rate_set > (10**6)*$rate_down_bufferbloat_refractory_period)); then
        		next_rate=$(( $cur_rate*(1000-$rate_adjust_OWD_spike)/1000 ))
		else
			next_rate=$cur_rate
		fi
        else
            # ... otherwise determine whether to increase or decrease the rate in dependence on load
            # high load, so we would like to increase the rate
            if (($high_load)); then
                next_rate=$(($cur_rate*(1000+$rate_adjust_load_high)/1000 ))
            else
		if (($t_elapsed_rate_set > (10**6)*$rate_down_decay_refractory_period)); then
		
			 # low load, so determine whether to decay down towards base rate, decay up towards base rate, or set as base rate
	                cur_rate_decayed_down=$(($cur_rate*(1000-$rate_adjust_load_low)/1000))
        	        cur_rate_decayed_up=$(($cur_rate*(1000+$rate_adjust_load_low)/1000))

                	# gently decrease to steady state rate
	                if (($cur_rate_decayed_down > $cur_base_rate)); then
        	                next_rate=$cur_rate_decayed_down
                	# gently increase to steady state rate
	                elif (($cur_rate_decayed_up < $cur_base_rate)); then
        	                next_rate=$cur_rate_decayed_up
                	# steady state has been reached
	                else
        	                next_rate=$cur_base_rate
        		fi
		else
			next_rate=$cur_rate
		fi
        fi
        fi

        # make sure to only return rates between cur_min_rate and cur_max_rate
        if (($next_rate < $cur_min_rate)); then
            next_rate=$cur_min_rate;
        fi

        if (($next_rate > $cur_max_rate)); then
            next_rate=$cur_max_rate;
        fi

        echo "${next_rate}"
}

# update download and upload rates for CAKE
update_loads()
{
        cur_rx_bytes=$(cat $rx_bytes_path)
        cur_tx_bytes=$(cat $tx_bytes_path)
        t_cur_bytes=$(date +%s%N)

        rx_load=$(( ( (8*10**8*($cur_rx_bytes - $prev_rx_bytes)) / ($t_cur_bytes - $t_prev_bytes)) / $cur_dl_rate  ))
        tx_load=$(( ( (8*10**8*($cur_tx_bytes - $prev_tx_bytes)) / ($t_cur_bytes - $t_prev_bytes)) / $cur_ul_rate  ))

        t_prev_bytes=$t_cur_bytes
        prev_rx_bytes=$cur_rx_bytes
        prev_tx_bytes=$cur_tx_bytes

}

# touch file to update timestamp and trigger tick
tick_trigger()
{
	while true
	do
		t_start=$(date +%s%N)
		touch "/tmp/CAKE-autorate/tick_trigger"
		t_end=$(date +%s%N)
		sleep_remaining_tick_time $t_start $t_end $main_loop_tick_duration
	done
}

[ ! -d "/tmp/CAKE-autorate" ] && mkdir "/tmp/CAKE-autorate"

for reflector in "${reflectors[@]}"
do
	monitor_reflector_path $reflector&
	bg_PIDs+=($!)
done

tick_trigger&
bg_PIDs+=($!)

cur_ul_rate=$base_ul_rate
cur_dl_rate=$base_dl_rate

last_ul_rate=$cur_ul_rate
last_dl_rate=$cur_dl_rate

tc qdisc change root dev ${ul_if} cake bandwidth ${cur_ul_rate}Kbit
tc qdisc change root dev ${dl_if} cake bandwidth ${cur_dl_rate}Kbit

prev_tx_bytes=$(cat $tx_bytes_path)
prev_rx_bytes=$(cat $rx_bytes_path)
t_prev_bytes=$(date +%s%N)

t_start=$(date +%s%N)
t_prev_ul_rate_set=$t_prev_bytes
t_prev_dl_rate_set=$t_prev_bytes

while true
do
	# skeep util tick trigger or bufferbloat delay event
	inotifywait -e create -e attrib /tmp/CAKE-autorate/ -q -q

	t_start=$(date +%s%N)

	update_loads

	no_ul_delays=$(ls /tmp/CAKE-autorate/*ul_path_delayed 2>/dev/null | wc -l)
	no_dl_delays=$(ls /tmp/CAKE-autorate/*dl_path_delayed 2>/dev/null | wc -l)

        t_elapsed_ul_rate_set=$(($t_start-$t_prev_ul_rate_set))	
        t_elapsed_dl_rate_set=$(($t_start-$t_prev_dl_rate_set))	

        ul_bufferbloat_detected=$(($no_ul_delays >= $reflector_thr))
	ul_high_load=$(($tx_load > $high_load_thr))
 	cur_ul_rate=$(get_next_shaper_rate $cur_ul_rate $min_ul_rate $base_ul_rate $max_ul_rate $ul_high_load $ul_bufferbloat_detected $t_elapsed_ul_rate_set)
        
	dl_bufferbloat_detected=$(($no_dl_delays >= $reflector_thr))
	dl_high_load=$(($rx_load > $high_load_thr))
 	cur_dl_rate=$(get_next_shaper_rate $cur_dl_rate $min_dl_rate $base_dl_rate $max_dl_rate $dl_high_load $dl_bufferbloat_detected $t_elapsed_dl_rate_set)

        if [ "$last_ul_rate" -ne "$cur_ul_rate" ] ; then
         	if [ "$enable_verbose_output" ]; then
			echo "tc qdisc change root dev ${ul_if} cake bandwidth ${cur_ul_rate}Kbit"
		fi
            	tc qdisc change root dev ${ul_if} cake bandwidth ${cur_ul_rate}Kbit
		t_prev_ul_rate_set=$(date +%s%N)
        fi
        # only fire up tc if there are rates to change...
	if [ "$last_dl_rate" -ne "$cur_dl_rate" ] ; then
          	if [ "$enable_verbose_output" ] ; then
			echo "tc qdisc change root dev ${dl_if} cake bandwidth ${cur_dl_rate}Kbit"
		fi
            	tc qdisc change root dev ${dl_if} cake bandwidth ${cur_dl_rate}Kbit
		t_prev_dl_rate_set=$(date +%s%N)
        fi

	# remember the last rates
        last_dl_rate=$cur_dl_rate
        last_ul_rate=$cur_ul_rate
done
