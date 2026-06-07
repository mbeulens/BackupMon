[CmdletBinding()]
param(
    [ValidateSet('daily', 'logdata')]
    [string]$Type,
    [switch]$DryRun
)

# ============================ CONFIG ============================
# Edit these for your server.
$script:BackupDir            = 'D:\SyntecServer\backup\mysql'
$script:StateFile           = "$script:BackupDir\backupcheck.state.json"
$script:SlackWebhookUrl     = 'https://hooks.slack.com/services/REPLACE/WITH/REAL'
$script:ServerName          = $env:COMPUTERNAME
$script:FreshnessDailyHours = 26
$script:FreshnessWeekHours  = 192   # 8 days
# ===============================================================

function Format-Size {
    param([Parameter(Mandatory)][long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

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
    $reasons = ($Issues | ForEach-Object { $k = $_; "${k}: $($reasonText[$k])" }) -join '; '
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
        $errText = "BackupCheck FAILED for '$Type' on ${ServerName}: $($_.Exception.Message)"
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
