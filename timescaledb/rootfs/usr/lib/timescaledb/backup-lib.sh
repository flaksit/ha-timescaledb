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

# Update an HA sensor state via supervisor API. Non-fatal: if SUPERVISOR_TOKEN is absent
# or the call fails, logs a specific named warning and returns 0 — the backup result is
# never lost due to a reporting failure (D-04). The named warning distinguishes
# 'token absent' vs 'curl failed' so operators know which condition occurred.
#
# NOTE: /api/states creates runtime state only — not entity-registry backed. Sensor state
# is absent until the next successful backup after an HA restart. This is expected behavior.
#
# Usage: update_ha_sensor <entity_id> <state> [attr_json]
#   attr_json: optional JSON object string; defaults to {} when not provided
update_ha_sensor() {
    local entity_id="$1"
    local state="$2"
    local attr_json="${3:-{}}"

    if [ -z "${SUPERVISOR_TOKEN:-}" ]; then
        bashio::log.warning "update_ha_sensor: SUPERVISOR_TOKEN unavailable — sensor '${entity_id}' not updated (backup succeeded)"
        return 0
    fi

    local payload
    payload=$(jq -nc --arg s "${state}" --argjson a "${attr_json}" '{"state":$s,"attributes":$a}')

    # SUPERVISOR_TOKEN goes in the Authorization header only — NEVER in URL or log output
    if ! curl -fsS --max-time 10 \
        -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -d "${payload}" \
        "http://supervisor/core/api/states/${entity_id}" 2>/dev/null; then
        bashio::log.warning "update_ha_sensor: failed to update sensor '${entity_id}' via supervisor API (HTTP error or timeout)"
    fi
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
