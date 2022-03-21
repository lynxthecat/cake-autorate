# CAKE with Adaptive Bandwidth - "autorate"

**CAKE-autorate** is a script that automatically adapts [CAKE Smart Queue Management (SQM)](https://www.bufferbloat.net/projects/codel/wiki/Cake/) bandwidth settings by measuring traffic load and RTT times. This is designed for variable bandwidth connections such as LTE, **and is not intended for use on connections that have a stable, fixed bandwidth**.

CAKE is an algorithm that manages the buffering of data being sent/received by an [OpenWrt router](https://openwrt.org) so that no more data is queued than is necessary, minimizing the latency ("bufferbloat") and improving the responsiveness of a network.

## CAKE forces users of variable bandwidth connections to make a horrible compromise

The CAKE algorithm always uses fixed upload and download bandwidth settings to manage its queues. Variable bandwidth connections present a challenge because the actual bandwidth at any given moment is not known. 

As CAKE works with a fixed set bandwidth this effectively forces the user to choose a compromise bandwidth setting, but typically this means lost bandwidth in exchange for latency control and/or bufferbloat during the worst conditions. This compromise is hardly ideal: whilst the actual usable line rate is above the set compromise bandwidth, the connection is unnecessarily throttled back to the compromise setting resulting in lost bandwidth (yellow); and whilst the actual usable line rate is below the set compromise bandwidth, the connection is not throttled enough (green) resulting in bufferbloat.

![image of Bandwidth Compromise](./Bandwidth-Compromise.png)

The **CAKE-autorate.sh** script periodically measures the load and Round-Trip-Time (RTT) to adjust the upload and download values for the CAKE algorithm.

## Theory of Operation

`CAKE-autorate.sh` monitors load (rx and tx) and ping respones from one or more reflectors, and adjusts the download and upload bandwidth for CAKE. Rate control is intentionally kept as simple as possible and follows the following approach:

- with low load, decay rate back to set baseline (and subject to refractory period)
- with high load, increase rate subject to set maximum
- on bufferbloat, decrease rate subject to set min (and subject to refractory period)

![image of CAKE-autorat rate control](./CAKE-autorate-rate-control.png)

**Setting the minimum bandwidth:** 
Set the minimum value to the worst possible observed bufferbloat free bandwidth. Ideally this CAKE bandwidth should never result in bufferbloat even under the worst conditions. This is a hard minimum - the script will never reduce the bandwidth below this level.

**Setting the baseline bandwidth:** 
This is the steady state bandwidth to be maintained under no or low load. This is likely the compromise bandwidth described above, i.e. the value you would set CAKE to that is bufferbloat free most, but not necessarily all, of the time. 

**Setting the maximum bandwidth:** 
The maximum bandwidth should be set to the lower of the maximum bandwidth that the ISP can provide or the maximum bandwidth required by the user. The script will adjust the bandwidth up when there is traffic, as long no RTT spike is detected. Setting this value to a maximum required level will have the advantage that the script will stay at that level during optimum conditions rather than always having to test whether the bandwidth can be increased (which necessarily results in allowing some excess latency through).

To elaborate on the above, a variable bandwidth connection may be most ideally divided up into a known fixed, stable component, on top of which is provided an unknown variable component:

![image of CAKE bandwidth adaptation](./CAKE-Bandwidth-Adaptation.png)

The minimum bandwidth is then set to (or slightly below) the fixed component, and the maximum bandwidth may be set to (or slightly above) the maximum observed bandwidth. Or, if a lower maximum bandwidth is required by the user, the maximum bandwidth is set to that lower bandwidth as explained above.

There is a detailed and fun discussion with plenty of sketches relating to the development of the script and alternatives on the
[OpenWrt Forum - CAKE /w Adaptive Bandwidth.](https://forum.openwrt.org/t/cake-w-adaptive-bandwidth/108848/312)

## Required packages

- **bash** for its builtins, arithmetic and array handling
- **iputils-ping** for more advanced ping with sub 1s ping frequency
- **coreutils-sleep** for accurate sleeping

## Installation on OpenWrt

- Install SQM (`luci-app-sqm`) and enable CAKE on the interface(s)
as described in the
[OpenWrt SQM documentation](https://openwrt.org/docs/guide-user/network/traffic-shaping/sqm)
- [SSH into the router](https://openwrt.org/docs/guide-quick-start/sshadministration)
- Run the following commands to place the script at `/root/CAKE-autorate/`
and make it executable:

   ```bash
   opkg update; opkg install bash iputils-ping coreutils-sleep
   cd /root
   mkdir CAKE-autorate
   cd CAKE-autorate
   wget https://raw.githubusercontent.com/lynxthecat/CAKE-autorate/main/CAKE-autorate.sh
   wget https://raw.githubusercontent.com/lynxthecat/CAKE-autorate/main/config.sh
   chmod +x ./CAKE-autorate.sh
   ```

- Edit the `config.sh` script using vi or nano to set the configuration paremters (see comments inside `config.sh` for details). 

  - Change `ul_if` and `dl_if` to match the names of the upload and download interfaces to which CAKE is applied These can be obtained, for example, by consulting the configured SQM settings in LuCi or by examining the output of `tc qdisc ls`.
  - Set minimum bandwidth variables (`min_dl_rate` and `min_ul_rate` in the script) as described above.
  - Set baseline bandwidth variables (`base_dl_rate` and `base_ul_rate` in the script) as described above.
  - Set maximum bandwidth (`max_dl_rate` and `max_ul_rate`) as described above.
  
## Manual testing

- Run the `CAKE-autorate.sh` script:
- Set **output_processing_stats** in `config.sh` to '1' 
- 
   ```bash
   ./CAKE-autorate.sh
   ```

- Monitor the script output to see how it adjusts the download and upload rates as you use the connection. 
- Press ^C to halt the process.

## Install as a service

You can install this as a service that starts up the autorate process whenever the router reboots.

To do this:

- [SSH into the router](https://openwrt.org/docs/guide-quick-start/sshadministration)
- Run these commands to install the service file
and start/enable it:

   ```bash
   cd /etc/init.d
   wget https://raw.githubusercontent.com/lynxthecat/CAKE-autorate/main/cake-autorate 
   service CAKE-autorate enable
   service CAKE-autorate start
   ```

When running as a service, the `CAKE-autorate.sh` script outputs to `/tmp/CAKE-autorate.log`.

WARNING: Disabling output by setting **output_processing_stats** to '0' when not required is a good idea given the rate of logging. 

## A Request to Testers

If you use this script I have just one ask. Please post your experience on this [OpenWrt Forum thread](https://forum.openwrt.org/t/cake-w-adaptive-bandwidth/108848/). Your feedback will help improve the script for the benefit of others.  
