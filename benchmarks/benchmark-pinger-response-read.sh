#!/usr/bin/env bash
# Microbenchmark only: this does not measure whole-program cake-autorate CPU use.
set -u
iterations=${1:-200000}
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

old()
{
	local i timestamp reflector seq rtt_ms dl ul originate received transmit finished
	local fd
	local -a command
	exec {fd}< "$input"
	for ((i=0; i<iterations; i++)); do
		read -r -u "$fd" -a command
		case $method in
			irtt) timestamp=${command[0]} reflector=${command[1]} seq=${command[2]} dl=${command[3]} ul=${command[4]} ;;
			tsping) timestamp=${command[0]} reflector=${command[1]} seq=${command[2]} dl=${command[8]} ul=${command[9]} ;;
			fping) timestamp=${command[0]} reflector=${command[1]} seq=${command[3]} rtt_ms=${command[6]} ;;
			fping-ts) timestamp=${command[0]} reflector=${command[1]} seq=${command[3]} originate=${command[13]#Originate=}000 received=${command[14]#Receive=}000 transmit=${command[15]#Transmit=}000 finished=${command[16]#Localreceive=}000 ;;
			ping) timestamp=${command[0]} reflector=${command[4]%:} seq=${command[5]} rtt_ms=${command[7]} ;;
		esac
	done
	exec {fd}<&-
}
new()
{
	local i timestamp reflector seq dl ul rtt_ms originate received transmit finished unexpected
	local field1 field2 field3 field4 field5 field6 field7 field8 field9 field10 field11 field12 fd
	exec {fd}< "$input"
	for ((i=0; i<iterations; i++)); do
		case $method in
			irtt) read -r -u "$fd" timestamp reflector seq dl ul unexpected ;;
			tsping) read -r -u "$fd" timestamp reflector seq field3 field4 field5 field6 field7 dl ul unexpected ;;
			fping) read -r -u "$fd" timestamp reflector field2 seq field4 field5 rtt_ms field7 field8 field9 field10 field11 unexpected ;;
			fping-ts) read -r -u "$fd" timestamp reflector field2 seq field4 field5 field6 field7 field8 field9 field10 field11 field12 originate received transmit finished unexpected ; originate=${originate#Originate=}000 received=${received#Receive=}000 transmit=${transmit#Transmit=}000 finished=${finished#Localreceive=}000 ;;
			ping) read -r -u "$fd" timestamp field1 field2 field3 reflector seq field6 rtt_ms field8 unexpected; reflector=${reflector%:} ;;
		esac
	done
	exec {fd}<&-
}
printf '%s (%d responses)\n' "$method" "$iterations"
printf 'old: '; time old
printf 'new: '; time new
