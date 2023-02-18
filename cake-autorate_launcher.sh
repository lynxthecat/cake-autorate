#!/bin/bash

PROC_STATE_FILE=/var/run/cake-autorate-lpids
PROC_STATE_FILE_LOCK="${PROC_STATE_FILE}.lock"
PROC_STATE_KILL_WAIT_MAX=30  # 3 seconds
# shellcheck source=cake-autorate_lib.sh
. /root/cake-autorate/cake-autorate_lib.sh
cake_instances=(/root/cake-autorate/cake-autorate_config*sh)

if [[ -f "${PROC_STATE_FILE}" ]]
then
	echo "Found a previous instance of cake-autorate-launcher running. Refusing to start." >&2
	echo "If you are sure that no other instance is running, delete ${PROC_STATE_FILE} and try again." >&2
	exit 1
fi

trap kill_cake_instances INT TERM EXIT
kill_cake_instances()
{
	trap true INT TERM EXIT
	echo "Killing all instances of cake one-by-one now."
	for cake_instance in "${cake_instances[@]}"
	do
		proc_man_stop "${cake_instance}"
	done
	rm -f "${PROC_STATE_FILE:?}" 2>/dev/null
	rm -f "${PROC_STATE_FILE_LOCK:?}" 2>/dev/null
	trap - INT TERM EXIT
}

for cake_instance in "${cake_instances[@]}"
do
	proc_man_start "${cake_instance}" /root/cake-autorate/cake-autorate.sh "${cake_instance}"
done
wait
