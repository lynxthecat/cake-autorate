# Installing cake-autorate

**cake-autorate** is a script that minimizes latency by adjusting CAKE
bandwidth settings based on traffic load and round-trip time
measurements. See the main [README](./README.md) page for more details
of the algorithm.

## Installation Steps (OpenWrt)

cake-autorate provides an installation script that installs all the
required tools. To use it:

- Install SQM (`luci-app-sqm`) and enable and configure `cake` Queue
  Discipline on the interface(s) as described in the
  [OpenWrt SQM documentation](https://openwrt.org/docs/guide-user/network/traffic-shaping/sqm)

- Alternatively, and especially if you may have more complex
  networking needs:

  - DSCPs - consider
    [cake-simple-qos](https://github.com/lynxthecat/cake-qos-simple);
  - WireGuard with PBR - consider
    [cake-dual-ifb](https://github.com/lynxthecat/cake-dual-ifb).

- [SSH into the router](https://openwrt.org/docs/guide-quick-start/sshadministration)

- Ensure `bash` and `fping` are installed.

  On most OpenWrt installations, you can install them by running:

  ```bash
  opkg update
  opkg install bash fping
  ```

  If the `opkg` command is not found, you may need to use `apk`
  instead:

  ```bash
  apk update
  apk add bash fping
  ```

- Use the installer script by copying and pasting each of the commands
  below. The commands retrieve the current version from this repo:

  ```bash
  wget -O /tmp/cake-autorate_setup.sh https://raw.githubusercontent.com/lynxthecat/cake-autorate/master/setup.sh
  sh /tmp/cake-autorate_setup.sh
  ```

- The installer script will detect a previous configuration file, and
  ask whether to preserve it.

## Installation Steps (Asus Merlin)

- From the Asus Merlin GUI: enable adaptive QOS and select cake.

- [SSH into the router](https://github.com/RMerl/asuswrt-merlin.ng/wiki/SSHD)

- Make sure these are installed: entware; coreutils-mktemp; jsonfilter; bash;
  and iputils-ping or fping.

  - Firstly, if not already installed,
    [install entware](https://github.com/RMerl/asuswrt-merlin.ng/wiki/Entware);
  - and then run:

  ```bash
  opkg update
  opkg install coreutils-mktemp jsonfilter bash fping
  ```

- Use the installer script by copying and pasting each of the commands
  below. The commands retrieve the current version from this repo:

  ```bash
  wget -O /tmp/cake-autorate_setup.sh https://raw.githubusercontent.com/lynxthecat/cake-autorate/master/setup.sh
  sh /tmp/cake-autorate_setup.sh
  ```

## Initial Configuration Steps (OpenWrt and Asus Merlin)

- For a fresh install, you will need to undertake the following steps.

- Edit the _config.primary.sh_ script using vi or nano to set the
  configuration parameters below (see comments in _config.primary.sh_
  for details).

  - **OpenWrt:** in the _/root/cake-autorate_ directory
  - **Asus Merlin:** in the _/jffs/configs/cake-autorate_ directory

In the configuration file:

- Change `dl_if` and `ul_if` to match the names of the upload and
  download interfaces to which CAKE is applied.

  | Variable | Setting                                          |
  | -------: | :----------------------------------------------- |
  |  `dl_if` | Interface that downloads data (often _ifb4-wan_) |
  |  `ul_if` | Interface that uploads (often _wan_)             |

- For OpenWrt installations, these can be obtained, for example, by
  consulting the configured SQM settings in LuCi or by examining the
  output of `tc qdisc ls`.

- For Asus Merlin the requisite interfaces can also be obtained by
  examining the output of `tc qdisc ls`. These are most likely:

  ```bash
  dl_if=ifb4eth0 # download interface
  ul_if=eth0     # upload interface
  ```

- Choose whether cake-autorate should adjust the shaper rates (disable
  for monitoring only):

  |                Variable | Setting                                    |
  | ----------------------: | :----------------------------------------- |
  | `adjust_dl_shaper_rate` | enable (1) or disable (0) download shaping |
  | `adjust_ul_shaper_rate` | enable (1) or disable (0) upload shaping   |

- Set bandwidth variables as described in _config.primary.sh_.

  | Type | Download                   | Upload                     |
  | ---: | :------------------------- | :------------------------- |
  | Min. | `min_dl_shaper_rate_kbps`  | `min_ul_shaper_rate_kbps`  |
  | Base | `base_dl_shaper_rate_kbps` | `base_ul_shaper_rate_kbps` |
  | Max. | `max_dl_shaper_rate_kbps`  | `max_ul_shaper_rate_kbps`  |

- Set connection idle variable as described in _config.primary.sh_.

  |                     Variable | Setting                                                  |
  | ---------------------------: | :------------------------------------------------------- |
  | `connection_active_thr_kbps` | threshold in Kbit/s below which dl/ul is considered idle |

## Configuration of cake-autorate

cake-autorate is highly configurable and almost every aspect of it can
be (and is ideally) fine-tuned.

- The file _defaults.sh_ has sensible default settings. After
  cake-autorate has been installed, you may wish to override some of
  these by providing corresponding entries inside _config.primary.sh_.

  - For example, to set a different `dl_owd_delta_delay_thr_ms`, then 
    add a line to the config file _config.primary.sh_ like:

    ```bash
    dl_owd_delta_delay_thr_ms=100.0
    ```

- Users are encouraged to look at _defaults.sh_, which documents the
  many configurable parameters of cake-autorate.

- The type of variable: integer, float, string used in any config file
  must reflect the same type used in _defaults.sh_, and otherwise 
  cake-autorate will throw an error on startup.

  ## Delay thresholds

  - At least the following variables relating to the delay thresholds
    may warrant overriding depending on the connection particulars.

    |                  Variable | Setting                                                                                                      |
    | ------------------------: | :----------------------------------------------------------------------------------------------------------- |
    |                  `dl_owd_delta_delay_thr_ms` | extent of download OWD increase to classify as a delay                                                       |
    |                  `ul_owd_delta_delay_thr_ms` | extent of upload OWD increase to classify as a delay                                                         |
    |      `dl_avg_owd_delta_max_adjust_up_thr_ms` | average download OWD threshold across reflectors at which maximum upward shaper rate adjustment is applied   |
    |      `ul_avg_owd_delta_max_adjust_up_thr_ms` | average upload OWD threshold across reflectors at which maximum upward shaper rate adjustment is applied     |
    |    `dl_avg_owd_delta_max_adjust_down_thr_ms` | average download OWD threshold across reflectors at which maximum downward shaper rate adjustment is applied |
    |    `ul_avg_owd_delta_max_adjust_down_thr_ms` | average upload OWD threshold across reflectors at which maximum downward shaper rate adjustment is applied   |


    An OWD measurement to an individual reflector that exceeds
    `xl_owd_delta_delay_thr_ms` from its baseline is classified as a 
    delay. Bufferbloat is detected when there are 
    `bufferbloat_detection_thr` delays out of the last
    `bufferbloat_detection_window` reflector responses. 

    Prior to bufferbloat detection, the extent of the average OWD
    delta taken across the reflectors governs how much the shaper
    rate is adjusted up. The adjustment is scaled linearly from 
    `shaper_rate_max_adjust_up_load_high` (at or below
    xl_avg_owd_delta_max_adjust_up_thr_ms)
    to `shaper_rate_min_adjust_up_load_high` (at 
    xl_owd_delta_thr_ms).

    Upon bufferbloat detection, the extent of the average OWD delta 
    taken across the reflectors governs how much the shaper rate is 
    adjusted down. The adjustment is scaled linearly from 
    `shaper_rate_min_adjust_down_bufferbloat` (at
    xl_owd_delta_thr_ms) 
    to `shaper_rate_min_adjust_down_bufferbloat` (at or above
    xl_avg_owd_delta_max_adjust_down_thr_ms).
    
    Avoiding bufferbloat requires throttling the connection, and thus
    there is a trade-off between bandwidth and latency.

    The delay thresholds affect how much the shaper rate is punished
    responsive to latency increase. Users that want very low latency
    at all times (at the expense of bandwidth) will want lower values.
    Users that can tolerate higher latency excursions (facilitating
    greater bandwidth).

    Although the default parameters have been designed to offer
    something that might work out of the box for certain connections,
    some analysis is likely required to optimize cake-autorate for the
    specific use-case.

    Read about this in the [ANALYSIS](./ANALYSIS.md) page.

    ## Reflectors

  - Additionally, the following variables relating to reflectors may
    also warrant overriding:

    |                  Variable | Setting                                 |
    | ------------------------: | :-------------------------------------- |
    |              `reflectors` | list of reflectors                      |
    |              `no_pingers` | number of reflectors to ping            |
    | `reflector_ping_interval` | interval between pinging each reflector |

    Reflector choice is a crucial parameter for cake-autorate.

    By default, cake-autorate sends ICMPs to various large anycast DNS
    hosts (Cloudflare, Google, Quad9, etc.).

    It is the responsibility of the user to ensure that the configured
    reflectors provide stable, low-latency responses.

    Some governments appear to block DNS hosts like Google. Users
    affected by the same will need to determine appropriate
    alternative reflectors.

    cake-autorate monitors the responses from reflectors and
    automatically kicks out bad reflectors. The parameters governing
    the same are configurable in the config file (see _defaults.sh_).

    ## Logging

  - The following variables control logging:

    |                       Variable | Setting                                                                                                                                                                                   |
    | -----------------------------: | :---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
    |      `output_processing_stats` | If non-zero, log the results of every iteration through the process                                                                                                                       |
    |            `output_load_stats` | If non-zero, log the log the measured achieved rates of upload and download                                                                                                               |
    |       `output_reflector_stats` | If non-zero, log the statistics generated in respect of reflector health monitoring                                                                                                       |
    |         `output_summary_stats` | If non-zero, log a summary with the key statistics                                                                                                                                        |
    |          `output_cake_changes` | If non-zero, log when changes are made to CAKE settings via `tc` - this shows when cake-autorate is adjusting the shaper                                                                  |
    |             `output_cpu_stats` | If non-zero, monitor and log CPU usage percentages across the detected cores                                                                                                              |
    |         `output_cpu_raw_stats` | If non-zero, log the raw CPU usage lines obtained during CPU usage monitoring                                                                                                              |
    |                        `debug` | If non-zero, debug lines will be output                                                                                                                                                   |
    | `log_DEBUG_messages_to_syslog` | If non-zero, log lines will also get sent to the system log                                                                                                                               |
    |                  `log_to_file` | If non-zero, log lines will be sent to /tmp/cake-autorate.log regardless of whether printing to console `log_file_max_time_mins` have elapsed or `log_file_max_size_KB` has been exceeded |
    |       `log_file_max_time_mins` | Number of minutes to elapse between log file rotaton                                                                                                                                      |
    |         `log_file_max_size_KB` | Number of KB (i.e. bytes/1024) worth of log lines between log file rotations                                                                                                              |

## Manual testing

To start the `cake-autorate.sh` script and watch the logged output as
it adjusts the CAKE parameters, run these commands:

```bash
cd /root/cake-autorate     # to the cake-autorate directory
./cake-autorate.sh
```

- Monitor the script output to see how it adjusts the download and
  upload rates as you use the connection.
- Press ^C to halt the process.

## Install as a service (OpenWrt)

You can install cake-autorate as a service that starts up the autorate
process whenever the router reboots. To do this:

- [SSH into the router](https://openwrt.org/docs/guide-quick-start/sshadministration)

- Run these commands to enable and start the service file:

  ```bash
  # the setup.sh script already installed the service file
  service cake-autorate enable
  service cake-autorate start
  ```

If you edit any of the configuration files, you will need to restart
the service with `service cake-autorate restart`

When running as a service, the `cake-autorate.sh` script outputs to
_/var/log/cake-autorate.primary.log_ (observing the instance
identifier _cake-autorate_config.identifier.sh_ set in the config file
name).

WARNING: Take care to ensure sufficient free memory exists on router
to handle selected logging parameters. Consider disabling logging or
adjusting logging parameters such as `log_file_max_time_mins` or
`log_file_max_size_KB` if necessary.

## Launch on Boot (Asus Merlin)

cake-autorate can be launched on boot by adding an appropriate entry
to e.g. post-mount - see
[here](https://github.com/RMerl/asuswrt-merlin.ng/wiki/User-scripts).

For example, add these lines to /jffs/scripts/post-mount:

```bash
source /etc/profile
/jffs/scripts/cake-autorate/launcher.sh
```

## Preserving cake-autorate files for backup or upgrades (OpenWrt)

OpenWrt devices can save files across upgrades. Read the
[Backup and Restore page on the OpenWrt wiki](https://openwrt.org/docs/guide-user/troubleshooting/backup_restore#customize_and_verify)
for details.

To ensure the cake-autorate script and configuration files are
preserved, enter the files below to the OpenWrt router's
[Configuration tab](https://openwrt.org/docs/guide-user/troubleshooting/backup_restore#back_up)

```bash
/root/cake-autorate
/etc/init.d/cake-autorate
```

## Multi-WAN Setups

- cake-autorate has been designed to run multiple instances
  simultaneously.
- cake-autorate will run one instance per config file present in the
  _/root/cake-autorate/_ directory in the form:

```bash
config.instance.sh
```

where 'instance' is replaced with e.g. 'primary', 'secondary', etc.

## Selecting a "ping binary"

cake-autorate reads the `$pinger_binary` variable in the config file
to select the ping binary. Choices include:

- **fping** (DEFAULT) round robin pinging to multiple reflectors with
  tightly controlled timings
- **tsping** round robin ICMP type 13 pinging to multiple reflectors
  with tightly controlled timings
- **iputils-ping** more advanced pinging than the default busybox ping
  with sub 1s ping frequency

**About tsping** @Lochnair has coded up an elegant ping utility in C
that sends out ICMP type 13 requests in a round robin manner, thereby
facilitating determination of one way delays (OWDs), i.e. not just
round trip time (RTT), but the constituent download and upload delays,
relative to multiple reflectors. Presently this must be compiled
manually (although we can expect an official OpenWrt package soon).

Instructions for building a `tsping` OpenWrt package are available
[from github.](https://github.com/Lochnair/tsping)
