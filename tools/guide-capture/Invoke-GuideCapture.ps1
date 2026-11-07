<#
.SYNOPSIS
    Regenerates every image of the user guide with one command.

.DESCRIPTION
    Copies this app to a lab computer, runs the capture steps in an interactive
    session of a lab account (scheduled task, interactive logon), copies the PNG
    files back, and removes the task and the copy. Only the images that already
    exist in docs\images are replaced.

    The lab computer needs a Configuration Manager console, a reachable SMS
    Provider and PowerShell remoting for the account in the credential script.
    The scan and the Live views only read. The Run Fix dialog is opened and
    cancelled. The capture never confirms a fix.

.PARAMETER CredentialScript
    A script that sets $LabCredential (a PSCredential). Keep it outside the repository.

.PARAMETER Target
    The lab computer name or address.

.PARAMETER LogonUser
    The domain account that has the interactive session on the lab computer.

.EXAMPLE
    .\tools\guide-capture\Invoke-GuideCapture.ps1 -CredentialScript C:\lab\credentials.local.ps1 -Target CLIENT01 -LogonUser contoso\labadmin
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CredentialScript,
    [Parameter(Mandatory)][string]$Target,
    [Parameter(Mandatory)][string]$LogonUser,
    [string]$SiteCode = 'MCM',
    [Parameter(Mandatory)][string]$SmsProvider,
    [int]$Minutes = 15
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = (Resolve-Path (Join-Path $here '..\..')).Path
$app = Split-Path $repo -Leaf
$images = Join-Path $repo 'docs\images'
. $CredentialScript
$prefs = @{ SiteCode = $SiteCode; SMSProvider = $SmsProvider } | ConvertTo-Json
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('guide-capture-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp | Out-Null
$session = New-PSSession -ComputerName $Target -Credential $LabCredential
try {
    foreach ($run in @(@{ Steps = 'steps-guide.ps1'; Prefs = $false }, @{ Steps = 'steps-console-missing.ps1'; Prefs = $true })) {
        $dest = "C:\guide\$app"
        Invoke-Command $session { param($d) Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*C:\guide\*' -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }; Start-Sleep -Seconds 2; if (Test-Path $d) { Remove-Item $d -Recurse -Force }; New-Item -ItemType Directory $d, 'C:\guide\ui' -Force | Out-Null } -ArgumentList $dest
        foreach ($item in Get-ChildItem -LiteralPath $repo -Force | Where-Object { $_.Name -notin '.git', '.claude', '.github', 'Logs', 'Reports', 'screenshots', 'TestResults', 'docs', 'Tests', 'tools' -and $_.Name -notlike '*.prefs.json' -and $_.Name -notlike '*.windowstate.json' -and $_.Name -notlike '*.local.*' -and $_.Name -notlike '*.png' }) {
            Copy-Item -LiteralPath $item.FullName -Destination "$dest\$($item.Name)" -ToSession $session -Recurse -Force
        }
        Copy-Item (Join-Path $here 'guilib.ps1') 'C:\guide\ui\guilib.ps1' -ToSession $session -Force
        Copy-Item (Join-Path $here 'main.ps1') 'C:\guide\ui\main.ps1' -ToSession $session -Force
        Copy-Item (Join-Path $here $run.Steps) 'C:\guide\ui\steps.ps1' -ToSession $session -Force
        Invoke-Command $session -ScriptBlock {
            param($a, $user, $json)
            if ($json) { Set-Content "C:\guide\$a\SiteHygiene.prefs.json" $json -Encoding UTF8 }
            Remove-Item C:\guide\ui\out -Recurse -Force -ErrorAction SilentlyContinue
            $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\guide\ui\main.ps1 -App $a"
            $pr = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
            Register-ScheduledTask -TaskName GuideShots -Action $act -Principal $pr -Force | Out-Null
            Start-ScheduledTask GuideShots
        } -ArgumentList $app, $LogonUser, $(if ($run.Prefs) { $prefs } else { $null })
        $end = (Get-Date).AddMinutes($Minutes)
        do { Start-Sleep 5; $done = Invoke-Command $session { Test-Path C:\guide\ui\out\finished.flag } } while (-not $done -and (Get-Date) -lt $end)
        if (-not $done) { throw "The capture did not finish: $($run.Steps)" }
        $out = Join-Path $tmp ([IO.Path]::GetFileNameWithoutExtension($run.Steps))
        New-Item -ItemType Directory $out | Out-Null
        Copy-Item 'C:\guide\ui\out\*' $out -FromSession $session -Recurse -Force
        $log = Join-Path $out 'run.log'
        if (Test-Path $log) { Get-Content $log | Where-Object { $_ -match 'ERROR' } | ForEach-Object { Write-Warning $_ } }
    }
    foreach ($png in Get-ChildItem $tmp -Recurse -Filter *.png) {
        if (Test-Path (Join-Path $images $png.Name)) { Copy-Item $png.FullName (Join-Path $images $png.Name) -Force }
    }
}
finally {
    Invoke-Command $session { Unregister-ScheduledTask GuideShots -Confirm:$false -ErrorAction SilentlyContinue; Remove-Item C:\guide -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-PSSession $session
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
