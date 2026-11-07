param([string]$App)
$ErrorActionPreference = 'Stop'
$OutDir = 'C:\guide\ui\out'; New-Item -ItemType Directory $OutDir -Force | Out-Null
$appDir = Join-Path 'C:\guide' $App
. C:\guide\ui\guilib.ps1
try { . C:\guide\ui\steps.ps1 } catch { Log ('ERROR: ' + $_.Exception.Message + ' @ ' + $_.ScriptStackTrace) }
finally { 'finished' | Set-Content (Join-Path $OutDir 'finished.flag') }
