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
      - SiteHygieneCommon module under .\Module\ (pulls in .\Lib\SuiteCommon\)
      - ConfigurationManager console (provides Get-CMApplication, etc.)
      - SqlServer module (Invoke-Sqlcmd) for the Client Health and
        Inactive Devices views; optional

.NOTES
    ScriptName : start-sitehygiene.ps1
    Version    : 2026.09.25.0020
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

$global:PrefsPath   = Join-Path $PSScriptRoot 'SiteHygiene.prefs.json'
$global:HistoryPath = Join-Path $PSScriptRoot 'History\metrics-history.csv'

# A retired ConfigMgr Health Dashboard install leaves its settings and
# history either where the suite installer parked them or in the sibling
# folder of a side-by-side layout. Import fills gaps only, before the
# preferences are read.
foreach ($legacyRoot in @((Join-Path $PSScriptRoot 'legacy\mecm-health-dashboard'), (Join-Path (Split-Path $PSScriptRoot -Parent) 'mecm-health-dashboard'))) {
    if (Test-Path -LiteralPath $legacyRoot) {
        $null = Import-HygieneLegacyDashboardState -LegacyRoot $legacyRoot -PrefsPath $global:PrefsPath -HistoryPath $global:HistoryPath
    }
}

function Get-ShPreferences {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns the full preferences hashtable by design.')]
    param()
    return Read-SuiteSettings -Path $global:PrefsPath -Defaults @{
        DarkMode              = $true
        SiteCode              = ''
        SMSProvider           = ''
        SQLServer             = ''
        ScanScopes            = @()
        ProviderPacingMs      = 0
        AutoRefreshMinutes    = 15
        InactiveThresholdDays = 14
        AlertsEnabled         = $true
        AlertCompliancePct    = 80
    }
}
function Save-ShPreferences {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Writes the full preferences hashtable by design.')]
    param([Parameter(Mandatory)][hashtable]$Prefs)
    $null = Save-SuiteSettings -Path $global:PrefsPath -Settings $Prefs
}
$global:Prefs = Get-ShPreferences

# The suite launcher hands its site code and provider to each tool it starts.
# A value saved in this tool wins; the launcher value fills an empty one.
if (-not $global:Prefs.SiteCode    -and $env:SUITE_CM_SITECODE) { $global:Prefs.SiteCode    = [string]$env:SUITE_CM_SITECODE }
if (-not $global:Prefs.SMSProvider -and $env:SUITE_CM_PROVIDER) { $global:Prefs.SMSProvider = [string]$env:SUITE_CM_PROVIDER }

$global:SuppressPath = Join-Path $PSScriptRoot 'SiteHygiene.suppressions.json'
$global:LastScanPath = Join-Path $PSScriptRoot 'SiteHygiene.lastscan.json'
function Get-ShSuppressedKeys {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns the full suppression key set by design.')]
    param()
    $stored = Read-SuiteSettings -Path $global:SuppressPath -Defaults @{ Keys = @() }
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($k in @($stored.Keys)) {
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

Initialize-SuiteTheme -Window $window `
    -IsDarkGetter { [bool]$global:Prefs['DarkMode'] } `
    -ActiveViewGetter { $script:ActiveView } `
    -ViewButtons $script:ViewButtons `
    -OptionsButton $btnOptions `
    -LogLabel $lblLogOutput

$__startIsDark = [bool]$global:Prefs['DarkMode']
$toggleTheme.IsOn = $__startIsDark
$txtThemeLabel.Text = if ($__startIsDark) { 'Dark Theme' } else { 'Light Theme' }
Update-SidebarButtonTheme

$toggleTheme.Add_Toggled({
    $isDark = [bool]$toggleTheme.IsOn
    if ($isDark) { [void][ControlzEx.Theming.ThemeManager]::Current.ChangeTheme($window, 'Dark.Steel'); $txtThemeLabel.Text = 'Dark Theme' }
    else         { [void][ControlzEx.Theming.ThemeManager]::Current.ChangeTheme($window, 'Light.Blue'); $txtThemeLabel.Text = 'Light Theme' }
    $global:Prefs['DarkMode'] = $isDark
    Save-ShPreferences -Prefs $global:Prefs
    Update-SidebarButtonTheme
    Update-TitleBarBrushes
    if ($script:ActiveView -eq 'Trends') { Update-TrendChart }
    Add-LogLine ('Theme: {0}' -f $(if ($isDark) { 'dark' } else { 'light' }))
})

# === View switching ===
$script:ViewMeta = @{
    'Findings'      = @{ Title = 'Findings';             Subtitle = 'Every hygiene finding from the last scan. Select a row for evidence, recommendation, and the fix script.'; Watermark = 'Filter by object, evidence, or check id...' }
    'Relationships' = @{ Title = 'Relationships';        Subtitle = 'Every supersedence and dependency relationship resolved from SDMPackageXML, healthy ones included. Select a row or a tree node for the application detail.'; Watermark = 'Filter by source, target, or deployment type...' }
    'Summary'       = @{ Title = 'Summary';              Subtitle = 'Per-check counts for the last scan, plus notes about datasets the scan could not read.'; Watermark = 'Filter rows...' }
    'Deployments'   = @{ Title = 'Deployments';          Subtitle = 'Application, package, software-update, and task-sequence deployments. Refresh to populate.'; Watermark = 'Filter by deployment, collection, or type...' }
    'Content'       = @{ Title = 'Content Distribution'; Subtitle = 'Only content with failed or in-progress DP-content pairs is shown. Healthy items are filtered out at the source.'; Watermark = 'Filter by content, package id, or type...' }
    'DPs'           = @{ Title = 'Distribution Points';  Subtitle = 'DP roster with site assignment, status from SMS_SiteSystemSummarizer, and pull-DP flag.'; Watermark = 'Filter by name or site...' }
    'Clients'       = @{ Title = 'Client Health';        Subtitle = 'Per-device CCM health and active status. Requires SQL Server access (CM_<site> database).'; Watermark = 'Filter by device, health, or OS...' }
    'Inactive'      = @{ Title = 'Inactive Devices';     Subtitle = 'Devices exceeding the inactivity threshold (configured in Options). SQL-backed.'; Watermark = 'Filter by device or OS...' }
    'Site'          = @{ Title = 'Site Health';          Subtitle = 'Site components (SMS_ComponentSummarizer) + site-system roles (SMS_SiteSystemSummarizer) in one rollup.'; Watermark = 'Filter by name, server, or type...' }
    'Trends'        = @{ Title = 'Trends';               Subtitle = 'Rolling history per live metric, captured at each completed refresh. Pick a metric and a 7 / 30 / 90 day range.'; Watermark = 'Filters do not apply to the chart' }
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
    $txtFilter.IsEnabled = ($View -notin 'Summary', 'Trends')

    $meta = $script:ViewMeta[$View]
    if ($meta) {
        $txtModuleTitle.Text    = $meta.Title
        $txtModuleSubtitle.Text = $meta.Subtitle
        [MahApps.Metro.Controls.TextBoxHelper]::SetWatermark($txtFilter, [string]$meta.Watermark)
    }
    Update-SidebarButtonTheme
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
    param([Parameter(Mandatory)][object[]]$Rows, [Parameter(Mandatory)][string[]]$Fields)
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
    switch ($script:ActiveView) {
        'Findings'      { $gridFindings.ItemsSource = Get-FilteredFindings }
        'Relationships' { $gridRelationships.ItemsSource = Get-FilteredRelationshipRows }
        'Deployments'   { $gridDeploy.ItemsSource   = Get-FilteredLiveRows -Rows @($script:DeploymentRows) -Fields @('DeploymentName','CollectionName','DeploymentType') }
        'Content'       { $gridContent.ItemsSource  = Get-FilteredLiveRows -Rows @($script:ContentRows)    -Fields @('ContentName','PackageID','ContentType') }
        'DPs'           { $gridDPs.ItemsSource      = Get-FilteredLiveRows -Rows @($script:DPRows)         -Fields @('DPName','SiteCode') }
        'Clients'       { $gridClients.ItemsSource  = Get-FilteredLiveRows -Rows @($script:ClientRows)     -Fields @('DeviceName','HealthState','ActiveStatus','OperatingSystem') }
        'Inactive'      { $gridInactive.ItemsSource = Get-FilteredLiveRows -Rows @($script:InactiveRows)   -Fields @('DeviceName','OperatingSystem') }
        'Site'          { $gridSite.ItemsSource     = Get-FilteredLiveRows -Rows @($script:SiteRows)       -Fields @('Name','MachineName','ItemType') }
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
    if ($sel.Count -eq 0) { Add-LogLine 'Unsuppress: select one or more findings first (enable Show suppressed to see them).'; return }
    foreach ($row in $sel) { [void]$script:SuppressedKeys.Remove([string]$row.SuppressKey) }
    Save-ShSuppressedKeys -KeySet $script:SuppressedKeys
    Add-LogLine ('Unsuppressed {0} finding(s).' -f $sel.Count)
    Update-SuppressCount
    Update-Filter
})

$gridFindings.Add_SelectionChanged({
    $row = $gridFindings.SelectedItem
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
    $title = if ($rows.Count -eq 1) { ('Run fix for {0}?' -f $rows[0].CheckId) } else { ('Run {0} fixes?' -f $rows.Count) }
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
                    $State.ErrorMsg = "Failed to connect to site $SiteCode (provider $SMSProvider)."; return
                }
            }
            $results = @{}
            foreach ($f in @($Findings)) {
                $results[[string]$f.SuppressKey] = Invoke-HygieneFix -Finding $f
            }
            $State.Results = $results
        }
        catch { $State.ErrorMsg = $_.Exception.Message }
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
                    $reason = if ($result) { $result.ErrorMessage } else { 'no result returned' }
                    Add-LogLine ('Fix failed [{0}] {1}: {2}' -f $row.CheckId, $row.ObjectName, $reason) -Level WARN
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
        Add-LogLine 'Scan: site code and SMS provider must be set in Options first.' -Level WARN
        Set-StatusText 'Open Options to configure site code and SMS provider, then scan.'
        return
    }
    if (Test-BgBusy -Action 'Scan') { return }
    Initialize-BgRunspace
    Dispose-BgWork
    $script:BgKind = 'Scan'
    $script:BgState = [hashtable]::Synchronized(@{ Step = 'Connecting...'; Done = $false; Findings = $null; Summary = $null; Notes = $null; RelData = $null; ErrorMsg = $null })
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
    Add-LogLine ('Scan: site={0} provider={1} scope={2} pacing={3}ms' -f $global:Prefs.SiteCode, $global:Prefs.SMSProvider, $(if ($script:ScanIsFull) { 'everything' } else { $scopes -join ', ' }), $pacing)
    Set-StatusText 'Scanning...'

    $siteCode    = [string]$global:Prefs.SiteCode
    $smsProvider = [string]$global:Prefs.SMSProvider

    $script:BgPowerShell = [powershell]::Create()
    $script:BgPowerShell.Runspace = $script:BgRunspace
    [void]$script:BgPowerShell.AddScript({
        param($SiteCode, $SMSProvider, $State, $Scopes, $PacingMs)
        try {
            if (-not (Test-CMConnection)) {
                $State.Step = "Connecting to $SiteCode..."
                $ok = Connect-CMSite -SiteCode $SiteCode -SMSProvider $SMSProvider
                if (-not $ok) { $State.ErrorMsg = "Failed to connect to site $SiteCode (provider $SMSProvider)."; return }
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
            $findings = @(Invoke-HygieneScan -Data $data -RelationshipData $relData -Scopes $Scopes)

            $notes = @($data.DatasetNotes)
            if ($relData) { $notes += @($relData.DatasetNotes) }
            elseif ($datasets -contains 'Relationships') { $notes += 'Relationship data unavailable; SUP/DEP/REL and APP-04 checks were skipped.' }

            $State.Findings = $findings
            $State.Summary  = @(Get-HygieneScanSummary -Findings $findings)
            $State.Notes    = $notes
            $State.RelData  = $relData
        }
        catch { $State.ErrorMsg = $_.Exception.Message }
        finally { $State.Done = $true }
    }).AddArgument($siteCode).AddArgument($smsProvider).AddArgument($script:BgState).AddArgument([string[]]$scopes).AddArgument($pacing)

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
                    FixState       = ''
                    SuppressKey    = Get-HygieneSuppressionKey -Finding $_
                }
            })
            $script:SummaryRows  = @($script:BgState.Summary)
            $script:DatasetNotes = @($script:BgState.Notes)
            $script:RelData      = $script:BgState.RelData
            Update-RelationshipViews

            $gridSummary.ItemsSource = $script:SummaryRows
            $txtDatasetNotes.Text = if ($script:DatasetNotes.Count -gt 0) {
                "Dataset notes:`r`n" + (($script:DatasetNotes | ForEach-Object { "  - $_" }) -join "`r`n")
            } else { 'All datasets loaded cleanly.' }

            Update-Filter
            Update-StatusBarSummary
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
    # Warn; sixty days escalates to Error.
    if ([int]$Row.DaysSinceContact -gt 60) { return $script:Glyph.Error }
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
    if (-not $row) { $txtContentDetail.Text = 'Select a content item to see DP breakdown.'; return }
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
    if (-not $global:Prefs.SiteCode -or -not $global:Prefs.SMSProvider) { $parts += 'Open Options to configure site code and SMS provider' }
    elseif ($script:LastScanTime -or $script:LiveConnected) { $parts += ('Connected to {0}' -f $global:Prefs.SiteCode) }
    elseif ($isLive) { $parts += 'Ready. Click Refresh All.' }
    else { $parts += 'Ready. Click Scan.' }

    if ($isLive) {
        if ($script:DeploymentCounts) { $parts += ('{0} deployments / {1} failed' -f $script:DeploymentCounts.TotalDeployments, $script:DeploymentCounts.FailedDeployments) }
        if ($script:ContentCounts)    { $parts += ('{0} content issues' -f $script:ContentCounts.TotalContentWithIssues) }
        if ($script:DPCounts)         { $parts += ('{0} DPs / {1} offline' -f $script:DPCounts.TotalDPs, $script:DPCounts.OfflineCount) }
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

$script:TrendLineBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#0078D4')
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

    $rows = @(Get-MetricsHistory -HistoryPath $global:HistoryPath -Days $days)
    $points = @(foreach ($r in $rows) {
        $v = $r.$column
        if ($null -ne $v -and '' -ne [string]$v) {
            [PSCustomObject]@{ T = $r.TimestampValue; V = [double]$v }
        }
    })
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
    $poly.Stroke = $script:TrendLineBrush
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
            $dot.Fill = $script:TrendLineBrush
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
        Add-LogLine 'Refresh: site code and SMS provider must be set in Options first.' -Level WARN
        Set-StatusText 'Open Options to configure site code and SMS provider, then refresh.'
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

    $script:BgPowerShell = [powershell]::Create()
    $script:BgPowerShell.Runspace = $script:BgRunspace
    [void]$script:BgPowerShell.AddScript({
        param($SiteCode, $SMSProvider, $SQLServer, $ThresholdDays, $State)
        try {
            if (-not (Test-CMConnection)) {
                $State.Step = "Connecting to $SiteCode..."
                $ok = Connect-CMSite -SiteCode $SiteCode -SMSProvider $SMSProvider
                if (-not $ok) { $State.ErrorMsg = "Failed to connect to site $SiteCode (provider $SMSProvider)."; return }
            }

            $sqlOk = $false
            if ($SQLServer) {
                $State.Step = "Testing SQL connection ($SQLServer)..."
                $sqlOk = Test-SQLConnection -SQLServer $SQLServer -SiteCode $SiteCode
            }

            $State.Step = 'Querying deployment health...'
            $deployData = @(Get-DeploymentHealth)
            $deployCounts = Get-DeploymentHealthCounts -DeploymentData $deployData

            $State.Step = 'Querying content distribution health...'
            $contentData = @(Get-ContentDistributionHealth -SMSProvider $SMSProvider -SiteCode $SiteCode)
            $contentCounts = Get-ContentHealthCounts -ContentData $contentData

            $State.Step = 'Resolving content names...'
            $nameMap = Get-ContentNameMap -SMSProvider $SMSProvider -SiteCode $SiteCode

            $State.Step = 'Querying distribution point health...'
            $dpData = @(Get-DPHealth -SMSProvider $SMSProvider -SiteCode $SiteCode)
            $dpCounts = Get-DPHealthCounts -DPData $dpData

            $clientData = @(); $clientCounts = $null
            $inactiveData = @(); $inactiveCounts = $null
            if ($sqlOk) {
                $State.Step = 'Querying client health (SQL)...'
                $clientData = @(Get-ClientHealthSummary -SQLServer $SQLServer -SiteCode $SiteCode)
                $clientCounts = Get-ClientHealthCounts -ClientData $clientData

                $State.Step = "Querying inactive devices (>$ThresholdDays days)..."
                $inactiveData = @(Get-InactiveDevices -SQLServer $SQLServer -SiteCode $SiteCode -ThresholdDays $ThresholdDays)
                $inactiveCounts = Get-InactiveDeviceCounts -DeviceData $inactiveData
            }

            $State.Step = 'Querying site component health...'
            $componentData = @(Get-SiteComponentHealth -SMSProvider $SMSProvider -SiteCode $SiteCode)
            $State.Step = 'Querying site system health...'
            $systemData = @(Get-SiteSystemHealth -SMSProvider $SMSProvider -SiteCode $SiteCode)
            $siteCounts = Get-SiteHealthCounts -ComponentData $componentData -SystemData $systemData

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
        catch { $State.ErrorMsg = $_.Exception.Message }
        finally { $State.Done = $true }
    }).AddArgument($siteCode).AddArgument($smsProvider).AddArgument($sqlServer).AddArgument($threshold).AddArgument($script:BgState)

    $script:BgInvokeHandle = $script:BgPowerShell.BeginInvoke()
    $script:BgTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:BgTimer.Interval = [TimeSpan]::FromMilliseconds(150)
    $script:BgTimer.Add_Tick({
        if ($script:BgState) {
            $current = [string]$script:BgState.Step
            if ($txtProgressStep.Text -ne $current) { $txtProgressStep.Text = $current }
        }
        Read-BgInformationStream
        if ($script:BgState -and $script:BgState.Done) {
            Complete-BgInvoke

            if ($script:BgState.ErrorMsg) {
                $progressOverlay.Visibility = [System.Windows.Visibility]::Collapsed
                $btnRefreshAll.IsEnabled = $true
                $script:LiveConnected = $false
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
            $progressOverlay.Visibility = [System.Windows.Visibility]::Collapsed
            $btnRefreshAll.IsEnabled = $true

            $sqlNote = if ($r.SqlOk) { 'SQL ok' } else { 'SQL skipped' }
            Add-LogLine ('Refresh complete: {0} deployments, {1} content issues, {2} DPs, {3} clients, {4} inactive, {5} site items ({6})' -f $script:DeploymentRows.Count, $script:ContentRows.Count, $script:DPRows.Count, $script:ClientRows.Count, $script:InactiveRows.Count, $script:SiteRows.Count, $sqlNote)
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
        return $dt
    }
    foreach ($row in @($Rows)) {
        $vals = @()
        foreach ($col in $dt.Columns) { $vals += [string]$row.PSObject.Properties[$col.ColumnName].Value }
        [void]$dt.Rows.Add($vals)
    }
    return $dt
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
            $rows = @(Get-MetricsHistory -HistoryPath $global:HistoryPath -Days (Get-TrendRangeDays)) |
                Where-Object { $null -ne $_.$column -and '' -ne [string]$_.$column } |
                ForEach-Object { [PSCustomObject]@{ Timestamp = $_.TimestampValue.ToString('yyyy-MM-dd HH:mm:ss'); Value = $_.$column } }
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
    $reportsDir = Join-Path $PSScriptRoot 'Reports'
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
            <Style x:Key="CategoryRowStyle" TargetType="Button" BasedOn="{StaticResource MahApps.Styles.Button.Square}">
                <Setter Property="Height" Value="36"/>
                <Setter Property="HorizontalContentAlignment" Value="Left"/>
                <Setter Property="Padding" Value="14,0,14,0"/>
                <Setter Property="FontSize" Value="13"/>
                <Setter Property="Controls:ControlsHelper.ContentCharacterCasing" Value="Normal"/>
                <Setter Property="Margin" Value="0"/>
            </Style>
            <Style x:Key="DialogButton" TargetType="Button" BasedOn="{StaticResource MahApps.Styles.Button.Square}">
                <Setter Property="MinWidth" Value="90"/><Setter Property="Height" Value="32"/>
                <Setter Property="Margin" Value="0,0,8,0"/>
                <Setter Property="Controls:ControlsHelper.ContentCharacterCasing" Value="Normal"/>
            </Style>
            <Style x:Key="DialogAccentButton" TargetType="Button" BasedOn="{StaticResource MahApps.Styles.Button.Square.Accent}">
                <Setter Property="MinWidth" Value="90"/><Setter Property="Height" Value="32"/>
                <Setter Property="Margin" Value="0,0,8,0"/>
                <Setter Property="Controls:ControlsHelper.ContentCharacterCasing" Value="Normal"/>
            </Style>
            <Style x:Key="OptLabel" TargetType="TextBlock">
                <Setter Property="FontSize" Value="11"/>
                <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.Gray1}"/>
                <Setter Property="Margin" Value="0,12,0,2"/>
            </Style>
            <Style x:Key="OptHint" TargetType="TextBlock">
                <Setter Property="FontSize" Value="10"/>
                <Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.Gray3}"/>
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
                <Button x:Name="btnCatConnection" Content="Connection" Style="{StaticResource CategoryRowStyle}"/>
                <Button x:Name="btnCatScope"      Content="Scan"       Style="{StaticResource CategoryRowStyle}"/>
                <Button x:Name="btnCatLive"       Content="Live"       Style="{StaticResource CategoryRowStyle}"/>
                <Button x:Name="btnCatAlerts"     Content="Alerts"     Style="{StaticResource CategoryRowStyle}"/>
                <Button x:Name="btnCatAbout"      Content="About"      Style="{StaticResource CategoryRowStyle}"/>
            </StackPanel>
        </Border>
        <Border Grid.Column="1" Grid.Row="0" Background="{DynamicResource MahApps.Brushes.Gray8}"/>
        <Grid Grid.Column="2" Grid.Row="0" Margin="20,16,20,16">
            <StackPanel x:Name="paneConnection" Visibility="Visible">
                <TextBlock Text="Configuration Manager Connection" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,10"/>
                <TextBlock Style="{StaticResource OptLabel}" Text="Site Code"/>
                <TextBox x:Name="txtSiteCode" FontSize="12" Padding="6,4,6,4" MaxLength="3"
                         Controls:TextBoxHelper.Watermark="e.g. MCM" Width="120" HorizontalAlignment="Left"/>
                <TextBlock Style="{StaticResource OptLabel}" Text="SMS Provider FQDN"/>
                <TextBox x:Name="txtSmsProvider" FontSize="12" Padding="6,4,6,4"
                         Controls:TextBoxHelper.Watermark="e.g. cm01.contoso.com"/>
                <TextBlock Style="{StaticResource OptHint}" Text="Used for the CM PSDrive root. Every scan and live query runs through that connection under your Configuration Manager role. A scan never mutates the site; the account only needs read access."/>
                <TextBlock Style="{StaticResource OptLabel}" Text="SQL Server (optional)"/>
                <TextBox x:Name="txtSqlServer" FontSize="12" Padding="6,4,6,4"
                         Controls:TextBoxHelper.Watermark="e.g. cm01.contoso.com (blank to skip SQL views)"/>
                <TextBlock Style="{StaticResource OptHint}" Text="SQL instance hosting CM_&lt;site&gt; (FQDN or FQDN\InstanceName). Leave blank to skip the Client Health and Inactive Devices views."/>
            </StackPanel>
            <StackPanel x:Name="paneScope" Visibility="Collapsed">
                <TextBlock Text="Scan" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,10"/>
                <TextBlock Text="A scan queries only the datasets the selected areas need. Areas marked slow read one object at a time from the SMS Provider and scale with object count."
                           FontSize="11" TextWrapping="Wrap" Margin="0,0,0,10"
                           Foreground="{DynamicResource MahApps.Brushes.Gray1}"/>
                <ScrollViewer VerticalScrollBarVisibility="Auto" MaxHeight="190">
                    <StackPanel x:Name="panelScopes"/>
                </ScrollViewer>
                <TextBlock Text="Rescan deltas are recorded only when every area is selected."
                           FontSize="11" TextWrapping="Wrap" Margin="0,10,0,0"
                           Foreground="{DynamicResource MahApps.Brushes.Gray1}"/>
                <TextBlock Style="{StaticResource OptLabel}" Text="Pause between provider calls (milliseconds)"/>
                <TextBox x:Name="txtPacing" FontSize="12" Padding="6,4,6,4" Width="120" HorizontalAlignment="Left" MaxLength="5"/>
                <TextBlock Style="{StaticResource OptHint}" Text="Scan queries run one after another. A pause spaces them out on a busy SMS Provider; 0 sends them back to back."/>
            </StackPanel>
            <StackPanel x:Name="paneLive" Visibility="Collapsed">
                <TextBlock Text="Live" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,10"/>
                <TextBlock Style="{StaticResource OptLabel}" Text="Auto-refresh interval (minutes)"/>
                <ComboBox x:Name="cboRefreshInterval" Width="160" HorizontalAlignment="Left" FontSize="12">
                    <ComboBoxItem Content="0"/>
                    <ComboBoxItem Content="5"/>
                    <ComboBoxItem Content="10"/>
                    <ComboBoxItem Content="15"/>
                    <ComboBoxItem Content="30"/>
                    <ComboBoxItem Content="60"/>
                </ComboBox>
                <TextBlock Style="{StaticResource OptHint}" Text="The timer arms after the first live refresh of a session, or at launch when the window last showed a Live view. 0 turns it off. Manual refresh resets it; Pause / Resume sits on the action bar."/>
                <TextBlock Style="{StaticResource OptLabel}" Text="Inactivity threshold (days)"/>
                <ComboBox x:Name="cboInactiveDays" Width="160" HorizontalAlignment="Left" FontSize="12">
                    <ComboBoxItem Content="7"/>
                    <ComboBoxItem Content="14"/>
                    <ComboBoxItem Content="30"/>
                    <ComboBoxItem Content="60"/>
                    <ComboBoxItem Content="90"/>
                </ComboBox>
                <TextBlock Style="{StaticResource OptHint}" Text="Devices with no DDR contact in this many days appear in the Inactive Devices view."/>
            </StackPanel>
            <StackPanel x:Name="paneAlerts" Visibility="Collapsed">
                <TextBlock Text="Alerts" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,10"/>
                <CheckBox x:Name="chkAlertsEnabled" Content="Enable threshold alerts" FontSize="12" Margin="0,4,0,0"/>
                <TextBlock Style="{StaticResource OptHint}"
                           Text="On each completed live refresh, alerts fire when a metric crosses into breach: any critical site component / site system, any critical distribution point, any failed DP-content pair, or overall deployment compliance below the floor. Alerts repeat only after the metric recovers and breaches again."/>
                <TextBlock Style="{StaticResource OptLabel}" Text="Deployment compliance floor (%)"/>
                <ComboBox x:Name="cboAlertCompliance" Width="160" HorizontalAlignment="Left" FontSize="12">
                    <ComboBoxItem Content="70"/>
                    <ComboBoxItem Content="80"/>
                    <ComboBoxItem Content="90"/>
                    <ComboBoxItem Content="95"/>
                </ComboBox>
                <TextBlock Style="{StaticResource OptHint}"
                           Text="Delivery is local-only: a Windows toast notification plus an audit line in Logs\SiteHygiene-alerts.log and the log drawer."/>
            </StackPanel>
            <StackPanel x:Name="paneAbout" Visibility="Collapsed">
                <TextBlock Text="About" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,10"/>
                <TextBlock x:Name="txtAboutVersion" Text="Site Hygiene" FontSize="13" FontWeight="SemiBold"/>
                <TextBlock Text="Configuration Manager site hygiene scanning: unused applications and packages, dead collections, stale and failing deployments, and every application relationship. Every finding carries its evidence and the PowerShell a fix would run. A scan changes nothing. Run Fix runs a script only after you confirm it."
                           FontSize="12" TextWrapping="Wrap" Margin="0,8,0,0"/>
                <TextBlock Text="The Live views show current deployment, content, distribution point, client, and site status on demand and on a timer, with history and threshold alerts. They create no findings and change nothing."
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
    $txtPacing          = $dlg.FindName('txtPacing')
    $panelScopes        = $dlg.FindName('panelScopes')
    $cboRefreshInterval = $dlg.FindName('cboRefreshInterval')
    $cboInactiveDays    = $dlg.FindName('cboInactiveDays')
    $chkAlertsEnabled   = $dlg.FindName('chkAlertsEnabled')
    $cboAlertCompliance = $dlg.FindName('cboAlertCompliance')
    $btnOk              = $dlg.FindName('btnOk')
    $btnCancel          = $dlg.FindName('btnCancel')

    $txtSiteCode.Text    = [string]$global:Prefs.SiteCode
    $txtSmsProvider.Text = [string]$global:Prefs.SMSProvider
    $txtSqlServer.Text   = [string]$global:Prefs.SQLServer
    $txtPacing.Text      = [string][int]$global:Prefs.ProviderPacingMs

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
            [void][System.Windows.MessageBox]::Show($dlg, 'Select at least one scan area.', 'Scan scope')
            return
        }
        $pacing = 0
        if (-not [int]::TryParse(([string]$txtPacing.Text).Trim(), [ref]$pacing) -or $pacing -lt 0 -or $pacing -gt 60000) {
            & $showPane 'Scope'
            [void][System.Windows.MessageBox]::Show($dlg, 'The pause must be a whole number of milliseconds from 0 to 60000.', 'Scan')
            return
        }
        # Empty means everything, so areas added by a later version are
        # scanned without revisiting this dialog.
        $global:Prefs['ScanScopes'] = $(if ($checked.Count -eq $scopeBoxes.Count) { @() } else { $checked })
        $global:Prefs['ProviderPacingMs'] = $pacing
        $newSite     = ([string]$txtSiteCode.Text).Trim()
        $newProvider = ([string]$txtSmsProvider.Text).Trim()
        $newSql      = ([string]$txtSqlServer.Text).Trim()
        $changed = ($newSite -ne [string]$global:Prefs.SiteCode) -or ($newProvider -ne [string]$global:Prefs.SMSProvider) -or ($newSql -ne [string]$global:Prefs.SQLServer)
        $global:Prefs.SiteCode    = $newSite
        $global:Prefs.SMSProvider = $newProvider
        $global:Prefs.SQLServer   = $newSql
        $global:Prefs.AutoRefreshMinutes    = $(if ($cboRefreshInterval.SelectedItem) { [int]([string]$cboRefreshInterval.SelectedItem.Content) } else { 15 })
        $global:Prefs.InactiveThresholdDays = $(if ($cboInactiveDays.SelectedItem)    { [int]([string]$cboInactiveDays.SelectedItem.Content) }    else { 14 })
        $global:Prefs.AlertsEnabled         = [bool]$chkAlertsEnabled.IsChecked
        $global:Prefs.AlertCompliancePct    = $(if ($cboAlertCompliance.SelectedItem) { [int]([string]$cboAlertCompliance.SelectedItem.Content) } else { 80 })
        Save-ShPreferences -Prefs $global:Prefs
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
    Restore-WindowState -Window $window -Path $global:WindowStatePath -OnStateLoaded {
        param($s)
        if ($s.ActiveView -in ($script:ScanViews + $script:LiveViews)) { Set-ActiveView -View ([string]$s.ActiveView) }
    }
    $isDark = [bool]$global:Prefs['DarkMode']
    if (-not $isDark) { [void][ControlzEx.Theming.ThemeManager]::Current.ChangeTheme($window, 'Light.Blue') }
    Update-TitleBarBrushes
    Set-ActiveView -View $script:ActiveView
    Update-SuppressCount
    $gridSummary.ItemsSource = @(Get-HygieneScanSummary -Findings @())
    Add-LogLine 'Site Hygiene ready. Configure Site / Provider in Options, then click Scan or Refresh All.'
    # The timer arms at launch only for a window that last showed a Live
    # view; a scan-focused session never starts polling on its own.
    if ($script:ActiveView -in $script:LiveViews -and $global:Prefs.SiteCode -and $global:Prefs.SMSProvider) {
        Start-AutoRefreshIfEnabled
    }
})

[void]$window.ShowDialog()
try { Stop-Transcript | Out-Null } catch { $null = $_ }
