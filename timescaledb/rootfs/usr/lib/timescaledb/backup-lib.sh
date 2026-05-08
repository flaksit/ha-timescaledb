# Shared backup helper library for ha-timescaledb.
#
# Sourced by:
#   - rootfs/usr/share/timescaledb/init-db.sh  (oneshot init)
#   - rootfs/etc/s6-overlay/s6-rc.d/pgbackrest-cron/run  (Phase 9 cron wrapper)
#
# NO SHEBANG LINE — this file is dot-sourced by scripts that already have
# #!/command/with-contenv bashio as their shebang. A shebang here would be
# treated as a comment, but is omitted to clearly signal "do not execute directly".
# bashio::log.* and SUPERVISOR_TOKEN are available because callers run under
# #!/command/with-contenv bashio.

# Send a persistent notification to Home Assistant via the supervisor API.
# Requires SUPERVISOR_TOKEN env var (auto-provided by HAOS to apps).
# Non-fatal: on any failure (missing token, network error) logs a warning and returns 0.
# Usage: notify_supervisor <title> <message>
notify_supervisor() {
    local title="$1"
    local message="$2"

    if [ -z "${SUPERVISOR_TOKEN:-}" ]; then
        bashio::log.warning "pgBackRest: ${title} (SUPERVISOR_TOKEN unavailable — notification not sent)"
        return 0
    fi

    local payload
    payload=$(jq -nc --arg title "${title}" --arg message "${message}" '{title: $title, message: $message}')

    # SUPERVISOR_TOKEN goes in the Authorization header only — NEVER in URL or log output
    if ! curl -fsS --max-time 10 \
        -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -d "${payload}" \
        http://supervisor/core/api/services/persistent_notification/create 2>/dev/null; then
        bashio::log.warning "pgBackRest: failed to send notification '${title}' via supervisor API"
    fi
    return 0
}

# Classify a pgbackrest exit code + stderr as "transient" or "non-transient".
# Non-transient errors must not be retried — they require manual intervention (wrong key, cipher mismatch).
# Transient errors (network timeouts, temporary DNS failures) are safe to retry.
# Defaults to "non-transient" when the error cannot be classified — safety-first.
# Usage: classify_pgbackrest_error <exit_code> [stderr_file]
# Output: echoes "transient" or "non-transient"
classify_pgbackrest_error() {
    local exit_code="$1"
    local stderr_file="${2:-}"
    local stderr_content=""

    # Exit codes that are always non-transient regardless of stderr:
    #   31 = crypto/cipher error (wrong passphrase, incompatible encryption)
    #   102 = stanza mismatch (existing stanza has different configuration)
    case "${exit_code}" in
        31|102) echo "non-transient"; return ;;
    esac

    if [ -f "${stderr_file}" ]; then
        stderr_content=$(tail -c 4096 "${stderr_file}" 2>/dev/null || true)
    fi

    # Non-transient patterns: auth/permission failures, known_hosts mismatches, key problems
    if echo "${stderr_content}" | grep -qiE 'authentication|denied|permission|unknown key|not found in known_hosts|host key verification|invalid private key|cipher'; then
        echo "non-transient"
    # Transient patterns: network connectivity / temporary infrastructure problems
    elif echo "${stderr_content}" | grep -qiE 'timeout|timed out|Connection reset|Connection refused|Temporary failure|could not resolve|network is unreachable|EOF from client'; then
        echo "transient"
    else
        # Unrecognized exit code with no pattern match — default to non-transient for safety
        echo "non-transient"
    fi
}

# Update an HA sensor via MQTT discovery. Non-fatal: if SUPERVISOR_TOKEN is absent or any
# curl call fails, logs a named warning and returns 0 — the backup result is never lost due
# to a reporting failure (D-04).
#
# WHY MQTT not the HA REST states endpoint: the REST endpoint creates runtime-only state
# that disappears after HA restart. MQTT retained messages are stored in the Mosquitto
# broker and replayed when HA reconnects — entities show as 'unavailable' (not missing)
# after restart and recover to their last value without waiting for the next backup.
#
# Publishes three retained messages: discovery config (entity registration), state, attributes.
# Get actual on-disk storage used by a pgBackRest repo on the Hetzner storage box.
# Uses SSH port 23 (shell access) + `du -sb .` in the chroot home directory.
# Falls back to empty string on failure (caller decides what to publish instead).
#
# WHY SSH not pgbackrest info: pgbackrest .info.size = uncompressed logical DB size,
# .info.repository.size = single backup's compressed footprint. Neither gives the true
# total folder size across all retained backups + WAL archives. `du -sb .` on the
# storage box is the only accurate source.
# WHY port 23 not 22: port 22 is SFTP only; port 23 provides shell access with du.
# WHY du -sb .: storage box chroots the user to their home dir — '/' is inaccessible,
# '.' is the backup root which contains the full pgbackrest stanza.
#
# Usage: repo_du <repo_key_int>   (1 or 2)
# Returns: byte count as string, or "" on failure
repo_du() {
    local _rk="$1"
    local _host="u404673-sub${_rk}.your-storagebox.de"
    local _user="u404673-sub${_rk}"
    local _key="${SECRETS_DIR}/pgbackrest_id_ed25519_repo${_rk}"

    [ -f "${_key}" ] || { echo ""; return 0; }

    # 2>&1 required: OpenSSH 10+ routes du output to stderr on Hetzner's restricted shell.
    # grep filters to the byte-count line, discarding post-quantum warnings and other noise.
    ssh -i "${_key}" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 \
        -p 23 \
        "${_user}@${_host}" \
        'du -sb .' 2>&1 | grep -E '^[0-9]' | awk '{print $1}' || echo ""
}

# Discovery config is idempotent — republishing with the same unique_id is safe.
#
# Usage: update_ha_sensor <entity_id> <state> [attr_json]
#   entity_id: full HA entity_id, e.g. sensor.timescaledb_last_backup_repo1
#   state:     state string (ISO timestamp or byte count as string)
#   attr_json: optional JSON object string; defaults to {} when not provided
update_ha_sensor() {
    local entity_id="$1"
    local state="$2"
    local attr_json="${3:-{}}"

    # Strip sensor. prefix to get the id used for topic routing, unique_id, and object_id.
    local _oid
    _oid="${entity_id#sensor.}"

    # Sensor metadata varies by type. Timestamp sensors get device_class=timestamp.
    # Size sensors get device_class=data_size + unit_of_measurement=B + state_class=measurement
    # so HA registers the unit and auto-scales display. Without these in the discovery config
    # payload, HA ignores unit/class sent via the attributes topic.
    local _device_class _unit _state_class
    case "${_oid}" in
        timescaledb_backup_last_backup_*)
            _device_class="timestamp" ; _unit="" ; _state_class="" ;;
        timescaledb_backup_*_size)
            _device_class="data_size" ; _unit="B" ; _state_class="measurement" ;;
        *) _device_class="" ; _unit="" ; _state_class="" ;;
    esac

    if [ -z "${SUPERVISOR_TOKEN:-}" ]; then
        bashio::log.warning "update_ha_sensor: SUPERVISOR_TOKEN unavailable — sensor '${entity_id}' not updated (backup succeeded)"
        return 0
    fi

    # Human-readable name: underscores → spaces, strip device prefix for UI display.
    local _name
    _name=$(printf '%s' "${_oid#timescaledb_backup_}" | tr '_' ' ')

    # HA entity_id = {device_slug}_{object_id} when a device is specified in the payload.
    # device "TimescaleDB Backup" → slug "timescaledb_backup". Using the full _oid as
    # object_id doubles the slug: sensor.timescaledb_backup_timescaledb_backup_last_backup_repo1.
    # Short object_id = _oid with the device slug prefix stripped → HA produces the correct
    # entity_id: sensor.timescaledb_backup_last_backup_repo1.
    local _short_oid="${_oid#timescaledb_backup_}"

    # Build discovery config. device_class, unit_of_measurement, state_class are conditionally
    # added — only fields present in the payload are registered by HA.
    local _config_json
    _config_json=$(jq -nc \
        --arg nm "${_name}" \
        --arg uid "${_oid}" \
        --arg oid "${_short_oid}" \
        --arg st "homeassistant/sensor/${_oid}/state" \
        --arg at "homeassistant/sensor/${_oid}/attrs" \
        --arg dc "${_device_class}" \
        --arg unit "${_unit}" \
        --arg sc "${_state_class}" \
        '{
          name: $nm,
          object_id: $oid,
          unique_id: $uid,
          state_topic: $st,
          json_attributes_topic: $at,
          device: { identifiers: ["ha_timescaledb_backup"], name: "TimescaleDB Backup" }
        }
        | if $dc   != "" then . + {device_class: $dc}             else . end
        | if $unit != "" then . + {unit_of_measurement: $unit}     else . end
        | if $sc   != "" then . + {state_class: $sc}              else . end')

    # Helper: publish one MQTT message via the supervisor proxy. Uses || true (not if !)
    # so that retain=true is handled as a JSON boolean, not as a shell condition.
    # SUPERVISOR_TOKEN goes in the Authorization header only — NEVER in URL or log output.
    _mqtt_publish() {
        local _topic="$1" _payload="$2" _retain="$3"
        local _pub
        _pub=$(jq -nc --arg t "${_topic}" --arg p "${_payload}" --argjson r "${_retain}" \
            '{topic: $t, payload: $p, retain: $r}')
        curl -fsS --max-time 10 \
            -X POST \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
            -d "${_pub}" \
            http://supervisor/core/api/services/mqtt/publish 2>/dev/null || true
    }

    # Retained discovery config: broker stores this; HA recreates entity on restart.
    # Publish on every backup run — idempotent since unique_id is stable.
    _mqtt_publish "homeassistant/sensor/${_oid}/config" \
        "${_config_json}" true

    # Retained state: broker replays on HA reconnect; entity shows last known value.
    _mqtt_publish "homeassistant/sensor/${_oid}/state" \
        "${state}" true

    # Retained attributes: includes backup_type/duration_seconds or unit_of_measurement.
    # attr_json is passed from run as a JSON object string; publish the raw string as payload.
    _mqtt_publish "homeassistant/sensor/${_oid}/attrs" \
        "${attr_json}" true

    bashio::log.info "update_ha_sensor: published MQTT discovery + state for '${entity_id}'"
    return 0
}

# Send a backup failure notification via notify_supervisor.
# Call after retry exhaustion. repo_id ∈ repo1|repo2.
# Delegates to notify_supervisor — see that function for non-fatal guarantee.
# Usage: notify_backup_failure <repo_id> <operation> <stderr_tail>
notify_backup_failure() {
    local repo_id="$1"
    local operation="$2"
    local stderr_tail="$3"

    notify_supervisor \
        "pgBackRest ${repo_id} backup failed" \
        "${operation} failed after all retry attempts. Last error: ${stderr_tail}. Check the app log for full output."
}
