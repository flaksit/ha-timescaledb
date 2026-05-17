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
#
# Why pass notification_id:
#   - Without notification_id, persistent_notification.create produces a transient
#     notification that appears in the UI bell but is NOT exposed as a
#     state-tracked entity. That makes notifications unqueryable via /api/states
#     and unautomatable (no entity to trigger off, no automation to surface, no
#     way to write Lovelace cards or generate dashboards).
#   - With notification_id, HA creates persistent_notification.<id> as a real
#     entity that survives restarts and is dedupable: re-firing with the same
#     id replaces the existing notification rather than spawning a new one. That
#     prevents a flapping repo from filling the UI with a hundred copies of the
#     same alert; the operator sees one current notification per condition.
#   - All callers SHOULD pass a stable kebab-case slug that identifies the
#     condition (not the timestamp / not the message body) so a recurring
#     failure overwrites its predecessor.
#
# Usage: notify_supervisor <title> <message> [notification_id]
notify_supervisor() {
    local title="$1"
    local message="$2"
    local notification_id="${3:-}"

    if [ -z "${SUPERVISOR_TOKEN:-}" ]; then
        bashio::log.warning "pgBackRest: ${title} (SUPERVISOR_TOKEN unavailable — notification not sent)"
        return 0
    fi

    local payload
    if [ -n "${notification_id}" ]; then
        payload=$(jq -nc --arg title "${title}" --arg message "${message}" --arg nid "${notification_id}" \
            '{title: $title, message: $message, notification_id: $nid}')
    else
        payload=$(jq -nc --arg title "${title}" --arg message "${message}" \
            '{title: $title, message: $message}')
    fi

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
# Non-transient errors must not be retried — they require manual intervention
# (wrong key, cipher mismatch, revoked SSH access). Transient errors (network
# timeouts, temporary DNS failures, SFTP subsystem hiccups) are safe to retry.
#
# Default policy (when no explicit classification matches): TRANSIENT.
# Rationale: every classifier path lands in the same retry loop with a bounded
# number of attempts and persistent_notification on exhaustion. The downside of
# misclassifying a truly unfixable error as transient is ~33 minutes of wasted
# retries before the same notification fires — operator gets the same eventual
# signal. The downside of misclassifying a genuinely transient failure as
# non-transient is immediate give-up and a lost backup window — strictly worse
# (data exposure vs. delayed notification). Both stanza-create retry (3-attempt)
# and pgbackrest-cron retry (6-attempt) share this classifier; the flip applies
# to both. Concrete failure mode that motivated this default: Hetzner sub-account
# external-reach disabled produces stderr "unable to init libssh2_sftp session"
# which matched no pattern and was treated as non-transient by the previous
# safety default — the same message can also fire on genuinely transient SFTP
# subsystem resets, where give-up-immediately is the wrong call.
#
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
        # Only consider pgbackrest's ERROR/WARN/HINT-prefixed lines for
        # classification. pgbackrest's "backup command begin" INFO line echoes
        # the full command line including option NAMES like --repo1-cipher-pass
        # and --repo1-cipher-type; matching the non-transient regex against
        # those names would tag every failure (even transient SFTP hiccups) as
        # non-transient because "cipher" appears in the option names. The real
        # error context lives in the ERROR (and occasionally WARN/HINT) lines
        # that come after, where regex matches actually identify the failure
        # mode. Pattern matches pgbackrest's log prefix
        #   "YYYY-MM-DD HH:MM:SS.SSS PNN  ERROR/WARN/HINT: ..."
        stderr_content=$(grep -E ' P[0-9]+ +(ERROR|WARN|HINT)' "${stderr_file}" 2>/dev/null \
            | tail -c 4096 || true)
    fi

    # Explicit non-transient patterns: auth / key / cipher problems that clearly
    # require an operator to fix configuration or credentials. Retrying these
    # only delays the inevitable notification by ~33 minutes.
    if echo "${stderr_content}" | grep -qiE 'authentication|denied|permission|unknown key|not found in known_hosts|host key verification|invalid private key|cipher'; then
        echo "non-transient"
    else
        # Everything else: assume transient and let the retry loop work. If the
        # error is in fact permanent, the loop exhausts after the usual backoff
        # and notify_backup_failure fires with the captured stderr tail.
        echo "transient"
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
    local _key="${SECRETS_DIR}/pgbackrest_id_ed25519_repo${_rk}"

    [ -f "${_key}" ] || { echo ""; return 0; }

    # Read host and user from pgbackrest.conf — sub-account numbers don't match repo keys
    # (e.g. repo1 → sub4, repo2 → sub5) so constructing from _rk would use wrong hosts.
    local _host _user
    _host=$(grep -m1 "^repo${_rk}-sftp-host=" /etc/pgbackrest/pgbackrest.conf 2>/dev/null | cut -d= -f2)
    _user=$(grep -m1 "^repo${_rk}-sftp-host-user=" /etc/pgbackrest/pgbackrest.conf 2>/dev/null | cut -d= -f2)

    [ -n "${_host}" ] || { echo ""; return 0; }

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
# Stable notification_id per repo so flapping failures dedupe in the HA UI
# (one current notification per repo, not one per retry exhaustion).
# Usage: notify_backup_failure <repo_id> <operation> <stderr_tail>
notify_backup_failure() {
    local repo_id="$1"
    local operation="$2"
    local stderr_tail="$3"

    notify_supervisor \
        "pgBackRest ${repo_id} backup failed" \
        "${operation} failed after all retry attempts. Last error: ${stderr_tail}. Check the app log for full output." \
        "pgbackrest-backup-${repo_id}-failed"
}

# -----------------------------------------------------------------------------
# Dual-archive window helpers — used around the yearly repo2 backup so WAL
# fans briefly to both repos. Without this window, the repo2 backup is not
# self-contained (archive-copy=y can only embed WAL from the SAME repo's
# archive, and repo2 has no continuous WAL stream by design — D-22a).
# See plans/1-not-good-doesn-t-wondrous-robin.md for the architectural context.
# -----------------------------------------------------------------------------

ARCHIVE_CONF=/etc/pgbackrest/pgbackrest-archive.conf
ARCHIVE_CONF_DUAL=/etc/pgbackrest/pgbackrest-archive-dual.conf
ARCHIVE_CONF_BACKUP="${ARCHIVE_CONF}.repo1only.bak"

# Swap the dual-repo archive config into place atomically.
#
# WHY atomic via cp-then-mv: PG's archive_command opens the file fresh on
# every WAL segment push. A partially-written conf during a naive cp would
# cause that archive-push to fail. cp to a sibling path on the same fs, then
# mv (atomic rename) replaces the file in a single inode flip.
#
# Stashes the previous content at ARCHIVE_CONF_BACKUP so disable_dual_archive
# can restore it without re-rendering. Returns 0 on success, non-zero on any
# step's failure (caller should NOT proceed to backup if this fails).
enable_dual_archive() {
    if [ ! -f "${ARCHIVE_CONF_DUAL}" ]; then
        bashio::log.error "enable_dual_archive: ${ARCHIVE_CONF_DUAL} missing — init-db.sh render must have failed"
        return 1
    fi

    # Capture the current repo1-only conf so disable_dual_archive can restore it.
    if ! cp -p "${ARCHIVE_CONF}" "${ARCHIVE_CONF_BACKUP}"; then
        bashio::log.error "enable_dual_archive: cp ${ARCHIVE_CONF} -> ${ARCHIVE_CONF_BACKUP} failed"
        return 1
    fi

    # Stage the dual conf next to the live path, then mv-rename for atomicity.
    local _staged="${ARCHIVE_CONF}.dual.staged"
    if ! cp -p "${ARCHIVE_CONF_DUAL}" "${_staged}"; then
        bashio::log.error "enable_dual_archive: cp ${ARCHIVE_CONF_DUAL} -> ${_staged} failed"
        rm -f "${ARCHIVE_CONF_BACKUP}"
        return 1
    fi
    if ! mv "${_staged}" "${ARCHIVE_CONF}"; then
        bashio::log.error "enable_dual_archive: mv ${_staged} -> ${ARCHIVE_CONF} failed"
        rm -f "${_staged}" "${ARCHIVE_CONF_BACKUP}"
        return 1
    fi
    bashio::log.info "enable_dual_archive: archive-push will fan WAL to repo1 + repo2"
    return 0
}

# Restore the repo1-only archive config. Idempotent: safe to call even when
# enable_dual_archive was not called (then the .bak does not exist and this
# is a no-op). Always returns 0 — disable_dual_archive must never fail-out
# of the caller because the caller (the trap) needs to clean up.
disable_dual_archive() {
    if [ ! -f "${ARCHIVE_CONF_BACKUP}" ]; then
        return 0
    fi
    local _staged="${ARCHIVE_CONF}.repo1only.staged"
    if cp -p "${ARCHIVE_CONF_BACKUP}" "${_staged}" \
        && mv "${_staged}" "${ARCHIVE_CONF}"; then
        rm -f "${ARCHIVE_CONF_BACKUP}"
        bashio::log.info "disable_dual_archive: archive-push restored to repo1-only"
    else
        # Best-effort: notify but never propagate failure here.
        bashio::log.error "disable_dual_archive: failed to restore ${ARCHIVE_CONF} — manual fix required"
        notify_supervisor \
            "pgBackRest archive config swap failed" \
            "disable_dual_archive could not restore ${ARCHIVE_CONF} from ${ARCHIVE_CONF_BACKUP}. WAL may continue fanning to repo2. Restart the addon to re-render."
    fi
    return 0
}

# Force PostgreSQL to switch WAL so a new segment is produced and archived
# under the current archive_command config. Used right after
# enable_dual_archive to push a fresh segment to both repos.
#
# Echoes the WAL filename returned by pg_switch_wal (so callers can poll for
# its arrival in repo2's archive). Returns 0 on success, 1 on psql failure.
force_wal_switch() {
    local _wal
    _wal=$(psql -h /tmp -U postgres -d postgres -tAc \
        "SELECT pg_walfile_name(pg_switch_wal());" 2>/dev/null \
        | tr -d '[:space:]')
    if [ -z "${_wal}" ]; then
        bashio::log.error "force_wal_switch: psql pg_switch_wal returned empty"
        return 1
    fi
    bashio::log.info "force_wal_switch: pg_switch_wal returned ${_wal}"
    printf '%s\n' "${_wal}"
    return 0
}

# Block until the named WAL segment shows up in repo2's archive, or timeout.
# repo2 has no continuous archive — this is the only way to confirm the
# brief dual-archive window actually shipped a segment before launching the
# backup command (whose archive-check otherwise blocks for a long timeout).
#
# Usage: wait_for_wal_in_repo2 <wal_name> [timeout_seconds]
# Returns 0 once present, 1 on timeout, 2 on pgbackrest invocation failure.
wait_for_wal_in_repo2() {
    local _wal="$1"
    local _timeout="${2:-120}"
    local _deadline=$(( $(date +%s) + _timeout ))
    local _info

    bashio::log.info "wait_for_wal_in_repo2: polling for ${_wal} (timeout ${_timeout}s)"
    while [ "$(date +%s)" -lt "${_deadline}" ]; do
        _info=$(env \
            "PGBACKREST_REPO1_CIPHER_PASS=$(cat "${SECRETS_DIR}/pgbackrest_cipher_pass_repo1" 2>/dev/null)" \
            "PGBACKREST_REPO2_CIPHER_PASS=$(cat "${SECRETS_DIR}/pgbackrest_cipher_pass_repo2" 2>/dev/null)" \
            gosu postgres /usr/bin/pgbackrest \
            --stanza=timescaledb --repo=2 info --output=json 2>/dev/null || echo '[]')
        # archive.max is the most recent archived WAL filename for the current
        # db version. Once it equals or exceeds the segment we forced, the
        # segment has landed.
        local _max
        _max=$(printf '%s' "${_info}" | jq -r \
            '.[0].archive | map(.max) | last // empty' 2>/dev/null || true)
        if [ -n "${_max}" ] && [ "${_max}" \> "${_wal}" -o "${_max}" = "${_wal}" ]; then
            bashio::log.info "wait_for_wal_in_repo2: ${_wal} present (max=${_max})"
            return 0
        fi
        sleep 5
    done
    bashio::log.error "wait_for_wal_in_repo2: timed out after ${_timeout}s waiting for ${_wal}"
    return 1
}

# Delete residual WAL segments left in repo2's archive after a yearly backup.
# Once archive-copy=y embedded the consistency-window segments inside the
# backup directory, the archive copies are redundant. pgbackrest expire does
# not prune them (no retention rule covers a non-continuous archive — see
# plans/1-not-good-doesn-t-wondrous-robin.md for the analysis). Use direct
# repo2 SFTP rm.
#
# Best-effort: failures here do not invalidate the backup. Log + continue.
post_yearly_archive_cleanup() {
    local _host _port _user _path
    _host=$(bashio::config 'repo2_sftp_host')
    _port=$(bashio::config 'repo2_sftp_port')
    _user=$(bashio::config 'repo2_sftp_user')
    _path=$(bashio::config 'repo2_sftp_path')
    if [ -z "${_host}" ] || [ -z "${_user}" ]; then
        bashio::log.warning "post_yearly_archive_cleanup: repo2 sftp config missing — skipping"
        return 0
    fi
    # Remove trailing slash from configured path; the script appends explicit paths.
    _path="${_path%/}"
    if [ -z "${_path}" ]; then
        _path=""  # path '/' means chroot root — leave empty so 'rm /archive/...' is clean
    fi

    bashio::log.info "post_yearly_archive_cleanup: removing residual WAL from repo2 archive"
    # Archive layout on the SFTP root (verified by direct ls):
    #   /archive/timescaledb/archive.info        ← MUST keep (pgbackrest metadata)
    #   /archive/timescaledb/archive.info.copy   ← MUST keep
    #   /archive/timescaledb/<pg-ver>/<prefix>/<wal-segment>.gz   ← delete these
    #   /archive/timescaledb/<pg-ver>/                            ← keep dir
    #   /archive/timescaledb/<pg-ver>/<prefix>/                   ← may rmdir if empty
    #
    # WAL segment files all start with '0' (hex). Glob '0*' inside the prefix
    # subdir avoids touching archive.info or the metadata at the timescaledb/ level.
    # -b - reads sftp commands from stdin; leading '-' on each command means
    # "continue on error" (the dir may already be empty from a prior run).
    sftp \
        -o "StrictHostKeyChecking=yes" \
        -o "UserKnownHostsFile=${SECRETS_DIR}/pgbackrest_known_hosts_repo2" \
        -i "${SECRETS_DIR}/pgbackrest_id_ed25519_repo2" \
        -P "${_port}" \
        -b - \
        "${_user}@${_host}" <<'SFTP_EOF' >/dev/null 2>&1 || true
-rm /archive/timescaledb/*/*/0*
-rmdir /archive/timescaledb/*/*
SFTP_EOF
    bashio::log.info "post_yearly_archive_cleanup: done (best-effort)"
    return 0
}
