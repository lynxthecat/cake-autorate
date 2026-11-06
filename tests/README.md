Run the pinger regression tests from the repository root:

```sh
python3 -m unittest discover -s tests -v
```

The tests exercise the production Bash functions and response parser with mock
clients, including all existing pinger methods. Python is only a test dependency.

To include integration tests using irtt-rs 0.10.2 or later:

```sh
IRTT_RS_BIN=/absolute/path/to/irtt-rs python3 -m unittest discover -s tests -v
```

These tests need UDP port 2112 free on 127.0.0.1, 127.0.0.2 and 127.0.0.3.
They cover native CSV, HMAC, reflector rotation, reconnection, blocked output,
shutdown, and the complete controller's idle/resume cycle. The controller runs
in monitor-only mode with temporary runtime paths, byte counters and a mock
`tc qdisc show`; no installed configuration or traffic shapers are changed.
