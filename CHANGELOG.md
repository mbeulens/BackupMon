# Changelog

All notable changes to this project are documented here.
This project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-06-08

### Added
- `bin/BackupCheck.ps1` — control script that verifies each MySQL backup `.rar` is present,
  non-zero, fresh, and not smaller than the previous run, alerting to Slack on any problem,
  with a Windows Event Log fallback. Decomposed into testable functions
  (`Format-Size`, `Test-BackupHealth`, `Get-LatestBackupFile`, `Read-State`/`Write-State`,
  `New-AlertMessage`, `Send-SlackAlert`, `Invoke-BackupCheck`).
- `tests/BackupCheck.Tests.ps1` — Pester 5 suite covering all functions and behaviors (30 tests).
- `docs/OPERATIONS.md` — configuration and Windows Task Scheduler setup.
- `bin/mysql-creds.example.cnf` — template for the git-ignored MySQL credentials file.
- `README.md`, `VERSION`, `CHANGELOG.md`.

### Changed
- Backup scripts now read credentials via `mysqldump --defaults-extra-file=...` instead of a
  password on the command line.
- Removed the hard-coded MySQL password from `bin/mysqlBackupLogData.bat` (replaced with the
  externalized credentials file); normalized the daily script's placeholder.

### Security
- Scrubbed the previously committed plaintext MySQL password from the entire git history.
