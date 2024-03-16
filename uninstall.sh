#!/bin/sh

# Uninstall script for cake-autorate
#
# See https://github.com/lynxthecat/cake-autorate for more details

# This needs to be encapsulated into a function so that we are sure that
# sh reads all the contents of the shell file before we potentially erase it.
#
# Otherwise the read operation might fail and it won't be able to proceed with
# the script as expected.
main() {
	# Set correctness options
	set -eu

	# Check if OS is OpenWRT
	unset ID_LIKE
	. /etc/os-release 2>/dev/null || true
	tainted=1
	for x in ${ID_LIKE:-}
	do
		[ ${x} = "openwrt" ] && tainted=0
	done
	if [ ${tainted} -eq 1 ]
	then
		printf "This script requires OpenWrt.\n" >&2
		return 1
	fi
	unset tainted

	# Stop cake-autorate before continueing
	if [ -x /etc/init.d/cake-autorate ]
	then
		/etc/init.d/cake-autorate stop || true
	fi
	rm -f /etc/init.d/cake-autorate /etc/rc.d/*cake-autorate

	# Check if an instance of cake-autorate is already running and exit if so
	if [ -d /var/run/cake-autorate ]
	then
		printf "At least one instance of cake-autorate appears to be running - exiting\n" >&2
		printf "If you want to uninstall a cake-autorate, first stop any running instance of cake-autorate\n" >&2
		printf "If you are sure that no instance of cake-autorate is running, delete the /var/run/cake-autorate directory\n" >&2
		exit 1
	fi

	# Set up CAKE-autorate files
	# cd to the /root directory
	cd /root/ || exit 1

	# cd into it
	cd cake-autorate/ || exit 1

	# remove configuration files if user does not want to keep them
	keepIt=''
	for file in *config.*.sh*
	do
		[ -e ${file} ] || continue   # handle case where there are no old config files
		if [ -z ${keepIt:-} ]
	        then
	                printf "Would you like to keep your configs? [Y/n]"
	                read -r keepIt
	                [ -z ${keepIt:-} ] && keepIt=Y
	        fi

		if [ ${keepIt} = "N" ] || [ ${keepIt} = "n" ]; then
			rm -f "${file}"
	        fi
	done

	# remove old program files from cake-autorate directory
	old_fnames="cake-autorate.sh cake-autorate_defaults.sh cake-autorate_launcher.sh cake-autorate_lib.sh cake-autorate_setup.sh"
	for file in ${old_fnames}
	do
		rm -f "${file}"
	done

	# remove current program files from the cake-autorate directory
	files="cake-autorate.sh defaults.sh launcher.sh lib.sh setup.sh uninstall.sh"
	for file in ${files}
	do
		rm -f "${file}"
	done

	# remove /root/cake-autorate if empty
	cd ..
	rmdir cake-autorate 2>/dev/null && printf >&2 "Removed empty /root/cake-autorate directory"

	printf '%s\n' "cake-autorate was uninstalled"
}

# Now that we are sure all code is loaded, we could execute the function
main "${@}"
