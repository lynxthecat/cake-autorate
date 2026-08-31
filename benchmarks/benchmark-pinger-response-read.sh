#!/usr/bin/env bash
# Parsing microbenchmark only; this does not measure whole-program CPU use.
set -u
iterations=${1:-500000}
method=${2:-fping}
case $method in
	irtt) line='1720000000000000 1.1.1.1 7 1200 2300' ;;
	tsping) line='1720000000.123456 1.1.1.1 8 a b c d e 1.25 2.50' ;;
	fping) line='[1720000000.12345] 1.1.1.1 : [9] 64 bytes 12.3 ms ttl 57 x z' ;;
	fping-ts) line='[1720000000.12345] 1.1.1.1 : [10] 64 bytes 4.0 ms ttl 57 x y z Originate=100 Receive=101 Transmit=102 Localreceive=103' ;;
	ping) line='[1720000000.123456] 64 bytes from 1.1.1.1: icmp_seq=11 ttl=57 time=8.4 ms' ;;
	*) printf 'unknown method: %s\n' "$method" >&2; exit 2 ;;
esac
input=$(mktemp)
trap 'rm -f "$input"' EXIT
for ((i=0; i<iterations; i++)); do printf '%s\n' "$line"; done > "$input"

master()
{
	local i fd timestamp timestamp_us reflector seq rtt_ms rtt_us dl ul originate received transmit finished reflector_response
	local -a command
	exec {fd}< "$input"
	for ((i=0; i<iterations; i++)); do
		reflector_response=0
		read -r -u "$fd" -a command
		case $method in
			irtt) if ((${#command[@]} == 5)); then timestamp=${command[0]} reflector=${command[1]} seq=${command[2]} dl=${command[3]} ul=${command[4]} timestamp_us=${command[0]} reflector_response=1; fi ;;
			tsping) if ((${#command[@]} == 10)); then timestamp=${command[0]} reflector=${command[1]} seq=${command[2]} dl=${command[8]}000 ul=${command[9]}000 timestamp_us=${command[0]//[.]} reflector_response=1; fi ;;
			fping) if ((${#command[@]} == 12)) && [[ ${command[6]} != *[!0-9.]* ]]; then timestamp=${command[0]} reflector=${command[1]} seq=${command[3]#[}; seq=${seq%]}; rtt_ms=${command[6]}; printf -v rtt_us %.3f "$rtt_ms"; ((dl=10#${rtt_us//.}/2, ul=dl)); timestamp_us=${timestamp#[}; timestamp_us=${timestamp_us%]}; timestamp_us=${timestamp_us//.}0; reflector_response=1; fi ;;
			fping-ts) if ((${#command[@]} == 17)); then timestamp=${command[0]} reflector=${command[1]} seq=${command[3]} originate=${command[13]#Originate=}000 received=${command[14]#Receive=}000 transmit=${command[15]#Transmit=}000 finished=${command[16]#Localreceive=}000; seq=${seq#[}; seq=${seq%]}; ((dl=finished-transmit, ul=received-originate)); timestamp_us=${timestamp#[}; timestamp_us=${timestamp_us%]}; timestamp_us=${timestamp_us//.}0; reflector_response=1; fi ;;
			ping) if ((${#command[@]} == 9)) && [[ ${command[7]} == time=* ]]; then timestamp=${command[0]} reflector=${command[4]%:} seq=${command[5]} rtt_ms=${command[7]//time=}; seq=${seq//icmp_seq=}; printf -v rtt_us %.3f "$rtt_ms"; ((dl=10#${rtt_us//.}/2, ul=dl)); timestamp_us=${timestamp#[}; timestamp_us=${timestamp_us%]}; timestamp_us=${timestamp_us//.}; reflector_response=1; fi ;;
		esac
	done
	exec {fd}<&-
}

pr417()
{
	local i fd timestamp timestamp_us reflector seq dl ul rtt_ms rtt_us originate received transmit finished unexpected reflector_response
	local field1 field2 field3 field4 field5 field6 field7 field8 field9 field10 field11 field12
	exec {fd}< "$input"
	for ((i=0; i<iterations; i++)); do
		reflector_response=0
		case $method in
			irtt) read -r -u "$fd" timestamp reflector seq dl ul unexpected ;;
			tsping) read -r -u "$fd" timestamp reflector seq field3 field4 field5 field6 field7 dl ul unexpected ;;
			fping) read -r -u "$fd" timestamp reflector field2 seq field4 field5 rtt_ms field7 field8 field9 field10 field11 unexpected ;;
			fping-ts) read -r -u "$fd" timestamp reflector field2 seq field4 field5 field6 field7 field8 field9 field10 field11 field12 originate received transmit finished unexpected ;;
			ping) read -r -u "$fd" timestamp field1 field2 field3 reflector seq field6 rtt_ms field8 unexpected ;;
		esac
		case $method in
			irtt) [[ -n $ul && -z $unexpected ]] && timestamp_us=$timestamp && reflector_response=1 ;;
			tsping) [[ -n $ul && -z $unexpected ]] && dl=${dl}000 && ul=${ul}000 && timestamp_us=${timestamp//[.]} && reflector_response=1 ;;
			fping) if [[ -n $field11 && -z $unexpected && $rtt_ms != *[!0-9.]* ]]; then seq=${seq#[}; seq=${seq%]}; printf -v rtt_us %.3f "$rtt_ms"; ((dl=10#${rtt_us//.}/2, ul=dl)); timestamp_us=${timestamp#[}; timestamp_us=${timestamp_us%]}; timestamp_us=${timestamp_us//.}0; reflector_response=1; fi ;;
			fping-ts) if [[ -n $finished && -z $unexpected ]]; then originate=${originate#Originate=}000 received=${received#Receive=}000 transmit=${transmit#Transmit=}000 finished=${finished#Localreceive=}000; seq=${seq#[}; seq=${seq%]}; ((dl=finished-transmit, ul=received-originate)); timestamp_us=${timestamp#[}; timestamp_us=${timestamp_us%]}; timestamp_us=${timestamp_us//.}0; reflector_response=1; fi ;;
			ping) if [[ -n $field8 && -z $unexpected && $rtt_ms == time=* ]]; then reflector=${reflector%:}; seq=${seq//icmp_seq=}; rtt_ms=${rtt_ms//time=}; printf -v rtt_us %.3f "$rtt_ms"; ((dl=10#${rtt_us//.}/2, ul=dl)); timestamp_us=${timestamp#[}; timestamp_us=${timestamp_us%]}; timestamp_us=${timestamp_us//.}; reflector_response=1; fi ;;
		esac
	done
	exec {fd}<&-
}

refined()
{
	local i fd timestamp timestamp_us reflector seq dl ul rtt_ms rtt_us originate received transmit finished unexpected reflector_response
	local field1 field2 field3 field4 field5 field6 field7 field8 field9 field10 field11 field12
	exec {fd}< "$input"
	for ((i=0; i<iterations; i++)); do
		reflector_response=0
		case $method in
			irtt) read -r -u "$fd" timestamp reflector seq dl ul unexpected; [[ -n $ul && -z $unexpected ]] && timestamp_us=$timestamp && reflector_response=1 ;;
			tsping) read -r -u "$fd" timestamp reflector seq field3 field4 field5 field6 field7 dl ul unexpected; [[ -n $ul && -z $unexpected ]] && dl=${dl}000 && ul=${ul}000 && timestamp_us=${timestamp//[.]} && reflector_response=1 ;;
			fping) read -r -u "$fd" timestamp reflector field2 seq field4 field5 rtt_ms field7 field8 field9 field10 field11 unexpected; if [[ -n $field11 && -z $unexpected && $rtt_ms != *[!0-9.]* ]]; then seq=${seq#[}; seq=${seq%]}; printf -v rtt_us %.3f "$rtt_ms"; ((dl=10#${rtt_us//.}/2, ul=dl)); timestamp_us=${timestamp#[}; timestamp_us=${timestamp_us%]}; timestamp_us=${timestamp_us//.}0; reflector_response=1; fi ;;
			fping-ts) read -r -u "$fd" timestamp reflector field2 seq field4 field5 field6 field7 field8 field9 field10 field11 field12 originate received transmit finished unexpected; if [[ -n $finished && -z $unexpected ]]; then originate=${originate#Originate=}000 received=${received#Receive=}000 transmit=${transmit#Transmit=}000 finished=${finished#Localreceive=}000; seq=${seq#[}; seq=${seq%]}; ((dl=finished-transmit, ul=received-originate)); timestamp_us=${timestamp#[}; timestamp_us=${timestamp_us%]}; timestamp_us=${timestamp_us//.}0; reflector_response=1; fi ;;
			ping) read -r -u "$fd" timestamp field1 field2 field3 reflector seq field6 rtt_ms field8 unexpected; if [[ -n $field8 && -z $unexpected && $rtt_ms == time=* ]]; then reflector=${reflector%:}; seq=${seq//icmp_seq=}; rtt_ms=${rtt_ms//time=}; printf -v rtt_us %.3f "$rtt_ms"; ((dl=10#${rtt_us//.}/2, ul=dl)); timestamp_us=${timestamp#[}; timestamp_us=${timestamp_us%]}; timestamp_us=${timestamp_us//.}; reflector_response=1; fi ;;
		esac
	done
	exec {fd}<&-
}
printf '%s (%d responses)\n' "$method" "$iterations"
printf 'master:  '; time master
printf 'PR #417: '; time pr417
printf 'refined:  '; time refined
