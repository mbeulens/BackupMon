# BackupCheck — Design

**Date:** 2026-06-08
**Status:** Approved (pending spec review)

## Problem

A Windows MySQL server runs two scheduled backups that each produce a `.rar` archive:

- `bin/mysqlBackupDaily.bat` — daily at **00:10**. Names its archive `backup.daily.%DATE:~0,3%.rar`, i.e. the first 3 characters of the Windows date. In practice this rotates across **7 weekday-named files** (e.g. `Sun/Mon/...` or Dutch `zo/ma/...` depending on server locale). Each weekday file is refreshed once per week.
- `bin/mysqlBackupLogData.bat` — weekly on **Sunday at 13:30**. Because it always runs on Sunday, it always writes the **same single file** (`backup.logdata.<Sun>.rar`) and `del`s it before recreating it — so last week's archive is gone the moment the new one is written.

We want a control script that detects a likely-bad backup and notifies someone, where "bad" means:

1. The archive is **smaller** than the previous one (strict: any shrink, per user choice).
2. The archive is **0 bytes**.
3. (Added) The archive is **missing**.
4. (Added) The backup appears **not to have run** (stale file), catching a silently-failed scheduled task.

Notifications go to **Slack** via an Incoming Webhook. **Alerts-only** (no success/heartbeat message).

## Approach

A single PowerShell script, `bin/BackupCheck.ps1`, parameterised by backup type (`daily` | `logdata`), plus a small JSON state file that remembers the last seen size per type. This unified, stateful approach works identically for both backup types and is the only way to give the weekly check something to compare against (its previous file is overwritten each week).

Rejected alternatives:
- **Pure on-disk comparison** (compare two newest files, no state): works for daily but impossible for weekly, since the weekly file is overwritten → inconsistent.
- **Replicate `%DATE:~0,3%` filename logic** to compute exact today/yesterday filenames: fragile (locale-dependent weekday abbreviations) and weekly still needs state.

## Components

### `bin/BackupCheck.ps1`
PowerShell script. Native to the Windows server; handles file sizes, JSON, and HTTP POST (`Invoke-RestMethod`) without extra dependencies.

**Parameters:**
- `-Type` (required): `daily` or `logdata`.
- `-DryRun` (optional switch): print what would be sent to Slack without posting.

**Config (variables at top of script):**
- `$BackupDir = "D:\SyntecServer\backup\mysql"`
- `$SlackWebhookUrl = "<incoming-webhook-url>"`
- `$ServerName = "<MySQL server name>"`
- `$StateFile = "$BackupDir\backupcheck.state.json"`
- Freshness windows: daily ≈ 26 hours, weekly ≈ 8 days.

### State file — `D:\SyntecServer\backup\mysql\backupcheck.state.json`
JSON keyed by backup type, storing the last observed size and timestamp:

```json
{
  "daily":   { "size": 12345678, "checkedAt": "2026-06-08T02:00:03" },
  "logdata": { "size": 98765432, "checkedAt": "2026-06-07T16:00:05" }
}
```

## Algorithm (identical for both types)

1. **Locate the file**
   - `daily`: newest `backup.daily.*.rar` in `$BackupDir` by `LastWriteTime`.
   - `logdata`: newest `backup.logdata.*.rar` in `$BackupDir` by `LastWriteTime`.
2. **Missing** — no matching file found → alert, stop.
3. **Zero bytes** — size == 0 → alert, stop (do not overwrite a good stored size with 0... see State update note).
4. **Stale** — `LastWriteTime` older than the freshness window for this type → alert ("backup may not have run"). Continue to size checks where sensible.
5. **Shrink** — if a previous size is recorded for this type and `current < previous` (strict) → alert, including current and previous sizes.
6. **Update state** — write `{ size: current, checkedAt: now }` for this type. (On zero-byte/missing cases the stored "good" previous size is left intact so the next valid run can still compare meaningfully.)

If none of 2–5 trigger, the run is silent (alerts-only).

## Notification

Slack message (only sent on a problem) includes:
- Server name
- Backup type (`daily` / `logdata`)
- Filename
- Current size (human-readable + bytes)
- Previous size (if known)
- Reason (missing / zero-bytes / stale / shrink)
- Timestamp

## Error handling

- If the script itself errors (e.g. backup folder unreachable), it still attempts a Slack alert describing the failure.
- If Slack is unreachable, fall back to writing a Warning/Error entry to the **Windows Event Log** so the failure is not silent.
- State-file read failure (missing/corrupt) is treated as "no previous size" (skip shrink check, then write fresh state).

## Scheduling (separate Windows Task Scheduler entries)

- **BackupCheck Daily** → `powershell -ExecutionPolicy Bypass -File "<path>\bin\BackupCheck.ps1" -Type daily` — daily at **02:00** (≈2 h after the 00:10 backup).
- **BackupCheck LogData** → `powershell -ExecutionPolicy Bypass -File "<path>\bin\BackupCheck.ps1" -Type logdata` — Sundays at **16:00** (≈2.5 h after the 13:30 backup).

## Testing

- **DryRun mode**: run with `-DryRun` to print the computed sizes, comparison result, and the Slack payload without posting.
- **Manual scenarios**: point `$BackupDir` at a test folder and stage files to exercise each path: normal (no alert), shrink, zero-byte, missing, and stale.
- **Slack smoke test**: a one-off forced alert to confirm the webhook URL works.

## Open items / assumptions

- Server locale affects weekday abbreviations in filenames, but the algorithm sidesteps this by selecting files via `LastWriteTime` rather than parsing dates.
- This project is not currently a git repository, so the spec is saved but not committed.
