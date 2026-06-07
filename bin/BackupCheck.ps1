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
