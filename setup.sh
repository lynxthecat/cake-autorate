#!/bin/sh

# Installation script for cake-autorate.sh
#
# See https://github.com/lynxthecat/cake-autorate for more details

# Set correctness options
set -eu

# Setup dependencies to check for
DEPENDENCIES="jsonfilter uclient-fetch tar grep"

# Set up remote locations and branch
BRANCH="master"
REPOSITORY="${CAKE_AUTORATE_REPO:-lynxthecat/cake-autorate}"
SRC_DIR="https://github.com/${REPOSITORY}/archive/"
API_URL="https://api.github.com/repos/${REPOSITORY}/commits/${BRANCH}"
DOC_URL="https://github.com/${REPOSITORY}#installation-on-openwrt"

# Check if an instance of cake-autorate is already running and exit if so
if [ -d /var/run/cake-autorate ]
then
	printf "cake-autorate is already running - exiting\n" >&2
	printf "If you want to install a new version, stop the service first\n" >&2
	printf "If you are sure cake-autorate is not running, delete the /var/run/cake-autorate directory\n" >&2
	exit 1
fi

# Retrieve required packages if not present
# shellcheck disable=SC2312
if [ "$(opkg list-installed | grep -Ec '^(bash|iputils-ping|fping) ')" -ne 3 ]
then
	printf "Running opkg update to update package lists:\n"
	opkg update
	printf "Installing bash, iputils-ping and fping packages:\n"
	opkg install bash iputils-ping fping
fi

exit_now=0
for dep in ${DEPENDENCIES}
do
	if ! type "${dep}" >/dev/null 2>&1; then
		printf >&2 "%s is required, please install it and rerun the script!\n" "${dep}"
		exit_now=1
	fi
done
[ ${exit_now} -ge 1 ] && exit ${exit_now}

# Set up CAKE-autorate files
# cd to the /root directory
cd /root/ || exit

# create the cake-autorate directory if it's not present
[ -d cake-autorate ] || mkdir cake-autorate

# cd into it
cd cake-autorate/ || exit

# Get the latest commit to download
commit=$(uclient-fetch -qO- "${API_URL}" | jsonfilter -e @.sha)
if [ -z "${commit:-}" ];
then
	printf >&2 "Invalid operation occurred, commit variable should not be empty"
	exit 1
fi

printf "Installing cake-autorate in /root/cake-autorate...\n"

# Download the files to a temporary directory, so we can move them to the cake-autorate directory
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT INT TERM
uclient-fetch -qO- "${SRC_DIR}/${commit}.tar.gz" | tar -xozf - -C "${tmp}"
mv "${tmp}/cake-autorate-"*/* "${tmp}"

# Migrate old configuration (and new file) files if present
for file in cake-autorate_config.*.sh*
do
	[ -e "${file}" ] || continue   # handle case where there are no old config files
	new_fname="$(printf '%s\n' "$file" | cut -c15-)"
	mv "${file}" "${new_fname}"
done

# Check if a configuration file exists, and ask whether to keep it
editmsg="\nNow edit the config.primary.sh file as described in:\n   ${DOC_URL}"
if [ -f config.primary.sh ]
then
	printf "Previous configuration present - keep it? [Y/n] "
	read -r keepIt
	if [ "${keepIt}" = "N" ] || [ "${keepIt}" = "n" ]; then
		mv "${tmp}/config.primary.sh" config.primary.sh
		rm -f config.primary.sh.new   # delete config.primary.sh.new if exists
	else
		editmsg="Using prior configuration"
		mv "${tmp}/config.primary.sh" config.primary.sh.new
	fi
else
	mv "${tmp}/config.primary.sh" config.primary.sh
fi

# remove old program files from cake-autorate directory
old_fnames="cake-autorate.sh cake-autorate_defaults.sh cake-autorate_launcher.sh cake-autorate_lib.sh cake-autorate_setup.sh"
for file in ${old_fnames}
do
	rm -f "${file}"
done

# move the program files to the cake-autorate directory
# scripts that need to be executable are already marked as such in the tarball
files="cake-autorate.sh defaults.sh launcher.sh lib.sh setup.sh"
for file in ${files}
do
	mv "${tmp}/${file}" "${file}"
done

# Get version and generate a file containing version information
version=$(grep -m 1 ^cake_autorate_version= /root/cake-autorate/cake-autorate.sh | cut -d= -f2 | cut -d'"' -f2)
cat > version.txt <<-EOF
	version=${version}
	commit=${commit}
EOF

# Also copy over the service file but DO NOT ACTIVATE IT
mv "${tmp}/cake-autorate" /etc/init.d/
chmod +x /etc/init.d/cake-autorate

# Tell how to handle the config file - use old, or edit the new one
# shellcheck disable=SC2059
printf "${editmsg}\n"

printf '\n%s\n\n' "${version} successfully installed, but not yet running"
printf '%s\n' "Start the software manually with:"
printf '%s\n' "   cd /root/cake-autorate; ./cake-autorate.sh"
printf '%s\n' "Run as a service with:"
printf '%s\n\n' "   service cake-autorate enable; service cake-autorate start"
