#!/bin/bash

# shellcheck source=cake-autorate_lib.sh
source /root/cake-autorate/cake-autorate_lib.sh
cake_instances=(/root/cake-autorate/cake-autorate_config*sh)

trap kill_cake_instances INT TERM EXIT

kill_cake_instances()
{
	trap - INT TERM EXIT

	echo "Killing all instances of cake one-by-one now."

	for ((cake_instance=0; cake_instance<${#cake_instances[@]}; cake_instance++))
	do
		kill "${cake_instance_pids[${cake_instance}]}"
		wait "${cake_instance_pids[${cake_instance}]}"
	done
	kill "${sleep_pid}"
}

for cake_instance in "${cake_instances[@]}"
do
	/root/cake-autorate/cake-autorate.sh "$cake_instance"&
	cake_instance_pids+=($!)
	cake_instance_list+=("${cake_instance}")
done

sleep_inf&
sleep_pid+=($!)
wait
