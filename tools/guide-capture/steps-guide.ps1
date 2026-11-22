Remove-Item (Join-Path $appDir 'SiteHygiene.suppressed.json') -ErrorAction SilentlyContinue
Remove-Item (Join-Path $appDir 'SiteHygiene.suppressions.json') -ErrorAction SilentlyContinue
$win = Start-App 'start-sitehygiene.ps1' 'Site Hygiene'
Maximize-Win $win
$win = Find-Top 'Site Hygiene' 10
function Idle([string]$id = 'btnScan', [int]$sec = 600) { Start-Sleep -Seconds 2; $null = Wait-Until { $b = Get-El $win $id -Quiet; $b -and $b.Current.IsEnabled } $sec; Start-Sleep -Seconds 2 }
function Rows($grid) { @((Get-El $win $grid).FindAll('Descendants', (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::DataItem)))) }
# Click a list item of an open combo box. A popup that is not drawn yet or that closed again is reopened up to four times.
function Click-Item($combo, [string]$item) { $li = $null; foreach ($try in 1..4) { $end = (Get-Date).AddSeconds(4); do { $li = Find-Role $win 'ListItem' $item; if ($li -and -not $li.Current.BoundingRectangle.IsEmpty) { break }; $li = $null; Start-Sleep -Milliseconds 400 } while ((Get-Date) -lt $end); if ($li) { break }; try { Collapse-El (Get-El $win $combo) } catch { $null = $_ }; Start-Sleep -Milliseconds 700; Expand-El (Get-El $win $combo); Start-Sleep -Milliseconds 700 }; if (-not $li) { throw "list item not visible: $item" }; Click-El $li; Start-Sleep -Milliseconds 700 }
function Pick($combo, [string]$item) { Expand-El (Get-El $win $combo); Start-Sleep -Milliseconds 700; Click-Item $combo $item }
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
Extra 'dark contrast samples' {
  Sample-El (Get-El $win 'btnViewFindings') 'dark sidebar view button'
  Sample-El (Get-El $win 'btnScan') 'dark inline button'
  Sample-El (Get-El $win 'btnOptions') 'dark sidebar options'
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
Section 'fix supersedence dialog' {
  # The window is captured and cancelled. The guide never confirms a fix. The lab site needs a supersedence to a deleted
  # application (check SUP-01) for this step: a missing row fails the capture.
  Invoke-El (Get-El $win 'btnViewFindings'); Start-Sleep -Seconds 1
  Set-Text (Get-El $win 'txtFilter') 'SUP-01'; Start-Sleep -Seconds 1
  $r = Rows 'gridFindings'; if (-not $r.Count) { throw 'No SUP-01 finding on the lab site for the Fix Supersedence window.' }
  Select-El $r[0]; Start-Sleep -Milliseconds 600
  Click-El (Get-El $win 'btnFixSupersedence'); $d = Find-Last 'Fix Supersedence' 20
  $null = Wait-Until { (Get-ElText (Get-El $d 'txtSummary')) -match 'will be removed|Nothing to remove|could not' } 90; Start-Sleep -Seconds 1
  Shot $d 'fix-supersedence-plan'
  Click-El (Get-El $d 'btnCancel'); Start-Sleep -Seconds 2
  Set-Text (Get-El $win 'txtFilter') ''; Start-Sleep -Milliseconds 600
}
Section 'show blockers' {
  # The window is captured and closed. The first application finding whose list holds at least one object is shot.
  Invoke-El (Get-El $win 'btnViewFindings'); Start-Sleep -Seconds 1
  Set-Text (Get-El $win 'txtFilter') 'Application'; Start-Sleep -Seconds 1
  $shot = $false
  foreach ($x in (Rows 'gridFindings' | Select-Object -First 25)) {
    try { Select-El $x } catch { continue }
    Start-Sleep -Milliseconds 400
    if (-not (Get-El $win 'btnShowBlockers').Current.IsEnabled) { continue }
    Click-El (Get-El $win 'btnShowBlockers'); $d = Find-Last 'What Blocks The Delete' 15
    $sum = Get-ElText (Get-El $d 'txtSummary')
    if ($sum -match 'blocks the delete') { Start-Sleep -Milliseconds 500; Shot $d 'show-blockers'; $shot = $true }
    Click-El (Get-El $d 'btnClose'); Start-Sleep -Seconds 1
    if ($shot) { break }
  }
  if (-not $shot) { throw 'No application finding with a blocker on the lab site for the Show Blockers window.' }
  Set-Text (Get-El $win 'txtFilter') ''; Start-Sleep -Milliseconds 600
}
Section 'relationships' {
  Invoke-El (Get-El $win 'btnViewRelationships'); Start-Sleep -Seconds 2; Shot $win 'relationships-inventory'
  $r = Rows 'gridRelationships'; if ($r.Count) { Select-El $r[0]; Start-Sleep -Milliseconds 800; Shot $win 'relationships-detail' }
  Select-El (Find-Role $win 'TabItem' 'Tree'); Start-Sleep -Seconds 1; Shot $win 'relationships-tree'
  Select-El (Find-Role $win 'TabItem' 'Inventory'); Start-Sleep -Milliseconds 600
  Pick 'cboRelKind' 'Dependency'; Shot $win 'relationships-filter-kind'; Pick 'cboRelKind' 'All Kinds'
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
    Invoke-El (Get-El $win 'btnRefreshAll'); Idle 'btnRefreshAll' 180; Start-Sleep -Seconds 7; Shot $win $v[1]
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
  Extra 'light contrast samples' {
    Sample-El (Get-El $win 'btnViewFindings') 'light sidebar view button'
    Sample-El (Get-El $win 'btnScan') 'light inline button'
    Sample-El (Get-El $win 'btnOptions') 'light sidebar options'
  }
  foreach ($v in @(@('Findings', 'light-findings'), @('Relationships', 'light-relationships'), @('Summary', 'light-summary'), @('Deployments', 'light-deployments'), @('Trends', 'light-trends'))) { Invoke-El (Get-El $win ('btnView' + $v[0])); Start-Sleep -Seconds 2; Shot $win $v[1] }
  Invoke-El (Get-El $win 'btnOptions'); $d = Find-Last 'Options' 10; Shot $d 'light-options'; Focus-Win $d; Send-Keys '{ESC}'; Start-Sleep -Seconds 1
  Toggle-El (Get-El $win 'toggleTheme')
}
Section 'tab order' { Invoke-El (Get-El $win 'btnViewFindings'); Focus-Win $win; Click-El (Get-El $win 'btnViewFindings'); 1..24 | ForEach-Object { Send-Keys '{TAB}'; $f = [System.Windows.Automation.AutomationElement]::FocusedElement; Log ('tab -> ' + $f.Current.AutomationId + ' / ' + $f.Current.Name) } }
Section 'filters' {
  Set-Text (Get-El $win 'txtFilter') 'Doc Demo'; Start-Sleep -Seconds 1; Shot $win 'findings-filter-text'; Set-Text (Get-El $win 'txtFilter') ''
  Expand-El (Get-El $win 'cboCategory'); Start-Sleep -Milliseconds 500; Shot $win 'findings-category-list' -Hover; Click-Item 'cboCategory' 'Packages'; Start-Sleep -Seconds 1; Shot $win 'findings-category-packages'
  Pick 'cboSeverity' 'Warning'; Shot $win 'findings-severity-warning'
}
Section 'persist' { Invoke-El (Get-El $win 'btnViewSummary'); Start-Sleep -Milliseconds 600; Invoke-El (Get-El $win 'Close'); Start-Sleep -Seconds 4; $win = Start-App 'start-sitehygiene.ps1' 'Site Hygiene'; Shot $win 'start-reopen' }
Section 'site options' { Invoke-El (Get-El $win 'btnOptions'); $d = Find-Last 'Options' 10; Shot $d 'options-connection-site'; Invoke-El (Get-El $d 'btnCancel'); Start-Sleep -Seconds 1 }
Stop-App 'start-sitehygiene.ps1'
