# App-specific names for Window.Tests.ps1.
# The main window has ten view containers in two sidebar groups (Scan and Live). The shell shows one
# container at a time (Set-ActiveView). Each view lists the container, its sidebar button and the
# active view name the theme uses.
$script:AppConfig = @{
    Title         = 'Site Hygiene'
    Shell         = 'start-sitehygiene.ps1'
    Xaml          = 'MainWindow.xaml'
    OptionsButton = 'btnOptions'
    LogLabel      = 'lblLogOutput'
    WorkflowButtons = @('btnScan', 'btnRefreshAll', 'btnPauseResume', 'btnSuppress', 'btnUnsuppress', 'btnRunFix', 'btnExportCsv', 'btnExportHtml', 'btnCopySummary', 'btnCancelScan')
    Views         = @(
        @{ Name = 'Findings';      Container = 'viewFindings';      Button = 'btnViewFindings' }
        @{ Name = 'Relationships'; Container = 'viewRelationships'; Button = 'btnViewRelationships' }
        @{ Name = 'Summary';       Container = 'viewSummary';       Button = 'btnViewSummary' }
        @{ Name = 'Deployments';   Container = 'viewDeployments';   Button = 'btnViewDeployments' }
        @{ Name = 'Content';       Container = 'viewContent';       Button = 'btnViewContent' }
        @{ Name = 'DPs';           Container = 'viewDPs';           Button = 'btnViewDPs' }
        @{ Name = 'Clients';       Container = 'viewClients';       Button = 'btnViewClients' }
        @{ Name = 'Inactive';      Container = 'viewInactive';      Button = 'btnViewInactive' }
        @{ Name = 'Site';          Container = 'viewSite';          Button = 'btnViewSite' }
        @{ Name = 'Trends';        Container = 'viewTrends';        Button = 'btnViewTrends' }
    )
}

# Findings rows of the shape the scan handler builds, so the grid shows real cell text.
$script:SampleFindings = @(
    1..4 | ForEach-Object {
        [PSCustomObject]@{
            SeverityGlyph = [string][char]0x26A0; Delta = $(if ($_ -eq 1) { 'New' } else { '' }); CheckId = 'APP-0{0}' -f $_
            Severity = 'Warning'; Category = 'Applications'; ObjectName = 'Sample application {0}' -f $_
            Evidence = 'No deployments and no references'; FixState = $(if ($_ -eq 2) { 'Fixed' } else { '' })
        }
    })

# Runs in the STA runspace. Opens the main window and measures every view in one theme and size.
# Arguments: Config, Dark, W, H, Findings.
$script:MainMeasureScript = {
    $cfg = $Arguments.Config
    $w = Open-TestWindow -XamlPath (Join-Path $Root $cfg.Xaml) -Dark $Arguments.Dark -Width $Arguments.W -Height $Arguments.H
    $w.FindName('gridFindings').ItemsSource = @($Arguments.Findings)
    # Contrast is read only at 1440x900. Clipped text and off-screen controls are read at both sizes.
    $full = $Arguments.W -ge 1440
    $out = @()
    foreach ($view in $cfg.Views) {
        foreach ($v in $cfg.Views) { $w.FindName($v.Container).Visibility = if ($v.Name -eq $view.Name) { 'Visible' } else { 'Collapsed' } }
        # The action bar follows the view the way Set-ActiveView of the start script sets it.
        $live = $view.Name -in 'Deployments', 'Content', 'DPs', 'Clients', 'Inactive', 'Site', 'Trends'
        $bar = @{
            btnScan = -not $live; btnRefreshAll = $live; btnPauseResume = $live; btnCopySummary = $live
            cboStatus = ($live -and $view.Name -ne 'Trends'); cboCategory = ($view.Name -eq 'Findings'); cboSeverity = ($view.Name -eq 'Findings')
            cboRelKind = ($view.Name -eq 'Relationships'); cboRelStatus = ($view.Name -eq 'Relationships'); txtFilter = ($view.Name -notin 'Summary', 'Trends')
        }
        foreach ($name in $bar.Keys) { $w.FindName($name).Visibility = if ($bar[$name]) { 'Visible' } else { 'Collapsed' } }        Initialize-ShellTheme -Window $w -Dark $Arguments.Dark -Views $cfg.Views -WorkflowButtonName $cfg.WorkflowButtons `
            -OptionsButtonName $cfg.OptionsButton -LogLabelName $cfg.LogLabel -ActiveView $view.Name
        $out += [PSCustomObject]@{
            View        = $view.Name
            Text        = if ($full) { @(Get-TextContrast $w) } else { @() }
            Clipped     = @(Get-ClippedText $w)
            Offscreen   = @(Get-OffscreenControls $w)
            Interactive = if ($full) { @(Get-InteractiveContrast $w) } else { @() }
            TitleBar    = if ($full) { Get-TitleBarContrast $w } else { $null }
        }
    }
    $w.Close()
    , $out
}

# Runs in the STA runspace. Opens the Options dialog from its XAML text at its declared and minimum size and
# measures every pane. Arguments: Xaml, Dark, Scopes (the check box texts of the scope pane).
$script:DialogMeasureScript = {
    [xml]$x = $Arguments.Xaml
    $probe = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    $sizes = @(, @($probe.Width, $probe.Height))
    if ($probe.MinWidth -gt 0 -and $probe.MinHeight -gt 0) { $sizes += , @($probe.MinWidth, $probe.MinHeight) }
    $probe = $null
    $panes = 'paneConnection', 'paneScope', 'paneLive', 'paneAlerts', 'paneAbout'
    $rows = foreach ($s in $sizes) {
        $w = Open-TestWindow -XamlText $Arguments.Xaml -Dark $Arguments.Dark -Width $s[0] -Height $s[1]
        # The shell fills the scope pane with one check box per scan area.
        $panel = $w.FindName('panelScopes')
        foreach ($t in $Arguments.Scopes) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content = $t; $cb.FontSize = 12; $cb.IsChecked = $true
            [void]$panel.Children.Add($cb)
        }
        # Entered text, so the contrast of the input text is measured too.
        $w.FindName('txtSiteCode').Text = 'ABC'
        $w.FindName('txtSmsProvider').Text = 'cm01.contoso.com'
        $w.FindName('txtSqlServer').Text = 'sql01.contoso.com'
        $w.FindName('txtPacing').Text = '0'
        Set-DialogTheme -Dialog $w -IsDark $Arguments.Dark
        foreach ($pane in $panes) {
            foreach ($p in $panes) { $w.FindName($p).Visibility = if ($p -eq $pane) { 'Visible' } else { 'Collapsed' } }
            Wait-Layout $w
            [PSCustomObject]@{
                Pane = $pane; Size = ('{0}x{1}' -f $s[0], $s[1])
                Text = @(Get-TextContrast $w); Interactive = @(Get-InteractiveContrast $w)
                Clipped = @(Get-ClippedText $w); Offscreen = @(Get-OffscreenControls $w)
                TitleBar = Get-TitleBarContrast $w
            }
        }
        $w.Close()
    }
    , @($rows)
}
