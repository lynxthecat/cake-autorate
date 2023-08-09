# Changelog

**cake-autorate** is a script that minimizes latency by adjusting CAKE
bandwidth settings based on traffic load and one-way-delay or
round-trip time measurements. Read the [README](./README.md) file for
more about cake-autorate. This is the history of changes.

<!-- Zep7RkGZ52|NEW ENTRY MARKER, DO NOT REMOVE -->

## 2023-07-29 - Version 3.1.0

- Removed consulting the achieved rate when setting the new shaper 
rate on detection of bufferbloat. Whilst the achieved transfer rate
on bufferbloat detection can give insight into the connection capacity,
leveraging this effectively proved troublesome.
- Introduced scaling of shaper rate reduction on bufferbloat based on
the average OWD delta taken across the bufferbloat detection window
as a portion of a user configurable average OWD delta threshold.
- Amended existing DATA log lines for more consistency and to incorporate 
the average OWD deltas and compensated thresholds.
- Introduced new SUMMARY log lines to offer a simple way to see a 
summary of key statistics using: `grep -e SUMMARY`.
- Utilities that read from log file(s) will need to be updated to 
take into account the changes to the logging. 

## 2023-07-08 - Version 3.0.0

- Version 3.0.0 of cake-autorate is the culmination of dozens of
  experiments, iterative improvements, and testing that are described
  in the 2.0.0 section below. To indicate that the current code
  contains significant enhancements (and avoid confusion), we decided
  to release this code with a new version number.

## 2023-07-05 - Version 2.0.0

- This version restructures the bash code for improved robustness,
  stability and performance.
- Employ FIFOs for passing not only data, but also instructions,
  between the major processes, obviating costly reliance on temporary
  files. A side effect of this is that now /var/run/cake-autorate is
  mostly empty during runs.
- Significantly reduced CPU consumption - cake-autorate can now run
  successfully on older routers.
- Introduce support for one way delays (OWDs) using the 'tsping'
  binary developed by @Lochnair. This works with ICMP type 13
  (timestamp) requests to ascertain the delay in each direction (i.e.
  OWDs).
- Many changes to help catch and handle or expose unusual error
  conditions.
- Fixed eternal sleep issue.
- Introduce more user-friendly config format by introducing
  defaults.sh and config.X.sh with the basics (interface names,
  whether to adjust the shaper rates and the min, base and max shaper
  rates) and any overrides from the defaults defined in defaults.sh.
- More intelligent check for another running instance.
- Introduce more user-friendly log file exports by automatically
  generating an export script and a log reset script for each running
  cake-autorate instance inside /var/run/cake-autorate/\*/.
- Added config file validation that checks all config file entries
  against those provided in defaults.sh. Firstly, the validation
  checks that the config file key finds a corresponding key in
  defaults.sh. And secondly, it checks that the value is of the same
  type out of array, integer, float, string, etc. Any identified
  problematic keys or values are reported to the user to assist with
  resolving any bad entries.
- Improved installer and new uninstaller.
- Many more fixes and improvements.
- Particular thanks to @rany2 for his input on this version.

## 2022-12-13 - Version 1.2

- cake-autorate now includes a sophisticated offline log file analysis
  utility written in Matlab/Octave: 'fn_parse_autorate_log.m' and
  maintained by @moeller0. This utility takes in a cake-autorate
  generated log file (in compressed or uncompressed format), which can
  be generated on the fly by sending an appropriate signal, and
  presents beautiful plots that depict latency and bandwidth over time
  together with many important cake-autorate vitals. This gratly
  simplifies assessing the efficacy of cake-autorate and associated
  settings on a given connection.
- Multiple instances of cake-autorate is now supported. cake-autorate
  can now be run on multiple interfaces such as in the case of mwan3
  failover. The interface is assigned by designating an appropaite
  interface identifier 'X' in the config file in the form
  cake-autorate_config.X.sh. A launcher script has been created that
  creates one cake-autorate instance per cake-autorate_config file
  placed inside /root/cake-autorate/. Log files are generated for each
  instance using the form /var/log/cake-autorate.X.log. The interface
  identifier 'X' cannot be empty.
- Improved reflector management. With a relatively high frequency
  (default 1 minute) cake-autorate now compares reflector baselines
  and deltas and rotates out reflectors with either baselines that are
  excessively higher than the minimum or deltas that are too close to
  the trigger threshold. And with a relatively low frequency (default
  60 minutes), cake-autorate now randomly rotates out a reflector from
  the presently active list. This simple algorithm is intended to
  converge upon a set of good reflectors from the intitial starting
  set. The initial starting set is now also randomized from the
  provided list of reflectors. The user is still encouraged to test
  the initial reflector list to rule out any particularly far away or
  highly variable reflectors.
- Reflector stats may now optionally be printed to help monitor the
  efficacy of the reflector management and quality of the present
  reflectors.
- LOAD stats may now optionally be printed to monitor achieved rates
  during sleep periods when pingers are shutdown.
- For each new sample, the baseline is now subtracted after having
  been updated rather than before having been updated.
- Pinger prefix and arguments are now facilitated for the chosen
  pinger binary to help improve compatibility with mwan3.
- Consideration was afforded to switching over to the use of SMA
  rather than EWMA for reflector baselines, but SMA was found to offer
  minimal improvement as compared to EWMA with appropriately chosen
  alpha values. The present use of EWMA with multiple alphas for
  increase and decrease enables tracking of either reflector owd
  minimums (conservative default) or averages (by setting alphas to
  around e.g. 0.095).
- User can now specify own log path, e.g. in case of logging out to
  cloud mount using rclone or USB stick

## 2022-09-28 - Version 1.1

Implemented several new features such as:

- Switch default pinger binary to fping - it was identified that using
  concurrent instances of iputils-ping resulted in drift between ICMP
  requests, and fping solves this because it offers round robin
  pinging to multiple reflectors with tightly controlled timing
  between requests
- Generalised pinger functions to support wrappers for different ping
  binaries - fping and iputils-ping now specifically supported and
  handled, and new ping binaries can easily be added by including
  appropriate wrapper functions.
- Generalised code to work with one way delays (OWDs) from RTTs in
  preparation to use ICMP type 13 requests
- Only use capacity estimate on bufferbloat detection where the
  adjusted shaper rate based thereon would exceed the minimum
  configured shaper rate (avoiding the situation where e.g. idle load
  on download during upload-related bufferbloat would cause download
  shaper rate to get punished all the way down to the minimum)
- Stall detection and handling
- Much better log file handling including defaulting to logging,
  supporting logging even when running from console, log file rotation
  on configured time elapsed or configured bytes written to

## 2022-08-21 - Version 1.0

- New installer script - cake-autorate-setup.sh - now installs all
  required files
- Installer checks for presence of previous config and asks whether to
  overwrite
- Installer also copies the service script into
  `/etc/init.d/cake-autorate`
- Installer does NOT start the software, but displays instructions for
  config and starting
- At startup, display version number and interface name and configured
  speeds
- Abort if the configured interfaces do not exist
- Style guide: the name of the algorithm and repo is "cake-autorate"
- All "cake-autorate..." filenames are lower case
- New log_msg() function that places a simple time stamp on the each
  line
- Moved images to their own directory
- No other new/interesting functionality

## 2022-07-01

- Significant testing with a Starlink connection (thanks to @gba)
- Have added code to compensate for Starlink satelite switch times to
  preemptively reduce shaper rates prior to switch thereby to help
  prevent or at least reduce the otherwise large RTT spikes associate
  with the switching

## 2022-06-07

- Add optional startup delay
- Fix octal/base issue on calculation of loads by forcing base 10
- Prevent crash on interface reset in which rx/tx_bytes counters are
  reset by checking for negative achieved rates and setting to zero
- Verify interfaces are up on startup and on main loop exit (and wait
  as necessary for them to come up)

## 2022-06-02

- No further changes - author now runs this code 24/7 as a service and
  it seems to **just work**

## 2022-04-25

- Included reflector health monitoring and support for reflector
  rotation upon detection of bad reflectors
- **Overall the code now seems to work very well and seems to have
  reached a mature stage**

## 2022-04-19

- Many further optimizations to reduce CPU use and improve performance
- Replaced coreutils-sleep with 'read -t' on dummy fifo to use bash
  inbuilt
- Added various features to help with weaker LTE connections
- Implemented significant number of robustifications

## 2022-03-21

- Huge reworking of cake-autorate. Now individual processes ping a
  reflector, maintain a baseline, and write out result lines to a
  common FIFO that is read in by a main loop and processed. Several
  optimisations have been effected to reduce CPU load. Sleep
  functionality has been added to put the pinging processes to sleep
  when the connection is not being used and to wake back up when the
  connection is used again - this saves unecessary CPU cycles and
  issuing pings throughout the 'wee' hours of the night.
- This script seems to be working very well on the author's LTE
  conneciton. The author personally uses it as a service 24/7 now.

## 2022-02-18

- Altered cake-autorate to employ inotifywait for main loop ticks
- Now main loops ticks are triggered either by a delay event or tick
  trigger (whichever comes first)

## 2022-02-17

- Completed and uploaded to new cake-autorate branch completely new
  bash implementation
- This will likely be the future for this project

## 2022-02-04

- Created new experimental-rapid-tick branch in which pings are made
  asynchronous with the main loop offering significantly more rapid
  ticks
- Corrected main and both experimental branches to work with min RTT
  output from each ping call (not average)

## 2021-12-11

- Modified tick duration to 1s and timeout duration to 0.8 seconds in
  'owd' code
- This seems to give an owd routine that mostly works
- Tested how 'owd' codes under independent upload and ownload
  saturations and it seems to work well
- Much optimisation still needed

## 2021-12-10

- Extensive development of 'owd' code
- Noticed tick duration 0.5s would result in slowdown during heavy
  usage owing to hping3 1s timeout
- Implemented timeout functionality to kill hping3 calls that take
  longer than 0.X seconds
- @Failsafe's awk parser a total joy to use!

## 2021-12-9

- Based on discussion in OpenWrt CAKE /w Adaptive Bandwidth thread
  created new 'owd' branch
- Adapted code to employ timestamp ICMP type 13 requests to try to
  ascertain direction of bufferbloat
- On OpenWrt CAKE /w Adaptive Bandwidth thread much testing/discussion
  around various ping utilities
- nping found to support ICMP type 13 but slow and unreliable
- settled on hping3 as identified by @Locknair (OpenWrt forum) as ery
  efficient and timing information proves reliable
- @Failsafe demonstrated awk mastery by writing awk parser to handle
  output of hping3

## 2021-12-6

- Reverted to old behaviour of decrementing both downlink and uplink
  rates upon bufferbloat detection
- Whilst guestimating direction of bufferbloat based on load is a nice
  idea/hack, it proved dangerous and unreliable
- Namely, suppose downlink load is 0.8 and uplink load is 0.4 and it
  is uplink that causes bufferbloat
- In this situation, decrementing downlink rate (because this is the
  heavily loaded direction) does not solve
- The bufferbloat, and this could result in downlink bandwidth being
  punished down to zero

## 2021-12-4

- @richb-hanover encourages use of single rate rather than min/max
  rates to help simplify things
- 'experimental' branch created that takes single uplink and downlink
  rates and adjusts rates based on those
- Seems to work but needs optimisation
- Tried out idea in 'experimental' branch of decrementing only
  direction that is heavily loaded upon detection of bufferbloat
- It mostly works, but edge cases may break it

## 2021-11-30 and early December

- @richb-hanover encourages use of documentation and helps with
  creation of readme.
- Readme developed to help users

## 2021-11-23

- Mysterious individual @dim-geo helpfuly replaces bc calls with awk
  calls
- And also simplifies awk calls

## 2021-late October to early Novermver

- Basic routine tested and adjusted based on testing on 4G connection
- @moeller0 helps tidy up code

## 2021-10-19

- sqm-autorate is born!
- A brief history:
- @Lynx (OpenWrt forum) wondered about simple algorith along the
  lines:
- if load \< 50% of minimum set load then assume no load and update
  moving average of unloaded ping to 8.8.8.8 if load > 50% of minimum
  set load acquire set of sample points by pinging 8.8.8.8 and acquire
  sample mean measure bufferbloat by subtracting moving average of
  unloaded ping from sample mean ascertain load during sample
  acquisition and make bandwidth increase or decrease decision based
  on determined load and determination of bufferbloat or not
- And @Lynx asked SQM/CAKE expert @moeller0 (OpenWrt forum) to suggest
  a basic algorithm.
- @moeller0 suggested the following approach:
  <https://forum.openwrt.org/t/cake-w-adaptive-bandwidth/108848/88?u=lynx>
- @Lynx wrote a shell script to implement this routine
