#!/usr/bin/env bash
# shellcheck disable=SC2155

CPU_CORES=$(grep -c '^processor' /proc/cpuinfo) || { echo "ERROR: failed to detect CPU core count from /proc/cpuinfo" >&2; exit 1; }

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
    local log_file_path log_dir
    shopt -s nullglob
    for log_dir in "${log_dirs[@]}"; do
        for log_file_path in "${log_dir}"/cake-autorate.*.log; do
            local instance="$(basename "${log_file_path}" | sed -E 's/^cake-autorate\.([^.]+)\.log$/\1/')"
            mosquitto_pub \
                -h "$MQTT_HOST" -p "$MQTT_PORT" \
                -u "$MQTT_USER" -P "$MQTT_PASS" \
                -r -q 1 \
                -t "${BASE_MQTT_TOPIC}/${instance}/availability" \
                -m "offline" 2>/dev/null || true
        done
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
        awk -F'; ' -v min_int="$MIN_INTERVAL_S" -v default_cores="$CPU_CORES" '
        BEGIN {
            last_emit = 0
            # Accumulators for mean-averaged fields
            s_dl_rate = s_ul_rate = 0
            s_dl_delays = s_ul_delays = 0
            s_dl_owd = s_ul_owd = 0
            s_cpu_total = 0
            sn = cn = 0
            # Latest-wins fields (categorical / discrete)
            dl_load = ul_load = "unknown"
            cake_dl = cake_ul = 0
            # Carry-forward for CPU (only ~1Hz vs ~20Hz SUMMARY)
            prev_cpu_total = 0
            num_cores = default_cores + 0
            for (i = 0; i < num_cores; i++) s_cpu_core[i] = 0
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

        $1=="CPU" && NF>=6 {
            cpu_epoch = $3+0
            s_cpu_total += $5+0
            if (num_cores == 0) num_cores = NF - 5
            for (i = 0; i < num_cores; i++)
                s_cpu_core[i] += $(6+i)+0
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
                    for (i = 0; i < num_cores; i++)
                        prev_cpu_core[i] = s_cpu_core[i] / cn
                }
                cpu_json = ""
                for (i = 0; i < num_cores; i++)
                    cpu_json = cpu_json sprintf(",\"cpu_core%d\":%.1f", i, prev_cpu_core[i])
                printf "{\"event_epoch\":%.6f,\"dl_achieved_rate_kbps\":%.1f,\"ul_achieved_rate_kbps\":%.1f,\"dl_sum_delays\":%.1f,\"ul_sum_delays\":%.1f,\"dl_avg_owd_delta_us\":%.1f,\"ul_avg_owd_delta_us\":%.1f,\"dl_load_condition\":\"%s\",\"ul_load_condition\":\"%s\",\"cake_dl_rate_kbps\":%.0f,\"cake_ul_rate_kbps\":%.0f,\"cpu_total\":%.1f%s,\"samples\":%d}\n",
                    event_epoch,
                    s_dl_rate / sd, s_ul_rate / sd,
                    s_dl_delays / sd, s_ul_delays / sd,
                    s_dl_owd / sd, s_ul_owd / sd,
                    dl_load, ul_load,
                    cake_dl, cake_ul,
                    prev_cpu_total, cpu_json,
                    sn
                # Reset accumulators
                s_dl_rate = s_ul_rate = 0
                s_dl_delays = s_ul_delays = 0
                s_dl_owd = s_ul_owd = 0
                s_cpu_total = 0
                for (i = 0; i < num_cores; i++) s_cpu_core[i] = 0
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

# Discover where cake-autorate writes its logs, and sanity-check the config.
#
# cake-autorate honours log_file_path_override per instance, so globbing only
# /var/log misses a relocated log and the publisher then silently does nothing.
# Resolve the log dir(s) the same way cake-autorate does, from the configs next
# to this script. The init.d launches ${SCRIPT_PREFIX}/mqtt-publisher.sh, so the
# script's own directory is SCRIPT_PREFIX; CONFIG_PREFIX equals it unless the
# install used a custom CAKE_AUTORATE_CONFIG_PREFIX (or Asuswrt-Merlin), whose
# configs are then not auto-discovered (we fall back to /var/log + the warning).
SCRIPT_PREFIX="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
CONFIG_PREFIX="${SCRIPT_PREFIX}"

declare -A seen_log_dir=()
log_dirs=()
any_stats_enabled=0
shopt -s nullglob
for config_path in "${CONFIG_PREFIX}"/config.*.sh; do
    [[ -r ${config_path} ]] || continue
    # Source defaults then this instance's config in a subshell (defaults first,
    # then the override, matching cake-autorate) and read only the keys we need.
    mapfile -t cfg_vals < <(
        unset log_file_path_override output_summary_stats output_cpu_stats
        # shellcheck source=defaults.sh
        [[ -r ${SCRIPT_PREFIX}/defaults.sh ]] && . "${SCRIPT_PREFIX}/defaults.sh" 2>/dev/null
        # shellcheck source=config.primary.sh
        . "${config_path}" 2>/dev/null
        printf '%s\n' "${log_file_path_override:-}" "${output_summary_stats:-0}" "${output_cpu_stats:-0}"
    )
    if [[ -n ${cfg_vals[0]} && -d ${cfg_vals[0]} ]]; then
        log_dir="${cfg_vals[0]}"
    else
        log_dir="/var/log"
    fi
    [[ -n ${seen_log_dir[${log_dir}]:-} ]] || { seen_log_dir[${log_dir}]=1; log_dirs+=("${log_dir}"); }
    [[ ${cfg_vals[1]} == 1 || ${cfg_vals[2]} == 1 ]] && any_stats_enabled=1
done
shopt -u nullglob
# Fall back to the historical default if discovery turned up nothing.
(( ${#log_dirs[@]} )) || log_dirs=("/var/log")

if (( ! any_stats_enabled )); then
    echo "WARNING: no cake-autorate config enables output_summary_stats=1 or output_cpu_stats=1 -- the Home Assistant sensors will be created via discovery but stay empty, because the SUMMARY/CPU log records the publisher reads are never produced. Enable output_summary_stats=1 (and/or output_cpu_stats=1) in the relevant config." >&2
fi

trap cleanup INT TERM EXIT

publish_stats_pids=()

shopt -s nullglob
for log_dir in "${log_dirs[@]}"; do
    for log_file_path in "${log_dir}"/cake-autorate.*.log; do
        ( publish_stats "$log_file_path" ) &
        publish_stats_pids+=($!)
    done
done
shopt -u nullglob

if (( ${#publish_stats_pids[@]} == 0 )); then
    echo "WARNING: no cake-autorate logs found (looked in: ${log_dirs[*]} for cake-autorate.*.log). Nothing to publish -- is cake-autorate running with logging enabled? If logs are relocated via log_file_path_override, ensure the instance config is readable next to this script so the path can be discovered." >&2
fi

wait
