#!/bin/bash


$( type logger 2>&1 ) && use_logger=1 || use_logger=0	# only perform the test once...

cake_instances=(/root/cake-autorate/cake-autorate_config*sh)

trap kill_cake_instances INT TERM EXIT

kill_cake_instances()
{
	trap - INT TERM EXIT

	echo "Killing all instances of cake one-by-one now."

	for ((cake_instance=0; cake_instance<${#cake_instances[@]}; cake_instance++))
	do
		out_string="INFO: ${EPOCHREALTIME} terminating ${cake_instance_list[${cake_instance}]}"
		echo ${out_string}
		# it is quite helpful to have a start marker per autorate instance in the system log
		(( ${use_logger} )) && logger -t "cake-autorate_launcher" "${out_string}"
		kill ${cake_instance_pids[${cake_instance}]}
		wait ${cake_instance_pids[${cake_instance}]}
	done
	kill ${sleep_pid}
	exit
}

for cake_instance in "${cake_instances[@]}"
do
	
	# it is quite helpful to have a start marker per utorate instance in the system log
	(( ${use_logger} )) && logger -t "cake-autorate_launcher" "INFO: ${EPOCHREALTIME} Launching cake-autorate with config ${cake_instance}"
	
	/root/cake-autorate/cake-autorate.sh $cake_instance&
	cake_instance_pids+=($!)
	cake_instance_list+=(${cake_instance})
done

sleep inf&
sleep_pid+=($!)
wait

