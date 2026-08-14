#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script_path="${repo_root}/cake-autorate.sh"

extract_function() {
	local function_name=${1}

	awk '
		$0 == function_name "()" { capture=1 }
		capture { print }
		capture && /^}$/ { exit }
	' function_name="${function_name}" "${script_path}"
}

assert_eq() {
	local expected=${1} actual=${2} message=${3}
	[[ ${actual} == "${expected}" ]] || {
		printf 'assert_eq failed: %s\nexpected: %s\nactual:   %s\n' "${message}" "${expected}" "${actual}" >&2
		exit 1
	}
}

assert_tc_calls() {
	local expected=${1} message=${2}
	assert_eq "${expected}" "${#tc_calls[@]}" "${message}"
}

# shellcheck disable=SC2034  # globals are consumed by extracted functions via eval
setup_common_state() {
	declare -gA shaper_rate_kbps=([dl]=20000 [ul]=5000)
	declare -gA last_shaper_rate_kbps=([dl]=25000 [ul]=5000)
	declare -gA interface=([dl]=ifb-wan0 [ul]=wan0)
	declare -gA adjust_shaper_rate=([dl]=1 [ul]=1)

	declare -gA compensated_avg_owd_delta_max_adjust_up_thr_us=([dl]=0 [ul]=0)
	declare -gA compensated_owd_delta_delay_thr_us=([dl]=0 [ul]=0)
	declare -gA compensated_avg_owd_delta_max_adjust_down_thr_us=([dl]=0 [ul]=0)

	declare -g output_cake_changes=0
	declare -g dl_max_wire_packet_size_bits=12000
	declare -g ul_max_wire_packet_size_bits=6000
	declare -g dl_avg_owd_delta_max_adjust_up_thr_us=100
	declare -g ul_avg_owd_delta_max_adjust_up_thr_us=200
	declare -g dl_owd_delta_delay_thr_us=300
	declare -g ul_owd_delta_delay_thr_us=400
	declare -g dl_avg_owd_delta_max_adjust_down_thr_us=500
	declare -g ul_avg_owd_delta_max_adjust_down_thr_us=600
	declare -g dl_compensation_us=11
	declare -g ul_compensation_us=22
	declare -g max_wire_packet_rtt_us=333

	declare -ga tc_calls=()
	declare -ga log_messages=()
	declare -gA tc_status_by_interface=([ifb-wan0]=0 [wan0]=0)

	log_msg() {
		log_messages+=("$*")
	}

	tc() {
		tc_calls+=("$*")
		return "${tc_status_by_interface[${5}]}"
	}

	eval "$(extract_function set_shaper_rate)"
	eval "$(extract_function initialize_shaper_rates)"
}

test_success_updates_state_after_tc() {
	setup_common_state

	set_shaper_rate dl
	local status=$?

	assert_eq "0" "${status}" "successful tc call should return 0"
	assert_tc_calls "1" "successful tc change should call tc once"
	assert_eq "20000" "${last_shaper_rate_kbps[dl]}" "successful tc should commit the new dl rate"
	assert_eq "600" "${dl_compensation_us}" "successful tc should recompute dl compensation"
	assert_eq "1200" "${ul_compensation_us}" "successful tc should recompute ul compensation"
	assert_eq "1800" "${max_wire_packet_rtt_us}" "successful tc should recompute max wire packet RTT"
}

test_failure_preserves_previous_state() {
	setup_common_state
	tc_status_by_interface[ifb-wan0]=42

	set +e
	set_shaper_rate dl
	local status=$?
	set -e

	assert_eq "42" "${status}" "failed tc call should propagate its status"
	assert_tc_calls "1" "failed tc change should still call tc once"
	assert_eq "25000" "${last_shaper_rate_kbps[dl]}" "failed tc must not advance the committed dl rate"
	assert_eq "11" "${dl_compensation_us}" "failed tc must preserve previous dl compensation"
	assert_eq "22" "${ul_compensation_us}" "failed tc must preserve previous ul compensation"
	assert_eq "333" "${max_wire_packet_rtt_us}" "failed tc must preserve previous RTT compensation"
	assert_eq "ERROR tc failed with status 42 while setting dl shaper on ifb-wan0 to 20000Kbit." "${log_messages[-1]}" "failed tc should emit an error log"
}

test_retry_repeats_tc_until_success() {
	setup_common_state
	tc_status_by_interface[ifb-wan0]=42
	set +e
	set_shaper_rate dl
	set -e

	tc_status_by_interface[ifb-wan0]=0
	set_shaper_rate dl
	local status=$?

	assert_eq "0" "${status}" "retry after a failure should succeed when tc succeeds"
	assert_tc_calls "2" "failed shaper change must remain pending for retry"
	assert_eq "20000" "${last_shaper_rate_kbps[dl]}" "successful retry should finally commit the new dl rate"
}

# shellcheck disable=SC2034  # the extracted function consumes this assignment via eval
test_cross_direction_failure_uses_committed_rates() {
	setup_common_state
	shaper_rate_kbps[ul]=4000
	tc_status_by_interface[ifb-wan0]=42

	set +e
	set_shaper_rate dl
	local dl_status=$?
	set -e
	set_shaper_rate ul
	local ul_status=$?

	assert_eq "42" "${dl_status}" "failed dl tc call should propagate its status"
	assert_eq "0" "${ul_status}" "successful ul tc call should return 0"
	assert_tc_calls "2" "each pending direction should call tc once"
	assert_eq "25000" "${last_shaper_rate_kbps[dl]}" "failed dl tc must preserve its committed rate"
	assert_eq "4000" "${last_shaper_rate_kbps[ul]}" "successful ul tc must commit its new rate"
	assert_eq "480" "${dl_compensation_us}" "ul success must use the committed dl rate"
	assert_eq "1500" "${ul_compensation_us}" "ul success must use the committed ul rate"
	assert_eq "1980" "${max_wire_packet_rtt_us}" "RTT compensation must use both committed rates"
}

test_startup_failure_propagates_without_initializing_rtt() {
	setup_common_state
	last_shaper_rate_kbps[dl]=0
	last_shaper_rate_kbps[ul]=0
	unset max_wire_packet_rtt_us
	tc_status_by_interface[ifb-wan0]=42
	tc_status_by_interface[wan0]=43

	set +e
	initialize_shaper_rates
	local status=$?
	set -e

	assert_eq "1" "${status}" "startup must fail when either initial tc call fails"
	assert_tc_calls "2" "startup should attempt both initial qdisc changes"
	assert_eq "0" "${last_shaper_rate_kbps[dl]}" "failed startup must not commit dl"
	assert_eq "0" "${last_shaper_rate_kbps[ul]}" "failed startup must not commit ul"
	[[ ! -v max_wire_packet_rtt_us ]] || {
		printf 'startup failure unexpectedly initialized max_wire_packet_rtt_us\n' >&2
		return 1
	}
	assert_eq "ERROR Initial CAKE shaper rate configuration failed. Exiting script." "${log_messages[-1]}" "startup failure should be logged before exit"
}

test_success_updates_state_after_tc
test_failure_preserves_previous_state
test_retry_repeats_tc_until_success
test_cross_direction_failure_uses_committed_rates
test_startup_failure_propagates_without_initializing_rtt

printf 'ok\n'
