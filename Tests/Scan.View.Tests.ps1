#Requires -Modules Pester
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'The cut-out shell code reads these stand-in controls through scope.')]
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'The shell keeps its paths in globals; the tests set the same names.')]
param ()
# The results of the background scan and the background refresh reach the grids. The scan and the
# refresh run in a background runspace. A timer on the window thread waits for the result, then
# fills the grids. These tests run that timer handler of the script (cut from its syntax tree)
# with a finished background result, real module code, and real WPF grids (not shown), and read
# the rows that each grid holds and the text that the user sees. A test that checks only that a
# control exists, or that a function was called, passes while a grid is empty.

BeforeAll {
    . "$PSScriptRoot\TestHelpers.ps1"
    Import-AppModule
    Add-Type -AssemblyName PresentationFramework
    $script:ShellPath = Join-Path $script:AppRoot 'start-sitehygiene.ps1'
    $wanted = 'Get-SeverityGlyph', 'Get-ComboValue', 'Get-FilteredFindings', 'Get-FilteredRelationshipRows', 'Test-LiveRowMatch',
        'Get-FilteredLiveRows', 'Update-Filter', 'Get-DeploymentGlyph', 'Get-ContentGlyph', 'Get-StatusWordGlyph', 'Get-ClientGlyph',
        'Get-InactiveGlyph', 'Format-DateOrEmpty', 'ConvertTo-DeploymentGridRows', 'ConvertTo-ContentGridRows', 'ConvertTo-DPGridRows',
        'ConvertTo-ClientGridRows', 'ConvertTo-InactiveGridRows', 'ConvertTo-SiteGridRows'
    foreach ($text in @(Get-ScriptFunctionText -Path $script:ShellPath -Name $wanted)) { . ([scriptblock]::Create($text)) }
    $script:Glyph = @{ OK = [char]0x2713; Error = [char]0x2717; Warn = [char]0x26A0; Unknown = [char]0x22EF }

    # The timer handler that holds the given marker text: the scan handler or the refresh handler.
    function Get-TickBlock {
        param([string]$Marker)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ShellPath, [ref]$null, [ref]$null)
        $calls = $ast.FindAll({
                param($x)
                $x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $x.Member.Value -eq 'Add_Tick' -and
                $x.Expression.Extent.Text -eq '$script:BgTimer' -and $x.Extent.Text.Contains($Marker)
            }, $true)
        if (@($calls).Count -ne 1) { throw "expected one Add_Tick handler with '$Marker', found $(@($calls).Count)" }
        $calls[0].Arguments[0].ScriptBlock.GetScriptBlock()
    }
    $script:ScanTick = Get-TickBlock -Marker 'Scan complete'
    $script:RefreshTick = Get-TickBlock -Marker 'Refresh complete'

    function Add-LogLine { param([string]$Text, $Level) $script:LogLines += $Text }
    function Set-StatusText { param([string]$Text) $script:StatusText = $Text }
    function Read-BgInformationStream { }
    function Complete-BgInvoke { }
    function Update-RelationshipViews { }
    function Update-StatusBarSummary { }
    function Sync-FooterSite { }
    function Update-TrendChart { }
    function Invoke-AlertEvaluation { }
    function Start-AutoRefreshIfEnabled { }
    function Add-MetricsHistoryEntry { }
    # Set-Item, not "function": a function named Write-Log trips the analyzer rule for built-in names on PowerShell 7.
    Set-Item -Path 'function:script:Write-Log' -Value { param($Message, $Level, [switch]$Quiet) }

    function New-TestFinding {
        param([string]$CheckId, [string]$Severity = 'Warning', [string]$Name)
        New-HygieneFinding -CheckId $CheckId -Severity $Severity -Category 'Applications' -ObjectType 'Application' -ObjectId ('ID-' + $Name) -ObjectName $Name -Evidence 'No deployments and no references' -Recommendation 'Retire it'
    }
}

AfterAll {
    Remove-Variable -Name LastScanPath, HistoryPath -Scope Global -ErrorAction SilentlyContinue
}

Describe 'The scan result fills the Findings and Summary grids' {
    BeforeEach {
        $script:LogLines = @(); $script:StatusText = ''
        $global:LastScanPath = Join-Path $TestDrive ('lastscan-{0}.json' -f [guid]::NewGuid().ToString('N'))
        $script:ActiveView = 'Findings'
        $script:ScanIsFull = $true
        $script:ScanStarted = Get-Date
        $script:AllFindings = @(); $script:RelationshipRows = @(); $script:RelData = $null
        $script:SuppressedKeys = New-Object 'System.Collections.Generic.HashSet[string]'
        $gridFindings = New-Object System.Windows.Controls.DataGrid
        $gridFindings.CanUserAddRows = $false
        $gridSummary = New-Object System.Windows.Controls.DataGrid
        $gridSummary.CanUserAddRows = $false
        $txtDatasetNotes = New-Object System.Windows.Controls.TextBox
        $txtProgressStep = New-Object System.Windows.Controls.TextBox
        $txtFilter = New-Object System.Windows.Controls.TextBox
        $cboCategory = [PSCustomObject]@{ SelectedItem = $null }
        $cboSeverity = [PSCustomObject]@{ SelectedItem = $null }
        $chkShowSuppressed = [PSCustomObject]@{ IsChecked = $false }
        $progressOverlay = [PSCustomObject]@{ Visibility = [System.Windows.Visibility]::Visible }
        $btnScan = [PSCustomObject]@{ IsEnabled = $false }
    }

    It 'puts every finding of the scan into the Findings grid, with the glyph and the text the user reads' {
        $findings = @(
            (New-TestFinding -CheckId 'APP-01' -Severity 'Warning' -Name 'App one'),
            (New-TestFinding -CheckId 'APP-02' -Severity 'Error' -Name 'App two'),
            (New-TestFinding -CheckId 'APP-03' -Severity 'Info' -Name 'App three'))
        $script:BgState = @{ Done = $true; ErrorMsg = $null; Step = 'x'; Findings = $findings; Summary = @(Get-HygieneScanSummary -Findings $findings); Notes = @('Distribution points: skipped'); RelData = $null; BlockerData = $null }
        & $script:ScanTick
        $gridFindings.Items.Count | Should -Be 3
        $gridFindings.Items[0].CheckId | Should -Be 'APP-01'
        $gridFindings.Items[0].ObjectName | Should -Be 'App one'
        $gridFindings.Items[0].Evidence | Should -Be 'No deployments and no references'
        [int]$gridFindings.Items[1].SeverityGlyph[0] | Should -Be 0x2717
        $gridSummary.Items.Count | Should -Be @(Get-HygieneScanSummary -Findings $findings).Count
        $gridSummary.Items.Count | Should -BeGreaterThan 0
    }

    It 'says what the scan found and what it left out, and gives the window back' {
        $findings = @((New-TestFinding -CheckId 'APP-01' -Name 'App one'))
        $script:BgState = @{ Done = $true; ErrorMsg = $null; Step = 'x'; Findings = $findings; Summary = @(Get-HygieneScanSummary -Findings $findings); Notes = @('Distribution points: skipped', 'Clients: skipped'); RelData = $null; BlockerData = $null }
        & $script:ScanTick
        $txtDatasetNotes.Text | Should -Match 'Distribution points: skipped'
        $txtDatasetNotes.Text | Should -Match 'Clients: skipped'
        [string]$progressOverlay.Visibility | Should -Be 'Collapsed'
        $btnScan.IsEnabled | Should -BeTrue
        ($script:LogLines -join ' | ') | Should -Match 'Scan complete: 1 finding'
    }

    It 'shows the one finding of a scan with one finding (a single object is not a list)' {
        $findings = @((New-TestFinding -CheckId 'APP-01' -Name 'Only one'))
        $script:BgState = @{ Done = $true; ErrorMsg = $null; Step = 'x'; Findings = $findings; Summary = @(Get-HygieneScanSummary -Findings $findings); Notes = @(); RelData = $null; BlockerData = $null }
        & $script:ScanTick
        $gridFindings.Items.Count | Should -Be 1
        $gridSummary.Items.Count | Should -Be @($script:BgState.Summary).Count
        $gridSummary.Items.Count | Should -BeGreaterThan 0
        $txtDatasetNotes.Text | Should -Be 'All datasets loaded cleanly.'
    }

    It 'shows empty grids for a scan that found nothing' {
        $script:BgState = @{ Done = $true; ErrorMsg = $null; Step = 'x'; Findings = @(); Summary = @(); Notes = @(); RelData = $null; BlockerData = $null }
        & $script:ScanTick
        $gridFindings.Items.Count | Should -Be 0
        $gridSummary.Items.Count | Should -Be 0
    }

    It 'marks a finding that the previous scan did not have as New, and no other' {
        $first = @((New-TestFinding -CheckId 'APP-01' -Name 'Old one'))
        $script:BgState = @{ Done = $true; ErrorMsg = $null; Step = 'x'; Findings = $first; Summary = @(); Notes = @(); RelData = $null; BlockerData = $null }
        & $script:ScanTick
        $second = @((New-TestFinding -CheckId 'APP-01' -Name 'Old one'), (New-TestFinding -CheckId 'APP-01' -Name 'New one'))
        $script:BgState = @{ Done = $true; ErrorMsg = $null; Step = 'x'; Findings = $second; Summary = @(); Notes = @(); RelData = $null; BlockerData = $null }
        & $script:ScanTick
        $gridFindings.Items.Count | Should -Be 2
        @($gridFindings.Items | Where-Object { $_.Delta -eq 'New' }).ObjectName | Should -Be @('New one')
    }

    It 'leaves the grids as they were and says the scan failed when the background step failed' {
        $gridFindings.ItemsSource = @([PSCustomObject]@{ CheckId = 'KEEP' })
        $script:BgState = @{ Done = $true; ErrorMsg = 'An error occurred. The log file has the details.'; ErrorDetail = 'x'; Step = 'x'; Findings = $null; Summary = $null; Notes = $null; RelData = $null; BlockerData = $null }
        & $script:ScanTick
        $gridFindings.Items.Count | Should -Be 1
        $script:StatusText | Should -Be 'Scan failed.'
        [string]$progressOverlay.Visibility | Should -Be 'Collapsed'
        $btnScan.IsEnabled | Should -BeTrue
    }
}

Describe 'The refresh result fills the live grids' {
    BeforeEach {
        $script:LogLines = @(); $script:StatusText = ''
        $global:HistoryPath = Join-Path $TestDrive 'history.json'
        $script:ActiveView = 'Deployments'
        $script:RefreshStarted = Get-Date
        $script:LiveConnected = $false
        $txtFilter = New-Object System.Windows.Controls.TextBox
        $cboStatus = [PSCustomObject]@{ SelectedItem = $null }
        $txtProgressStep = New-Object System.Windows.Controls.TextBox
        $progressOverlay = [PSCustomObject]@{ Visibility = [System.Windows.Visibility]::Visible }
        $btnRefreshAll = [PSCustomObject]@{ IsEnabled = $false }
        foreach ($g in 'gridDeploy', 'gridContent', 'gridDPs', 'gridClients', 'gridInactive', 'gridSite') {
            $newGrid = New-Object System.Windows.Controls.DataGrid
            $newGrid.CanUserAddRows = $false
            Set-Variable -Name $g -Value $newGrid
        }
        $script:Result = [PSCustomObject]@{
            DeploymentCounts = @{}; ContentCounts = @{}; DPCounts = @{}; ClientCounts = @{}; InactiveCounts = @{}; SiteCounts = @{}
            DeploymentData = @(
                [PSCustomObject]@{ DeploymentId = 'D1'; DeploymentName = 'Office'; DeploymentType = 'Application'; CollectionName = 'All Systems'; Purpose = 'Required'; NumberTargeted = 10; NumberSuccess = 10; NumberErrors = 0; NumberInProgress = 0; NumberUnknown = 0; PercentCompliant = 100 }
                [PSCustomObject]@{ DeploymentId = 'D2'; DeploymentName = 'Chrome'; DeploymentType = 'Application'; CollectionName = 'Pilot'; Purpose = 'Available'; NumberTargeted = 4; NumberSuccess = 2; NumberErrors = 1; NumberInProgress = 1; NumberUnknown = 0; PercentCompliant = 50 })
            ContentData = @(); ContentNameMap = @{}
            DPData = @([PSCustomObject]@{ DPName = 'DP01'; SiteCode = 'MCM'; Status = 'OK'; IsPullDP = $false })
            ClientData = @(); InactiveData = @(); ComponentData = @(); SystemData = @()
            SqlOk = $false
        }
        $script:BgState = @{ Done = $true; ErrorMsg = $null; Step = 'x'; Result = $script:Result }
    }

    It 'puts the deployments and the distribution points into their grids' {
        & $script:RefreshTick
        $script:LiveConnected | Should -BeTrue
        $gridDeploy.Items.Count | Should -Be 2
        $gridDeploy.Items[0].DeploymentName | Should -Be 'Office'
        [int]$gridDeploy.Items[1].StatusGlyph[0] | Should -Be 0x2717
        ($script:LogLines -join ' | ') | Should -Match 'Refresh complete: 2 deployments'
        [string]$progressOverlay.Visibility | Should -Be 'Collapsed'
        $btnRefreshAll.IsEnabled | Should -BeTrue
    }

    It 'fills the grid of the active view: <View>' -ForEach @(
        @{ View = 'DPs'; Count = 1 }
        @{ View = 'Deployments'; Count = 2 }
        @{ View = 'Content'; Count = 0 }
    ) {
        $script:ActiveView = $View
        & $script:RefreshTick
        $shown = switch ($View) { 'DPs' { $gridDPs } 'Deployments' { $gridDeploy } 'Content' { $gridContent } }
        $shown.Items.Count | Should -Be $Count
    }

    It 'shows the one distribution point of a site with one (a single object is not a list)' {
        $script:ActiveView = 'DPs'
        & $script:RefreshTick
        $gridDPs.Items.Count | Should -Be 1
        $gridDPs.Items[0].DPName | Should -Be 'DP01'
    }

    It 'keeps the grids as they were and says the refresh failed when the background step failed' {
        $script:ActiveView = 'Deployments'
        $gridDeploy.ItemsSource = @([PSCustomObject]@{ DeploymentName = 'KEEP' })
        $script:BgState = @{ Done = $true; ErrorMsg = 'An error occurred. The log file has the details.'; Step = 'x'; Result = $null }
        & $script:RefreshTick
        $gridDeploy.Items.Count | Should -Be 1
        $script:StatusText | Should -Be 'Refresh failed.'
        $script:LiveConnected | Should -BeFalse
    }
}
