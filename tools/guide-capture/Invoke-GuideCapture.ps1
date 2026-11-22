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

    One capture runs at a time on a lab computer. The command takes the lock file
    C:\guide\capture.lock (text owner|pid|start) before it registers the first scheduled task and
    waits while another capture holds it. The poll loop refreshes the lock. A lock that nobody
    refreshed for 30 minutes is stale and is replaced. The command removes the lock at the end
    only when this capture took it.

    The lab computer needs a Configuration Manager console, a reachable SMS
    Provider and PowerShell remoting for the account in the credential script.
    The scan and the Live views only read. The Run Fix dialog is opened and
    cancelled. The capture never confirms a fix.

.PARAMETER CredentialScript
    A script that sets $LabCredential (a PSCredential). Keep it outside the repository.

.PARAMETER Target
    The lab computer name or address.

.PARAMETER LockWaitMinutes
    How long to wait for the capture lock of another capture before the command stops.

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
    [int]$LockWaitMinutes = 90,
    [switch]$AddNew
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
# Stops the processes that earlier runs of this tool recorded in the ledger on the lab VM (process id and start time), and nothing else.
# No process is stopped by a command-line pattern: another session may own a process that matches (vault: testing-policy, 'Process rules on a lab VM').
$stopRecorded = @'
param($ledger)
if (Test-Path -LiteralPath $ledger) {
    foreach ($line in @(Get-Content -LiteralPath $ledger)) {
        $id, $ticks = $line -split '\|', 2
        $p = Get-Process -Id ([int]$id) -ErrorAction SilentlyContinue
        if ($p -and $p.Id -ne $PID -and $p.StartTime.Ticks -eq [long]$ticks) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $ledger -Force -ErrorAction SilentlyContinue
}
'@
$repo = (Resolve-Path (Join-Path $here '..\..')).Path
# The lab folder and the task carry the repository name, not the name of the folder that this copy runs from (a worktree name showed in the images).
$app = 'site-hygiene'
$images = Join-Path $repo 'docs\images'
$base = "C:\guide\$app"
$taskName = "GuideShots-$app"
. $CredentialScript
$prefs = @{ SiteCode = $SiteCode; SMSProvider = $SmsProvider } | ConvertTo-Json
$captureJson = @{ SiteCode = $SiteCode; SmsProvider = $SmsProvider } | ConvertTo-Json
$failed = New-Object System.Collections.Generic.List[string]
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('guide-capture-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp | Out-Null
$lockPath = 'C:\guide\capture.lock'
$lockText = '{0}|{1}|{2}' -f $app, $PID, (Get-Date).ToString('o')
$haveLock = $false
$session = New-PSSession -ComputerName $Target -Credential $LabCredential
try {
    # The lock (D-16): C:\guide\capture.lock, text owner|pid|start. New-Item fails with an IOException when the file exists: busy.
    # A lock is stale only when its last write is older than 30 minutes AND its owner pid runs neither on the lab computer nor on
    # this computer. The lock of a live owner is never removed. A lock in a format this tool does not know blocks and is reported.
    # A removed lock is reported with a warning. The holder refreshes the lock in its poll loop.
    $lockEnd = (Get-Date).AddMinutes($LockWaitMinutes)
    $unknownReported = $false
    while (-not $haveLock) {
        $got = Invoke-Command $session {
            param($path, $text)
            New-Item -ItemType Directory -Path (Split-Path -Path $path -Parent) -Force | Out-Null
            try { $null = New-Item -ItemType File -Path $path -Value $text -ErrorAction Stop; 'taken' }
            catch [System.IO.IOException] {
                $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
                if (-not $item) { 'gone' }
                else {
                    $held = ([string](Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue)).Trim()
                    if ($held -notmatch '^[^|\s][^|]*\|\d+\|\d{4}-\d{2}-\d{2}T') { 'unknown: ' + $held }
                    else { 'held: {0}|{1}|{2}' -f [int]((Get-Date) - $item.LastWriteTime).TotalMinutes, [bool](Get-Process -Id ([int]($held -split '\|')[1]) -ErrorAction SilentlyContinue), $held }
                }
            }
        } -ArgumentList $lockPath, $lockText
        if ($got -eq 'taken') { $haveLock = $true; continue }
        if ($got -eq 'gone') { continue }
        if ($got -like 'unknown:*') {
            if (-not $unknownReported) { Write-Warning "The lab lock $lockPath has a format this tool does not know and blocks the capture ($got). Waiting; the lock is not removed."; $unknownReported = $true }
        }
        elseif ($got -like 'held:*') {
            $age, $aliveLab, $heldText = $got.Substring(6) -split '\|', 3
            $ownerPid = [int]($heldText -split '\|')[1]
            if ([int]$age -gt 30 -and $aliveLab -ne 'True' -and -not (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue)) {
                $removed = Invoke-Command $session { param($path, $text) if (([string](Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue)).Trim() -eq $text) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue; $true } else { $false } } -ArgumentList $lockPath, $heldText
                if ($removed) { Write-Warning "The stale lab lock $lockPath was removed ($heldText; last write $age minutes ago; owner pid $ownerPid is not running)."; continue }
            }
        }
        if ((Get-Date) -gt $lockEnd) { throw "Another capture holds $lockPath. The wait of $LockWaitMinutes minutes is over." }
        Start-Sleep -Seconds 15
    }
    foreach ($run in @(@{ Steps = 'steps-guide.ps1'; Prefs = $false }, @{ Steps = 'steps-console-missing.ps1'; Prefs = $true })) {
        $dest = "$base\$app"
        Invoke-Command $session { param($b) & ([scriptblock]::Create($using:stopRecorded)) (Join-Path $b 'ui\run.pids'); Start-Sleep -Seconds 2; if (Test-Path $b) { Remove-Item $b -Recurse -Force }; New-Item -ItemType Directory "$b\$($using:app)", "$b\ui" -Force | Out-Null } -ArgumentList $base
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
        # The poll refreshes the lock, so that a long capture never looks stale.
        do { Start-Sleep 5; $done = Invoke-Command $session { param($b) (Get-Item -LiteralPath 'C:\guide\capture.lock' -ErrorAction SilentlyContinue).LastWriteTime = Get-Date; Test-Path "$b\ui\out\finished.flag" } -ArgumentList $base } while (-not $done -and (Get-Date) -lt $end)
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
    # One pass is the check run and the capture run (D-21): the steps sample the contrast of the windows they shoot, and
    # the guide image test reads the manifest of the images that this run produced.
    $logs = @(Get-ChildItem $tmp -Recurse -Filter run.log)
    $sampleCount = 0; $warnCount = 0
    foreach ($runLog in $logs) {
        $lines = @(Get-Content $runLog.FullName)
        $sampleCount += @($lines | Where-Object { $_ -match '\sSAMPLE\s' }).Count
        $warnCount += @($lines | Where-Object { $_ -match '\sWARN\s' }).Count
    }
    # Only the images that the guide holds count as produced (an extra shot of a step stays out of the list).
    $names = @($captured | ForEach-Object { $_.Name } | Where-Object { Test-Path (Join-Path $images $_) } | Sort-Object -Unique)
    $manifest = [ordered]@{ Count = $names.Count; Images = $names } | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $here 'produced-images.json'), ($manifest -replace "`r?`n", "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Output ('Capture verdict: PASS. Images produced {0}, probe samples {1}, warnings {2}, errors 0.' -f $names.Count, $sampleCount, $warnCount)
}
finally {
    Invoke-Command $session { param($b, $task) Stop-ScheduledTask $task -ErrorAction SilentlyContinue; & ([scriptblock]::Create($using:stopRecorded)) (Join-Path $b 'ui\run.pids'); Unregister-ScheduledTask $task -Confirm:$false -ErrorAction SilentlyContinue; Remove-Item $b -Recurse -Force -ErrorAction SilentlyContinue } -ArgumentList $base, $taskName
    # Release the lock last, and only when this capture took it.
    try {
        if ($haveLock) {
            Invoke-Command $session { param($path, $text) if ((Test-Path -LiteralPath $path) -and (([string](Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue)).Trim() -eq $text)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } } -ArgumentList $lockPath, $lockText
        }
    } catch { Write-Warning "Release of the capture lock failed: $($_.Exception.Message)" }
    Remove-PSSession $session
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
