param([string]$App)
$ErrorActionPreference = 'Stop'
$OutDir = 'C:\guide\ui\out'; New-Item -ItemType Directory $OutDir -Force | Out-Null
$appDir = Join-Path 'C:\guide' $App
. C:\guide\ui\guilib.ps1
# Settings that the orchestrator passes in (site code, SMS provider).
$Capture = Get-Content -LiteralPath C:\guide\ui\capture.json -Raw | ConvertFrom-Json
try { . C:\guide\ui\steps.ps1 } catch { Log ('ERROR: ' + $_.Exception.Message + ' @ ' + $_.ScriptStackTrace) }
finally { 'finished' | Set-Content (Join-Path $OutDir 'finished.flag') }
