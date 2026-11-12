<#
.SYNOPSIS
    Regenerates every image of the user guide with one command.

.DESCRIPTION
    Copies this app to a lab computer, runs the capture steps in an interactive
    session of a lab account (scheduled task, interactive logon), copies the PNG
    files back, and removes the task and the copy. Only the images that already
    exist in docs\images are replaced. Everything of the capture is in the folder
    C:\guide\<app> and in the task GuideShots-<app>. The script never changes the
    folder C:\guide itself, a file of another app or another task.

    The lab computer needs a Configuration Manager console, a reachable SMS
    Provider and PowerShell remoting for the account in the credential script.
    The scan and the Live views only read. The Run Fix dialog is opened and
    cancelled. The capture never confirms a fix.

.PARAMETER CredentialScript
    A script that sets $LabCredential (a PSCredential). Keep it outside the repository.

.PARAMETER Target
    The lab computer name or address.

.PARAMETER AddNew
    Also copy images that are not in docsimages yet. Use it for the first capture of a new page.

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
    [int]$Minutes = 15,
    [switch]$AddNew
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = (Resolve-Path (Join-Path $here '..\..')).Path
$app = Split-Path $repo -Leaf
$images = Join-Path $repo 'docs\images'
$base = "C:\guide\$app"
$taskName = "GuideShots-$app"
. $CredentialScript
$prefs = @{ SiteCode = $SiteCode; SMSProvider = $SmsProvider } | ConvertTo-Json
$captureJson = @{ SiteCode = $SiteCode; SmsProvider = $SmsProvider } | ConvertTo-Json
$failed = New-Object System.Collections.Generic.List[string]
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('guide-capture-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp | Out-Null
$session = New-PSSession -ComputerName $Target -Credential $LabCredential
try {
    foreach ($run in @(@{ Steps = 'steps-guide.ps1'; Prefs = $false }, @{ Steps = 'steps-console-missing.ps1'; Prefs = $true })) {
        $dest = "$base\$app"
        Invoke-Command $session { param($b) Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*$b\*" -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }; Start-Sleep -Seconds 2; if (Test-Path $b) { Remove-Item $b -Recurse -Force }; New-Item -ItemType Directory "$b\$($using:app)", "$b\ui" -Force | Out-Null } -ArgumentList $base
        foreach ($item in Get-ChildItem -LiteralPath $repo -Force | Where-Object { $_.Name -notin '.git', '.claude', '.github', 'Logs', 'History', 'Reports', 'screenshots', 'TestResults', 'docs', 'Tests', 'tools' -and $_.Name -notlike '*.prefs.json' -and $_.Name -notlike '*.windowstate.json' -and $_.Name -notlike '*.lastscan.json' -and $_.Name -notlike '*.suppressions.json' -and $_.Name -notlike '*.local.*' -and $_.Name -notlike '*.png' }) {
            Copy-Item -LiteralPath $item.FullName -Destination "$dest\$($item.Name)" -ToSession $session -Recurse -Force
        }
        Copy-Item (Join-Path $here 'guilib.ps1') "$base\ui\guilib.ps1" -ToSession $session -Force
        Copy-Item (Join-Path $here 'main.ps1') "$base\ui\main.ps1" -ToSession $session -Force
        Copy-Item (Join-Path $here $run.Steps) "$base\ui\steps.ps1" -ToSession $session -Force
        Invoke-Command $session { param($b, $j) Set-Content "$b\ui\capture.json" $j -Encoding UTF8 } -ArgumentList $base, $captureJson
        Invoke-Command $session -ScriptBlock {
            param($a, $b, $user, $json, $task)
            if ($json) { Set-Content "$b\$a\SiteHygiene.prefs.json" $json -Encoding UTF8 }
            Remove-Item "$b\ui\out" -Recurse -Force -ErrorAction SilentlyContinue
            $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $b\ui\main.ps1 -App $a -Base $b"
            $pr = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
            Register-ScheduledTask -TaskName $task -Action $act -Principal $pr -Force | Out-Null
            Start-ScheduledTask $task
        } -ArgumentList $app, $base, $LogonUser, $(if ($run.Prefs) { $prefs } else { $null }), $taskName
        $end = (Get-Date).AddMinutes($Minutes)
        do { Start-Sleep 5; $done = Invoke-Command $session { param($b) Test-Path "$b\ui\out\finished.flag" } -ArgumentList $base } while (-not $done -and (Get-Date) -lt $end)
        if (-not $done) { throw "The capture did not finish: $($run.Steps)" }
        $out = Join-Path $tmp ([IO.Path]::GetFileNameWithoutExtension($run.Steps))
        New-Item -ItemType Directory $out | Out-Null
        Copy-Item "$base\ui\out\*" $out -FromSession $session -Recurse -Force
        $log = Join-Path $out 'run.log'
        if (Test-Path $log) { Get-Content $log | Where-Object { $_ -cmatch '^\d\d:\d\d:\d\d\s+ERROR[ :]' } | ForEach-Object { Write-Warning $_; $failed.Add($_) } }
    }
    # A failed section stops the capture before any guide image is replaced.
    if ($failed.Count) { throw ("The capture failed. No image was replaced.`n" + ($failed -join "`n")) }
    $captured = @(Get-ChildItem $tmp -Recurse -Filter *.png)
    $missing = @(Get-ChildItem $images -Filter *.png | Where-Object { $captured.Name -notcontains $_.Name } | ForEach-Object { $_.Name })
    if ($missing.Count) { throw ("The capture did not produce these guide images. No image was replaced.`n" + ($missing -join "`n")) }
    foreach ($png in $captured) {
        if ($AddNew -or (Test-Path (Join-Path $images $png.Name))) { Copy-Item $png.FullName (Join-Path $images $png.Name) -Force }
    }
}
finally {
    Invoke-Command $session { param($b, $task) Unregister-ScheduledTask $task -Confirm:$false -ErrorAction SilentlyContinue; Remove-Item $b -Recurse -Force -ErrorAction SilentlyContinue } -ArgumentList $base, $taskName
    Remove-PSSession $session
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
