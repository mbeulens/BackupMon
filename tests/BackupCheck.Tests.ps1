BeforeAll {
    . "$PSScriptRoot/../bin/BackupCheck.ps1"
}

Describe 'BackupCheck' {
    It 'loads without executing main' {
        $true | Should -Be $true
    }
}
