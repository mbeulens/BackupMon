@{
    # Folder containing the backup .rar files.
    BackupDir = 'D:\SyntecServer\backup\mysql'

    # Slack Incoming Webhook URL. Keep this out of git — the real
    # BackupCheck.config.psd1 is git-ignored; only this .example file is committed.
    SlackWebhookUrl = 'https://hooks.slack.com/services/REPLACE/WITH/REAL'

    # Friendly server label shown in alerts. Leave '' to use the machine name.
    ServerName = ''

    # Hours before a backup is considered "stale / did not run".
    FreshnessDailyHours = 26   # daily check
    FreshnessWeekHours  = 192  # weekly check (8 days)
}
