<#
.SYNOPSIS
    MahApps.Metro WPF shell for the MECM Site Hygiene scanner.

.DESCRIPTION
    Sidebar navigation across two views (Findings, Summary), inline action
    bar (Scan, filter, category filter, severity filter, exports), and an
    Options modal. A scan is read-only: every finding shows its evidence,
    a recommendation, and the exact PowerShell a fix would run - the
    script is displayed, never executed, by this tool.

    Requirements:
      - PowerShell 5.1
      - .NET Framework 4.7.2+
      - MahApps.Metro DLLs in .\Lib\
      - SiteHygieneCommon module under .\Module\ (pulls in .\Lib\SuiteCommon\)
      - ConfigurationManager console (provides Get-CMApplication, etc.)

.NOTES
    ScriptName : start-sitehygiene.ps1
    Version    : 0.3.0
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

$global:PrefsPath = Join-Path $PSScriptRoot 'SiteHygiene.prefs.json'
function Get-ShPreferences {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns the full preferences hashtable by design.')]
    param()
    return Read-SuiteSettings -Path $global:PrefsPath -Defaults @{ DarkMode = $true; SiteCode = ''; SMSProvider = '' }
}
function Save-ShPreferences {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Writes the full preferences hashtable by design.')]
    param([Parameter(Mandatory)][hashtable]$Prefs)
    $null = Save-SuiteSettings -Path $global:PrefsPath -Settings $Prefs
}
$global:Prefs = Get-ShPreferences

$global:SuppressPath = Join-Path $PSScriptRoot 'SiteHygiene.suppressions.json'
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

$script:ToolLogPath = Join-Path $__txDir ('SiteHygiene-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Initialize-Logging -LogPath $script:ToolLogPath

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
$btnOptions           = $window.FindName('btnOptions')

$txtModuleTitle    = $window.FindName('txtModuleTitle')
$txtModuleSubtitle = $window.FindName('txtModuleSubtitle')

$btnScan       = $window.FindName('btnScan')
$btnSuppress        = $window.FindName('btnSuppress')
$btnUnsuppress      = $window.FindName('btnUnsuppress')
$chkShowSuppressed  = $window.FindName('chkShowSuppressed')
$txtSuppressCount   = $window.FindName('txtSuppressCount')
$txtFilter     = $window.FindName('txtFilter')
$cboCategory   = $window.FindName('cboCategory')
$cboSeverity   = $window.FindName('cboSeverity')
$btnExportCsv  = $window.FindName('btnExportCsv')
$btnExportHtml = $window.FindName('btnExportHtml')

$viewFindings      = $window.FindName('viewFindings')
$viewRelationships = $window.FindName('viewRelationships')
$viewSummary       = $window.FindName('viewSummary')
$gridFindings      = $window.FindName('gridFindings')
$txtFindingDetail  = $window.FindName('txtFindingDetail')
$treeRelationships     = $window.FindName('treeRelationships')
$txtRelationshipDetail = $window.FindName('txtRelationshipDetail')
$gridSummary       = $window.FindName('gridSummary')
$txtDatasetNotes   = $window.FindName('txtDatasetNotes')

$progressOverlay  = $window.FindName('progressOverlay')
$txtProgressTitle = $window.FindName('txtProgressTitle')
$txtProgressStep  = $window.FindName('txtProgressStep')

$lblLogOutput = $window.FindName('lblLogOutput')
$txtLog       = $window.FindName('txtLog')
$txtStatus    = $window.FindName('txtStatus')

$null = $txtAppTitle, $txtVersion, $txtProgressTitle

function Add-LogLine {
    param([Parameter(Mandatory)][string]$Message)
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
)
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
    Add-LogLine ('Theme: {0}' -f $(if ($isDark) { 'dark' } else { 'light' }))
})

# === View switching ===
$script:ViewMeta = @{
    'Findings'      = @{ Title = 'Findings';      Subtitle = 'Every hygiene finding from the last scan. Select a row for evidence, recommendation, and the fix script.' }
    'Relationships' = @{ Title = 'Relationships'; Subtitle = 'Supersedence chains and dependency trees resolved from SDMPackageXML. Select a node for the application detail.' }
    'Summary'       = @{ Title = 'Summary';       Subtitle = 'Per-check counts for the last scan, plus notes about datasets the scan could not read.' }
}
function Set-ActiveView {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='In-window Visibility + header text only.')]
    param([Parameter(Mandatory)][ValidateSet('Findings','Relationships','Summary')][string]$View)
    $script:ActiveView = $View
    $viewFindings.Visibility      = if ($View -eq 'Findings')      { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    $viewRelationships.Visibility = if ($View -eq 'Relationships') { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    $viewSummary.Visibility       = if ($View -eq 'Summary')       { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    $meta = $script:ViewMeta[$View]
    if ($meta) {
        $txtModuleTitle.Text    = $meta.Title
        $txtModuleSubtitle.Text = $meta.Subtitle
    }
    Update-SidebarButtonTheme
    Update-StatusBarSummary
}
$btnViewFindings.Add_Click({      Set-ActiveView -View 'Findings'      })
$btnViewRelationships.Add_Click({ Set-ActiveView -View 'Relationships' })
$btnViewSummary.Add_Click({       Set-ActiveView -View 'Summary'       })

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
$window.Dispatcher.Add_UnhandledException({ param($s, $e) & $global:__writeCrash 'DispatcherUnhandledException' $e.Exception; $e.Handled = $false })
[AppDomain]::CurrentDomain.Add_UnhandledException({ param($s, $e) & $global:__writeCrash 'AppDomainUnhandledException' ([Exception]$e.ExceptionObject) })

# === State ===
$script:AllFindings    = @()
$script:SummaryRows    = @()
$script:DatasetNotes   = @()
$script:LastScanTime   = $null
$script:RelData        = $null

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

function Update-RelationshipTree {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Rebuilds the in-window TreeView.')]
    param()
    $treeRelationships.Items.Clear()
    if (-not $script:RelData) {
        $txtRelationshipDetail.Text = 'Relationship data was not collected on the last scan.'
        return
    }
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
}

function Get-SeverityGlyph {
    param([string]$Severity)
    switch ($Severity) {
        'Error'   { return [char]0x2717 }
        'Warning' { return [char]0x26A0 }
        default   { return [char]0x2139 }
    }
}

function Update-StatusBarSummary {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='In-window TextBlock update.')]
    param()
    $parts = @()
    if (-not $global:Prefs.SiteCode -or -not $global:Prefs.SMSProvider) { $parts += 'Open Options to configure site code and SMS provider' }
    elseif (-not $script:LastScanTime) { $parts += 'Ready. Click Scan.' }
    else { $parts += ('Connected to {0}' -f $global:Prefs.SiteCode) }
    if (@($script:AllFindings).Count -gt 0) {
        $errors   = @($script:AllFindings | Where-Object { $_.Severity -eq 'Error' }).Count
        $warnings = @($script:AllFindings | Where-Object { $_.Severity -eq 'Warning' }).Count
        $infos    = @($script:AllFindings | Where-Object { $_.Severity -eq 'Info' }).Count
        $parts += ('{0} findings ({1} error, {2} warning, {3} info)' -f @($script:AllFindings).Count, $errors, $warnings, $infos)
    }
    if ($script:LastScanTime) { $parts += ('last scan {0}' -f $script:LastScanTime.ToString('HH:mm:ss')) }
    Set-StatusText ($parts -join '   |   ')
}

# === Filter ===
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
function Update-Filter {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Recomputes ItemsSource on the findings grid.')]
    param()
    $gridFindings.ItemsSource = Get-FilteredFindings
}
$txtFilter.Add_TextChanged({ Update-Filter })
$cboCategory.Add_SelectionChanged({ Update-Filter })
$cboSeverity.Add_SelectionChanged({ Update-Filter })
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

# === Detail panel ===
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
        $lines += 'Fix script (not executed by this tool):'
        $lines += ('  {0}' -f $row.FixScript)
    }
    $txtFindingDetail.Text = $lines -join [Environment]::NewLine
})

# === Bg runspace + scan ===
$script:BgRunspace     = $null
$script:BgPowerShell   = $null
$script:BgInvokeHandle = $null
$script:BgState        = $null
$script:BgTimer        = $null
$script:BgGraveyard    = @()

function Initialize-BgRunspace {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Lazy-init; idempotent.')]
    param()
    if ($script:BgRunspace -and $script:BgRunspace.RunspaceStateInfo.State -eq 'Opened') { return }
    $script:BgRunspace = [runspacefactory]::CreateRunspace()
    $script:BgRunspace.ApartmentState = 'STA'
    $script:BgRunspace.ThreadOptions  = 'ReuseThread'
    $script:BgRunspace.Open()
    $modulePath = Join-Path $PSScriptRoot 'Module\SiteHygieneCommon.psd1'
    $initPS = [powershell]::Create()
    $initPS.Runspace = $script:BgRunspace
    [void]$initPS.AddScript({
        param($ModulePath, $LogPath)
        Import-Module -Name $ModulePath -Force -DisableNameChecking
        if ($LogPath) { Initialize-Logging -LogPath $LogPath -Attach }
    }).AddArgument($modulePath).AddArgument($script:ToolLogPath)
    [void]$initPS.Invoke()
    $initPS.Dispose()
}

function Dispose-BgWork {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification='Dispose semantics intentional.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Tears down ephemeral runspace plumbing.')]
    param()
    if ($script:BgTimer) { try { $script:BgTimer.Stop() } catch { $null = $_ } ; $script:BgTimer = $null }
    if ($script:BgPowerShell) {
        # BeginStop, not Stop: a synchronous Stop() blocks the UI thread for
        # as long as the pipeline is stuck inside a CM/CIM call against an
        # unresponsive provider. The stopping pipeline is parked and reaped
        # on a later teardown pass once it has actually stopped.
        try { [void]$script:BgPowerShell.BeginStop($null, $null) } catch { $null = $_ }
        $script:BgGraveyard += ,$script:BgPowerShell
        $script:BgPowerShell = $null
    }
    $script:BgInvokeHandle = $null
    $script:BgGraveyard = @($script:BgGraveyard | Where-Object {
        if ($_.InvocationStateInfo.State -in @('Stopped', 'Completed', 'Failed')) {
            try { $_.Dispose() } catch { $null = $_ }
            $false
        }
        else { $true }
    })
}

function Invoke-Scan {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Posts work to bg runspace.')]
    param()
    if (-not $global:Prefs.SiteCode -or -not $global:Prefs.SMSProvider) {
        Add-LogLine 'Scan: site code and SMS provider must be set in Options first.'
        Set-StatusText 'Open Options to configure site code and SMS provider, then scan.'
        return
    }
    Initialize-BgRunspace
    Dispose-BgWork
    $script:BgState = [hashtable]::Synchronized(@{ Step = 'Connecting...'; Done = $false; Findings = $null; Summary = $null; Notes = $null; RelData = $null; ErrorMsg = $null })
    $btnScan.IsEnabled = $false
    $txtProgressStep.Text  = 'Connecting...'
    $progressOverlay.Visibility = [System.Windows.Visibility]::Visible
    Add-LogLine ('Scan: site={0} provider={1}' -f $global:Prefs.SiteCode, $global:Prefs.SMSProvider)
    Set-StatusText 'Scanning...'

    $siteCode    = [string]$global:Prefs.SiteCode
    $smsProvider = [string]$global:Prefs.SMSProvider

    $script:BgPowerShell = [powershell]::Create()
    $script:BgPowerShell.Runspace = $script:BgRunspace
    [void]$script:BgPowerShell.AddScript({
        param($SiteCode, $SMSProvider, $State)
        try {
            if (-not (Test-CMConnection)) {
                $State.Step = "Connecting to $SiteCode..."
                $ok = Connect-CMSite -SiteCode $SiteCode -SMSProvider $SMSProvider
                if (-not $ok) { $State.ErrorMsg = "Failed to connect to site $SiteCode (provider $SMSProvider)."; return }
            }
            $State.Step = 'Collecting site data (applications, packages, collections, deployments)...'
            $data = Get-HygieneData

            $State.Step = 'Parsing application relationships (SDMPackageXML)...'
            $relData = Get-HygieneRelationshipData

            $State.Step = 'Running hygiene checks...'
            $findings = @(Invoke-HygieneScan -Data $data -RelationshipData $relData)

            $notes = @($data.DatasetNotes)
            if ($relData) { $notes += @($relData.DatasetNotes) }
            else { $notes += 'Relationship data unavailable; SUP/DEP/REL and APP-04 checks were skipped.' }

            $State.Findings = $findings
            $State.Summary  = @(Get-HygieneScanSummary -Findings $findings)
            $State.Notes    = $notes
            $State.RelData  = $relData
        }
        catch { $State.ErrorMsg = $_.Exception.Message }
        finally { $State.Done = $true }
    }).AddArgument($siteCode).AddArgument($smsProvider).AddArgument($script:BgState)

    $script:BgInvokeHandle = $script:BgPowerShell.BeginInvoke()
    $script:BgTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:BgTimer.Interval = [TimeSpan]::FromMilliseconds(150)
    $script:BgTimer.Add_Tick({
        if ($script:BgState) { $current = [string]$script:BgState.Step; if ($txtProgressStep.Text -ne $current) { $txtProgressStep.Text = $current } }
        if ($script:BgState -and $script:BgState.Done) {
            $script:BgTimer.Stop()
            try { [void]$script:BgPowerShell.EndInvoke($script:BgInvokeHandle) } catch { $null = $_ }
            try { $script:BgPowerShell.Dispose() } catch { $null = $_ }
            $script:BgPowerShell   = $null
            $script:BgInvokeHandle = $null

            if ($script:BgState.ErrorMsg) {
                $progressOverlay.Visibility = [System.Windows.Visibility]::Collapsed
                $btnScan.IsEnabled = $true
                Add-LogLine ('Scan failed: {0}' -f $script:BgState.ErrorMsg)
                Set-StatusText 'Scan failed.'
                return
            }

            $script:LastScanTime = Get-Date
            $script:AllFindings = @($script:BgState.Findings | ForEach-Object {
                [pscustomobject]@{
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
                    SuppressKey    = Get-HygieneSuppressionKey -Finding $_
                }
            })
            $script:SummaryRows  = @($script:BgState.Summary)
            $script:DatasetNotes = @($script:BgState.Notes)
            $script:RelData      = $script:BgState.RelData
            Update-RelationshipTree

            $gridSummary.ItemsSource = $script:SummaryRows
            $txtDatasetNotes.Text = if ($script:DatasetNotes.Count -gt 0) {
                "Dataset notes:`r`n" + (($script:DatasetNotes | ForEach-Object { "  - $_" }) -join "`r`n")
            } else { 'All datasets loaded cleanly.' }

            Update-Filter
            Update-StatusBarSummary
            $progressOverlay.Visibility = [System.Windows.Visibility]::Collapsed
            $btnScan.IsEnabled = $true
            Add-LogLine ('Scan complete: {0} finding(s).' -f @($script:AllFindings).Count)
        }
    })
    $script:BgTimer.Start()
}
$btnScan.Add_Click({ Invoke-Scan })

# =============================================================================
# Export buttons.
# =============================================================================
$btnExportCsv.Add_Click({
    $rows = Get-FilteredFindings
    if (@($rows).Count -eq 0) { Add-LogLine 'Export CSV: nothing to export.'; return }
    $sfd = New-Object Microsoft.Win32.SaveFileDialog
    $sfd.Filter = 'CSV files (*.csv)|*.csv'
    $sfd.FileName = ('SiteHygiene-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $reportsDir = Join-Path $PSScriptRoot 'Reports'
    if (-not (Test-Path -LiteralPath $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null }
    $sfd.InitialDirectory = $reportsDir
    if ($sfd.ShowDialog() -eq $true) {
        Export-HygieneCsv -Findings @($rows) -OutputPath $sfd.FileName
        Add-LogLine ('Exported CSV: {0}' -f $sfd.FileName)
    }
})

$btnExportHtml.Add_Click({
    $rows = Get-FilteredFindings
    if (@($rows).Count -eq 0) { Add-LogLine 'Export HTML: nothing to export.'; return }
    $sfd = New-Object Microsoft.Win32.SaveFileDialog
    $sfd.Filter = 'HTML files (*.html)|*.html'
    $sfd.FileName = ('SiteHygiene-{0}.html' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $reportsDir = Join-Path $PSScriptRoot 'Reports'
    if (-not (Test-Path -LiteralPath $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null }
    $sfd.InitialDirectory = $reportsDir
    if ($sfd.ShowDialog() -eq $true) {
        Export-HygieneHtml -Findings @($rows) -OutputPath $sfd.FileName
        Add-LogLine ('Exported HTML: {0}' -f $sfd.FileName)
    }
})

# === Themed dialogs (Set-DialogTheme: SuiteCommon) ===
function Show-OptionsDialog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Modal dialog show / dispose; reads as a single action.')]
    param()
    $dlgXaml = @'
<Controls:MetroWindow
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:Controls="clr-namespace:MahApps.Metro.Controls;assembly=MahApps.Metro"
    Title="Options" Width="640" Height="380"
    MinWidth="560" MinHeight="380"
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
                <Button x:Name="btnCatAbout"      Content="About"      Style="{StaticResource CategoryRowStyle}"/>
            </StackPanel>
        </Border>
        <Border Grid.Column="1" Grid.Row="0" Background="{DynamicResource MahApps.Brushes.Gray8}"/>
        <Grid Grid.Column="2" Grid.Row="0" Margin="20,16,20,16">
            <StackPanel x:Name="paneConnection" Visibility="Visible">
                <TextBlock Text="MECM Connection" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,10"/>
                <TextBlock Text="Site Code" FontSize="11" Margin="0,4,0,2" Foreground="{DynamicResource MahApps.Brushes.Gray1}"/>
                <TextBox x:Name="txtSiteCode" FontSize="12" Padding="6,4,6,4"
                         Controls:TextBoxHelper.Watermark="e.g. MCM" Width="120" HorizontalAlignment="Left"/>
                <TextBlock Text="SMS Provider FQDN" FontSize="11" Margin="0,12,0,2" Foreground="{DynamicResource MahApps.Brushes.Gray1}"/>
                <TextBox x:Name="txtSmsProvider" FontSize="12" Padding="6,4,6,4"
                         Controls:TextBoxHelper.Watermark="e.g. cm01.contoso.com"/>
                <TextBlock Text="Used for the CM PSDrive root plus two read-only CIM queries (collection settings, application dependency relations). A scan never mutates the site; the account only needs read access."
                           FontSize="11" TextWrapping="Wrap" Margin="0,16,0,0"
                           Foreground="{DynamicResource MahApps.Brushes.Gray1}"/>
            </StackPanel>
            <StackPanel x:Name="paneAbout" Visibility="Collapsed">
                <TextBlock Text="About" FontSize="13" FontWeight="SemiBold" Margin="0,0,0,10"/>
                <TextBlock Text="Site Hygiene v0.3.0" FontSize="13" FontWeight="SemiBold"/>
                <TextBlock Text="Read-only MECM hygiene scanning: unused applications and packages, dead collections, stale and failing deployments. Every finding carries its evidence and the PowerShell a fix would take - shown, never executed."
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
    $btnCatConnection = $dlg.FindName('btnCatConnection')
    $btnCatAbout      = $dlg.FindName('btnCatAbout')
    $paneConnection   = $dlg.FindName('paneConnection')
    $paneAbout        = $dlg.FindName('paneAbout')
    $txtSiteCode      = $dlg.FindName('txtSiteCode')
    $txtSmsProvider   = $dlg.FindName('txtSmsProvider')
    $btnOk            = $dlg.FindName('btnOk')
    $btnCancel        = $dlg.FindName('btnCancel')
    $txtSiteCode.Text    = [string]$global:Prefs.SiteCode
    $txtSmsProvider.Text = [string]$global:Prefs.SMSProvider
    $btnCatConnection.Add_Click({ $paneConnection.Visibility = [System.Windows.Visibility]::Visible; $paneAbout.Visibility = [System.Windows.Visibility]::Collapsed })
    $btnCatAbout.Add_Click({      $paneConnection.Visibility = [System.Windows.Visibility]::Collapsed; $paneAbout.Visibility = [System.Windows.Visibility]::Visible })
    $btnOk.Add_Click({
        $newSite     = ([string]$txtSiteCode.Text).Trim()
        $newProvider = ([string]$txtSmsProvider.Text).Trim()
        $changed = ($newSite -ne [string]$global:Prefs.SiteCode) -or ($newProvider -ne [string]$global:Prefs.SMSProvider)
        $global:Prefs.SiteCode    = $newSite
        $global:Prefs.SMSProvider = $newProvider
        Save-ShPreferences -Prefs $global:Prefs
        if ($changed) {
            Dispose-BgWork
            if ($script:BgRunspace) { try { $script:BgRunspace.CloseAsync() } catch { $null = $_ } ; $script:BgRunspace = $null }
            $script:BgState = $null
            $progressOverlay.Visibility = [System.Windows.Visibility]::Collapsed
            $btnScan.IsEnabled = $true
        }
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
    Save-WindowState -Window $window -Path $global:WindowStatePath -ExtraState @{ ActiveView = $script:ActiveView }
    Dispose-BgWork
    # CloseAsync: a blocking Close() waits for a still-stopping pipeline and
    # can hold the closing window on a hung provider call. The process ends
    # when the dialog returns; a lingering stuck call dies with it.
    if ($script:BgRunspace) { try { $script:BgRunspace.CloseAsync() } catch { $null = $_ } }
})

$treeRelationships.Add_SelectedItemChanged({
    $item = $treeRelationships.SelectedItem
    if (-not $item -or -not $script:RelData -or $null -eq $item.Tag) {
        return
    }
    $ciid = 0
    try { $ciid = [int]$item.Tag } catch { return }
    if ($ciid -eq 0) {
        $txtRelationshipDetail.Text = 'This node references an application that no longer exists in the site.'
        return
    }
    $app = $script:RelData.Apps[$ciid]
    if (-not $app) { return }
    $out = @($script:RelData.Relationships | Where-Object { [int]$_.FromAppCIID -eq $ciid })
    $in  = @($script:RelData.Relationships | Where-Object { [int]$_.ToAppCIID -eq $ciid })
    $lines = @(
        ('{0}  (CI_ID {1})' -f $app.Name, $app.CI_ID),
        ('Version:        {0}' -f $app.SoftwareVersion),
        ('Manufacturer:   {0}' -f $(if ($app.Manufacturer) { $app.Manufacturer } else { '(not set)' })),
        ('Enabled:        {0}    Retired: {1}    Has content: {2}' -f $app.IsEnabled, $app.IsExpired, $app.HasContent),
        '',
        ('Outgoing:       {0} supersedence, {1} dependency' -f @($out | Where-Object { $_.Kind -eq 'Supersedence' }).Count, @($out | Where-Object { $_.Kind -eq 'Dependency' }).Count),
        ('Incoming:       {0} supersedence, {1} dependency' -f @($in | Where-Object { $_.Kind -eq 'Supersedence' }).Count, @($in | Where-Object { $_.Kind -eq 'Dependency' }).Count)
    )
    $txtRelationshipDetail.Text = $lines -join [Environment]::NewLine
})

$window.Add_Loaded({
    Restore-WindowState -Window $window -Path $global:WindowStatePath -OnStateLoaded {
        param($s)
        if ($s.ActiveView -in @('Findings','Relationships','Summary')) { Set-ActiveView -View ([string]$s.ActiveView) }
    }
    $isDark = [bool]$global:Prefs['DarkMode']
    if (-not $isDark) { [void][ControlzEx.Theming.ThemeManager]::Current.ChangeTheme($window, 'Light.Blue') }
    Update-TitleBarBrushes
    Update-StatusBarSummary
    Update-SuppressCount
    $gridSummary.ItemsSource = @(Get-HygieneScanSummary -Findings @())
    Add-LogLine 'Site Hygiene ready. Configure Site / Provider in Options, then click Scan.'
})

[void]$window.ShowDialog()
try { Stop-Transcript | Out-Null } catch { $null = $_ }
