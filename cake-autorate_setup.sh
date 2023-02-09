#!/bin/sh

# Installation script for cake-autorate.sh
#
# See https://github.com/lynxthecat/cake-autorate for more details

# Set correctness options
set -eu

# Set up remote locations and branch
SRC_DIR="https://github.com/lynxthecat/cake-autorate/archive/refs/heads/"
DOC_URL="https://github.com/lynxthecat/CAKE-autorate#installation-on-openwrt"
BRANCH="testing"

# Retrieve required packages
printf "Running opkg update to update package lists:\n"
opkg update
printf "Installing bash, iputils-ping and fping packages:\n"
opkg install bash iputils-ping fping

# Set up CAKE-autorate files
# cd to the /root directory
cd /root/ || exit

# create the cake-autorate directory if it's not present
[ -d cake-autorate ] || mkdir cake-autorate

# cd into it
cd cake-autorate/ || exit

printf "Installing cake-autorate in /root/cake-autorate...\n"

# Download the files to a temporary directory, so we can move them to the cake-autorate directory
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT INT TERM
wget -qO- "${SRC_DIR}/${BRANCH}.tar.gz" | tar -xozf - -C "${tmp}"
mv "${tmp}/cake-autorate-${BRANCH}"/* "${tmp}"

# Check if a configuration file exists, and ask whether to keep it
editmsg="\nNow edit the cake-autorate_config.primary.sh file as described in:\n   $DOC_URL"
if [ -f cake-autorate_config.primary.sh ]; then
	printf "Previous configuration present - keep it? [Y/n] "
	read -r keepIt
	if [ "$keepIt" = "N" ] || [ "$keepIt" = "n" ]; then
		mv "${tmp}/cake-autorate_config.primary.sh" cake-autorate_config.primary.sh
	else
		editmsg="Using prior configuration"
		mv "${tmp}/cake-autorate_config.primary.sh" cake-autorate_config.primary.sh.new
	fi
else 
	mv "${tmp}/cake-autorate_config.primary.sh" cake-autorate_config.primary.sh
fi

# move the program files to the cake-autorate directory
# scripts that need to be executable are already marked as such in the tarball
files="cake-autorate.sh cake-autorate_defaults.sh cake-autorate_launcher.sh cake-autorate_lib.sh cake-autorate_setup.sh"
for file in $files; do
	mv "${tmp}/${file}" "${file}"
done

# Also copy over the service file but DO NOT ACTIVATE IT
mv "${tmp}/cake-autorate" /etc/init.d/
chmod +x /etc/init.d/cake-autorate

# Tell how to handle the config file - use old, or edit the new one
printf '%s\n' "$editmsg"

printf '\n%s\n\n' "$(grep cake_autorate_version /root/cake-autorate/cake-autorate_config.primary.sh) successfully installed, but not yet running"
printf '%s\n' "Start the software manually with:"
printf '%s\n' "   cd /root/cake-autorate; ./cake-autorate.sh"
printf '%s\n' "Run as a service with:"
printf '%s\n\n' "   service cake-autorate enable; service cake-autorate start"
