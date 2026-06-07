# BackupCheck — Operations

## MySQL credentials (backup scripts)
The backup scripts (`bin/mysqlBackupDaily.bat`, `bin/mysqlBackupLogData.bat`) read the MySQL
password from a git-ignored option file via `mysqldump --defaults-extra-file=...`, so the
password never appears on the command line, in the process list, or in Task Scheduler logs.

Set it up once on the server:
1. Copy `bin/mysql-creds.example.cnf` to **`D:\SyntecServer\backup\mysql-creds.cnf`**
   (in `backup\`, the parent of `backup\mysql\`, so the weekly robocopy does **not** ship it off-server).
2. Edit the file and fill in the real `password=` (and adjust `user=` if not `root`).
3. Restrict its NTFS permissions so only the backup/service account can read it:
   ```bat
   icacls "D:\SyntecServer\backup\mysql-creds.cnf" /inheritance:r /grant:r "SYSTEM:R" "Administrators:R"
   ```

The real `mysql-creds.cnf` is git-ignored; only `bin/mysql-creds.example.cnf` is committed.
If you change `$BackupDir` or move the creds file, update the `--defaults-extra-file=` path in both `.bat` scripts to match.

## Configure
Settings live in a git-ignored PowerShell data file next to the script. Copy the template once:
```powershell
Copy-Item bin\BackupCheck.config.example.psd1 bin\BackupCheck.config.psd1
```
Then edit `bin\BackupCheck.config.psd1`:
- `BackupDir` — folder holding the `.rar` files (default `D:\SyntecServer\backup\mysql`).
- `SlackWebhookUrl` — your Slack Incoming Webhook URL (required).
- `ServerName` — label shown in alerts; leave `''` to use the machine name.
- `FreshnessDailyHours` / `FreshnessWeekHours` — staleness windows (defaults `26` and `192` h = 8 days).

`BackupDir` and `SlackWebhookUrl` are required; the script exits with a clear error if the config
file is missing or incomplete. Only `BackupCheck.config.example.psd1` is committed — the real
`BackupCheck.config.psd1` is git-ignored so the webhook URL never lands in git.

## Test manually before scheduling
Dry run (never posts to Slack, never writes state):
```powershell
powershell -ExecutionPolicy Bypass -File "D:\path\to\bin\BackupCheck.ps1" -Type daily -DryRun
powershell -ExecutionPolicy Bypass -File "D:\path\to\bin\BackupCheck.ps1" -Type logdata -DryRun
```
Force a real Slack test by temporarily pointing `$BackupDir` at an empty folder and running `-Type daily` (should post a "missing" alert).

## Schedule (Windows Task Scheduler)
Run these in an elevated `cmd` (adjust the path). The daily check runs at 02:00 (about 2 h after the 00:10 backup); the weekly check runs Sundays at 16:00 (about 2.5 h after the 13:30 log backup).

```bat
schtasks /Create /TN "BackupCheck Daily" /SC DAILY /ST 02:00 /RL HIGHEST /F ^
  /TR "powershell -ExecutionPolicy Bypass -NonInteractive -File \"D:\path\to\bin\BackupCheck.ps1\" -Type daily"

schtasks /Create /TN "BackupCheck LogData" /SC WEEKLY /D SUN /ST 16:00 /RL HIGHEST /F ^
  /TR "powershell -ExecutionPolicy Bypass -NonInteractive -File \"D:\path\to\bin\BackupCheck.ps1\" -Type logdata"
```

Verify / run on demand:
```bat
schtasks /Query  /TN "BackupCheck Daily" /V /FO LIST
schtasks /Run    /TN "BackupCheck Daily"
```

## State file
`backupcheck.state.json` lives in `$BackupDir` and stores the last good size per type. Deleting it just skips the next shrink comparison (it is rebuilt on the next run). It is git-ignored.

## How the checks work
For each run the script:
1. Finds the newest matching `.rar` (`backup.daily.*.rar` or `backup.logdata.*.rar`) by last-write time.
2. Alerts if the file is **missing**, **0 bytes**, **stale** (older than the freshness window, i.e. the backup likely did not run), or **smaller** than the previously recorded size (strict: any shrink).
3. Records the current size as the new baseline — but only when the file exists and is non-zero, so a bad run never overwrites the last known-good size.

Alerts go to Slack only (no message on success). If Slack itself is unreachable during an error, the script writes a Windows Event Log entry as a fallback.
