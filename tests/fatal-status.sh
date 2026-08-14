#!/usr/bin/env bash
# shellcheck shell=bash

set -u
set -o pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

declare -A tracked_pids=()
fixture_dir=
suite_failed=0
wait_status=0
exec {test_sleep_fd}<> <(:)

cleanup()
{
	local pid pid_file

	trap - INT TERM EXIT
	if ((suite_failed)); then
		if [[ -d ${fixture_dir} ]]; then
			for pid_file in "${fixture_dir}"/*.pids
			do
				[[ -f ${pid_file} ]] || continue
				while read -r pid
				do
					[[ ${pid} =~ ^[0-9]+$ ]] && tracked_pids[${pid}]=1
				done < <(tr ' ' '\n' < "${pid_file}")
			done
		fi
		for pid in "${!tracked_pids[@]}"
		do
			kill -CONT "${pid}" 2>/dev/null || true
			kill -TERM "${pid}" 2>/dev/null || true
		done
		read -r -t 0.05 -u "${test_sleep_fd}" || true
		for pid in "${!tracked_pids[@]}"
		do
			kill -KILL "${pid}" 2>/dev/null || true
			wait "${pid}" 2>/dev/null || true
		done
	fi
	[[ -n ${fixture_dir} ]] && rm -r "${fixture_dir}" 2>/dev/null || true
}

trap cleanup EXIT

fail()
{
	suite_failed=1
	printf 'not ok - %s\n' "${1}" >&2
	exit 1
}

ok()
{
	printf 'ok - %s\n' "${1}"
}

pause()
{
	read -r -t "${1}" -u "${test_sleep_fd}" || true
}

assert_eq()
{
	local expected=${1} actual=${2} context=${3}

	[[ ${actual} == "${expected}" ]] || fail "${context}: expected '${expected}', got '${actual}'"
}

make_tmp_dir()
{
	[[ -z ${fixture_dir} ]] || rm -r "${fixture_dir}" 2>/dev/null || fail "failed to remove prior fixture"
	fixture_dir=$(mktemp -d) || fail "failed to create temporary directory"
}

wait_for_file()
{
	local path=${1} attempt

	for ((attempt=0; attempt<2000; attempt++))
	do
		[[ -f ${path} ]] && return 0
		pause 0.01
	done
	return 1
}

wait_with_timeout()
{
	local pid=${1} context=${2} watchdog marker

	marker=${3}/watchdog.${pid}
	trap - EXIT
	(
		read -r -t 10 -u "${test_sleep_fd}" || true
		: > "${marker}"
		kill -TERM "${pid}" 2>/dev/null || exit 0
		read -r -t 1 -u "${test_sleep_fd}" || true
		kill -KILL "${pid}" 2>/dev/null || true
	) &
	watchdog=${!}
	trap cleanup EXIT
	wait "${pid}"
	wait_status=${?}
	unset "tracked_pids[${pid}]"
	kill -TERM "${watchdog}" 2>/dev/null || true
	wait "${watchdog}" 2>/dev/null || true
	[[ ! -f ${marker} ]] || fail "${context}: timed out"
}

assert_pid_gone()
{
	local pid=${1} context=${2} attempt

	for ((attempt=0; attempt<100; attempt++))
	do
		if ! kill -0 "${pid}" 2>/dev/null
		then
			unset "tracked_pids[${pid}]"
			return
		fi
		pause 0.01
	done
	fail "${context}: PID ${pid} is still running"
}

read_direct_child_pids()
{
	local pid_file=${1} expected_parent=${2}

	read -r child_pid child_parent_pid < "${pid_file}" || fail "missing PID record ${pid_file}"
	[[ ${child_pid} =~ ^[0-9]+$ && ${child_parent_pid} =~ ^[0-9]+$ ]] || fail "invalid PID record ${pid_file}"
	assert_eq "${expected_parent}" "${child_parent_pid}" "cake instance must be a direct launcher child"
	tracked_pids[${child_pid}]=1
}

render_launcher()
{
	local script_prefix=${1} config_prefix=${2} launcher=${3}

	sed -e "s|%%SCRIPT_PREFIX%%|${script_prefix}|g" \
		-e "s|%%CONFIG_PREFIX%%|${config_prefix}|g" \
		"${repo_dir}/launcher.sh.template" > "${launcher}" || fail "failed to render launcher"
	chmod +x "${launcher}"
}

write_fake_cake()
{
	local path=${1}

	cp "${repo_dir}/tests/fixtures/fake-cake.sh" "${path}" || fail "failed to copy fake cake fixture"
	chmod +x "${path}"
}

make_launcher_fixture()
{
	make_tmp_dir
	script_prefix=${fixture_dir}/script
	config_prefix=${fixture_dir}/config
	launcher=${fixture_dir}/launcher.sh
	mkdir "${script_prefix}" "${config_prefix}"
	render_launcher "${script_prefix}" "${config_prefix}" "${launcher}"
	write_fake_cake "${script_prefix}/cake-autorate.sh"
}

start_launcher()
{
	local mode=${1} simultaneous=${2:-0} path_prefix=${3:-${PATH}} trace=${4:-0}
	local -a bash_args=()

	((trace)) && bash_args=(-x)

	CAKE_AUTORATE_TEST_DIR=${fixture_dir} \
	CAKE_AUTORATE_TEST_MODE=${mode} \
	CAKE_AUTORATE_TEST_SIMULTANEOUS=${simultaneous} \
	PATH=${path_prefix} \
		bash "${bash_args[@]}" "${launcher}" {test_sleep_fd}>&- > "${fixture_dir}/launcher.out" 2>&1 &
	launcher_pid=${!}
	tracked_pids[${launcher_pid}]=1
}

write_blocking_uci()
{
	local path=${1}

	cp "${repo_dir}/tests/fixtures/blocking-uci.sh" "${path}" || fail "failed to copy UCI fixture"
	chmod +x "${path}"
}

test_term_during_config_discovery()
{
	local fake_bin

	make_launcher_fixture
	fake_bin=${fixture_dir}/bin
	mkdir "${fake_bin}"
	write_blocking_uci "${fake_bin}/uci"
	start_launcher unexpected 0 "${fake_bin}:${PATH}"
	wait_for_file "${fixture_dir}/discovery.ready" || fail "TERM discovery fixture did not become ready"
	kill -TERM "${launcher_pid}"
	: > "${fixture_dir}/discovery.release"
	wait_with_timeout "${launcher_pid}" "TERM during config discovery" "${fixture_dir}"
	assert_eq 0 "${wait_status}" "TERM during config discovery"
	[[ ! -e ${fixture_dir}/cake.started ]] || fail "TERM during discovery started a cake instance"

	ok "TERM trap is active during config discovery"
}

test_sigint_in_foreground_pty()
{
	local fake_bin status

	make_launcher_fixture
	fake_bin=${fixture_dir}/bin
	mkdir "${fake_bin}"
	write_blocking_uci "${fake_bin}/uci"
	status=$(python3 "${repo_dir}/tests/fixtures/pty-runner.py" "${launcher}" "${fixture_dir}" "${fake_bin}:${PATH}") || fail "PTY SIGINT runner failed"
	assert_eq 0 "${status}" "foreground Ctrl-C status"
	[[ ! -e ${fixture_dir}/cake.started ]] || fail "foreground Ctrl-C started a cake instance"

	ok "foreground PTY SIGINT returns zero during discovery"
}

test_child_failure_and_all_zero()
{
	local failed_pid slow_pid

	make_launcher_fixture
	: > "${config_prefix}/config.fail.sh"
	: > "${config_prefix}/config.slow.sh"
	start_launcher failure 0 "${PATH}" 1
	wait_with_timeout "${launcher_pid}" "child status 42" "${fixture_dir}"
	assert_eq 42 "${wait_status}" "launcher child failure status"
	read_direct_child_pids "${fixture_dir}/fail.pids" "${launcher_pid}"
	failed_pid=${child_pid}
	read_direct_child_pids "${fixture_dir}/slow.pids" "${launcher_pid}"
	slow_pid=${child_pid}
	if grep -Eq "^\+* kill -TERM -- -${failed_pid}( |$)" "${fixture_dir}/launcher.out"
	then
		fail "launcher signalled the already-reaped failed PID"
	fi
	grep -Eq "^\+* kill -TERM -- -${slow_pid}( |$)" "${fixture_dir}/launcher.out" || fail "launcher did not signal the live sibling group"
	assert_pid_gone "${failed_pid}" "failed child reap"
	assert_pid_gone "${slow_pid}" "failed sibling cleanup"

	make_launcher_fixture
	: > "${config_prefix}/config.fast.sh"
	: > "${config_prefix}/config.slow.sh"
	start_launcher all-zero
	wait_with_timeout "${launcher_pid}" "all-zero children" "${fixture_dir}"
	assert_eq 0 "${wait_status}" "all children zero"
	[[ -f ${fixture_dir}/fast.done && -f ${fixture_dir}/slow.done ]] || fail "launcher did not wait for every zero child"

	ok "launcher propagates 42 and waits for all-zero children"
}

run_two_fail_race()
{
	local simultaneous=${1}

	rm -f "${fixture_dir}"/{first,second}.{ready,pids,exiting} "${fixture_dir}/release"
	start_launcher two-fail "${simultaneous}" "${PATH}" "${simultaneous}"
	wait_for_file "${fixture_dir}/first.ready" || fail "first failing child did not become ready"
	wait_for_file "${fixture_dir}/second.ready" || fail "second failing child did not become ready"
	read_direct_child_pids "${fixture_dir}/first.pids" "${launcher_pid}"
	first_pid=${child_pid}
	read_direct_child_pids "${fixture_dir}/second.pids" "${launcher_pid}"
	second_pid=${child_pid}
	((simultaneous)) && kill -STOP "${launcher_pid}"
	: > "${fixture_dir}/release"
	if ((simultaneous))
	then
		wait_for_file "${fixture_dir}/first.exiting" || fail "first simultaneous child did not exit"
		wait_for_file "${fixture_dir}/second.exiting" || fail "second simultaneous child did not exit"
		pause 0.01
		kill -CONT "${launcher_pid}"
	fi
	wait_with_timeout "${launcher_pid}" "two-child failure race" "${fixture_dir}"
	if ((simultaneous))
	then
		[[ ${wait_status} == 42 || ${wait_status} == 43 ]] || fail "simultaneous failures returned ${wait_status}"
	else
		assert_eq 42 "${wait_status}" "first controlled child failure"
	fi
	if ((simultaneous)) && grep -Eq "^\+* kill -TERM -- -(${first_pid}|${second_pid})( |$)" "${fixture_dir}/launcher.out"
	then
		fail "launcher signalled a child already completed in the simultaneous race"
	fi
	assert_pid_gone "${first_pid}" "first failure reap"
	assert_pid_gone "${second_pid}" "second failure reap"
}

test_two_fail_race()
{
	local iteration stress_iterations=${CAKE_AUTORATE_STRESS_ITERATIONS:-1}

	make_launcher_fixture
	: > "${config_prefix}/config.first.sh"
	: > "${config_prefix}/config.second.sh"
	run_two_fail_race 0
	for ((iteration=1; iteration<=stress_iterations; iteration++))
	do
		run_two_fail_race 1
	done

	ok "two-failure race and ${stress_iterations} simultaneous stress iterations"
}

write_real_config()
{
	local instance=${1}

	cat > "${config_prefix}/config.${instance}.sh" <<EOF
dl_if=lo
ul_if=${iface}
adjust_dl_shaper_rate=0
adjust_ul_shaper_rate=0
pinger_method=ping
reflectors=(127.0.0.1)
no_pingers=1
debug=0
log_to_file=1
log_file_path_override="\${CAKE_AUTORATE_TEST_DIR}"
EOF
}

make_real_launcher_fixture()
{
	command -v unshare >/dev/null 2>&1 || fail "unshare is required for the real daemon tests"
	make_tmp_dir
	fake_bin=${fixture_dir}/bin
	config_prefix=${fixture_dir}/config
	ns_run=${fixture_dir}/run
	launcher=${fixture_dir}/launcher.sh
	mkdir "${fake_bin}" "${config_prefix}" "${ns_run}"
	render_launcher "${repo_dir}" "${config_prefix}" "${launcher}"
	if [[ -e /run/current-system ]]
	then
		ln -s "$(readlink -f /run/current-system)" "${ns_run}/current-system"
	fi
	for iface_path in /sys/class/net/*
	do
		iface=${iface_path##*/}
		[[ ${iface} != lo ]] && break
	done
	[[ ${iface:-lo} != lo ]] || fail "real daemon test needs two network interfaces"

	cat > "${fake_bin}/tc" <<'EOF'
#!/usr/bin/env bash
if [[ ${CAKE_AUTORATE_TEST_STUBBORN:-0} == 1 ]] && mkdir "${CAKE_AUTORATE_TEST_DIR}/stubborn.lock" 2>/dev/null
then
	bash -c 'trap "" TERM; while :; do :; done' </dev/null >/dev/null 2>&1 &
	printf '%s\n' "${!}" > "${CAKE_AUTORATE_TEST_DIR}/stubborn.pids"
fi
printf '%s\n' 'qdisc cake 8001: root refcnt 2 bandwidth 100Mbit noatm overhead 0'
EOF
	cat > "${fake_bin}/ping" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' INT TERM
while :
do
	:
done
EOF
	cat > "${fake_bin}/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
	chmod +x "${fake_bin}/tc" "${fake_bin}/ping" "${fake_bin}/logger"
}

start_real_launcher()
{
	local trace=${1:-0}

	# The nested Bash expands the exported CAKE_AUTORATE_* variables.
	# shellcheck disable=SC2016
	CAKE_AUTORATE_TEST_DIR=${fixture_dir} \
	CAKE_AUTORATE_TEST_BIN=${fake_bin} \
	CAKE_AUTORATE_TEST_RUN=${ns_run} \
	CAKE_AUTORATE_TEST_PATH=${PATH} \
	CAKE_AUTORATE_TEST_LAUNCHER=${launcher} \
	CAKE_AUTORATE_TEST_TRACE=${trace} \
	CAKE_AUTORATE_TEST_STUBBORN=${stubborn_mode:-0} \
	CAKE_AUTORATE_SCRIPT_PREFIX=${repo_dir} \
	CAKE_AUTORATE_CONFIG_PREFIX=${config_prefix} \
		unshare -Urm --map-root-user bash -c '
			mount --bind "${CAKE_AUTORATE_TEST_RUN}" /run
			export PATH="${CAKE_AUTORATE_TEST_BIN}:${CAKE_AUTORATE_TEST_PATH}"
			if [[ ${CAKE_AUTORATE_TEST_TRACE} == 1 ]]
			then
				exec bash -x "${CAKE_AUTORATE_TEST_LAUNCHER}"
			fi
			exec bash "${CAKE_AUTORATE_TEST_LAUNCHER}"
		' {test_sleep_fd}>&- > "${fixture_dir}/launcher.out" 2>&1 &
	launcher_pid=${!}
	tracked_pids[${launcher_pid}]=1
}

load_real_instance()
{
	local instance=${1} attempt worker_pid

	proc_file=${ns_run}/cake-autorate/${instance}/proc_pids
	for ((attempt=0; attempt<2000; attempt++))
	do
		grep -q '^main=[0-9][0-9]*$' "${proc_file}" 2>/dev/null && break
		pause 0.01
	done
	grep -q '^main=[0-9][0-9]*$' "${proc_file}" 2>/dev/null || fail "real ${instance} daemon did not publish its main PID"
	instance_main_pid=$(awk -F= '/^main=/ {print $2}' "${proc_file}")
	instance_pgid=$(ps -o pgid= -p "${instance_main_pid}" | tr -d ' ')
	instance_parent_pid=$(ps -o ppid= -p "${instance_main_pid}" | tr -d ' ')
	assert_eq "${instance_main_pid}" "${instance_pgid}" "${instance} main must lead its process group"
	assert_eq "${launcher_pid}" "${instance_parent_pid}" "${instance} main must be a direct launcher child"
	tracked_pids[${instance_main_pid}]=1
	mapfile -t instance_worker_pids < <(awk -F= '/^[^=]+=-?[0-9]+$/ && $1 != "main" {gsub(/^-/, "", $2); print $2}' "${proc_file}")
	for worker_pid in "${instance_worker_pids[@]}"
	do
		tracked_pids[${worker_pid}]=1
	done
}

assert_group_gone()
{
	local pgid=${1} context=${2} attempt pid

	for ((attempt=0; attempt<200; attempt++))
	do
		if ! kill -0 -- "-${pgid}" 2>/dev/null
		then
			for pid in "${!tracked_pids[@]}"
			do
				kill -0 "${pid}" 2>/dev/null || unset "tracked_pids[${pid}]"
			done
			return
		fi
		pause 0.01
	done
	fail "${context}: process group ${pgid} still has members"
}

test_real_launcher_fatal_and_sigkill()
{
	local fatal_main fatal_pgid killed_main killed_pgid worker_pgid worker_pid
	local -a worker_pids

	make_real_launcher_fixture
	write_real_config primary
	start_real_launcher
	load_real_instance primary
	fatal_main=${instance_main_pid}
	fatal_pgid=${instance_pgid}
	printf '%s\n' 'synthetic fatal stderr from real launcher test' > "/proc/${fatal_main}/fd/2"
	wait_with_timeout "${launcher_pid}" "real launcher fatal stderr" "${fixture_dir}"
	assert_eq 1 "${wait_status}" "real launcher fatal stderr status"
	assert_group_gone "${fatal_pgid}" "fatal daemon group cleanup"

	make_real_launcher_fixture
	write_real_config primary
	start_real_launcher
	load_real_instance primary
	killed_main=${instance_main_pid}
	killed_pgid=${instance_pgid}
	worker_pids=("${instance_worker_pids[@]}")
	((${#worker_pids[@]} >= 3)) || fail "real daemon SIGKILL fixture exposed fewer than three workers"
	for worker_pid in "${worker_pids[@]}"
	do
		worker_pgid=$(ps -o pgid= -p "${worker_pid}" | tr -d ' ')
		assert_eq "${killed_pgid}" "${worker_pgid}" "real daemon worker must remain in its instance PGID"
	done
	kill -KILL "${killed_main}"
	wait_with_timeout "${launcher_pid}" "real daemon main SIGKILL" "${fixture_dir}"
	assert_eq 137 "${wait_status}" "real daemon main SIGKILL status"
	assert_group_gone "${killed_pgid}" "SIGKILL daemon group cleanup"
	for worker_pid in "${worker_pids[@]}"
	do
		assert_pid_gone "${worker_pid}" "SIGKILL daemon worker cleanup"
	done

	ok "real launcher propagates fatal stderr and main SIGKILL without orphans"
}

test_real_launcher_stopped_instances()
{
	local sibling_pgid victim_main victim_pgid stopped_pgid

	make_real_launcher_fixture
	write_real_config sibling
	write_real_config victim
	start_real_launcher
	load_real_instance sibling
	sibling_pgid=${instance_pgid}
	load_real_instance victim
	victim_main=${instance_main_pid}
	victim_pgid=${instance_pgid}
	kill -STOP -- "-${sibling_pgid}"
	kill -KILL "${victim_main}"
	wait_with_timeout "${launcher_pid}" "stopped sibling after victim SIGKILL" "${fixture_dir}"
	assert_eq 137 "${wait_status}" "stopped sibling victim SIGKILL status"
	assert_group_gone "${sibling_pgid}" "stopped sibling group cleanup"
	assert_group_gone "${victim_pgid}" "killed victim group cleanup"

	make_real_launcher_fixture
	write_real_config primary
	start_real_launcher
	load_real_instance primary
	stopped_pgid=${instance_pgid}
	kill -STOP -- "-${stopped_pgid}"
	kill -TERM "${launcher_pid}"
	wait_with_timeout "${launcher_pid}" "operator TERM with stopped daemon" "${fixture_dir}"
	assert_eq 0 "${wait_status}" "operator TERM with stopped daemon status"
	assert_group_gone "${stopped_pgid}" "operator TERM stopped group cleanup"

	ok "stopped real daemon groups resume, terminate and never deadlock"
}

test_real_launcher_kill_escalation()
{
	local elapsed_us main_pgid start_us stubborn_pid stubborn_pgid

	make_real_launcher_fixture
	write_real_config primary
	stubborn_mode=1
	start_real_launcher 1
	load_real_instance primary
	main_pgid=${instance_pgid}
	wait_for_file "${fixture_dir}/stubborn.pids" || fail "stubborn worker did not start"
	read -r stubborn_pid < "${fixture_dir}/stubborn.pids"
	tracked_pids[${stubborn_pid}]=1
	stubborn_pgid=$(ps -o pgid= -p "${stubborn_pid}" | tr -d ' ')
	assert_eq "${main_pgid}" "${stubborn_pgid}" "stubborn worker must inherit daemon PGID"
	start_us=${EPOCHREALTIME/.}
	kill -TERM "${launcher_pid}"
	wait_with_timeout "${launcher_pid}" "stubborn worker KILL escalation" "${fixture_dir}"
	((elapsed_us=10#${EPOCHREALTIME/.} - 10#${start_us}))
	assert_eq 0 "${wait_status}" "operator TERM with stubborn worker status"
	((elapsed_us < 6000000)) || fail "stubborn worker cleanup exceeded six seconds"
	grep -Eq "kill -KILL -- -${main_pgid}( |$)" "${fixture_dir}/launcher.out" || fail "launcher did not escalate stubborn group to KILL"
	assert_pid_gone "${stubborn_pid}" "stubborn worker KILL cleanup"
	assert_group_gone "${main_pgid}" "stubborn worker group cleanup"

	ok "TERM-ignoring real worker is KILLed within the bounded cleanup"
}

test_term_during_config_discovery
test_sigint_in_foreground_pty
test_child_failure_and_all_zero
test_two_fail_race
test_real_launcher_fatal_and_sigkill
test_real_launcher_stopped_instances
test_real_launcher_kill_escalation
