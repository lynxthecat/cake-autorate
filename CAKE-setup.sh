#! /bin/ash
# Basic installation script for CAKE-autorate.sh
# See https://github.com/lynxthecat/sqm-autorate for details
# https://www.shellcheck.net/ is your friend

SRC_DIR="https://raw.githubusercontent.com/lynxthecat/CAKE-autorate/main/"

# Retrieve required packages
# opkg update
# opkg install bash iputils-ping 

# Set up CAKE-autorate files
# cd to the /root directory
cd /root/ || exit

# create the CAKE-autorate directory if it's not present
[[ -d CAKE-autorate ]] || mkdir CAKE-autorate

# cd into it
cd CAKE-autorate/ || exit
pwd

# rm the main script and fetch a fresh copy
[[ -f CAKE-autorate.sh ]] && rm CAKE-autorate.sh
wget -q "$SRC_DIR"CAKE-autorate.sh
echo "Retrieved CAKE-autorate.sh"

# Check if the configuration script exists, and ask whether to keep it

if [ -f CAKE-config.sh ]; then
	echo "Previous configuration present - keep it? [Y/n]"
	read keepIt
	if [ "$keepIt" == "N" ] || [ "$keepIt" == "n" ]; then
		rm ./CAKE-config.sh
		wget -q "$SRC_DIR"CAKE-config.sh
		echo "Retrieved CAKE-config.sh"
		echo "Now edit the CAKE-config.sh file as described in:" 
		echo " https://github.com/lynxthecat/CAKE-autorate#installation-on-openwrt"
	else
		echo "Using saved configuration"
	fi
else 
	wget "$SRC_DIR"CAKE-config.sh 
	echo "Retrieved CAKE-config.sh (really)"
	echo "Now edit the CAKE-config.sh file as described in:" 
	echo " https://github.com/lynxthecat/CAKE-autorate#installation-on-openwrt"	
fi
# make both .sh files executable
chmod +x *.sh

# Also copy over the service file but DO NOT ACTIVATE IT
# cd into the directory and remove the previous file
cd /etc/init.d || exit
[[ -f cake-autorate ]] && rm cake-autorate
wget -q "$SRC_DIR"cake-autorate
echo "Retrieved cake-autorate service script"
chmod +x cake-autorate

# Go back to the beginning
cd /root/CAKE-autorate || exit
echo " "
echo "CAKE-autorate installation successful"
echo "You can start the software manually with 'cd /root/CAKE-autorate; bash ./CAKE-autorate.sh'"
echo "   or run as a service with 'service cake-autorate enable;service cake-autorate start'"
