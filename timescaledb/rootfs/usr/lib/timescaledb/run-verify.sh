#!/command/with-contenv bashio
# Single-code-path pgBackRest verify runner (Phase 10 BKUP-15).
#
# Called by:
#   - pgbackrest-cron's dispatch_for_date on Sundays (weekly verify branch — plan 10-03)
#   - Operator's manual retry SSH command from notify_verify_failure body (D-06)
#
# Same code path means manual retry produces the same sensor publish as the cron run.
#
# WHY no retry loop (D-04 fail-fast): verify failures may signal repository corruption;
# silencing one with 5x backoff would only delay the operator's signal. The failure
# notification IS the retry mechanism — the operator runs the same script via SSH.
# WHY combined stdout+stderr redirect (same idiom as run_backup): pgbackrest writes
# its INFO and ERROR lines to stdout via log-level-console=info; a stderr-only redirect
# would yield an empty tail for the failure notification.
# WHY tail -n 5: D-07 schema literally specifies "last 5 lines of stderr", not bytes.
# WHY no --no-pitr flag: pgBackRest 2.58 verify does not accept --no-pitr (that flag is
# restore-only). RESEARCH.md was incorrect on this point. Verify's manifest + archive
# checksum validation does not require any flag to skip WAL coverage on repo2 (which
# has no continuous archive by design — D-22a); verify works against the archive
# directory contents as found.

set -uo pipefail

if [ "$#" -ne 1 ]; then
    bashio::log.error "run-verify.sh: exactly one argument required: repo1 | repo2"
    exit 2
fi

REPO_ID="$1"
case "${REPO_ID}" in
    repo1|repo2) ;;
    *)
        bashio::log.error "run-verify.sh: invalid repo '${REPO_ID}' — expected repo1 or repo2"
        exit 2
        ;;
esac

SECRETS_DIR="/data/secrets"

# shellcheck source=../backup-lib.sh
. /usr/lib/timescaledb/backup-lib.sh

# Strip "repo" prefix to get the integer key pgbackrest --repo= expects (1 or 2).
_repo_key="${REPO_ID##repo}"

_stderr_file=$(mktemp)
_exit_code=0

bashio::log.info "run-verify.sh: ${REPO_ID} verify starting"

# Both cipher passphrases are injected regardless of --repo=N: pgbackrest 2.58 reads
# all configured repo cipher passes when discovering stanza metadata. Matches the
# run_backup invocation pattern verbatim.
env \
    "PGBACKREST_REPO1_CIPHER_PASS=$(cat "${SECRETS_DIR}/pgbackrest_cipher_pass_repo1" 2>/dev/null)" \
    "PGBACKREST_REPO2_CIPHER_PASS=$(cat "${SECRETS_DIR}/pgbackrest_cipher_pass_repo2" 2>/dev/null)" \
    gosu postgres /usr/bin/pgbackrest \
        --stanza=timescaledb \
        "--repo=${_repo_key}" \
        verify \
        >"${_stderr_file}" 2>&1 || _exit_code=$?

# Forward captured output to the addon log so operators see the full pgbackrest
# chatter the same way run_backup forwards it.
cat "${_stderr_file}" || true

if [ "${_exit_code}" -eq 0 ]; then
    _ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    update_ha_verify_sensor "${REPO_ID}" "${_ts}"
    bashio::log.info "verify ${REPO_ID} ok"
    rm -f "${_stderr_file}"
    exit 0
fi

_stderr_tail=$(tail -n 5 "${_stderr_file}" 2>/dev/null || true)
notify_verify_failure "${REPO_ID}" "${_exit_code}" "${_stderr_tail}"
bashio::log.error "verify ${REPO_ID} failed (exit ${_exit_code})"
rm -f "${_stderr_file}"
exit "${_exit_code}"
