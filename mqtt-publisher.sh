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
    # Publish offline status for all instances on graceful shutdown
    local log_file_path
    shopt -s nullglob
    for log_file_path in /var/log/cake-autorate.*.log; do
        local instance="$(basename "${log_file_path}" | sed -E 's/^cake-autorate\.([^.]+)\.log$/\1/')"
        mosquitto_pub \
            -h "$MQTT_HOST" -p "$MQTT_PORT" \
            -u "$MQTT_USER" -P "$MQTT_PASS" \
            -r -q 1 \
            -t "${BASE_MQTT_TOPIC}/${instance}/availability" \
            -m "offline" 2>/dev/null || true
    done
    shopt -u nullglob
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
    local AVAIL_TOPIC="${BASE_MQTT_TOPIC}/${1}/availability"

    publish_config "$DEVICE_ID" "dl_achieved_rate_kbps" \
    "{\"name\":\"DL Achieved Rate\",\"state_topic\":\"$MQTT_TOPIC\",\"value_template\":\"{{ value_json.dl_achieved_rate_kbps }}\",\"unit_of_measurement\":\"kbps\",\"unique_id\":\"${DEVICE_ID}_dl_achieved_rate\",\"availability_topic\":\"$AVAIL_TOPIC\",\"device\":{\"identifiers\":[\"$DEVICE_ID\"],\"name\":\"$DEVICE_NAME\"}}"

    publish_config "$DEVICE_ID" "ul_achieved_rate_kbps" \
    "{\"name\":\"UL Achieved Rate\",\"state_topic\":\"$MQTT_TOPIC\",\"value_template\":\"{{ value_json.ul_achieved_rate_kbps }}\",\"unit_of_measurement\":\"kbps\",\"unique_id\":\"${DEVICE_ID}_ul_achieved_rate\",\"availability_topic\":\"$AVAIL_TOPIC\",\"device\":{\"identifiers\":[\"$DEVICE_ID\"],\"name\":\"$DEVICE_NAME\"}}"

    publish_config "$DEVICE_ID" "cake_dl_rate_kbps" \
    "{\"name\":\"CAKE DL Rate\",\"state_topic\":\"$MQTT_TOPIC\",\"value_template\":\"{{ value_json.cake_dl_rate_kbps }}\",\"unit_of_measurement\":\"kbps\",\"unique_id\":\"${DEVICE_ID}_cake_dl_rate\",\"availability_topic\":\"$AVAIL_TOPIC\",\"device\":{\"identifiers\":[\"$DEVICE_ID\"],\"name\":\"$DEVICE_NAME\"}}"

    publish_config "$DEVICE_ID" "cake_ul_rate_kbps" \
    "{\"name\":\"CAKE UL Rate\",\"state_topic\":\"$MQTT_TOPIC\",\"value_template\":\"{{ value_json.cake_ul_rate_kbps }}\",\"unit_of_measurement\":\"kbps\",\"unique_id\":\"${DEVICE_ID}_cake_ul_rate\",\"availability_topic\":\"$AVAIL_TOPIC\",\"device\":{\"identifiers\":[\"$DEVICE_ID\"],\"name\":\"$DEVICE_NAME\"}}"

    publish_config "$DEVICE_ID" "dl_sum_delays" \
    "{\"name\":\"DL Delay Sum\",\"state_topic\":\"$MQTT_TOPIC\",\"value_template\":\"{{ value_json.dl_sum_delays }}\",\"unit_of_measurement\":\"us\",\"unique_id\":\"${DEVICE_ID}_dl_delay\",\"availability_topic\":\"$AVAIL_TOPIC\",\"device\":{\"identifiers\":[\"$DEVICE_ID\"],\"name\":\"$DEVICE_NAME\"}}"

    publish_config "$DEVICE_ID" "ul_sum_delays" \
    "{\"name\":\"UL Delay Sum\",\"state_topic\":\"$MQTT_TOPIC\",\"value_template\":\"{{ value_json.ul_sum_delays }}\",\"unit_of_measurement\":\"us\",\"unique_id\":\"${DEVICE_ID}_ul_delay\",\"availability_topic\":\"$AVAIL_TOPIC\",\"device\":{\"identifiers\":[\"$DEVICE_ID\"],\"name\":\"$DEVICE_NAME\"}}"

    publish_config "$DEVICE_ID" "dl_avg_owd_delta_us" \
    "{\"name\":\"DL OWD Delta\",\"state_topic\":\"$MQTT_TOPIC\",\"value_template\":\"{{ value_json.dl_avg_owd_delta_us }}\",\"unit_of_measurement\":\"us\",\"unique_id\":\"${DEVICE_ID}_dl_owd\",\"availability_topic\":\"$AVAIL_TOPIC\",\"device\":{\"identifiers\":[\"$DEVICE_ID\"],\"name\":\"$DEVICE_NAME\"}}"

    publish_config "$DEVICE_ID" "ul_avg_owd_delta_us" \
    "{\"name\":\"UL OWD Delta\",\"state_topic\":\"$MQTT_TOPIC\",\"value_template\":\"{{ value_json.ul_avg_owd_delta_us }}\",\"unit_of_measurement\":\"us\",\"unique_id\":\"${DEVICE_ID}_ul_owd\",\"availability_topic\":\"$AVAIL_TOPIC\",\"device\":{\"identifiers\":[\"$DEVICE_ID\"],\"name\":\"$DEVICE_NAME\"}}"

    publish_config "$DEVICE_ID" "dl_load_condition" \
    "{\"name\":\"DL Load Condition\",\"state_topic\":\"$MQTT_TOPIC\",\"value_template\":\"{{ value_json.dl_load_condition }}\",\"unique_id\":\"${DEVICE_ID}_dl_condition\",\"availability_topic\":\"$AVAIL_TOPIC\",\"device\":{\"identifiers\":[\"$DEVICE_ID\"],\"name\":\"$DEVICE_NAME\"}}"

    publish_config "$DEVICE_ID" "ul_load_condition" \
    "{\"name\":\"UL Load Condition\",\"state_topic\":\"$MQTT_TOPIC\",\"value_template\":\"{{ value_json.ul_load_condition }}\",\"unique_id\":\"${DEVICE_ID}_ul_condition\",\"availability_topic\":\"$AVAIL_TOPIC\",\"device\":{\"identifiers\":[\"$DEVICE_ID\"],\"name\":\"$DEVICE_NAME\"}}"

    publish_config "$DEVICE_ID" "cpu_total" \
    "{\"name\":\"CPU Total\",\"state_topic\":\"$MQTT_TOPIC\",\"value_template\":\"{{ value_json.cpu_total }}\",\"unit_of_measurement\":\"%\",\"unique_id\":\"${DEVICE_ID}_cpu_total\",\"availability_topic\":\"$AVAIL_TOPIC\",\"device\":{\"identifiers\":[\"$DEVICE_ID\"],\"name\":\"$DEVICE_NAME\"}}"

    for c in $(seq 0 $((CPU_CORES - 1))); do
        publish_config "$DEVICE_ID" "cpu_core$c" \
        "{\"name\":\"CPU Core $c\",\"state_topic\":\"$MQTT_TOPIC\",\"value_template\":\"{{ value_json.cpu_core$c }}\",\"unit_of_measurement\":\"%\",\"unique_id\":\"${DEVICE_ID}_cpu_core$c\",\"availability_topic\":\"$AVAIL_TOPIC\",\"device\":{\"identifiers\":[\"$DEVICE_ID\"],\"name\":\"$DEVICE_NAME\"}}"
    done
}

publish_stats() 
{
    local log_file_path="${1}"

    local instance="$(basename "${log_file_path}" | sed -E 's/^cake-autorate\.([^.]+)\.log$/\1/')"

    local MQTT_TOPIC="${BASE_MQTT_TOPIC}/${instance}"
    local AVAIL_TOPIC="${BASE_MQTT_TOPIC}/${instance}/availability"

    publish_discovery "${instance}"

    while true; do
        # Publish birth message (retained) to mark sensors as available
        # on initial connect and after any reconnect.
        mosquitto_pub \
            -h "$MQTT_HOST" -p "$MQTT_PORT" \
            -u "$MQTT_USER" -P "$MQTT_PASS" \
            -r -q 1 \
            -t "$AVAIL_TOPIC" \
            -m "online"

        tail -F "${log_file_path}" 2>/dev/null | \
        awk -F'; ' -v min_int="$MIN_INTERVAL_S" '
        BEGIN {
            last_emit = 0
            # Accumulators for mean-averaged fields
            s_dl_rate = s_ul_rate = 0
            s_dl_delays = s_ul_delays = 0
            s_dl_owd = s_ul_owd = 0
            s_cpu_total = s_cpu_c0 = s_cpu_c1 = 0
            sn = cn = 0
            # Latest-wins fields (categorical / discrete)
            dl_load = ul_load = "unknown"
            cake_dl = cake_ul = 0
            # Carry-forward for CPU (only ~1Hz vs ~20Hz SUMMARY)
            prev_cpu_total = prev_cpu_c0 = prev_cpu_c1 = 0
            summary_epoch = cpu_epoch = 0
        }

        $1=="SUMMARY" && NF>=13 {
            summary_epoch = $3+0
            s_dl_rate  += $4+0
            s_ul_rate  += $5+0
            s_dl_delays += $6+0
            s_ul_delays += $7+0
            s_dl_owd   += $8+0
            s_ul_owd   += $9+0
            dl_load  = $10
            ul_load  = $11
            cake_dl  = $12+0
            cake_ul  = $13+0
            sn++
        }

        $1=="CPU" && NF>=7 {
            cpu_epoch = $3+0
            s_cpu_total += $5+0
            s_cpu_c0   += $6+0
            s_cpu_c1   += $7+0
            cn++
        }

        {
            event_epoch = (summary_epoch > cpu_epoch) ? summary_epoch : cpu_epoch
            if (event_epoch > 0 && event_epoch - last_emit >= min_int) {
                last_emit = event_epoch
                # Compute means; guard div-by-zero
                sd = (sn > 0) ? sn : 1
                # CPU: use new mean if available, else carry forward
                if (cn > 0) {
                    prev_cpu_total = s_cpu_total / cn
                    prev_cpu_c0 = s_cpu_c0 / cn
                    prev_cpu_c1 = s_cpu_c1 / cn
                }
                printf "{\"event_epoch\":%.6f,\"dl_achieved_rate_kbps\":%.1f,\"ul_achieved_rate_kbps\":%.1f,\"dl_sum_delays\":%.1f,\"ul_sum_delays\":%.1f,\"dl_avg_owd_delta_us\":%.1f,\"ul_avg_owd_delta_us\":%.1f,\"dl_load_condition\":\"%s\",\"ul_load_condition\":\"%s\",\"cake_dl_rate_kbps\":%.0f,\"cake_ul_rate_kbps\":%.0f,\"cpu_total\":%.1f,\"cpu_core0\":%.1f,\"cpu_core1\":%.1f,\"samples\":%d}\n",
                    event_epoch,
                    s_dl_rate / sd, s_ul_rate / sd,
                    s_dl_delays / sd, s_ul_delays / sd,
                    s_dl_owd / sd, s_ul_owd / sd,
                    dl_load, ul_load,
                    cake_dl, cake_ul,
                    prev_cpu_total, prev_cpu_c0, prev_cpu_c1,
                    sn
                # Reset accumulators
                s_dl_rate = s_ul_rate = 0
                s_dl_delays = s_ul_delays = 0
                s_dl_owd = s_ul_owd = 0
                s_cpu_total = s_cpu_c0 = s_cpu_c1 = 0
                sn = cn = 0
                fflush("")
            }
        }
        ' | mosquitto_pub \
            -h "$MQTT_HOST" -p "$MQTT_PORT" \
            -u "$MQTT_USER" -P "$MQTT_PASS" \
            -t "$MQTT_TOPIC" -l -q 1 \
            --will-topic "$AVAIL_TOPIC" \
            --will-payload "offline" \
            --will-qos 1 \
            --will-retain

        sleep 5
    done
}

trap cleanup INT TERM EXIT

publish_stats_pids=()

shopt -s nullglob
for log_file_path in /var/log/cake-autorate.*.log; do
    ( publish_stats "$log_file_path" ) &
    publish_stats_pids+=($!)
done
shopt -u nullglob

wait
