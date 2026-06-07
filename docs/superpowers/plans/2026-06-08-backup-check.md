# BackupCheck Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A PowerShell control script that verifies each MySQL backup `.rar` is fresh, non-zero, present, and not smaller than the previous run, alerting to Slack when any check fails.

**Architecture:** A single script `bin/BackupCheck.ps1` decomposed into small pure functions (size formatting, health decision, file selection, state I/O, message building) plus thin side-effect functions (Slack POST, Event Log fallback) and an orchestrator. A JSON state file remembers the last good size per backup type so the weekly check (whose file is overwritten each Sunday) has something to compare against. Two Windows Scheduled Tasks invoke it with `-Type daily` / `-Type logdata`.

**Tech Stack:** PowerShell 5.1+ (cross-platform PowerShell 7 for local dev), Pester 5 for tests, Slack Incoming Webhook, Windows Task Scheduler.

---

## File Structure

- `bin/BackupCheck.ps1` — the checker. All functions + a guarded `main` block that only runs when `-Type` is supplied (so Pester can dot-source it to test functions without executing).
- `tests/BackupCheck.Tests.ps1` — Pester 5 test suite.
- `docs/OPERATIONS.md` — how to configure (webhook, paths), schedule the tasks, and test manually.
- `.gitignore` — ignore local state/test artifacts.
- Runtime-only (not in repo): `D:\SyntecServer\backup\mysql\backupcheck.state.json` — the state file, created on the server.

### Key function contracts (defined once, referenced by later tasks)

```powershell
# Pure: bytes -> human-readable string
Format-Size -Bytes <long> -> [string]

# Filesystem: newest matching .rar or $null
Get-LatestBackupFile -BackupDir <string> -Type <'daily'|'logdata'> -> [FileInfo] | $null

# State I/O (JSON keyed by type: @{ size=<long>; checkedAt=<string> })
Read-State  -StateFile <string> -> [hashtable]
Write-State -StateFile <string> -State <hashtable> -> void

# Pure decision logic — the heart of the script
Test-BackupHealth -File <FileInfo|$null> -PreviousSize <long|$null> -Now <datetime> -FreshnessHours <int>
  -> [pscustomobject]@{ Alert=<bool>; Issues=<string[]>; CurrentSize=<long|$null>; PreviousSize=<long|$null> }
  # Issues values: 'missing' | 'zero' | 'stale' | 'shrink'

# Pure: build the alert text
New-AlertMessage -ServerName <string> -Type <string> -File <FileInfo|$null> -Issues <string[]> -PreviousSize <long|$null> -> [string]

# Side effects
Send-SlackAlert        -WebhookUrl <string> -Text <string> -> void
Write-EventLogFallback -Text <string> -> void

# Orchestrator
Invoke-BackupCheck -Type ... -BackupDir ... -StateFile ... -WebhookUrl ... -ServerName ... -FreshnessHours ... [-Now ...] [-DryRun]
  -> the Test-BackupHealth result object
```

---

## Task 1: Project setup (git, tooling, skeleton)

**Files:**
- Create: `.gitignore`
- Create: `bin/BackupCheck.ps1` (skeleton only)
- Create: `tests/BackupCheck.Tests.ps1` (empty Describe)

- [ ] **Step 1: Initialise git**

Run:
```bash
cd /home/beuner/Development/Local/BackupMon
git init
```
Expected: `Initialized empty Git repository ...`

- [ ] **Step 2: Install PowerShell 7 + Pester (local dev box only; skip on the Windows server where PS 5.1 + Pester ship built-in)**

Run:
```bash
command -v pwsh || (sudo snap install powershell --classic || echo "Install pwsh manually: https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux")
pwsh -NoProfile -Command "if (-not (Get-Module -ListAvailable Pester | Where-Object Version -ge '5.0')) { Install-Module Pester -MinimumVersion 5.0 -Force -Scope CurrentUser }; Get-Module -ListAvailable Pester | Select-Object Name,Version | Sort-Object Version -Descending | Select-Object -First 1"
```
Expected: prints `Pester  5.x.x`

- [ ] **Step 3: Write `.gitignore`**

```gitignore
# Runtime state (created on the server, never committed)
backupcheck.state.json
# Local test scratch
TestResults/
*.log
```

- [ ] **Step 4: Write the script skeleton `bin/BackupCheck.ps1`**

```powershell
[CmdletBinding()]
param(
    [ValidateSet('daily', 'logdata')]
    [string]$Type,
    [switch]$DryRun
)

# ============================ CONFIG ============================
# Edit these for your server.
$script:BackupDir            = 'D:\SyntecServer\backup\mysql'
$script:StateFile           = Join-Path $script:BackupDir 'backupcheck.state.json'
$script:SlackWebhookUrl     = 'https://hooks.slack.com/services/REPLACE/WITH/REAL'
$script:ServerName          = $env:COMPUTERNAME
$script:FreshnessDailyHours = 26
$script:FreshnessWeekHours  = 192   # 8 days
# ===============================================================

# (functions added in later tasks)

# ----- main guard: only runs for a real invocation, not when dot-sourced by tests -----
if ($Type) {
    $freshness = if ($Type -eq 'daily') { $script:FreshnessDailyHours } else { $script:FreshnessWeekHours }
    Invoke-BackupCheck -Type $Type `
        -BackupDir  $script:BackupDir `
        -StateFile  $script:StateFile `
        -WebhookUrl $script:SlackWebhookUrl `
        -ServerName $script:ServerName `
        -FreshnessHours $freshness `
        -DryRun:$DryRun | Out-Null
}
```

- [ ] **Step 5: Write the test file skeleton `tests/BackupCheck.Tests.ps1`**

```powershell
BeforeAll {
    . "$PSScriptRoot/../bin/BackupCheck.ps1"
}

Describe 'BackupCheck' {
    It 'loads without executing main' {
        $true | Should -Be $true
    }
}
```

- [ ] **Step 6: Run the tests (verifies dot-sourcing works and main does not run)**

Run:
```bash
pwsh -NoProfile -Command "Invoke-Pester -Path tests/BackupCheck.Tests.ps1 -Output Detailed"
```
Expected: `Tests Passed: 1`

- [ ] **Step 7: Commit**

```bash
git add .gitignore bin/BackupCheck.ps1 tests/BackupCheck.Tests.ps1
git commit -m "chore: scaffold BackupCheck script, tests, and gitignore"
```

---

## Task 2: `Format-Size`

**Files:**
- Modify: `bin/BackupCheck.ps1` (add function under the CONFIG block)
- Test: `tests/BackupCheck.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Add inside the `Describe 'BackupCheck'` block:
```powershell
Context 'Format-Size' {
    It 'formats bytes' { Format-Size -Bytes 512 | Should -Be '512 B' }
    It 'formats kilobytes' { Format-Size -Bytes 2048 | Should -Be '2.00 KB' }
    It 'formats megabytes' { Format-Size -Bytes 5242880 | Should -Be '5.00 MB' }
    It 'formats gigabytes' { Format-Size -Bytes 3221225472 | Should -Be '3.00 GB' }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path tests/BackupCheck.Tests.ps1 -Output Detailed"`
Expected: FAIL — `CommandNotFoundException: Format-Size`

- [ ] **Step 3: Implement `Format-Size`** (add after the CONFIG block)

```powershell
function Format-Size {
    param([Parameter(Mandatory)][long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}
```

- [ ] **Step 4: Run to verify pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path tests/BackupCheck.Tests.ps1 -Output Detailed"`
Expected: all `Format-Size` tests PASS

- [ ] **Step 5: Commit**

```bash
git add bin/BackupCheck.ps1 tests/BackupCheck.Tests.ps1
git commit -m "feat: add Format-Size helper"
```

---

## Task 3: `Test-BackupHealth` (core decision logic)

**Files:**
- Modify: `bin/BackupCheck.ps1`
- Test: `tests/BackupCheck.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Add a new `Context` in the test file:
```powershell
Context 'Test-BackupHealth' {
    $now = [datetime]'2026-06-08T02:00:00'
    function NewFakeFile($len, $written) {
        [pscustomobject]@{ Length = [long]$len; LastWriteTime = [datetime]$written; Name = 'backup.daily.Mon.rar' }
    }

    It 'no alert when fresh, non-zero, and not smaller' {
        $f = NewFakeFile 1000 '2026-06-08T00:15:00'
        $r = Test-BackupHealth -File $f -PreviousSize 900 -Now $now -FreshnessHours 26
        $r.Alert | Should -Be $false
        $r.Issues | Should -BeNullOrEmpty
    }
    It 'alerts missing when file is null' {
        $r = Test-BackupHealth -File $null -PreviousSize 900 -Now $now -FreshnessHours 26
        $r.Alert | Should -Be $true
        $r.Issues | Should -Contain 'missing'
    }
    It 'alerts zero when length is 0' {
        $f = NewFakeFile 0 '2026-06-08T00:15:00'
        $r = Test-BackupHealth -File $f -PreviousSize 900 -Now $now -FreshnessHours 26
        $r.Issues | Should -Contain 'zero'
        $r.Issues | Should -Not -Contain 'shrink'
    }
    It 'alerts stale when older than freshness window' {
        $f = NewFakeFile 1000 '2026-06-06T00:15:00'
        $r = Test-BackupHealth -File $f -PreviousSize 900 -Now $now -FreshnessHours 26
        $r.Issues | Should -Contain 'stale'
    }
    It 'alerts shrink when smaller than previous (strict)' {
        $f = NewFakeFile 899 '2026-06-08T00:15:00'
        $r = Test-BackupHealth -File $f -PreviousSize 900 -Now $now -FreshnessHours 26
        $r.Issues | Should -Contain 'shrink'
    }
    It 'does not alert shrink when equal to previous' {
        $f = NewFakeFile 900 '2026-06-08T00:15:00'
        $r = Test-BackupHealth -File $f -PreviousSize 900 -Now $now -FreshnessHours 26
        $r.Alert | Should -Be $false
    }
    It 'no shrink check when no previous size' {
        $f = NewFakeFile 10 '2026-06-08T00:15:00'
        $r = Test-BackupHealth -File $f -PreviousSize $null -Now $now -FreshnessHours 26
        $r.Alert | Should -Be $false
    }
    It 'can report both stale and shrink' {
        $f = NewFakeFile 899 '2026-06-06T00:15:00'
        $r = Test-BackupHealth -File $f -PreviousSize 900 -Now $now -FreshnessHours 26
        $r.Issues | Should -Contain 'stale'
        $r.Issues | Should -Contain 'shrink'
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path tests/BackupCheck.Tests.ps1 -Output Detailed"`
Expected: FAIL — `CommandNotFoundException: Test-BackupHealth`

- [ ] **Step 3: Implement `Test-BackupHealth`**

```powershell
function Test-BackupHealth {
    param(
        $File,                                  # FileInfo-like or $null
        $PreviousSize,                          # [long] or $null
        [Parameter(Mandatory)][datetime]$Now,
        [Parameter(Mandatory)][int]$FreshnessHours
    )
    $issues = New-Object System.Collections.Generic.List[string]
    if ($null -eq $File) {
        $issues.Add('missing')
    }
    elseif ([long]$File.Length -eq 0) {
        $issues.Add('zero')
    }
    else {
        if ($File.LastWriteTime -lt $Now.AddHours(-$FreshnessHours)) { $issues.Add('stale') }
        if ($null -ne $PreviousSize -and [long]$File.Length -lt [long]$PreviousSize) { $issues.Add('shrink') }
    }
    [pscustomobject]@{
        Alert        = ($issues.Count -gt 0)
        Issues       = $issues.ToArray()
        CurrentSize  = if ($File) { [long]$File.Length } else { $null }
        PreviousSize = $PreviousSize
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path tests/BackupCheck.Tests.ps1 -Output Detailed"`
Expected: all `Test-BackupHealth` tests PASS

- [ ] **Step 5: Commit**

```bash
git add bin/BackupCheck.ps1 tests/BackupCheck.Tests.ps1
git commit -m "feat: add Test-BackupHealth decision logic"
```

---

## Task 4: `Get-LatestBackupFile`

**Files:**
- Modify: `bin/BackupCheck.ps1`
- Test: `tests/BackupCheck.Tests.ps1`

- [ ] **Step 1: Write the failing tests** (uses Pester's `$TestDrive` temp folder)

```powershell
Context 'Get-LatestBackupFile' {
    BeforeEach {
        $script:dir = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:dir | Out-Null
    }
    It 'returns null when no files match' {
        Get-LatestBackupFile -BackupDir $script:dir -Type 'daily' | Should -Be $null
    }
    It 'returns the newest daily file by LastWriteTime' {
        $old = Join-Path $script:dir 'backup.daily.Mon.rar'; 'a' | Set-Content $old
        Start-Sleep -Milliseconds 50
        $new = Join-Path $script:dir 'backup.daily.Tue.rar'; 'bb' | Set-Content $new
        (Get-LatestBackupFile -BackupDir $script:dir -Type 'daily').Name | Should -Be 'backup.daily.Tue.rar'
    }
    It 'does not return logdata files for daily type' {
        'a' | Set-Content (Join-Path $script:dir 'backup.logdata.Sun.rar')
        Get-LatestBackupFile -BackupDir $script:dir -Type 'daily' | Should -Be $null
    }
    It 'returns the logdata file for logdata type' {
        'a' | Set-Content (Join-Path $script:dir 'backup.logdata.Sun.rar')
        (Get-LatestBackupFile -BackupDir $script:dir -Type 'logdata').Name | Should -Be 'backup.logdata.Sun.rar'
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path tests/BackupCheck.Tests.ps1 -Output Detailed"`
Expected: FAIL — `CommandNotFoundException: Get-LatestBackupFile`

- [ ] **Step 3: Implement `Get-LatestBackupFile`**

```powershell
function Get-LatestBackupFile {
    param(
        [Parameter(Mandatory)][string]$BackupDir,
        [Parameter(Mandatory)][ValidateSet('daily', 'logdata')][string]$Type
    )
    $pattern = if ($Type -eq 'daily') { 'backup.daily.*.rar' } else { 'backup.logdata.*.rar' }
    Get-ChildItem -Path $BackupDir -Filter $pattern -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}
```

- [ ] **Step 4: Run to verify pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path tests/BackupCheck.Tests.ps1 -Output Detailed"`
Expected: all `Get-LatestBackupFile` tests PASS

- [ ] **Step 5: Commit**

```bash
git add bin/BackupCheck.ps1 tests/BackupCheck.Tests.ps1
git commit -m "feat: add Get-LatestBackupFile selection by LastWriteTime"
```

---

## Task 5: State I/O — `Read-State` / `Write-State`

**Files:**
- Modify: `bin/BackupCheck.ps1`
- Test: `tests/BackupCheck.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

```powershell
Context 'State I/O' {
    BeforeEach { $script:sf = Join-Path $TestDrive ([guid]::NewGuid().ToString() + '.json') }

    It 'returns empty hashtable when file missing' {
        $s = Read-State -StateFile $script:sf
        $s | Should -BeOfType System.Collections.Hashtable
        $s.Count | Should -Be 0
    }
    It 'round-trips a stored size' {
        $state = @{ daily = @{ size = 12345; checkedAt = '2026-06-08T02:00:00' } }
        Write-State -StateFile $script:sf -State $state
        $read = Read-State -StateFile $script:sf
        [long]$read['daily'].size | Should -Be 12345
    }
    It 'returns empty hashtable on corrupt json' {
        'not json {{{' | Set-Content $script:sf
        (Read-State -StateFile $script:sf).Count | Should -Be 0
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path tests/BackupCheck.Tests.ps1 -Output Detailed"`
Expected: FAIL — `CommandNotFoundException: Read-State`

- [ ] **Step 3: Implement `Read-State` and `Write-State`**

```powershell
function Read-State {
    param([Parameter(Mandatory)][string]$StateFile)
    if (-not (Test-Path -LiteralPath $StateFile)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $StateFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        $ht = @{}
        foreach ($p in $obj.PSObject.Properties) { $ht[$p.Name] = $p.Value }
        return $ht
    }
    catch { return @{} }
}

function Write-State {
    param(
        [Parameter(Mandatory)][string]$StateFile,
        [Parameter(Mandatory)][hashtable]$State
    )
    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StateFile -Encoding UTF8
}
```

- [ ] **Step 4: Run to verify pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path tests/BackupCheck.Tests.ps1 -Output Detailed"`
Expected: all `State I/O` tests PASS

- [ ] **Step 5: Commit**

```bash
git add bin/BackupCheck.ps1 tests/BackupCheck.Tests.ps1
git commit -m "feat: add JSON state read/write with corrupt-file tolerance"
```

---

## Task 6: `New-AlertMessage`

**Files:**
- Modify: `bin/BackupCheck.ps1`
- Test: `tests/BackupCheck.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

```powershell
Context 'New-AlertMessage' {
    function NewFakeFile2($len, $name) {
        [pscustomobject]@{ Length = [long]$len; Name = $name; LastWriteTime = [datetime]'2026-06-08T00:15:00' }
    }
    It 'includes server, type, reason, and sizes for a shrink' {
        $f = NewFakeFile2 899 'backup.daily.Tue.rar'
        $m = New-AlertMessage -ServerName 'SQL01' -Type 'daily' -File $f -Issues @('shrink') -PreviousSize 900
        $m | Should -BeLike '*SQL01*'
        $m | Should -BeLike '*daily*'
        $m | Should -BeLike '*shrink*'
        $m | Should -BeLike '*backup.daily.Tue.rar*'
        $m | Should -BeLike '*899 B*'
        $m | Should -BeLike '*900 B*'
    }
    It 'handles a missing file (no FileInfo)' {
        $m = New-AlertMessage -ServerName 'SQL01' -Type 'logdata' -File $null -Issues @('missing') -PreviousSize 900
        $m | Should -BeLike '*missing*'
        $m | Should -BeLike '*logdata*'
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path tests/BackupCheck.Tests.ps1 -Output Detailed"`
Expected: FAIL — `CommandNotFoundException: New-AlertMessage`

- [ ] **Step 3: Implement `New-AlertMessage`**

```powershell
function New-AlertMessage {
    param(
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][string]$Type,
        $File,
        [string[]]$Issues,
        $PreviousSize
    )
    $reasonText = @{
        missing = 'Backup file is MISSING'
        zero    = 'Backup file is 0 BYTES'
        stale   = 'Backup appears NOT to have run (file is stale)'
        shrink  = 'Backup is SMALLER than the previous run'
    }
    $reasons = ($Issues | ForEach-Object { $reasonText[$_] }) -join '; '
    $fileName = if ($File) { $File.Name } else { '(none found)' }
    $curText  = if ($File) { "$(Format-Size -Bytes ([long]$File.Length)) ($([long]$File.Length) B)" } else { 'n/a' }
    $prevText = if ($null -ne $PreviousSize) { "$(Format-Size -Bytes ([long]$PreviousSize)) ($([long]$PreviousSize) B)" } else { 'unknown' }

    @(
        ":rotating_light: *MySQL backup problem on $ServerName*",
        "*Type:* $Type",
        "*File:* $fileName",
        "*Current size:* $curText",
        "*Previous size:* $prevText",
        "*Problem:* $reasons"
    ) -join "`n"
}
```

- [ ] **Step 4: Run to verify pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path tests/BackupCheck.Tests.ps1 -Output Detailed"`
Expected: all `New-AlertMessage` tests PASS

- [ ] **Step 5: Commit**

```bash
git add bin/BackupCheck.ps1 tests/BackupCheck.Tests.ps1
git commit -m "feat: add Slack alert message builder"
```

---

## Task 7: Side effects + `Invoke-BackupCheck` orchestrator

**Files:**
- Modify: `bin/BackupCheck.ps1`
- Test: `tests/BackupCheck.Tests.ps1`

- [ ] **Step 1: Write the failing tests** (mock the network/event-log side effects)

```powershell
Context 'Invoke-BackupCheck' {
    BeforeEach {
        $script:dir = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:dir | Out-Null
        $script:sf  = Join-Path $script:dir 'state.json'
        Mock -CommandName Send-SlackAlert -MockWith { }
        Mock -CommandName Write-EventLogFallback -MockWith { }
    }
    $now = [datetime]'2026-06-08T02:00:00'

    It 'no Slack call on a healthy fresh backup and records size' {
        $p = Join-Path $script:dir 'backup.daily.Sun.rar'; 'hello' | Set-Content $p
        (Get-Item $p).LastWriteTime = [datetime]'2026-06-08T00:15:00'
        $r = Invoke-BackupCheck -Type daily -BackupDir $script:dir -StateFile $script:sf -WebhookUrl 'http://x' -ServerName 'SQL01' -FreshnessHours 26 -Now $now
        $r.Alert | Should -Be $false
        Should -Invoke Send-SlackAlert -Times 0
        [long](Read-State -StateFile $script:sf)['daily'].size | Should -Be (Get-Item $p).Length
    }
    It 'sends Slack alert on missing file and does NOT overwrite a prior good size' {
        Write-State -StateFile $script:sf -State @{ daily = @{ size = 5000; checkedAt = 'x' } }
        $r = Invoke-BackupCheck -Type daily -BackupDir $script:dir -StateFile $script:sf -WebhookUrl 'http://x' -ServerName 'SQL01' -FreshnessHours 26 -Now $now
        $r.Issues | Should -Contain 'missing'
        Should -Invoke Send-SlackAlert -Times 1
        [long](Read-State -StateFile $script:sf)['daily'].size | Should -Be 5000
    }
    It 'sends Slack alert on shrink and updates stored size to the smaller value' {
        Write-State -StateFile $script:sf -State @{ daily = @{ size = 5000; checkedAt = 'x' } }
        $p = Join-Path $script:dir 'backup.daily.Sun.rar'; 'hi' | Set-Content $p
        (Get-Item $p).LastWriteTime = [datetime]'2026-06-08T00:15:00'
        $r = Invoke-BackupCheck -Type daily -BackupDir $script:dir -StateFile $script:sf -WebhookUrl 'http://x' -ServerName 'SQL01' -FreshnessHours 26 -Now $now
        $r.Issues | Should -Contain 'shrink'
        Should -Invoke Send-SlackAlert -Times 1
        [long](Read-State -StateFile $script:sf)['daily'].size | Should -Be (Get-Item $p).Length
    }
    It 'DryRun never calls Slack even on a problem' {
        $r = Invoke-BackupCheck -Type daily -BackupDir $script:dir -StateFile $script:sf -WebhookUrl 'http://x' -ServerName 'SQL01' -FreshnessHours 26 -Now $now -DryRun
        $r.Alert | Should -Be $true
        Should -Invoke Send-SlackAlert -Times 0
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path tests/BackupCheck.Tests.ps1 -Output Detailed"`
Expected: FAIL — `CommandNotFoundException: Invoke-BackupCheck` (Mock of Send-SlackAlert also fails until defined)

- [ ] **Step 3: Implement the side effects and orchestrator**

```powershell
function Send-SlackAlert {
    param(
        [Parameter(Mandatory)][string]$WebhookUrl,
        [Parameter(Mandatory)][string]$Text
    )
    $payload = @{ text = $Text } | ConvertTo-Json -Depth 3
    Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType 'application/json' -Body $payload -TimeoutSec 20 | Out-Null
}

function Write-EventLogFallback {
    param([Parameter(Mandatory)][string]$Text)
    try {
        $source = 'BackupCheck'
        if (-not [System.Diagnostics.EventLog]::SourceExists($source)) {
            New-EventLog -LogName Application -Source $source -ErrorAction Stop
        }
        Write-EventLog -LogName Application -Source $source -EntryType Error -EventId 1001 -Message $Text
    }
    catch {
        Write-Warning "BackupCheck: could not write to Event Log: $($_.Exception.Message)"
    }
}

function Invoke-BackupCheck {
    param(
        [Parameter(Mandatory)][ValidateSet('daily', 'logdata')][string]$Type,
        [Parameter(Mandatory)][string]$BackupDir,
        [Parameter(Mandatory)][string]$StateFile,
        [Parameter(Mandatory)][string]$WebhookUrl,
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][int]$FreshnessHours,
        [datetime]$Now = (Get-Date),
        [switch]$DryRun
    )
    try {
        $file  = Get-LatestBackupFile -BackupDir $BackupDir -Type $Type
        $state = Read-State -StateFile $StateFile
        $prev  = $null
        if ($state.ContainsKey($Type) -and $null -ne $state[$Type]) { $prev = [long]$state[$Type].size }

        $result = Test-BackupHealth -File $file -PreviousSize $prev -Now $Now -FreshnessHours $FreshnessHours

        if ($result.Alert) {
            $msg = New-AlertMessage -ServerName $ServerName -Type $Type -File $file -Issues $result.Issues -PreviousSize $prev
            if ($DryRun) {
                Write-Host "[DryRun] Would send Slack alert:`n$msg"
            }
            else {
                Send-SlackAlert -WebhookUrl $WebhookUrl -Text $msg
            }
        }
        else {
            Write-Host "BackupCheck OK: $Type, $($file.Name), $(Format-Size -Bytes ([long]$file.Length))"
        }

        # Update state only when we have a real, non-zero file (keep last good size otherwise).
        if (-not $DryRun -and $file -and [long]$file.Length -gt 0) {
            $state[$Type] = @{ size = [long]$file.Length; checkedAt = $Now.ToString('s') }
            Write-State -StateFile $StateFile -State $state
        }

        return $result
    }
    catch {
        $errText = "BackupCheck FAILED for '$Type' on $ServerName: $($_.Exception.Message)"
        if (-not $DryRun) {
            try { Send-SlackAlert -WebhookUrl $WebhookUrl -Text ":rotating_light: $errText" }
            catch { Write-EventLogFallback -Text $errText }
        }
        else {
            Write-Host "[DryRun] $errText"
        }
        return [pscustomobject]@{ Alert = $true; Issues = @('error'); CurrentSize = $null; PreviousSize = $null }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path tests/BackupCheck.Tests.ps1 -Output Detailed"`
Expected: all `Invoke-BackupCheck` tests PASS, full suite green

- [ ] **Step 5: Commit**

```bash
git add bin/BackupCheck.ps1 tests/BackupCheck.Tests.ps1
git commit -m "feat: add Slack/EventLog side effects and orchestrator"
```

---

## Task 8: Operations doc (config + scheduling)

**Files:**
- Create: `docs/OPERATIONS.md`

- [ ] **Step 1: Write `docs/OPERATIONS.md`**

````markdown
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
Run these in an elevated `cmd` (adjust the path). The daily check runs at 02:00 (≈2 h after the 00:10 backup); the weekly check runs Sundays at 16:00 (≈2.5 h after the 13:30 log backup).

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
````

- [ ] **Step 2: Commit**

```bash
git add docs/OPERATIONS.md
git commit -m "docs: add operations and scheduling guide"
```

---

## Task 9: End-to-end dry-run verification

**Files:** none (verification only)

- [ ] **Step 1: Run the full Pester suite one final time**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path tests/BackupCheck.Tests.ps1 -Output Detailed"`
Expected: 0 failed.

- [ ] **Step 2: Manual dry-run against a staged folder**

Run:
```bash
pwsh -NoProfile -Command @'
$dir = Join-Path ([System.IO.Path]::GetTempPath()) ("bc_" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $dir | Out-Null
Set-Content (Join-Path $dir "backup.daily.Mon.rar") "some content"
. ./bin/BackupCheck.ps1
Invoke-BackupCheck -Type daily -BackupDir $dir -StateFile (Join-Path $dir "state.json") -WebhookUrl "http://unused" -ServerName "TEST" -FreshnessHours 26 -Now ([datetime]"2026-06-08T02:00:00") -DryRun | Format-List
'@
```
Expected: prints `Alert : False` (the staged file is fresh and non-zero, no previous size) and no Slack call attempted.

- [ ] **Step 3: On the Windows server — real smoke test**

Edit the CONFIG block with the real `$SlackWebhookUrl`, then run:
```bat
powershell -ExecutionPolicy Bypass -File "D:\path\to\bin\BackupCheck.ps1" -Type daily -DryRun
```
Expected: prints either `BackupCheck OK: daily, ...` or `[DryRun] Would send Slack alert: ...`. Then temporarily point `$BackupDir` at an empty folder and run without `-DryRun` to confirm a real Slack alert arrives.

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "chore: BackupCheck complete and verified"
```