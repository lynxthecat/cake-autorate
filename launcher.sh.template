#!/usr/bin/env bash

cake_instances=(%%CONFIG_PREFIX%%/config.*.sh)
cake_instance_pids=()

trap kill_cake_instances INT TERM EXIT

kill_cake_instances()
{
	trap - INT TERM EXIT

	echo "Killing all instances of cake one-by-one now."

	for ((cake_instance=0; cake_instance<${#cake_instances[@]}; cake_instance++))
	do
		kill "${cake_instance_pids[${cake_instance}]}" 2>/dev/null || true
	done
	wait
}

for cake_instance in "${cake_instances[@]}"
do
	%%SCRIPT_PREFIX%%/cake-autorate.sh "${cake_instance}" &
	cake_instance_pids+=(${!})
done
wait
