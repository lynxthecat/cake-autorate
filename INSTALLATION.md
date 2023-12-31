# Installing cake-autorate on OpenWrt

**cake-autorate** is a script that minimizes latency by adjusting CAKE
bandwidth settings based on traffic load and round-trip time
measurements. See the main [README](./README.md) page for more details
of the algorithm.

## Installation Steps

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

- Use the installer script by copying and pasting each of the commands
  below. The commands retrieve the current version from this repo:

  ```bash
  wget -O /tmp/cake-autorate_setup.sh https://raw.githubusercontent.com/lynxthecat/cake-autorate/v3.1/setup.sh

  sh /tmp/cake-autorate_setup.sh
  ```

- The installer script will detect a previous configuration file, and
  ask whether to preserve it.

- For a fresh install, you will need to undertake the following steps.

- Edit the _config.primary.sh_ script (in the _/root/cake-autorate_
  directory) using vi or nano to set the configuration parameters
  below (see comments in _config.primary.sh_ for details).

  - Change `dl_if` and `ul_if` to match the names of the upload and
    download interfaces to which CAKE is applied. These can be
    obtained, for example, by consulting the configured SQM settings
    in LuCI or by examining the output of `tc qdisc ls`.

    | Variable | Setting |
    | -------: | :----------------------------------------------- |
    | `dl_if` | Interface that downloads data (often _ifb4-wan_) |
    | `ul_if` | Interface that uploads (often _wan_) |

  - Set bandwidth variables as described in _config.primary.sh_.

    | Type | Download | Upload |
    | ---: | :------------------------- | :------------------------- |
    | Min. | `min_dl_shaper_rate_kbps` | `min_ul_shaper_rate_kbps` |
    | Base | `base_dl_shaper_rate_kbps` | `base_ul_shaper_rate_kbps` |
    | Max. | `max_dl_shaper_rate_kbps` | `max_ul_shaper_rate_kbps` |

  - Choose whether cake-autorate should adjust the shaper rates
    (disable for monitoring only):

    | Variable | Setting |
    | ----------------------: | :----------------------------------------- |
    | `adjust_dl_shaper_rate` | enable (1) or disable (0) download shaping |
    | `adjust_ul_shaper_rate` | enable (1) or disable (0) upload shaping |

- The other configuration file - _defaults.sh_ - has sensible default
  settings. After cake-autorate has been installed and is running, you
  may wish to change some of these.

  - For example, to set a different `dl_delay_thr_ms`, then add a line
    to the config like:

    ```bash
    dl_delay_thr_ms=100
    ```

  - The following variables control logging:

    | Variable | Setting |
    | -----------------------------: | :---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
    | `output_processing_stats` | If non-zero, log the results of every iteration through the process |
    | `output_load_stats` | If non-zero, log the log the measured achieved rates of upload and download |
    | `output_reflector_stats` | If non-zero, log the statistics generated in respect of reflector health monitoring |
    | `output_summary_stats` | If non-zero, log a summary with the key statistics |
    | `output_cake_changes` | If non-zero, log when changes are made to CAKE settings via `tc` - this shows when cake-autorate is adjusting the shaper |
    | `debug` | If non-zero, debug lines will be output |
    | `log_DEBUG_messages_to_syslog` | If non-zero, log lines will also get sent to the system log |
    | `log_to_file` | If non-zero, log lines will be sent to /tmp/cake-autorate.log regardless of whether printing to console `log_file_max_time_mins` have elapsed or `log_file_max_size_KB` has been exceeded |
    | `log_file_max_time_mins` | Number of minutes to elapse between log file rotaton |
    | `log_file_max_size_KB` | Number of KB (i.e. bytes/1024) worth of log lines between log file rotations |

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

## Install as a service

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

WARNING: Take care to ensure sufficient free (Flash) memory exists in
router to handle selected logging parameters.

## Preserving cake-autorate files for backup or upgrades

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
config.interface.sh
```

where 'interface' is replaced with e.g. 'primary', 'secondary', etc.

## Example Starlink Configuration

- OpenWrt forum member @gba has kindly shared
  [his Starlink config](Example_Starlink_config.sh). This ought to
  provide some helpful pointers for adding appropriate overrides for
  Starlink users.
- See discussion on OpenWrt thread from
  [around this post](https://forum.openwrt.org/t/cake-w-adaptive-bandwidth/108848/3100?u=lynx).

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
