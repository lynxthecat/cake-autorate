# Analyzing cake-autorate data

**cake-autorate** is a script that minimizes latency by adjusting CAKE
bandwidth settings based on traffic load and round-trip time
measurements. See the main [README](./README.md) page for more details
of the algorithm.

## Viewing a simple summary of key statistics on the command line

A simple summary of the key statistics can be generated on the command
line so long as `output_reflector_stats` is enabled using e.g.:

```bash
tail -f /var/log/cake-autorate.primary.log | grep -e SUMMARY
```

## Logging options for a more detailed analysis

Enabling `output_processing_stats` and `output_load_stats` is
recommended for any detailed analysis and indeed necessary for either
plotting tool described below.

## Exporting a Log File

Extract a compressed log file from a running cake-autorate instance
using one of these methods:

1. Run the auto-generated _log_file_export_ script inside the run
   directory:

   ```bash
   /var/run/cake-autorate/*/log_file_export
   ```

   ... or ...

1. Send a USR1 signal to the main log file process(es) using:

   ```bash
   awk -F= '/^maintain_log_file=/ {print $2}' /var/run/cake-autorate/*/proc_pids | xargs kill -USR1
   ```

Either will place a compressed log file in _/var/log_ with the date
and time in its filename.

## Resetting the Log File

Force a log file reset on a running cake-autorate instance by using
one of these methods:

1. Run the auto-generated log_file_rotate script inside the run
   directory:

   ```bash
   /var/run/cake-autorate/*/log_file_reset
   ```

   ... or ...

1. Send a USR2 signal to the main log file process(es) using:

   ```bash
   awk -F= '/^maintain_log_file=/ {print $2}' /var/run/cake-autorate/*/proc_pids | xargs kill -USR2
   ```

## Plotting the Log File

The excellent Octave/Matlab program _fn_parse_autorate_log.m_ by
@moeller0 of OpenWrt can read an exported log file and produce a
helpful graph like this:

<img src="https://user-images.githubusercontent.com/10721999/194724668-d8973bb6-5a37-4b05-a212-3514db8f56f1.png" width=80% height=80%>

The command below will run the Octave program (see the introductory
notes in _fn_parse_autorate_log.m_ for more details):

```bash
octave -qf --eval 'fn_parse_autorate_log("./log.gz", "./output.pdf")'
```

The script below can be run on a remote machine to extract the log
from the router and generate the pdfs for viewing from the remote
machine:

```bash
log_file=$(ssh root@192.168.1.1 '/var/run/cake-autorate/primary/log_file_export 1>/dev/null && cat /var/run/cake-autorate/primary/last_log_file_export') && scp root@192.168.1.1:${log_file} . && ssh root@192.168.1.1 "rm ${log_file}"
octave -qf --eval 'fn_parse_autorate_log("./*primary*log.gz", "./output.pdf")'
```

### Prometheus cake-autorate exporter

Check out [bairhys](https://github.com/bairhys)'
[prometheus-cake-autorate-exporter](https://github.com/bairhys/prometheus-cake-autorate-exporter)
for beautiful, continuous plotting of cake-autorate statistics:

<img src="https://user-images.githubusercontent.com/33058425/258621455-724c213d-8a0b-4aa3-ae87-ae786c4cd2a2.png" width=100% height=100%>
