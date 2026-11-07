<#
.SYNOPSIS
    Prints the contrast violations of the main window and of the Options dialog in both
    themes, in the format of KnownContrastDefects.ps1.

.DESCRIPTION
    Run it when the window test reports a new or a fixed violation, to see the
    current list. Opens the windows off screen at 1440x900, as Window.Tests.ps1 does.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification='Console tool.')]
param()
. "$PSScriptRoot\TestHelpers.ps1"
. "$PSScriptRoot\WindowHarness.ps1"
. "$PSScriptRoot\WindowConfig.ps1"
. "$PSScriptRoot\KnownContrastDefects.ps1"
Import-AppModule
$shell = [System.IO.File]::ReadAllText((Join-Path $script:AppRoot $script:AppConfig.Shell))
$dialogXaml = [regex]::Match($shell, "(?s)@'\s*(<Controls:MetroWindow.*?)\s*'@").Groups[1].Value
$scopes = @(Get-HygieneScanScope | ForEach-Object { if ($_.Slow) { '{0} (slow)' -f $_.Title } else { $_.Title } })
try {
    foreach ($dark in $true, $false) {
        $theme = if ($dark) { 'dark' } else { 'light' }
        $main = Invoke-WpfSta -Arguments @{ Dark = $dark; W = 1440; H = 900; Config = $script:AppConfig; Findings = $script:SampleFindings } -Script $script:MainMeasureScript
        Write-Host ("== main {0}" -f $theme)
        Write-Host ((Get-ContrastViolationKey -Views @($main) | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', ')
        $dlg = Invoke-WpfSta -Arguments @{ Xaml = $dialogXaml; Dark = $dark; Scopes = $scopes } -Script $script:DialogMeasureScript
        $first = @($dlg)[0].Size
        Write-Host ("== dialog {0}" -f $theme)
        Write-Host ((Get-ContrastViolationKey -Views @($dlg | Where-Object Size -eq $first) | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', ')
    }
}
finally { Close-WpfSession }
