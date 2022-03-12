#!/bin/bash

# CAKE-autorate automatically adjusts bandwidth for CAKE in dependence on detected load and OWD/RTT

# inspired by @moeller0 (OpenWrt forum)
# initial sh implementation by @Lynx (OpenWrt forum)
# requires packages: bash, iputils-ping, coreutils-date, coreutils-sleep

trap cleanup_and_killall INT TERM EXIT

cleanup_and_killall()
{
	echo "Killing all background processes and cleaning up /tmp files."
	# Resume pingers in case they are sleeping so they can be killed off
	kill -CONT -- ${ping_pids[@]}
	trap - INT && trap - TERM && trap - EXIT && kill -- ${sleep_pids[@]} && kill -- ${ping_pids[@]} && kill -- ${monitor_pids[@]}
	[ -d "/tmp/CAKE-autorate" ] && rm -r "/tmp/CAKE-autorate"
	exit
}

install_dir="/root/CAKE-autorate/"

. $install_dir"config.sh"
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
	local load_condition=$5
	local t_next_rate=$6
	local -n t_last_bufferbloat=$7
	local -n t_last_decay=$8
    	local -n next_rate=$9

	local cur_rate_decayed_down
 	local cur_rate_decayed_up

	case $load_condition in

 		# in case of supra-threshold OWD spikes decrease the rate providing not inside bufferbloat refractory period
		bufferbloat)
			if (( $t_next_rate > ($t_last_bufferbloat+(10**3)*$bufferbloat_refractory_period) )); then
        			next_rate=$(( $cur_rate*(1000-$rate_adjust_OWD_spike)/1000 ))
				t_last_bufferbloat=${EPOCHREALTIME/./}
			else
				next_rate=$cur_rate
			fi
			;;
           	# ... otherwise determine whether to increase or decrease the rate in dependence on load
            	# high load, so increase rate providing not inside bufferbloat refractory period 
		high_load)	
			if (( $t_next_rate > ($t_last_bufferbloat+(10**3)*$bufferbloat_refractory_period) )); then
                		next_rate=$(($cur_rate*(1000+$rate_adjust_load_high)/1000 ))
			
			else
				next_rate=$cur_rate
			fi
			;;
		# low load, so determine whether to decay down towards base rate, decay up towards base rate, or set as base rate
		low_load)
			if (($t_next_rate > ($t_last_decay+(10**3)*$decay_refractory_period) )); then
		
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
				t_last_decay=${EPOCHREALTIME/./}
			else
				next_rate=$cur_rate
			fi
			;;
	esac
        # make sure to only return rates between cur_min_rate and cur_max_rate
        if (($next_rate < $cur_min_rate)); then
            next_rate=$cur_min_rate;
        fi

        if (($next_rate > $cur_max_rate)); then
            next_rate=$cur_max_rate;
        fi

}

# update download and upload rates for CAKE
update_loads()
{
        cur_rx_bytes=$(cat $rx_bytes_path)
        cur_tx_bytes=$(cat $tx_bytes_path)
        t_cur_bytes=${EPOCHREALTIME/./}

        rx_load=$(( ( (8*10**8*($cur_rx_bytes - $prev_rx_bytes)) / ($t_cur_bytes - $t_prev_bytes)) / $cur_dl_rate  ))
        tx_load=$(( ( (8*10**8*($cur_tx_bytes - $prev_tx_bytes)) / ($t_cur_bytes - $t_prev_bytes)) / $cur_ul_rate  ))

        t_prev_bytes=$t_cur_bytes
        prev_rx_bytes=$cur_rx_bytes
        prev_tx_bytes=$cur_tx_bytes

}

[ ! -d "/tmp/CAKE-autorate" ] && mkdir "/tmp/CAKE-autorate"

for reflector in "${reflectors[@]}"
do
	t_start=${EPOCHREALTIME/./}
	mkfifo /tmp/CAKE-autorate/${reflector}_pipe
	ping_reflector $reflector&
 	sleep inf >/tmp/CAKE-autorate/${reflector}_pipe&
	sleep_pids+=($!)
	monitor_reflector_path $reflector&
	monitor_pids+=($!)
	t_end=${EPOCHREALTIME/./}
	# Space out pings by ping interval / number of reflectors
	sleep_remaining_tick_time $t_start $t_end $((((10**3)*$(x1000 $ping_reflector_interval)) /$no_reflectors))
done

for reflector in "${reflectors[@]}"
do
	read ping_pid < /tmp/CAKE-autorate/${reflector}_ping_pid
	ping_pids+=($ping_pid)
done

cur_ul_rate=$base_ul_rate
cur_dl_rate=$base_dl_rate

last_ul_rate=$cur_ul_rate
last_dl_rate=$cur_dl_rate

tc qdisc change root dev ${ul_if} cake bandwidth ${cur_ul_rate}Kbit
tc qdisc change root dev ${dl_if} cake bandwidth ${cur_dl_rate}Kbit

prev_tx_bytes=$(cat $tx_bytes_path)
prev_rx_bytes=$(cat $rx_bytes_path)
t_prev_bytes=${EPOCHREALTIME/./}

t_start=${EPOCHREALTIME/./}
t_end=${EPOCHREALTIME/./}
t_prev_ul_rate_set=$t_prev_bytes
t_prev_dl_rate_set=$t_prev_bytes
t_ul_last_bufferbloat=$t_prev_bytes
t_ul_last_decay=$t_prev_bytes
t_dl_last_bufferbloat=$t_prev_bytes
t_dl_last_decay=$t_prev_bytes

t_sustained_base_rate=0
ping_sleep=0

while true
do
	t_start=${EPOCHREALTIME/./}

	update_loads

	ul_load_condition="low_load"
	(($tx_load > $high_load_thr)) && ul_load_condition="high_load"

	dl_load_condition="low_load"
	(($rx_load > $high_load_thr)) && dl_load_condition="high_load"

	if ! [[ $ping_sleep == 1 && $ul_load_condition == "low_load" && $dl_load_condition == "low_load" ]]; then
	
		no_ul_delays=$(ls /tmp/CAKE-autorate/*ul_path_delayed 2>/dev/null | wc -l)
	        (($no_ul_delays >= $reflector_thr)) && ul_load_condition="bufferbloat"
	 	get_next_shaper_rate $cur_ul_rate $min_ul_rate $base_ul_rate $max_ul_rate $ul_load_condition $t_start t_ul_last_bufferbloat t_ul_last_decay cur_ul_rate
        
		no_dl_delays=$(ls /tmp/CAKE-autorate/*dl_path_delayed 2>/dev/null | wc -l)
	        (($no_dl_delays >= $reflector_thr)) && dl_load_condition="bufferbloat" 
	 	get_next_shaper_rate $cur_dl_rate $min_dl_rate $base_dl_rate $max_dl_rate $dl_load_condition $t_start t_dl_last_bufferbloat t_dl_last_decay cur_dl_rate

		# put pingers to sleep if base_rate sustained > ping_sleep_thr
		if (( $cur_ul_rate == $base_ul_rate && $last_ul_rate == $base_ul_rate && $cur_dl_rate == $base_dl_rate && $last_dl_rate == $base_dl_rate )); then
			((t_sustained_base_rate+=$(($t_start-$t_end))))
			if (($t_sustained_base_rate > (10**6)*$ping_sleep_thr && $ping_sleep==0)); then 
				kill -STOP -- ${ping_pids[@]}
				ping_sleep=1
				# Conservatively set ul/dl rates to hard minimum
				cur_ul_rate=$min_ul_rate
            			tc qdisc change root dev ${ul_if} cake bandwidth ${cur_ul_rate}Kbit
				cur_dl_rate=$min_dl_rate
        	    		tc qdisc change root dev ${dl_if} cake bandwidth ${cur_dl_rate}Kbit
				# remember the last rates
			        last_ul_rate=$cur_ul_rate
		        	last_dl_rate=$cur_dl_rate
			fi
		else
			t_sustained_base_rate=0
		
			# resuming from ping sleep, so just restart pingers and continue on to next loop without changing rates
			if (( $ping_sleep==1 )); then
				kill -CONT -- ${ping_pids[@]}
				ping_sleep=0
				cur_ul_rate=$min_ul_rate
				cur_dl_rate=$min_dl_rate

			# pingers active, so safe to change rates if there are rates to change	
			else
		        	# fire up tc if there are rates to change
			        if (( $cur_ul_rate != $last_ul_rate )); then
			         	(( $enable_verbose_output )) && echo "tc qdisc change root dev ${ul_if} cake bandwidth ${cur_ul_rate}Kbit"
            				tc qdisc change root dev ${ul_if} cake bandwidth ${cur_ul_rate}Kbit
					t_prev_ul_rate_set=${EPOCHREALTIME/./}
	        		fi
				if (( $cur_dl_rate != $last_dl_rate)); then
          				(($enable_verbose_output)) && echo "tc qdisc change root dev ${dl_if} cake bandwidth ${cur_dl_rate}Kbit"
	            			tc qdisc change root dev ${dl_if} cake bandwidth ${cur_dl_rate}Kbit
					t_prev_dl_rate_set=${EPOCHREALTIME/./}
				fi
				# remember the last rates
			        last_ul_rate=$cur_ul_rate
		        	last_dl_rate=$cur_dl_rate
			fi
		fi

	fi

	t_end=${EPOCHREALTIME/./}
	sleep_remaining_tick_time $t_start $t_end $(((10**3)*$main_loop_tick_duration))
done
