#Requires -Modules Pester
# Start-up without the ConfigMgr console: the message is plain text, the call
# returns $false, and no raw exception reaches the user on the not-found path.
# The branch for a module that is found but fails to import logs the caught error in the
# vendored SuiteCommon. That text is not covered here; the fix belongs in app-packager-suite.

BeforeAll {
    . "$PSScriptRoot\TestHelpers.ps1"
    Import-AppModule
}

Describe 'Connect-CMSite without the ConfigMgr module' {
    BeforeEach {
        $script:logged = [System.Collections.ArrayList]::new()
        Mock Write-Log { [void]$script:logged.Add(@{ Message = $Message; Level = $Level }) } -ModuleName SuiteCommon
        Mock Get-Module { $null } -ModuleName SuiteCommon -ParameterFilter { $Name -eq 'ConfigurationManager' }
        Mock Resolve-ConfigurationManagerModulePath { $null } -ModuleName SuiteCommon
    }

    It 'returns false and logs a plain error when no console is installed' {
        Connect-CMSite -SiteCode 'MCM' -SMSProvider 'cm01.contoso.com' | Should -BeFalse
        $script:logged.Count | Should -Be 1
        $script:logged[0].Level | Should -Be 'ERROR'
        $script:logged[0].Message | Should -Be 'ConfigurationManager module not found. Ensure the CM console is installed.'
    }

    It 'returns false when the given module path does not exist' {
        Connect-CMSite -SiteCode 'MCM' -SMSProvider 'cm01' -CMModulePath (Join-Path $TestDrive 'nope\ConfigurationManager.psd1') | Should -BeFalse
        $script:logged[0].Message | Should -BeLike 'ConfigurationManager module not found*'
    }

    It 'writes no PowerShell error text such as a stack trace or exception type' {
        $null = Connect-CMSite -SiteCode 'MCM' -SMSProvider 'cm01'
        $script:logged[0].Message | Should -Not -Match 'Exception|at <ScriptBlock>|CategoryInfo|FullyQualifiedErrorId'
    }

    It 'reports not connected afterwards' {
        $null = Connect-CMSite -SiteCode 'MCM' -SMSProvider 'cm01'
        Test-CMConnection | Should -BeFalse
        Get-CMConnectionInfo | Should -BeNullOrEmpty
    }

}
