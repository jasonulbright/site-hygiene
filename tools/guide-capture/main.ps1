param([string]$App, [string]$Base)
$ErrorActionPreference = 'Stop'
# Every path sits under the Base folder of this app, so that a capture of another app on the same lab computer is never touched.
$OutDir = Join-Path $Base 'ui\out'; New-Item -ItemType Directory $OutDir -Force | Out-Null
$appDir = Join-Path $Base $App
# Record this runner in the ledger, so that the capture tool stops it by process id and never by a command-line pattern.
$me = Get-Process -Id $PID
('{0}|{1}' -f $me.Id, $me.StartTime.Ticks) | Add-Content -LiteralPath (Join-Path $PSScriptRoot 'run.pids')
. (Join-Path $Base 'ui\guilib.ps1')
# Settings that the orchestrator passes in (site code, SMS provider).
$Capture = Get-Content -LiteralPath (Join-Path $Base 'ui\capture.json') -Raw | ConvertFrom-Json
try { . (Join-Path $Base 'ui\steps.ps1') } catch { Log ('ERROR: ' + $_.Exception.Message + ' @ ' + $_.ScriptStackTrace) }
finally { 'finished' | Set-Content (Join-Path $OutDir 'finished.flag') }
