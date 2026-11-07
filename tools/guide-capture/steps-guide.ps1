Remove-Item (Join-Path $appDir 'SiteHygiene.suppressed.json') -ErrorAction SilentlyContinue
Remove-Item (Join-Path $appDir 'SiteHygiene.suppressions.json') -ErrorAction SilentlyContinue
$win = Start-App 'start-sitehygiene.ps1' 'Site Hygiene'
Size-Win $win 1440 900
$win = Find-Top 'Site Hygiene' 10
function Idle([string]$id = 'btnScan', [int]$sec = 600) { Start-Sleep -Seconds 2; $null = Wait-Until { $b = Get-El $win $id -Quiet; $b -and $b.Current.IsEnabled } $sec; Start-Sleep -Seconds 2 }
function Rows($grid) { @((Get-El $win $grid).FindAll('Descendants', (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::DataItem)))) }
function Pick($combo, [string]$item) { Expand-El (Get-El $win $combo); Start-Sleep -Milliseconds 500; Click-El (Find-Role $win 'ListItem' $item); Start-Sleep -Milliseconds 700 }
Section 'first run' {
  Shot $win 'start-first-run'
  Invoke-El (Get-El $win 'btnScan'); Start-Sleep -Seconds 2; Shot $win 'scan-without-connection'
  Invoke-El (Get-El $win 'btnOptions'); $d = Find-Last 'Options' 10; Shot $d 'options-connection-empty'
  Set-Text (Get-El $d 'txtSiteCode') $Capture.SiteCode; Set-Text (Get-El $d 'txtSmsProvider') $Capture.SmsProvider; Shot $d 'options-connection'
  foreach ($c in @(@('btnCatScope', 'options-scan'), @('btnCatLive', 'options-live'), @('btnCatAlerts', 'options-alerts'), @('btnCatAbout', 'options-about'))) { Invoke-El (Get-El $d $c[0]); Start-Sleep -Milliseconds 600; Shot $d $c[1] }
  Invoke-El (Get-El $d 'btnOk'); Start-Sleep -Seconds 1
}
Section 'scan' {
  Invoke-El (Get-El $win 'btnScan'); Start-Sleep -Seconds 4; Shot $win 'scan-running'
  Idle; Invoke-El (Get-El $win 'btnViewFindings'); Start-Sleep -Seconds 1; Shot $win 'findings'
}
Section 'findings detail' {
  $r = Rows 'gridFindings'; Select-El $r[1]; Start-Sleep -Milliseconds 800; Shot $win 'finding-with-fix'
  Select-El $r[0]; Start-Sleep -Milliseconds 800; Shot $win 'finding-error-no-fix'
}
Section 'suppress' {
  $r = Rows 'gridFindings'; Select-El $r[3]; Start-Sleep -Milliseconds 500; Invoke-El (Get-El $win 'btnSuppress'); Start-Sleep -Seconds 1; Shot $win 'finding-suppressed'
  Toggle-El (Get-El $win 'chkShowSuppressed'); Start-Sleep -Seconds 1; Shot $win 'show-suppressed'
  $r = Rows 'gridFindings'; foreach ($x in $r) { try { Select-El $x } catch { continue }; if ((Get-El $win 'btnUnsuppress').Current.IsEnabled) { Invoke-El (Get-El $win 'btnUnsuppress'); break } }
  Start-Sleep -Seconds 1; Toggle-El (Get-El $win 'chkShowSuppressed'); Shot $win 'after-unsuppress'
}
Section 'run fix dialog' {
  # The dialog is captured and cancelled. The guide never confirms a fix.
  $r = Rows 'gridFindings'; foreach ($x in $r) { Select-El $x; Start-Sleep -Milliseconds 500; if ((Get-El $win 'btnRunFix').Current.IsEnabled) { break } }
  Invoke-El (Get-El $win 'btnRunFix'); Start-Sleep -Seconds 2
  Shot $win 'run-fix-confirm'
  Invoke-El (Get-El $win 'No')
  Start-Sleep -Seconds 2; Shot $win 'after-fix-cancel'
}
Section 'relationships' {
  Invoke-El (Get-El $win 'btnViewRelationships'); Start-Sleep -Seconds 2; Shot $win 'relationships-inventory'
  $r = Rows 'gridRelationships'; if ($r.Count) { Select-El $r[0]; Start-Sleep -Milliseconds 800; Shot $win 'relationships-detail' }
  Select-El (Find-Role $win 'TabItem' 'Tree'); Start-Sleep -Seconds 1; Shot $win 'relationships-tree'
  Select-El (Find-Role $win 'TabItem' 'Inventory'); Start-Sleep -Milliseconds 600
  Pick 'cboRelKind' 'Dependency'; Shot $win 'relationships-filter-kind'; Pick 'cboRelKind' 'All kinds'
}
Section 'summary' { Invoke-El (Get-El $win 'btnViewSummary'); Start-Sleep -Seconds 2; Shot $win 'summary'; Log ('dataset notes: ' + (Get-ElText (Get-El $win 'txtDatasetNotes'))) }
Section 'exports' {
  Invoke-El (Get-El $win 'btnViewFindings'); Start-Sleep -Seconds 1
  Invoke-El (Get-El $win 'btnExportCsv'); File-Dialog $null $null; Shot $win 'findings-exported'
  Invoke-El (Get-El $win 'btnExportHtml'); File-Dialog $null $null; Start-Sleep -Seconds 1
}
foreach ($v in @(@('Deployments', 'deployments'), @('Content', 'content'), @('DPs', 'dps'), @('Clients', 'clients-no-sql'), @('Inactive', 'inactive-no-sql'), @('Site', 'site-health'))) {
  Section ('live ' + $v[0]) {
    Invoke-El (Get-El $win ('btnView' + $v[0])); Start-Sleep -Seconds 2; Shot $win ($v[1] + '-before')
    Invoke-El (Get-El $win 'btnRefreshAll'); Idle 'btnRefreshAll' 180; Shot $win $v[1]
    $gid = @{ Deployments = 'gridDeploy'; Content = 'gridContent'; DPs = 'gridDPs'; Clients = 'gridClients'; Inactive = 'gridInactive'; Site = 'gridSite' }[$v[0]]
    $r = Rows $gid; if ($r.Count) { Select-El $r[0]; Start-Sleep -Milliseconds 800; Shot $win ($v[1] + '-detail') }
  }
}
Section 'trends' {
  Invoke-El (Get-El $win 'btnViewTrends'); Start-Sleep -Seconds 2; Shot $win 'trends'
  Expand-El (Get-El $win 'cboTrendMetric'); Start-Sleep -Milliseconds 500; Shot $win 'trends-metric-list' -Hover; Collapse-El (Get-El $win 'cboTrendMetric')
  Expand-El (Get-El $win 'cboTrendRange'); Start-Sleep -Milliseconds 500; Shot $win 'trends-range-list' -Hover; Collapse-El (Get-El $win 'cboTrendRange')
}
Section 'pause' { Invoke-El (Get-El $win 'btnPauseResume'); Start-Sleep -Seconds 1; Shot $win 'auto-refresh-paused'; Invoke-El (Get-El $win 'btnPauseResume') }
Section 'light' {
  Toggle-El (Get-El $win 'toggleTheme'); Start-Sleep -Seconds 1
  foreach ($v in @(@('Findings', 'light-findings'), @('Relationships', 'light-relationships'), @('Summary', 'light-summary'), @('Deployments', 'light-deployments'), @('Trends', 'light-trends'))) { Invoke-El (Get-El $win ('btnView' + $v[0])); Start-Sleep -Seconds 2; Shot $win $v[1] }
  Invoke-El (Get-El $win 'btnOptions'); $d = Find-Last 'Options' 10; Shot $d 'light-options'; Focus-Win $d; Send-Keys '{ESC}'; Start-Sleep -Seconds 1
  Toggle-El (Get-El $win 'toggleTheme')
}
Section 'tab order' { Invoke-El (Get-El $win 'btnViewFindings'); Focus-Win $win; Click-El (Get-El $win 'btnViewFindings'); 1..24 | ForEach-Object { Send-Keys '{TAB}'; $f = [System.Windows.Automation.AutomationElement]::FocusedElement; Log ('tab -> ' + $f.Current.AutomationId + ' / ' + $f.Current.Name) } }
Section 'filters' {
  Set-Text (Get-El $win 'txtFilter') 'Doc Demo'; Start-Sleep -Seconds 1; Shot $win 'findings-filter-text'; Set-Text (Get-El $win 'txtFilter') ''
  Expand-El (Get-El $win 'cboCategory'); Start-Sleep -Milliseconds 500; Shot $win 'findings-category-list' -Hover; Click-El (Find-Role $win 'ListItem' 'Packages'); Start-Sleep -Seconds 1; Shot $win 'findings-category-packages'
  Pick 'cboSeverity' 'Warning'; Shot $win 'findings-severity-warning'
}
Section 'persist' { Invoke-El (Get-El $win 'btnViewSummary'); Start-Sleep -Milliseconds 600; Invoke-El (Get-El $win 'Close'); Start-Sleep -Seconds 4; $win = Start-App 'start-sitehygiene.ps1' 'Site Hygiene'; Shot $win 'start-reopen' }
Stop-App 'start-sitehygiene.ps1'
