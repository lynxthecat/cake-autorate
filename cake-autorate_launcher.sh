#!/bin/bash

cake_instances=(/root/cake-autorate/cake-autorate_config*sh)

trap kill_cake_instances INT TERM EXIT

kill_cake_instances()
{
	trap - INT TERM EXIT
	echo "Killing all instances of cake now."
	kill ${cake_instance_pids[@]}
	wait
	exit
}

cake_instance_pids=()

for cake_instance in "${cake_instances[@]}"
do
	/root/cake-autorate/cake-autorate.sh $cake_instance&
	cake_instance_pids+=($!)
done

sleep inf&
cake_instance_pids+=($!)
wait

