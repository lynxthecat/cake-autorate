# CAKE with Adaptive Bandwidth - "cake-autorate"

**cake-autorate** is a script that automatically adjusts CAKE
bandwidth settings based on traffic load and one-way-delay or
round-trip-time measurements. cake-autorate is intended for variable
bandwidth connections such as LTE, Starlink, and cable modems and is
not generally required for use on connections that have a stable,
fixed bandwidth.

[CAKE Smart Queue Management (SQM)](https://www.bufferbloat.net/projects/codel/wiki/Cake/)
is an algorithm that manages the buffering of data being sent/received
by a device such as an [OpenWrt router](https://openwrt.org) so that
no more data is queued than is necessary, minimizing the latency
("bufferbloat") and improving the responsiveness of a network.

Present version is 2.0.0 - please see [the changelog](CHANGELOG.md)
for details.

## The Problem: CAKE on variable speed connections forces an unpalatable compromise

The CAKE algorithm uses static upload and download bandwidth settings
to manage its queues. Variable bandwidth connections present a
challenge because the actual bandwidth at any given moment is not
known.

Because CAKE works with fixed bandwidth parameters, the user must
choose a single compromise bandwidth setting. This compromise is not
ideal: setting the parameter too low means the connection is
unnecessarily throttled to the compromise setting even when the
available link speed is higher (yellow). Setting the rate too high,
for times when the usable line rate falls below the compromise value,
means that the link is not throttled enough (green) resulting in
bufferbloat.

<img src="images/bandwidth-compromise.png" width=75% height=75%>

## The Solution: Set CAKE parameters based on load and latency

The cake-autorate script continually measures the load and One Way
Delay (OWD) or Round-Trip-Time (RTT) to adjust the upload and download
settings for the CAKE algorithm.

### Theory of Operation

`cake-autorate.sh` monitors load (receive and transmit utilization)
and ping response times from one or more reflectors (hosts on the
internet), and adjusts the download and upload bandwidth settings for
CAKE.

cake-autorate uses this simple approach:

- with low load, decay rate back to the configured baseline (and
  subject to refractory period)
- with high load, increase rate subject to the configured maximum
- if bufferbloat (increased latency) is detected, decrease rate
  subject to the configured min (and subject to refractory period)

<img src="images/cake-bandwidth-autorate-rate-control.png" width=80% height=80%>

cake-autorate requires three configuration values for each direction,
upload and download.

**Setting the minimum bandwidth:** Set the minimum value to the lowest
possible observed bufferbloat-free bandwidth. Ideally this setting
should never result in bufferbloat even under the worst conditions.
This is a hard minimum - the script will never reduce the bandwidth
below this level.

**Setting the baseline bandwidth:** This is the steady state bandwidth
to be maintained under no or low load. This is likely the compromise
bandwidth described above, i.e. the value you would set CAKE to that
is bufferbloat free most, but not necessarily all, of the time.

**Setting the maximum bandwidth:** The maximum bandwidth should be set
to the maximum bandwdith the connection can provide or lower. When
there is heavy traffic, the script will adjust the bandwidth up to
this limit, and then back off if an OWD or RTT spike is detected.
Since repeatedly testing for the maximum bandwidth on load necessarily
involves letting some excess latency through, reducing the maximum
bandwidth to a level below the maximum possible bandwidth has the
benefit of reducing that excess latency associated with testing for
the maximum bandwidth, and may allow for some degree of cruising along
at that upper limit whilst the true connection capacity is higher than
the set maximum bandwidth.

To elaborate on setting the minimum and maximum, a variable bandwidth
connection may be most ideally divided up into a known fixed, stable
component, on top of which is provided an unknown variable component:

![image of cake bandwidth adaptation](images/cake-bandwidth-adaptation.png)

The minimum bandwidth is then set to (or slightly below) the fixed
component, and the maximum bandwidth may be set to (or slightly above)
the maximum observed bandwidth (if maximum bandwidth is desired) or
lower than the maximum observed bandwidth (if the user is willing to
sacrifice some bandwidth in favour of reduced latency associated with
always testing for the true maximum as explained above).

The baseline bandwidth is likely optimally either the minimum
bandwidth or somewhere close thereto (e.g. the compromise bandwidth).

## Installation on OpenWrt

Read the installation instructions in the separate
[INSTALLATION](./INSTALLATION.md) page.

## Analysis of the cake-autorate logs

cake-autorate maintains a detailed log file thats is helpful in
discerning performance.

Read about this in the [ANALYSIS](./ANALYSIS.md) page.

## CPU load monitoring

The user should verify that CPU load is kept within acceptable ranges,
especially for devices with weaker CPUs.

cake-autorate uses inter-process communication between multiple
concurrent processes and incorporates various optimisations to reduce
the CPU load needed to perform its many tasks. A call to
`ps |grep -e bash -e fping` reveals the presence of the multiple
concurrent processes for each cake-autorate instance. This is normal
and expected behaviour.

```bash
root@OpenWrt-1:~# ps |grep -e bash -e fping
 5183 root      3396 S    {cake-autorate.s} /bin/bash /root/cake-autorate/cake-autorate.sh /root/cake-autorate/config.primary.sh
 5192 root      3240 S    {cake-autorate.s} /bin/bash /root/cake-autorate/cake-autorate.sh /root/cake-autorate/config.primary.sh
 5196 root      3200 S    {cake-autorate.s} /bin/bash /root/cake-autorate/cake-autorate.sh /root/cake-autorate/config.primary.sh
 5207 root      3356 S    {cake-autorate.s} /bin/bash /root/cake-autorate/cake-autorate.sh /root/cake-autorate/config.primary.sh
 5208 root      3468 S    {cake-autorate.s} /bin/bash /root/cake-autorate/cake-autorate.sh /root/cake-autorate/config.primary.sh
 5212 root      3496 S    {cake-autorate.s} /bin/bash /root/cake-autorate/cake-autorate.sh /root/cake-autorate/config.primary.sh
 5213 root      3504 S    {cake-autorate.s} /bin/bash /root/cake-autorate/cake-autorate.sh /root/cake-autorate/config.primary.sh
 5214 root      1928 S    fping --timestamp --loop --period 300 --interval 50 --timeout 10000 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 9.9.9.9 9
```

Process IDs can be checked using
`cat /var/run/cake-autorate/primary/proc_pids`, e.g.:

```bash
root@OpenWrt-1:~# cat /var/run/cake-autorate/primary/proc_pids
intercept_stderr=8591
maintain_log_file=8597
parse_fping_preprocessor=21175
parse_fping=8624
monitor_achieved_rates=8618
main=8573
maintain_pingers=8620
parse_fping_pinger=21176
```

It is useful to keep an htop instance running and run some speed tests
to see the maximum CPU utilisation of the processes and keep an eye on
the loadavg:

![image](https://github.com/lynxthecat/cake-autorate/assets/10721999/732ecdc0-e847-48db-baa5-c10616c2ad1b)

CPU load is proportional to the frequency of ping responses. Reducing
the number of pingers or pinger interval will therefore significantly
reduce CPU usage. The default ping response rate is 20 Hz (6 pingers
with 0.3 seconds between pings). Reducing the number of pingers to
three will give a ping response rate of 10 Hz and approximately half
the CPU load.
