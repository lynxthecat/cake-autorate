#!/usr/bin/env bash
set -u

parse()
{
	local method=$1 line=$2 timestamp reflector seq dl_owd_us ul_owd_us unexpected
	local dl_owd_ms ul_owd_ms rtt_ms originate received transmit finished
	local field1 field2 field3 field4 field5 field6 field7 field8 field9 field10 field11 field12
	case $method in
		irtt) read -r timestamp reflector seq dl_owd_us ul_owd_us unexpected <<< "$line" ;;
		tsping) read -r timestamp reflector seq field3 field4 field5 field6 field7 dl_owd_ms ul_owd_ms unexpected <<< "$line" ;;
		fping) read -r timestamp reflector field2 seq field4 field5 rtt_ms field7 field8 field9 field10 field11 unexpected <<< "$line" ;;
		fping-ts) read -r timestamp reflector field2 seq field4 field5 field6 field7 field8 field9 field10 field11 field12 originate received transmit finished unexpected <<< "$line" ;;
		ping) read -r timestamp field1 field2 field3 reflector seq field6 rtt_ms field8 unexpected <<< "$line" ;;
	esac

	[[ -n $timestamp ]] || { printf empty; return; }
	if [[ $timestamp == SARS ]]
	then
		case $method in
			irtt) [[ -n $reflector && -n $seq && -z $dl_owd_us$unexpected ]] && printf 'sars:%s:%s' "$reflector" "$seq" || printf malformed ;;
			tsping) [[ -n $reflector && -n $seq && -z $field3$unexpected ]] && printf 'sars:%s:%s' "$reflector" "$seq" || printf malformed ;;
			fping|fping-ts) [[ -n $reflector && -n $field2 && -z $seq$unexpected ]] && printf 'sars:%s:%s' "$reflector" "$field2" || printf malformed ;;
			ping) [[ -n $field1 && -n $field2 && -z $field3$unexpected ]] && printf 'sars:%s:%s' "$field1" "$field2" || printf malformed ;;
		esac
		return
	fi

	case $method in
		irtt) [[ -n $ul_owd_us && -z $unexpected ]] && printf 'ping:%s:%s:%s:%s:%s' "$timestamp" "$reflector" "$seq" "$dl_owd_us" "$ul_owd_us" || printf malformed ;;
		tsping) [[ -n $ul_owd_ms && -z $unexpected ]] && printf 'ping:%s:%s:%s:%s:%s' "$timestamp" "$reflector" "$seq" "$dl_owd_ms" "$ul_owd_ms" || printf malformed ;;
		fping) [[ -n $field11 && -z $unexpected && $rtt_ms != *[!0-9.]* ]] && printf 'ping:%s:%s:%s:%s' "$timestamp" "$reflector" "$seq" "$rtt_ms" || printf malformed ;;
		fping-ts) [[ -n $finished && -z $unexpected ]] && printf 'ping:%s:%s:%s:%s:%s:%s:%s' "$timestamp" "$reflector" "$seq" "${originate#Originate=}000" "${received#Receive=}000" "${transmit#Transmit=}000" "${finished#Localreceive=}000" || printf malformed ;;
		ping) [[ -n $field8 && -z $unexpected && $rtt_ms == time=* ]] && printf 'ping:%s:%s:%s:%s' "$timestamp" "${reflector%:}" "$seq" "$rtt_ms" || printf malformed ;;
	esac
}

check()
{
	local expected=$1 method=$2 line=$3 actual
	actual=$(parse "$method" "$line")
	if [[ $actual != "$expected" ]]; then printf 'FAIL %s\n expected: %s\n actual:   %s\n' "$method: $line" "$expected" "$actual" >&2; exit 1; fi
}

check 'ping:1720000000000000:1.1.1.1:7:1200:2300' irtt '1720000000000000 1.1.1.1 7 1200 2300'
check 'ping:1720000000.123456:1.1.1.1:8:1.25:2.50' tsping '1720000000.123456 1.1.1.1 8 a b c d e 1.25 2.50'
check 'ping:[1720000000.12345]:1.1.1.1:[9]:12.3' fping '[1720000000.12345] 1.1.1.1 : [9] 64 bytes 12.3 ms ttl 57 x z'
check 'ping:[1720000000.12345]:1.1.1.1:[10]:100000:101000:102000:103000' fping-ts '[1720000000.12345] 1.1.1.1 : [10] 64 bytes 4.0 ms ttl 57 x y z Originate=100 Receive=101 Transmit=102 Localreceive=103'
check 'ping:[1720000000.123456]:1.1.1.1:icmp_seq=11:time=8.4' ping '[1720000000.123456] 64 bytes from 1.1.1.1: icmp_seq=11 ttl=57 time=8.4 ms'

for method in irtt tsping fping fping-ts ping; do
	check 'sars:123:456' "$method" 'SARS 123 456'
	check malformed "$method" 'SARS 123'
	check malformed "$method" 'SARS 123 456 extra'
done

check malformed irtt '1720000000000000 1.1.1.1 7 1200'
check malformed irtt '1720000000000000 1.1.1.1 7 1200 2300 extra'
check malformed tsping '1720000000.123456 1.1.1.1 8 a b c d e 1.25'
check malformed tsping '1720000000.123456 1.1.1.1 8 a b c d e 1.25 2.50 extra'
check malformed fping '[1] 1.1.1.1 : [9] 64 bytes timeout ms ttl 57 x z'
check malformed fping '[1] 1.1.1.1 : [9] 64 bytes 1.0 ms ttl 57 x'
check malformed fping '[1] 1.1.1.1 : [9] 64 bytes 1.0 ms ttl 57 x z extra'
check malformed fping-ts '[1] 1.1.1.1 : [10] 64 bytes 4 ms ttl 57 x y z Originate=100 Receive=101 Transmit=102'
check malformed fping-ts '[1] 1.1.1.1 : [10] 64 bytes 4 ms ttl 57 x y z Originate=100 Receive=101 Transmit=102 Localreceive=103 extra'
check malformed ping '[1] 64 bytes from 1.1.1.1: icmp_seq=11 ttl=57 timeout ms'
check malformed ping '[1] 64 bytes from 1.1.1.1: icmp_seq=11 ttl=57 time=8.4'
check malformed ping '[1] 64 bytes from 1.1.1.1: icmp_seq=11 ttl=57 time=8.4 ms extra'
printf 'All pinger-response read tests passed.\n'
