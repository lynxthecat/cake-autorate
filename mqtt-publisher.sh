#!/usr/bin/env bash

CPU_CORES=2

MQTT_HOST=""
MQTT_PORT=""
MQTT_USER=""
MQTT_PASS=""

DISC_PREFIX="homeassistant"
BASE_DEVICE_ID="cake_autorate"
BASE_DEVICE_NAME="cake-autorate"
BASE_MQTT_TOPIC="cake-autorate"

MIN_INTERVAL_S=1

set -m

cleanup() 
{
    trap - INT TERM EXIT
    for pid in "${publish_stats_pids[@]}"; do
        kill -- -"$pid" 2>/dev/null || true
    done
    exit 0
}

publish_config() 
{
    local device_id="$1"
    local object_id="$2"
    local payload="$3"

    mosquitto_pub \
        -h "$MQTT_HOST" -p "$MQTT_PORT" \
        -u "$MQTT_USER" -P "$MQTT_PASS" \
        -r -q 1 \
        -t "$DISC_PREFIX/sensor/$device_id/$object_id/config" \
        -m "$payload"
}

publish_discovery() 
{
    local DEVICE_ID="${BASE_DEVICE_ID}_${1}"
    local DEVICE_NAME="${BASE_DEVICE_NAME} (${1})"
    local MQTT_TOPIC="${BASE_MQTT_TOPIC}/${1}"

    publish_config "$DEVICE_ID" "dl_achieved_rate_kbps" \
    "{\"name\":\"DL Achieved Rate\",\"state_topic\":\"$MQTT_TOPIC\",\"value_template\":\"{{ value_json.dl_achieved_rate_kbps }}\",\"unit_of_measurement\":\"kbps\",\"unique_id\":\"${DEVICE_ID}_dl_achieved_rate\",\"device\":{\"identifiers\":[\"$DEVICE_ID\"],\"name\":\"$DEVICE_NAME\"}}"

    publish_config "$DEVICE_ID" "ul_achieved_rate_kbps" \
    "{\"name\":\"UL Achieved Rate\",\"state_topic\":\"$MQTT_TOPIC\",\"value_template\":\"{{ value_json.ul_achieved_rate_kbps }}\",\"unit_of_measurement\":\"kbps\",\"unique_id\":\"${DEVICE_ID}_ul_achieved_rate\",\"device\":{\"identifiers\":[\"$DEVICE_ID\"],\"name\":\"$DEVICE_NAME\"}}"

    publish_config "$DEVICE_ID" "cake_dl_rate_kbps" \
    "{\"name\":\"CAKE DL Rate\",\"state_topic\":\"$MQTT_TOPIC\",\"value_template\":\"{{ value_json.cake_dl_rate_kbps }}\",\"unit_of_measurement\":\"kbps\",\"unique_id\":\"${DEVICE_ID}_cake_dl_rate\",\"device\":{\"identifiers\":[\"$DEVICE_ID\"],\"name\":\"$DEVICE_NAME\"}}"

    publish_config "$DEVICE_ID" "cake_ul_rate_kbps" \
    "{\"name\":\"CAKE UL Rate\",\"state_topic\":\"$MQTT_TOPIC\",\"value_template\":\"{{ value_json.cake_ul_rate_kbps }}\",\"unit_of_measurement\":\"kbps\",\"unique_id\":\"${DEVICE_ID}_cake_ul_rate\",\"device\":{\"identifiers\":[\"$DEVICE_ID\"],\"name\":\"$DEVICE_NAME\"}}"

    publish_config "$DEVICE_ID" "dl_sum_delays" \
    "{\"name\":\"DL Delay Sum\",\"state_topic\":\"$MQTT_TOPIC\",\"value_template\":\"{{ value_json.dl_sum_delays }}\",\"unit_of_measurement\":\"us\",\"unique_id\":\"${DEVICE_ID}_dl_delay\",\"device\":{\"identifiers\":[\"$DEVICE_ID\"],\"name\":\"$DEVICE_NAME\"}}"

    publish_config "$DEVICE_ID" "ul_sum_delays" \
    "{\"name\":\"UL Delay Sum\",\"state_topic\":\"$MQTT_TOPIC\",\"value_template\":\"{{ value_json.ul_sum_delays }}\",\"unit_of_measurement\":\"us\",\"unique_id\":\"${DEVICE_ID}_ul_delay\",\"device\":{\"identifiers\":[\"$DEVICE_ID\"],\"name\":\"$DEVICE_NAME\"}}"

    publish_config "$DEVICE_ID" "dl_avg_owd_delta_us" \
    "{\"name\":\"DL OWD Delta\",\"state_topic\":\"$MQTT_TOPIC\",\"value_template\":\"{{ value_json.dl_avg_owd_delta_us }}\",\"unit_of_measurement\":\"us\",\"unique_id\":\"${DEVICE_ID}_dl_owd\",\"device\":{\"identifiers\":[\"$DEVICE_ID\"],\"name\":\"$DEVICE_NAME\"}}"

    publish_config "$DEVICE_ID" "ul_avg_owd_delta_us" \
    "{\"name\":\"UL OWD Delta\",\"state_topic\":\"$MQTT_TOPIC\",\"value_template\":\"{{ value_json.ul_avg_owd_delta_us }}\",\"unit_of_measurement\":\"us\",\"unique_id\":\"${DEVICE_ID}_ul_owd\",\"device\":{\"identifiers\":[\"$DEVICE_ID\"],\"name\":\"$DEVICE_NAME\"}}"

    publish_config "$DEVICE_ID" "dl_load_condition" \
    "{\"name\":\"DL Load Condition\",\"state_topic\":\"$MQTT_TOPIC\",\"value_template\":\"{{ value_json.dl_load_condition }}\",\"unique_id\":\"${DEVICE_ID}_dl_condition\",\"device\":{\"identifiers\":[\"$DEVICE_ID\"],\"name\":\"$DEVICE_NAME\"}}"

    publish_config "$DEVICE_ID" "ul_load_condition" \
    "{\"name\":\"UL Load Condition\",\"state_topic\":\"$MQTT_TOPIC\",\"value_template\":\"{{ value_json.ul_load_condition }}\",\"unique_id\":\"${DEVICE_ID}_ul_condition\",\"device\":{\"identifiers\":[\"$DEVICE_ID\"],\"name\":\"$DEVICE_NAME\"}}"

    publish_config "$DEVICE_ID" "cpu_total" \
    "{\"name\":\"CPU Total\",\"state_topic\":\"$MQTT_TOPIC\",\"value_template\":\"{{ value_json.cpu_total }}\",\"unit_of_measurement\":\"%\",\"unique_id\":\"${DEVICE_ID}_cpu_total\",\"device\":{\"identifiers\":[\"$DEVICE_ID\"],\"name\":\"$DEVICE_NAME\"}}"

    for c in $(seq 0 $((CPU_CORES - 1))); do
        publish_config "$DEVICE_ID" "cpu_core$c" \
        "{\"name\":\"CPU Core $c\",\"state_topic\":\"$MQTT_TOPIC\",\"value_template\":\"{{ value_json.cpu_core$c }}\",\"unit_of_measurement\":\"%\",\"unique_id\":\"${DEVICE_ID}_cpu_core$c\",\"device\":{\"identifiers\":[\"$DEVICE_ID\"],\"name\":\"$DEVICE_NAME\"}}"
    done
}

publish_stats() 
{
    local log_file_path="${1}"

    local instance="$(basename "${log_file_path}" | sed -E 's/^cake-autorate\.([^.]+)\.log$/\1/')"

    local MQTT_TOPIC="${BASE_MQTT_TOPIC}/${instance}"

    publish_discovery "${instance}"

    while true; do
        tail -F "${log_file_path}" 2>/dev/null | \
        awk -F'; ' -v min_int="$MIN_INTERVAL_S" '
        BEGIN {
            last_emit = 0
            dl_achieved_rate_kbps = ul_achieved_rate_kbps = 0
            dl_sum_delays = ul_sum_delays = 0
            dl_avg_owd_delta_us = ul_avg_owd_delta_us = 0
            dl_load_condition = ul_load_condition = "unknown"
            cake_dl_rate_kbps = cake_ul_rate_kbps = 0
            cpu_total = cpu_core0 = cpu_core1 = 0
            summary_epoch = cpu_epoch = 0
        }

        $1=="SUMMARY" && NF>=13 {
            summary_epoch = $3+0
            dl_achieved_rate_kbps = $4
            ul_achieved_rate_kbps = $5
            dl_sum_delays = $6
            ul_sum_delays = $7
            dl_avg_owd_delta_us = $8
            ul_avg_owd_delta_us = $9
            dl_load_condition = $10
            ul_load_condition = $11
            cake_dl_rate_kbps = $12
            cake_ul_rate_kbps = $13
        }

        $1=="CPU" && NF>=7 {
            cpu_epoch = $3+0
            cpu_total = $5
            cpu_core0 = $6
            cpu_core1 = $7
        }

        {
            event_epoch = (summary_epoch > cpu_epoch) ? summary_epoch : cpu_epoch
            if (event_epoch > 0 && event_epoch - last_emit >= min_int) {
                last_emit = event_epoch
                printf "{\"event_epoch\":%.6f,\"dl_achieved_rate_kbps\":%s,\"ul_achieved_rate_kbps\":%s,\"dl_sum_delays\":%s,\"ul_sum_delays\":%s,\"dl_avg_owd_delta_us\":%s,\"ul_avg_owd_delta_us\":%s,\"dl_load_condition\":\"%s\",\"ul_load_condition\":\"%s\",\"cake_dl_rate_kbps\":%s,\"cake_ul_rate_kbps\":%s,\"cpu_total\":%s,\"cpu_core0\":%s,\"cpu_core1\":%s}\n",
                    event_epoch,
                    dl_achieved_rate_kbps,
                    ul_achieved_rate_kbps,
                    dl_sum_delays,
                    ul_sum_delays,
                    dl_avg_owd_delta_us,
                    ul_avg_owd_delta_us,
                    dl_load_condition,
                    ul_load_condition,
                    cake_dl_rate_kbps,
                    cake_ul_rate_kbps,
                    cpu_total,
                    cpu_core0,
<<<<<<< fix/mqtt-publisher-cpu-labels
                    cpu_core1
=======
                    cpu_core1,
                    cpu_core2
                fflush("")
>>>>>>> master
            }
        }
        ' | mosquitto_pub \
            -h "$MQTT_HOST" -p "$MQTT_PORT" \
            -u "$MQTT_USER" -P "$MQTT_PASS" \
            -t "$MQTT_TOPIC" -l -q 1

        sleep 5
    done
}

trap cleanup INT TERM EXIT

publish_stats_pids=()

for log_file_path in /var/log/cake-autorate.*.log; do
    ( publish_stats "$log_file_path" ) &
    publish_stats_pids+=($!)
done

wait

