#!/usr/bin/env bash
# shellcheck disable=SC2154  # Variables are supplied by fatal-status.sh.

instance=${1##*/config.}
instance=${instance%.sh}

record_pid()
{
	printf '%s %s\n' "$$" "${PPID}" > "${CAKE_AUTORATE_TEST_DIR}/${instance}.pids"
	: > "${CAKE_AUTORATE_TEST_DIR}/${instance}.ready"
}

wait_for_path()
{
	while [[ ! -e ${1} ]]
	do
		:
	done
}

busy_wait_us()
{
	local start_us=${EPOCHREALTIME/.}

	while ((10#${EPOCHREALTIME/.} - 10#${start_us} < ${1}))
	do
		:
	done
}

idle()
{
	trap 'exit 0' INT TERM
	while :
	do
		:
	done
}

record_pid
case ${CAKE_AUTORATE_TEST_MODE} in
	failure)
		if [[ ${instance} == fail ]]
		then
			wait_for_path "${CAKE_AUTORATE_TEST_DIR}/slow.ready"
			exit 42
		fi
		idle
		;;
	all-zero)
		if [[ ${instance} == slow ]]
		then
			busy_wait_us 100000
		fi
		: > "${CAKE_AUTORATE_TEST_DIR}/${instance}.done"
		exit 0
		;;
	two-fail)
		wait_for_path "${CAKE_AUTORATE_TEST_DIR}/release"
		if [[ ${instance} == first ]]
		then
			: > "${CAKE_AUTORATE_TEST_DIR}/first.exiting"
			exit 42
		fi
		wait_for_path "${CAKE_AUTORATE_TEST_DIR}/first.exiting"
		[[ ${CAKE_AUTORATE_TEST_SIMULTANEOUS:-0} == 1 ]] || busy_wait_us 100000
		: > "${CAKE_AUTORATE_TEST_DIR}/second.exiting"
		exit 43
		;;
	*)
		: > "${CAKE_AUTORATE_TEST_DIR}/cake.started"
		exit 99
		;;
esac
