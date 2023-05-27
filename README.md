# CAKE with Adaptive Bandwidth - "autorate"

**CAKE-autorate** is a script that minimizes latency by adjusting CAKE bandwidth settings based on traffic load and round-trip time measurements. This is intended for variable bandwidth connections such as LTE, Starlink, and cable modems and is not generally required for use on connections that have a stable, fixed bandwidth.

[CAKE Smart Queue Management (SQM)](https://www.bufferbloat.net/projects/codel/wiki/Cake/) is an algorithm that manages the buffering of data being sent/received by a device such as an [OpenWrt router](https://openwrt.org) so that no more data is queued than is necessary, minimizing the latency ("bufferbloat") and improving the responsiveness of a network.

Present version is 2.1.0 - please see [the changelog](CHANGELOG.md) for details. 

## The Problem: CAKE on Variable Speed Connections forces an Unpalatable Compromise

The CAKE algorithm works from fixed upload and download bandwidth settings to manage its queues. Variable bandwidth connections present a challenge because the actual bandwidth at any given moment is not known. 

Because CAKE works with fixed speed parameters the user must choose a compromise bandwidth setting. Setting it too low means lost bandwidth in exchange for latency control; setting the parameter too high induces bufferbloat when the link slows down.

This compromise is not ideal: when the usable line rate is above the set compromise bandwidth, the connection is unnecessarily throttled to the compromise setting resulting in lost bandwidth (yellow); when the usable line rate falls below the compromise value, the connection is not throttled enough (green) resulting in bufferbloat.

<img src="images/bandwidth-compromise.png" width=75% height=75%>

## The Solution: Set CAKE parameters based on _Load_ and _RTT_

The CAKE-autorate script continually measures the load and Round-Trip-Time (RTT) to adjust the upload and download settings for the CAKE algorithm.

## Theory of Operation

`cake-autorate.sh` monitors load (rx and tx utilization) and ping responses from one or more reflectors, and adjusts the download and upload bandwidth settings for CAKE. Rate control is intentionally kept as simple as possible and follows the following approach:

- with low load, decay rate back to the configured baseline (and subject to refractory period)
- with high load, increase rate subject to the configured maximum
- on bufferbloat (when increased latency is detected), decrease rate subject to the configured min (and subject to refractory period)

<img src="images/cake-bandwidth-autorate-rate-control.png" width=80% height=80%>

**Setting the minimum bandwidth:** 
Set the minimum value to the worst possible observed bufferbloat-free bandwidth. Ideally this CAKE bandwidth should never result in bufferbloat even under the worst conditions. This is a hard minimum - the script will never reduce the bandwidth below this level.

**Setting the baseline bandwidth:** 
This is the steady state bandwidth to be maintained under no or low load. This is likely the compromise bandwidth described above, i.e. the value you would set CAKE to that is bufferbloat free most, but not necessarily all, of the time. 

**Setting the maximum bandwidth:** 
The maximum bandwidth should be set to the lower of the maximum bandwidth that the ISP can provide or the maximum bandwidth required by the user. The script will adjust the bandwidth up when there is traffic, as long no RTT spike is detected. Setting this value to a maximum required level will have the advantage that the script will stay at that level during optimum conditions rather than always having to test whether the bandwidth can be increased (which necessarily results in allowing some excess latency through).

To elaborate on setting the minimum and maximum, a variable bandwidth connection may be most ideally divided up into a known fixed, stable component, on top of which is provided an unknown variable component:

![image of cake bandwidth adaptation](images/cake-bandwidth-adaptation.png)

The minimum bandwidth is then set to (or slightly below) the fixed component, and the maximum bandwidth may be set to (or slightly above) the maximum observed bandwidth. Or, if a lower maximum bandwidth is required by the user, the maximum bandwidth is set to that lower bandwidth as explained above.

The baseline bandwidth is likely optimally either the minimum bandwidth or somewhere close thereto (e.g. the compromise bandwidth). 

There is a detailed and fun discussion with plenty of sketches relating to the development of the script and alternatives on the
[OpenWrt Forum - CAKE /w Adaptive Bandwidth.](https://forum.openwrt.org/t/cake-w-adaptive-bandwidth/108848/312)

## Installation

Read the installation instructions in the separate [INSTALLATION](./INSTALLATION.md) page.

## Analysis of the CAKE-autorate logs

CAKE-autorate keeps a number of log files that help to analyze its performance.
Read about them in the [ANALYSIS](./ANALYSIS.md) page.

## Optimizations

CAKE-autorate uses inter-process communication between
multiple concurrent processes to dramatically decrease
the CPU required to perform its many tasks.
The `ps |grep -e bash -e fping` shows the many tasks running: 

```bash
root@OpenWrt-1:~/cake-autorate# ps |grep -e bash -e fping
 2492 root      2744 S    bash
 2787 root      2356 S    {cake-autorate_l} /bin/bash /root/cake-autorate/cake-autorate_launcher.sh
 2789 root      3228 S    {cake-autorate.s} /bin/bash /root/cake-autorate/cake-autorate.sh /root/cake-autorate/cake-autorate_config.pri
 2817 root      3176 S    {cake-autorate.s} /bin/bash /root/cake-autorate/cake-autorate.sh /root/cake-autorate/cake-autorate_config.pri
 2822 root      3136 S    {cake-autorate.s} /bin/bash /root/cake-autorate/cake-autorate.sh /root/cake-autorate/cake-autorate_config.pri
 2834 root      3160 S    {cake-autorate.s} /bin/bash /root/cake-autorate/cake-autorate.sh /root/cake-autorate/cake-autorate_config.pri
 2836 root      3256 S    {cake-autorate.s} /bin/bash /root/cake-autorate/cake-autorate.sh /root/cake-autorate/cake-autorate_config.pri
 2839 root      3340 S    {cake-autorate.s} /bin/bash /root/cake-autorate/cake-autorate.sh /root/cake-autorate/cake-autorate_config.pri
 2840 root      3308 S    {cake-autorate.s} /bin/bash /root/cake-autorate/cake-autorate.sh /root/cake-autorate/cake-autorate_config.pri
 2841 root      1928 S    fping --timestamp --loop --period 300 --interval 50 --timeout 10000 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 9.9.9.9 9
```

## A Request to Testers

If you use this script, please post your experience on this [OpenWrt Forum thread](https://forum.openwrt.org/t/cake-w-adaptive-bandwidth/135379/). Your feedback will help improve the script for the benefit of others.  
