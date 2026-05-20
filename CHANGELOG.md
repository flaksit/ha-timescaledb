# Changelog

All notable changes to this addon are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Pre-release suffixes
(`-phaseN.M`) mark in-flight development iterations and are not released to
HACS.

## [1.1.2-phase10.2] — 2026-05-20

Phase 10 (v1.1.x backup hardening) — fix invalid `--no-pitr` flag on
`pgbackrest verify`. The verify command does not accept `--no-pitr` (it is a
restore-only option); `run-verify.sh` exited 31 ("invalid option") on every
invocation, so the two new verify sensors never published their first
discovery payload. Removed the flag; verify against repo1 now completes
successfully in ~4.5 min. Documentation that previously cited
`pgbackrest verify --no-pitr` was updated accordingly.

## [1.1.2-phase10.1] — 2026-05-20

Phase 10 (v1.1.x backup hardening) — initial development iteration.

### Added

- **BKUP-15** — Weekly `pgbackrest verify` on both repos via the
  existing `pgbackrest-cron` longrun. Sunday branch in `dispatch_for_date`
  runs `/usr/lib/timescaledb/run-verify.sh repo1` then `repo2`, sequentially,
  immediately after the daily backup. Fail-fast — non-zero exit fires
  `notify_verify_failure` once (no retry loop); the operator runs the same
  script via SSH to retry.
- **BKUP-16** — Quarterly HA notification (Jan/Apr/Jul/Oct 1). Unconditional
  branch in `dispatch_for_date` calls `notify_quarterly_drill_due` which
  fires both `notify.notify` (mobile push) and `persistent_notification.create`
  (sticky HA UI). Message body links to the canonical playbook at
  [`scripts/verify-restore/QUARTERLY-DRILL.md`](./scripts/verify-restore/QUARTERLY-DRILL.md).
- Two new HA sensors: `sensor.timescaledb_backup_last_verify_repo1` and
  `sensor.timescaledb_backup_last_verify_repo2` (success-only ISO-8601
  timestamps; `device_class=timestamp`; grouped under the existing
  "TimescaleDB Backup" device).
- New helpers in `backup-lib.sh`: `update_ha_verify_sensor`,
  `notify_verify_failure`, `notify_quarterly_drill_due`.
- New executable `run-verify.sh` — single-code-path verify runner used by
  both the cron branch and the operator's manual SSH retry.
- New playbook `scripts/verify-restore/QUARTERLY-DRILL.md` — manual deep
  restore drill steps for both repos.

### Changed

- New failure notification path `pgbackrest-verify-<repo>-failed` (stable
  notification_id so flapping verifies dedupe in the HA UI).
- `update_ha_sensor` `case` block now recognises `timescaledb_backup_last_verify_*`
  and emits `device_class=timestamp` in the MQTT discovery config for the new
  sensors.

## [1.1.1] — earlier

See git history.

[1.1.2-phase10.1]: https://github.com/flaksit/ha-timescaledb/tree/main
[1.1.1]: https://github.com/flaksit/ha-timescaledb/releases/tag/v1.1.1
