#! /bin/ash
# Basic installation script for CAKE-autorate.sh
# See https://github.com/lynxthecat/sqm-autorate for details
# https://www.shellcheck.net/ is your friend

SRC_DIR="https://raw.githubusercontent.com/lynxthecat/CAKE-autorate/main/"
#SRC_DIR="https://raw.githubusercontent.com/richb-hanover/CAKE-autorate/setup-script/"
DOC_URL="https://github.com/lynxthecat/CAKE-autorate#installation-on-openwrt"

# Retrieve required packages
# opkg update
# opkg install bash iputils-ping 

# Set up CAKE-autorate files
# cd to the /root directory
cd /root/ || exit

# create the CAKE-autorate directory if it's not present
[[ -d CAKE-autorate ]] || mkdir CAKE-autorate

printf "Installing CAKE-autorate in /root/CAKE-autorate...\n"

# cd into it
cd CAKE-autorate/ || exit

# rm the main script and fetch a fresh copy
[[ -f CAKE-autorate.sh ]] && rm CAKE-autorate.sh
wget -q "$SRC_DIR"CAKE-autorate.sh

# Check if the configuration script exists, and ask whether to keep it

editmsg=$(printf "\nNow edit the CAKE-autorate-config.sh file as described in:\n   $DOC_URL")

if [ -f CAKE-autorate-config.sh ]; then
	printf "Previous configuration present - keep it? [Y/n] "
	read keepIt
	if [ "$keepIt" == "N" ] || [ "$keepIt" == "n" ]; then
		rm ./CAKE-autorate-config.sh
		wget -q "$SRC_DIR"CAKE-autorate-config.sh
	else
		editmsg="Using prior configuration"
	fi
else 
	wget -q "$SRC_DIR"CAKE-autorate-config.sh 
fi
# make both .sh files executable
chmod +x *.sh

# Tell how to handle the config file - use old, or edit the new one
printf "$editmsg \n"

# Also copy over the service file but DO NOT ACTIVATE IT
# cd into the directory and remove the previous file
cd /etc/init.d || exit
[[ -f cake-autorate ]] && rm cake-autorate
wget -q "$SRC_DIR"cake-autorate
chmod +x cake-autorate

printf "\n"
printf "`grep CAKE_autorate /root/CAKE-autorate/CAKE-autorate-config.sh` successfully installed but not yet running\n"
printf "\n"
printf "Start the software manually with:\n"
printf "   cd /root/CAKE-autorate; bash ./CAKE-autorate.sh\n"
printf "Run as a service with:\n"
printf "   service cake-autorate enable;service cake-autorate start\n"
