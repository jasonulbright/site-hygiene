<#
.SYNOPSIS
    Main window of Site Hygiene, a scanner, repair tool, and live monitor for Configuration Manager sites.

.DESCRIPTION
    Sidebar navigation in two groups. Scan: Findings, Relationships,
    Summary. Live: Deployments, Content, Distribution Points, Client
    Health, Inactive Devices, Site Health, Trends. An Options modal holds
    the connection, scan scope, refresh, and alert settings.

    A scan is read-only: every finding shows its evidence, a
    recommendation, and the exact PowerShell a fix would run. Run Fix
    executes that script only after a confirmation dialog that shows it.
    The Live views read current site status on demand and on a timer;
    they never create findings and never mutate the site.

    Requirements:
      - PowerShell 5.1
      - .NET Framework 4.7.2+
      - MahApps.Metro DLLs in .\Lib\
      - SiteHygieneCommon module under .\Module\ (loads .\Lib\SuiteCommon\)
      - Configuration Manager console (provides Get-CMApplication and other cmdlets)
      - SqlServer module (Invoke-Sqlcmd) for the Client Health and
        Inactive Devices views; optional

.NOTES
    ScriptName : start-sitehygiene.ps1
    Version    : 2026.11.20.0042
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification='PS51-WPF-001..003: $global: survives closure scope-strip.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification='WPF event handler scriptblocks bind positional sender/args ($s, $e).')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$__txDir = Join-Path $PSScriptRoot 'Logs'
try {
    if (-not (Test-Path -LiteralPath $__txDir)) { New-Item -ItemType Directory -Path $__txDir -Force | Out-Null }
    $__tx = Join-Path $__txDir ('SiteHygiene-startup-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Start-Transcript -LiteralPath $__tx -Force | Out-Null
} catch { $null = $_ }

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $psExe = (Get-Process -Id $PID).Path
    $fwd   = @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',$PSCommandPath)
    Start-Process -FilePath $psExe -ArgumentList $fwd | Out-Null
    try { Stop-Transcript | Out-Null } catch { $null = $_ }
    exit 0
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$libDir = Join-Path $PSScriptRoot 'Lib'
if (-not (Test-Path -LiteralPath $libDir)) { throw "Lib/ directory not found at: $libDir." }
Get-ChildItem -LiteralPath $libDir -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
[void][System.Reflection.Assembly]::LoadFrom((Join-Path $libDir 'Microsoft.Xaml.Behaviors.dll'))
[void][System.Reflection.Assembly]::LoadFrom((Join-Path $libDir 'ControlzEx.dll'))
[void][System.Reflection.Assembly]::LoadFrom((Join-Path $libDir 'MahApps.Metro.dll'))

$__modulePath = Join-Path $PSScriptRoot 'Module\SiteHygieneCommon.psd1'
if (-not (Test-Path -LiteralPath $__modulePath)) { throw "Shared module not found at: $__modulePath" }
Import-Module -Name $__modulePath -Force -DisableNameChecking
# Single version source: the module manifest. Every UI surface (title-bar
# version, About pane) renders from this value.
$script:AppVersion = [string](Import-PowerShellDataFile -LiteralPath $__modulePath).ModuleVersion

$script:ToolLogPath = Join-Path $__txDir ('SiteHygiene-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Initialize-Logging -LogPath $script:ToolLogPath

$__oldPaths = Get-HygieneSitePath -Site ([pscustomobject]@{ Active = $false }) -ToolRoot $PSScriptRoot
$global:PrefsPath = $__oldPaths.PrefsPath
$global:HistoryPath = $__oldPaths.HistoryPath

# A retired ConfigMgr Health Dashboard install leaves its settings and
# history either where the suite installer parked them or in the sibling
# folder of a side-by-side layout. Import fills gaps only, before the
# site is resolved, so the first start for a site copies the imported files too.
foreach ($legacyRoot in @((Join-Path $PSScriptRoot 'legacy\mecm-health-dashboard'), (Join-Path (Split-Path $PSScriptRoot -Parent) 'mecm-health-dashboard'))) {
    if (Test-Path -LiteralPath $legacyRoot) {
        $null = Import-HygieneLegacyDashboardState -LegacyRoot $legacyRoot -PrefsPath $global:PrefsPath -HistoryPath $global:HistoryPath
    }
}

# The site (Q-112f): the launcher chooses it. The first start for a site copies the old data of this tool into
# sites\<SITE>\tools\site-hygiene and keeps the old files. With no site the tool keeps its old paths.
$script:Site = Resolve-SuiteToolSite -Tool 'site-hygiene' -ToolRoot $PSScriptRoot -LegacyPrefsPath $global:PrefsPath
$__sitePaths = Get-HygieneSitePath -Site $script:Site -ToolRoot $PSScriptRoot -Create
$global:HistoryPath  = $__sitePaths.HistoryPath
$global:SuppressPath = $__sitePaths.SuppressPath
$global:LastScanPath = $__sitePaths.LastScanPath
$script:ReportsDir   = $__sitePaths.ReportsDir

function Get-ShPreferences {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns the full preferences hashtable by design.')]
    param()
    return Read-HygienePreference -Path $global:PrefsPath -Site $script:Site
}
function Save-ShPreferences {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Writes the full preferences hashtable by design.')]
    param([Parameter(Mandatory)][hashtable]$Prefs)
    $null = Save-HygienePreference -Path $global:PrefsPath -Prefs $Prefs -Site $script:Site
}
$global:Prefs = Get-ShPreferences

function Get-ShSuppressedKeys {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns the full suppression key set by design.')]
    param()
    $stored = Read-SuiteSettings -Path $global:SuppressPath -Defaults @{ Keys = @() }
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    # The indexer, not .Keys: the settings hashtable holds an entry named Keys.
    foreach ($k in @($stored['Keys'])) {
        if (-not [string]::IsNullOrWhiteSpace([string]$k)) { [void]$set.Add([string]$k) }
    }
    # Comma-wrapped: a bare return would unroll the HashSet into strings.
    return ,$set
}
function Save-ShSuppressedKeys {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Writes the full suppression key set by design.')]
    param([Parameter(Mandatory)]$KeySet)
    $null = Save-SuiteSettings -Path $global:SuppressPath -Settings @{ Keys = @($KeySet) }
}
$script:SuppressedKeys = Get-ShSuppressedKeys

$xamlPath = Join-Path $PSScriptRoot 'MainWindow.xaml'
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

$txtAppTitle        = $window.FindName('txtAppTitle')
$txtVersion         = $window.FindName('txtVersion')
$txtThemeLabel      = $window.FindName('txtThemeLabel')
$toggleTheme        = $window.FindName('toggleTheme')

$btnViewFindings      = $window.FindName('btnViewFindings')
$btnViewRelationships = $window.FindName('btnViewRelationships')
$btnViewSummary       = $window.FindName('btnViewSummary')
$btnViewDeployments   = $window.FindName('btnViewDeployments')
$btnViewContent       = $window.FindName('btnViewContent')
$btnViewDPs           = $window.FindName('btnViewDPs')
$btnViewClients       = $window.FindName('btnViewClients')
$btnViewInactive      = $window.FindName('btnViewInactive')
$btnViewSite          = $window.FindName('btnViewSite')
$btnViewTrends        = $window.FindName('btnViewTrends')
$btnOptions           = $window.FindName('btnOptions')

$txtModuleTitle    = $window.FindName('txtModuleTitle')
$txtModuleSubtitle = $window.FindName('txtModuleSubtitle')

$btnScan            = $window.FindName('btnScan')
$btnRefreshAll      = $window.FindName('btnRefreshAll')
$btnPauseResume     = $window.FindName('btnPauseResume')
$btnSuppress        = $window.FindName('btnSuppress')
$btnUnsuppress      = $window.FindName('btnUnsuppress')
$btnRunFix          = $window.FindName('btnRunFix')
$btnFixSupersedence = $window.FindName('btnFixSupersedence')
$btnShowBlockers = $window.FindName('btnShowBlockers')
$chkShowSuppressed  = $window.FindName('chkShowSuppressed')
$txtSuppressCount   = $window.FindName('txtSuppressCount')
$txtFilter          = $window.FindName('txtFilter')
$cboCategory        = $window.FindName('cboCategory')
$cboSeverity        = $window.FindName('cboSeverity')
$cboRelKind         = $window.FindName('cboRelKind')
$cboRelStatus       = $window.FindName('cboRelStatus')
$cboStatus          = $window.FindName('cboStatus')
$btnExportCsv       = $window.FindName('btnExportCsv')
$btnExportHtml      = $window.FindName('btnExportHtml')
$btnCopySummary     = $window.FindName('btnCopySummary')

$viewFindings      = $window.FindName('viewFindings')
$viewRelationships = $window.FindName('viewRelationships')
$viewSummary       = $window.FindName('viewSummary')
$viewDeployments   = $window.FindName('viewDeployments')
$viewContent       = $window.FindName('viewContent')
$viewDPs           = $window.FindName('viewDPs')
$viewClients       = $window.FindName('viewClients')
$viewInactive      = $window.FindName('viewInactive')
$viewSite          = $window.FindName('viewSite')
$viewTrends        = $window.FindName('viewTrends')

$gridFindings          = $window.FindName('gridFindings')
$txtFindingDetail      = $window.FindName('txtFindingDetail')
$gridRelationships     = $window.FindName('gridRelationships')
$treeRelationships     = $window.FindName('treeRelationships')
$txtRelationshipDetail = $window.FindName('txtRelationshipDetail')
$gridSummary           = $window.FindName('gridSummary')
$txtDatasetNotes       = $window.FindName('txtDatasetNotes')

$gridDeploy   = $window.FindName('gridDeploy');   $txtDeployDetail   = $window.FindName('txtDeployDetail')
$gridContent  = $window.FindName('gridContent');  $txtContentDetail  = $window.FindName('txtContentDetail')
$gridDPs      = $window.FindName('gridDPs');      $txtDPDetail       = $window.FindName('txtDPDetail')
$gridClients  = $window.FindName('gridClients');  $txtClientDetail   = $window.FindName('txtClientDetail')
$gridInactive = $window.FindName('gridInactive'); $txtInactiveDetail = $window.FindName('txtInactiveDetail')
$gridSite     = $window.FindName('gridSite');     $txtSiteDetail     = $window.FindName('txtSiteDetail')

$cboTrendMetric  = $window.FindName('cboTrendMetric')
$cboTrendRange   = $window.FindName('cboTrendRange')
$canvasTrend     = $window.FindName('canvasTrend')
$txtTrendEmpty   = $window.FindName('txtTrendEmpty')
$txtTrendSummary = $window.FindName('txtTrendSummary')

$progressOverlay  = $window.FindName('progressOverlay')
$txtProgressTitle = $window.FindName('txtProgressTitle')
$txtProgressStep  = $window.FindName('txtProgressStep')
$btnCancelScan    = $window.FindName('btnCancelScan')

$lblLogOutput = $window.FindName('lblLogOutput')
$txtLog       = $window.FindName('txtLog')
$txtStatus    = $window.FindName('txtStatus')

if ($txtVersion) { $txtVersion.Text = "v$script:AppVersion" }
$null = $txtAppTitle

function Add-LogLine {
    # -FromBackground: the background runspace already wrote the line to the
    # log file; only the pane and the console still need it.
    param([Parameter(Mandatory)][string]$Message, [switch]$FromBackground, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    if ($FromBackground) { Write-Host $Message; $Message = $Message -replace '^\[[^\]]+\]\s*(?:\[(?:INFO |DEBUG|WARN |ERROR)\]\s*)?', '' }
    else { Write-Log $Message -Level $Level }
    $ts = (Get-Date).ToString('HH:mm:ss')
    $line = '{0}  {1}' -f $ts, $Message
    if ([string]::IsNullOrWhiteSpace($txtLog.Text)) { $txtLog.Text = $line }
    else { $txtLog.AppendText([Environment]::NewLine + $line) }
    $txtLog.ScrollToEnd()
}

function Set-StatusText {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Updates an in-window TextBlock only.')]
    param([Parameter(Mandatory)][string]$Text)
    $txtStatus.Text = $Text
}

function Sync-FooterSite {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Updates an in-window TextBlock only.')]
    param()
    try { Update-SuiteFooter -Window $window -SiteCode ([string]$global:Prefs.SiteCode) -SiteServer ([string]$global:Prefs.SMSProvider) }
    catch { Write-Log ('Footer: {0}' -f $_.Exception.Message) -Level ERROR -Quiet; Add-LogLine 'The footer failed. The log file has the details.' }
}

# === Title-bar drag fallback (PS51-WPF-033): SuiteCommon owns the hook ===
Install-TitleBarDragFallback -Window $window

# === Theme (palette, sidebar, title bar, dialogs: SuiteCommon) ===
[void][ControlzEx.Theming.ThemeManager]::Current.ChangeTheme($window, 'Dark.Steel')

$script:ViewButtons = @(
    @{ Name = 'Findings';      Button = $btnViewFindings }
    @{ Name = 'Relationships'; Button = $btnViewRelationships }
    @{ Name = 'Summary';       Button = $btnViewSummary }
    @{ Name = 'Deployments';   Button = $btnViewDeployments }
    @{ Name = 'Content';       Button = $btnViewContent }
    @{ Name = 'DPs';           Button = $btnViewDPs }
    @{ Name = 'Clients';       Button = $btnViewClients }
    @{ Name = 'Inactive';      Button = $btnViewInactive }
    @{ Name = 'Site';          Button = $btnViewSite }
    @{ Name = 'Trends';        Button = $btnViewTrends }
)
$script:ScanViews = @('Findings', 'Relationships', 'Summary')
$script:LiveViews = @('Deployments', 'Content', 'DPs', 'Clients', 'Inactive', 'Site', 'Trends')
$script:ActiveView = 'Findings'

# Every button of the main window takes the same themed style. SuiteCommon paints them: blue with white text in the light theme, dark in the dark theme.
$script:WorkflowButtons = @($btnScan, $btnRefreshAll, $btnPauseResume, $btnSuppress, $btnUnsuppress, $btnRunFix, $btnFixSupersedence, $btnShowBlockers, $btnExportCsv, $btnExportHtml, $btnCopySummary, $btnCancelScan)

Initialize-SuiteTheme -Window $window `
    -IsDarkGetter { [bool]$global:Prefs['DarkMode'] } `
    -ActiveViewGetter { $script:ActiveView } `
    -ViewButtons $script:ViewButtons `
    -OptionsButton $btnOptions `
    -WorkflowButtons $script:WorkflowButtons `
    -OptionsButtons @($btnOptions) `
    -LogLabel $lblLogOutput

$__startIsDark = [bool]$global:Prefs['DarkMode']
$toggleTheme.IsOn = $__startIsDark
$txtThemeLabel.Text = if ($__startIsDark) { 'Dark Theme' } else { 'Light Theme' }
Update-SidebarButtonTheme
Set-ButtonTheme

$toggleTheme.Add_Toggled({
    $isDark = [bool]$toggleTheme.IsOn
    if ($isDark) { [void][ControlzEx.Theming.ThemeManager]::Current.ChangeTheme($window, 'Dark.Steel'); $txtThemeLabel.Text = 'Dark Theme' }
    else         { [void][ControlzEx.Theming.ThemeManager]::Current.ChangeTheme($window, 'Light.Blue'); $txtThemeLabel.Text = 'Light Theme' }
    $global:Prefs['DarkMode'] = $isDark
    Save-ShPreferences -Prefs $global:Prefs
    Update-SidebarButtonTheme
    Set-ButtonTheme
    Update-TitleBarBrushes
    if ($script:ActiveView -eq 'Trends') { Update-TrendChart }
    Add-LogLine ('Theme: {0}' -f $(if ($isDark) { 'dark' } else { 'light' }))
})

# === View switching ===
$script:ViewMeta = @{
    'Findings'      = @{ Title = 'Findings';             Subtitle = 'Each hygiene finding from the last scan. Select a row to see the evidence, the recommendation and the fix script.'; Watermark = 'Filter by object, evidence, or check id...' }
    'Relationships' = @{ Title = 'Relationships';        Subtitle = 'Each supersedence and dependency relationship in the application definitions, including the healthy ones. Select a row or a tree node to see the application details.'; Watermark = 'Filter by source, target, or deployment type...' }
    'Summary'       = @{ Title = 'Summary';              Subtitle = 'The finding count of each check from the last scan, and notes about the data that the scan could not read.'; Watermark = '' }
    'Deployments'   = @{ Title = 'Deployments';          Subtitle = 'Application, package, software update and task sequence deployments. Select Refresh All to load them.'; Watermark = 'Filter by deployment, collection, or type...' }
    'Content'       = @{ Title = 'Content Distribution'; Subtitle = 'Content that failed or is in progress on a distribution point. Healthy content is not shown.'; Watermark = 'Filter by content, package id, or type...' }
    'DPs'           = @{ Title = 'Distribution Points';  Subtitle = 'Each distribution point with its site, its status and its pull distribution point setting.'; Watermark = 'Filter by name or site...' }
    'Clients'       = @{ Title = 'Client Health';        Subtitle = 'The client health and the active status of each device. This view needs access to the site database.'; Watermark = 'Filter by device, health, or OS...' }
    'Inactive'      = @{ Title = 'Inactive Devices';     Subtitle = 'Devices that exceed the inactivity threshold from Options. This view needs access to the site database.'; Watermark = 'Filter by device or OS...' }
    'Site'          = @{ Title = 'Site Health';          Subtitle = 'The status of the site components and the site system roles.'; Watermark = 'Filter by name, server, or type...' }
    'Trends'        = @{ Title = 'Trends';               Subtitle = 'The history of each live metric, saved at each completed refresh. Select a metric and a range of 7, 30 or 90 days.'; Watermark = '' }
}

function Set-ControlVisible {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='In-window Visibility only.')]
    param([Parameter(Mandatory)]$Control, [Parameter(Mandatory)][bool]$Visible)
    $Control.Visibility = $(if ($Visible) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed })
}

function Set-ActiveView {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='In-window Visibility + header text only.')]
    param([Parameter(Mandatory)][ValidateSet('Findings','Relationships','Summary','Deployments','Content','DPs','Clients','Inactive','Site','Trends')][string]$View)
    $script:ActiveView = $View
    $isLive = $View -in $script:LiveViews

    Set-ControlVisible $viewFindings      ($View -eq 'Findings')
    Set-ControlVisible $viewRelationships ($View -eq 'Relationships')
    Set-ControlVisible $viewSummary       ($View -eq 'Summary')
    Set-ControlVisible $viewDeployments   ($View -eq 'Deployments')
    Set-ControlVisible $viewContent       ($View -eq 'Content')
    Set-ControlVisible $viewDPs           ($View -eq 'DPs')
    Set-ControlVisible $viewClients       ($View -eq 'Clients')
    Set-ControlVisible $viewInactive      ($View -eq 'Inactive')
    Set-ControlVisible $viewSite          ($View -eq 'Site')
    Set-ControlVisible $viewTrends        ($View -eq 'Trends')

    # The action bar follows the group: scan controls on the Scan views,
    # refresh controls on the Live views.
    Set-ControlVisible $btnScan         (-not $isLive)
    Set-ControlVisible $btnRefreshAll   $isLive
    Set-ControlVisible $btnPauseResume  $isLive
    Set-ControlVisible $btnCopySummary  $isLive
    Set-ControlVisible $cboStatus       ($isLive -and $View -ne 'Trends')
    Set-ControlVisible $cboCategory     ($View -eq 'Findings')
    Set-ControlVisible $cboSeverity     ($View -eq 'Findings')
    Set-ControlVisible $cboRelKind      ($View -eq 'Relationships')
    Set-ControlVisible $cboRelStatus    ($View -eq 'Relationships')
    Set-ControlVisible $txtFilter       ($View -notin 'Summary', 'Trends')

    $meta = $script:ViewMeta[$View]
    if ($meta) {
        $txtModuleTitle.Text    = $meta.Title
        $txtModuleSubtitle.Text = $meta.Subtitle
        [MahApps.Metro.Controls.TextBoxHelper]::SetWatermark($txtFilter, [string]$meta.Watermark)
    }
    Update-SidebarButtonTheme
    Set-ButtonTheme
    Update-Filter
    Update-StatusBarSummary
    if ($View -eq 'Trends') { Update-TrendChart }
}
$btnViewFindings.Add_Click({      Set-ActiveView -View 'Findings'      })
$btnViewRelationships.Add_Click({ Set-ActiveView -View 'Relationships' })
$btnViewSummary.Add_Click({       Set-ActiveView -View 'Summary'       })
$btnViewDeployments.Add_Click({   Set-ActiveView -View 'Deployments'   })
$btnViewContent.Add_Click({       Set-ActiveView -View 'Content'       })
$btnViewDPs.Add_Click({           Set-ActiveView -View 'DPs'           })
$btnViewClients.Add_Click({       Set-ActiveView -View 'Clients'       })
$btnViewInactive.Add_Click({      Set-ActiveView -View 'Inactive'      })
$btnViewSite.Add_Click({          Set-ActiveView -View 'Site'          })
$btnViewTrends.Add_Click({        Set-ActiveView -View 'Trends'        })

# === Crash handlers ===
$global:__crashLog = Join-Path $__txDir ('SiteHygiene-crash-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$global:__writeCrash = {
    param($Source, $Exception)
    try {
        $lines = @(('=== ' + $Source + ' @ ' + (Get-Date -Format 'o') + ' ==='))
        $lines += ('Type   : ' + $Exception.GetType().FullName)
        $lines += ('Message: ' + $Exception.Message)
        $lines += ([string]$Exception.StackTrace).Split([Environment]::NewLine)
        [System.IO.File]::AppendAllText($global:__crashLog, (($lines -join [Environment]::NewLine) + [Environment]::NewLine))
    } catch { $null = $_ }
}
$window.Dispatcher.Add_UnhandledException({
    param($s, $e)
    & $global:__writeCrash 'DispatcherUnhandledException' $e.Exception
    # A handler that runs while the host pipeline is stopping (console
    # closing, process kill during window close) throws this; nothing to
    # recover, so it is logged and swallowed.
    $e.Handled = ($e.Exception -is [System.Management.Automation.PipelineStoppedException])
})
[AppDomain]::CurrentDomain.Add_UnhandledException({ param($s, $e) & $global:__writeCrash 'AppDomainUnhandledException' ([Exception]$e.ExceptionObject) })

# === Glyphs ===
$script:Glyph = @{
    OK      = [char]0x2713
    Error   = [char]0x2717
    Warn    = [char]0x26A0
    Unknown = [char]0x22EF
}
function Get-SeverityGlyph {
    param([string]$Severity)
    switch ($Severity) {
        'Error'   { return $script:Glyph.Error }
        'Warning' { return $script:Glyph.Warn }
        default   { return [char]0x2139 }
    }
}

# === Scan state ===
$script:AllFindings      = @()
$script:SummaryRows      = @()
$script:DatasetNotes     = @()
$script:LastScanTime     = $null
$script:RelData          = $null
$script:BlockerData      = $null
$script:RelationshipRows = @()

# === Live state ===
$script:DeploymentRows = @()
$script:ContentRows    = @()
$script:DPRows         = @()
$script:ClientRows     = @()
$script:InactiveRows   = @()
$script:SiteRows       = @()
$script:DeploymentCounts = $null
$script:ContentCounts    = $null
$script:DPCounts         = $null
$script:ClientCounts     = $null
$script:InactiveCounts   = $null
$script:SiteCounts       = $null
$script:LastRefreshTime  = $null
$script:LiveConnected    = $false

# =============================================================================
# Relationships: tree and inventory.
# =============================================================================
function Add-RelationshipTreeNodes {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Builds in-window TreeViewItems.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Adds the full node set by design.')]
    param(
        [Parameter(Mandatory)]$Parent,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Nodes
    )
    foreach ($n in $Nodes) {
        $item = New-Object System.Windows.Controls.TreeViewItem
        $item.Header = ('{0}  {1}' -f $n.Glyph, $n.Label)
        $item.Tag = [int]$n.AppCIID
        [void]$Parent.Items.Add($item)
        if (@($n.Children).Count -gt 0) {
            Add-RelationshipTreeNodes -Parent $item -Nodes @($n.Children)
        }
    }
}

function Get-RelationshipStatusGlyph {
    param([string]$Status)
    switch ($Status) {
        'Healthy'         { return $script:Glyph.OK }
        'Orphaned'        { return $script:Glyph.Error }
        'Circular'        { return $script:Glyph.Error }
        'Expired Target'  { return $script:Glyph.Error }
        default           { return $script:Glyph.Warn }
    }
}

function Update-RelationshipViews {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Rebuilds the in-window TreeView and inventory rows.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Updates both relationship surfaces by design.')]
    param()
    $treeRelationships.Items.Clear()
    $script:RelationshipRows = @()
    if (-not $script:RelData) {
        $txtRelationshipDetail.Text = 'Relationship data was not collected on the last scan.'
        Update-Filter
        return
    }
    $script:RelationshipRows = @(Get-HygRelationshipInventory -RelationshipData $script:RelData | ForEach-Object {
        [pscustomobject]@{
            StatusGlyph          = $(if ($_.Circular) { $script:Glyph.Error } else { Get-RelationshipStatusGlyph -Status $_.Status })
            Kind                 = $_.Kind
            Status               = $_.Status
            Circular             = $_.Circular
            LoopFlag             = $(if ($_.Circular) { 'Yes' } else { '' })
            SourceName           = $_.SourceName
            SourceVersion        = $_.SourceVersion
            SourceDeploymentType = $_.SourceDeploymentType
            TargetName           = $_.TargetName
            TargetVersion        = $_.TargetVersion
            DependencyState      = $_.DependencyState
            ChainDepth           = $_.ChainDepth
            SourceCIID           = $_.SourceCIID
            TargetCIID           = $_.TargetCIID
            TargetModelName      = $_.TargetModelName
        }
    })

    $supNodes = @(Build-HygRelationshipTree -RelationshipData $script:RelData -Kind Supersedence)
    $depNodes = @(Build-HygRelationshipTree -RelationshipData $script:RelData -Kind Dependency)

    $supRoot = New-Object System.Windows.Controls.TreeViewItem
    $supRoot.Header = ('Supersedence Chains ({0})' -f $supNodes.Count)
    $supRoot.IsExpanded = $true
    [void]$treeRelationships.Items.Add($supRoot)
    Add-RelationshipTreeNodes -Parent $supRoot -Nodes $supNodes

    $depRoot = New-Object System.Windows.Controls.TreeViewItem
    $depRoot.Header = ('Dependency Trees ({0})' -f $depNodes.Count)
    $depRoot.IsExpanded = $true
    [void]$treeRelationships.Items.Add($depRoot)
    Add-RelationshipTreeNodes -Parent $depRoot -Nodes $depNodes
    Update-Filter
}

function Get-RelationshipAppLines {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns the detail line set for one application.')]
    param([Parameter(Mandatory)][int]$CIID)
    if ($CIID -eq 0) { return @('This node references an application that no longer exists in the site.') }
    $app = $script:RelData.Apps[$CIID]
    if (-not $app) { return @(('CI_ID {0} is not in the relationship data.' -f $CIID)) }
    $out = @($script:RelData.Relationships | Where-Object { [int]$_.FromAppCIID -eq $CIID })
    $in  = @($script:RelData.Relationships | Where-Object { [int]$_.ToAppCIID -eq $CIID })
    return @(
        ('{0}  (CI_ID {1})' -f $app.Name, $app.CI_ID),
        ('Version:        {0}' -f $app.SoftwareVersion),
        ('Manufacturer:   {0}' -f $(if ($app.Manufacturer) { $app.Manufacturer } else { '(not set)' })),
        ('Enabled:        {0}    Retired: {1}    Has content: {2}' -f $app.IsEnabled, $app.IsExpired, $app.HasContent),
        ('Outgoing:       {0} supersedence, {1} dependency' -f @($out | Where-Object { $_.Kind -eq 'Supersedence' }).Count, @($out | Where-Object { $_.Kind -eq 'Dependency' }).Count),
        ('Incoming:       {0} supersedence, {1} dependency' -f @($in | Where-Object { $_.Kind -eq 'Supersedence' }).Count, @($in | Where-Object { $_.Kind -eq 'Dependency' }).Count)
    )
}

$treeRelationships.Add_SelectedItemChanged({
    $item = $treeRelationships.SelectedItem
    if (-not $item -or -not $script:RelData -or $null -eq $item.Tag) { return }
    $ciid = 0
    try { $ciid = [int]$item.Tag } catch { return }
    $txtRelationshipDetail.Text = (Get-RelationshipAppLines -CIID $ciid) -join [Environment]::NewLine
})

$gridRelationships.Add_SelectionChanged({
    $row = $gridRelationships.SelectedItem
    if (-not $row -or -not $script:RelData) { return }
    $lines = @(('{0}: {1}{2}   [{3}]' -f $row.Kind, $row.Status, $(if ($row.Circular -and $row.Status -ne 'Circular') { ', in a loop' } else { '' }), $(if ($row.DependencyState) { $row.DependencyState } else { 'depth ' + $row.ChainDepth })), '', 'SOURCE')
    $lines += Get-RelationshipAppLines -CIID ([int]$row.SourceCIID)
    $lines += ''
    $lines += 'TARGET'
    if ([int]$row.TargetCIID -eq 0) { $lines += ('{0} no longer exists in the site.' -f $row.TargetModelName) }
    else { $lines += Get-RelationshipAppLines -CIID ([int]$row.TargetCIID) }
    $txtRelationshipDetail.Text = $lines -join [Environment]::NewLine
})

function Get-FilteredRelationshipRows {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns the filtered row set.')]
    param()
    $rows = @($script:RelationshipRows)
    $needle = ([string]$txtFilter.Text).Trim().ToLowerInvariant()
    if ($needle) {
        $rows = @($rows | Where-Object {
            ([string]$_.SourceName).ToLowerInvariant().Contains($needle) -or
            ([string]$_.TargetName).ToLowerInvariant().Contains($needle) -or
            ([string]$_.SourceDeploymentType).ToLowerInvariant().Contains($needle)
        })
    }
    $kind = Get-ComboValue -Combo $cboRelKind
    if ($kind -in 'Supersedence', 'Dependency') { $rows = @($rows | Where-Object { $_.Kind -eq $kind }) }
    $status = Get-ComboValue -Combo $cboRelStatus
    if ($status -eq 'Healthy') { $rows = @($rows | Where-Object { $_.Status -eq 'Healthy' -and -not $_.Circular }) }
    elseif ($status -eq 'Broken') { $rows = @($rows | Where-Object { $_.Status -ne 'Healthy' -or $_.Circular }) }
    return $rows
}

# =============================================================================
# Findings: filter, suppression, detail, fix.
# =============================================================================
function Get-ComboValue {
    param($Combo)
    if (-not $Combo.SelectedItem) { return 'All' }
    $item = $Combo.SelectedItem
    if ($item -is [System.Windows.Controls.ComboBoxItem]) { return [string]$item.Content }
    return [string]$item
}
function Get-FilteredFindings {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns the filtered findings set.')]
    param()
    $rows = @($script:AllFindings)
    $needle = ([string]$txtFilter.Text).Trim().ToLowerInvariant()
    if ($needle) {
        $rows = @($rows | Where-Object {
            ([string]$_.ObjectName).ToLowerInvariant().Contains($needle) -or
            ([string]$_.Evidence).ToLowerInvariant().Contains($needle) -or
            ([string]$_.CheckId).ToLowerInvariant().Contains($needle)
        })
    }
    $category = Get-ComboValue -Combo $cboCategory
    if ($category -ne 'All') { $rows = @($rows | Where-Object { $_.Category -eq $category }) }
    $severity = Get-ComboValue -Combo $cboSeverity
    if ($severity -ne 'All') { $rows = @($rows | Where-Object { $_.Severity -eq $severity }) }
    if (-not [bool]$chkShowSuppressed.IsChecked) {
        $rows = @($rows | Where-Object { -not $script:SuppressedKeys.Contains([string]$_.SuppressKey) })
    }
    return $rows
}
function Update-SuppressCount {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='In-window TextBlock update.')]
    param()
    $txtSuppressCount.Text = ('{0} key(s) suppressed' -f $script:SuppressedKeys.Count)
}

function Test-LiveRowMatch {
    param($Row, [string]$Filter)
    switch ($Filter) {
        'OK / Healthy'          { return ($Row.StatusGlyph -eq $script:Glyph.OK) }
        'Warning / In Progress' { return ($Row.StatusGlyph -eq $script:Glyph.Warn) }
        'Failed / Error'        { return ($Row.StatusGlyph -eq $script:Glyph.Error) }
        default                 { return $true }
    }
}

function Get-FilteredLiveRows {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns the filtered row set of the active live view.')]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows, [Parameter(Mandatory)][string[]]$Fields)
    $needle = ([string]$txtFilter.Text).Trim().ToLowerInvariant()
    $statusFilter = Get-ComboValue -Combo $cboStatus
    return @($Rows | Where-Object {
        $row = $_
        $hit = -not $needle
        if (-not $hit) {
            foreach ($f in $Fields) {
                $val = $row.PSObject.Properties[$f].Value
                if ($null -ne $val -and ([string]$val).ToLowerInvariant().Contains($needle)) { $hit = $true; break }
            }
        }
        $hit -and (Test-LiveRowMatch -Row $row -Filter $statusFilter)
    })
}

function Update-Filter {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Recomputes ItemsSource on the active grid.')]
    param()
    # A one-row result unrolls to a bare object, which ItemsSource rejects
    # with a conversion error; @() keeps every result a list.
    switch ($script:ActiveView) {
        'Findings'      { $gridFindings.ItemsSource = @(Get-FilteredFindings) }
        'Relationships' { $gridRelationships.ItemsSource = @(Get-FilteredRelationshipRows) }
        'Deployments'   { $gridDeploy.ItemsSource   = @(Get-FilteredLiveRows -Rows @($script:DeploymentRows) -Fields @('DeploymentName','CollectionName','DeploymentType')) }
        'Content'       { $gridContent.ItemsSource  = @(Get-FilteredLiveRows -Rows @($script:ContentRows)    -Fields @('ContentName','PackageID','ContentType')) }
        'DPs'           { $gridDPs.ItemsSource      = @(Get-FilteredLiveRows -Rows @($script:DPRows)         -Fields @('DPName','SiteCode')) }
        'Clients'       { $gridClients.ItemsSource  = @(Get-FilteredLiveRows -Rows @($script:ClientRows)     -Fields @('DeviceName','HealthState','ActiveStatus','OperatingSystem')) }
        'Inactive'      { $gridInactive.ItemsSource = @(Get-FilteredLiveRows -Rows @($script:InactiveRows)   -Fields @('DeviceName','OperatingSystem')) }
        'Site'          { $gridSite.ItemsSource     = @(Get-FilteredLiveRows -Rows @($script:SiteRows)       -Fields @('Name','MachineName','ItemType')) }
        default         { }
    }
}
$txtFilter.Add_TextChanged({ Update-Filter })
$cboCategory.Add_SelectionChanged({ Update-Filter })
$cboSeverity.Add_SelectionChanged({ Update-Filter })
$cboRelKind.Add_SelectionChanged({ Update-Filter })
$cboRelStatus.Add_SelectionChanged({ Update-Filter })
$cboStatus.Add_SelectionChanged({ Update-Filter })
$chkShowSuppressed.Add_Click({ Update-Filter })

$btnSuppress.Add_Click({
    $sel = @($gridFindings.SelectedItems)
    if ($sel.Count -eq 0) { Add-LogLine 'Suppress: select one or more findings first.'; return }
    foreach ($row in $sel) { [void]$script:SuppressedKeys.Add([string]$row.SuppressKey) }
    Save-ShSuppressedKeys -KeySet $script:SuppressedKeys
    Add-LogLine ('Suppressed {0} finding(s).' -f $sel.Count)
    Update-SuppressCount
    Update-Filter
})

$btnUnsuppress.Add_Click({
    $sel = @($gridFindings.SelectedItems)
    if ($sel.Count -eq 0) { Add-LogLine 'Unsuppress: select one or more findings first (turn on Show Suppressed to see them).'; return }
    foreach ($row in $sel) { [void]$script:SuppressedKeys.Remove([string]$row.SuppressKey) }
    Save-ShSuppressedKeys -KeySet $script:SuppressedKeys
    Add-LogLine ('Unsuppressed {0} finding(s).' -f $sel.Count)
    Update-SuppressCount
    Update-Filter
})

$gridFindings.Add_SelectionChanged({
    $row = $gridFindings.SelectedItem
    $btnFixSupersedence.IsEnabled = (@(Get-SupersedenceFixSelection).Count -gt 0)
    $btnShowBlockers.IsEnabled = ($row -and [string]$row.ObjectType -eq 'Application' -and [string]$row.ObjectId -like '*/Application_*' -and $script:BlockerData -and $script:RelData)
    if (-not $row) {
        $txtFindingDetail.Text = 'Select a finding to see its evidence, recommendation, and the fix script it would take.'
        return
    }
    $lines = @(
        ('{0}  [{1}]  {2}' -f $row.CheckId, $row.Severity, $row.ObjectName),
        ('Object type:    {0}' -f $row.ObjectType)
    )
    if ($row.ObjectId) { $lines += ('Object id:      {0}' -f $row.ObjectId) }
    $lines += ''
    $lines += ('Evidence:       {0}' -f $row.Evidence)
    $lines += ''
    $lines += ('Recommendation: {0}' -f $row.Recommendation)
    if ($row.FixScript) {
        $lines += ''
        $lines += $(if (Test-HygieneFixExecutable -FixScript $row.FixScript) { 'Fix script (Run Fix executes exactly this):' } else { 'Fix guidance (display-only, nothing to execute):' })
        $lines += ('  {0}' -f $row.FixScript)
    }
    if ($row.FixState) { $lines += ''; $lines += ('Fix state:      {0}' -f $row.FixState) }
    $txtFindingDetail.Text = $lines -join [Environment]::NewLine
    $btnRunFix.IsEnabled = (@(Get-RunnableSelection).Count -gt 0)
})

function Get-RunnableSelection {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns the runnable subset of the selection.')]
    param()
    return @($gridFindings.SelectedItems | Where-Object {
        $_.FixState -ne 'Fixed' -and (Test-HygieneFixExecutable -FixScript $_.FixScript)
    })
}

# =============================================================================
# Background runspace. One operation at a time: a scan, a fix batch, or a
# live refresh. BgKind names the running one so completion and cancel act
# on the right state.
# =============================================================================
$script:BgRunspace     = $null
$script:BgPowerShell   = $null
$script:BgInvokeHandle = $null
$script:BgState        = $null
$script:BgTimer        = $null
$script:BgGraveyard    = @()
$script:BgKind         = ''

function Initialize-BgRunspace {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Lazy-init; idempotent.')]
    param()
    if ($script:BgRunspace -and $script:BgRunspace.RunspaceStateInfo.State -eq 'Opened') { return }
    $script:BgRunspace = New-SuiteBgRunspace -ModulePath (Join-Path $PSScriptRoot 'Module\SiteHygieneCommon.psd1') -LogPath $script:ToolLogPath
}

function Dispose-BgWork {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification='Dispose semantics intentional.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Tears down ephemeral runspace plumbing.')]
    param()
    $script:BgGraveyard = @(Stop-SuiteBgWork -PowerShell $script:BgPowerShell -Timer $script:BgTimer -Graveyard $script:BgGraveyard)
    $script:BgTimer = $null
    $script:BgPowerShell = $null
    $script:BgInvokeHandle = $null
    $script:BgKind = ''
}

function Reset-BgConnection {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Discards the cached background connection.')]
    param()
    Dispose-BgWork
    Close-SuiteBgRunspace -Runspace $script:BgRunspace
    $script:BgRunspace = $null
    $script:BgState = $null
    $script:LiveConnected = $false
    $progressOverlay.Visibility = [System.Windows.Visibility]::Collapsed
    $btnScan.IsEnabled = $true
    $btnRefreshAll.IsEnabled = $true
}

function Test-BgBusy {
    param([Parameter(Mandatory)][string]$Action)
    if ($script:BgPowerShell) {
        Add-LogLine ('{0}: a {1} is still running.' -f $Action, $(if ($script:BgKind) { $script:BgKind.ToLowerInvariant() } else { 'background operation' })) -Level WARN
        return $true
    }
    return $false
}

function Read-BgInformationStream {
    # The background runspace has no console host: its Write-Log output
    # lands on the Information stream and is surfaced from here.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Drains the stream.')]
    param()
    if (-not $script:BgPowerShell) { return }
    $info = $script:BgPowerShell.Streams.Information
    while ($script:BgInfoIndex -lt $info.Count) {
        $record = $info[$script:BgInfoIndex]; $script:BgInfoIndex++
        if ($record -and $record.MessageData) { Add-LogLine ([string]$record.MessageData) -FromBackground }
    }
}

function Complete-BgInvoke {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Ends the finished pipeline.')]
    param()
    $script:BgTimer.Stop()
    Read-BgInformationStream
    try { [void]$script:BgPowerShell.EndInvoke($script:BgInvokeHandle) } catch { $null = $_ }
    try { $script:BgPowerShell.Dispose() } catch { $null = $_ }
    $script:BgPowerShell   = $null
    $script:BgInvokeHandle = $null
    $script:BgKind         = ''
}

$btnRunFix.Add_Click({
    $rows = @(Get-RunnableSelection)
    if ($rows.Count -eq 0) { return }
    if (Test-BgBusy -Action 'Run Fix') { return }

    $scriptLines = @($rows | ForEach-Object { ('[{0}] {1}' -f $_.CheckId, $_.FixScript) })
    $title = if ($rows.Count -eq 1) { ('Run Fix for {0}?' -f $rows[0].CheckId) } else { ('Run {0} Fixes?' -f $rows.Count) }
    $msg = ("This runs the following against site {0}:`r`n`r`n{1}" -f $global:Prefs.SiteCode, ($scriptLines -join "`r`n"))
    if (-not (Show-ConfirmDialog -Title $title -Message $msg -Owner $window)) { return }

    Initialize-BgRunspace
    Dispose-BgWork
    $script:BgKind = 'Fix'
    foreach ($row in $rows) { Add-LogLine ('Run Fix [{0}] {1}: {2}' -f $row.CheckId, $row.ObjectName, $row.FixScript) }
    $btnRunFix.IsEnabled = $false
    $script:BgState = [hashtable]::Synchronized(@{ Done = $false; Results = $null; ErrorMsg = $null })
    $script:BgInfoIndex = 0
    # Rows are keyed back to results by SuppressKey; the bg runspace gets
    # detached copies so it never touches WPF-bound objects.
    $findings = @($rows | ForEach-Object { [pscustomobject]@{ CheckId = $_.CheckId; ObjectName = $_.ObjectName; FixScript = $_.FixScript; SuppressKey = $_.SuppressKey } })
    $script:FixRowsByKey = @{}
    foreach ($row in $rows) { $script:FixRowsByKey[[string]$row.SuppressKey] = $row }

    $script:BgPowerShell = [powershell]::Create()
    $script:BgPowerShell.Runspace = $script:BgRunspace
    [void]$script:BgPowerShell.AddScript({
        param($SiteCode, $SMSProvider, $Findings, $State)
        try {
            if (-not (Test-CMConnection)) {
                if (-not (Connect-CMSite -SiteCode $SiteCode -SMSProvider $SMSProvider)) {
                    $State.ErrorMsg = "Failed to connect to site $SiteCode (SMS Provider $SMSProvider)."; return
                }
            }
            $results = @{}
            foreach ($f in @($Findings)) {
                $results[[string]$f.SuppressKey] = Invoke-HygieneFix -Finding $f -Confirm:$false
            }
            $State.Results = $results
        }
        catch { $State.ErrorDetail = $_.Exception.Message; $State.ErrorMsg = 'An error occurred. The log file has the details.' }
        finally { $State.Done = $true }
    }).AddArgument([string]$global:Prefs.SiteCode).AddArgument([string]$global:Prefs.SMSProvider).AddArgument($findings).AddArgument($script:BgState)

    $script:BgInvokeHandle = $script:BgPowerShell.BeginInvoke()
    $script:BgTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:BgTimer.Interval = [TimeSpan]::FromMilliseconds(150)
    $script:BgTimer.Add_Tick({
        Read-BgInformationStream
        if (-not ($script:BgState -and $script:BgState.Done)) { return }
        Complete-BgInvoke

        if ($script:BgState.ErrorMsg) {
            foreach ($row in $script:FixRowsByKey.Values) { $row.FixState = 'Failed' }
            if ($script:BgState.ErrorDetail) { Write-Log ('Run Fix failed: {0}' -f $script:BgState.ErrorDetail) -Level ERROR -Quiet }
            Add-LogLine ('Run Fix failed: {0}' -f $script:BgState.ErrorMsg) -Level ERROR
            Set-StatusText 'Fix failed - see log.'
        }
        else {
            $fixed = 0; $failed = 0
            foreach ($key in $script:FixRowsByKey.Keys) {
                $row = $script:FixRowsByKey[$key]
                $result = $script:BgState.Results[$key]
                if ($result -and $result.Success) {
                    $row.FixState = 'Fixed'; $fixed++
                    if ($result.Output) { Add-LogLine ('Fix output [{0}]: {1}' -f $row.CheckId, $result.Output) }
                }
                else {
                    $row.FixState = 'Failed'; $failed++
                    if ($result -and $result.ErrorMessage) { Write-Log ('Fix failed [{0}] {1}: {2}' -f $row.CheckId, $row.ObjectName, $result.ErrorMessage) -Level WARN -Quiet }
                    Add-LogLine ('Fix failed [{0}] {1}. {2}' -f $row.CheckId, $row.ObjectName, $(if ($result) { 'The log file has the details.' } else { 'The fix returned no result.' })) -Level WARN
                }
            }
            Add-LogLine ('Run Fix complete: {0} fixed, {1} failed. Rescan to confirm.' -f $fixed, $failed)
            Set-StatusText $(if ($failed -eq 0) { 'Fix(es) applied - rescan to confirm.' } else { 'Some fixes failed - see log.' })
        }
        $script:FixRowsByKey = @{}
        $gridFindings.Items.Refresh()
        $btnRunFix.IsEnabled = (@(Get-RunnableSelection).Count -gt 0)
    })
    $script:BgTimer.Start()
})

# =============================================================================
# Scan.
# =============================================================================
function Invoke-Scan {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Posts work to bg runspace.')]
    param()
    if (-not $global:Prefs.SiteCode -or -not $global:Prefs.SMSProvider) {
        Add-LogLine 'Scan: set the site code and the SMS Provider in Options first.' -Level WARN
        Set-StatusText 'Open Options to set the site code and the SMS Provider, then scan.'
        return
    }
    if (Test-BgBusy -Action 'Scan') { return }
    Initialize-BgRunspace
    Dispose-BgWork
    $script:BgKind = 'Scan'
    $script:BgState = [hashtable]::Synchronized(@{ Step = 'Connecting...'; Done = $false; Findings = $null; Summary = $null; Notes = $null; RelData = $null; BlockerData = $null; ErrorMsg = $null })
    $btnScan.IsEnabled = $false
    $txtProgressTitle.Text = 'Scanning...'
    $txtProgressStep.Text  = 'Connecting...'
    $progressOverlay.Visibility = [System.Windows.Visibility]::Visible

    $allScopes = @(Get-HygieneScanScope | ForEach-Object { $_.Id })
    $scopes = @(@($global:Prefs['ScanScopes']) | Where-Object { $_ -in $allScopes })
    if ($scopes.Count -eq 0) { $scopes = $allScopes }
    $script:ScanIsFull = ($scopes.Count -eq $allScopes.Count)
    $script:ScanStarted = Get-Date
    $script:BgInfoIndex = 0
    $pacing = [int]$global:Prefs['ProviderPacingMs']
    $deploymentOldDays = [int]$global:Prefs['DeploymentOldDays']
    if ($deploymentOldDays -le 0) { $deploymentOldDays = 365 }
    Add-LogLine ('Scan: site={0} provider={1} scope={2} pacing={3}ms' -f $global:Prefs.SiteCode, $global:Prefs.SMSProvider, $(if ($script:ScanIsFull) { 'everything' } else { $scopes -join ', ' }), $pacing)
    Set-StatusText 'Scanning...'

    $siteCode    = [string]$global:Prefs.SiteCode
    $smsProvider = [string]$global:Prefs.SMSProvider

    $script:BgPowerShell = [powershell]::Create()
    $script:BgPowerShell.Runspace = $script:BgRunspace
    [void]$script:BgPowerShell.AddScript({
        param($SiteCode, $SMSProvider, $State, $Scopes, $PacingMs, $DeploymentOldDays)
        try {
            if (-not (Test-CMConnection)) {
                $State.Step = "Connecting to $SiteCode..."
                $ok = Connect-CMSite -SiteCode $SiteCode -SMSProvider $SMSProvider
                if (-not $ok) { $State.ErrorMsg = "Failed to connect to site $SiteCode (SMS Provider $SMSProvider)."; return }
            }
            $datasets = @(Get-HygieneRequiredDataset -Scopes $Scopes)

            # The relationship pass runs first: its per-application XML
            # answers the task sequence install setting, which otherwise
            # costs one provider read per referenced application.
            $relData = $null
            $autoInstall = $null
            if ($datasets -contains 'Relationships') {
                $State.Step = 'Reading application definitions...'
                $relData = Get-HygieneRelationshipData -ProgressState $State
                if ($relData) { $autoInstall = $relData.AutoInstallByModel }
            }

            $data = Get-HygieneData -Datasets @($datasets | Where-Object { $_ -ne 'Relationships' }) -ProgressState $State -PacingMs $PacingMs -AutoInstallByModel $autoInstall

            $State.Step = 'Running hygiene checks...'
            $thresholds = Get-HygieneDefaultThresholds
            $thresholds.DeploymentOldDays = [int]$DeploymentOldDays
            $findings = @(Invoke-HygieneScan -Data $data -Thresholds $thresholds -RelationshipData $relData -Scopes $Scopes)

            $notes = @($data.DatasetNotes)
            if ($relData) { $notes += @($relData.DatasetNotes) }
            elseif ($datasets -contains 'Relationships') { $notes += 'Relationship data unavailable; SUP/DEP/REL and APP-04 checks were skipped.' }

            $State.Findings = $findings
            $State.Summary  = @(Get-HygieneScanSummary -Findings $findings)
            $State.Notes    = $notes
            $State.RelData  = $relData
            # The datasets that answer what blocks the delete of an application; no query is added for them.
            $State.BlockerData = [pscustomobject]@{ Applications = @($data.Applications); Deployments = @($data.Deployments); TaskSequences = @($data.TaskSequences) }
        }
        catch { $State.ErrorDetail = $_.Exception.Message; $State.ErrorMsg = 'An error occurred. The log file has the details.' }
        finally { $State.Done = $true }
    }).AddArgument($siteCode).AddArgument($smsProvider).AddArgument($script:BgState).AddArgument([string[]]$scopes).AddArgument($pacing).AddArgument($deploymentOldDays)

    $script:BgInvokeHandle = $script:BgPowerShell.BeginInvoke()
    $script:BgTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:BgTimer.Interval = [TimeSpan]::FromMilliseconds(150)
    $script:BgTimer.Add_Tick({
        if ($script:BgState) {
            $current = '{0}  [{1:mm\:ss}]' -f [string]$script:BgState.Step, ((Get-Date) - $script:ScanStarted)
            if ($txtProgressStep.Text -ne $current) { $txtProgressStep.Text = $current }
        }
        Read-BgInformationStream
        if ($script:BgState -and $script:BgState.Done) {
            Complete-BgInvoke

            if ($script:BgState.ErrorMsg) {
                $progressOverlay.Visibility = [System.Windows.Visibility]::Collapsed
                $btnScan.IsEnabled = $true
                if ($script:BgState.ErrorDetail) { Write-Log ('Scan failed: {0}' -f $script:BgState.ErrorDetail) -Level ERROR -Quiet }
                Add-LogLine ('Scan failed: {0}' -f $script:BgState.ErrorMsg) -Level ERROR
                Set-StatusText 'Scan failed.'
                return
            }

            $script:LastScanTime = Get-Date
            # A scoped scan is not comparable to the full baseline: every
            # out-of-scope finding would read as resolved, and saving it
            # would make the next full scan report them all as new.
            $previous = $(if ($script:ScanIsFull) { Read-HygieneScanResult -Path $global:LastScanPath } else { $null })
            $delta = Get-HygieneScanDelta -Findings @($script:BgState.Findings) -Previous $previous
            if ($script:ScanIsFull) { Save-HygieneScanResult -Findings @($script:BgState.Findings) -Path $global:LastScanPath }
            if (-not $script:ScanIsFull) { Add-LogLine 'Scoped scan: delta baseline left unchanged.' }
            elseif ($delta.HasBaseline) {
                Add-LogLine ('Delta vs previous scan: {0} new, {1} resolved.' -f $delta.NewKeys.Count, @($delta.Resolved).Count)
                foreach ($r in @($delta.Resolved)) { Add-LogLine ('  Resolved: [{0}] {1}' -f $r.CheckId, $r.ObjectName) }
            }
            else { Add-LogLine 'No previous scan on file; delta baseline recorded.' }
            $script:AllFindings = @($script:BgState.Findings | ForEach-Object {
                [pscustomobject]@{
                    Delta          = $(if ($delta.NewKeys.Contains((Get-HygieneSuppressionKey -Finding $_))) { 'New' } else { '' })
                    SeverityGlyph  = Get-SeverityGlyph -Severity $_.Severity
                    CheckId        = $_.CheckId
                    Severity       = $_.Severity
                    Category       = $_.Category
                    ObjectType     = $_.ObjectType
                    ObjectId       = $_.ObjectId
                    ObjectName     = $_.ObjectName
                    Evidence       = $_.Evidence
                    Recommendation = $_.Recommendation
                    FixScript      = $_.FixScript
                    FixData        = $_.FixData
                    FixState       = ''
                    SuppressKey    = Get-HygieneSuppressionKey -Finding $_
                }
            })
            $script:SummaryRows  = @($script:BgState.Summary)
            $script:DatasetNotes = @($script:BgState.Notes)
            $script:RelData      = $script:BgState.RelData
            $script:BlockerData  = $script:BgState.BlockerData
            Update-RelationshipViews

            $gridSummary.ItemsSource = $script:SummaryRows
            $txtDatasetNotes.Text = if ($script:DatasetNotes.Count -gt 0) {
                "Dataset notes:`r`n" + (($script:DatasetNotes | ForEach-Object { "  - $_" }) -join "`r`n")
            } else { 'All datasets loaded cleanly.' }

            Update-Filter
            Update-StatusBarSummary
            Sync-FooterSite
            $progressOverlay.Visibility = [System.Windows.Visibility]::Collapsed
            $btnScan.IsEnabled = $true
            Add-LogLine ('Scan complete: {0} finding(s), {1} relationship(s).' -f @($script:AllFindings).Count, @($script:RelationshipRows).Count)
        }
    })
    $script:BgTimer.Start()
}
$btnScan.Add_Click({ Invoke-Scan })

$btnCancelScan.Add_Click({
    if (-not $script:BgPowerShell) { return }
    $kind = $script:BgKind
    # The stop lands when the in-flight provider call returns; the runspace
    # is discarded so the next operation never queues behind a stuck pipeline.
    Reset-BgConnection
    Add-LogLine ('{0} cancelled.' -f $(if ($kind) { $kind } else { 'Operation' }))
    Set-StatusText ('{0} cancelled.' -f $(if ($kind) { $kind } else { 'Operation' }))
    if ($kind -eq 'Refresh') { Start-AutoRefreshIfEnabled }
})

# =============================================================================
# Live: glyphs and grid rows.
# =============================================================================
function Get-DeploymentGlyph {
    param($Row)
    if ([int]$Row.NumberErrors -gt 0)     { return $script:Glyph.Error }
    # Zero-target check must come before the compliance check; otherwise an
    # untargeted deployment (Targeted=0, Compliance=0) trips the warn branch.
    if ([int]$Row.NumberTargeted -eq 0)   { return $script:Glyph.Unknown }
    if ([int]$Row.NumberInProgress -gt 0) { return $script:Glyph.Warn }
    if ([double]$Row.PercentCompliant -lt 95) { return $script:Glyph.Warn }
    return $script:Glyph.OK
}
function Get-ContentGlyph {
    param($Row)
    if ([int]$Row.FailedCount -gt 0)     { return $script:Glyph.Error }
    if ([int]$Row.InProgressCount -gt 0) { return $script:Glyph.Warn }
    return $script:Glyph.OK
}
function Get-StatusWordGlyph {
    param($Row)
    switch ([string]$Row.Status) {
        'OK'       { return $script:Glyph.OK }
        'Warning'  { return $script:Glyph.Warn }
        'Critical' { return $script:Glyph.Error }
        default    { return $script:Glyph.Unknown }
    }
}
function Get-ClientGlyph {
    param($Row)
    if ([string]$Row.HealthState  -eq 'Unhealthy') { return $script:Glyph.Error }
    if ([string]$Row.ActiveStatus -eq 'Inactive')  { return $script:Glyph.Warn }
    if ([string]$Row.HealthState  -eq 'Healthy')   { return $script:Glyph.OK }
    return $script:Glyph.Unknown
}
function Get-InactiveGlyph {
    param($Row)
    # Every row is already past the configured threshold, so the floor is
    # Warn; sixty days, or no contact on record, escalates to Error.
    if ($null -eq $Row.DaysSinceContact -or [int]$Row.DaysSinceContact -gt 60) { return $script:Glyph.Error }
    return $script:Glyph.Warn
}

function Format-DateOrEmpty {
    param($Value)
    if ($null -eq $Value) { return '' }
    $dt = $Value -as [datetime]
    if ($dt) { return $dt.ToString('yyyy-MM-dd HH:mm') }
    return [string]$Value
}

function ConvertTo-DeploymentGridRows {
    param($Rows)
    $out = @(foreach ($r in @($Rows)) {
        [PSCustomObject]@{
            StatusGlyph      = Get-DeploymentGlyph -Row $r
            DeploymentId     = $r.DeploymentId
            DeploymentName   = $r.DeploymentName
            DeploymentType   = $r.DeploymentType
            CollectionName   = $r.CollectionName
            Purpose          = $r.Purpose
            NumberTargeted   = $r.NumberTargeted
            NumberSuccess    = $r.NumberSuccess
            NumberErrors     = $r.NumberErrors
            NumberInProgress = $r.NumberInProgress
            NumberUnknown    = $r.NumberUnknown
            PercentCompliant = $r.PercentCompliant
        }
    })
    return ,$out
}
function ConvertTo-ContentGridRows {
    param($Rows, $NameMap)
    $out = @(foreach ($r in @($Rows)) {
        $info = if ($NameMap) { $NameMap[$r.PackageID] } else { $null }
        [PSCustomObject]@{
            StatusGlyph     = Get-ContentGlyph -Row $r
            ContentName     = $(if ($info) { $info.Name } else { $r.PackageID })
            ContentType     = $(if ($info) { $info.Type } else { 'Application' })
            PackageID       = $r.PackageID
            TotalDPs        = $r.TotalDPs
            InstalledCount  = $r.InstalledCount
            FailedCount     = $r.FailedCount
            InProgressCount = $r.InProgressCount
        }
    })
    return ,$out
}
function ConvertTo-DPGridRows {
    param($Rows)
    $out = @(foreach ($r in @($Rows)) {
        [PSCustomObject]@{
            StatusGlyph   = Get-StatusWordGlyph -Row $r
            DPName        = $r.DPName
            SiteCode      = $r.SiteCode
            Status        = $r.Status
            IsPullDP      = $r.IsPullDP
        }
    })
    return ,$out
}
function ConvertTo-ClientGridRows {
    param($Rows)
    $out = @(foreach ($r in @($Rows)) {
        [PSCustomObject]@{
            StatusGlyph        = Get-ClientGlyph -Row $r
            DeviceName         = $r.DeviceName
            HealthState        = $r.HealthState
            ActiveStatus       = $r.ActiveStatus
            ClientState        = $r.ClientState
            LastOnlineDisplay  = Format-DateOrEmpty $r.LastOnlineTime
            LastDDRDisplay     = Format-DateOrEmpty $r.LastDDR
            LastPolicyDisplay  = Format-DateOrEmpty $r.LastPolicyRequest
            LastHWDisplay      = Format-DateOrEmpty $r.LastHWInventory
            ClientVersion      = $r.ClientVersion
            OperatingSystem    = $r.OperatingSystem
        }
    })
    return ,$out
}
function ConvertTo-InactiveGridRows {
    param($Rows)
    $out = @(foreach ($r in @($Rows)) {
        [PSCustomObject]@{
            StatusGlyph       = Get-InactiveGlyph -Row $r
            DeviceName        = $r.DeviceName
            LastOnlineDisplay = Format-DateOrEmpty $r.LastOnlineTime
            LastDDRDisplay    = Format-DateOrEmpty $r.LastDDR
            DaysSinceContact  = $r.DaysSinceContact
            OperatingSystem   = $r.OperatingSystem
            ClientVersion     = $r.ClientVersion
        }
    })
    return ,$out
}
function ConvertTo-SiteGridRows {
    param($ComponentRows, $SystemRows)
    $out = @()
    foreach ($r in @($ComponentRows)) {
        $out += [PSCustomObject]@{
            StatusGlyph        = Get-StatusWordGlyph -Row $r
            Name               = $r.ComponentName
            ItemType           = $r.ItemType
            MachineName        = $r.MachineName
            Status             = $r.Status
            State              = $r.State
            LastStartedDisplay = Format-DateOrEmpty $r.LastStarted
        }
    }
    foreach ($r in @($SystemRows)) {
        $out += [PSCustomObject]@{
            StatusGlyph        = Get-StatusWordGlyph -Row $r
            Name               = $r.RoleName
            ItemType           = $r.ItemType
            MachineName        = $r.ServerName
            Status             = $r.Status
            State              = ''
            LastStartedDisplay = ''
        }
    }
    return ,$out
}

# === Live detail panels ===
$gridDeploy.Add_SelectionChanged({
    $row = $gridDeploy.SelectedItem
    if (-not $row) { $txtDeployDetail.Text = 'Select a deployment to see status breakdown.'; return }
    $txtDeployDetail.Text = @(
        'DEPLOYMENT', ('-' * 40),
        ('Name:         {0}' -f $row.DeploymentName),
        ('Type:         {0}' -f $row.DeploymentType),
        ('Collection:   {0}' -f $row.CollectionName),
        ('Purpose:      {0}' -f $row.Purpose), '',
        ('Targeted:     {0}' -f $row.NumberTargeted),
        ('Success:      {0}' -f $row.NumberSuccess),
        ('Errors:       {0}' -f $row.NumberErrors),
        ('In Progress:  {0}' -f $row.NumberInProgress),
        ('Unknown:      {0}' -f $row.NumberUnknown),
        ('% Compliant:  {0}%' -f $row.PercentCompliant), '',
        ('Deployment ID: {0}' -f $row.DeploymentId)
    ) -join [Environment]::NewLine
})
$gridContent.Add_SelectionChanged({
    $row = $gridContent.SelectedItem
    if (-not $row) { $txtContentDetail.Text = 'Select a content item to see the distribution point breakdown.'; return }
    $txtContentDetail.Text = @(
        'CONTENT', ('-' * 40),
        ('Name:        {0}' -f $row.ContentName),
        ('Type:        {0}' -f $row.ContentType),
        ('Package ID:  {0}' -f $row.PackageID), '',
        ('Total DPs:   {0}' -f $row.TotalDPs),
        ('Installed:   {0}' -f $row.InstalledCount),
        ('Failed:      {0}' -f $row.FailedCount),
        ('In Progress: {0}' -f $row.InProgressCount)
    ) -join [Environment]::NewLine
})
$gridDPs.Add_SelectionChanged({
    $row = $gridDPs.SelectedItem
    if (-not $row) { $txtDPDetail.Text = 'Select a distribution point to see details.'; return }
    $txtDPDetail.Text = @(
        'DISTRIBUTION POINT', ('-' * 40),
        ('Name:          {0}' -f $row.DPName),
        ('Site:          {0}' -f $row.SiteCode),
        ('Status:        {0}' -f $row.Status),
        ('Pull DP:       {0}' -f $row.IsPullDP)
    ) -join [Environment]::NewLine
})
$gridClients.Add_SelectionChanged({
    $row = $gridClients.SelectedItem
    if (-not $row) { $txtClientDetail.Text = 'Select a device to see client health details.'; return }
    $txtClientDetail.Text = @(
        'CLIENT HEALTH', ('-' * 40),
        ('Device:        {0}' -f $row.DeviceName),
        ('Health State:  {0}' -f $row.HealthState),
        ('Active:        {0}' -f $row.ActiveStatus),
        ('Client State:  {0}' -f $row.ClientState),
        ('Client:        {0}' -f $row.ClientVersion),
        ('OS:            {0}' -f $row.OperatingSystem), '',
        ('Last Online:   {0}' -f $row.LastOnlineDisplay),
        ('Last DDR:      {0}' -f $row.LastDDRDisplay),
        ('Last Policy:   {0}' -f $row.LastPolicyDisplay),
        ('Last HW Inv:   {0}' -f $row.LastHWDisplay)
    ) -join [Environment]::NewLine
})
$gridInactive.Add_SelectionChanged({
    $row = $gridInactive.SelectedItem
    if (-not $row) { $txtInactiveDetail.Text = 'Select a device to see contact history.'; return }
    $txtInactiveDetail.Text = @(
        'INACTIVE DEVICE', ('-' * 40),
        ('Device:           {0}' -f $row.DeviceName),
        ('Days Since:       {0}' -f $row.DaysSinceContact),
        ('Operating System: {0}' -f $row.OperatingSystem),
        ('Client Version:   {0}' -f $row.ClientVersion), '',
        ('Last Online:      {0}' -f $row.LastOnlineDisplay),
        ('Last DDR:         {0}' -f $row.LastDDRDisplay)
    ) -join [Environment]::NewLine
})
$gridSite.Add_SelectionChanged({
    $row = $gridSite.SelectedItem
    if (-not $row) { $txtSiteDetail.Text = 'Select a component or site system for details.'; return }
    $txtSiteDetail.Text = @(
        'SITE HEALTH ITEM', ('-' * 40),
        ('Name:         {0}' -f $row.Name),
        ('Type:         {0}' -f $row.ItemType),
        ('Server:       {0}' -f $row.MachineName),
        ('Status:       {0}' -f $row.Status),
        ('State:        {0}' -f $row.State),
        ('Last Started: {0}' -f $row.LastStartedDisplay)
    ) -join [Environment]::NewLine
})

# =============================================================================
# Status bar.
# =============================================================================
function Update-StatusBarSummary {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='In-window TextBlock update.')]
    param()
    $parts = @()
    $isLive = $script:ActiveView -in $script:LiveViews
    if (-not $global:Prefs.SiteCode -or -not $global:Prefs.SMSProvider) { $parts += 'Open Options to set the site code and the SMS Provider' }
    elseif ($script:LastScanTime -or $script:LiveConnected) { $parts += ('Connected to {0}' -f $global:Prefs.SiteCode) }
    elseif ($isLive) { $parts += 'Ready. Select Refresh All.' }
    else { $parts += 'Ready. Select Scan.' }

    if ($isLive) {
        if ($script:DeploymentCounts) { $parts += ('{0} deployments / {1} failed' -f $script:DeploymentCounts.TotalDeployments, $script:DeploymentCounts.FailedDeployments) }
        if ($script:ContentCounts)    { $parts += ('{0} content issues' -f $script:ContentCounts.TotalContentWithIssues) }
        if ($script:DPCounts)         { $parts += ('{0} distribution points / {1} offline' -f $script:DPCounts.TotalDPs, $script:DPCounts.OfflineCount) }
        if ($script:ClientCounts)     { $parts += ('{0} unhealthy / {1} inactive' -f $script:ClientCounts.UnhealthyCount, $script:ClientCounts.InactiveCount) }
        if ($script:InactiveCounts)   { $parts += ('{0} stale devices' -f $script:InactiveCounts.InactiveCount) }
        if ($script:SiteCounts)       { $parts += ('site {0} OK / {1} crit' -f $script:SiteCounts.OKCount, $script:SiteCounts.CriticalCount) }
        if ($script:LastRefreshTime)  { $parts += ('last refresh {0}' -f $script:LastRefreshTime.ToString('HH:mm:ss')) }
        if ($script:AutoRefreshPaused) { $parts += 'auto-refresh paused' }
    }
    else {
        if (@($script:AllFindings).Count -gt 0) {
            $errors   = @($script:AllFindings | Where-Object { $_.Severity -eq 'Error' }).Count
            $warnings = @($script:AllFindings | Where-Object { $_.Severity -eq 'Warning' }).Count
            $infos    = @($script:AllFindings | Where-Object { $_.Severity -eq 'Info' }).Count
            $parts += ('{0} findings ({1} error, {2} warning, {3} info)' -f @($script:AllFindings).Count, $errors, $warnings, $infos)
        }
        if ($script:LastScanTime) { $parts += ('last scan {0}' -f $script:LastScanTime.ToString('HH:mm:ss')) }
    }
    Set-StatusText ($parts -join '   |   ')
}

# =============================================================================
# Trends: metric history chart (pure WPF, no chart libraries). History rows
# are appended on every completed refresh; this section reads and draws.
# =============================================================================
$script:TrendMetrics = @(
    @{ Label = 'Deployment Compliance %';     Column = 'CompliancePct' },
    @{ Label = 'Deployments With Errors';     Column = 'DeploymentFailed' },
    @{ Label = 'Content Items With Issues';   Column = 'ContentIssues' },
    @{ Label = 'Failed DP-Content Pairs';     Column = 'ContentFailedPairs' },
    @{ Label = 'DPs Critical';                Column = 'DPOffline' },
    @{ Label = 'DPs Degraded';                Column = 'DPDegraded' },
    @{ Label = 'Unhealthy Clients';           Column = 'ClientUnhealthy' },
    @{ Label = 'Inactive Devices';            Column = 'InactiveDevices' },
    @{ Label = 'Site Items Critical';         Column = 'SiteCritical' }
)
foreach ($m in $script:TrendMetrics) {
    $item = New-Object System.Windows.Controls.ComboBoxItem
    $item.Content = $m.Label
    $item.Tag     = $m.Column
    [void]$cboTrendMetric.Items.Add($item)
}
$cboTrendMetric.SelectedIndex = 0

$script:TrendGridBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#55808080')

function Get-TrendRangeDays {
    $sel = $cboTrendRange.SelectedItem
    if ($sel -and ([string]$sel.Content) -match '^(\d+)') { return [int]$Matches[1] }
    return 30
}
function Get-TrendLabelBrush {
    $b = $window.TryFindResource('MahApps.Brushes.ThemeForeground')
    if ($b) { return $b }
    return [System.Windows.Media.Brushes]::Gray
}
function Get-TrendLineBrush {
    $b = $window.TryFindResource('MahApps.Brushes.Accent')
    if ($b) { return $b }
    return [System.Windows.Media.BrushConverter]::new().ConvertFrom('#0078D4')
}
function Add-TrendCanvasText {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Adds a TextBlock to the trend canvas.')]
    param([string]$Text, [double]$X, [double]$Y, $Brush, [double]$FontSize = 10)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.FontSize = $FontSize
    $tb.Foreground = $Brush
    [System.Windows.Controls.Canvas]::SetLeft($tb, $X)
    [System.Windows.Controls.Canvas]::SetTop($tb, $Y)
    [void]$canvasTrend.Children.Add($tb)
}
function Add-TrendCanvasLine {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Adds a Line to the trend canvas.')]
    param([double]$X1, [double]$Y1, [double]$X2, [double]$Y2, $Brush, [double]$Thickness = 1)
    $ln = New-Object System.Windows.Shapes.Line
    $ln.X1 = $X1; $ln.Y1 = $Y1; $ln.X2 = $X2; $ln.Y2 = $Y2
    $ln.Stroke = $Brush
    $ln.StrokeThickness = $Thickness
    [void]$canvasTrend.Children.Add($ln)
}
function Update-TrendChart {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Redraws the in-window trend canvas from the history CSV.')]
    param()
    if (-not $canvasTrend) { return }
    $canvasTrend.Children.Clear()

    $sel = $cboTrendMetric.SelectedItem
    if (-not $sel) {
        $txtTrendEmpty.Visibility = [System.Windows.Visibility]::Visible
        $txtTrendSummary.Text = ''
        return
    }
    $column = [string]$sel.Tag
    $label  = [string]$sel.Content
    $days   = Get-TrendRangeDays

    $points = @(Get-MetricsSeries -HistoryPath $global:HistoryPath -Column $column -Days $days)
    if ($points.Count -lt 1) {
        $txtTrendEmpty.Visibility = [System.Windows.Visibility]::Visible
        $txtTrendSummary.Text = ''
        return
    }
    $txtTrendEmpty.Visibility = [System.Windows.Visibility]::Collapsed

    $w = $canvasTrend.ActualWidth
    $h = $canvasTrend.ActualHeight
    if ($w -lt 80 -or $h -lt 60) { return }   # Not laid out yet; SizeChanged redraws.

    $marL = 48.0; $marR = 12.0; $marT = 10.0; $marB = 24.0
    $plotW = $w - $marL - $marR
    $plotH = $h - $marT - $marB

    $vMin = ($points | Measure-Object -Property V -Minimum).Minimum
    $vMax = ($points | Measure-Object -Property V -Maximum).Maximum
    if ($vMax -eq $vMin) { $vMax = $vMin + 1 }
    $t0 = $points[0].T.Ticks
    $t1 = $points[-1].T.Ticks
    $tSpan = [double]($t1 - $t0)
    $labelBrush = Get-TrendLabelBrush
    $lineBrush  = Get-TrendLineBrush

    foreach ($frac in 0.0, 0.25, 0.5, 0.75, 1.0) {
        $y = $marT + $plotH * (1.0 - $frac)
        Add-TrendCanvasLine -X1 $marL -Y1 $y -X2 ($marL + $plotW) -Y2 $y -Brush $script:TrendGridBrush
        $val = $vMin + ($vMax - $vMin) * $frac
        Add-TrendCanvasText -Text ('{0:0.#}' -f $val) -X 4 -Y ($y - 7) -Brush $labelBrush
    }

    $fmt = if ($days -le 7) { 'MM-dd HH:mm' } else { 'yyyy-MM-dd' }
    Add-TrendCanvasText -Text $points[0].T.ToString($fmt)  -X $marL -Y ($marT + $plotH + 6) -Brush $labelBrush
    $endLabel = $points[-1].T.ToString($fmt)
    Add-TrendCanvasText -Text $endLabel -X ($marL + $plotW - 6.0 * $endLabel.Length) -Y ($marT + $plotH + 6) -Brush $labelBrush

    $poly = New-Object System.Windows.Shapes.Polyline
    $poly.Stroke = $lineBrush
    $poly.StrokeThickness = 2
    $pc = New-Object System.Windows.Media.PointCollection
    foreach ($p in $points) {
        $x = if ($tSpan -gt 0) { $marL + $plotW * (($p.T.Ticks - $t0) / $tSpan) } else { $marL + $plotW / 2 }
        $y = $marT + $plotH * (1.0 - (($p.V - $vMin) / ($vMax - $vMin)))
        $pc.Add([System.Windows.Point]::new($x, $y))
    }
    $poly.Points = $pc
    [void]$canvasTrend.Children.Add($poly)

    if ($points.Count -le 90) {
        foreach ($pt in $pc) {
            $dot = New-Object System.Windows.Shapes.Ellipse
            $dot.Width = 5; $dot.Height = 5
            $dot.Fill = $lineBrush
            [System.Windows.Controls.Canvas]::SetLeft($dot, $pt.X - 2.5)
            [System.Windows.Controls.Canvas]::SetTop($dot, $pt.Y - 2.5)
            [void]$canvasTrend.Children.Add($dot)
        }
    }

    $vals = @($points | ForEach-Object { $_.V })
    $stats = $vals | Measure-Object -Minimum -Maximum -Average
    $txtTrendSummary.Text = ('{0}: {1} samples over {2} days   |   latest {3:0.#}   min {4:0.#}   max {5:0.#}   avg {6:0.#}' -f `
        $label, $points.Count, $days, $points[-1].V, $stats.Minimum, $stats.Maximum, $stats.Average)
}
$cboTrendMetric.Add_SelectionChanged({ if ($script:ActiveView -eq 'Trends') { Update-TrendChart } })
$cboTrendRange.Add_SelectionChanged({  if ($script:ActiveView -eq 'Trends') { Update-TrendChart } })
$canvasTrend.Add_SizeChanged({         if ($script:ActiveView -eq 'Trends') { Update-TrendChart } })

# =============================================================================
# Alerts: threshold evaluation on each completed refresh. Transition-based:
# an alert fires when a metric crosses from OK into breach, not on every
# refresh while it stays breached. Delivery is local: a toast plus
# Logs\SiteHygiene-alerts.log and the log drawer.
# =============================================================================
$global:AlertLogPath = Join-Path $__txDir 'SiteHygiene-alerts.log'
$script:AlertBreachState = @{}

function Send-ShToast {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Shows a local toast notification.')]
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Message)
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]
        $tTitle = [System.Security.SecurityElement]::Escape($Title)
        $tMsg   = [System.Security.SecurityElement]::Escape($Message)
        $xmlText = "<toast><visual><binding template=""ToastGeneric""><text>$tTitle</text><text>$tMsg</text></binding></visual></toast>"
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($xmlText)
        $toast = New-Object Windows.UI.Notifications.ToastNotification -ArgumentList $xml
        # PowerShell's registered AppUserModelID hosts script-generated toasts.
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
        return $true
    } catch {
        return $false
    }
}

function Write-AlertEntry {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Appends to the alert log and log drawer; sends a toast.')]
    param([Parameter(Mandatory)][string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -LiteralPath $global:AlertLogPath -Value $line -Encoding UTF8 } catch { $null = $_ }
    Add-LogLine ('ALERT: {0}' -f $Message) -Level WARN
    if (-not (Send-ShToast -Title 'Site Hygiene' -Message $Message)) {
        Add-LogLine 'Toast delivery unavailable; alert recorded in SiteHygiene-alerts.log only.' -Level WARN
    }
}

function Invoke-AlertEvaluation {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Evaluates thresholds and emits transition alerts.')]
    param()
    if (-not [bool]$global:Prefs.AlertsEnabled) { return }
    $complianceFloor = [int]$global:Prefs.AlertCompliancePct
    $rules = @()
    if ($script:SiteCounts) {
        $rules += @{ Key = 'SiteCritical'; Breached = ([int]$script:SiteCounts.CriticalCount -gt 0)
                     Message  = ('Site health: {0} component / site-system item(s) critical.' -f $script:SiteCounts.CriticalCount) }
    }
    if ($script:DPCounts) {
        $rules += @{ Key = 'DPCritical'; Breached = ([int]$script:DPCounts.OfflineCount -gt 0)
                     Message  = ('{0} distribution point(s) in critical state.' -f $script:DPCounts.OfflineCount) }
    }
    if ($script:ContentCounts) {
        $rules += @{ Key = 'FailedContent'; Breached = ([int]$script:ContentCounts.TotalFailedPairs -gt 0)
                     Message  = ('{0} failed DP-content pair(s).' -f $script:ContentCounts.TotalFailedPairs) }
    }
    if ($script:DeploymentCounts -and [int]$script:DeploymentCounts.TotalDeployments -gt 0) {
        $rules += @{ Key = 'Compliance'; Breached = ([double]$script:DeploymentCounts.OverallCompliance -lt $complianceFloor)
                     Message  = ('Overall deployment compliance {0}% is below the {1}% floor.' -f $script:DeploymentCounts.OverallCompliance, $complianceFloor) }
    }
    foreach ($r in $rules) {
        $wasBreached = [bool]$script:AlertBreachState[$r.Key]
        if ($r.Breached -and -not $wasBreached) { Write-AlertEntry -Message $r.Message }
        $script:AlertBreachState[$r.Key] = [bool]$r.Breached
    }
}

# =============================================================================
# Live refresh. The queries run one after another on the shared background
# runspace; the overlay shows the current step.
# =============================================================================
function Invoke-RefreshAll {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Posts work to the background runspace and arms a DispatcherTimer.')]
    param()
    if (-not $global:Prefs.SiteCode -or -not $global:Prefs.SMSProvider) {
        Add-LogLine 'Refresh: set the site code and the SMS Provider in Options first.' -Level WARN
        Set-StatusText 'Open Options to set the site code and the SMS Provider, then refresh.'
        return
    }
    # A timer tick during a scan is dropped; the next tick retries.
    if (Test-BgBusy -Action 'Refresh') { return }
    Initialize-BgRunspace
    Dispose-BgWork
    $script:BgKind = 'Refresh'
    if ($script:AutoTimer) { $script:AutoTimer.Stop() }

    $script:BgState = [hashtable]::Synchronized(@{ Step = 'Connecting...'; Done = $false; Result = $null; ErrorMsg = $null })
    $script:BgInfoIndex = 0
    $script:RefreshStarted = Get-Date
    $btnRefreshAll.IsEnabled = $false
    $txtProgressTitle.Text = 'Refreshing live data...'
    $txtProgressStep.Text  = 'Connecting...'
    $progressOverlay.Visibility = [System.Windows.Visibility]::Visible
    Add-LogLine ('Refresh: site={0} provider={1} sql={2}' -f $global:Prefs.SiteCode, $global:Prefs.SMSProvider, $(if ($global:Prefs.SQLServer) { $global:Prefs.SQLServer } else { '(none)' }))
    Set-StatusText 'Refreshing...'

    $siteCode    = [string]$global:Prefs.SiteCode
    $smsProvider = [string]$global:Prefs.SMSProvider
    $sqlServer   = [string]$global:Prefs.SQLServer
    $threshold   = [int]$global:Prefs.InactiveThresholdDays
    $trustSql    = [bool]$global:Prefs.SqlTrustServerCertificate
    $sqlTimeout  = [int]$global:Prefs.SqlQueryTimeoutSeconds

    $script:BgPowerShell = [powershell]::Create()
    $script:BgPowerShell.Runspace = $script:BgRunspace
    [void]$script:BgPowerShell.AddScript({
        param($SiteCode, $SMSProvider, $SQLServer, $ThresholdDays, $State, $TrustSql, $SqlTimeout)
        try {
            # The site database reads use the configured timeout (preference SqlQueryTimeoutSeconds; 0 = no limit).
            Set-HygieneSqlTimeout -Seconds ([Math]::Max(0, [int]$SqlTimeout))
            if (-not (Test-CMConnection)) {
                $State.Step = "Connecting to $SiteCode..."
                $ok = Connect-CMSite -SiteCode $SiteCode -SMSProvider $SMSProvider
                if (-not $ok) { $State.ErrorMsg = "Failed to connect to site $SiteCode (SMS Provider $SMSProvider)."; return }
            }

            $sqlOk = $false
            if ($SQLServer) {
                $State.Step = "Testing SQL connection ($SQLServer)..."
                $sqlOk = Test-SQLConnection -SQLServer $SQLServer -SiteCode $SiteCode -TrustServerCertificate $TrustSql
            }

            $State.Step = 'Querying deployment health...'
            $deployData = @(Get-DeploymentHealth)
            $deployCounts = Get-DeploymentHealthCounts -DeploymentData $deployData

            $State.Step = 'Querying content distribution health...'
            $contentData = @(Get-ContentDistributionHealth)
            $contentCounts = Get-ContentHealthCounts -ContentData $contentData

            $State.Step = 'Resolving content names...'
            $nameMap = Get-ContentNameMap

            # A failed area keeps its counts $null, never zero: zero would
            # record a false recovery in the history and reset the alert
            # latch for an incident that is still open.
            $State.Step = 'Querying distribution point health...'
            $dpData = @(); $dpCounts = $null
            try {
                $dpData = @(Get-DPHealth)
                $dpCounts = Get-DPHealthCounts -DPData $dpData
            } catch { $dpData = @(); Write-Log ('Distribution point status unavailable: {0}' -f $_.Exception.Message) -Level WARN -Quiet; Add-LogLine 'Distribution point status unavailable. The log file has the details.' -Level WARN }

            $clientData = @(); $clientCounts = $null
            $inactiveData = @(); $inactiveCounts = $null
            if ($sqlOk) {
                $State.Step = 'Querying client health (SQL)...'
                try {
                    $clientData = @(Get-ClientHealthSummary -SQLServer $SQLServer -SiteCode $SiteCode -TrustServerCertificate $TrustSql)
                    $clientCounts = Get-ClientHealthCounts -ClientData $clientData
                } catch { $clientData = @() }

                $State.Step = "Querying inactive devices (>$ThresholdDays days)..."
                try {
                    $inactiveData = @(Get-InactiveDevices -SQLServer $SQLServer -SiteCode $SiteCode -ThresholdDays $ThresholdDays -TrustServerCertificate $TrustSql)
                    $inactiveCounts = Get-InactiveDeviceCounts -DeviceData $inactiveData
                } catch { $inactiveData = @() }
            }

            $componentData = @(); $systemData = @(); $siteCounts = $null
            try {
                $State.Step = 'Querying site component health...'
                $componentData = @(Get-SiteComponentHealth)
                $State.Step = 'Querying site system health...'
                $systemData = @(Get-SiteSystemHealth)
                $siteCounts = Get-SiteHealthCounts -ComponentData $componentData -SystemData $systemData
            } catch { $componentData = @(); $systemData = @() }

            $State.Result = [PSCustomObject]@{
                SqlOk            = $sqlOk
                DeploymentData   = $deployData
                DeploymentCounts = $deployCounts
                ContentData      = $contentData
                ContentCounts    = $contentCounts
                ContentNameMap   = $nameMap
                DPData           = $dpData
                DPCounts         = $dpCounts
                ClientData       = $clientData
                ClientCounts     = $clientCounts
                InactiveData     = $inactiveData
                InactiveCounts   = $inactiveCounts
                ComponentData    = $componentData
                SystemData       = $systemData
                SiteCounts       = $siteCounts
            }
        }
        catch { $State.ErrorDetail = $_.Exception.Message; $State.ErrorMsg = 'An error occurred. The log file has the details.' }
        finally { $State.Done = $true }
    }).AddArgument($siteCode).AddArgument($smsProvider).AddArgument($sqlServer).AddArgument($threshold).AddArgument($script:BgState).AddArgument($trustSql).AddArgument($sqlTimeout)

    $script:BgInvokeHandle = $script:BgPowerShell.BeginInvoke()
    $script:BgTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:BgTimer.Interval = [TimeSpan]::FromMilliseconds(150)
    $script:BgTimer.Add_Tick({
        if ($script:BgState) {
            $current = '{0}  [{1:mm\:ss}]' -f [string]$script:BgState.Step, ((Get-Date) - $script:RefreshStarted)
            if ($txtProgressStep.Text -ne $current) { $txtProgressStep.Text = $current }
        }
        Read-BgInformationStream
        if ($script:BgState -and $script:BgState.Done) {
            Complete-BgInvoke

            if ($script:BgState.ErrorMsg) {
                $progressOverlay.Visibility = [System.Windows.Visibility]::Collapsed
                $btnRefreshAll.IsEnabled = $true
                $script:LiveConnected = $false
                if ($script:BgState.ErrorDetail) { Write-Log ('Refresh failed: {0}' -f $script:BgState.ErrorDetail) -Level ERROR -Quiet }
                Add-LogLine ('Refresh failed: {0}' -f $script:BgState.ErrorMsg) -Level ERROR
                Set-StatusText 'Refresh failed.'
                # A transient failure must not stop the cadence.
                Start-AutoRefreshIfEnabled
                return
            }

            $script:LiveConnected = $true
            $r = $script:BgState.Result
            $script:DeploymentCounts = $r.DeploymentCounts
            $script:ContentCounts    = $r.ContentCounts
            $script:DPCounts         = $r.DPCounts
            $script:ClientCounts     = $r.ClientCounts
            $script:InactiveCounts   = $r.InactiveCounts
            $script:SiteCounts       = $r.SiteCounts

            $script:DeploymentRows = ConvertTo-DeploymentGridRows -Rows $r.DeploymentData
            $script:ContentRows    = ConvertTo-ContentGridRows    -Rows $r.ContentData -NameMap $r.ContentNameMap
            $script:DPRows         = ConvertTo-DPGridRows         -Rows $r.DPData
            $script:ClientRows     = ConvertTo-ClientGridRows     -Rows $r.ClientData
            $script:InactiveRows   = ConvertTo-InactiveGridRows   -Rows $r.InactiveData
            $script:SiteRows       = ConvertTo-SiteGridRows       -ComponentRows $r.ComponentData -SystemRows $r.SystemData
            $script:LastRefreshTime = Get-Date

            Add-MetricsHistoryEntry -HistoryPath $global:HistoryPath `
                -DeploymentCounts $script:DeploymentCounts `
                -ContentCounts    $script:ContentCounts `
                -DPCounts         $script:DPCounts `
                -ClientCounts     $script:ClientCounts `
                -InactiveCounts   $script:InactiveCounts `
                -SiteCounts       $script:SiteCounts
            Invoke-AlertEvaluation
            if ($script:ActiveView -eq 'Trends') { Update-TrendChart }

            Update-Filter
            Update-StatusBarSummary
            Sync-FooterSite
            $progressOverlay.Visibility = [System.Windows.Visibility]::Collapsed
            $btnRefreshAll.IsEnabled = $true

            $sqlNote = if ($r.SqlOk) { 'SQL ok' } else { 'SQL skipped' }
            Add-LogLine ('Refresh complete: {0} deployments, {1} content issues, {2} distribution points, {3} devices, {4} inactive, {5} site items ({6})' -f $script:DeploymentRows.Count, $script:ContentRows.Count, $script:DPRows.Count, $script:ClientRows.Count, $script:InactiveRows.Count, $script:SiteRows.Count, $sqlNote)
            Start-AutoRefreshIfEnabled
        }
    })
    $script:BgTimer.Start()
}
$btnRefreshAll.Add_Click({ Invoke-RefreshAll })

# === Auto-refresh timer ===
$script:AutoTimer         = $null
$script:AutoRefreshPaused = $false

function Start-AutoRefreshIfEnabled {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Mutates the in-process DispatcherTimer; idempotent.')]
    param()
    if ($script:AutoRefreshPaused) { return }
    $minutes = [int]$global:Prefs.AutoRefreshMinutes
    if ($minutes -le 0) { return }
    if (-not $script:AutoTimer) {
        $script:AutoTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:AutoTimer.Add_Tick({ Invoke-RefreshAll })
    }
    $script:AutoTimer.Interval = [TimeSpan]::FromMinutes($minutes)
    $script:AutoTimer.Start()
}
function Stop-AutoRefresh {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Stops the in-process DispatcherTimer; idempotent.')]
    param()
    if ($script:AutoTimer) { $script:AutoTimer.Stop() }
}
$btnPauseResume.Add_Click({
    $script:AutoRefreshPaused = -not $script:AutoRefreshPaused
    if ($script:AutoRefreshPaused) {
        Stop-AutoRefresh
        $btnPauseResume.Content = 'Resume Auto-Refresh'
        Add-LogLine 'Auto-refresh paused.'
    } else {
        $btnPauseResume.Content = 'Pause Auto-Refresh'
        Start-AutoRefreshIfEnabled
        Add-LogLine 'Auto-refresh resumed.'
    }
    Update-StatusBarSummary
})

# =============================================================================
# Export and copy summary.
# =============================================================================
function ConvertTo-DataTableForExport {
    param([Parameter(Mandatory)]$Rows, [string[]]$Columns)
    $dt = New-Object System.Data.DataTable
    if ($Columns -and $Columns.Count -gt 0) {
        foreach ($c in $Columns) { [void]$dt.Columns.Add($c, [string]) }
    } elseif (@($Rows).Count -gt 0) {
        foreach ($p in @($Rows)[0].PSObject.Properties) {
            if ($p.Name -ne 'StatusGlyph') { [void]$dt.Columns.Add($p.Name, [string]) }
        }
    } else {
        return ,$dt
    }
    foreach ($row in @($Rows)) {
        $vals = @()
        foreach ($col in $dt.Columns) { $vals += [string]$row.PSObject.Properties[$col.ColumnName].Value }
        [void]$dt.Rows.Add($vals)
    }
    # The comma keeps PowerShell from unrolling the table into its rows; the export functions take the table itself.
    return ,$dt
}

function Get-ActiveExportInfo {
    switch ($script:ActiveView) {
        'Relationships' {
            return @{ Name = 'Relationships'; Columns = @('Kind','Status','Circular','SourceName','SourceVersion','SourceDeploymentType','TargetName','TargetVersion','DependencyState','ChainDepth','TargetModelName'); Rows = @(Get-FilteredRelationshipRows) }
        }
        'Deployments' {
            return @{ Name = 'Deployments'; Columns = @('DeploymentName','DeploymentType','CollectionName','Purpose','NumberTargeted','NumberSuccess','NumberErrors','NumberInProgress','NumberUnknown','PercentCompliant'); Rows = $gridDeploy.ItemsSource }
        }
        'Content' {
            return @{ Name = 'Content'; Columns = @('ContentName','ContentType','PackageID','TotalDPs','InstalledCount','FailedCount','InProgressCount'); Rows = $gridContent.ItemsSource }
        }
        'DPs' {
            return @{ Name = 'DistributionPoints'; Columns = @('DPName','SiteCode','Status','IsPullDP'); Rows = $gridDPs.ItemsSource }
        }
        'Clients' {
            return @{ Name = 'ClientHealth'; Columns = @('DeviceName','HealthState','ActiveStatus','LastOnlineDisplay','LastDDRDisplay','LastPolicyDisplay','LastHWDisplay','ClientVersion','OperatingSystem'); Rows = $gridClients.ItemsSource }
        }
        'Inactive' {
            return @{ Name = 'InactiveDevices'; Columns = @('DeviceName','LastOnlineDisplay','LastDDRDisplay','DaysSinceContact','OperatingSystem','ClientVersion'); Rows = $gridInactive.ItemsSource }
        }
        'Site' {
            return @{ Name = 'SiteHealth'; Columns = @('Name','ItemType','MachineName','Status','State','LastStartedDisplay'); Rows = $gridSite.ItemsSource }
        }
        'Trends' {
            $sel = $cboTrendMetric.SelectedItem
            if (-not $sel) { return $null }
            $column = [string]$sel.Tag
            $rows = @(Get-MetricsSeries -HistoryPath $global:HistoryPath -Column $column -Days (Get-TrendRangeDays)) |
                ForEach-Object { [PSCustomObject]@{ Timestamp = $_.T.ToString('yyyy-MM-dd HH:mm:ss'); Value = $_.V } }
            return @{ Name = ('Trends-{0}' -f ($column -replace '[^A-Za-z0-9]', '')); Columns = @('Timestamp','Value'); Rows = @($rows) }
        }
        default { return $null }
    }
}

function Show-ExportSaveDialog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Modal dialog; reads as one action.')]
    param([Parameter(Mandatory)][string]$Extension, [Parameter(Mandatory)][string]$Name)
    $sfd = New-Object Microsoft.Win32.SaveFileDialog
    $sfd.Filter = $(if ($Extension -eq 'csv') { 'CSV files (*.csv)|*.csv' } else { 'HTML files (*.html)|*.html' })
    $sfd.FileName = ('SiteHygiene-{0}-{1}.{2}' -f $Name, (Get-Date -Format 'yyyyMMdd-HHmmss'), $Extension)
    $reportsDir = $script:ReportsDir
    if (-not (Test-Path -LiteralPath $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null }
    $sfd.InitialDirectory = $reportsDir
    if ($sfd.ShowDialog() -eq $true) { return $sfd.FileName }
    return $null
}

function Invoke-Export {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Writes a report file the user picked.')]
    param([Parameter(Mandatory)][ValidateSet('csv','html')][string]$Extension)
    if ($script:ActiveView -in 'Findings', 'Summary') {
        $rows = @(Get-FilteredFindings)
        if ($rows.Count -eq 0) { Add-LogLine ('Export {0}: nothing to export.' -f $Extension.ToUpperInvariant()); return }
        $path = Show-ExportSaveDialog -Extension $Extension -Name 'Findings'
        if (-not $path) { return }
        if ($Extension -eq 'csv') { Export-HygieneCsv -Findings $rows -OutputPath $path }
        else { Export-HygieneHtml -Findings $rows -OutputPath $path }
        Add-LogLine ('Exported {0}: {1}' -f $Extension.ToUpperInvariant(), $path)
        return
    }
    $info = Get-ActiveExportInfo
    if (-not $info -or -not $info.Rows -or @($info.Rows).Count -eq 0) { Add-LogLine ('Export {0}: nothing to export.' -f $Extension.ToUpperInvariant()); return }
    $path = Show-ExportSaveDialog -Extension $Extension -Name $info.Name
    if (-not $path) { return }
    $dt = ConvertTo-DataTableForExport -Rows $info.Rows -Columns $info.Columns
    if ($Extension -eq 'csv') { Export-HygieneTableCsv -DataTable $dt -OutputPath $path }
    else { Export-HygieneTableHtml -DataTable $dt -OutputPath $path -ReportTitle ('Site Hygiene - {0}' -f $info.Name) }
    Add-LogLine ('Exported {0}: {1}' -f $Extension.ToUpperInvariant(), $path)
}
$btnExportCsv.Add_Click({ Invoke-Export -Extension 'csv' })
$btnExportHtml.Add_Click({ Invoke-Export -Extension 'html' })

$btnCopySummary.Add_Click({
    if (-not $script:DeploymentCounts) { Add-LogLine 'Copy Summary: no refresh data yet.' -Level WARN; return }
    $summary = New-HygieneLiveSummaryText `
        -DeploymentCounts $script:DeploymentCounts `
        -ContentCounts    $script:ContentCounts `
        -DPCounts         $script:DPCounts `
        -ClientCounts     $script:ClientCounts `
        -InactiveCounts   $script:InactiveCounts `
        -SiteCounts       $script:SiteCounts
    [System.Windows.Clipboard]::SetText($summary)
    Add-LogLine 'Summary copied to clipboard.'
})

# =============================================================================
# Options dialog (Set-DialogTheme: SuiteCommon).
# =============================================================================
function Show-OptionsDialog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Modal dialog show / dispose; reads as a single action.')]
    param()
    $dlgXaml = @'
<Controls:MetroWindow
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:Controls="clr-namespace:MahApps.Metro.Controls;assembly=MahApps.Metro"
    Title="Options" Width="700" Height="560"
    MinWidth="600" MinHeight="540"
    WindowStartupLocation="CenterOwner" TitleCharacterCasing="Normal"
    GlowBrush="{DynamicResource MahApps.Brushes.Accent}"
    NonActiveGlowBrush="{DynamicResource MahApps.Brushes.Accent}"
    BorderThickness="1" ShowIconOnTitleBar="False">
    <Window.Resources>
        <ResourceDictionary>
            <ResourceDictionary.MergedDictionaries>
                <ResourceDictionary Source="pack://application:,,,/MahApps.Metro;component/Styles/Controls.xaml" />
                <ResourceDictionary Source="pack://application:,,,/MahApps.Metro;component/Styles/Fonts.xaml" />
                <ResourceDictionary Source="pack://application:,,,/MahApps.Metro;component/Styles/Themes/Dark.Steel.xaml" />
            </ResourceDictionary.MergedDictionaries>
            <!-- The same template and style as the main window. The colors come from MahApps resources and from the code that themes the dialog. -->
            <!-- A disabled text box or combo box is dimmed by opacity: WCAG 1.4.3 exempts inactive components from 4.5:1,
                 and the contrast probe requires that they look clearly dimmed. The border is the one of the SuiteCommon implicit style. -->
            <Style TargetType="TextBox" BasedOn="{StaticResource MahApps.Styles.TextBox}">
                <Setter Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.Gray2}"/>
                <Style.Triggers>
                    <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
                </Style.Triggers>
            </Style>
            <Style TargetType="ComboBox" BasedOn="{StaticResource MahApps.Styles.ComboBox}">
                <Setter Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.Gray2}"/>
                <Style.Triggers>
                    <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
                </Style.Triggers>
            </Style>
            <ControlTemplate x:Key="ThemedButtonTemplate" TargetType="Button">
                <Border x:Name="Bd"
                        Background="{TemplateBinding Background}"
                        BorderBrush="{TemplateBinding BorderBrush}"
                        BorderThickness="{TemplateBinding BorderThickness}"
                        SnapsToDevicePixels="True">
                    <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                      VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                                      Margin="{TemplateBinding Padding}"
                                      RecognizesAccessKey="True"
                                      SnapsToDevicePixels="True"/>
                </Border>
                <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="Bd" Property="Opacity" Value="0.85"/>
                    </Trigger>
                    <Trigger Property="IsKeyboardFocused" Value="True">
                        <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                    </Trigger>
                    <Trigger Property="IsPressed" Value="True">
                        <Setter TargetName="Bd" Property="Opacity" Value="0.7"/>
                    </Trigger>
                    <Trigger Property="IsEnabled" Value="False">
                        <Setter TargetName="Bd" Property="Opacity" Value="0.5"/>
                    </Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>
            <Style x:Key="ThemedButtonStyle" TargetType="Button" BasedOn="{StaticResource MahApps.Styles.Button.Square}">

                <Setter Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.Gray2}"/>
                <Setter Property="Template" Value="{StaticResource ThemedButtonTemplate}"/>
                <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                <Setter Property="BorderThickness" Value="1"/>
            </Style>
            <Style x:Key="CategoryRowStyle" TargetType="Button" BasedOn="{StaticResource ThemedButtonStyle}">
                <Setter Property="Height" Value="36"/>
                <Setter Property="HorizontalContentAlignment" Value="Left"/>
                <Setter Property="Padding" Value="14,0,14,0"/>
                <Setter Property="FontSize" Value="13"/>
                <Setter Property="Controls:ControlsHelper.ContentCharacterCasing" Value="Normal"/>
                <Setter Property="Margin" Value="0"/>
            </Style>
            <!-- The one secondary style: a gray fill, the theme text color and a visible border. Cancel uses it. The primary style is DialogAccentButton. -->
            <Style x:Key="DialogButton" TargetType="Button" BasedOn="{StaticResource ThemedButtonStyle}">
                <Setter Property="Template" Value="{DynamicResource SuiteNeutralButtonTemplate}"/>
                <Setter Property="Background" Value="{DynamicResource MahApps.Brushes.Gray10}"/>
                <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                <Setter Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.Gray2}"/>
                <Setter Property="MinWidth" Value="90"/><Setter Property="Height" Value="32"/>
                <Setter Property="Margin" Value="0,0,8,0"/>
                <Setter Property="Controls:ControlsHelper.ContentCharacterCasing" Value="Normal"/>
            </Style>
            <Style x:Key="DialogAccentButton" TargetType="Button" BasedOn="{StaticResource ThemedButtonStyle}">
                <Setter Property="Template" Value="{DynamicResource SuiteAccentButtonTemplate}"/>
                <Setter Property="MinWidth" Value="90"/><Setter Property="Height" Value="32"/>
                <Setter Property="Background" Value="{DynamicResource MahApps.Brushes.AccentBase}"/>
                <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.IdealForeground}"/>
                <Setter Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.AccentBase}"/>
                <Setter Property="Margin" Value="0,0,8,0"/>
                <Setter Property="Controls:ControlsHelper.ContentCharacterCasing" Value="Normal"/>
            </Style>
            <Style x:Key="OptLabel" TargetType="TextBlock">
                <Setter Property="FontSize" Value="11"/>
                <Setter Property="FontWeight" Value="Bold"/>
                <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.Gray1}"/>
                <Setter Property="Margin" Value="0,12,0,2"/>
            </Style>
            <Style x:Key="OptHint" TargetType="TextBlock">
                <Setter Property="FontSize" Value="10"/>
                <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.Gray1}"/>
                <Setter Property="TextWrapping" Value="Wrap"/>
                <Setter Property="Margin" Value="0,2,0,0"/>
            </Style>
        </ResourceDictionary>
    </Window.Resources>
    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="180"/>
            <ColumnDefinition Width="1"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Border Grid.Column="0" Grid.Row="0" Padding="6,12,0,12">
            <StackPanel>
                <Button x:Name="btnCatConnection" Content="Connection" Style="{StaticResource CategoryRowStyle}" ToolTip="Show the ConfigMgr connection settings: the site code, the SMS Provider and the SQL Server."/>
                <Button x:Name="btnCatScope"      Content="Scan"       Style="{StaticResource CategoryRowStyle}" ToolTip="Show the scan settings: the areas to scan, the pause between calls and the deployment age."/>
                <Button x:Name="btnCatLive"       Content="Live"       Style="{StaticResource CategoryRowStyle}" ToolTip="Show the auto-refresh interval and the inactivity threshold."/>
                <Button x:Name="btnCatAlerts"     Content="Alerts"     Style="{StaticResource CategoryRowStyle}" ToolTip="Show the threshold alert settings."/>
                <Button x:Name="btnCatAbout"      Content="About"      Style="{StaticResource CategoryRowStyle}" ToolTip="Show the version, the author and the license of the app."/>
            </StackPanel>
        </Border>
        <Border Grid.Column="1" Grid.Row="0" Background="{DynamicResource MahApps.Brushes.Gray8}"/>
        <Grid Grid.Column="2" Grid.Row="0" Margin="20,16,20,16">
            <StackPanel x:Name="paneConnection" Visibility="Visible">
                <TextBlock Text="Configuration Manager Connection" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,10"/>
                <TextBlock Style="{StaticResource OptLabel}" FontSize="14" FontWeight="Bold" Text="Site Code"/>
                <TextBox x:Name="txtSiteCode" ToolTip="Enter the three-character site code of the ConfigMgr site." FontSize="12" Padding="6,4,6,4" MaxLength="3"
                         Controls:TextBoxHelper.Watermark="MCM" Width="120" HorizontalAlignment="Left"/>
                <TextBlock Style="{StaticResource OptLabel}" FontSize="14" FontWeight="Bold" Text="SMS Provider FQDN"/>
                <TextBox x:Name="txtSmsProvider" ToolTip="Enter the fully qualified domain name of the server that hosts the SMS Provider." FontSize="12" Padding="6,4,6,4"
                         Controls:TextBoxHelper.Watermark="cm01.contoso.com"/>
                <TextBlock Style="{StaticResource OptHint}" Text="The app uses these values for the ConfigMgr drive. Every scan and live query runs through this connection with your ConfigMgr security role. A scan changes nothing, so the account needs read access only."/>
                <TextBlock Style="{StaticResource OptLabel}" Text="SQL Server (Optional)"/>
                <TextBox x:Name="txtSqlServer" ToolTip="Enter the SQL Server that hosts the site database, or leave it empty to skip the Client Health and Inactive Devices views." FontSize="12" Padding="6,4,6,4"
                         Controls:TextBoxHelper.Watermark="cm01.contoso.com (blank to skip SQL views)"/>
                <TextBlock Style="{StaticResource OptHint}" Text="The SQL Server instance that hosts the site database CM_&lt;site&gt;. Use the FQDN or FQDN\InstanceName. Leave the box empty to skip the Client Health and Inactive Devices views."/>
                <CheckBox x:Name="chkSqlTrustCert" ToolTip="Connect to SQL Server without validating its certificate, while the connection stays encrypted." Content="Trust the SQL Server Certificate" FontSize="12" Margin="0,10,0,0"/>
                <TextBlock Style="{StaticResource OptHint}" Text="The connection stays encrypted, but the app does not validate the server certificate. Clear this box when this computer trusts the SQL Server certificate."/>
            </StackPanel>
            <StackPanel x:Name="paneScope" Visibility="Collapsed">
                <TextBlock Text="Scan" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,10"/>
                <TextBlock Text="A scan reads only the data that the selected areas need. An area marked slow reads one object at a time from the SMS Provider, so it takes longer on a large site."
                           FontSize="11" TextWrapping="Wrap" Margin="0,0,0,10"
                           Foreground="{DynamicResource MahApps.Brushes.Gray1}"/>
                <ScrollViewer VerticalScrollBarVisibility="Auto" MaxHeight="190">
                    <StackPanel x:Name="panelScopes"/>
                </ScrollViewer>
                <TextBlock Text="The app records the changes since the last scan only when you select every area."
                           FontSize="11" TextWrapping="Wrap" Margin="0,10,0,0"
                           Foreground="{DynamicResource MahApps.Brushes.Gray1}"/>
                <TextBlock Style="{StaticResource OptLabel}" Text="Pause Between Provider Calls (Milliseconds)"/>
                <TextBox x:Name="txtPacing" ToolTip="Enter the pause in milliseconds between the queries of a scan, or 0 for no pause." FontSize="12" Padding="6,4,6,4" Width="120" HorizontalAlignment="Left" MaxLength="5"/>
                <TextBlock Style="{StaticResource OptHint}" Text="The scan runs its queries one after another. A pause spaces them out on a busy SMS Provider. Enter 0 for no pause."/>
                <TextBlock Style="{StaticResource OptLabel}" Text="Report Deployments Older Than (Days)"/>
                <TextBox x:Name="txtDeploymentOldDays" ToolTip="Enter the age in days after which check DPL-06 reports a deployment." FontSize="12" Padding="6,4,6,4" Width="120" HorizontalAlignment="Left" MaxLength="5"/>
                <TextBlock Style="{StaticResource OptHint}" Text="Check DPL-06 reports a deployment that is older. The default is 365 days."/>
            </StackPanel>
            <StackPanel x:Name="paneLive" Visibility="Collapsed">
                <TextBlock Text="Live" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,10"/>
                <TextBlock Style="{StaticResource OptLabel}" Text="Auto-Refresh Interval (Minutes)"/>
                <ComboBox x:Name="cboRefreshInterval" ToolTip="Select the minutes between automatic refreshes of the live views, or 0 to turn the refresh off." Width="160" HorizontalAlignment="Left" FontSize="12">
                    <ComboBoxItem Content="0"/>
                    <ComboBoxItem Content="5"/>
                    <ComboBoxItem Content="10"/>
                    <ComboBoxItem Content="15"/>
                    <ComboBoxItem Content="30"/>
                    <ComboBoxItem Content="60"/>
                </ComboBox>
                <TextBlock Style="{StaticResource OptHint}" Text="The timer starts after the first live refresh of a session, or at launch when the window last showed a Live view. 0 turns it off. A manual refresh resets the timer. Use Pause Auto-Refresh on the action bar to stop it."/>
                <TextBlock Style="{StaticResource OptLabel}" Text="Inactivity Threshold (Days)"/>
                <ComboBox x:Name="cboInactiveDays" ToolTip="Select the days without contact after which a device shows in the Inactive Devices view." Width="160" HorizontalAlignment="Left" FontSize="12">
                    <ComboBoxItem Content="7"/>
                    <ComboBoxItem Content="14"/>
                    <ComboBoxItem Content="30"/>
                    <ComboBoxItem Content="60"/>
                    <ComboBoxItem Content="90"/>
                </ComboBox>
                <TextBlock Style="{StaticResource OptHint}" Text="A device with no discovery data record (DDR) contact in this many days shows in the Inactive Devices view."/>
            </StackPanel>
            <StackPanel x:Name="paneAlerts" Visibility="Collapsed">
                <TextBlock Text="Alerts" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,10"/>
                <CheckBox x:Name="chkAlertsEnabled" ToolTip="Show a Windows toast notification when a live metric crosses its limit after a refresh." Content="Enable Threshold Alerts" FontSize="12" Margin="0,4,0,0"/>
                <TextBlock Style="{StaticResource OptHint}"
                           Text="After each live refresh, an alert shows when a metric crosses its limit. The metrics are a critical site component or site system, a critical distribution point, a failed content distribution, and deployment compliance below the floor. An alert shows again only after the metric recovers and crosses its limit again."/>
                <TextBlock Style="{StaticResource OptLabel}" Text="Deployment Compliance Floor (%)"/>
                <ComboBox x:Name="cboAlertCompliance" ToolTip="Select the compliance percentage below which a deployment raises an alert." Width="160" HorizontalAlignment="Left" FontSize="12">
                    <ComboBoxItem Content="70"/>
                    <ComboBoxItem Content="80"/>
                    <ComboBoxItem Content="90"/>
                    <ComboBoxItem Content="95"/>
                </ComboBox>
                <TextBlock Style="{StaticResource OptHint}"
                           Text="An alert shows as a Windows toast notification. The app also writes a line to Logs\SiteHygiene-alerts.log and to the log pane."/>
            </StackPanel>
            <StackPanel x:Name="paneAbout" Visibility="Collapsed">
                <TextBlock Text="About" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,10"/>
                <TextBlock x:Name="txtAboutVersion" Text="Site Hygiene" FontSize="13" FontWeight="SemiBold"/>
                <TextBlock Text="Scans a ConfigMgr site for unused applications and packages, empty collections, stale and failing deployments, and application relationships. Each finding shows its evidence and the PowerShell that a fix runs. A scan changes nothing. Run Fix runs a script only after you confirm."
                           FontSize="12" TextWrapping="Wrap" Margin="0,8,0,0"/>
                <TextBlock Text="The Live views show the current status of deployments, content, distribution points, clients and the site. They refresh on demand and on a timer, and they keep a history and raise threshold alerts. They create no findings and change nothing."
                           FontSize="12" TextWrapping="Wrap" Margin="0,8,0,0"/>
                <TextBlock Text="Author: Jason Ulbright. License: MIT."
                           FontSize="11" Margin="0,16,0,0" Foreground="{DynamicResource MahApps.Brushes.Gray1}"/>
            </StackPanel>
        </Grid>
        <Border Grid.Row="1" Grid.ColumnSpan="3" Padding="16,12,16,12">
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                <Button x:Name="btnOk"     Content="OK"     Style="{StaticResource DialogAccentButton}" IsDefault="True"/>
                <Button x:Name="btnCancel" Content="Cancel" Style="{StaticResource DialogButton}"        IsCancel="True"/>
            </StackPanel>
        </Border>
    </Grid>
</Controls:MetroWindow>
'@
    [xml]$dx = $dlgXaml
    $reader2 = New-Object System.Xml.XmlNodeReader $dx
    $dlg = [System.Windows.Markup.XamlReader]::Load($reader2)
    $dlg.Owner = $window
    Install-TitleBarDragFallback -Window $dlg
    Set-DialogTheme -Dialog $dlg
    # The category buttons look like the sidebar buttons of the main window: accent color with the ideal foreground in the light theme.
    foreach ($catName in 'btnCatConnection', 'btnCatScope', 'btnCatLive', 'btnCatAlerts', 'btnCatAbout') {
        $cat = $dlg.FindName($catName)
        if (-not [bool]$global:Prefs['DarkMode']) {
            $cat.Background = $dlg.TryFindResource('MahApps.Brushes.Accent')
            $cat.Foreground = $dlg.TryFindResource('MahApps.Brushes.IdealForeground')
            $cat.BorderBrush = $dlg.TryFindResource('MahApps.Brushes.Accent')
        }
    }

    $panes = @{
        Connection = $dlg.FindName('paneConnection')
        Scope      = $dlg.FindName('paneScope')
        Live       = $dlg.FindName('paneLive')
        Alerts     = $dlg.FindName('paneAlerts')
        About      = $dlg.FindName('paneAbout')
    }
    $showPane = {
        param($Name)
        foreach ($k in $panes.Keys) { $panes[$k].Visibility = $(if ($k -eq $Name) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }) }
    }
    $dlg.FindName('btnCatConnection').Add_Click({ & $showPane 'Connection' })
    $dlg.FindName('btnCatScope').Add_Click({      & $showPane 'Scope' })
    $dlg.FindName('btnCatLive').Add_Click({       & $showPane 'Live' })
    $dlg.FindName('btnCatAlerts').Add_Click({     & $showPane 'Alerts' })
    $dlg.FindName('btnCatAbout').Add_Click({      & $showPane 'About' })

    $txtAboutVersion = $dlg.FindName('txtAboutVersion')
    if ($txtAboutVersion) { $txtAboutVersion.Text = "Site Hygiene v$script:AppVersion" }
    $txtSiteCode        = $dlg.FindName('txtSiteCode')
    $txtSmsProvider     = $dlg.FindName('txtSmsProvider')
    $txtSqlServer       = $dlg.FindName('txtSqlServer')
    $chkSqlTrustCert    = $dlg.FindName('chkSqlTrustCert')
    $txtPacing          = $dlg.FindName('txtPacing')
    $txtDeploymentOldDays = $dlg.FindName('txtDeploymentOldDays')
    $panelScopes        = $dlg.FindName('panelScopes')
    $cboRefreshInterval = $dlg.FindName('cboRefreshInterval')
    $cboInactiveDays    = $dlg.FindName('cboInactiveDays')
    $chkAlertsEnabled   = $dlg.FindName('chkAlertsEnabled')
    $cboAlertCompliance = $dlg.FindName('cboAlertCompliance')
    $btnOk              = $dlg.FindName('btnOk')
    $btnCancel          = $dlg.FindName('btnCancel')

    $txtSiteCode.Text    = [string]$global:Prefs.SiteCode
    if ($script:Site.Active) {
        # The launcher chooses the site (Q-112f). The field shows it and does not change it.
        $txtSiteCode.IsReadOnly = $true
        $txtSiteCode.ToolTip = 'The site is chosen in the AppPackager Suite launcher. Restart this tool after you change it.'
    }
    $txtSmsProvider.Text = [string]$global:Prefs.SMSProvider
    $txtSqlServer.Text   = [string]$global:Prefs.SQLServer
    $chkSqlTrustCert.IsChecked = [bool]$global:Prefs.SqlTrustServerCertificate
    $txtPacing.Text      = [string][int]$global:Prefs.ProviderPacingMs
    $txtDeploymentOldDays.Text = [string]$(if ([int]$global:Prefs.DeploymentOldDays -gt 0) { [int]$global:Prefs.DeploymentOldDays } else { 365 })

    $savedScopes = @(@($global:Prefs['ScanScopes']) | Where-Object { $_ })
    $scopeBoxes = @(Get-HygieneScanScope | ForEach-Object {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content   = $(if ($_.Slow) { '{0} (slow)' -f $_.Title } else { $_.Title })
        $cb.Tag       = $_.Id
        $cb.FontSize  = 12
        $cb.Margin    = [System.Windows.Thickness]::new(0, 3, 0, 3)
        $cb.IsChecked = ($savedScopes.Count -eq 0 -or $_.Id -in $savedScopes)
        [void]$panelScopes.Children.Add($cb)
        $cb
    })

    $selectCombo = {
        param($Combo, [string]$Value, [int]$FallbackIndex)
        foreach ($i in $Combo.Items) { if ([string]$i.Content -eq $Value) { $Combo.SelectedItem = $i; break } }
        if (-not $Combo.SelectedItem) { $Combo.SelectedIndex = $FallbackIndex }
    }
    & $selectCombo $cboRefreshInterval ([string][int]$global:Prefs.AutoRefreshMinutes) 3
    & $selectCombo $cboInactiveDays    ([string][int]$global:Prefs.InactiveThresholdDays) 1
    & $selectCombo $cboAlertCompliance ([string][int]$global:Prefs.AlertCompliancePct) 1
    $chkAlertsEnabled.IsChecked = [bool]$global:Prefs.AlertsEnabled

    $btnOk.Add_Click({
        $checked = @($scopeBoxes | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag })
        if ($checked.Count -eq 0) {
            & $showPane 'Scope'
            [void][System.Windows.MessageBox]::Show($dlg, 'Select at least one scan area.', 'Scan Scope')
            return
        }
        $pacing = 0
        if (-not [int]::TryParse(([string]$txtPacing.Text).Trim(), [ref]$pacing) -or $pacing -lt 0 -or $pacing -gt 60000) {
            & $showPane 'Scope'
            [void][System.Windows.MessageBox]::Show($dlg, 'The pause must be a whole number of milliseconds from 0 to 60000.', 'Scan')
            return
        }
        $oldDays = 0
        if (-not [int]::TryParse(([string]$txtDeploymentOldDays.Text).Trim(), [ref]$oldDays) -or $oldDays -lt 30 -or $oldDays -gt 5000) {
            & $showPane 'Scope'
            [void][System.Windows.MessageBox]::Show($dlg, 'The age of an old deployment must be a whole number of days from 30 to 5000.', 'Scan')
            return
        }
        $global:Prefs['DeploymentOldDays'] = $oldDays
        # Empty means everything, so areas added by a later version are
        # scanned without revisiting this dialog.
        $global:Prefs['ScanScopes'] = $(if ($checked.Count -eq $scopeBoxes.Count) { @() } else { $checked })
        $global:Prefs['ProviderPacingMs'] = $pacing
        $newSite     = $(if ($script:Site.Active) { [string]$global:Prefs.SiteCode } else { ([string]$txtSiteCode.Text).Trim() })
        $newProvider = ([string]$txtSmsProvider.Text).Trim()
        $newSql      = ([string]$txtSqlServer.Text).Trim()
        $changed = ($newSite -ne [string]$global:Prefs.SiteCode) -or ($newProvider -ne [string]$global:Prefs.SMSProvider) -or ($newSql -ne [string]$global:Prefs.SQLServer)
        $global:Prefs.SiteCode    = $newSite
        $global:Prefs.SMSProvider = $newProvider
        $global:Prefs.SQLServer   = $newSql
        $global:Prefs.SqlTrustServerCertificate = [bool]$chkSqlTrustCert.IsChecked
        $global:Prefs.AutoRefreshMinutes    = $(if ($cboRefreshInterval.SelectedItem) { [int]([string]$cboRefreshInterval.SelectedItem.Content) } else { 15 })
        $global:Prefs.InactiveThresholdDays = $(if ($cboInactiveDays.SelectedItem)    { [int]([string]$cboInactiveDays.SelectedItem.Content) }    else { 14 })
        $global:Prefs.AlertsEnabled         = [bool]$chkAlertsEnabled.IsChecked
        $global:Prefs.AlertCompliancePct    = $(if ($cboAlertCompliance.SelectedItem) { [int]([string]$cboAlertCompliance.SelectedItem.Content) } else { 80 })
        Save-ShPreferences -Prefs $global:Prefs
        Sync-FooterSite
        Add-LogLine ('Options saved: site={0} provider={1} sql={2} pacing={3}ms interval={4}m threshold={5}d' -f $newSite, $newProvider, $(if ($newSql) { $newSql } else { '(none)' }), $pacing, $global:Prefs.AutoRefreshMinutes, $global:Prefs.InactiveThresholdDays)
        # The background runspace caches the prior connection; a changed
        # site, provider, or SQL server needs a fresh one.
        if ($changed) { Reset-BgConnection }
        Stop-AutoRefresh
        if ($script:AutoTimer -and -not $script:AutoRefreshPaused) { Start-AutoRefreshIfEnabled }
        $dlg.DialogResult = $true; $dlg.Close()
    })
    $btnCancel.Add_Click({ $dlg.DialogResult = $false; $dlg.Close() })
    [void]$dlg.ShowDialog()
    Update-StatusBarSummary
}
$btnOptions.Add_Click({ Show-OptionsDialog })

# =============================================================================
# Fix Supersedence (check SUP-01). The window shows the plan, which applications and deployment types lose which
# reference, and changes nothing until the operator selects Remove References. Cancel closes it without a change.
# The work runs in a runspace of its own, so the window stays open.
# =============================================================================
function Get-SupersedenceFixSelection {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns the selected findings that the fix can act on.')]
    param()
    return @($gridFindings.SelectedItems | Where-Object { $_.CheckId -eq 'SUP-01' -and $_.FixData -and $_.FixState -ne 'Fixed' })
}

function Show-SupersedenceFixDialog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Modal dialog show; reads as a single action.')]
    param([Parameter(Mandatory)][object[]]$Rows)

    $supXaml = @'
<Controls:MetroWindow
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:Controls="clr-namespace:MahApps.Metro.Controls;assembly=MahApps.Metro"
    Title="Fix Supersedence"
    Width="940" Height="560" MinWidth="640" MinHeight="380"
    WindowStartupLocation="CenterOwner" TitleCharacterCasing="Normal"
    GlowBrush="{DynamicResource MahApps.Brushes.Accent}"
    NonActiveGlowBrush="{DynamicResource MahApps.Brushes.Accent}"
    BorderThickness="1" ShowIconOnTitleBar="False">
    <Window.Resources>
        <ResourceDictionary>
            <ResourceDictionary.MergedDictionaries>
                <ResourceDictionary Source="pack://application:,,,/MahApps.Metro;component/Styles/Controls.xaml" />
                <ResourceDictionary Source="pack://application:,,,/MahApps.Metro;component/Styles/Fonts.xaml" />
                <ResourceDictionary Source="pack://application:,,,/MahApps.Metro;component/Styles/Themes/Dark.Steel.xaml" />
            </ResourceDictionary.MergedDictionaries>
            <ControlTemplate x:Key="ThemedButtonTemplate" TargetType="Button">
                <Border x:Name="Bd"
                        Background="{TemplateBinding Background}"
                        BorderBrush="{TemplateBinding BorderBrush}"
                        BorderThickness="{TemplateBinding BorderThickness}"
                        SnapsToDevicePixels="True">
                    <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                      VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                                      Margin="{TemplateBinding Padding}"
                                      RecognizesAccessKey="True"
                                      SnapsToDevicePixels="True"/>
                </Border>
                <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="Bd" Property="Opacity" Value="0.85"/>
                    </Trigger>
                    <Trigger Property="IsKeyboardFocused" Value="True">
                        <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                    </Trigger>
                    <Trigger Property="IsPressed" Value="True">
                        <Setter TargetName="Bd" Property="Opacity" Value="0.7"/>
                    </Trigger>
                    <Trigger Property="IsEnabled" Value="False">
                        <Setter TargetName="Bd" Property="Opacity" Value="0.5"/>
                    </Trigger>
                </ControlTemplate.Triggers>
            </ControlTemplate>
            <Style x:Key="ThemedButtonStyle" TargetType="Button" BasedOn="{StaticResource MahApps.Styles.Button.Square}">
                <Setter Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.Gray2}"/>
                <Setter Property="Template" Value="{StaticResource ThemedButtonTemplate}"/>
                <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                <Setter Property="BorderThickness" Value="1"/>
            </Style>
            <!-- The one secondary style: a gray fill, the theme text color and a visible border. Cancel uses it. The primary style is DialogAccentButton. -->
            <Style x:Key="DialogButton" TargetType="Button" BasedOn="{StaticResource ThemedButtonStyle}">
                <Setter Property="Template" Value="{DynamicResource SuiteNeutralButtonTemplate}"/>
                <Setter Property="Background" Value="{DynamicResource MahApps.Brushes.Gray10}"/>
                <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                <Setter Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.Gray2}"/>
                <Setter Property="MinWidth" Value="90"/><Setter Property="Height" Value="32"/>
                <Setter Property="Margin" Value="0,0,8,0"/>
                <Setter Property="Controls:ControlsHelper.ContentCharacterCasing" Value="Normal"/>
            </Style>
            <Style x:Key="DialogAccentButton" TargetType="Button" BasedOn="{StaticResource ThemedButtonStyle}">
                <Setter Property="Template" Value="{DynamicResource SuiteAccentButtonTemplate}"/>
                <Setter Property="MinWidth" Value="90"/><Setter Property="Height" Value="32"/>
                <Setter Property="Background" Value="{DynamicResource MahApps.Brushes.AccentBase}"/>
                <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.IdealForeground}"/>
                <Setter Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.AccentBase}"/>
                <Setter Property="Margin" Value="0,0,8,0"/>
                <Setter Property="Controls:ControlsHelper.ContentCharacterCasing" Value="Normal"/>
            </Style>
            <!-- Grid headers keep the case of their text, as in the main window. -->
            <Style TargetType="DataGridColumnHeader" BasedOn="{StaticResource MahApps.Styles.DataGridColumnHeader}">
                <Setter Property="Controls:ControlsHelper.ContentCharacterCasing" Value="Normal"/>
            </Style>
        </ResourceDictionary>
    </Window.Resources>
    <Grid Margin="20,16,20,12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock x:Name="txtSummary" Grid.Row="0" FontSize="13" TextWrapping="Wrap" Text="Reading the plan from the site..."/>
        <TextBlock x:Name="txtDetail" Grid.Row="1" FontSize="11" TextWrapping="Wrap" Margin="0,6,0,0"
                   Foreground="{DynamicResource MahApps.Brushes.Gray1}"/>
        <CheckBox x:Name="chkRevisions" Grid.Row="2" Margin="0,8,0,0" FontSize="12" IsChecked="True" IsEnabled="False"
                  Controls:ControlsHelper.ContentCharacterCasing="Normal"
                  Content="Also Delete the Old Revisions This Fix Creates"
                  ToolTip="The change makes a new revision of each application. This step deletes the older revisions of the changed applications, so that check APP-05 does not report them. A revision that another object still uses stays."/>
        <ProgressBar x:Name="barRunning" Grid.Row="3" Height="4" Margin="0,8,0,0" IsIndeterminate="True" Visibility="Collapsed"/>
        <DataGrid x:Name="gridPlan" Grid.Row="4" Margin="0,12,0,0" IsReadOnly="True" AutoGenerateColumns="False"
                  CanUserAddRows="False" CanUserDeleteRows="False" SelectionMode="Single" SelectionUnit="FullRow"
                  HeadersVisibility="Column" GridLinesVisibility="Horizontal" RowHeaderWidth="0" FontSize="12"
                  Background="{DynamicResource MahApps.Brushes.ThemeBackground}"
                  Foreground="{DynamicResource MahApps.Brushes.ThemeForeground}"
                  BorderBrush="{DynamicResource MahApps.Brushes.Gray8}" BorderThickness="1"
                  HorizontalGridLinesBrush="{DynamicResource MahApps.Brushes.Gray8}">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Application" Width="*" Binding="{Binding ApplicationName}"/>
                <DataGridTextColumn Header="Deployment Type" Width="*" Binding="{Binding DeploymentTypeName}"/>
                <DataGridTextColumn Header="Reference To Deleted Application" Width="3*" Binding="{Binding Reference}"/>
                <DataGridTextColumn Header="Result" Width="*" Binding="{Binding Result}"/>
            </DataGrid.Columns>
        </DataGrid>
        <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
            <Button x:Name="btnApply"  Content="Remove References" ToolTip="Remove the listed references from the applications, then run the check again on them." Style="{StaticResource DialogAccentButton}" MinWidth="150" IsEnabled="False"/>
            <Button x:Name="btnCancel" Content="Cancel" Style="{StaticResource DialogButton}"/>
        </StackPanel>
    </Grid>
</Controls:MetroWindow>
'@
    [xml]$supX = $supXaml
    $supReader = New-Object System.Xml.XmlNodeReader $supX
    $supDlg = [System.Windows.Markup.XamlReader]::Load($supReader)
    $supDlg.Owner = $window
    Install-TitleBarDragFallback -Window $supDlg
    Set-DialogTheme -Dialog $supDlg

    $txtSummary = $supDlg.FindName('txtSummary')
    $txtDetail  = $supDlg.FindName('txtDetail')
    $barRunning = $supDlg.FindName('barRunning')
    # The bar is collapsed in the XAML (an indeterminate bar animates for as long as it is visible) and shows while the window reads the plan.
    $barRunning.Visibility = [System.Windows.Visibility]::Visible
    $gridPlan   = $supDlg.FindName('gridPlan')
    $btnApply   = $supDlg.FindName('btnApply')
    $chkRevisions = $supDlg.FindName('chkRevisions')
    $btnCancel  = $supDlg.FindName('btnCancel')

    $siteCode    = [string]$global:Prefs.SiteCode
    $smsProvider = [string]$global:Prefs.SMSProvider
    $targets = @($Rows | ForEach-Object { [pscustomobject]@{ FindingKey = [string]$_.SuppressKey; FixData = $_.FixData } })
    # phase: Planning, Ready, Applying, Done. The timer reads it; the buttons change it.
    $state = [hashtable]::Synchronized(@{ Phase = 'Planning'; Done = $false; Plan = $null; Result = $null; Recheck = $null; ErrorMsg = $null; StopRequested = $false; Cancelled = $false })
    $outcome = [hashtable]@{ Fixed = @(); Removed = 0; Failed = 0; Skipped = 0; Remaining = -1; OldRevisions = -1 }

    $rs = New-SuiteBgRunspace -ModulePath (Join-Path $PSScriptRoot 'Module\SiteHygieneCommon.psd1') -LogPath $script:ToolLogPath
    $run = @{ PowerShell = $null; Handle = $null; Items = $null }
    $startWork = {
        param([scriptblock]$Script, [object[]]$Arguments)
        $state.Done = $false
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($Script)
        foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
        $run.PowerShell = $ps
        $run.Handle = $ps.BeginInvoke()
    }.GetNewClosure()
    $endWork = {
        try { [void]$run.PowerShell.EndInvoke($run.Handle) } catch { $null = $_ }
        try { $run.PowerShell.Dispose() } catch { $null = $_ }
        $run.PowerShell = $null
    }.GetNewClosure()

    $planScript = {
        param($Targets, $SiteCode, $SmsProvider, $State)
        try {
            if (-not (Connect-CMSite -SiteCode $SiteCode -SMSProvider $SmsProvider)) { $State.ErrorMsg = ('Failed to connect to site {0} (SMS Provider {1}).' -f $SiteCode, $SmsProvider); return }
            $State.Plan = Get-HygSupersedencePlan -Target $Targets
        }
        catch { $State.ErrorMsg = 'The plan could not be read. The log file has the details.'; Write-Log ('Fix Supersedence plan failed: {0}' -f $_.Exception.Message) -Level ERROR -Quiet }
        finally { $State.Done = $true }
    }
    $applyScript = {
        param($Plan, $DeleteRevisions, $State)
        try {
            $State.Result = Remove-HygBrokenSupersedence -Plan $Plan -DeleteOldRevisions:([bool]$DeleteRevisions) -State $State -Confirm:$false
            $changed = @($State.Result.Results | Where-Object { $_.Result -eq 'Removed' } | ForEach-Object { $_.Row.ApplicationModelName } | Select-Object -Unique)
            if ($changed.Count -gt 0) { $State.Recheck = Test-HygSupersedenceRecheck -ApplicationModelName $changed }
        }
        catch { $State.ErrorMsg = 'The fix stopped with an error. The log file has the details.'; Write-Log ('Fix Supersedence failed: {0}' -f $_.Exception.Message) -Level ERROR -Quiet }
        finally { $State.Done = $true }
    }

    $words = { param([int]$N, [string]$One, [string]$Many) if ($N -eq 1) { '{0} {1}' -f $N, $One } else { '{0} {1}' -f $N, $Many } }.GetNewClosure()
    $showPlan = {
        $plan = $state.Plan
        $planRows = @($plan.Rows)
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($r in $planRows) {
            $ref = [string]$r.ReferencedApplicationModel
            if ($ref -match '/') { $ref = $ref.Substring($ref.IndexOf('/') + 1) }
            $items.Add([pscustomobject]@{ ApplicationName = $r.ApplicationName; DeploymentTypeName = $r.DeploymentTypeName; Reference = $ref; Result = ''; Row = $r })
        }
        $run.Items = $items
        $gridPlan.ItemsSource = $items
        $apps = @($planRows | Select-Object -ExpandProperty ApplicationModelName -Unique).Count
        $skipped = @($plan.Skipped).Count
        if ($planRows.Count -eq 0) {
            $txtSummary.Text = 'Nothing to remove.'
            $txtDetail.Text = $(if ($skipped -gt 0) { ('{0} no longer need a fix. Scan again to refresh the list.' -f (& $words $skipped 'finding' 'findings')) } else { '' })
            Add-LogLine ('Fix Supersedence: nothing to remove ({0} skipped).' -f $skipped)
            return
        }
        $txtSummary.Text = ('{0} on {1} will be removed.' -f (& $words $planRows.Count 'broken supersedence reference' 'broken supersedence references'), (& $words $apps 'application' 'applications'))
        $txtDetail.Text = ('Only the rules that point at an application that no longer exists are removed. The cmdlets Set-CMApplicationSupersedence and Remove-CMDeploymentTypeSupersedence cannot do this, because they need the deleted application. The fix edits the application document with the serializer of the console and refuses to write when anything but those rules would change. Each change makes a new revision of the application.{0}' -f $(if ($skipped -gt 0) { (' {0} no longer need a fix and are left out.' -f (& $words $skipped 'finding' 'findings')) } else { '' }))
        $chkRevisions.IsEnabled = $true
        $btnApply.IsEnabled = $true
        $state.Phase = 'Ready'
        Add-LogLine ('Fix Supersedence plan: {0} on {1}. Nothing is changed until you confirm.' -f (& $words $planRows.Count 'reference' 'references'), (& $words $apps 'application' 'applications'))
        foreach ($r in $planRows) { Add-LogLine ('  Plan: [{0}] deployment type {1}: remove the broken reference' -f $r.ApplicationName, $r.DeploymentTypeName) }
    }.GetNewClosure()

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $timer.Add_Tick({
        if (-not $state.Done) { return }
        $timer.Stop()
        & $endWork
        $barRunning.Visibility = [System.Windows.Visibility]::Collapsed
        if ($state.ErrorMsg) {
            $txtSummary.Text = [string]$state.ErrorMsg
            $txtDetail.Text = ''
            $btnApply.IsEnabled = $false
            $btnCancel.Content = 'Close'
            $state.Phase = 'Done'
            Add-LogLine ('Fix Supersedence: {0}' -f $state.ErrorMsg) -Level ERROR
            return
        }
        if ($state.Phase -eq 'Planning') { & $showPlan; $btnCancel.Content = 'Cancel'; if ($state.Phase -ne 'Ready') { $btnCancel.Content = 'Close'; $state.Phase = 'Done' }; return }

        # Applying finished.
        $res = $state.Result
        $outcome.Removed = [int]$res.Removed; $outcome.Failed = [int]$res.Failed; $outcome.Skipped = [int]$res.Skipped; 
        foreach ($item in $run.Items) {
            $hit = @($res.Results | Where-Object { $_.Row.RuleId -eq $item.Row.RuleId -and $_.Row.ApplicationModelName -eq $item.Row.ApplicationModelName }) | Select-Object -First 1
            if ($hit) { $item.Result = [string]$hit.Result; if ($hit.Result -eq 'Removed') { $outcome.Fixed += [string]$item.Row.FindingKey } }
        }
        $gridPlan.Items.Refresh()
        $remaining = $(if ($state.Recheck) { [int]$state.Recheck.Remaining } else { -1 })
        $outcome.Remaining = $remaining
        $line = ('{0} removed, {1} failed, {2} skipped.' -f $res.Removed, $res.Failed, $res.Skipped)
        $txtSummary.Text = $(if ($res.Failed -eq 0 -and $res.Removed -gt 0) { ('Removed {0}.' -f (& $words $res.Removed 'broken supersedence reference' 'broken supersedence references')) } else { $line })
        $recheckText = $(if ($remaining -ge 0) { ('Check SUP-01 ran again on the changed applications: {0} left. Old revisions left on them: {1}.' -f $remaining, [int]$state.Recheck.OldRevisions) } else { 'Check SUP-01 was not run again: no reference was removed.' })
        $notes = @($res.Results | Where-Object { $_.Result -eq 'Removed' -and $_.RevisionNote } | ForEach-Object { $_.RevisionNote } | Select-Object -Unique)
        $txtDetail.Text = ('{0} {1}{2}' -f $line, $recheckText, $(if ($notes.Count -gt 0) { ' ' + ($notes -join ' ') } else { '' }))
        Add-LogLine ('Fix Supersedence: {0}' -f $line)
        foreach ($n in $notes) { Add-LogLine ('Fix Supersedence: {0}' -f $n) }
        Add-LogLine ('Fix Supersedence: {0}' -f $recheckText)
        foreach ($m in @($res.Results | Where-Object { $_.Result -eq 'Failed' })) { Add-LogLine ('Fix Supersedence failed [{0}] {1}. The log file has the details.' -f $m.Row.ApplicationName, $m.Row.DeploymentTypeName) -Level WARN }
        $btnCancel.Content = 'Close'
        $state.Phase = 'Done'
    }.GetNewClosure())

    $btnApply.Add_Click({
        if ($state.Phase -ne 'Ready') { return }
        $state.Phase = 'Applying'
        $btnApply.IsEnabled = $false
        $barRunning.Visibility = [System.Windows.Visibility]::Visible
        $chkRevisions.IsEnabled = $false
        $txtSummary.Text = 'Removing the references...'
        Add-LogLine ('Fix Supersedence: confirmed. Removing the references{0}.' -f $(if ([bool]$chkRevisions.IsChecked) { ', then the old revisions of the changed applications' } else { '' }))
        & $startWork $applyScript @($state.Plan, [bool]$chkRevisions.IsChecked, $state)
        $timer.Start()
    }.GetNewClosure())

    $btnCancel.Add_Click({
        switch ($state.Phase) {
            'Planning' {
                $state.Cancelled = $true
                $timer.Stop()
                try { if ($run.PowerShell) { [void]$run.PowerShell.BeginStop($null, $null) } } catch { $null = $_ }
                Add-LogLine 'Fix Supersedence: cancelled. Nothing was changed.'
                $supDlg.Close()
            }
            'Ready' { Add-LogLine 'Fix Supersedence: cancelled. Nothing was changed.'; $supDlg.Close() }
            'Applying' {
                if (-not $state.StopRequested) {
                    $state.StopRequested = $true
                    $btnCancel.IsEnabled = $false
                    $txtSummary.Text = 'Stopping after the application in work...'
                    Add-LogLine 'Fix Supersedence: stop requested. The application in work finishes first.'
                }
            }
            default { $supDlg.Close() }
        }
    }.GetNewClosure())
    $supDlg.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Escape -and $state.Phase -ne 'Applying') { $e.Handled = $true; $btnCancel.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) }
    }.GetNewClosure())
    $supDlg.Add_Closing({
        param($s, $e)
        if ($state.Phase -eq 'Applying') {
            $e.Cancel = $true
            if (-not $state.StopRequested) { $state.StopRequested = $true; $btnCancel.IsEnabled = $false; $txtSummary.Text = 'Stopping after the application in work...' }
            return
        }
        $timer.Stop()
        try { if ($run.PowerShell) { [void]$run.PowerShell.BeginStop($null, $null) } } catch { $null = $_ }
        Close-SuiteBgRunspace -Runspace $rs
    }.GetNewClosure())

    $btnApply.IsEnabled = $false
    & $startWork $planScript @($targets, $siteCode, $smsProvider, $state)
    $timer.Start()
    [void]$supDlg.ShowDialog()
    return [pscustomobject]$outcome
}

$btnFixSupersedence.Add_Click({
    $rows = @(Get-SupersedenceFixSelection)
    if ($rows.Count -eq 0) { return }
    if (Test-BgBusy -Action 'Fix Supersedence') { return }
    Add-LogLine ('Fix Supersedence: {0} finding(s) selected. The plan is read from the site first.' -f $rows.Count)
    $outcome = Show-SupersedenceFixDialog -Rows $rows
    if ($outcome -and @($outcome.Fixed).Count -gt 0) {
        foreach ($row in $script:AllFindings) { if ($row.CheckId -eq 'SUP-01' -and @($outcome.Fixed) -contains [string]$row.SuppressKey) { $row.FixState = 'Fixed' } }
        $gridFindings.Items.Refresh()
        Set-StatusText $(if ($outcome.Failed -eq 0) { 'Supersedence fixed - scan again to confirm.' } else { 'Some references failed - see log.' })
    }
    $btnFixSupersedence.IsEnabled = (@(Get-SupersedenceFixSelection).Count -gt 0)
})

# =============================================================================
# Show Blockers: what blocks the delete of one application. The list is built from the datasets of the last scan, so
# it reads nothing from the site. A task sequence or a collection that the account may not see is not in them.
# =============================================================================
function Show-BlockersDialog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Modal dialog show; reads as a single action.')]
    param([Parameter(Mandatory)][string]$ModelName, [Parameter(Mandatory)][string]$Name)

    $blkXaml = @'
<Controls:MetroWindow
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:Controls="clr-namespace:MahApps.Metro.Controls;assembly=MahApps.Metro"
    Title="What Blocks The Delete"
    Width="900" Height="460" MinWidth="560" MinHeight="300"
    WindowStartupLocation="CenterOwner" TitleCharacterCasing="Normal"
    GlowBrush="{DynamicResource MahApps.Brushes.Accent}"
    NonActiveGlowBrush="{DynamicResource MahApps.Brushes.Accent}"
    BorderThickness="1" ShowIconOnTitleBar="False">
    <Window.Resources>
        <ResourceDictionary>
            <ResourceDictionary.MergedDictionaries>
                <ResourceDictionary Source="pack://application:,,,/MahApps.Metro;component/Styles/Controls.xaml" />
                <ResourceDictionary Source="pack://application:,,,/MahApps.Metro;component/Styles/Fonts.xaml" />
                <ResourceDictionary Source="pack://application:,,,/MahApps.Metro;component/Styles/Themes/Dark.Steel.xaml" />
            </ResourceDictionary.MergedDictionaries>
            <Style x:Key="ThemedButtonStyle" TargetType="Button" BasedOn="{StaticResource MahApps.Styles.Button.Square}">
                <Setter Property="BorderBrush" Value="{DynamicResource MahApps.Brushes.Gray2}"/>
                <Setter Property="Template" Value="{DynamicResource SuiteNeutralButtonTemplate}"/>
                <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.ThemeForeground}"/>
                <Setter Property="BorderThickness" Value="1"/>
            </Style>
            <Style x:Key="DialogButton" TargetType="Button" BasedOn="{StaticResource ThemedButtonStyle}">
                <Setter Property="Background" Value="{DynamicResource MahApps.Brushes.Gray10}"/>
                <Setter Property="MinWidth" Value="90"/><Setter Property="Height" Value="32"/>
                <Setter Property="Margin" Value="0,0,8,0"/>
                <Setter Property="Controls:ControlsHelper.ContentCharacterCasing" Value="Normal"/>
            </Style>
            <Style TargetType="DataGridColumnHeader" BasedOn="{StaticResource MahApps.Styles.DataGridColumnHeader}">
                <Setter Property="Controls:ControlsHelper.ContentCharacterCasing" Value="Normal"/>
            </Style>
        </ResourceDictionary>
    </Window.Resources>
    <Grid Margin="20,16,20,12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock x:Name="txtSummary" Grid.Row="0" FontSize="13" TextWrapping="Wrap"/>
        <TextBlock x:Name="txtNote" Grid.Row="1" FontSize="11" TextWrapping="Wrap" Margin="0,6,0,0" Foreground="{DynamicResource MahApps.Brushes.Gray1}"/>
        <DataGrid x:Name="gridBlockers" Grid.Row="2" Margin="0,12,0,0" IsReadOnly="True" AutoGenerateColumns="False"
                  CanUserAddRows="False" SelectionMode="Single" SelectionUnit="FullRow" HeadersVisibility="Column"
                  GridLinesVisibility="Horizontal" RowHeaderWidth="0" FontSize="12"
                  Background="{DynamicResource MahApps.Brushes.ThemeBackground}"
                  Foreground="{DynamicResource MahApps.Brushes.ThemeForeground}"
                  BorderBrush="{DynamicResource MahApps.Brushes.Gray8}" BorderThickness="1"
                  HorizontalGridLinesBrush="{DynamicResource MahApps.Brushes.Gray8}">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Kind" Width="190" Binding="{Binding Kind}"/>
                <DataGridTextColumn Header="Name" Width="*" Binding="{Binding Name}"/>
                <DataGridTextColumn Header="Detail" Width="2*" Binding="{Binding Detail}"/>
            </DataGrid.Columns>
        </DataGrid>
        <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
            <Button x:Name="btnClose" Content="Close" Style="{StaticResource DialogButton}" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Controls:MetroWindow>
'@
    [xml]$blkX = $blkXaml
    $blkReader = New-Object System.Xml.XmlNodeReader $blkX
    $blkDlg = [System.Windows.Markup.XamlReader]::Load($blkReader)
    $blkDlg.Owner = $window
    Install-TitleBarDragFallback -Window $blkDlg
    Set-DialogTheme -Dialog $blkDlg

    $items = @(Get-HygApplicationBlocker -Data $script:BlockerData -RelationshipData $script:RelData -ModelName $ModelName)
    $blkDlg.FindName('gridBlockers').ItemsSource = $items
    $blkDlg.FindName('txtSummary').Text = $(if ($items.Count -eq 0) { ("Nothing in the last scan refers to '{0}'. The site can still refuse the delete for an object that the scan cannot see." -f $Name) } else { ("{0} blocks the delete of '{1}'." -f $(if ($items.Count -eq 1) { '1 object' } else { '{0} objects' -f $items.Count }), $Name) })
    $blkDlg.FindName('txtNote').Text = 'The list comes from the last scan. A task sequence, a collection or a folder that your account may not see is not in it. A stale reference is a reference row of a task sequence that the site does not return.'
    $blkDlg.FindName('btnClose').Add_Click({ $blkDlg.Close() }.GetNewClosure())
    Add-LogLine ("Show Blockers: {0} object(s) refer to '{1}'." -f $items.Count, $Name)
    [void]$blkDlg.ShowDialog()
}

$btnShowBlockers.Add_Click({
    $row = $gridFindings.SelectedItem
    if (-not $row -or -not $script:BlockerData -or -not $script:RelData) { return }
    $name = [string]$row.ObjectName
    Show-BlockersDialog -ModelName ([string]$row.ObjectId) -Name $name
})


# === Window state (geometry logic: SuiteCommon) ===
$global:WindowStatePath = Join-Path $PSScriptRoot 'SiteHygiene.windowstate.json'

$window.Add_Closing({
    try {
        Save-WindowState -Window $window -Path $global:WindowStatePath -ExtraState @{ ActiveView = $script:ActiveView }
        Stop-AutoRefresh
        Dispose-BgWork
        Close-SuiteBgRunspace -Runspace $script:BgRunspace
    } catch {
        try { & $global:__writeCrash 'ClosingHandler' $_.Exception } catch { $null = $_ }
    }
})

$window.Add_Loaded({
    # The first start, with no saved window state, opens maximized: the design size is a 1080p work area.
    if (-not (Test-Path -LiteralPath $global:WindowStatePath)) { $window.WindowState = [System.Windows.WindowState]::Maximized }
    Restore-WindowState -Window $window -Path $global:WindowStatePath -OnStateLoaded {
        param($s)
        if ($s.ActiveView -in ($script:ScanViews + $script:LiveViews)) { Set-ActiveView -View ([string]$s.ActiveView) }
    }
    $isDark = [bool]$global:Prefs['DarkMode']
    if (-not $isDark) { [void][ControlzEx.Theming.ThemeManager]::Current.ChangeTheme($window, 'Light.Blue') }
    Update-TitleBarBrushes
    Set-ActiveView -View $script:ActiveView
    try { [void](Initialize-SuiteFooter -Window $window -StatusName 'txtStatus' -OnOpenOptions { Show-OptionsDialog }) }
    catch { Write-Log ('Footer: {0}' -f $_.Exception.Message) -Level ERROR -Quiet; Add-LogLine 'The footer failed. The log file has the details.' }
    Sync-FooterSite
    $null = Start-SuiteSiteWatch -Window $window -Site $script:Site
    if ($script:Site.Active) {
        Write-Log ('Site {0}; data in {1}' -f $script:Site.SiteFolder, $script:Site.ToolFolder) -Quiet
        Add-LogLine ('Site {0}; data in sites\{0}\tools\site-hygiene' -f $script:Site.SiteFolder)
    }
    Update-SuppressCount
    $gridSummary.ItemsSource = @(Get-HygieneScanSummary -Findings @())
    Add-LogLine 'Site Hygiene ready. Set the site code and the SMS Provider in Options, then select Scan or Refresh All.'
    # The timer arms at launch only for a window that last showed a Live
    # view; a scan-focused session never starts polling on its own.
    if ($script:ActiveView -in $script:LiveViews -and $global:Prefs.SiteCode -and $global:Prefs.SMSProvider) {
        Start-AutoRefreshIfEnabled
    }
})

# Suite update notice: one shared daily lookup across the suite tools; the launcher installs.
$null = Start-SuiteUpdateNotice -Path $PSScriptRoot -OnResult { param($u) if ($u.Available) { Add-LogLine ('Suite update available: v{0}. Update from the AppPackager Suite Launcher.' -f $u.Latest) } }
[void]$window.ShowDialog()
try { Stop-Transcript | Out-Null } catch { $null = $_ }
