# BackupMon

MySQL backup scripts and a monitoring/control script for the Windows MySQL server.

## Contents

| Path | Purpose |
|------|---------|
| `bin/mysqlBackupDaily.bat` | Daily MySQL dump (excludes log/audit tables) → `.rar`. Scheduled daily at 00:10. |
| `bin/mysqlBackupLogData.bat` | Weekly dump of the log/audit tables → `.rar`, then robocopy to the backup share. Scheduled Sundays 13:30. |
| `bin/BackupCheck.ps1` | Control script: verifies each backup `.rar` is present, non-zero, fresh, and not smaller than the previous run; alerts to Slack on any problem. |
| `bin/mysql-creds.example.cnf` | Template for the git-ignored MySQL credentials file. |
| `bin/BackupCheck.config.example.psd1` | Template for the git-ignored `BackupCheck.ps1` settings file. |
| `tests/BackupCheck.Tests.ps1` | Pester test suite for `BackupCheck.ps1`. |
| `docs/OPERATIONS.md` | Configuration and Windows Task Scheduler setup for `BackupCheck.ps1`. |

## Credentials

The backup scripts read the MySQL password from a git-ignored option file via
`mysqldump --defaults-extra-file=...`, so the password never appears on the command line.

1. Copy `bin/mysql-creds.example.cnf` to `D:\SyntecServer\backup\mysql-creds.cnf`.
2. Fill in the real password and restrict its NTFS permissions (see the comments in the example file).

## BackupCheck monitoring

`BackupCheck.ps1 -Type daily|logdata` checks the latest matching archive and posts a Slack
alert if it is **missing**, **0 bytes**, **stale** (the backup likely did not run), or
**smaller** than the previously recorded size. It keeps the last good size per type in a
git-ignored `backupcheck.state.json`. See `docs/OPERATIONS.md` for configuration and scheduling.

Run the tests (PowerShell + [Pester 5](https://pester.dev)):

```powershell
Invoke-Pester -Path tests/BackupCheck.Tests.ps1 -Output Detailed
```

## Versioning & branches

- Work happens on `dev`; `master` holds released versions.
- Patch releases (`0.1.x`) are routine commits on `dev`.
- Minor/major releases update this README + `CHANGELOG.md`, then merge `dev` → `master`.

See `CHANGELOG.md` for the version history.
