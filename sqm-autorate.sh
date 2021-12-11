# Automatically adjust bandwidth for CAKE in dependence on detected load and OWD

# inspired by @moeller0 (OpenWrt forum)
# initial sh implementation by @Lynx (OpenWrt forum)
# requires packages: hping3, iputils-ping, coreutils-date and coreutils-sleep

debug=1

enable_verbose_output=1 # enable (1) or disable (0) output monitoring lines showing bandwidth changes

ul_if=wan # upload interface
dl_if=veth-lan # download interface

base_ul_rate=30000 # steady state bandwidth for upload

base_dl_rate=30000 # steady state bandwidth for download

tick_duration=1.0 # seconds to wait between ticks

alpha_OWD_increase=0.001 # how rapidly baseline OWD is allowed to increase
alpha_OWD_decrease=0.9 # how rapidly baseline OWD is allowed to decrease

rate_adjust_OWD_spike=0.05 # how rapidly to reduce bandwidth upon detection of bufferbloat
rate_adjust_load_high=0.005 # how rapidly to increase bandwidth upon high load detected
rate_adjust_load_low=0.0025 # how rapidly to return to base rate upon low load detected

load_thresh=0.5 # % of currently set bandwidth for detecting high load

max_delta_OWD=15 # increase from baseline OWD for detection of bufferbloat

# verify these are correct using 'cat /sys/class/...'
case "${dl_if}" in
    \veth*)
        rx_bytes_path="/sys/class/net/${dl_if}/statistics/tx_bytes"
        ;;
    \ifb*)
        rx_bytes_path="/sys/class/net/${dl_if}/statistics/tx_bytes"
        ;;
    *)
        rx_bytes_path="/sys/class/net/${dl_if}/statistics/rx_bytes"
        ;;
esac

case "${ul_if}" in
    \veth*)
        tx_bytes_path="/sys/class/net/${ul_if}/statistics/rx_bytes"
        ;;
    \ifb*)
        tx_bytes_path="/sys/class/net/${ul_if}/statistics/rx_bytes"
        ;;
    *)
        tx_bytes_path="/sys/class/net/${ul_if}/statistics/tx_bytes"
        ;;
esac

if [ "$debug" ] ; then
    echo "rx_bytes_path: $rx_bytes_path"
    echo "tx_bytes_path: $tx_bytes_path"
fi


# list of reflectors to use
read -d '' reflectors << EOF
46.227.200.54
46.227.200.55
194.242.2.2
194.242.2.3
149.112.112.10
149.112.112.11
149.112.112.112
193.19.108.2
193.19.108.3
9.9.9.9
9.9.9.10
9.9.9.11
EOF

OWDs=$(mktemp)
BASELINES_prev=$(mktemp)
BASELINES_cur=$(mktemp)


if [ $enable_verbose_output -eq 1 ]; then
	RED='\033[0;31m'
	NC='\033[0m' # No Color
fi


# get minimum OWDs for each reflector
get_OWDs() {
> $OWDs
for reflector in $reflectors;
do
    # awk mastery by @_Failsafe (OpenWrt forum) 
    echo $reflector $(timeout 0.8 hping3 $reflector --icmp --icmp-ts -i u1000 -c 1 2> /dev/null | ./hping_parser.awk) >> $OWDs&
done
wait
}

call_awk() {
  printf '%s' "$(awk 'BEGIN {print '"${1}"'}')"
}

get_next_shaper_rate() {
    local cur_delta_RTT
    local cur_max_delta_RTT
    local cur_rate
    local cur_base_rate
    local cur_load
    local cur_load_thresh
    local cur_rate_adjust_RTT_spike
    local cur_rate_adjust_load_high
    local cur_rate_adjust_load_low

    local next_rate
    local cur_rate_decayed_down
    local cur_rate_decayed_up

    cur_delta_OWD=$1
    cur_max_delta_OWD=$2
    cur_rate=$3
    cur_base_rate=$4
    cur_load=$5
    cur_load_thresh=$6
    cur_rate_adjust_OWD_spike=$7
    cur_rate_adjust_load_high=$8
    cur_rate_adjust_load_low=$9

        # in case of supra-threshold OWD spikes decrease the rate so long as there is a load
        if awk "BEGIN {exit !(($cur_delta_OWD >= $cur_max_delta_OWD))}"; then
            next_rate=$( call_awk "int( ${cur_rate}*(1-${cur_rate_adjust_OWD_spike}) )" )
        else
            # ... otherwise determine whether to increase or decrease the rate in dependence on load
            # high load, so we would like to increase the rate
            if awk "BEGIN {exit !($cur_load >= $cur_load_thresh)}"; then
                next_rate=$( call_awk "int( ${cur_rate}*(1+${cur_rate_adjust_load_high}) )" )
            else
                # low load, so determine whether to decay down towards base rate, decay up towards base rate, or set as base rate
                cur_rate_decayed_down=$( call_awk "int( ${cur_rate}*(1-${cur_rate_adjust_load_low}) )" )
                cur_rate_decayed_up=$( call_awk "int( ${cur_rate}*(1+${cur_rate_adjust_load_low}) )" )

                # gently decrease to steady state rate
                if awk "BEGIN {exit !($cur_rate_decayed_down > $cur_base_rate)}"; then
                        next_rate=$cur_rate_decayed_down
                # gently increase to steady state rate
                elif awk "BEGIN {exit !($cur_rate_decayed_up < $cur_base_rate)}"; then
                        next_rate=$cur_rate_decayed_up
                # steady state has been reached
                else
                        next_rate=$cur_base_rate
        fi
        fi
        fi

        echo "${next_rate}"
}


# update download and upload rates for CAKE
function update_rates {
        cur_rx_bytes=$(cat $rx_bytes_path)
        cur_tx_bytes=$(cat $tx_bytes_path)
        t_cur_bytes=$(date +%s.%N)

        rx_load=$( call_awk "(8/1000)*(${cur_rx_bytes} - ${prev_rx_bytes}) / (${t_cur_bytes} - ${t_prev_bytes}) * (1/${cur_dl_rate}) " )
        tx_load=$( call_awk "(8/1000)*(${cur_tx_bytes} - ${prev_tx_bytes}) / (${t_cur_bytes} - ${t_prev_bytes}) * (1/${cur_ul_rate}) " )

        t_prev_bytes=$t_cur_bytes
        prev_rx_bytes=$cur_rx_bytes
        prev_tx_bytes=$cur_tx_bytes

        # calculate the next rate for dl and ul
        cur_dl_rate=$( get_next_shaper_rate "$min_downlink_delta" "$max_delta_OWD" "$cur_dl_rate" "$base_dl_rate" "$rx_load" "$load_thresh" "$rate_adjust_OWD_spike" "$rate_adjust_load_high" "$rate_adjust_load_low")
        cur_ul_rate=$( get_next_shaper_rate "$min_uplink_delta" "$max_delta_OWD" "$cur_ul_rate" "$base_ul_rate" "$tx_load" "$load_thresh" "$rate_adjust_OWD_spike" "$rate_adjust_load_high" "$rate_adjust_load_low")

        if [ $enable_verbose_output -eq 1 ]; then
                printf "${RED} %s;%14.2f;%14.2f;%14.2f;%14.2f;%14.2f;%14.2f;${NC}\n" $( date "+%Y%m%dT%H%M%S.%N" ) $rx_load $tx_load $min_downlink_delta $min_uplink_delta $cur_dl_rate $cur_ul_rate
        fi
}

# determine minimum OWD deltas across all reflectors
# and update baselines for each reflector
get_min_OWD_deltas() {

	local reflector
	local prev_uplink_baseline
	local prev_downlink_baseline
	local cur_uplink_baseline
	local cur_downlink_baseline
	local reflector_OWDs
	local uplink_OWD
	local dowlink_OWD
	
	min_uplink_delta=10000
	min_downlink_delta=10000

	> $BASELINES_cur

	# Read through previous OWD baseline file for each reflector
	# get corresponding new OWD measurement for each reflector
	# update baselines and store in cur OWD baseline file
	while IFS= read -r reflector_line; do
		reflector=$(echo $reflector_line | awk '{print $1}')
		prev_uplink_baseline=$(echo $reflector_line | awk '{print $2}')
		prev_downlink_baseline=$(echo $reflector_line | awk '{print $3}')

		reflector_OWDs=$(awk '/'$reflector'/' $OWDs)
		uplink_OWD=$(echo $reflector_OWDs | awk '{print $2}')
		downlink_OWD=$(echo $reflector_OWDs | awk '{print $3}')

		# Check for any bad OWD values for reflector and if found just 
		# maintain previous baseline for reflector and continue to next reflector
		if [ "$uplink_OWD" = "999999999" ] || [ "$downlink_OWD" = "999999999" ]; then
			echo $reflector $prev_uplink_baseline $prev_downlink_baseline >> $BASELINES_cur 
        		if [ $enable_verbose_output -eq 1 ]; then
                		echo $reflector "No Response. Skipping this reflector."
        		fi
			continue
		fi

		delta_uplink_OWD=$( call_awk "${uplink_OWD} - ${prev_uplink_baseline}" )
		delta_downlink_OWD=$( call_awk "${downlink_OWD} - ${prev_downlink_baseline}" )

        	if [ $enable_verbose_output -eq 1 ]; then
                	printf "%25s;%14.2f;%14.2f;%14.2f;%14.2f;%14.2f;%14.2f;\n" $reflector $prev_downlink_baseline $downlink_OWD $delta_downlink_OWD $prev_uplink_baseline $uplink_OWD $delta_uplink_OWD 
        	fi

		if awk "BEGIN {exit !($delta_uplink_OWD >= 0)}"; then
        	        cur_uplink_baseline=$( call_awk "( 1 - ${alpha_OWD_increase} ) * ${prev_uplink_baseline} + ${alpha_OWD_increase} * ${uplink_OWD} " )
	        else
        	        cur_uplink_baseline=$( call_awk "( 1 - ${alpha_OWD_decrease} ) * ${prev_uplink_baseline} + ${alpha_OWD_decrease} * ${uplink_OWD} " )
	        fi
		
		if awk "BEGIN {exit !($delta_downlink_OWD >= 0)}"; then
        	        cur_downlink_baseline=$( call_awk "( 1 - ${alpha_OWD_increase} ) * ${prev_downlink_baseline} + ${alpha_OWD_increase} * ${downlink_OWD} " )
	        else
        	        cur_downlink_baseline=$( call_awk "( 1 - ${alpha_OWD_decrease} ) * ${prev_downlink_baseline} + ${alpha_OWD_decrease} * ${downlink_OWD} " )
	        fi
		echo $reflector $cur_uplink_baseline $cur_downlink_baseline >> $BASELINES_cur

		if awk "BEGIN {exit !($delta_uplink_OWD < $min_uplink_delta)}"; then
			min_uplink_delta=$delta_uplink_OWD
		fi

		if awk "BEGIN {exit !($delta_downlink_OWD < $min_downlink_delta)}"; then
			min_downlink_delta=$delta_downlink_OWD
		fi

	done < $BASELINES_prev

	mv $BASELINES_cur $BASELINES_prev

}

# set initial values for first run

get_OWDs
cp $OWDs $BASELINES_prev

cur_dl_rate=$base_dl_rate
cur_ul_rate=$base_ul_rate
# set the next different from the cur_XX_rates so that on the first round we are guaranteed to call tc
last_dl_rate=0
last_ul_rate=0
min_uplink_delta=0
min_downlink_delta=0
t_prev_bytes=$(date +%s.%N)

prev_rx_bytes=$(cat $rx_bytes_path)
prev_tx_bytes=$(cat $tx_bytes_path)

if [ $enable_verbose_output -eq 1 ]; then
        printf "%25s;%14s;%14s;%14s;%14s;%14s;%14s;%14s;\n" "log_time" "rx_load" "tx_load" "min_dl_delta" "min_ul_delta" "cur_dl_rate" "cur_ul_rate"
fi

# main loop runs every tick_duration seconds
while true
do
        t_start=$(date +%s.%N)
        get_OWDs
        get_min_OWD_deltas
        update_rates

        # only fire up tc if there are rates to change...
        if [ "$last_dl_rate" -ne "$cur_dl_rate" ] ; then
            #echo "tc qdisc change root dev ${dl_if} cake bandwidth ${cur_dl_rate}Kbit"
            tc qdisc change root dev ${dl_if} cake bandwidth ${cur_dl_rate}Kbit
        fi
        if [ "$last_ul_rate" -ne "$cur_ul_rate" ] ; then
            #echo "tc qdisc change root dev ${ul_if} cake bandwidth ${cur_ul_rate}Kbit"
            tc qdisc change root dev ${ul_if} cake bandwidth ${cur_ul_rate}Kbit
        fi
        # remember the last rates
        last_dl_rate=$cur_dl_rate
        last_ul_rate=$cur_ul_rate

        t_end=$(date +%s.%N)
        sleep_duration=$( call_awk "${tick_duration} - ${t_end} + ${t_start}" )
        if awk "BEGIN {exit !($sleep_duration > 0)}"; then
                sleep $sleep_duration
        fi
done
