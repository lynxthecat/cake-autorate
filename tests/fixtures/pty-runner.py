import os
import pty
import signal
import sys
import time

launcher, test_dir, path = sys.argv[1:]
pid, master = pty.fork()
if pid == 0:
    env = os.environ.copy()
    env["CAKE_AUTORATE_TEST_DIR"] = test_dir
    env["CAKE_AUTORATE_TEST_MODE"] = "unexpected"
    env["PATH"] = path
    os.execvpe("bash", ["bash", launcher], env)

deadline = time.monotonic() + 5
while not os.path.exists(os.path.join(test_dir, "discovery.ready")):
    if time.monotonic() >= deadline:
        os.killpg(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        sys.exit(124)
    time.sleep(0.01)

os.write(master, b"\x03")
open(os.path.join(test_dir, "discovery.release"), "w").close()
deadline = time.monotonic() + 5
while True:
    waited, result = os.waitpid(pid, os.WNOHANG)
    if waited:
        break
    if time.monotonic() >= deadline:
        os.killpg(pid, signal.SIGKILL)
        _, result = os.waitpid(pid, 0)
        break
    time.sleep(0.01)
os.close(master)
if os.WIFEXITED(result):
    print(os.WEXITSTATUS(result))
else:
    print(128 + os.WTERMSIG(result))
