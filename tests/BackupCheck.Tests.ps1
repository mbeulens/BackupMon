BeforeAll {
    . "$PSScriptRoot/../bin/BackupCheck.ps1"
}

Describe 'BackupCheck' {
    It 'loads without executing main' {
        $true | Should -Be $true
    }

    Context 'Import-BackupConfig' {
        BeforeEach { $script:cfgPath = Join-Path $TestDrive ([guid]::NewGuid().ToString() + '.psd1') }

        It 'throws a helpful error when the file is missing' {
            { Import-BackupConfig -Path $script:cfgPath } | Should -Throw '*not found*'
        }
        It 'loads values and derives the state file path' {
            Set-Content -LiteralPath $script:cfgPath -Value "@{ BackupDir = 'D:\backups\mysql'; SlackWebhookUrl = 'http://hook'; ServerName = 'SQL01'; FreshnessDailyHours = 30; FreshnessWeekHours = 200 }"
            $c = Import-BackupConfig -Path $script:cfgPath
            $c.BackupDir | Should -Be 'D:\backups\mysql'
            $c.SlackWebhookUrl | Should -Be 'http://hook'
            $c.ServerName | Should -Be 'SQL01'
            $c.FreshnessDailyHours | Should -Be 30
            $c.FreshnessWeekHours | Should -Be 200
            $c.StateFile | Should -Be 'D:\backups\mysql\backupcheck.state.json'
        }
        It 'throws when a required key is missing' {
            Set-Content -LiteralPath $script:cfgPath -Value "@{ BackupDir = 'D:\x' }"
            { Import-BackupConfig -Path $script:cfgPath } | Should -Throw '*SlackWebhookUrl*'
        }
        It 'defaults freshness and server name when omitted' {
            Set-Content -LiteralPath $script:cfgPath -Value "@{ BackupDir = 'D:\x'; SlackWebhookUrl = 'http://h' }"
            $c = Import-BackupConfig -Path $script:cfgPath
            $c.FreshnessDailyHours | Should -Be 26
            $c.FreshnessWeekHours | Should -Be 192
            $c.ServerName | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Format-Size' {
        It 'formats bytes' { Format-Size -Bytes 512 | Should -Be '512 B' }
        It 'formats kilobytes' { Format-Size -Bytes 2048 | Should -Be '2.00 KB' }
        It 'formats megabytes' { Format-Size -Bytes 5242880 | Should -Be '5.00 MB' }
        It 'formats gigabytes' { Format-Size -Bytes 3221225472 | Should -Be '3.00 GB' }
    }

    Context 'Test-BackupHealth' {
        BeforeAll {
            $script:now = [datetime]'2026-06-08T02:00:00'
            function NewFakeFile($len, $written) {
                [pscustomobject]@{ Length = [long]$len; LastWriteTime = [datetime]$written; Name = 'backup.daily.Mon.rar' }
            }
        }

        It 'no alert when fresh, non-zero, and not smaller' {
            $f = NewFakeFile 1000 '2026-06-08T00:15:00'
            $r = Test-BackupHealth -File $f -PreviousSize 900 -Now $script:now -FreshnessHours 26
            $r.Alert | Should -Be $false
            $r.Issues | Should -BeNullOrEmpty
        }
        It 'alerts missing when file is null' {
            $r = Test-BackupHealth -File $null -PreviousSize 900 -Now $script:now -FreshnessHours 26
            $r.Alert | Should -Be $true
            $r.Issues | Should -Contain 'missing'
        }
        It 'alerts zero when length is 0' {
            $f = NewFakeFile 0 '2026-06-08T00:15:00'
            $r = Test-BackupHealth -File $f -PreviousSize 900 -Now $script:now -FreshnessHours 26
            $r.Issues | Should -Contain 'zero'
            $r.Issues | Should -Not -Contain 'shrink'
        }
        It 'alerts stale when older than freshness window' {
            $f = NewFakeFile 1000 '2026-06-06T00:15:00'
            $r = Test-BackupHealth -File $f -PreviousSize 900 -Now $script:now -FreshnessHours 26
            $r.Issues | Should -Contain 'stale'
        }
        It 'alerts shrink when smaller than previous (strict)' {
            $f = NewFakeFile 899 '2026-06-08T00:15:00'
            $r = Test-BackupHealth -File $f -PreviousSize 900 -Now $script:now -FreshnessHours 26
            $r.Issues | Should -Contain 'shrink'
        }
        It 'does not alert shrink when equal to previous' {
            $f = NewFakeFile 900 '2026-06-08T00:15:00'
            $r = Test-BackupHealth -File $f -PreviousSize 900 -Now $script:now -FreshnessHours 26
            $r.Alert | Should -Be $false
        }
        It 'no shrink check when no previous size' {
            $f = NewFakeFile 10 '2026-06-08T00:15:00'
            $r = Test-BackupHealth -File $f -PreviousSize $null -Now $script:now -FreshnessHours 26
            $r.Alert | Should -Be $false
        }
        It 'can report both stale and shrink' {
            $f = NewFakeFile 899 '2026-06-06T00:15:00'
            $r = Test-BackupHealth -File $f -PreviousSize 900 -Now $script:now -FreshnessHours 26
            $r.Issues | Should -Contain 'stale'
            $r.Issues | Should -Contain 'shrink'
        }
    }

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

    Context 'New-AlertMessage' {
        BeforeAll {
            function NewFakeFile2($len, $name) {
                [pscustomobject]@{ Length = [long]$len; Name = $name; LastWriteTime = [datetime]'2026-06-08T00:15:00' }
            }
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

    Context 'Invoke-BackupCheck' {
        BeforeEach {
            $script:dir = Join-Path $TestDrive ([guid]::NewGuid())
            New-Item -ItemType Directory -Path $script:dir | Out-Null
            $script:sf  = Join-Path $script:dir 'state.json'
            $script:now = [datetime]'2026-06-08T02:00:00'
            Mock -CommandName Send-SlackAlert -MockWith { }
            Mock -CommandName Write-EventLogFallback -MockWith { }
        }

        It 'no Slack call on a healthy fresh backup and records size' {
            $p = Join-Path $script:dir 'backup.daily.Sun.rar'; 'hello' | Set-Content $p
            (Get-Item $p).LastWriteTime = [datetime]'2026-06-08T00:15:00'
            $r = Invoke-BackupCheck -Type daily -BackupDir $script:dir -StateFile $script:sf -WebhookUrl 'http://x' -ServerName 'SQL01' -FreshnessHours 26 -Now $script:now
            $r.Alert | Should -Be $false
            Should -Invoke Send-SlackAlert -Times 0
            [long](Read-State -StateFile $script:sf)['daily'].size | Should -Be (Get-Item $p).Length
        }
        It 'sends Slack alert on missing file and does NOT overwrite a prior good size' {
            Write-State -StateFile $script:sf -State @{ daily = @{ size = 5000; checkedAt = 'x' } }
            $r = Invoke-BackupCheck -Type daily -BackupDir $script:dir -StateFile $script:sf -WebhookUrl 'http://x' -ServerName 'SQL01' -FreshnessHours 26 -Now $script:now
            $r.Issues | Should -Contain 'missing'
            Should -Invoke Send-SlackAlert -Times 1
            [long](Read-State -StateFile $script:sf)['daily'].size | Should -Be 5000
        }
        It 'sends Slack alert on shrink and updates stored size to the smaller value' {
            Write-State -StateFile $script:sf -State @{ daily = @{ size = 5000; checkedAt = 'x' } }
            $p = Join-Path $script:dir 'backup.daily.Sun.rar'; 'hi' | Set-Content $p
            (Get-Item $p).LastWriteTime = [datetime]'2026-06-08T00:15:00'
            $r = Invoke-BackupCheck -Type daily -BackupDir $script:dir -StateFile $script:sf -WebhookUrl 'http://x' -ServerName 'SQL01' -FreshnessHours 26 -Now $script:now
            $r.Issues | Should -Contain 'shrink'
            Should -Invoke Send-SlackAlert -Times 1
            [long](Read-State -StateFile $script:sf)['daily'].size | Should -Be (Get-Item $p).Length
        }
        It 'DryRun never calls Slack even on a problem' {
            $r = Invoke-BackupCheck -Type daily -BackupDir $script:dir -StateFile $script:sf -WebhookUrl 'http://x' -ServerName 'SQL01' -FreshnessHours 26 -Now $script:now -DryRun
            $r.Alert | Should -Be $true
            Should -Invoke Send-SlackAlert -Times 0
        }
    It 'sends Slack alert on a zero-byte file and does NOT overwrite a prior good size' {
        Write-State -StateFile $script:sf -State @{ daily = @{ size = 5000; checkedAt = 'x' } }
        $p = Join-Path $script:dir 'backup.daily.Sun.rar'; New-Item -ItemType File -Path $p | Out-Null
        (Get-Item $p).LastWriteTime = [datetime]'2026-06-08T00:15:00'
        $r = Invoke-BackupCheck -Type daily -BackupDir $script:dir -StateFile $script:sf -WebhookUrl 'http://x' -ServerName 'SQL01' -FreshnessHours 26 -Now $script:now
        $r.Issues | Should -Contain 'zero'
        Should -Invoke Send-SlackAlert -Times 1
        [long](Read-State -StateFile $script:sf)['daily'].size | Should -Be 5000
    }
    It 'DryRun does not write a state file' {
        $p = Join-Path $script:dir 'backup.daily.Sun.rar'; 'hello' | Set-Content $p
        (Get-Item $p).LastWriteTime = [datetime]'2026-06-08T00:15:00'
        Invoke-BackupCheck -Type daily -BackupDir $script:dir -StateFile $script:sf -WebhookUrl 'http://x' -ServerName 'SQL01' -FreshnessHours 26 -Now $script:now -DryRun | Out-Null
        Test-Path $script:sf | Should -Be $false
    }
    It 'on internal error sends a Slack alert and returns an error result' {
        Mock -CommandName Test-BackupHealth -MockWith { throw 'boom' }
        $p = Join-Path $script:dir 'backup.daily.Sun.rar'; 'hello' | Set-Content $p
        $r = Invoke-BackupCheck -Type daily -BackupDir $script:dir -StateFile $script:sf -WebhookUrl 'http://x' -ServerName 'SQL01' -FreshnessHours 26 -Now $script:now
        $r.Alert | Should -Be $true
        $r.Issues | Should -Contain 'error'
        Should -Invoke Send-SlackAlert -Times 1
    }
    It 'on internal error with Slack failure falls back to the event log' {
        Mock -CommandName Test-BackupHealth -MockWith { throw 'boom' }
        Mock -CommandName Send-SlackAlert -MockWith { throw 'slack down' }
        $p = Join-Path $script:dir 'backup.daily.Sun.rar'; 'hello' | Set-Content $p
        $r = Invoke-BackupCheck -Type daily -BackupDir $script:dir -StateFile $script:sf -WebhookUrl 'http://x' -ServerName 'SQL01' -FreshnessHours 26 -Now $script:now
        $r.Issues | Should -Contain 'error'
        Should -Invoke Write-EventLogFallback -Times 1
    }
    }
}
