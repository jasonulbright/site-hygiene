# Test copy only: make the module path lookup return nothing, as on a computer without the console.
$f = Join-Path $appDir 'Lib\SuiteCommon\SuiteCommon.psm1'
$t = Get-Content -LiteralPath $f -Raw
$t = $t -replace '(?s)(function Resolve-ConfigurationManagerModulePath \{)', '$1 return $null;'
Set-Content -LiteralPath $f -Value $t -Encoding UTF8
Remove-Item Env:SMS_ADMIN_UI_PATH -ErrorAction SilentlyContinue
$win = Start-App 'start-sitehygiene.ps1' 'Site Hygiene'
Size-Win $win 1440 900
$win = Find-Top 'Site Hygiene' 10
Invoke-El (Get-El $win 'btnScan'); Start-Sleep -Seconds 6
Shot $win 'console-missing-scan'
Invoke-El (Get-El $win 'btnViewDeployments'); Start-Sleep -Seconds 1; Invoke-El (Get-El $win 'btnRefreshAll'); Start-Sleep -Seconds 8
Shot $win 'console-missing-refresh'
Stop-App 'start-sitehygiene.ps1'
