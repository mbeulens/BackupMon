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
