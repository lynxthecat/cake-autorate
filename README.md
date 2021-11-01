# sqm-autorate
Adjusts bandwidth for CAKE by measuring load and RTT times

In summary, for each 'tick':

- under low load, bandwidth decays down to minimum set bandwidth
- under high load, bandwidth is incremented until RTT spike is deteted or until max set bandwidth is hit 
- upon RTT spike, bandwidth is decremented 

Requires packages: 

* bc (for calculations) 
* iputils-ping (for more advanced ping with sub 1s ping frequency)
* coreutils-date (for accurate time keeping)
* coreutils-sleep (for accurate sleeping)

Example steps to set up on OpenWrt:

* enable CAKE on your interfaces of choice as described in the OpenWrt documentation, e.g. here 
https://openwrt.org/docs/guide-user/network/traffic-shaping/sqm
* ssh into router
* run 'opkg update'
* run 'opkg install bc iputils-ping coreutils-date coreutils-sleep
* run 'cd root'
* run 'wget https://raw.githubusercontent.com/lynxthecat/sqm-autorate/main/sqm-autorate.sh'
* run 'chmod +x ./sqm-autorate.sh
* edit script using vi to change parameters for your connection, e.g. upload and download interfaces to which CAKE is applied
* set minimum bandwidth to the minimum bandwidth you want when there is no load
* set maximum bandwidth to the maximum bandwidth you think your connection can obtain
* run script using './sqm-autorate.sh'
* monitor output lines to see how it scales up download and upload rates as you use the connection
* optionally set up service file in /etc/init.d to run as service from LuCi
* the service file outputs to /tmp
* if 'enable_verbose_output' is set to '1' then this will generate one line of text every tick_duration
* so if running script and monitoring is not required then take care to set 'enable_verbose_output' to '0'
