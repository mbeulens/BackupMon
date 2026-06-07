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
}
