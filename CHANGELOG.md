# Changelog

**autorate.sh** is a script that automatically adapts
[CAKE Smart Queue Management (SQM)](https://www.bufferbloat.net/projects/codel/wiki/Cake/)
bandwidth settings by measuring traffic load and RTT times.
Read the [README](./README.md) file for more details.
This is the history of changes.

## 2022-02-18

- Altered CAKE-autorate to employ inotifywait for main loop ticks
- Now main loops ticks are triggered either by a delay event or tick trigger (whichever comes first)

## 2022-02-17

- Completed and uploaded to new CAKE-autorate branch completely new bash implementation
- This will likely be the future for this project 

## 2022-02-04

- Created new experimental-rapid-tick branch in which pings are made asynchronous with the main loop offering significantly more rapid ticks
- Corrected main and both experimental branches to work with min RTT output from each ping call (not average)

## 2021-12-11

- Modified tick duration to 1s and timeout duration to 0.8 seconds in 'owd' code
- This seems to give an owd routine that mostly works
- Tested how 'owd' codes under independent upload and ownload saturations and it seems to work well
- Much optimisation still needed

## 2021-12-10

- Extensive development of 'owd' code
- Noticed tick duration 0.5s would result in slowdown during heavy usage owing to hping3 1s timeout
- Implemented timeout functionality to kill hping3 calls that take longer than 0.X seconds
- @Failsafe's awk parser a total joy to use!

## 2021-12-9

- Based on discussion in OpenWrt CAKE /w Adaptive Bandwidth thread created new 'owd' branch 
- Adapted code to employ timestamp ICMP type 13 requests to try to ascertain direction of bufferbloat
- On OpenWrt CAKE /w Adaptive Bandwidth thread much testing/discussion around various ping utilities
- nping found to support ICMP type 13 but slow and unreliable
- settled on hping3 as identified by @Locknair (OpenWrt forum) as ery efficient and timing information proves reliable
- @Failsafe (OpenWrt forum) demonstrated awk mastery by writing awk parser to handle output of hping3 

## 2021-12-6

- Reverted to old behaviour of decrementing both downlink and uplink rates upon bufferbloat detection
- Whilst guestimating direction of bufferbloat based on load is a nice idea/hack, it proved dangerous and unreliable
- Namely, suppose downlink load is 0.8 and uplink load is 0.4 and it is uplink that causes bufferbloat
- In this situation, decrementing downlink rate (because this is the heavily loaded direction) does not solve 
- The bufferbloat, and this could result in downlink bandwidth being punished down to zero

## 2021-12-4

- @richb-hanover encourages use of single rate rather than min/max rates to help simplify things
- 'experimental' branch created that takes single uplink and downlink rates and adjusts rates based on those
- Seems to work but needs optimisation
- Tried out idea in 'experimental' branch of decrementing only direction that is heavily loaded upon detection of bufferbloat
- It mostly works, but edge cases may break it

## 2021-11-30 and early December

- @richb-hanover encourages use of documentation and helps with creation of readme.
- Readme developed to help users

## 2021-11-23

- Mysterious individual @dim-geo helpfuly replaces bc calls with awk calls
- And also simplifies awk calls

## 2021-late October to early Novermver

- Basic routine tested and adjusted based on testing on 4G connection
- @moeller0 helps tidy up code

## 2021-10-19

- sqm-autorate is born! 
- A brief history:
- @Lynx (OpenWrt forum) wondered about simple algorith along the lines:
- if load < 50% of minimum set load then assume no load and update moving average of unloaded ping to 8.8.8.8
if load > 50% of minimum set load acquire set of sample points by pinging 8.8.8.8 and acquire sample mean
measure bufferbloat by subtracting moving average of unloaded ping from sample mean
ascertain load during sample acquisition and make bandwidth increase or decrease decision based on determined load and determination of bufferbloat or not
- And @Lynx asked SQM/CAKE expert @moeller0 (OpenWrt forum) to suggest a basic algorithm. 
- @moeller0 suggested the following approach: https://forum.openwrt.org/t/cake-w-adaptive-bandwidth/108848/88?u=lynx
- @Lynx wrote a shell script to implement this routine
