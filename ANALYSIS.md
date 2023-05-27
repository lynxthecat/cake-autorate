# Analyzing CAKE-autorate data

**CAKE-autorate** is a script that minimizes latency by adjusting CAKE bandwidth settings based on traffic load and round-trip time measurements.
See the main [README](./README.md) page for more details of the algorithm.

## Exporting a Log File ##

A compressed log file can be extracted from a running cake-autorate instance using one of either two methods:

1. Run the auto-generated _log\_file\_export_ script inside the run directory:

   ```bash
   /var/run/cake-autorate/*/log_file_export
   ```

   ... or ...

2.	Send a USR1 signal to the main log file process using:

   ```bash
   kill -USR1 $(cat /var/run/cake-autorate/*/proc_state | grep -E    '^maintain_log_file=' | cut -d= -f2)
   ```

Either will place a compressed log file in _/var/log_ with the date and time in its filename.

## Rotating the Log File 

Similarly, a log file rotation can be requested on a running cake-autorate instance by using one of either two methods

1. Run the auto-generated log_file_rotate script inside the run directory:

	```bash
   /var/run/cake-autorate/*/log_file_rotate
   ```
   ... or ...

2. Send a USR2 signal to the main log file process using:

   ```bash
   kill -USR2 $(cat /var/run/cake-autorate/*/proc_state | grep -E '^maintain_log_file=' | cut -d= -f2)
   ```

## Plotting the Log File 

The excellent Octave/Matlab program _fn\_parse\_autorate\_log.m_ by @moeller0 of OpenWrt can read an exported log file and produce a helpful graph like this:

<img src="https://user-images.githubusercontent.com/10721999/194724668-d8973bb6-5a37-4b05-a212-3514db8f56f1.png" width=80% height=80%>

The command below will run the Octave program (see the introductory notes in _fn\_parse\_autorate\_log.m_ for more details):
 
```bash
octave -qf --eval 'fn_parse_autorate_log("./log.gz", "./output.pdf")'
```

The script below runs on a laptop to extract the log from the router and generate the pdfs for viewing from a client machine:

```bash
log_file=$(ssh root@192.168.1.1 '/var/run/cake-autorate/primary/log_file_export 1>/dev/null && cat /var/run/cake-autorate/primary/last_log_file_export') && scp root@192.168.1.1:${log_file} . && ssh root@192.168.1.1 "rm ${log_file}"
octave -qf --eval 'fn_parse_autorate_log("./*primary*log.gz", "./output.pdf")'
```
  
## A Request to Testers

If you use this script, please post your experience on this [OpenWrt Forum thread](https://forum.openwrt.org/t/cake-w-adaptive-bandwidth/135379/). Your feedback will help improve the script for the benefit of others.  
