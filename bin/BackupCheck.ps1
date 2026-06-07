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
