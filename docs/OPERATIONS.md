# BackupCheck — Operations

## Configure
Edit the CONFIG block at the top of `bin/BackupCheck.ps1`:
- `$BackupDir` — folder holding the `.rar` files (default `D:\SyntecServer\backup\mysql`).
- `$SlackWebhookUrl` — your Slack Incoming Webhook URL.
- `$ServerName` — defaults to the machine name; override if you want a friendlier label.
- Freshness windows: daily `26` h, weekly `192` h (8 days).

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
