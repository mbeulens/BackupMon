BeforeAll {
    . "$PSScriptRoot/../bin/BackupCheck.ps1"
}

Describe 'BackupCheck' {
    It 'loads without executing main' {
        $true | Should -Be $true
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
}
