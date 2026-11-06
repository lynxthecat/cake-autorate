#!/usr/bin/env python3
"""Pinger regression tests: python3 -m unittest discover -s tests -v.

Set IRTT_RS_BIN to an irtt-rs 0.10.2+ dispatcher to also run loopback tests.
No router interfaces, traffic shapers or installed configuration are touched.
"""

import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "cake-autorate.sh").read_text()
LIB = (ROOT / "lib.sh").read_text()
REAL_CLIENT = os.environ.get("IRTT_RS_BIN")


def function(source, name):
    start = source.index(f"\n{name}()\n") + 1
    end = source.index("\n}\n", start) + 3
    return source[start:end]


PINGERS = SCRIPT.split("# GENERIC PINGER START AND STOP FUNCTIONS\n", 1)[1].split(
    "# END OF GENERIC PINGER START AND STOP FUNCTIONS", 1
)[0]
PARSER = SCRIPT.split('\t\t\tcase "${pinger_method}" in\n', 1)[1].split(
    "\n\t\t\tesac", 1
)[0]
ROUTING = SCRIPT.split("\n\tif ((reflector_response))\n", 1)[1].split(
    "\n\tcase ${main_state}", 1
)[0]
CHECKS = SCRIPT.split("# Check ping binary exists\n", 1)[1].split(
    "\n(( min_dl_shaper_rate_kbps", 1
)[0]


class PingerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.bin = self.path / "bin"
        self.bin.mkdir()
        self.mock = self.bin / "irtt-rs"
        self.mock.write_text("""#!/usr/bin/env bash
if [[ ${2:-} == --help ]]
then
    printf '%s\\n' "${MOCK_HELP:---targets-stdin --events}"
    exit
fi
printf '%s\\n' "${BASHPID}" > "${TEST_TMP}/client.pid"
printf '%s\\n' "$@" > "${TEST_TMP}/args"
trap 'exit 0' TERM INT
while IFS= read -r targets
do
    printf '%s\\n' "${targets}" >> "${TEST_TMP}/targets"
done
""")
        self.mock.chmod(0o700)

    def run_shell(self, body, *, real=False, timeout=15):
        prelude = """
set -u
set -o pipefail
set -f
IFS=' ,'
export LC_ALL=C
exec {__sleep_fd}<> <(:)
exec {main_fd}<> <(:)
declare -A proc_pids pinger_by_reflector
declare -A retained_dl_owd_baselines_us retained_ul_owd_baselines_us
declare -A retained_dl_owd_delta_ewmas_us retained_ul_owd_delta_ewmas_us
declare -a pinger_pids dl_owd_baselines_us ul_owd_baselines_us
declare -a dl_owd_delta_ewmas_us ul_owd_delta_ewmas_us
reflectors=(127.0.0.1 127.0.0.2 127.0.0.3 127.0.0.4)
no_pingers=2 no_reflectors=4 pingers_active=0
reflector_ping_interval_s=0.1 reflector_ping_interval_ms=100
reflector_ping_interval_us=100000 ping_response_interval_ms=50
ping_response_interval_us=50000 pingers_t_start_us=${EPOCHREALTIME/.}
ping_prefix_string='' ping_extra_args='' pinger_method=irtt-rs
retain_reflector_stats=1 reflector_misbehaving_detection_window=2
for ((pinger=0; pinger<no_pingers; pinger++))
do
    pinger_by_reflector[${reflectors[pinger]}]=${pinger}
    dl_owd_baselines_us[pinger]=100000 ul_owd_baselines_us[pinger]=100000
    dl_owd_delta_ewmas_us[pinger]=0 ul_owd_delta_ewmas_us[pinger]=0
done
log_msg() { printf '%s\\n' "$*" >> "${TEST_TMP}/log"; }
export_proc_pids() { :; }
fail() { printf '%s\\n' "$*" >&2; exit 1; }
assert() { "$@" || fail "assertion failed: $*"; }
await_file()
{
    local attempt
    for ((attempt=0; attempt<200; attempt++))
    do
        [[ -s ${1} ]] && return
        sleep_s 0.01
    done
    fail "timed out waiting for ${1}"
}
trap 'terminate "${pinger_pids[*]}"' EXIT
"""
        helpers = "\n".join(function(LIB, name) for name in ("sleep_s", "terminate"))
        program = prelude + helpers + PINGERS + "\n" + body
        env = dict(os.environ, TEST_TMP=str(self.path))
        if real:
            (self.bin / "irtt-rs").unlink()
            (self.bin / "irtt-rs").symlink_to(Path(REAL_CLIENT).resolve())
        env["PATH"] = str(self.bin) + os.pathsep + env["PATH"]
        result = subprocess.run(
            ["bash", "-c", program], env=env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_rotation_keeps_client_and_unchanged_reflectors(self):
        self.run_shell("""
start_pingers
await_file "${TEST_TMP}/client.pid"
pid=${pinger_pids[0]}
assert test "${pid}" = "$(cat "${TEST_TMP}/client.pid")"
t_start_us=${EPOCHREALTIME/.}
replace_pinger_reflector 1
await_file "${TEST_TMP}/targets"
assert test "$(cat "${TEST_TMP}/targets")" = '127.0.0.1,127.0.0.3'
assert test "${pinger_pids[0]}" = "${pid}"
assert test "${reflectors[*]}" = '127.0.0.1 127.0.0.3 127.0.0.4 127.0.0.2'
assert test "${pinger_by_reflector[127.0.0.3]}" = 1
assert test -z "${pinger_by_reflector[127.0.0.2]:-}"
assert test "${retained_dl_owd_baselines_us[127.0.0.2]}" = 100000
stop_pingers
assert test -z "${irtt_rs_targets_fd:-}"
assert test -z "${pinger_pids[0]:-}"
assert test -z "${proc_pids[irtt_rs_pinger]:-}"
assert test ! -e "/proc/${pid}"
""")
        args = (self.path / "args").read_text().splitlines()
        for option in ("--continuous", "--reconnect", "--no-stats", "--targets-stdin"):
            self.assertIn(option, args)
        self.assertEqual(args[-2:], ["127.0.0.1", "127.0.0.2"])

    def test_stopped_rotation_and_no_spares(self):
        self.run_shell("""
t_start_us=${EPOCHREALTIME/.}
replace_pinger_reflector 0
assert test ! -e "${TEST_TMP}/client.pid"
start_pingers
await_file "${TEST_TMP}/client.pid"
assert test "$(tail -2 "${TEST_TMP}/args")" = $'127.0.0.3\\n127.0.0.2'
no_reflectors=${no_pingers}
replace_pinger_reflector 1
assert test ! -e "${TEST_TMP}/targets"
stop_pingers
""")

    def test_dead_client_update_recovers_without_sigpipe(self):
        self.run_shell("""
start_pingers
await_file "${TEST_TMP}/client.pid"
pid=${pinger_pids[0]}
kill -KILL "${pid}"
wait "${pid}" 2>/dev/null || :
t_start_us=${EPOCHREALTIME/.}
replace_pinger_reflector 1
assert test "${pinger_pids[0]}" != "${pid}"
assert kill -0 "${pinger_pids[0]}"
stop_pingers
""")

    def test_prefix_executes_client_with_extra_args(self):
        wrapper = self.bin / "prefix"
        wrapper.write_text('#!/usr/bin/env bash\nprintf "used\\n" > "${TEST_TMP}/prefix"\nexec "$@"\n')
        wrapper.chmod(0o700)
        self.run_shell("""
ping_prefix_string=prefix ping_extra_args='--hmac 0x1234 --mark 42'
start_pingers
await_file "${TEST_TMP}/client.pid"
assert test -s "${TEST_TMP}/prefix"
assert test "${pinger_pids[0]}" = "$(cat "${TEST_TMP}/client.pid")"
stop_pingers
""")
        self.assertIn("--hmac\n0x1234\n--mark\n42", (self.path / "args").read_text())

    def test_repeated_start_stop_releases_descriptors_and_children(self):
        self.run_shell("""
# Globbing is disabled in production; count descriptors in a subshell.
fd_count() { (set +f; fds=(/proc/${BASHPID}/fd/*); echo "${#fds[@]}"); }
before=$(fd_count)
for ((cycle=0; cycle<12; cycle++))
do
    start_pingers
    pid=${pinger_pids[0]}
    fd=${irtt_rs_targets_fd}
    start_pingers
    assert test "${pinger_pids[0]}" = "${pid}"
    stop_pingers
    stop_pingers
    assert test ! -e "/proc/${pid}"
    assert test ! -e "/proc/${BASHPID}/fd/${fd}"
done
assert test "$(fd_count)" = "${before}"
""")

    def test_cleanup_closes_and_reaps_client(self):
        self.run_shell(function(SCRIPT, "cleanup_and_killall") + """
config_path=test run_path=${TEST_TMP}/run log_file_buffer_timeout_ms=50
mkdir "${run_path}"
start_pingers
await_file "${TEST_TMP}/client.pid"
trap cleanup_and_killall EXIT
""")
        pid = (self.path / "client.pid").read_text().strip()
        self.assertFalse(Path(f"/proc/{pid}").exists())
        self.assertFalse((self.path / "run").exists())

    def test_csv_and_removed_target_routing(self):
        self.run_shell("""
parse()
{
    reflector_response=0
    read -r -a command <<< "${1}"
    case ${pinger_method} in
""" + PARSER + """
    esac
    if ((reflector_response))
""" + ROUTING + """
}
parse '1793178293027526000,127.0.0.1,42,-16018,17642'
assert test "${reflector_response}" = 1
assert test "${timestamp}" = 1793178293027526
assert test "${dl_owd_us}" = -16018
assert test "${ul_owd_us}" = 17642
assert test "${pinger}" = 0
for row in \
    '1793178293027526000,127.0.0.1,42,,17642' \
    '1793178293027526000,127.0.0.1,42,16018,' \
    '1793178293027526000,127.0.0.1,42,NaN,17642' \
    '1793178293027526000,127.0.0.1,42,1.2,17642' \
    'client_receive_wall_ns,target,seq,rd_us,sd_us' \
    '1793178293027526000,127.0.0.1,no_seq,16018,17642'
do
    parse "${row}"
    assert test "${reflector_response}" = 0
done
t_start_us=${EPOCHREALTIME/.}
replace_pinger_reflector 0
parse '1793178293027526000,127.0.0.1,43,16018,17642'
assert test "${reflector_response}" = 0
parse '1793178293027526000,127.0.0.3,0,16018,-17642'
assert test "${reflector_response}" = 1
assert test "${pinger}" = 0
""")

    def test_feature_and_target_limit_checks(self):
        self.run_shell(CHECKS + "\n:")
        for help_text in ("--targets-stdin", "--events", "old client"):
            with self.subTest(help_text=help_text):
                self.run_shell("(export MOCK_HELP='" + help_text + "'\n" + CHECKS + "\n)\nassert test $? = 1")
        self.run_shell("(no_pingers=129 no_reflectors=129\n" + CHECKS + "\n)\nassert test $? = 1")

    def test_existing_shared_and_individual_pingers(self):
        mock = """#!/usr/bin/env bash
trap 'exit 0' TERM INT
while :; do read -r -t 0.1 || :; done
"""
        for name in ("ping", "fping", "tsping", "gawk"):
            executable = self.bin / name
            executable.write_text(mock)
            executable.chmod(0o700)
        self.run_shell("""
for pinger_method in fping fping-ts tsping ping irtt
do
    pinger_pids=()
    start_pingers
    expected=1
    [[ ${pinger_method} == ping || ${pinger_method} == irtt ]] && expected=2
    assert test "${#pinger_pids[@]}" = "${expected}"
    for pid in "${pinger_pids[@]}"; do assert kill -0 -- "${pid}"; done
    stop_pingers
    for pid in "${pinger_pids[@]}"; do
        assert bash -c '! kill -0 -- "$1" 2>/dev/null' bash "${pid}"
    done
done
pinger_pids=()
""")

    @unittest.skipUnless(REAL_CLIENT, "set IRTT_RS_BIN for loopback integration")
    def test_controller_rotation_idle_resume_and_cleanup(self):
        interfaces = [p.name for p in Path("/sys/class/net").iterdir()]
        if len(interfaces) < 2:
            self.skipTest("monitor-only controller needs two interfaces")
        app = self.path / "app"
        app.mkdir()
        # Relocate only runtime files; run the complete controller in monitor-only mode.
        (app / "cake-autorate.sh").write_text(
            SCRIPT.replace("/var/run/cake-autorate", str(self.path / "run"))
        )
        for name in ("defaults.sh", "lib.sh"):
            (app / name).write_bytes((ROOT / name).read_bytes())
        tc = self.bin / "tc"
        tc.write_text('''#!/usr/bin/env bash
[[ ${1} == qdisc && ${2} == show ]] || exit 1
echo 'qdisc cake noatm overhead 0'
''')
        tc.chmod(0o700)
        self.mock.unlink()
        self.mock.symlink_to(Path(REAL_CLIENT).resolve())
        config = app / "config.test.sh"
        config.write_text(f'''dl_if={interfaces[0]}
ul_if={interfaces[1]}
adjust_dl_shaper_rate=0
adjust_ul_shaper_rate=0
pinger_method=irtt-rs
reflectors=(127.0.0.1 127.0.0.2 127.0.0.3)
no_pingers=2
randomize_reflectors=0
reflector_ping_interval_s=0.1
reflector_health_check_interval_s=0.1
reflector_replacement_interval_mins=0
sustained_idle_sleep_thr_s=0.5
output_processing_stats=1
log_to_file=0
''')
        counters = self.path / "bytes"
        counters.write_text("0\n")
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                   CAKE_AUTORATE_SCRIPT_PREFIX=str(app), INVOCATION_ID="test",
                   rx_bytes_path=str(counters), tx_bytes_path=str(counters))
        with subprocess.Popen(
            [REAL_CLIENT, "server", "--bind", "127.0.0.1:2112", "--bind",
             "127.0.0.2:2112", "--bind", "127.0.0.3:2112", "--min-interval", "0"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        ) as server, (self.path / "controller.log").open("w") as output:
            controller = subprocess.Popen(
                ["bash", str(app / "cake-autorate.sh"), str(config)], env=env,
                stdout=output, stderr=subprocess.STDOUT,
            )
            tracked_pids = set()

            def await_log(message):
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    log = (self.path / "controller.log").read_text()
                    if message in log:
                        return log
                    if controller.poll() is not None:
                        self.fail(log)
                    pid_file = self.path / "run/test/proc_pids"
                    if pid_file.exists():
                        for line in pid_file.read_text().splitlines():
                            tracked_pids.add(int(line.split("=")[1]))
                    time.sleep(0.02)
                self.fail(f"missing {message}:\n{log}")

            try:
                await_log("from: RUNNING to: IDLE")
                counters.write_text("1000000000\n")
                log = await_log("from: IDLE to: RUNNING")
                self.assertIn("replacing reflector:", log)
                self.assertIn("DATA", log)
            finally:
                controller.terminate()
                controller.wait(timeout=6)
                server.terminate()
            log = (self.path / "controller.log").read_text()
            self.assertNotIn("ERROR", log)
            self.assertFalse((self.path / "run/test").exists())
            for pid in tracked_pids:
                self.assertFalse(Path(f"/proc/{pid}").exists(), f"process {pid} survived")

    @unittest.skipUnless(REAL_CLIENT, "set IRTT_RS_BIN for loopback integration")
    def test_native_rotation_reconnection_and_shutdown(self):
        self.run_shell("""
ping_extra_args='--hmac 0x12345678 --reconnect-timeout 200ms --reconnect-max-delay 500ms'
start_server()
{
    irtt-rs server --bind "${1}:2112" --min-interval 0 --hmac 0x12345678 \
        > "${TEST_TMP}/server-${1}.log" 2>&1 &
    server=${!}
}
start_server 127.0.0.1
server1=${server}
start_server 127.0.0.2
server2=${server}
start_server 127.0.0.3
server3=${server}
trap 'stop_pingers; terminate "${server1} ${server2} ${server3}"' EXIT
read_target()
{
    local attempt
    for ((attempt=0; attempt<100; attempt++))
    do
        if read -r -t 0.1 -u "${main_fd}" -a reply && [[ ${reply[1]:-} == "${1}" ]]
        then
            return
        fi
    done
    fail "no native reply from ${1}"
}
start_pingers
pid=${pinger_pids[0]}
read_target 127.0.0.1
read_target 127.0.0.2
sleep_s 0.5
read_target 127.0.0.1
seq_before=${reply[2]}
t_start_us=${EPOCHREALTIME/.}
replace_pinger_reflector 1
read_target 127.0.0.3
read_target 127.0.0.1
assert test "${reply[2]}" -gt "${seq_before}"
assert test "${pinger_pids[0]}" = "${pid}"
# Reconnect a silent session while the other target keeps replying.
terminate "${server3}"
sleep_s 0.3
read_target 127.0.0.1
start_server 127.0.0.3
server3=${server}
read_target 127.0.0.3
assert test "${pinger_pids[0]}" = "${pid}"
# Recover a failed initial open without restarting the client or its healthy peer.
terminate "${server3}"
stop_pingers
start_pingers
pid=${pinger_pids[0]}
read_target 127.0.0.1
start_server 127.0.0.3
server3=${server}
read_target 127.0.0.1
read_target 127.0.0.3
assert test "${pinger_pids[0]}" = "${pid}"
stop_pingers
# Terminate during an unanswered open, then while stdout is blocked.
reflectors=(127.0.0.4) no_pingers=1
start_pingers
pid=${pinger_pids[0]}
start_us=${EPOCHREALTIME/.}
stop_pingers
assert test ! -e "/proc/${pid}"
assert test "$(( ${EPOCHREALTIME/.} - start_us ))" -lt 1000000
reflectors=(127.0.0.1) reflector_ping_interval_s=0.0001
start_pingers
pid=${pinger_pids[0]}
sleep_s 0.5
start_us=${EPOCHREALTIME/.}
stop_pingers
assert test ! -e "/proc/${pid}"
assert test "$(( ${EPOCHREALTIME/.} - start_us ))" -lt 1000000
""", real=True, timeout=30)


if __name__ == "__main__":
    unittest.main()
