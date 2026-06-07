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
}
