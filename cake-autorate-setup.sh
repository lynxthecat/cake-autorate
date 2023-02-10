#! /bin/sh
# Basic installation script for cake-autorate.sh
# See https://github.com/lynxthecat/sqm-autorate for details
# https://www.shellcheck.net/ is your friend

SRC_DIR="https://raw.githubusercontent.com/lynxthecat/cake-autorate/stable/"
DOC_URL="https://github.com/lynxthecat/CAKE-autorate#installation-on-openwrt"

# Retrieve required packages if not present
if [ $(opkg list-installed | grep -E '^(bash|iputils-ping|fping) ' | wc -l) -ne 3 ]; then
	printf "Running opkg update to update package lists:\n"
	opkg update
	printf "Installing bash, iputils-ping and fping packages:\n"
	opkg install bash iputils-ping fping
fi

# Set up CAKE-autorate files
# cd to the /root directory
cd /root/ || exit

# create the cake-autorate directory if it's not present
[[ -d cake-autorate ]] || mkdir cake-autorate

printf "Installing cake-autorate in /root/cake-autorate...\n"

# cd into it
cd cake-autorate/ || exit

# rm the main script and fetch a fresh copy
[[ -f cake-autorate.sh ]] && rm cake-autorate.sh
wget -q "$SRC_DIR"cake-autorate.sh

# Check if a configuration file exists, and ask whether to keep it

editmsg="\nNow edit the cake-autorate_config.primary.sh file as described in:\n   $DOC_URL"

if [ -f cake-autorate_config.primary.sh ]; then
	printf "Previous configuration present - keep it? [Y/n] "
	read keepIt
	if [ "$keepIt" == "N" ] || [ "$keepIt" == "n" ]; then
		rm ./cake-autorate_config.primary.sh
		wget -q "$SRC_DIR"cake-autorate_config.primary.sh
	else
		editmsg="Using prior configuration"
	fi
else 
	wget -q "$SRC_DIR"cake-autorate_config.primary.sh 
fi

# make both .sh files executable
chmod +x *.sh

# Tell how to handle the config file - use old, or edit the new one
printf "$editmsg \n"

# Also copy over the service file but DO NOT ACTIVATE IT
# cd into the directory and remove the previous file
wget -q "$SRC_DIR"cake-autorate_launcher.sh
chmod +x cake-autorate_launcher.sh
cd /etc/init.d || exit
[[ -f cake-autorate ]] && rm cake-autorate
wget -q "$SRC_DIR"cake-autorate
chmod +x cake-autorate

printf "\n`grep cake_autorate_version /root/cake-autorate/cake-autorate_config.primary.sh` successfully installed, but not yet running\n\n"
printf "Start the software manually with:\n"
printf "   cd /root/cake-autorate; ./cake-autorate.sh\n"
printf "Run as a service with:\n"
printf "   service cake-autorate enable; service cake-autorate start\n\n"
