#Requires -Modules Pester
# Logic of start-sitehygiene.ps1. The script cannot be dot-sourced (it opens the window), so each function is
# cut out of its syntax tree and defined here, with plain objects in place of the window controls. The script
# state that the functions read ($script:ActiveView, $global:Prefs and the control variables) is set by the tests.

BeforeAll {
    . "$PSScriptRoot\TestHelpers.ps1"
    Import-AppModule
    Add-Type -AssemblyName PresentationFramework
    $script:ShellPath = Join-Path $script:AppRoot 'start-sitehygiene.ps1'
    $wanted = 'Get-SeverityGlyph', 'Get-RelationshipStatusGlyph', 'Get-ComboValue', 'Get-FilteredFindings', 'Get-FilteredRelationshipRows',
    'Test-LiveRowMatch', 'Get-FilteredLiveRows', 'Update-Filter', 'Update-SuppressCount', 'Get-RunnableSelection', 'Get-DeploymentGlyph',
    'Get-ContentGlyph', 'Get-StatusWordGlyph', 'Get-ClientGlyph', 'Get-InactiveGlyph', 'Format-DateOrEmpty', 'ConvertTo-DeploymentGridRows',
    'ConvertTo-ContentGridRows', 'ConvertTo-DPGridRows', 'ConvertTo-ClientGridRows', 'ConvertTo-InactiveGridRows', 'ConvertTo-SiteGridRows',
    'Update-StatusBarSummary', 'Set-StatusText', 'Get-TrendRangeDays', 'ConvertTo-DataTableForExport', 'Get-ActiveExportInfo', 'Get-RelationshipAppLines',
    'Test-BgBusy', 'Add-LogLine', 'Set-ControlVisible', 'Invoke-Export', 'Invoke-AlertEvaluation', 'Write-AlertEntry', 'Start-AutoRefreshIfEnabled', 'Stop-AutoRefresh',
    'Show-ExportSaveDialog', 'Send-ShToast', 'Get-ShSuppressedKeys', 'Save-ShSuppressedKeys', 'Get-ShPreferences', 'Save-ShPreferences', 'Add-RelationshipTreeNodes'
    foreach ($text in @(Get-ScriptFunctionText -Path $script:ShellPath -Name $wanted)) { . ([scriptblock]::Create($text)) }

    $script:Glyph = @{ OK = [char]0x2713; Error = [char]0x2717; Warn = [char]0x26A0; Unknown = [char]0x22EF }
    $script:LiveViews = @('Deployments', 'Content', 'DPs', 'Clients', 'Inactive', 'Site', 'Trends')

    function New-Combo { param($Value) [PSCustomObject]@{ SelectedItem = $Value } }
    function New-Grid { [PSCustomObject]@{ ItemsSource = $null; SelectedItems = @(); SelectedItem = $null } }
}

Describe 'Glyphs' {
    It 'marks severity <Severity> with the right glyph' -ForEach @(
        @{ Severity = 'Error'; Code = 0x2717 }, @{ Severity = 'Warning'; Code = 0x26A0 }, @{ Severity = 'Info'; Code = 0x2139 }, @{ Severity = 'Other'; Code = 0x2139 }, @{ Severity = ''; Code = 0x2139 }
    ) {
        [int](Get-SeverityGlyph -Severity $Severity) | Should -Be $Code
    }

    It 'marks relationship status <Status> with a glyph' -ForEach @(
        @{ Status = 'Healthy'; Code = 0x2713 }, @{ Status = 'Orphaned'; Code = 0x2717 }, @{ Status = 'Circular'; Code = 0x2717 },
        @{ Status = 'Expired Target'; Code = 0x2717 }, @{ Status = 'Retired Target'; Code = 0x26A0 }, @{ Status = ''; Code = 0x26A0 }
    ) {
        [int](Get-RelationshipStatusGlyph -Status $Status) | Should -Be $Code
    }

    It 'marks a deployment <Case>' -ForEach @(
        @{ Case = 'with errors as an error'; Row = @{ NumberErrors = 1; NumberTargeted = 5; NumberInProgress = 0; PercentCompliant = 100 }; Code = 0x2717 }
        @{ Case = 'that targets nothing as unknown'; Row = @{ NumberErrors = 0; NumberTargeted = 0; NumberInProgress = 0; PercentCompliant = 0 }; Code = 0x22EF }
        @{ Case = 'in progress as a warning'; Row = @{ NumberErrors = 0; NumberTargeted = 5; NumberInProgress = 1; PercentCompliant = 100 }; Code = 0x26A0 }
        @{ Case = 'below 95 percent as a warning'; Row = @{ NumberErrors = 0; NumberTargeted = 5; NumberInProgress = 0; PercentCompliant = 94.9 }; Code = 0x26A0 }
        @{ Case = 'at 95 percent as good'; Row = @{ NumberErrors = 0; NumberTargeted = 5; NumberInProgress = 0; PercentCompliant = 95 }; Code = 0x2713 }
    ) {
        [int](Get-DeploymentGlyph -Row ([PSCustomObject]$Row)) | Should -Be $Code
    }

    It 'marks content <Case>' -ForEach @(
        @{ Case = 'with failures as an error'; Row = @{ FailedCount = 1; InProgressCount = 1 }; Code = 0x2717 }
        @{ Case = 'in progress as a warning'; Row = @{ FailedCount = 0; InProgressCount = 2 }; Code = 0x26A0 }
        @{ Case = 'with neither as good'; Row = @{ FailedCount = 0; InProgressCount = 0 }; Code = 0x2713 }
    ) {
        [int](Get-ContentGlyph -Row ([PSCustomObject]$Row)) | Should -Be $Code
    }

    It 'marks a status word <Status>' -ForEach @(
        @{ Status = 'OK'; Code = 0x2713 }, @{ Status = 'Warning'; Code = 0x26A0 }, @{ Status = 'Critical'; Code = 0x2717 }, @{ Status = 'Unknown'; Code = 0x22EF }, @{ Status = $null; Code = 0x22EF }
    ) {
        [int](Get-StatusWordGlyph -Row ([PSCustomObject]@{ Status = $Status })) | Should -Be $Code
    }

    It 'marks a client <Health> and <Active>' -ForEach @(
        @{ Health = 'Unhealthy'; Active = 'Active'; Code = 0x2717 }, @{ Health = 'Healthy'; Active = 'Inactive'; Code = 0x26A0 },
        @{ Health = 'Healthy'; Active = 'Active'; Code = 0x2713 }, @{ Health = 'Unknown'; Active = 'Active'; Code = 0x22EF }
    ) {
        [int](Get-ClientGlyph -Row ([PSCustomObject]@{ HealthState = $Health; ActiveStatus = $Active })) | Should -Be $Code
    }

    It 'marks an inactive device with <Days> days' -ForEach @(
        @{ Days = 14; Code = 0x26A0 }, @{ Days = 60; Code = 0x26A0 }, @{ Days = 61; Code = 0x2717 }, @{ Days = $null; Code = 0x2717 }
    ) {
        [int](Get-InactiveGlyph -Row ([PSCustomObject]@{ DaysSinceContact = $Days })) | Should -Be $Code
    }
}

Describe 'Format-DateOrEmpty' {
    It 'formats <Case>' -ForEach @(
        @{ Case = 'a date'; Value = [datetime]'2026-11-06T14:05:59'; Expected = '2026-11-06 14:05' }
        @{ Case = 'a date as text'; Value = '2026-11-06 14:05:59'; Expected = '2026-11-06 14:05' }
        @{ Case = 'text that is not a date'; Value = 'never'; Expected = 'never' }
        @{ Case = 'null'; Value = $null; Expected = '' }
    ) {
        Format-DateOrEmpty $Value | Should -Be $Expected
    }
}

Describe 'Grid row builders' {
    It 'keeps one row per input row and returns a list for a single row' {
        $rows = ConvertTo-DeploymentGridRows -Rows ([PSCustomObject]@{ DeploymentId = 'D1'; DeploymentName = 'n'; NumberErrors = 0; NumberTargeted = 1; NumberInProgress = 0; PercentCompliant = 100 })
        $rows -is [array] | Should -BeTrue
        $rows.Count | Should -Be 1
        $rows[0].DeploymentName | Should -Be 'n'
        (ConvertTo-DeploymentGridRows -Rows @()).Count | Should -Be 0
    }

    It 'names the content from the name map and falls back to the package id' {
        $map = @{ P1 = @{ Name = 'Office'; Type = 'Package' } }
        $rows = ConvertTo-ContentGridRows -NameMap $map -Rows @(
            [PSCustomObject]@{ PackageID = 'P1'; FailedCount = 0; InProgressCount = 1 }
            [PSCustomObject]@{ PackageID = 'P2'; FailedCount = 1; InProgressCount = 0 })
        $rows[0].ContentName | Should -Be 'Office'
        $rows[0].ContentType | Should -Be 'Package'
        $rows[1].ContentName | Should -Be 'P2'
        $rows[1].ContentType | Should -Be 'Application'
        (ConvertTo-ContentGridRows -Rows @([PSCustomObject]@{ PackageID = 'P3'; FailedCount = 0; InProgressCount = 0 }))[0].ContentName | Should -Be 'P3'
    }

    It 'builds distribution point, client, inactive and site rows' {
        (ConvertTo-DPGridRows -Rows @([PSCustomObject]@{ DPName = 'DP1'; SiteCode = 'MCM'; Status = 'Critical'; IsPullDP = 'No' }))[0].StatusGlyph | Should -Be $script:Glyph.Error
        $c = (ConvertTo-ClientGridRows -Rows @([PSCustomObject]@{ DeviceName = 'PC'; HealthState = 'Healthy'; ActiveStatus = 'Active'; LastOnlineTime = [datetime]'2026-01-02 03:04'; LastDDR = $null }))[0]
        $c.LastOnlineDisplay | Should -Be '2026-01-02 03:04'
        $c.LastDDRDisplay | Should -Be ''
        (ConvertTo-InactiveGridRows -Rows @([PSCustomObject]@{ DeviceName = 'PC'; DaysSinceContact = 99 }))[0].StatusGlyph | Should -Be $script:Glyph.Error
        $s = ConvertTo-SiteGridRows -ComponentRows @([PSCustomObject]@{ ComponentName = 'SMS_X'; ItemType = 'Component'; MachineName = 'M'; Status = 'OK'; State = 'Started'; LastStarted = $null }) `
            -SystemRows @([PSCustomObject]@{ RoleName = 'Role'; ItemType = 'Site System'; ServerName = 'S'; Status = 'Warning' })
        $s.Count | Should -Be 2
        $s[0].Name | Should -Be 'SMS_X'
        $s[1].Name | Should -Be 'Role'
        $s[1].MachineName | Should -Be 'S'
        $s[1].StatusGlyph | Should -Be $script:Glyph.Warn
    }
}

Describe 'Filters' {
    BeforeEach {
        $script:ActiveView = 'Findings'
        $txtFilter = [PSCustomObject]@{ Text = '' }
        $cboCategory = New-Combo 'All'
        $cboSeverity = New-Combo 'All'
        $cboRelKind = New-Combo 'All'
        $cboRelStatus = New-Combo 'All'
        $cboStatus = New-Combo 'All'
        $chkShowSuppressed = [PSCustomObject]@{ IsChecked = $false }
        $script:SuppressedKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $script:AllFindings = @(
            [PSCustomObject]@{ CheckId = 'APP-01'; ObjectName = 'Alpha'; Evidence = 'no deployments'; Category = 'Applications'; Severity = 'Warning'; SuppressKey = 'k1' }
            [PSCustomObject]@{ CheckId = 'PKG-01'; ObjectName = 'Beta [x64]'; Evidence = 'unused'; Category = 'Packages'; Severity = 'Info'; SuppressKey = 'k2' }
            [PSCustomObject]@{ CheckId = 'APP-02'; ObjectName = 'Gamma'; Evidence = $null; Category = 'Applications'; Severity = 'Error'; SuppressKey = 'k3' })
    }

    It 'gives All for a combo with nothing selected, the content of an item, and a string as it is' {
        Get-ComboValue -Combo (New-Combo $null) | Should -Be 'All'
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = 'Error'
        Get-ComboValue -Combo (New-Combo $item) | Should -Be 'Error'
        Get-ComboValue -Combo (New-Combo 'Warning') | Should -Be 'Warning'
    }

    It 'returns every finding with empty filters' {
        @(Get-FilteredFindings).Count | Should -Be 3
    }

    It 'filters findings by text "<Text>" on object, evidence and check id without case and with brackets as plain text' -ForEach @(
        @{ Text = 'alpha'; Expected = @('k1') }, @{ Text = 'DEPLOY'; Expected = @('k1') }, @{ Text = 'pkg-01'; Expected = @('k2') },
        @{ Text = '[x64]'; Expected = @('k2') }, @{ Text = '  gamma  '; Expected = @('k3') }, @{ Text = 'nothing like it'; Expected = @() }, @{ Text = '*'; Expected = @() }
    ) {
        $txtFilter.Text = $Text
        @(Get-FilteredFindings | ForEach-Object SuppressKey) | Should -Be $Expected
    }

    It 'filters by category and severity together' {
        $cboCategory = New-Combo 'Applications'
        $cboSeverity = New-Combo 'Error'
        @(Get-FilteredFindings | ForEach-Object SuppressKey) | Should -Be @('k3')
    }

    It 'hides suppressed findings unless the box is checked' {
        [void]$script:SuppressedKeys.Add('K1')
        @(Get-FilteredFindings).Count | Should -Be 2
        $chkShowSuppressed.IsChecked = $true
        @(Get-FilteredFindings).Count | Should -Be 3
    }

    It 'filters relationship rows by text, kind and status' {
        $script:RelationshipRows = @(
            [PSCustomObject]@{ SourceName = 'A'; TargetName = 'B'; SourceDeploymentType = 'MSI'; Kind = 'Supersedence'; Status = 'Healthy'; Circular = $false }
            [PSCustomObject]@{ SourceName = 'C'; TargetName = 'D'; SourceDeploymentType = 'Script'; Kind = 'Dependency'; Status = 'Healthy'; Circular = $true }
            [PSCustomObject]@{ SourceName = 'E'; TargetName = 'F'; SourceDeploymentType = 'MSI'; Kind = 'Dependency'; Status = 'Orphaned'; Circular = $false })
        @(Get-FilteredRelationshipRows).Count | Should -Be 3
        $txtFilter.Text = 'msi'
        @(Get-FilteredRelationshipRows).Count | Should -Be 2
        $txtFilter.Text = ''
        $cboRelKind = New-Combo 'Dependency'
        @(Get-FilteredRelationshipRows).Count | Should -Be 2
        $cboRelStatus = New-Combo 'Healthy'
        @(Get-FilteredRelationshipRows).SourceName | Should -Be @()
        $cboRelKind = New-Combo 'All'
        @(Get-FilteredRelationshipRows).SourceName | Should -Be @('A')
        $cboRelStatus = New-Combo 'Broken'
        @(Get-FilteredRelationshipRows).SourceName | Should -Be @('C', 'E')
    }

    It 'matches a live row to the status filter <Filter>' -ForEach @(
        @{ Filter = 'OK / Healthy'; Glyph = 0x2713; Expected = $true }, @{ Filter = 'OK / Healthy'; Glyph = 0x2717; Expected = $false },
        @{ Filter = 'Warning / In Progress'; Glyph = 0x26A0; Expected = $true }, @{ Filter = 'Warning / In Progress'; Glyph = 0x2713; Expected = $false },
        @{ Filter = 'Failed / Error'; Glyph = 0x2717; Expected = $true }, @{ Filter = 'Failed / Error'; Glyph = 0x26A0; Expected = $false },
        @{ Filter = 'All'; Glyph = 0x22EF; Expected = $true }
    ) {
        Test-LiveRowMatch -Row ([PSCustomObject]@{ StatusGlyph = [char]$Glyph }) -Filter $Filter | Should -Be $Expected
    }

    It 'filters live rows by the named fields and the status filter, and ignores a field that a row lacks' {
        $rows = @(
            [PSCustomObject]@{ DeviceName = 'PC1'; OperatingSystem = 'Windows 11'; StatusGlyph = $script:Glyph.OK }
            [PSCustomObject]@{ DeviceName = 'PC2'; OperatingSystem = $null; StatusGlyph = $script:Glyph.Error })
        @(Get-FilteredLiveRows -Rows $rows -Fields 'DeviceName', 'OperatingSystem', 'NoSuchField').Count | Should -Be 2
        $txtFilter.Text = 'windows'
        @(Get-FilteredLiveRows -Rows $rows -Fields 'DeviceName', 'OperatingSystem', 'NoSuchField').DeviceName | Should -Be @('PC1')
        $txtFilter.Text = ''
        $cboStatus = New-Combo 'Failed / Error'
        @(Get-FilteredLiveRows -Rows $rows -Fields 'DeviceName').DeviceName | Should -Be @('PC2')
        @(Get-FilteredLiveRows -Rows @() -Fields 'DeviceName').Count | Should -Be 0
    }

    It 'sets the grid of the active view to a list, also for one row' {
        $gridFindings = New-Grid
        $gridDeploy = New-Grid
        $script:ActiveView = 'Findings'
        $txtFilter.Text = 'alpha'
        Update-Filter
        $gridFindings.ItemsSource -is [array] | Should -BeTrue
        $gridFindings.ItemsSource.Count | Should -Be 1
        $gridDeploy.ItemsSource | Should -BeNullOrEmpty
        $script:ActiveView = 'Deployments'
        $script:DeploymentRows = @([PSCustomObject]@{ DeploymentName = 'App'; CollectionName = 'c'; DeploymentType = 'Application'; StatusGlyph = $script:Glyph.OK })
        $txtFilter.Text = ''
        Update-Filter
        $gridDeploy.ItemsSource.Count | Should -Be 1
    }

    It 'does nothing for a view without a grid' {
        $script:ActiveView = 'Summary'
        { Update-Filter } | Should -Not -Throw
    }

    It 'counts the suppressed keys in the label' {
        $txtSuppressCount = [PSCustomObject]@{ Text = '' }
        [void]$script:SuppressedKeys.Add('a')
        [void]$script:SuppressedKeys.Add('A')
        [void]$script:SuppressedKeys.Add('b')
        Update-SuppressCount
        $txtSuppressCount.Text | Should -Be '2 key(s) suppressed'
    }

    It 'offers Run Fix only for rows that are not fixed and have a script to run' {
        $gridFindings = [PSCustomObject]@{ SelectedItems = @(
                [PSCustomObject]@{ FixState = ''; FixScript = "Remove-CMPackage -Id 'P1'" }
                [PSCustomObject]@{ FixState = 'Fixed'; FixScript = "Remove-CMPackage -Id 'P2'" }
                [PSCustomObject]@{ FixState = 'Failed'; FixScript = "Remove-CMPackage -Id 'P3'" }
                [PSCustomObject]@{ FixState = ''; FixScript = '# guidance only' }
                [PSCustomObject]@{ FixState = ''; FixScript = $null }) }
        @(Get-RunnableSelection).FixScript | Should -Be @("Remove-CMPackage -Id 'P1'", "Remove-CMPackage -Id 'P3'")
    }
}

Describe 'Suppression keys and preferences' {
    BeforeEach {
        $global:SuppressPath = Join-Path $TestDrive 'sup.json'
        $global:PrefsPath = Join-Path $TestDrive 'prefs.json'
        Remove-Item -LiteralPath $global:SuppressPath, $global:PrefsPath -ErrorAction SilentlyContinue
        Import-SuiteCommonGlobal
    }

    It 'keeps a key set without case and without empty keys across a save and a read' {
        $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        [void]$set.Add('APP-01|x')
        [void]$set.Add('PKG-01|y')
        Save-ShSuppressedKeys -KeySet $set
        $back = Get-ShSuppressedKeys
        $back.Count | Should -Be 2
        $back.Contains('app-01|X') | Should -BeTrue
    }

    It 'returns an empty set when the file is missing or holds blank keys' {
        (Get-ShSuppressedKeys).Count | Should -Be 0
        Set-Content -LiteralPath $global:SuppressPath -Value '{"Keys":["a","", "  ", null]}'
        (Get-ShSuppressedKeys).Count | Should -Be 1
    }

    It 'reads a damaged suppression file as no suppressions without an error' {
        Set-Content -LiteralPath $global:SuppressPath -Value '{broken'
        { Get-ShSuppressedKeys } | Should -Not -Throw
        (Get-ShSuppressedKeys).Count | Should -Be 0
    }

    It 'reads a file in the format that earlier versions wrote: <Case>' -ForEach @(
        @{ Case = 'several keys'; Json = '{"Keys":["APP-01|a","PKG-01|b"]}'; Count = 2 }
        @{ Case = 'one key as a plain string'; Json = '{"Keys":"APP-01|a"}'; Count = 1 }
        @{ Case = 'an empty list'; Json = '{"Keys":[]}'; Count = 0 }
        @{ Case = 'no Keys property'; Json = '{"Other":1}'; Count = 0 }
    ) {
        Set-Content -LiteralPath $global:SuppressPath -Value $Json
        (Get-ShSuppressedKeys).Count | Should -Be $Count
    }

    It 'leaves the file of an earlier version unchanged when it reads it' {
        $json = '{"Keys":["APP-01|a"]}'
        Set-Content -LiteralPath $global:SuppressPath -Value $json
        $before = [System.IO.File]::ReadAllBytes($global:SuppressPath)
        $null = Get-ShSuppressedKeys
        [System.IO.File]::ReadAllBytes($global:SuppressPath) | Should -Be $before
    }
    It 'returns the defaults without a file and keeps a saved value' {
        $p = Get-ShPreferences
        $p.DarkMode | Should -BeTrue
        $p.AutoRefreshMinutes | Should -Be 15
        $p.InactiveThresholdDays | Should -Be 14
        $p.AlertCompliancePct | Should -Be 80
        $p.SqlTrustServerCertificate | Should -BeTrue
        $p.SiteCode = 'ABC'
        Save-ShPreferences -Prefs $p
        (Get-ShPreferences).SiteCode | Should -Be 'ABC'
    }

    It 'falls back to the defaults for a damaged preferences file' {
        Set-Content -LiteralPath $global:PrefsPath -Value '{broken'
        (Get-ShPreferences).AutoRefreshMinutes | Should -Be 15
    }
}

Describe 'Status text and log' {
    BeforeEach {
        $txtStatus = [PSCustomObject]@{ Text = '' }
        $script:ActiveView = 'Findings'
        $global:Prefs = @{ SiteCode = 'ABC'; SMSProvider = 'cm01' }
        $script:LastScanTime = $null; $script:LiveConnected = $false; $script:AllFindings = @(); $script:AutoRefreshPaused = $false
        foreach ($n in 'DeploymentCounts', 'ContentCounts', 'DPCounts', 'ClientCounts', 'InactiveCounts', 'SiteCounts', 'LastRefreshTime') { Set-Variable -Name $n -Scope Script -Value $null }
    }

    It 'asks for the site settings first' {
        $global:Prefs = @{ SiteCode = ''; SMSProvider = 'cm01' }
        Update-StatusBarSummary
        $txtStatus.Text | Should -Be 'Open Options to configure site code and SMS provider'
    }

    It 'says what to click on a scan view and on a live view' {
        Update-StatusBarSummary
        $txtStatus.Text | Should -Be 'Ready. Click Scan.'
        $script:ActiveView = 'Deployments'
        Update-StatusBarSummary
        $txtStatus.Text | Should -Be 'Ready. Click Refresh All.'
    }

    It 'counts the findings by severity after a scan' {
        $script:LastScanTime = [datetime]'2026-11-06 10:11:12'
        $script:AllFindings = @(
            [PSCustomObject]@{ Severity = 'Error' }, [PSCustomObject]@{ Severity = 'Warning' }, [PSCustomObject]@{ Severity = 'Warning' }, [PSCustomObject]@{ Severity = 'Info' })
        Update-StatusBarSummary
        $txtStatus.Text | Should -Be 'Connected to ABC   |   4 findings (1 error, 2 warning, 1 info)   |   last scan 10:11:12'
    }

    It 'lists the live counts that exist and the pause' {
        $script:ActiveView = 'Site'
        $script:LiveConnected = $true
        $script:DeploymentCounts = [PSCustomObject]@{ TotalDeployments = 5; FailedDeployments = 1 }
        $script:SiteCounts = [PSCustomObject]@{ OKCount = 9; CriticalCount = 2 }
        $script:AutoRefreshPaused = $true
        Update-StatusBarSummary
        $txtStatus.Text | Should -Be 'Connected to ABC   |   5 deployments / 1 failed   |   site 9 OK / 2 crit   |   auto-refresh paused'
    }

    It 'adds a line to the log pane and keeps the earlier lines' {
        $txtLog = New-Object System.Windows.Controls.TextBox
        Mock Write-Log { }
        Add-LogLine 'first'
        Add-LogLine 'second' -Level WARN
        $lines = @($txtLog.Text -split "`r?`n")
        $lines.Count | Should -Be 2
        $lines[0] | Should -Match '^\d\d:\d\d:\d\d  first$'
        $lines[1] | Should -Match '  second$'
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -eq 'second' -and $Level -eq 'WARN' }
    }

    It 'strips the timestamp and level of a line that the background runspace already logged' {
        $txtLog = New-Object System.Windows.Controls.TextBox
        Mock Write-Host { }
        Mock Write-Log { }
        Add-LogLine '[2026-11-06 10:00:00] [WARN ] Dataset x unavailable' -FromBackground
        $txtLog.Text | Should -Match '^\d\d:\d\d:\d\d  Dataset x unavailable$'
        Should -Invoke Write-Log -Times 0 -Exactly
    }

    It 'tells the user when a background operation is running' {
        $txtLog = New-Object System.Windows.Controls.TextBox
        Mock Write-Log { }
        $script:BgPowerShell = $null
        Test-BgBusy -Action 'Scan' | Should -BeFalse
        $script:BgPowerShell = [PSCustomObject]@{ Running = $true }
        $script:BgKind = 'Fix'
        Test-BgBusy -Action 'Scan' | Should -BeTrue
        $txtLog.Text | Should -BeLike '*Scan: a fix is still running.'
        $script:BgKind = ''
        Test-BgBusy -Action 'Scan' | Should -BeTrue
        $txtLog.Text | Should -BeLike '*a background operation is still running.'
        $script:BgPowerShell = $null
    }

    It 'sets the status text' {
        Set-StatusText -Text 'Working'
        $txtStatus.Text | Should -Be 'Working'
    }

    It 'sets a control visible or collapsed' {
        $c = New-Object System.Windows.Controls.Button
        Set-ControlVisible -Control $c -Visible $false
        $c.Visibility | Should -Be 'Collapsed'
        Set-ControlVisible -Control $c -Visible $true
        $c.Visibility | Should -Be 'Visible'
    }

    It 'reads the trend range from the combo and falls back to 30 days' -ForEach @(
        @{ Content = '7 days'; Expected = 7 }, @{ Content = '90 days'; Expected = 90 }, @{ Content = 'all'; Expected = 30 }, @{ Content = $null; Expected = 30 }
    ) {
        $item = if ($null -ne $Content) { [PSCustomObject]@{ Content = $Content } } else { $null }
        $cboTrendRange = [PSCustomObject]@{ SelectedItem = $item }
        Get-TrendRangeDays | Should -Be $Expected
    }
}

Describe 'Alerts' {
    BeforeEach {
        $global:Prefs = @{ AlertsEnabled = $true; AlertCompliancePct = 80 }
        $script:AlertBreachState = @{}
        foreach ($n in 'DeploymentCounts', 'ContentCounts', 'DPCounts', 'SiteCounts') { Set-Variable -Name $n -Scope Script -Value $null }
        $global:AlertLogPath = Join-Path $TestDrive 'alerts.log'
        $txtLog = New-Object System.Windows.Controls.TextBox
        Mock Write-Log { }
        Mock Send-ShToast { $true }
    }

    It 'sends one alert when a metric crosses into breach and none while it stays there' {
        $script:SiteCounts = [PSCustomObject]@{ CriticalCount = 2 }
        Invoke-AlertEvaluation
        Invoke-AlertEvaluation
        Should -Invoke Send-ShToast -Times 1 -Exactly -ParameterFilter { $Message -eq 'Site health: 2 component / site-system item(s) critical.' }
        @(Get-Content -LiteralPath $global:AlertLogPath).Count | Should -Be 1
    }

    It 'alerts again after the metric recovers and breaches again' {
        $script:SiteCounts = [PSCustomObject]@{ CriticalCount = 1 }
        Invoke-AlertEvaluation
        $script:SiteCounts = [PSCustomObject]@{ CriticalCount = 0 }
        Invoke-AlertEvaluation
        $script:SiteCounts = [PSCustomObject]@{ CriticalCount = 3 }
        Invoke-AlertEvaluation
        Should -Invoke Send-ShToast -Times 2 -Exactly
    }

    It 'alerts on <Rule> when its threshold is crossed' -ForEach @(
        @{ Rule = 'a critical distribution point'; Var = 'DPCounts'; Value = @{ OfflineCount = 1 }; Text = '1 distribution point(s) in critical state.' }
        @{ Rule = 'a failed content pair'; Var = 'ContentCounts'; Value = @{ TotalFailedPairs = 4 }; Text = '4 failed DP-content pair(s).' }
        @{ Rule = 'compliance below the floor'; Var = 'DeploymentCounts'; Value = @{ TotalDeployments = 10; OverallCompliance = 79.9 }; Text = 'Overall deployment compliance 79.9% is below the 80% floor.' }
    ) {
        Set-Variable -Name $Var -Scope Script -Value ([PSCustomObject]$Value)
        Invoke-AlertEvaluation
        Should -Invoke Send-ShToast -Times 1 -Exactly -ParameterFilter { $Message -eq $Text }
    }

    It 'does not alert at the compliance floor, for no deployments, for a healthy site or when alerts are off' {
        $script:DeploymentCounts = [PSCustomObject]@{ TotalDeployments = 10; OverallCompliance = 80 }
        $script:SiteCounts = [PSCustomObject]@{ CriticalCount = 0 }
        Invoke-AlertEvaluation
        $script:DeploymentCounts = [PSCustomObject]@{ TotalDeployments = 0; OverallCompliance = 0 }
        Invoke-AlertEvaluation
        $script:SiteCounts = [PSCustomObject]@{ CriticalCount = 5 }
        $global:Prefs.AlertsEnabled = $false
        Invoke-AlertEvaluation
        Should -Invoke Send-ShToast -Times 0 -Exactly
    }

    It 'records the alert in the log pane when no toast can be shown' {
        Mock Send-ShToast { $false }
        $script:SiteCounts = [PSCustomObject]@{ CriticalCount = 1 }
        Invoke-AlertEvaluation
        $txtLog.Text | Should -BeLike '*Toast delivery unavailable*'
        $txtLog.Text | Should -BeLike '*ALERT: Site health*'
    }

    It 'still logs the alert when the alert log cannot be written' {
        $global:AlertLogPath = Join-Path $TestDrive 'no\such\folder\alerts.log'
        $script:SiteCounts = [PSCustomObject]@{ CriticalCount = 1 }
        { Invoke-AlertEvaluation } | Should -Not -Throw
        $txtLog.Text | Should -BeLike '*ALERT: Site health*'
    }
}

Describe 'Export' {
    BeforeEach {
        $script:ActiveView = 'Findings'
        $txtFilter = [PSCustomObject]@{ Text = '' }
        $cboCategory = New-Combo 'All'; $cboSeverity = New-Combo 'All'; $cboRelKind = New-Combo 'All'; $cboRelStatus = New-Combo 'All'
        $chkShowSuppressed = [PSCustomObject]@{ IsChecked = $true }
        $script:SuppressedKeys = [System.Collections.Generic.HashSet[string]]::new()
        $script:AllFindings = @()
        $txtLog = New-Object System.Windows.Controls.TextBox
        Mock Write-Log { }
    }

    It 'builds a text-only table with the given columns, in order, and a blank for a missing property' {
        $dt = ConvertTo-DataTableForExport -Rows @([PSCustomObject]@{ A = 1; B = 'x' }, [PSCustomObject]@{ A = 2 }) -Columns 'B', 'A', 'C'
        ($dt.Columns | ForEach-Object ColumnName) | Should -Be @('B', 'A', 'C')
        $dt.Rows.Count | Should -Be 2
        $dt.Rows[0]['B'] | Should -Be 'x'
        $dt.Rows[1]['B'] | Should -Be ''
        $dt.Rows[1]['C'] | Should -Be ''
    }

    It 'takes the columns from the first row without the status glyph, and returns an empty table for no rows' {
        $dt = ConvertTo-DataTableForExport -Rows @([PSCustomObject]@{ StatusGlyph = 'x'; Name = 'n' })
        ($dt.Columns | ForEach-Object ColumnName) | Should -Be @('Name')
        (ConvertTo-DataTableForExport -Rows @()).Columns.Count | Should -Be 0
    }

    It 'describes the export of view <View>' -ForEach @(
        @{ View = 'Deployments'; Name = 'Deployments' }, @{ View = 'Content'; Name = 'Content' }, @{ View = 'DPs'; Name = 'DistributionPoints' },
        @{ View = 'Clients'; Name = 'ClientHealth' }, @{ View = 'Inactive'; Name = 'InactiveDevices' }, @{ View = 'Site'; Name = 'SiteHealth' }, @{ View = 'Relationships'; Name = 'Relationships' }
    ) {
        $script:ActiveView = $View
        $script:RelationshipRows = @()
        $gridDeploy = [PSCustomObject]@{ ItemsSource = @(1) }; $gridContent = $gridDeploy; $gridDPs = $gridDeploy; $gridClients = $gridDeploy; $gridInactive = $gridDeploy; $gridSite = $gridDeploy
        $info = Get-ActiveExportInfo
        $info.Name | Should -Be $Name
        $info.Columns.Count | Should -BeGreaterThan 2
    }

    It 'has no export for a view without a table' {
        $script:ActiveView = 'Summary'
        Get-ActiveExportInfo | Should -BeNullOrEmpty
    }

    It 'exports the rows of the live view <View> as <Extension> to the file the user picked' -ForEach @(
        foreach ($v in 'Deployments', 'Content', 'DPs', 'Clients', 'Inactive', 'Site') { foreach ($x in 'csv', 'html') { @{ View = $v; Extension = $x } } }
    ) {
        $script:ActiveView = $View
        $rows = @([PSCustomObject]@{ DeploymentName = 'RowAlpha'; ContentName = 'RowAlpha'; DPName = 'RowAlpha'; DeviceName = 'RowAlpha'; Name = 'RowAlpha' }, [PSCustomObject]@{ DeploymentName = 'RowBeta'; ContentName = 'RowBeta'; DPName = 'RowBeta'; DeviceName = 'RowBeta'; Name = 'RowBeta' })
        $gridDeploy = [PSCustomObject]@{ ItemsSource = $rows }; $gridContent = $gridDeploy; $gridDPs = $gridDeploy; $gridClients = $gridDeploy; $gridInactive = $gridDeploy; $gridSite = $gridDeploy
        $global:Out = Join-Path $TestDrive ('live-{0}.{1}' -f $View, $Extension)
        Mock Show-ExportSaveDialog { $global:Out }
        Invoke-Export -Extension $Extension
        Test-Path -LiteralPath $global:Out | Should -BeTrue
        $text = [System.IO.File]::ReadAllText($global:Out)
        $body = if ($Extension -eq 'html') { [regex]::Match($text, '(?s)<tbody>(.*)</tbody>').Groups[1].Value } else { $text }
        $body | Should -Match 'RowAlpha'
        $body | Should -Match 'RowBeta'
        $txtLog.Text | Should -BeLike ('*Exported {0}: *' -f $Extension.ToUpperInvariant())
    }

    It 'says nothing is exported when the view has no rows and asks for no file' {
        Mock Show-ExportSaveDialog { 'x' }
        Invoke-Export -Extension csv
        Should -Invoke Show-ExportSaveDialog -Times 0 -Exactly
        $txtLog.Text | Should -BeLike '*Export CSV: nothing to export.'
    }

    It 'exports the findings that the filter shows to the file the user picked' {
        $script:AllFindings = @([PSCustomObject]@{ CheckId = 'APP-01'; Severity = 'Warning'; Category = 'Applications'; ObjectType = 'Application'; ObjectId = 'i'; ObjectName = 'Alpha'; Evidence = 'e'; Recommendation = 'r'; FixScript = ''; SuppressKey = 'k' })
        $global:Out = Join-Path $TestDrive 'findings.csv'
        Mock Show-ExportSaveDialog { $global:Out }
        Invoke-Export -Extension csv
        @(Import-Csv -LiteralPath $global:Out).ObjectName | Should -Be @('Alpha')
        $txtLog.Text | Should -BeLike '*Exported CSV: *findings.csv'
    }

    It 'writes nothing when the user cancels the save dialog' {
        $script:AllFindings = @([PSCustomObject]@{ CheckId = 'APP-01'; Severity = 'Warning'; Category = 'Applications'; ObjectType = 'Application'; ObjectId = 'i'; ObjectName = 'Alpha'; Evidence = 'e'; Recommendation = 'r'; FixScript = ''; SuppressKey = 'k' })
        Mock Show-ExportSaveDialog { $null }
        Mock Export-HygieneCsv { }
        Invoke-Export -Extension csv
        Should -Invoke Export-HygieneCsv -Times 0 -Exactly
        $txtLog.Text | Should -BeNullOrEmpty
    }
}

Describe 'Get-RelationshipAppLines' {
    BeforeEach {
        $script:RelData = [PSCustomObject]@{
            Apps          = @{ 5 = [PSCustomObject]@{ CI_ID = 5; Name = 'App'; SoftwareVersion = '2.0'; Manufacturer = ''; IsEnabled = $true; IsExpired = $false; HasContent = $true } }
            Relationships = @(
                [PSCustomObject]@{ FromAppCIID = 5; ToAppCIID = 6; Kind = 'Supersedence' }
                [PSCustomObject]@{ FromAppCIID = 5; ToAppCIID = 7; Kind = 'Dependency' }
                [PSCustomObject]@{ FromAppCIID = 8; ToAppCIID = 5; Kind = 'Dependency' })
        }
    }

    It 'says so for a node that points at a deleted application' {
        Get-RelationshipAppLines -CIID 0 | Should -Be @('This node references an application that no longer exists in the site.')
    }

    It 'says so for an id that is not in the data' {
        Get-RelationshipAppLines -CIID 99 | Should -Be @('CI_ID 99 is not in the relationship data.')
    }

    It 'describes an application with its manufacturer placeholder and the edge counts' {
        $lines = Get-RelationshipAppLines -CIID 5
        $lines[0] | Should -Be 'App  (CI_ID 5)'
        $lines[2] | Should -BeLike '*(not set)'
        $lines[4] | Should -Be 'Outgoing:       1 supersedence, 1 dependency'
        $lines[5] | Should -Be 'Incoming:       0 supersedence, 1 dependency'
    }
}

Describe 'Add-RelationshipTreeNodes' {
    It 'adds the nodes with their glyph, label and application id, children included' {
        $parent = New-Object System.Windows.Controls.TreeViewItem
        $nodes = @([PSCustomObject]@{ Glyph = 'G'; Label = 'Parent'; AppCIID = 1; Children = @([PSCustomObject]@{ Glyph = 'H'; Label = 'Child'; AppCIID = 2; Children = @() }) })
        Add-RelationshipTreeNodes -Parent $parent -Nodes $nodes
        $parent.Items.Count | Should -Be 1
        $parent.Items[0].Header | Should -Be 'G  Parent'
        $parent.Items[0].Tag | Should -Be 1
        $parent.Items[0].Items[0].Header | Should -Be 'H  Child'
    }

    It 'adds nothing for an empty list' {
        $parent = New-Object System.Windows.Controls.TreeViewItem
        Add-RelationshipTreeNodes -Parent $parent -Nodes @()
        $parent.Items.Count | Should -Be 0
    }
}
