<#
.SYNOPSIS
    Lab test for the Site Hygiene write path (Run Fix). Creates ZZTEST- objects on the lab site
    server, scans for them, runs their fix scripts and removes everything.

.DESCRIPTION
    Copies the module to the site server and runs Hyg.Lab.Remote.ps1 there as a one-time scheduled
    task under the lab account. A task is needed because the module reads the SMS Provider with the
    caller's credential, and a WinRM session cannot pass that credential on to a second hop. The
    script then reads the results, removes the task and the copy, prints one line per step, and exits
    1 when a step failed. The remote script refuses to start when a ZZTEST- object exists. The lab
    credential comes from the file in -CredentialFile, which defines $LabCredential. The script never
    prints it.

.EXAMPLE
    .\Tests\Lab\Invoke-HygLab.ps1 -CredentialFile C:\path\to\lab-credentials.local.ps1

    The file must define $LabCredential, a PSCredential for the lab administrator.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification='Console harness.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification='CredentialFile is a file path, not a secret.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification='Each remote script block declares its values in a param block and receives them with -ArgumentList.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CredentialFile,
    [string]$ComputerName = 'CM01',
    [ValidatePattern('^[A-Za-z0-9]{3}$')][string]$SiteCode = 'MCM',
    [ValidatePattern('^[A-Za-z0-9.-]+$')][string]$Provider = 'CM01.CONTOSO.COM',
    [int]$TimeoutMinutes = 15
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. $CredentialFile
if (-not $LabCredential) { throw "The credential file did not define `$LabCredential." }

$session = New-PSSession -ComputerName $ComputerName -Credential $LabCredential
$remoteRoot = $null
$taskName = 'ZZTEST-SH-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$results = @()
$done = $false
$script:CleanupFailed = $false
try {
    $remoteRoot = Invoke-Command -Session $session -ScriptBlock {
        $p = Join-Path $env:SystemRoot ('Temp\ZZTEST-sh-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        $p
    }
    Copy-Item -ToSession $session -Path (Join-Path $repo 'Module') -Destination $remoteRoot -Recurse
    Copy-Item -ToSession $session -Path (Join-Path $repo 'Lib') -Destination $remoteRoot -Recurse
    Copy-Item -ToSession $session -Path (Join-Path $PSScriptRoot 'Hyg.Lab.Remote.ps1') -Destination $remoteRoot

    $plain = $LabCredential.GetNetworkCredential().Password
    $user = $LabCredential.UserName
    Invoke-Command -Session $session -ArgumentList $taskName, $remoteRoot, $SiteCode, $Provider, $user, $plain -ScriptBlock {
        param($task, $root, $site, $prov, $user, $pw)
        $wrapper = Join-Path $root 'run.ps1'
        @(
            '$ErrorActionPreference = ''Continue'''
            "& '$root\Hyg.Lab.Remote.ps1' -ModuleRoot '$root' -SiteCode '$site' -Provider '$prov' | Out-Null"
        ) | Set-Content -LiteralPath $wrapper -Encoding UTF8
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $wrapper)
        Register-ScheduledTask -TaskName $task -Action $action -User $user -Password $pw -RunLevel Highest -Force | Out-Null
        Start-ScheduledTask -TaskName $task
    }

    # The wrapper writes results.json as its last step; wait for that file.
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        Start-Sleep -Seconds 5
        $done = Invoke-Command -Session $session -ArgumentList $remoteRoot -ScriptBlock { param($root) Test-Path -LiteralPath (Join-Path $root 'results.json') }
    } while (-not $done -and (Get-Date) -lt $deadline)
    if (-not $done) {
        # Do not stop the task while its cleanup may still run: give it a grace period first.
        Write-Warning 'The lab task wrote no result before the timeout. Waiting up to 5 more minutes for its cleanup.'
        $grace = (Get-Date).AddMinutes(5)
        do {
            Start-Sleep -Seconds 5
            $done = Invoke-Command -Session $session -ArgumentList $remoteRoot -ScriptBlock { param($root) Test-Path -LiteralPath (Join-Path $root 'results.json') }
        } while (-not $done -and (Get-Date) -lt $grace)
    }
    $json = Invoke-Command -Session $session -ArgumentList $remoteRoot -ScriptBlock {
        param($root)
        $f = Join-Path $root 'results.json'
        if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Raw -Encoding UTF8 }
    }
    # Windows PowerShell 5.1 returns a JSON array as one object; the second step unrolls it.
    if ($json) { $parsed = $json | ConvertFrom-Json; $results = @($parsed | ForEach-Object { $_ }) }
    else {
        # The task died before it wrote results.json. Its per-step lines are in progress.txt: show them.
        $progress = @(Invoke-Command -Session $session -ArgumentList $remoteRoot -ScriptBlock {
                param($root)
                $f = Join-Path $root 'progress.txt'
                if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Encoding UTF8 }
            })
        $results = @($progress | ForEach-Object {
                $parts = ([string]$_) -split ' \| ', 3
                [PSCustomObject]@{ Step = $parts[1]; Ok = ($parts[0] -eq 'True'); Detail = $parts[2] }
            })
        $results += [PSCustomObject]@{ Step = 'run'; Ok = $false; Detail = 'The lab task wrote no result. The lines above are the steps that finished.' }
    }
}
finally {
    # Remove the task and the staged files only when the task finished. A task that never wrote its
    # result may still hold ZZTEST- objects; its staged files stay for inspection.
    # The task holds the lab password. A failed unregister is a failure of this run.
    # A broken session (the cause of the error, or a lost connection) is replaced by a fresh one, so the
    # cleanup still runs. The original error is not replaced: a cleanup problem is reported as a warning.
    $cleanupSession = $session
    if ($session.State -ne 'Opened') {
        try { $cleanupSession = New-PSSession -ComputerName $ComputerName -Credential $LabCredential } catch { Write-Warning "No session for the cleanup: $($_.Exception.Message). Remove the scheduled task $taskName on $ComputerName by hand."; $cleanupSession = $null; $script:CleanupFailed = $true }
    }
    if ($cleanupSession) {
        try {
            $cleanupErrors = @(Invoke-Command -Session $cleanupSession -ArgumentList $taskName, $remoteRoot, ([bool]$done) -ScriptBlock {
                    param($t, $p, $finished)
                    if ($t -like 'ZZTEST-*') {
                        try { Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue } catch { $null = $_ }
                        try { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction Stop } catch { "Could not unregister the task ${t}: $($_.Exception.Message)" }
                    }
                    if (-not $finished -and $p -like "$env:SystemRoot\Temp\ZZTEST-*" -and (Test-Path -LiteralPath (Join-Path $p 'restore.txt'))) { "Restore by hand: $(Get-Content -LiteralPath (Join-Path $p 'restore.txt'))" }
                    if ($finished -and $p -like "$env:SystemRoot\Temp\ZZTEST-*") { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
                })
            foreach ($e in $cleanupErrors) { Write-Warning $e; if ($e -notlike 'Restore by hand*') { $script:CleanupFailed = $true } }
        }
        catch { Write-Warning "The cleanup failed: $($_.Exception.Message). Remove the scheduled task $taskName on $ComputerName by hand."; $script:CleanupFailed = $true }
        if ($cleanupSession -ne $session) { Remove-PSSession $cleanupSession -ErrorAction SilentlyContinue }
    }
    if (-not $done) { Write-Warning "The lab task did not finish. Staged files are in $remoteRoot on $ComputerName. Check the site for ZZTEST- objects." }
    Remove-PSSession $session -ErrorAction SilentlyContinue
}
if ($script:CleanupFailed) { $results += [PSCustomObject]@{ Step = 'task cleanup'; Ok = $false; Detail = 'The scheduled task is still registered on the site server. Remove it by hand.' } }
foreach ($r in $results) { Write-Host ('{0} {1}  {2}' -f $(if ($r.Ok) { '[PASS]' } else { '[FAIL]' }), $r.Step, $r.Detail) }
$bad = @($results | Where-Object { -not $_.Ok })
Write-Host ('{0} steps, {1} failed' -f @($results).Count, $bad.Count)
if ($bad.Count -gt 0) { exit 1 }
