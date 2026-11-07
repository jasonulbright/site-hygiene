#Requires -Modules Pester
# The Live functions (SiteHygieneLive.psm1): deployment, content, distribution point, client, inactive device
# and site reads with mocked provider and SQL calls, the metrics history, the table exports and the legacy
# dashboard import. Every read is mocked; no site or SQL server is needed.

BeforeAll {
    . "$PSScriptRoot\TestHelpers.ps1"
    Import-AppModule
    $script:Stubs = New-CmStub -Name 'Get-CMDeployment', 'Get-CMApplicationDeploymentStatus', 'Get-CMSoftwareUpdateDeploymentStatus',
    'Get-CMBaselineDeploymentStatus', 'Get-CMPackageDeploymentStatus', 'Get-CMDeploymentStatusDetails', 'Invoke-CMWmiQuery', 'Get-CMDistributionPoint'
    $script:Stubs += New-CmStub -Name 'Invoke-Sqlcmd' -Definition { [CmdletBinding()] param($ServerInstance, $Database, $Query, $QueryTimeout, [switch]$TrustServerCertificate) }
    $script:Mod = 'SiteHygieneLive'
    function New-Table {
        param([string[]]$Columns, [object[][]]$Rows)
        $dt = New-Object System.Data.DataTable
        foreach ($c in $Columns) { [void]$dt.Columns.Add($c, [string]) }
        foreach ($r in $Rows) { [void]$dt.Rows.Add([string[]]$r) }
        , $dt
    }
}

AfterAll { Remove-CmStub -Name $script:Stubs }

Describe 'Get-DeploymentHealth' {
    BeforeEach {
        Mock Write-Log { } -ModuleName $script:Mod
    }

    It 'maps feature type <Type> to <Name>' -ForEach @(
        @{ Type = 1; Name = 'Application' }, @{ Type = 2; Name = 'Program' }, @{ Type = 3; Name = 'Mobile Program' }, @{ Type = 4; Name = 'Script' },
        @{ Type = 5; Name = 'Software Update' }, @{ Type = 6; Name = 'Baseline' }, @{ Type = 7; Name = 'Task Sequence' },
        @{ Type = 8; Name = 'Content Distribution' }, @{ Type = 9; Name = 'DP Group' }, @{ Type = 10; Name = 'DP Health' },
        @{ Type = 11; Name = 'Configuration Policy' }, @{ Type = 99; Name = 'Other (99)' }
    ) {
        $global:Fx = [PSCustomObject]@{ DeploymentID = 'D1'; SoftwareName = 'x'; FeatureType = $Type; DeploymentIntent = 1; NumberTargeted = 1 }
        Mock Get-CMDeployment { $global:Fx } -ModuleName $script:Mod
        @(Get-DeploymentHealth)[0].DeploymentType | Should -Be $Name
    }

    It 'maps intent <Intent> to <Purpose>' -ForEach @(
        @{ Intent = 1; Purpose = 'Required' }, @{ Intent = 2; Purpose = 'Available' }, @{ Intent = 3; Purpose = 'Simulate' }, @{ Intent = 0; Purpose = 'Unknown' }
    ) {
        $global:Fx = [PSCustomObject]@{ DeploymentID = 'D1'; SoftwareName = 'x'; FeatureType = 1; DeploymentIntent = $Intent; NumberTargeted = 1 }
        Mock Get-CMDeployment { $global:Fx } -ModuleName $script:Mod
        @(Get-DeploymentHealth)[0].Purpose | Should -Be $Purpose
    }

    It 'names a deployment after <Case>' -ForEach @(
        @{ Case = 'the software name'; Props = @{ SoftwareName = 'Soft'; ApplicationName = 'App' }; Expected = 'Soft' }
        @{ Case = 'the application name'; Props = @{ ApplicationName = 'App' }; Expected = 'App' }
        @{ Case = 'the deployment id'; Props = @{}; Expected = 'D1' }
    ) {
        $o = [ordered]@{ DeploymentID = 'D1'; FeatureType = 1; DeploymentIntent = 1; NumberTargeted = 1 }
        foreach ($k in $Props.Keys) { $o[$k] = $Props[$k] }
        $global:Fx = [PSCustomObject]$o
        Mock Get-CMDeployment { $global:Fx } -ModuleName $script:Mod
        @(Get-DeploymentHealth)[0].DeploymentName | Should -Be $Expected
    }

    It 'computes the compliance percentage and survives zero targeted devices' {
        $global:Fx = @(
            [PSCustomObject]@{ DeploymentID = 'A'; SoftwareName = 'a'; FeatureType = 1; DeploymentIntent = 1; NumberTargeted = 3; NumberSuccess = 1; NumberErrors = 1; NumberInProgress = 1; NumberUnknown = 0 }
            [PSCustomObject]@{ DeploymentID = 'B'; SoftwareName = 'b'; FeatureType = 1; DeploymentIntent = 1; NumberTargeted = 0; NumberSuccess = 0 })
        Mock Get-CMDeployment { $global:Fx } -ModuleName $script:Mod
        $r = @(Get-DeploymentHealth)
        $r[0].PercentCompliant | Should -Be 33.3
        $r[1].PercentCompliant | Should -Be 0
        $r[1].NumberErrors | Should -Be 0
    }

    It 'returns nothing for a site with no deployments' {
        Mock Get-CMDeployment { } -ModuleName $script:Mod
        @(Get-DeploymentHealth).Count | Should -Be 0
    }

    It 'lets a provider failure reach the caller' {
        Mock Get-CMDeployment { throw 'provider down' } -ModuleName $script:Mod
        { Get-DeploymentHealth } | Should -Throw '*provider down*'
    }
}

Describe 'Get-DeploymentDetails' {
    BeforeEach {
        Mock Write-Log { } -ModuleName $script:Mod
        $global:Fx = [PSCustomObject]@{ FeatureType = 1 }
        Mock Get-CMDeployment { $global:Fx } -ModuleName $script:Mod
        Mock Get-CMApplicationDeploymentStatus { [PSCustomObject]@{ Kind = 'app' } } -ModuleName $script:Mod
        Mock Get-CMSoftwareUpdateDeploymentStatus { [PSCustomObject]@{ Kind = 'sum' } } -ModuleName $script:Mod
        Mock Get-CMBaselineDeploymentStatus { [PSCustomObject]@{ Kind = 'baseline' } } -ModuleName $script:Mod
        Mock Get-CMPackageDeploymentStatus { [PSCustomObject]@{ Kind = 'package' } } -ModuleName $script:Mod
        Mock Get-CMDeploymentStatusDetails { [PSCustomObject]@{ DeviceName = 'PC1'; AppStatusType = 5; StatusTime = [datetime]'2026-01-02' } } -ModuleName $script:Mod
    }

    It 'asks the status cmdlet for feature type <Type> and reads the details' -ForEach @(
        @{ Type = 1; Cmdlet = 'Get-CMApplicationDeploymentStatus' }, @{ Type = 5; Cmdlet = 'Get-CMSoftwareUpdateDeploymentStatus' },
        @{ Type = 6; Cmdlet = 'Get-CMBaselineDeploymentStatus' }, @{ Type = 2; Cmdlet = 'Get-CMPackageDeploymentStatus' }, @{ Type = 7; Cmdlet = 'Get-CMPackageDeploymentStatus' }
    ) {
        $global:Fx = [PSCustomObject]@{ FeatureType = $Type }
        $r = @(Get-DeploymentDetails -DeploymentId 'D1')
        $r.Count | Should -Be 1
        $r[0].DeviceName | Should -Be 'PC1'
        $r[0].StatusDescription | Should -Be 'Error'
        foreach ($c in 'Get-CMApplicationDeploymentStatus', 'Get-CMSoftwareUpdateDeploymentStatus', 'Get-CMBaselineDeploymentStatus', 'Get-CMPackageDeploymentStatus') {
            Should -Invoke $c -ModuleName $script:Mod -Times $(if ($c -eq $Cmdlet) { 1 } else { 0 }) -Exactly
        }
    }

    It 'returns an empty list when the deployment does not exist' {
        Mock Get-CMDeployment { } -ModuleName $script:Mod
        @(Get-DeploymentDetails -DeploymentId 'NOPE').Count | Should -Be 0
        Should -Invoke Get-CMDeploymentStatusDetails -ModuleName $script:Mod -Times 0 -Exactly
    }

    It 'returns an empty list and logs a warning when a read fails' {
        Mock Get-CMApplicationDeploymentStatus { throw 'access denied' } -ModuleName $script:Mod
        @(Get-DeploymentDetails -DeploymentId 'D1').Count | Should -Be 0
        Should -Invoke Write-Log -ModuleName $script:Mod -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Message -like '*access denied*' }
    }

    It 'reads <Case>' -ForEach @(
        @{ Case = 'a machine name when there is no device name'; Row = [PSCustomObject]@{ MachineName = 'M1'; StatusType = 1 }; Device = 'M1'; Type = 1; Text = 'Success' }
        @{ Case = 'no name at all'; Row = [PSCustomObject]@{ Other = 1 }; Device = ''; Type = 4; Text = 'Unknown' }
        @{ Case = 'an unlisted status'; Row = [PSCustomObject]@{ DeviceName = 'D'; AppStatusType = 9 }; Device = 'D'; Type = 9; Text = 'Status 9' }
        @{ Case = 'in progress'; Row = [PSCustomObject]@{ DeviceName = 'D'; AppStatusType = 2 }; Device = 'D'; Type = 2; Text = 'In Progress' }
        @{ Case = 'requirements not met'; Row = [PSCustomObject]@{ DeviceName = 'D'; AppStatusType = 3 }; Device = 'D'; Type = 3; Text = 'Requirements Not Met' }
    ) {
        $global:Fx2 = $Row
        Mock Get-CMDeploymentStatusDetails { $global:Fx2 } -ModuleName $script:Mod
        $r = @(Get-DeploymentDetails -DeploymentId 'D1')[0]
        $r.DeviceName | Should -Be $Device
        $r.StatusType | Should -Be $Type
        $r.StatusDescription | Should -Be $Text
        $r.LastStatusTime | Should -BeNullOrEmpty
    }
}

Describe 'Health counts' {
    It 'counts deployments, failures and overall compliance' {
        $c = Get-DeploymentHealthCounts -DeploymentData @(
            [PSCustomObject]@{ NumberErrors = 1; NumberTargeted = 10; NumberSuccess = 5 }
            [PSCustomObject]@{ NumberErrors = 0; NumberTargeted = 10; NumberSuccess = 10 })
        $c.TotalDeployments | Should -Be 2
        $c.FailedDeployments | Should -Be 1
        $c.OverallCompliance | Should -Be 75
    }

    It 'gives zero counts for an empty list' {
        $c = Get-DeploymentHealthCounts -DeploymentData @()
        $c.TotalDeployments | Should -Be 0
        $c.OverallCompliance | Should -Be 0
        (Get-ContentHealthCounts -ContentData @()).TotalFailedPairs | Should -Be 0
        (Get-DPHealthCounts -DPData @()).TotalDPs | Should -Be 0
        (Get-ClientHealthCounts -ClientData @()).HealthyCount | Should -Be 0
        (Get-InactiveDeviceCounts -DeviceData @()).InactiveCount | Should -Be 0
        (Get-SiteHealthCounts).CriticalCount | Should -Be 0
    }

    It 'counts content with issues and failed pairs' {
        $c = Get-ContentHealthCounts -ContentData @([PSCustomObject]@{ FailedCount = 2 }, [PSCustomObject]@{ FailedCount = 1 })
        $c.TotalContentWithIssues | Should -Be 2
        $c.TotalFailedPairs | Should -Be 3
    }

    It 'counts distribution points by status' {
        $c = Get-DPHealthCounts -DPData @([PSCustomObject]@{ Status = 'Critical' }, [PSCustomObject]@{ Status = 'Warning' }, [PSCustomObject]@{ Status = 'OK' })
        $c.TotalDPs | Should -Be 3
        $c.OfflineCount | Should -Be 1
        $c.DegradedCount | Should -Be 1
    }

    It 'counts client health and activity' {
        $c = Get-ClientHealthCounts -ClientData @(
            [PSCustomObject]@{ HealthStateValue = 1; ActiveStatusValue = 1 }
            [PSCustomObject]@{ HealthStateValue = 2; ActiveStatusValue = 0 }
            [PSCustomObject]@{ HealthStateValue = 3; ActiveStatusValue = 0 })
        $c.HealthyCount | Should -Be 1
        $c.UnhealthyCount | Should -Be 1
        $c.InactiveCount | Should -Be 2
    }

    It 'counts site items by status value across components and systems' {
        $c = Get-SiteHealthCounts -ComponentData @([PSCustomObject]@{ StatusValue = 0 }, [PSCustomObject]@{ StatusValue = 2 }) -SystemData @([PSCustomObject]@{ StatusValue = 1 }, [PSCustomObject]@{ StatusValue = 0 })
        $c.OKCount | Should -Be 2
        $c.WarningCount | Should -Be 1
        $c.CriticalCount | Should -Be 1
    }
}

Describe 'Content reads' {
    BeforeEach { Mock Write-Log { } -ModuleName $script:Mod }

    It 'reports only packages with a failed or in-progress pair, with the right counts' {
        $global:Fx = @(
            foreach ($s in 0, 8, 3) { [PSCustomObject]@{ PackageID = 'P1'; State = $s } }
            foreach ($s in 0, 0) { [PSCustomObject]@{ PackageID = 'P2'; State = $s } }
            foreach ($s in 1, 2, 4, 5, 7, 6) { [PSCustomObject]@{ PackageID = 'P3'; State = $s } })
        Mock Invoke-CMWmiQuery { $global:Fx } -ModuleName $script:Mod
        $r = @(Get-ContentDistributionHealth)
        $r.Count | Should -Be 2
        $p1 = $r | Where-Object PackageID -eq 'P1'
        $p1.TotalDPs | Should -Be 3
        $p1.InstalledCount | Should -Be 2
        $p1.FailedCount | Should -Be 1
        $p1.PctComplete | Should -Be '66.7%'
        $p3 = $r | Where-Object PackageID -eq 'P3'
        $p3.InProgressCount | Should -Be 5
        $p3.FailedCount | Should -Be 1
    }

    It 'returns nothing when every package is installed' {
        Mock Invoke-CMWmiQuery { [PSCustomObject]@{ PackageID = 'P1'; State = 0 } } -ModuleName $script:Mod
        @(Get-ContentDistributionHealth).Count | Should -Be 0
    }

    It 'maps package type <Type> to <Name>' -ForEach @(
        @{ Type = 0; Name = 'Package' }, @{ Type = 3; Name = 'Driver Package' }, @{ Type = 4; Name = 'Task Sequence' }, @{ Type = 5; Name = 'Software Update' },
        @{ Type = 6; Name = 'Device Setting' }, @{ Type = 7; Name = 'Virtual App' }, @{ Type = 8; Name = 'Application' }, @{ Type = 257; Name = 'OS Image' },
        @{ Type = 258; Name = 'Boot Image' }, @{ Type = 259; Name = 'OS Upgrade' }, @{ Type = 42; Name = 'Type 42' }
    ) {
        $global:Fx = [PSCustomObject]@{ PackageID = 'P1'; Name = 'Thing'; PackageType = $Type }
        Mock Invoke-CMWmiQuery { $global:Fx } -ModuleName $script:Mod
        $m = Get-ContentNameMap
        $m['P1'].Name | Should -Be 'Thing'
        $m['P1'].Type | Should -Be $Name
    }

    It 'returns an empty map and logs a warning when the lookup fails' {
        Mock Invoke-CMWmiQuery { throw 'no class' } -ModuleName $script:Mod
        (Get-ContentNameMap).Count | Should -Be 0
        Should -Invoke Write-Log -ModuleName $script:Mod -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' }
    }

    It 'returns the rows of one distribution point from the cached rows' {
        $rows = @([PSCustomObject]@{ DPName = 'A'; V = 1 }, [PSCustomObject]@{ DPName = 'B'; V = 2 })
        @(Get-DPDetails -DPName 'B' -StatusRows $rows).V | Should -Be @(2)
        @(Get-DPDetails -DPName 'A' -StatusRows @()).Count | Should -Be 0
    }
}

Describe 'Get-DPHealth' {
    BeforeEach { Mock Write-Log { } -ModuleName $script:Mod }

    It 'keeps the worst status of a server that appears twice and reads the pull flag' {
        Mock Get-CMDistributionPoint { [PSCustomObject]@{ NetworkOSPath = '\\dp01.contoso.com'; SiteCode = 'MCM'; Props = @([PSCustomObject]@{ PropertyName = 'IsPullDP'; Value = 1 }) } } -ModuleName $script:Mod
        Mock Invoke-CMWmiQuery {
            [PSCustomObject]@{ SiteSystem = '["Display=\\DP01.contoso.com\"]MSWNET:["SMS_SITE=MCM"]\\DP01.contoso.com\'; Status = 1 }
            [PSCustomObject]@{ SiteSystem = '["Display=\\DP01.contoso.com\"]MSWNET:["SMS_SITE=MCM"]\\DP01.contoso.com\'; Status = 2 }
            [PSCustomObject]@{ SiteSystem = ''; Status = 2 }
        } -ModuleName $script:Mod
        $r = @(Get-DPHealth)
        $r.Count | Should -Be 1
        $r[0].DPName | Should -Be 'DP01.CONTOSO.COM'
        $r[0].Status | Should -Be 'Critical'
        $r[0].IsPullDP | Should -Be 'Yes'
    }

    It 'reads a plain site system name and marks an unlisted server Unknown' {
        Mock Get-CMDistributionPoint {
            [PSCustomObject]@{ NetworkOSPath = '\\dp02'; SiteCode = 'MCM'; Props = @() }
            [PSCustomObject]@{ NetworkOSPath = '\\dp03'; SiteCode = 'MCM'; Props = @([PSCustomObject]@{ PropertyName = 'IsPullDP'; Value = 0 }) }
        } -ModuleName $script:Mod
        Mock Invoke-CMWmiQuery { [PSCustomObject]@{ SiteSystem = ' dp02 '; Status = 0 } } -ModuleName $script:Mod
        $r = @(Get-DPHealth)
        ($r | Where-Object DPName -eq 'DP02').Status | Should -Be 'OK'
        ($r | Where-Object DPName -eq 'DP03').Status | Should -Be 'Unknown'
        ($r | Where-Object DPName -eq 'DP03').IsPullDP | Should -Be 'No'
    }

    It 'maps status value <Value> to <Text>' -ForEach @(@{ Value = 0; Text = 'OK' }, @{ Value = 1; Text = 'Warning' }, @{ Value = 2; Text = 'Critical' }, @{ Value = 7; Text = 'Unknown' }) {
        $global:Fx = $Value
        Mock Get-CMDistributionPoint { [PSCustomObject]@{ NetworkOSPath = '\\dp02'; SiteCode = 'MCM'; Props = @() } } -ModuleName $script:Mod
        Mock Invoke-CMWmiQuery { [PSCustomObject]@{ SiteSystem = 'dp02'; Status = $global:Fx } } -ModuleName $script:Mod
        @(Get-DPHealth)[0].Status | Should -Be $Text
    }
}

Describe 'SQL reads' {
    BeforeEach { Mock Write-Log { } -ModuleName $script:Mod }

    It 'maps client health and activity values' {
        $global:Fx = @(
            [PSCustomObject]@{ DeviceName = 'A'; LastEvaluationHealthy = 1; ClientActiveStatus = 1; LastActiveTime = $null; ClientStateDescription = 'ok'; ClientVersion = '5.0'; OperatingSystem = 'W11' }
            [PSCustomObject]@{ DeviceName = 'B'; LastEvaluationHealthy = 2; ClientActiveStatus = 0 }
            [PSCustomObject]@{ DeviceName = 'C'; LastEvaluationHealthy = 3; ClientActiveStatus = 5 })
        Mock Invoke-Sqlcmd { $global:Fx } -ModuleName $script:Mod
        $r = @(Get-ClientHealthSummary -SQLServer 'sql01' -SiteCode 'MCM')
        $r.Count | Should -Be 3
        $r[0].HealthState | Should -Be 'Healthy'
        $r[0].ActiveStatus | Should -Be 'Active'
        $r[1].HealthState | Should -Be 'Unhealthy'
        $r[1].ActiveStatus | Should -Be 'Inactive'
        $r[2].HealthState | Should -Be 'Unknown'
        $r[2].ActiveStatus | Should -Be 'Unknown'
        Should -Invoke Invoke-Sqlcmd -ModuleName $script:Mod -Times 1 -Exactly -ParameterFilter { $Database -eq 'CM_MCM' -and $ServerInstance -eq 'sql01' -and $Query -like '*v_CH_ClientSummary*' }
    }

    It 'logs and rethrows when the client query fails' {
        Mock Invoke-Sqlcmd { throw 'login failed' } -ModuleName $script:Mod
        { Get-ClientHealthSummary -SQLServer 'sql01' -SiteCode 'MCM' } | Should -Throw '*login failed*'
        Should -Invoke Write-Log -ModuleName $script:Mod -Times 1 -Exactly -ParameterFilter { $Level -eq 'ERROR' }
    }

    It 'reads inactive devices with the threshold in the query and a null day count for DBNull' {
        $global:Fx = @(
            [PSCustomObject]@{ DeviceName = 'A'; DaysSinceContact = 40 }
            [PSCustomObject]@{ DeviceName = 'B'; DaysSinceContact = [System.DBNull]::Value }
            [PSCustomObject]@{ DeviceName = 'C'; DaysSinceContact = $null })
        Mock Invoke-Sqlcmd { $global:Fx } -ModuleName $script:Mod
        $r = @(Get-InactiveDevices -SQLServer 'sql01' -SiteCode 'MCM' -ThresholdDays 30)
        $r[0].DaysSinceContact | Should -Be 40
        $r[1].DaysSinceContact | Should -BeNullOrEmpty
        $r[2].DaysSinceContact | Should -BeNullOrEmpty
        Should -Invoke Invoke-Sqlcmd -ModuleName $script:Mod -Times 1 -Exactly -ParameterFilter { $Query -like '*> 30*' }
    }

    It 'logs and rethrows when the inactive device query fails' {
        Mock Invoke-Sqlcmd { throw 'timeout' } -ModuleName $script:Mod
        { Get-InactiveDevices -SQLServer 'sql01' -SiteCode 'MCM' } | Should -Throw '*timeout*'
    }

    It 'answers false when the connection test gets no row or an error' {
        Mock Invoke-Sqlcmd { [PSCustomObject]@{ Test = 2 } } -ModuleName $script:Mod
        Test-SQLConnection -SQLServer 'sql01' -SiteCode 'MCM' | Should -BeFalse
        Mock Invoke-Sqlcmd { throw 'unreachable' } -ModuleName $script:Mod
        Test-SQLConnection -SQLServer 'sql01' -SiteCode 'MCM' | Should -BeFalse
    }

    It 'builds the database name from the site code' {
        $p = InModuleScope SiteHygieneLive { New-HygieneSqlParameter -SQLServer 's\i' -SiteCode 'ABC' -Query 'q' }
        $p.Database | Should -Be 'CM_ABC'
        $p.ServerInstance | Should -Be 's\i'
        $p.ErrorAction | Should -Be 'Stop'
    }
}

Describe 'Site health reads' {
    BeforeEach { Mock Write-Log { } -ModuleName $script:Mod }

    It 'maps component status and state values' -ForEach @(
        @{ Status = 0; Text = 'OK'; State = 0; StateText = 'Stopped' }, @{ Status = 1; Text = 'Warning'; State = 1; StateText = 'Started' },
        @{ Status = 2; Text = 'Critical'; State = 2; StateText = 'Paused' }, @{ Status = 9; Text = 'Unknown (9)'; State = 3; StateText = 'Installing' },
        @{ Status = 0; Text = 'OK'; State = 4; StateText = 'Re-installing' }, @{ Status = 0; Text = 'OK'; State = 5; StateText = 'De-installing' },
        @{ Status = 0; Text = 'OK'; State = 8; StateText = 'Unknown (8)' }
    ) {
        $global:Fx = [PSCustomObject]@{ ComponentName = 'C'; MachineName = 'M'; Status = $Status; State = $State; AvailabilityState = 0; LastStarted = $null }
        Mock Invoke-CMWmiQuery { $global:Fx } -ModuleName $script:Mod
        $r = @(Get-SiteComponentHealth)[0]
        $r.Status | Should -Be $Text
        $r.State | Should -Be $StateText
        $r.ItemType | Should -Be 'Component'
    }

    It 'maps site system rows and a plain server name' {
        Mock Invoke-CMWmiQuery {
            [PSCustomObject]@{ SiteSystem = '["Display=\\CM01.contoso.com\"]MSWNET:["SMS_SITE=MCM"]\\CM01.contoso.com\'; SiteCode = 'MCM'; Role = 'SMS Site Server'; Status = 1; AvailabilityState = 0 }
            [PSCustomObject]@{ SiteSystem = 'plain'; SiteCode = 'MCM'; Role = 'SMS Management Point'; Status = 5; AvailabilityState = 1 }
            [PSCustomObject]@{ SiteSystem = ''; SiteCode = 'MCM'; Role = 'SMS Fallback'; Status = 2; AvailabilityState = 0 }
        } -ModuleName $script:Mod
        $r = @(Get-SiteSystemHealth)
        $r[0].ServerName | Should -Be 'CM01.CONTOSO.COM'
        $r[0].Status | Should -Be 'Warning'
        $r[1].ServerName | Should -Be 'PLAIN'
        $r[1].Status | Should -Be 'Unknown (5)'
        $r[2].ServerName | Should -Be ''
        $r[2].ItemType | Should -Be 'Site System'
    }

    It 'logs and rethrows when <Name> fails' -ForEach @(@{ Name = 'Get-SiteComponentHealth' }, @{ Name = 'Get-SiteSystemHealth' }) {
        Mock Invoke-CMWmiQuery { throw 'wmi failed' } -ModuleName $script:Mod
        { & $Name } | Should -Throw '*wmi failed*'
        Should -Invoke Write-Log -ModuleName $script:Mod -Times 1 -Exactly -ParameterFilter { $Level -eq 'ERROR' }
    }
}

Describe 'Metrics history' {
    BeforeEach {
        Mock Write-Log { } -ModuleName $script:Mod
        $script:dir = Join-Path ([IO.Path]::GetTempPath()) ('hyg-{0}' -f [Guid]::NewGuid().ToString('N'))
        $script:hist = Join-Path $script:dir 'nested\metrics-history.csv'
    }
    AfterEach { Remove-Item -LiteralPath $script:dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'creates the folder and the header, and records empty columns for missing counts' {
        Add-MetricsHistoryEntry -HistoryPath $script:hist
        $row = @(Import-Csv -LiteralPath $script:hist)
        $row.Count | Should -Be 1
        $row[0].DeploymentTotal | Should -Be ''
        $row[0].SiteCritical | Should -Be ''
        ($row[0].Timestamp -as [datetime]) | Should -Not -BeNullOrEmpty
    }

    It 'appends one row per call under one header' {
        $counts = [PSCustomObject]@{ TotalDeployments = 4; FailedDeployments = 1; OverallCompliance = 82.5 }
        Add-MetricsHistoryEntry -HistoryPath $script:hist -DeploymentCounts $counts
        Add-MetricsHistoryEntry -HistoryPath $script:hist -DeploymentCounts $counts -DPCounts ([PSCustomObject]@{ TotalDPs = 3; OfflineCount = 1; DegradedCount = 0 })
        $rows = @(Import-Csv -LiteralPath $script:hist)
        $rows.Count | Should -Be 2
        @(Get-Content -LiteralPath $script:hist | Where-Object { $_ -like '"Timestamp"*' }).Count | Should -Be 1
        $rows[1].DPOffline | Should -Be '1'
        $rows[1].CompliancePct | Should -Be '82.5'
    }

    It 'drops rows older than 180 days when it writes' {
        New-Item -ItemType Directory -Path (Split-Path $script:hist -Parent) -Force | Out-Null
        $old = (Get-Date).AddDays(-200).ToString('o')
        $fresh = (Get-Date).AddDays(-2).ToString('o')
        Add-MetricsHistoryEntry -HistoryPath $script:hist
        $lines = @(Get-Content -LiteralPath $script:hist)
        $cols = ($lines[1] -split ',').Count
        $blank = ('""' + (',""' * ($cols - 1)))
        Add-Content -LiteralPath $script:hist -Value ('"{0}"{1}' -f $old, $blank.Substring(2))
        Add-Content -LiteralPath $script:hist -Value ('"{0}"{1}' -f $fresh, $blank.Substring(2))
        Add-MetricsHistoryEntry -HistoryPath $script:hist
        $rows = @(Import-Csv -LiteralPath $script:hist)
        @($rows | Where-Object { ([datetime]$_.Timestamp) -lt (Get-Date).AddDays(-180) }).Count | Should -Be 0
        $rows.Count | Should -Be 3
    }

    It 'does not throw when the history path cannot be written' {
        { Add-MetricsHistoryEntry -HistoryPath (Join-Path $script:dir "bad`0name.csv") } | Should -Not -Throw
        Should -Invoke Write-Log -ModuleName $script:Mod -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' }
    }

    It 'returns rows inside the day range, oldest first, and an empty list for a missing file' {
        @(Get-MetricsHistory -HistoryPath $script:hist).Count | Should -Be 0
        New-Item -ItemType Directory -Path (Split-Path $script:hist -Parent) -Force | Out-Null
        Set-Content -LiteralPath $script:hist -Encoding UTF8 -Value @(
            '"Timestamp","CompliancePct"'
            ('"{0}","3"' -f (Get-Date).AddDays(-1).ToString('o'))
            ('"{0}","1"' -f (Get-Date).AddDays(-5).ToString('o'))
            ('"{0}","9"' -f (Get-Date).AddDays(-60).ToString('o'))
            '"not a date","7"')
        @(Get-MetricsHistory -HistoryPath $script:hist -Days 30).CompliancePct | Should -Be @('1', '3')
        @(Get-MetricsSeries -HistoryPath $script:hist -Column 'CompliancePct' -Days 90).V | Should -Be @(9, 1, 3)
        @(Get-MetricsSeries -HistoryPath $script:hist -Column 'NoSuchColumn').Count | Should -Be 0
    }
}

Describe 'Table exports' {
    BeforeEach {
        Mock Write-Log { } -ModuleName $script:Mod
        $script:dir = Join-Path ([IO.Path]::GetTempPath()) ('hyg-{0}' -f [Guid]::NewGuid().ToString('N'))
    }
    AfterEach { Remove-Item -LiteralPath $script:dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'writes a CSV with the column names and creates the folder' {
        $dt = New-Table -Columns 'Name', 'Count' -Rows @(@('PC1', '3'), @('He said "hi", twice', '4'))
        $out = Join-Path $script:dir 'sub\t.csv'
        Export-HygieneTableCsv -DataTable $dt -OutputPath $out
        $rows = @(Import-Csv -LiteralPath $out)
        $rows.Count | Should -Be 2
        $rows[1].Name | Should -Be 'He said "hi", twice'
    }

    It 'writes a header-only CSV for an empty table without failing' {
        $dt = New-Table -Columns 'Name' -Rows @()
        $out = Join-Path $script:dir 't.csv'
        { Export-HygieneTableCsv -DataTable $dt -OutputPath $out } | Should -Not -Throw
    }

    It 'marks failures with a glyph and bold, and good values with a check mark' {
        $dt = New-Table -Columns 'Name', 'FailedCount', 'InProgressCount', 'Status' -Rows @(@('A', '2', '1', 'OK'), @('B', '0', '0', 'Critical'), @('C', '0', '0', 'Warning'))
        $out = Join-Path $script:dir 'h.html'
        Export-HygieneTableHtml -DataTable $dt -OutputPath $out -ReportTitle 'Report'
        $html = [System.IO.File]::ReadAllText($out)
        $html | Should -Match ('<td class="attn"><span class="glyph">{0}</span>2</td>' -f [char]0x2717)
        $html | Should -Match ('<td class="attn"><span class="glyph">{0}</span>1</td>' -f [char]0x26A0)
        $html | Should -Match ('<td><span class="glyph">{0}</span>OK</td>' -f [char]0x2713)
        $html | Should -Match ('<td class="attn"><span class="glyph">{0}</span>Critical</td>' -f [char]0x2717)
        $html | Should -Match ('<td class="attn"><span class="glyph">{0}</span>Warning</td>' -f [char]0x26A0)
        $html | Should -Match 'Rows: 3'
    }

    It 'encodes markup in a value, a column name and the title' {
        $dt = New-Table -Columns 'Name<b>' -Rows @(, @('<script>alert(1)</script> & "q"'))
        $out = Join-Path $script:dir 'e.html'
        Export-HygieneTableHtml -DataTable $dt -OutputPath $out -ReportTitle 'Title <i>x</i> & y'
        $html = [System.IO.File]::ReadAllText($out)
        $html | Should -Not -Match '<script>'
        $html | Should -Not -Match '<th>Name<b></th>'
        $html | Should -Not -Match '<h1>Title <i>'
        $html | Should -Match '&lt;script&gt;alert\(1\)&lt;/script&gt; &amp; (&quot;|")q(&quot;|")'
        $html | Should -Match '<th>Name&lt;b&gt;</th>'
        $html | Should -Match '<title>\s*Title &lt;i&gt;x&lt;/i&gt; &amp; y\s*</title>'
    }

    It 'writes the report as UTF-8 that keeps non-ASCII text' {
        $dt = New-Table -Columns 'Name' -Rows @(, @("Caf$([char]0xE9) $([char]0x2603)"))
        $out = Join-Path $script:dir 'u.html'
        Export-HygieneTableHtml -DataTable $dt -OutputPath $out
        $shown = [System.Net.WebUtility]::HtmlDecode([System.IO.File]::ReadAllText($out, [System.Text.Encoding]::UTF8))
        $shown | Should -BeLike "*Caf$([char]0xE9) $([char]0x2603)*"
    }
}

Describe 'New-HygieneLiveSummaryText' {
    It 'writes one line per area from the counts' {
        $text = New-HygieneLiveSummaryText `
            -DeploymentCounts ([PSCustomObject]@{ TotalDeployments = 5; FailedDeployments = 1; OverallCompliance = 91.5 }) `
            -ContentCounts ([PSCustomObject]@{ TotalContentWithIssues = 2; TotalFailedPairs = 3 }) `
            -DPCounts ([PSCustomObject]@{ TotalDPs = 4; OfflineCount = 1; DegradedCount = 2 }) `
            -ClientCounts ([PSCustomObject]@{ HealthyCount = 90; UnhealthyCount = 5; InactiveCount = 7 }) `
            -InactiveCounts ([PSCustomObject]@{ InactiveCount = 8 }) `
            -SiteCounts ([PSCustomObject]@{ OKCount = 20; WarningCount = 1; CriticalCount = 0 })
        $text | Should -BeLike '*Deployments:  5 total, 1 with errors (91.5% compliant)*'
        $text | Should -BeLike '*Content:      2 items with issues, 3 failed DP-content pairs*'
        $text | Should -BeLike '*DPs:          4 total, 1 offline, 2 degraded*'
        $text | Should -BeLike '*Clients:      90 healthy, 5 unhealthy, 7 inactive*'
        $text | Should -BeLike '*Devices:      8 inactive*'
        $text | Should -BeLike '*Site Health:  20 OK, 1 warning, 0 critical*'
    }

    It 'does not fail when the counts are missing' {
        { New-HygieneLiveSummaryText } | Should -Not -Throw
    }
}

Describe 'Import-HygieneLegacyDashboardState' {
    BeforeEach {
        Mock Write-Log { } -ModuleName $script:Mod
        $script:dir = Join-Path ([IO.Path]::GetTempPath()) ('hyg-{0}' -f [Guid]::NewGuid().ToString('N'))
        $script:legacy = Join-Path $script:dir 'legacy'
        New-Item -ItemType Directory -Path (Join-Path $script:legacy 'History') -Force | Out-Null
        $script:prefs = Join-Path $script:dir 'prefs.json'
        $script:hist = Join-Path $script:dir 'History\metrics-history.csv'
    }
    AfterEach { Remove-Item -LiteralPath $script:dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'imports only the settings that the preferences do not hold and leaves the legacy files alone' {
        Set-Content -LiteralPath (Join-Path $script:legacy 'MECMHealthDash.prefs.json') -Encoding UTF8 -Value '{"SQLServer":"old-sql","AutoRefreshMinutes":5,"AlertsEnabled":false,"Other":"x"}'
        Set-Content -LiteralPath $script:prefs -Encoding UTF8 -Value '{"AutoRefreshMinutes":30}'
        $r = Import-HygieneLegacyDashboardState -LegacyRoot $script:legacy -PrefsPath $script:prefs -HistoryPath $script:hist
        $r.ImportedKeys | Should -Be @('SQLServer', 'AlertsEnabled')
        $doc = Get-Content -LiteralPath $script:prefs -Raw -Encoding UTF8 | ConvertFrom-Json
        $doc.AutoRefreshMinutes | Should -Be 30
        $doc.SQLServer | Should -Be 'old-sql'
        $doc.PSObject.Properties['Other'] | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $script:legacy 'MECMHealthDash.prefs.json') | Should -BeTrue
        $again = Import-HygieneLegacyDashboardState -LegacyRoot $script:legacy -PrefsPath $script:prefs -HistoryPath $script:hist
        $again.ImportedKeys.Count | Should -Be 0
    }

    It 'copies the history once and never over an existing file' {
        Set-Content -LiteralPath (Join-Path $script:legacy 'History\metrics-history.csv') -Value 'legacy'
        (Import-HygieneLegacyDashboardState -LegacyRoot $script:legacy -PrefsPath $script:prefs -HistoryPath $script:hist).HistoryCopied | Should -BeTrue
        Set-Content -LiteralPath $script:hist -Value 'mine'
        (Import-HygieneLegacyDashboardState -LegacyRoot $script:legacy -PrefsPath $script:prefs -HistoryPath $script:hist).HistoryCopied | Should -BeFalse
        (Get-Content -LiteralPath $script:hist) | Should -Be 'mine'
    }

    It 'warns and imports nothing from a damaged legacy preferences file' {
        Set-Content -LiteralPath (Join-Path $script:legacy 'MECMHealthDash.prefs.json') -Value '{not json'
        $r = Import-HygieneLegacyDashboardState -LegacyRoot $script:legacy -PrefsPath $script:prefs -HistoryPath $script:hist
        $r.ImportedKeys.Count | Should -Be 0
        Should -Invoke Write-Log -ModuleName $script:Mod -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' }
    }

    It 'returns nothing imported for an empty legacy folder' {
        $r = Import-HygieneLegacyDashboardState -LegacyRoot $script:legacy -PrefsPath $script:prefs -HistoryPath $script:hist
        $r.ImportedKeys.Count | Should -Be 0
        $r.HistoryCopied | Should -BeFalse
    }
}
