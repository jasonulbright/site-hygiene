#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for the SiteHygieneCommon check engine.

.DESCRIPTION
    Every check is pure over a prefetched data object, so the whole engine
    is covered with synthetic data. No Configuration Manager site, CIM, or elevation required.

.EXAMPLE
    Invoke-Pester .\SiteHygieneCommon.Tests.ps1
#>

BeforeAll {
    Import-Module "$PSScriptRoot\..\Module\SiteHygieneCommon.psd1" -Force -DisableNameChecking

    function New-HygAppXml {
        param(
            [string]$DTTitle = 'Install',
            [string[]]$SupersedesModels = @(),
            [object[]]$Dependencies = @(),
            [string[]]$ContentLocations = @()
        )
        $d = 'http://schemas.microsoft.com/SystemCenterConfigurationManager/2009/AppMgmtDigest'
        $r = 'https://schemas.microsoft.com/SystemsCenterConfigurationManager/2009/06/14/Rules'
        $sup = foreach ($m in $SupersedesModels) {
            $scope, $logical = $m -split '/', 2
            "<DeploymentTypeRule xmlns='$r'><DeploymentTypeIntentExpression><DeploymentTypeApplicationReference AuthoringScopeId='$scope' LogicalName='$logical'/></DeploymentTypeIntentExpression></DeploymentTypeRule>"
        }
        $dep = foreach ($x in $Dependencies) {
            $scope, $logical = $x.Model -split '/', 2
            $state = if ($x.State) { " DesiredState='$($x.State)'" } else { '' }
            "<DeploymentTypeRule xmlns='$r'><DeploymentTypeIntentExpression$state><DeploymentTypeApplicationReference AuthoringScopeId='$scope' LogicalName='$logical'/></DeploymentTypeIntentExpression></DeploymentTypeRule>"
        }
        $content = foreach ($c in $ContentLocations) { "<Content><Location>$c</Location></Content>" }
        return "<AppMgmtDigest xmlns='$d'><DeploymentType AuthoringScopeId='ScopeId_T' LogicalName='DeploymentType_X'><Title>$DTTitle</Title><Installer><Contents>$($content -join '')</Contents></Installer><Supersedes>$($sup -join '')</Supersedes><Dependencies>$($dep -join '')</Dependencies></DeploymentType></AppMgmtDigest>"
    }

    function New-HygRelApp {
        param(
            [int]$CI_ID,
            [string]$Name,
            [string]$Model,
            [string]$Xml = '',
            [bool]$IsSuperseding = $false,
            [bool]$IsEnabled = $true,
            [bool]$IsExpired = $false,
            [bool]$HasContent = $true,
            [string]$Manufacturer = 'Vendor'
        )
        [pscustomobject]@{
            CI_ID = $CI_ID; ModelName = $Model; Name = $Name; SoftwareVersion = '1.0'
            Manufacturer = $Manufacturer; IsEnabled = $IsEnabled; IsExpired = $IsExpired
            IsSuperseded = $false; IsSuperseding = $IsSuperseding; HasContent = $HasContent
            NumberOfDeploymentTypes = $(if ($Xml) { 1 } else { 0 }); SDMPackageXML = $Xml
        }
    }

    function New-HygRelData {
        param([object[]]$Apps)
        $parsed = ConvertTo-HygRelationships -Applications $Apps
        $lookup = @{}
        foreach ($a in $Apps) { $lookup[[int]$a.CI_ID] = $a }
        [pscustomobject]@{
            Apps = $lookup; Relationships = $parsed.Relationships
            ContentLocations = $parsed.ContentLocations; DatasetNotes = $parsed.ParseNotes
        }
    }

    function New-HygData {
        param(
            [object[]]$Applications = @(),
            [object[]]$Packages = @(),
            [object[]]$Programs = @(),
            [object[]]$TaskSequences = @(),
            [object[]]$Collections = @(),
            [object[]]$Deployments = @(),
            [object[]]$AppDeployments = @(),
            [string[]]$CollectionsWithSettings = @(),
            [int[]]$DependencyTargetCIIDs = @(),
            [object[]]$CollectionDependencies = @(),
            [object[]]$Devices = @(),
            [object[]]$Boundaries = @(),
            [object[]]$BoundaryGroups = @(),
            [object[]]$BootImages = @(),
            [object[]]$OSImages = @(),
            [object[]]$OSUpgradePackages = @(),
            [object[]]$DriverPackages = @(),
            [object[]]$UpdateGroups = @(),
            [object[]]$UpdatePackages = @(),
            [object[]]$AutoDeploymentRules = @(),
            [object[]]$MaintenanceTasks = @(),
            [string[]]$DatasetNotes = @(),
            [string[]]$FailedDatasets = @()
        )
        [pscustomobject]@{
            Applications            = $Applications
            Packages                = $Packages
            Programs                = $Programs
            TaskSequences           = $TaskSequences
            Collections             = $Collections
            Deployments             = $Deployments
            AppDeployments          = $AppDeployments
            CollectionsWithSettings = $CollectionsWithSettings
            DependencyTargetCIIDs   = $DependencyTargetCIIDs
            CollectionDependencies  = $CollectionDependencies
            Devices                 = $Devices
            Boundaries              = $Boundaries
            BoundaryGroups          = $BoundaryGroups
            BootImages              = $BootImages
            OSImages                = $OSImages
            OSUpgradePackages       = $OSUpgradePackages
            DriverPackages          = $DriverPackages
            UpdateGroups            = $UpdateGroups
            UpdatePackages          = $UpdatePackages
            AutoDeploymentRules     = $AutoDeploymentRules
            MaintenanceTasks        = $MaintenanceTasks
            DatasetNotes            = $DatasetNotes
            FailedDatasets          = $FailedDatasets
            CollectedAt             = Get-Date
        }
    }

    function New-HygDevice {
        param(
            [int]$ResourceID = 100,
            [string]$Name = 'PC01',
            [bool]$IsClient = $true,
            [string]$ClientVersion = '5.00.9135.1000',
            $LastActiveTime = (Get-Date).AddDays(-1),
            [string]$SMBIOSGUID = ''
        )
        [pscustomobject]@{
            ResourceID = $ResourceID; Name = $Name; IsClient = $IsClient
            ClientVersion = $ClientVersion; LastActiveTime = $LastActiveTime
            SMBIOSGUID = $SMBIOSGUID
        }
    }

    function New-HygApp {
        param(
            [int]$CI_ID = 100,
            [string]$Name = 'App',
            [string]$ModelName = 'ScopeId_X/Application_Y',
            [string]$PackageID = 'MCM0010A',
            [bool]$IsDeployed = $false,
            [bool]$IsExpired = $false,
            [bool]$IsSuperseded = $false,
            [bool]$IsSuperseding = $false,
            [datetime]$DateCreated = (Get-Date).AddDays(-365)
        )
        [pscustomobject]@{
            CI_ID = $CI_ID; ModelName = $ModelName; Name = $Name
            IsDeployed = $IsDeployed; IsExpired = $IsExpired
            IsSuperseded = $IsSuperseded; IsSuperseding = $IsSuperseding
            PackageID = $PackageID; DateCreated = $DateCreated
        }
    }

    function New-HygCollection {
        param(
            [string]$CollectionID = 'MCM00001',
            [string]$Name = 'Collection',
            [int]$MemberCount = 0,
            [int]$RefreshType = 2,
            [string]$LimitToCollectionID = 'SMS00001',
            [string[]]$IncludeIDs = @(),
            [string[]]$ExcludeIDs = @(),
            [int]$DirectRuleCount = 0,
            [int]$QueryRuleCount = 0,
            [int]$FullDaySpan = 0,
            [int]$FullHourSpan = 0,
            [int]$FullMinuteSpan = 0,
            [int]$FullStartHour = -1
        )
        [pscustomobject]@{
            CollectionID = $CollectionID; Name = $Name; MemberCount = $MemberCount
            RefreshType = $RefreshType; LimitToCollectionID = $LimitToCollectionID
            IsBuiltIn = ($CollectionID -like 'SMS*')
            IncludeIDs = $IncludeIDs; ExcludeIDs = $ExcludeIDs
            DirectRuleCount = $DirectRuleCount; QueryRuleCount = $QueryRuleCount
            FullDaySpan = $FullDaySpan; FullHourSpan = $FullHourSpan
            FullMinuteSpan = $FullMinuteSpan; FullStartHour = $FullStartHour
        }
    }

    function New-HygDeployment {
        param(
            [string]$SoftwareName = 'App',
            [string]$PackageID = '',
            [string]$CollectionID = 'MCM00001',
            [string]$CollectionName = 'Collection',
            [int]$DeploymentIntent = 1,
            [int]$FeatureType = 1,
            [int]$NumberTargeted = 0,
            [int]$NumberSuccess = 0,
            [int]$NumberInProgress = 0,
            [int]$NumberErrors = 0,
            $EnforcementDeadline = $null,
            $CreationTime = $null
        )
        [pscustomobject]@{
            SoftwareName = $SoftwareName; PackageID = $PackageID
            CollectionID = $CollectionID; CollectionName = $CollectionName
            DeploymentIntent = $DeploymentIntent; FeatureType = $FeatureType
            NumberTargeted = $NumberTargeted; NumberSuccess = $NumberSuccess
            NumberInProgress = $NumberInProgress; NumberErrors = $NumberErrors
            EnforcementDeadline = $EnforcementDeadline; CreationTime = $CreationTime
        }
    }
}

# ============================================================================
# APP checks
# ============================================================================

Describe 'Test-HygAppNoReferences (APP-01)' {
    It 'flags an old app with no deployments and no references' {
        $data = New-HygData -Applications @(New-HygApp -Name 'Orphan App')
        $f = @(Test-HygAppNoReferences -Data $data)
        $f.Count | Should -Be 1
        $f[0].CheckId | Should -Be 'APP-01'
        $f[0].ObjectName | Should -Be 'Orphan App'
    }

    It 'skips deployed, superseding, superseded, and young apps' {
        $data = New-HygData -Applications @(
            (New-HygApp -CI_ID 1 -Name 'Deployed' -IsDeployed $true),
            (New-HygApp -CI_ID 2 -Name 'Superseding' -IsSuperseding $true),
            (New-HygApp -CI_ID 3 -Name 'Superseded' -IsSuperseded $true),
            (New-HygApp -CI_ID 4 -Name 'Fresh' -DateCreated (Get-Date).AddDays(-3))
        )
        @(Test-HygAppNoReferences -Data $data).Count | Should -Be 0
    }

    It 'skips an app referenced by a task sequence via PackageID' {
        $data = New-HygData `
            -Applications @(New-HygApp -Name 'TS Ref' -PackageID 'MCM00TS1') `
            -TaskSequences @([pscustomobject]@{ PackageID = 'MCM000TS'; Name = 'Build'; ReferencedIDs = @('MCM00TS1') })
        @(Test-HygAppNoReferences -Data $data).Count | Should -Be 0
    }

    It 'skips an app referenced by a task sequence via ModelName' {
        $data = New-HygData `
            -Applications @(New-HygApp -Name 'Model Ref' -ModelName 'ScopeId_A/Application_B' -PackageID '') `
            -TaskSequences @([pscustomobject]@{ PackageID = 'MCM000TS'; Name = 'Build'; ReferencedIDs = @('ScopeId_A/Application_B') })
        @(Test-HygAppNoReferences -Data $data).Count | Should -Be 0
    }

    It 'skips a dependency target' {
        $data = New-HygData `
            -Applications @(New-HygApp -CI_ID 555 -Name 'Runtime dependency') `
            -DependencyTargetCIIDs @(555)
        @(Test-HygAppNoReferences -Data $data).Count | Should -Be 0
    }

    It 'honors the AppUnusedMinAgeDays threshold' {
        $data = New-HygData -Applications @(New-HygApp -Name 'Two weeks old' -DateCreated (Get-Date).AddDays(-14))
        @(Test-HygAppNoReferences -Data $data -Thresholds @{ AppUnusedMinAgeDays = 7 }).Count | Should -Be 1
        @(Test-HygAppNoReferences -Data $data -Thresholds @{ AppUnusedMinAgeDays = 30 }).Count | Should -Be 0
    }
}

Describe 'Test-HygAppRetiredDeployed (APP-02)' {
    It 'flags retired apps that still have deployments as Error' {
        $data = New-HygData -Applications @(New-HygApp -Name 'Zombie' -IsExpired $true -IsDeployed $true)
        $f = @(Test-HygAppRetiredDeployed -Data $data)
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Error'
    }

    It 'ignores retired-but-undeployed and active-deployed apps' {
        $data = New-HygData -Applications @(
            (New-HygApp -CI_ID 1 -IsExpired $true),
            (New-HygApp -CI_ID 2 -IsDeployed $true)
        )
        @(Test-HygAppRetiredDeployed -Data $data).Count | Should -Be 0
    }
}

Describe 'Test-HygAppSupersededDeployed (APP-03)' {
    It 'flags superseded apps still deployed' {
        $data = New-HygData -Applications @(New-HygApp -Name 'Old version' -IsSuperseded $true -IsDeployed $true)
        $f = @(Test-HygAppSupersededDeployed -Data $data)
        $f.Count | Should -Be 1
        $f[0].CheckId | Should -Be 'APP-03'
    }

    It 'leaves the retired case to APP-02' {
        $data = New-HygData -Applications @(New-HygApp -IsSuperseded $true -IsDeployed $true -IsExpired $true)
        @(Test-HygAppSupersededDeployed -Data $data).Count | Should -Be 0
    }
}

# ============================================================================
# PKG-01
# ============================================================================

Describe 'Test-HygPackageUnused (PKG-01)' {
    It 'flags a package with no programs, deployments, or TS references' {
        $data = New-HygData -Packages @([pscustomobject]@{ PackageID = 'MCM00PKG'; Name = 'Dead Package' })
        $f = @(Test-HygPackageUnused -Data $data)
        $f.Count | Should -Be 1
        $f[0].ObjectId | Should -Be 'MCM00PKG'
    }

    It 'skips packages with a program, a deployment, or a TS reference' {
        $data = New-HygData `
            -Packages @(
                [pscustomobject]@{ PackageID = 'MCM00P01'; Name = 'Has program' },
                [pscustomobject]@{ PackageID = 'MCM00P02'; Name = 'Has deployment' },
                [pscustomobject]@{ PackageID = 'MCM00P03'; Name = 'In TS' }
            ) `
            -Programs @([pscustomobject]@{ PackageID = 'MCM00P01'; ProgramName = 'Install' }) `
            -Deployments @(New-HygDeployment -PackageID 'MCM00P02') `
            -TaskSequences @([pscustomobject]@{ PackageID = 'MCM000TS'; Name = 'Build'; ReferencedIDs = @('MCM00P03') })
        @(Test-HygPackageUnused -Data $data).Count | Should -Be 0
    }

    It 'carves out default Configuration Manager Client packages' {
        $data = New-HygData -Packages @([pscustomobject]@{ PackageID = 'MCM00001'; Name = 'Configuration Manager Client Package' })
        @(Test-HygPackageUnused -Data $data).Count | Should -Be 0
    }
}

# ============================================================================
# COL checks
# ============================================================================

Describe 'Test-HygCollectionEmptyUnused (COL-01)' {
    It 'flags an empty, unreferenced, settings-free custom collection' {
        $data = New-HygData -Collections @(New-HygCollection -Name 'Dead Collection')
        $f = @(Test-HygCollectionEmptyUnused -Data $data)
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Info'
    }

    It 'skips built-ins, non-empty, deployment targets, include/exclude/limiting references, and settings holders' {
        $c = @(
            (New-HygCollection -CollectionID 'SMS00001' -Name 'Built-in'),
            (New-HygCollection -CollectionID 'MCM00002' -Name 'Has members' -MemberCount 5),
            (New-HygCollection -CollectionID 'MCM00003' -Name 'Deployment target'),
            (New-HygCollection -CollectionID 'MCM00004' -Name 'Included elsewhere'),
            (New-HygCollection -CollectionID 'MCM00005' -Name 'Excluded elsewhere'),
            (New-HygCollection -CollectionID 'MCM00006' -Name 'Limits another'),
            (New-HygCollection -CollectionID 'MCM00007' -Name 'Has variables'),
            (New-HygCollection -CollectionID 'MCM00008' -Name 'Referencer' -MemberCount 1 -IncludeIDs @('MCM00004') -ExcludeIDs @('MCM00005') -LimitToCollectionID 'MCM00006')
        )
        $data = New-HygData -Collections $c `
            -Deployments @(New-HygDeployment -CollectionID 'MCM00003') `
            -CollectionsWithSettings @('MCM00007')
        @(Test-HygCollectionEmptyUnused -Data $data).Count | Should -Be 0
    }
}

Describe 'Test-HygDeploymentEmptyCollection (COL-02)' {
    It 'flags a deployment aimed at an empty collection' {
        $data = New-HygData `
            -Collections @(New-HygCollection -CollectionID 'MCM00009' -Name 'Empty target') `
            -Deployments @(New-HygDeployment -SoftwareName 'App X' -CollectionID 'MCM00009' -CollectionName 'Empty target')
        $f = @(Test-HygDeploymentEmptyCollection -Data $data)
        $f.Count | Should -Be 1
        $f[0].CheckId | Should -Be 'COL-02'
    }

    It 'ignores deployments to populated collections' {
        $data = New-HygData `
            -Collections @(New-HygCollection -CollectionID 'MCM00010' -MemberCount 12) `
            -Deployments @(New-HygDeployment -CollectionID 'MCM00010')
        @(Test-HygDeploymentEmptyCollection -Data $data).Count | Should -Be 0
    }
}

Describe 'Test-HygIncrementalCeiling (COL-03)' {
    It 'stays silent at or under the ceiling and fires over it' {
        $under = New-HygData -Collections @(1..3 | ForEach-Object { New-HygCollection -CollectionID "MCM0000$_" -RefreshType 4 })
        @(Test-HygIncrementalCeiling -Data $under -Thresholds @{ IncrementalCeiling = 3 }).Count | Should -Be 0

        $over = New-HygData -Collections @(1..5 | ForEach-Object { New-HygCollection -CollectionID "MCM0000$_" -RefreshType 6 })
        $f = @(Test-HygIncrementalCeiling -Data $over -Thresholds @{ IncrementalCeiling = 3 })
        $f.Count | Should -Be 1
        $f[0].Evidence | Should -Match '5 collections'
    }
}

# ============================================================================
# DPL checks
# ============================================================================

Describe 'Test-HygDeploymentExpired (DPL-01)' {
    It 'flags an app deployment whose expiration has passed' {
        $data = New-HygData -AppDeployments @([pscustomobject]@{
            ApplicationName = 'App'; CollectionName = 'Coll'; TargetCollectionID = 'MCM00001'
            ExpirationTimeEnabled = $true; ExpirationTime = (Get-Date).AddDays(-2)
        })
        $f = @(Test-HygDeploymentExpired -Data $data)
        $f.Count | Should -Be 1
        $f[0].CheckId | Should -Be 'DPL-01'
    }

    It 'ignores future expirations and deployments without one' {
        $data = New-HygData -AppDeployments @(
            [pscustomobject]@{ ApplicationName = 'A'; CollectionName = 'C'; TargetCollectionID = 'X'; ExpirationTimeEnabled = $true;  ExpirationTime = (Get-Date).AddDays(2) },
            [pscustomobject]@{ ApplicationName = 'B'; CollectionName = 'C'; TargetCollectionID = 'X'; ExpirationTimeEnabled = $false; ExpirationTime = $null }
        )
        @(Test-HygDeploymentExpired -Data $data).Count | Should -Be 0
    }
}

Describe 'Test-HygDeploymentPastDeadlineFailures (DPL-02)' {
    It 'flags a required deployment past deadline over the failure threshold' {
        $data = New-HygData -Deployments @(New-HygDeployment -SoftwareName 'Broken App' `
            -NumberTargeted 100 -NumberErrors 30 -EnforcementDeadline (Get-Date).AddDays(-30))
        $f = @(Test-HygDeploymentPastDeadlineFailures -Data $data)
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Error'
        $f[0].Evidence | Should -Match '30 of 100'
    }

    It 'respects intent, grace window, and failure percentage' {
        $data = New-HygData -Deployments @(
            (New-HygDeployment -DeploymentIntent 2 -NumberTargeted 100 -NumberErrors 90 -EnforcementDeadline (Get-Date).AddDays(-30)),
            (New-HygDeployment -NumberTargeted 100 -NumberErrors 90 -EnforcementDeadline (Get-Date).AddDays(-2)),
            (New-HygDeployment -NumberTargeted 100 -NumberErrors 5  -EnforcementDeadline (Get-Date).AddDays(-30))
        )
        @(Test-HygDeploymentPastDeadlineFailures -Data $data -Thresholds @{ DeadlineGraceDays = 7; FailurePctThreshold = 20 }).Count | Should -Be 0
    }
}

Describe 'Test-HygDeploymentAvailableUnused (DPL-03)' {
    It 'flags an old available deployment with zero takers' {
        $data = New-HygData -Deployments @(New-HygDeployment -DeploymentIntent 2 `
            -NumberTargeted 50 -CreationTime (Get-Date).AddDays(-90))
        $f = @(Test-HygDeploymentAvailableUnused -Data $data)
        $f.Count | Should -Be 1
        $f[0].CheckId | Should -Be 'DPL-03'
    }

    It 'ignores young, adopted, or untargeted available deployments' {
        $data = New-HygData -Deployments @(
            (New-HygDeployment -DeploymentIntent 2 -NumberTargeted 50 -CreationTime (Get-Date).AddDays(-2)),
            (New-HygDeployment -DeploymentIntent 2 -NumberTargeted 50 -NumberSuccess 1 -CreationTime (Get-Date).AddDays(-90)),
            (New-HygDeployment -DeploymentIntent 2 -NumberTargeted 0  -CreationTime (Get-Date).AddDays(-90))
        )
        @(Test-HygDeploymentAvailableUnused -Data $data).Count | Should -Be 0
    }
}

# ============================================================================
# Orchestration + summary + export
# ============================================================================

Describe 'Invoke-HygieneScan' {
    It 'aggregates findings across checks sorted by severity' {
        $data = New-HygData `
            -Applications @(
                (New-HygApp -CI_ID 1 -Name 'Orphan'),
                (New-HygApp -CI_ID 2 -Name 'Zombie' -IsExpired $true -IsDeployed $true)
            ) `
            -Collections @(New-HygCollection -Name 'Dead Collection')
        $f = @(Invoke-HygieneScan -Data $data)
        $f.Count | Should -Be 3
        $f[0].Severity | Should -Be 'Error'
        $f[-1].Severity | Should -Be 'Info'
    }

    It 'returns an empty result for a clean site' {
        $data = New-HygData
        @(Invoke-HygieneScan -Data $data).Count | Should -Be 0
    }
}

Describe 'Get-HygieneScanSummary' {
    It 'returns a row per catalog check with counts' {
        $data = New-HygData -Applications @(New-HygApp -Name 'Zombie' -IsExpired $true -IsDeployed $true)
        $findings = @(Invoke-HygieneScan -Data $data)
        $summary = @(Get-HygieneScanSummary -Findings $findings)
        $summary.Count | Should -Be (@(Get-HygieneCheckCatalog).Count)
        ($summary | Where-Object { $_.CheckId -eq 'APP-02' }).Findings | Should -Be 1
        ($summary | Where-Object { $_.CheckId -eq 'COL-01' }).Findings | Should -Be 0
    }
}

Describe 'Export-HygieneCsv / Export-HygieneHtml / New-HygieneSummaryText' {
    BeforeAll {
        $script:sampleFindings = @(
            New-HygieneFinding -CheckId 'APP-02' -Severity Error -Category 'Applications' `
                -ObjectType 'Application' -ObjectId '42' -ObjectName "O'Brien <App>" `
                -Evidence 'Retired but deployed.' -Recommendation 'Remove deployments.' `
                -FixScript "Get-CMApplicationDeployment -Name 'O''Brien <App>' | Remove-CMApplicationDeployment -Force"
        )
    }

    It 'writes a CSV with every finding column' {
        $p = Join-Path $TestDrive 'f.csv'
        Export-HygieneCsv -Findings $script:sampleFindings -OutputPath $p
        $rows = @(Import-Csv -LiteralPath $p)
        $rows.Count | Should -Be 1
        $rows[0].CheckId | Should -Be 'APP-02'
        $rows[0].FixScript | Should -Match 'Remove-CMApplicationDeployment'
    }

    It 'writes HTML with severity class and HTML-encoded object names' {
        $p = Join-Path $TestDrive 'f.html'
        Export-HygieneHtml -Findings $script:sampleFindings -OutputPath $p -ReportTitle 'Hygiene Test'
        $content = Get-Content -LiteralPath $p -Raw
        $content | Should -Match 'sev-Error'
        $content | Should -Match 'O&#39;Brien &lt;App&gt;'
        $content | Should -Not -Match '<App>'
    }

    It 'summary text counts severities and carries dataset notes' {
        $text = New-HygieneSummaryText -Findings $script:sampleFindings -DatasetNotes @('Dependency relations unavailable')
        $text | Should -Match 'Total findings: 1'
        $text | Should -Match 'Error: 1'
        $text | Should -Match 'Dependency relations unavailable'
    }
}

# ============================================================================
# Relationships (absorbed from the supersedence-auditor tool)
# ============================================================================

Describe 'ConvertTo-HygRelationships' {
    It 'resolves a supersedence to an existing app' {
        $apps = @(
            (New-HygRelApp -CI_ID 1 -Name 'New App' -Model 'ScopeId_T/Application_A' -IsSuperseding $true -Xml (New-HygAppXml -SupersedesModels @('ScopeId_T/Application_B'))),
            (New-HygRelApp -CI_ID 2 -Name 'Old App' -Model 'ScopeId_T/Application_B')
        )
        $p = ConvertTo-HygRelationships -Applications $apps
        @($p.Relationships).Count | Should -Be 1
        $r = $p.Relationships[0]
        $r.Kind | Should -Be 'Supersedence'
        $r.FromAppName | Should -Be 'New App'
        $r.ToAppName | Should -Be 'Old App'
        $r.ToAppExists | Should -BeTrue
    }

    It 'marks a supersedence to a deleted app as not existing' {
        $apps = @(
            (New-HygRelApp -CI_ID 1 -Name 'New App' -Model 'ScopeId_T/Application_A' -IsSuperseding $true -Xml (New-HygAppXml -SupersedesModels @('ScopeId_T/Application_GONE')))
        )
        $p = ConvertTo-HygRelationships -Applications $apps
        $p.Relationships[0].ToAppExists | Should -BeFalse
        $p.Relationships[0].ToModelName | Should -Be 'ScopeId_T/Application_GONE'
    }

    It 'classifies dependency DesiredState Required, Optional, and default' {
        $apps = @(
            (New-HygRelApp -CI_ID 1 -Name 'Parent' -Model 'ScopeId_T/Application_P' -Xml (New-HygAppXml -Dependencies @(
                @{ Model = 'ScopeId_T/Application_R'; State = 'Required' },
                @{ Model = 'ScopeId_T/Application_O'; State = 'Optional' },
                @{ Model = 'ScopeId_T/Application_D'; State = '' }
            ))),
            (New-HygRelApp -CI_ID 2 -Name 'Req' -Model 'ScopeId_T/Application_R'),
            (New-HygRelApp -CI_ID 3 -Name 'Opt' -Model 'ScopeId_T/Application_O'),
            (New-HygRelApp -CI_ID 4 -Name 'Def' -Model 'ScopeId_T/Application_D')
        )
        $p = ConvertTo-HygRelationships -Applications $apps
        $deps = @($p.Relationships | Where-Object { $_.Kind -eq 'Dependency' })
        $deps.Count | Should -Be 3
        ($deps | Where-Object { $_.ToAppName -eq 'Req' }).DependencyState | Should -Be 'Required'
        ($deps | Where-Object { $_.ToAppName -eq 'Opt' }).DependencyState | Should -Be 'Optional'
        ($deps | Where-Object { $_.ToAppName -eq 'Def' }).DependencyState | Should -Be 'AppDependence'
    }

    It 'extracts deployment-type content locations' {
        $loc = '\\server\share\app\1.0'
        $apps = @(New-HygRelApp -CI_ID 1 -Name 'App' -Model 'ScopeId_T/Application_A' -Xml (New-HygAppXml -DTTitle 'MSI Install' -ContentLocations @($loc)))
        $p = ConvertTo-HygRelationships -Applications $apps
        @($p.ContentLocations).Count | Should -Be 1
        $p.ContentLocations[0].Location | Should -Be $loc
        $p.ContentLocations[0].DTName | Should -Be 'MSI Install'
    }

    It 'notes malformed XML instead of throwing' {
        $apps = @([pscustomobject]@{
            CI_ID = 9; ModelName = 'S/A'; Name = 'Broken'; SoftwareVersion = '1'
            Manufacturer = ''; IsEnabled = $true; IsExpired = $false; IsSuperseded = $false
            IsSuperseding = $true; HasContent = $true; NumberOfDeploymentTypes = 1
            SDMPackageXML = '<not-xml'
        })
        $p = ConvertTo-HygRelationships -Applications $apps
        @($p.Relationships).Count | Should -Be 0
        @($p.ParseNotes).Count | Should -Be 1
    }

    It 'skips Supersedes blocks when the app is not flagged IsSuperseding' {
        $apps = @(
            (New-HygRelApp -CI_ID 1 -Name 'Not Superseding' -Model 'ScopeId_T/Application_A' -IsSuperseding $false -Xml (New-HygAppXml -SupersedesModels @('ScopeId_T/Application_B')))
        )
        @((ConvertTo-HygRelationships -Applications $apps).Relationships).Count | Should -Be 0
    }
}

Describe 'Find-HygCircularEdges' {
    It 'finds both edges of a two-node loop and ignores a chain' {
        $edges = @(
            [pscustomobject]@{ FromAppCIID = 1; ToAppCIID = 2 },
            [pscustomobject]@{ FromAppCIID = 2; ToAppCIID = 1 },
            [pscustomobject]@{ FromAppCIID = 3; ToAppCIID = 4 }
        )
        $circ = @(Find-HygCircularEdges -Edges $edges)
        $circ.Count | Should -Be 2
        ($circ | ForEach-Object { $_.FromAppCIID }) | Should -Not -Contain 3
    }

    It 'returns empty for an acyclic graph' {
        $edges = @(
            [pscustomobject]@{ FromAppCIID = 1; ToAppCIID = 2 },
            [pscustomobject]@{ FromAppCIID = 2; ToAppCIID = 3 }
        )
        @(Find-HygCircularEdges -Edges $edges).Count | Should -Be 0
    }
}

Describe 'Test-HygRelationshipChecks' {
    It 'SUP-01 flags a supersedence to a deleted app as Error' {
        $rel = New-HygRelData -Apps @(
            (New-HygRelApp -CI_ID 1 -Name 'New' -Model 'S/A' -IsSuperseding $true -Xml (New-HygAppXml -SupersedesModels @('S/GONE')))
        )
        $f = @(Test-HygRelationshipChecks -RelationshipData $rel)
        @($f | Where-Object { $_.CheckId -eq 'SUP-01' }).Count | Should -Be 1
        ($f | Where-Object { $_.CheckId -eq 'SUP-01' }).Severity | Should -Be 'Error'
    }

    It 'SUP-04 outranks SUP-03 when the target is retired and the source disabled' {
        $rel = New-HygRelData -Apps @(
            (New-HygRelApp -CI_ID 1 -Name 'New' -Model 'S/A' -IsSuperseding $true -IsEnabled $false -Xml (New-HygAppXml -SupersedesModels @('S/B'))),
            (New-HygRelApp -CI_ID 2 -Name 'Old' -Model 'S/B' -IsExpired $true)
        )
        $f = @(Test-HygRelationshipChecks -RelationshipData $rel)
        @($f | Where-Object { $_.CheckId -eq 'SUP-04' }).Count | Should -Be 1
        @($f | Where-Object { $_.CheckId -eq 'SUP-03' }).Count | Should -Be 0
    }

    It 'SUP-03 flags a disabled superseding app' {
        $rel = New-HygRelData -Apps @(
            (New-HygRelApp -CI_ID 1 -Name 'New' -Model 'S/A' -IsSuperseding $true -IsEnabled $false -Xml (New-HygAppXml -SupersedesModels @('S/B'))),
            (New-HygRelApp -CI_ID 2 -Name 'Old' -Model 'S/B')
        )
        $f = @(Test-HygRelationshipChecks -RelationshipData $rel)
        @($f | Where-Object { $_.CheckId -eq 'SUP-03' }).Count | Should -Be 1
    }

    It 'SUP-02 flags both edges of a circular supersedence' {
        $rel = New-HygRelData -Apps @(
            (New-HygRelApp -CI_ID 1 -Name 'A' -Model 'S/A' -IsSuperseding $true -Xml (New-HygAppXml -SupersedesModels @('S/B'))),
            (New-HygRelApp -CI_ID 2 -Name 'B' -Model 'S/B' -IsSuperseding $true -Xml (New-HygAppXml -SupersedesModels @('S/A')))
        )
        $f = @(Test-HygRelationshipChecks -RelationshipData $rel)
        @($f | Where-Object { $_.CheckId -eq 'SUP-02' }).Count | Should -Be 2
    }

    It 'DEP-01/03/04/05 classify dependency target problems' {
        $rel = New-HygRelData -Apps @(
            (New-HygRelApp -CI_ID 1 -Name 'Parent' -Model 'S/P' -Xml (New-HygAppXml -Dependencies @(
                @{ Model = 'S/GONE';      State = 'Required' },
                @{ Model = 'S/RETIRED';   State = 'Required' },
                @{ Model = 'S/DISABLED';  State = 'Required' },
                @{ Model = 'S/NOCONTENT'; State = 'Required' }
            ))),
            (New-HygRelApp -CI_ID 2 -Name 'Retired'   -Model 'S/RETIRED' -IsExpired $true),
            (New-HygRelApp -CI_ID 3 -Name 'Disabled'  -Model 'S/DISABLED' -IsEnabled $false),
            (New-HygRelApp -CI_ID 4 -Name 'NoContent' -Model 'S/NOCONTENT' -HasContent $false)
        )
        $f = @(Test-HygRelationshipChecks -RelationshipData $rel)
        @($f | Where-Object { $_.CheckId -eq 'DEP-01' }).Count | Should -Be 1
        @($f | Where-Object { $_.CheckId -eq 'DEP-04' }).Count | Should -Be 1
        @($f | Where-Object { $_.CheckId -eq 'DEP-03' }).Count | Should -Be 1
        @($f | Where-Object { $_.CheckId -eq 'DEP-05' }).Count | Should -Be 1
        ($f | Where-Object { $_.CheckId -eq 'DEP-05' }).Severity | Should -Be 'Info' -Because 'contentless script deployment types can be valid'
        ($f | Where-Object { $_.CheckId -eq 'DEP-05' }).Evidence | Should -Not -Match 'distributed'
        ($f | Where-Object { $_.CheckId -eq 'DEP-05' }).Evidence | Should -Match 'not evidence of an installation'
    }

    It 'DEP-02 flags a circular dependency' {
        $rel = New-HygRelData -Apps @(
            (New-HygRelApp -CI_ID 1 -Name 'A' -Model 'S/A' -Xml (New-HygAppXml -Dependencies @(@{ Model = 'S/B'; State = 'Required' }))),
            (New-HygRelApp -CI_ID 2 -Name 'B' -Model 'S/B' -Xml (New-HygAppXml -Dependencies @(@{ Model = 'S/A'; State = 'Required' })))
        )
        $f = @(Test-HygRelationshipChecks -RelationshipData $rel)
        @($f | Where-Object { $_.CheckId -eq 'DEP-02' }).Count | Should -Be 2
    }

    It 'REL-01 flags relationship participants without a manufacturer' {
        $rel = New-HygRelData -Apps @(
            (New-HygRelApp -CI_ID 1 -Name 'NoVendor' -Model 'S/A' -Manufacturer '' -Xml (New-HygAppXml -Dependencies @(@{ Model = 'S/B'; State = 'Required' }))),
            (New-HygRelApp -CI_ID 2 -Name 'HasVendor' -Model 'S/B' -Manufacturer 'Contoso')
        )
        $f = @(Test-HygRelationshipChecks -RelationshipData $rel)
        $rel01 = @($f | Where-Object { $_.CheckId -eq 'REL-01' })
        $rel01.Count | Should -Be 1
        $rel01[0].ObjectName | Should -Be 'NoVendor'
    }
}

Describe 'Test-HygAppContentPath (APP-04)' {
    It 'flags missing content locations and passes existing ones' {
        $goodPath = Join-Path $TestDrive 'content-exists'
        New-Item -ItemType Directory -Path $goodPath -Force | Out-Null
        $missing = Join-Path $TestDrive 'content-missing'
        $rel = [pscustomobject]@{
            Apps = @{}; Relationships = @(); DatasetNotes = @()
            ContentLocations = @(
                [pscustomobject]@{ AppCIID = 1; AppName = 'Good'; DTName = 'DT'; Location = $goodPath },
                [pscustomobject]@{ AppCIID = 2; AppName = 'Bad';  DTName = 'DT'; Location = $missing },
                [pscustomobject]@{ AppCIID = 3; AppName = 'Bad2'; DTName = 'DT'; Location = $missing }
            )
        }
        $f = @(Test-HygAppContentPath -RelationshipData $rel)
        $f.Count | Should -Be 2
        @($f | ForEach-Object { $_.CheckId } | Select-Object -Unique) | Should -Be @('APP-04')
        ($f | ForEach-Object { $_.ObjectName }) | Should -Not -Contain 'Good / DT'
    }
}

Describe 'Invoke-HygieneScan with relationship data' {
    It 'includes relationship findings and APP-04 when data is supplied' {
        $data = New-HygData
        $rel = New-HygRelData -Apps @(
            (New-HygRelApp -CI_ID 1 -Name 'New' -Model 'S/A' -IsSuperseding $true -Xml (New-HygAppXml -SupersedesModels @('S/GONE')))
        )
        $f = @(Invoke-HygieneScan -Data $data -RelationshipData $rel)
        @($f | Where-Object { $_.CheckId -eq 'SUP-01' }).Count | Should -Be 1
    }

    It 'skips relationship checks cleanly when data is absent' {
        $data = New-HygData
        { Invoke-HygieneScan -Data $data } | Should -Not -Throw
    }
}

Describe 'Get-HygieneSuppressionKey' {
    It 'builds a stable pipe-delimited identity' {
        $f = New-HygieneFinding -CheckId 'APP-02' -Severity Error -Category 'Applications' `
            -ObjectType 'Application' -ObjectId '42' -ObjectName 'Zombie' `
            -Evidence 'e' -Recommendation 'r'
        Get-HygieneSuppressionKey -Finding $f | Should -Be 'APP-02|Application|42|Zombie'
    }
}


Describe 'Build-HygRelationshipTree' {
    It 'builds a nested chain rooted at the top superseding app' {
        $rel = New-HygRelData -Apps @(
            (New-HygRelApp -CI_ID 1 -Name 'A' -Model 'S/A' -IsSuperseding $true -Xml (New-HygAppXml -SupersedesModels @('S/B'))),
            (New-HygRelApp -CI_ID 2 -Name 'B' -Model 'S/B' -IsSuperseding $true -Xml (New-HygAppXml -SupersedesModels @('S/C'))),
            (New-HygRelApp -CI_ID 3 -Name 'C' -Model 'S/C')
        )
        $tree = @(Build-HygRelationshipTree -RelationshipData $rel -Kind Supersedence)
        $tree.Count | Should -Be 1
        $tree[0].Label | Should -Match '^A'
        @($tree[0].Children).Count | Should -Be 1
        $tree[0].Children[0].Label | Should -Match '^B'
        $tree[0].Children[0].Children[0].Label | Should -Match '^C'
        $tree[0].Glyph | Should -Be ([char]0x2713)
    }

    It 'marks a missing target with an x glyph' {
        $rel = New-HygRelData -Apps @(
            (New-HygRelApp -CI_ID 1 -Name 'A' -Model 'S/A' -IsSuperseding $true -Xml (New-HygAppXml -SupersedesModels @('S/GONE')))
        )
        $tree = @(Build-HygRelationshipTree -RelationshipData $rel -Kind Supersedence)
        $tree[0].Children[0].Glyph | Should -Be ([char]0x2717)
        $tree[0].Children[0].Label | Should -Match 'Unknown'
    }

    It 'terminates and annotates a circular chain' {
        $rel = New-HygRelData -Apps @(
            (New-HygRelApp -CI_ID 1 -Name 'A' -Model 'S/A' -IsSuperseding $true -Xml (New-HygAppXml -SupersedesModels @('S/B'))),
            (New-HygRelApp -CI_ID 2 -Name 'B' -Model 'S/B' -IsSuperseding $true -Xml (New-HygAppXml -SupersedesModels @('S/A')))
        )
        $tree = @(Build-HygRelationshipTree -RelationshipData $rel -Kind Supersedence)
        $tree.Count | Should -BeGreaterThan 0
        $flat = New-Object System.Collections.Generic.List[string]
        $walk = $null
        $walk = {
            param($Nodes)
            foreach ($n in $Nodes) { $flat.Add([string]$n.Label); & $walk @($n.Children) }
        }
        & $walk $tree
        ($flat | Where-Object { $_ -match 'circular reference' }).Count | Should -BeGreaterThan 0
    }

    It 'marks a disabled child with a warn glyph' {
        $rel = New-HygRelData -Apps @(
            (New-HygRelApp -CI_ID 1 -Name 'Parent' -Model 'S/P' -Xml (New-HygAppXml -Dependencies @(@{ Model = 'S/D'; State = 'Required' }))),
            (New-HygRelApp -CI_ID 2 -Name 'Dep' -Model 'S/D' -IsEnabled $false)
        )
        $tree = @(Build-HygRelationshipTree -RelationshipData $rel -Kind Dependency)
        $tree[0].Children[0].Glyph | Should -Be ([char]0x26A0)
    }
}


# ============================================================================
# DEV / BND / TSQ / UPD / MNT families
# ============================================================================

Describe 'Test-HygDeviceInactive (DEV-01)' {
    It 'aggregates inactive clients as Warning when cleanup tasks are disabled' {
        $data = New-HygData -Devices @(
            (New-HygDevice -ResourceID 1 -Name 'OLD01' -LastActiveTime (Get-Date).AddDays(-200)),
            (New-HygDevice -ResourceID 2 -Name 'FRESH' -LastActiveTime (Get-Date).AddDays(-2))
        ) -MaintenanceTasks @([pscustomobject]@{ TaskName = 'Delete Aged Discovery Data'; Enabled = $false })
        $f = @(Test-HygDeviceInactive -Data $data)
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Warning'
        $f[0].Evidence | Should -Match '1 clients'
    }

    It 'downgrades to Info when a discovery cleanup task is enabled' {
        $data = New-HygData -Devices @(New-HygDevice -LastActiveTime (Get-Date).AddDays(-200)) `
            -MaintenanceTasks @([pscustomobject]@{ TaskName = 'Delete Inactive Client Discovery Data'; Enabled = $true })
        (Test-HygDeviceInactive -Data $data).Severity | Should -Be 'Info'
    }

    It 'stays silent when nothing is inactive' {
        $data = New-HygData -Devices @(New-HygDevice)
        @(Test-HygDeviceInactive -Data $data).Count | Should -Be 0
    }
}

Describe 'Test-HygDeviceDuplicates (DEV-02)' {
    It 'flags name duplicates with their resource ids' {
        $data = New-HygData -Devices @(
            (New-HygDevice -ResourceID 1 -Name 'PC01'),
            (New-HygDevice -ResourceID 2 -Name 'pc01'),
            (New-HygDevice -ResourceID 3 -Name 'PC02')
        )
        $f = @(Test-HygDeviceDuplicates -Data $data)
        $f.Count | Should -Be 1
        $f[0].ObjectId | Should -Match '1, 2'
    }

    It 'flags cross-name SMBIOS collisions' {
        $g = '11111111-2222-3333-4444-555555555555'
        $data = New-HygData -Devices @(
            (New-HygDevice -ResourceID 1 -Name 'OLDNAME' -SMBIOSGUID $g),
            (New-HygDevice -ResourceID 2 -Name 'NEWNAME' -SMBIOSGUID $g)
        )
        $f = @(Test-HygDeviceDuplicates -Data $data)
        $f.Count | Should -Be 1
        $f[0].ObjectName | Should -Match 'OLDNAME'
        $f[0].ObjectName | Should -Match 'NEWNAME'
    }
}

Describe 'Test-HygClientVersions (DEV-03)' {
    It 'aggregates clients behind the newest version' {
        $data = New-HygData -Devices @(
            (New-HygDevice -ResourceID 1 -Name 'NEW' -ClientVersion '5.00.9140.1000'),
            (New-HygDevice -ResourceID 2 -Name 'OLD' -ClientVersion '5.00.9100.1000')
        )
        $f = @(Test-HygClientVersions -Data $data)
        $f.Count | Should -Be 1
        $f[0].Evidence | Should -Match '1 of 2'
        # [version] normalizes '5.00.x' to '5.0.x' when stringified.
        $f[0].Evidence | Should -Match '5\.0\.9140\.1000'
    }

    It 'stays silent when every client matches the newest version' {
        $data = New-HygData -Devices @(
            (New-HygDevice -ResourceID 1 -ClientVersion '5.00.9140.1000'),
            (New-HygDevice -ResourceID 2 -Name 'PC02' -ClientVersion '5.00.9140.1000')
        )
        @(Test-HygClientVersions -Data $data).Count | Should -Be 0
    }
}

Describe 'Test-HygBoundaryChecks (BND-01/02/03)' {
    It 'flags ungrouped boundaries and empty boundary groups' {
        $data = New-HygData `
            -Boundaries @(
                [pscustomobject]@{ DisplayName = 'Orphan'; Value = '10.1.0.0'; BoundaryType = 0; GroupCount = 0 },
                [pscustomobject]@{ DisplayName = 'Homed';  Value = '10.2.0.0'; BoundaryType = 0; GroupCount = 1 }
            ) `
            -BoundaryGroups @(
                [pscustomobject]@{ GroupID = 1; Name = 'Empty Group'; SiteSystemCount = 0 },
                [pscustomobject]@{ GroupID = 2; Name = 'Full Group';  SiteSystemCount = 2 }
            )
        $f = @(Test-HygBoundaryChecks -Data $data)
        @($f | Where-Object { $_.CheckId -eq 'BND-01' }).Count | Should -Be 1
        @($f | Where-Object { $_.CheckId -eq 'BND-02' }).Count | Should -Be 1
    }

    It 'detects overlapping IP ranges and ignores disjoint ones' {
        $data = New-HygData -Boundaries @(
            [pscustomobject]@{ DisplayName = 'R1'; Value = '10.0.0.1-10.0.0.100';   BoundaryType = 3; GroupCount = 1 },
            [pscustomobject]@{ DisplayName = 'R2'; Value = '10.0.0.50-10.0.0.200';  BoundaryType = 3; GroupCount = 1 },
            [pscustomobject]@{ DisplayName = 'R3'; Value = '10.0.1.1-10.0.1.50';    BoundaryType = 3; GroupCount = 1 }
        )
        $f = @(Test-HygBoundaryChecks -Data $data | Where-Object { $_.CheckId -eq 'BND-03' })
        $f.Count | Should -Be 1
        $f[0].ObjectName | Should -Match '10.0.0.1-10.0.0.100'
    }
}

Describe 'Test-HygTaskSequenceRefs (TSQ-01/02)' {
    It 'flags a task sequence referencing deleted content' {
        $data = New-HygData `
            -TaskSequences @([pscustomobject]@{ PackageID = 'MCM000TS'; Name = 'Build'; ReferencedIDs = @('MCM00PKG', 'MCM00GNE'); BootImageID = '' }) `
            -Packages @([pscustomobject]@{ PackageID = 'MCM00PKG'; Name = 'Known' })
        $f = @(Test-HygTaskSequenceRefs -Data $data | Where-Object { $_.CheckId -eq 'TSQ-01' })
        $f.Count | Should -Be 1
        $f[0].Evidence | Should -Match 'MCM00GNE'
        $f[0].Evidence | Should -Not -Match 'MCM00PKG,'
    }

    It 'flags unreferenced custom boot images and driver packages, sparing defaults and referenced ones' {
        $data = New-HygData `
            -TaskSequences @([pscustomobject]@{ PackageID = 'MCM000TS'; Name = 'Build'; ReferencedIDs = @('MCM00DRV'); BootImageID = 'MCM00BI1' }) `
            -BootImages @(
                [pscustomobject]@{ PackageID = 'MCM00BI1'; Name = 'Custom WinPE used' },
                [pscustomobject]@{ PackageID = 'MCM00BI2'; Name = 'Custom WinPE unused' },
                [pscustomobject]@{ PackageID = 'MCM00BI3'; Name = 'Boot image (x64)' }
            ) `
            -DriverPackages @(
                [pscustomobject]@{ PackageID = 'MCM00DRV'; Name = 'Model A drivers' },
                [pscustomobject]@{ PackageID = 'MCM00DRX'; Name = 'Retired model drivers' }
            )
        $f = @(Test-HygTaskSequenceRefs -Data $data | Where-Object { $_.CheckId -eq 'TSQ-02' })
        $f.Count | Should -Be 2
        ($f | ForEach-Object { $_.ObjectName }) | Should -Contain 'Custom WinPE unused'
        ($f | ForEach-Object { $_.ObjectName }) | Should -Contain 'Retired model drivers'
        ($f | ForEach-Object { $_.ObjectName }) | Should -Not -Contain 'Boot image (x64)'
    }
}

Describe 'Test-HygUpdateGroupChecks (UPD-01)' {
    It 'flags a group over the expired threshold using the documented expired count only' {
        $data = New-HygData -UpdateGroups @(
            [pscustomobject]@{ Name = 'Old SUG'; CI_ID = 1; NumberOfUpdates = 100; NumberOfExpiredUpdates = 35; ContainsSupersededUpdates = $true },
            [pscustomobject]@{ Name = 'Clean SUG'; CI_ID = 2; NumberOfUpdates = 100; NumberOfExpiredUpdates = 2; ContainsSupersededUpdates = $true }
        )
        $f = @(Test-HygUpdateGroupChecks -Data $data | Where-Object { $_.CheckId -eq 'UPD-01' })
        $f.Count | Should -Be 1 -Because 'superseded presence is a boolean on the provider and must not inflate the percentage'
        $f[0].ObjectName | Should -Be 'Old SUG'
        $f[0].Evidence | Should -Match 'also contains superseded'
    }
}

Describe 'Test-HygAdrChecks (UPD-03)' {
    It 'classifies ADR error as Error, disabled as Info, stale as Warning' {
        $data = New-HygData -AutoDeploymentRules @(
            [pscustomobject]@{ Name = 'Erroring'; AutoDeploymentEnabled = $true;  LastRunTime = (Get-Date).AddDays(-1);  LastErrorCode = 2147500037 },
            [pscustomobject]@{ Name = 'Disabled'; AutoDeploymentEnabled = $false; LastRunTime = (Get-Date).AddDays(-1);  LastErrorCode = 0 },
            [pscustomobject]@{ Name = 'Stale';    AutoDeploymentEnabled = $true;  LastRunTime = (Get-Date).AddDays(-90); LastErrorCode = 0 },
            [pscustomobject]@{ Name = 'Healthy';  AutoDeploymentEnabled = $true;  LastRunTime = (Get-Date).AddDays(-3);  LastErrorCode = 0 }
        )
        $f = @(Test-HygAdrChecks -Data $data | Where-Object { $_.CheckId -eq 'UPD-03' })
        $f.Count | Should -Be 3
        ($f | Where-Object { $_.ObjectName -eq 'Erroring' }).Severity | Should -Be 'Error'
        ($f | Where-Object { $_.ObjectName -eq 'Disabled' }).Severity | Should -Be 'Info'
        ($f | Where-Object { $_.ObjectName -eq 'Stale' }).Severity | Should -Be 'Warning'
        ($f | Where-Object { $_.ObjectName -eq 'Erroring' }).FixScript | Should -Match 'Invoke-CMSoftwareUpdateAutoDeploymentRule'
    }
}

Describe 'Dataset-failure skipping' {
    It 'skips a check whose required dataset failed, with a visible Scan finding instead of fabricated evidence' {
        $data = New-HygData -Applications @() -Deployments @()
        $data | Add-Member -NotePropertyName FailedDatasets -NotePropertyValue @('Deployments') -Force
        $f = @(Invoke-HygieneScan -Data $data)
        $skips = @($f | Where-Object { $_.Category -eq 'Scan' -and $_.ObjectName -like 'Check * skipped' })
        ($skips.CheckId) | Should -Contain 'APP-01' -Because 'APP-01 reads Deployments as evidence'
        ($skips.CheckId) | Should -Contain 'COL-01'
        @($f | Where-Object { $_.CheckId -eq 'APP-01' -and $_.Category -ne 'Scan' }).Count | Should -Be 0
    }

    It 'runs everything when no dataset failed' {
        $data = New-HygData
        $data | Add-Member -NotePropertyName FailedDatasets -NotePropertyValue @() -Force
        $f = @(Invoke-HygieneScan -Data $data)
        @($f | Where-Object { $_.ObjectName -like 'Check * skipped' }).Count | Should -Be 0
    }

    It 'gates every supporting dataset used by absence and severity checks' {
        $cases = @(
            @{ Failed = 'TaskSequences';          Check = 'APP-01'; Data = (New-HygData -Applications @((New-HygApp))) },
            @{ Failed = 'DependencyTargetCIIDs';  Check = 'APP-01'; Data = (New-HygData -Applications @((New-HygApp))) },
            @{ Failed = 'Programs';               Check = 'PKG-01'; Data = (New-HygData -Packages @([pscustomobject]@{ PackageID = 'MCM00001'; Name = 'Unknown program state' })) },
            @{ Failed = 'CollectionsWithSettings'; Check = 'COL-01'; Data = (New-HygData -Collections @((New-HygCollection))) },
            @{ Failed = 'MaintenanceTasks';       Check = 'DEV-01'; Data = (New-HygData -Devices @((New-HygDevice -LastActiveTime (Get-Date).AddDays(-365)))) }
        )

        foreach ($case in $cases) {
            $case.Data.FailedDatasets = @($case.Failed)
            $f = @(Invoke-HygieneScan -Data $case.Data | Where-Object { $_.CheckId -eq $case.Check })
            @($f | Where-Object { $_.Category -eq 'Scan' }).Count | Should -Be 1 -Because "$($case.Check) must skip when $($case.Failed) failed"
            @($f | Where-Object { $_.Category -ne 'Scan' }).Count | Should -Be 0 -Because 'incomplete input must never become a cleanup finding'
        }
    }
}

Describe 'TSQ-01 content universe' {
    It 'does not flag OS image and OS upgrade package references as deleted' {
        $data = New-HygData `
            -TaskSequences @([pscustomobject]@{ PackageID = 'MCM000TS'; Name = 'Build'; ReferencedIDs = @('MCM00IMG','MCM00UPG','MCM0GONE'); BootImageID = '' }) `
            -OSImages @([pscustomobject]@{ PackageID = 'MCM00IMG'; Name = 'Win11 image' }) `
            -OSUpgradePackages @([pscustomobject]@{ PackageID = 'MCM00UPG'; Name = 'Win11 upgrade' })
        $f = @(Test-HygTaskSequenceRefs -Data $data | Where-Object { $_.CheckId -eq 'TSQ-01' })
        ($f | ForEach-Object Evidence) -join ' ' | Should -Not -Match 'MCM00IMG'
        ($f | ForEach-Object Evidence) -join ' ' | Should -Not -Match 'MCM00UPG'
        ($f | ForEach-Object Evidence) -join ' ' | Should -Match 'MCM0GONE'
    }

    It 'flags a deleted BootImageID even though it is stored outside References' {
        $data = New-HygData -TaskSequences @(
            [pscustomobject]@{ PackageID = 'MCM000TS'; Name = 'Broken boot image'; ReferencedIDs = @(); BootImageID = 'MCM0GONE' }
        )
        $f = @(Test-HygTaskSequenceRefs -Data $data | Where-Object { $_.CheckId -eq 'TSQ-01' })
        $f.Count | Should -Be 1
        $f[0].Evidence | Should -Match 'MCM0GONE'
    }
}

Describe 'APP-04 bounded probe' {
    It 'reports an unanswering path as Unknown at Info, not missing' {
        $rel = [pscustomobject]@{
            ContentLocations = @([pscustomobject]@{ AppCIID = 1; AppName = 'App'; DTName = 'DT'; Location = '\\240.0.0.1\dead$\src' })
        }
        # Timeout 0 forces the timed-out branch deterministically; a live
        # network probe against a dead endpoint varies by network stack.
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $f = @(Test-HygAppContentPath -RelationshipData $rel -ProbeTimeoutMs 0)
        $sw.Stop()
        $sw.ElapsedMilliseconds | Should -BeLessThan 5000 -Because 'the probe must not block on a dead SMB endpoint'
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Info'
        $f[0].Evidence | Should -Match 'unknown'
    }

    It 'reports a genuinely missing local path as a workstation-scoped Warning' {
        $rel = [pscustomobject]@{
            ContentLocations = @([pscustomobject]@{ AppCIID = 1; AppName = 'App'; DTName = 'DT'; Location = (Join-Path $TestDrive 'does-not-exist') })
        }
        $f = @(Test-HygAppContentPath -RelationshipData $rel)
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Warning'
        $f[0].Evidence | Should -Match 'from this workstation'
    }
}

Describe 'SuiteCommon background-runspace initialization' {
    It 'throws immediately instead of returning an opened runspace when bootstrap fails' {
        $missingModule = Join-Path $TestDrive 'missing-module.psd1'
        { New-SuiteBgRunspace -ModulePath $missingModule } | Should -Throw '*Background runspace initialization failed*'
    }
}

Describe 'Version metadata single-sourcing' {
    It 'keeps the manifest, changelog headline, script header, and check catalog in agreement' {
        $root = Split-Path $PSScriptRoot -Parent
        $manifestVersion = [string](Import-PowerShellDataFile (Join-Path $root 'Module\SiteHygieneCommon.psd1')).ModuleVersion
        $clTop = (Get-Content (Join-Path $root 'CHANGELOG.md') -TotalCount 10 | Where-Object { $_ -match '^## \[?([0-9][0-9\.]*[0-9])' } | Select-Object -First 1)
        $clTop -match '([0-9][0-9\.]*[0-9])' | Out-Null
        $Matches[1] | Should -Be $manifestVersion -Because 'the changelog headline must match the manifest'
        $header = (Select-String (Join-Path $root 'start-sitehygiene.ps1') -Pattern 'Version    : ([0-9\.]+)' | Select-Object -First 1).Matches[0].Groups[1].Value
        $header | Should -Be $manifestVersion -Because 'the script header must match the manifest'
        (Select-String (Join-Path $root 'start-sitehygiene.ps1') -Pattern '\$script:AppVersion').Count | Should -BeGreaterThan 1 -Because 'UI version strings must render from the manifest-derived variable'
        @(Get-HygieneCheckCatalog).Count | Should -Be 57
        @(Get-HygieneCheckCatalog | Where-Object { $_.Id -eq 'UPD-02' }).Count | Should -Be 0 -Because 'UPD-02 was removed; its provider join was invalid'
    }
}

Describe 'Test-HygMaintenanceTasks (MNT-01/02)' {
    It 'flags recommended cleanup tasks that are disabled and the disabled backup task' {
        $data = New-HygData -MaintenanceTasks @(
            [pscustomobject]@{ TaskName = 'Delete Aged Discovery Data'; Enabled = $false },
            [pscustomobject]@{ TaskName = 'Delete Aged Inventory History'; Enabled = $true },
            [pscustomobject]@{ TaskName = 'Rebuild Indexes'; Enabled = $false },
            [pscustomobject]@{ TaskName = 'Backup Site Server'; Enabled = $false }
        )
        $f = @(Test-HygMaintenanceTasks -Data $data)
        @($f | Where-Object { $_.CheckId -eq 'MNT-01' }).Count | Should -Be 1
        ($f | Where-Object { $_.CheckId -eq 'MNT-01' }).ObjectName | Should -Be 'Delete Aged Discovery Data'
        @($f | Where-Object { $_.CheckId -eq 'MNT-02' }).Count | Should -Be 1
    }

    It 'stays silent when everything recommended is enabled' {
        $data = New-HygData -MaintenanceTasks @(
            [pscustomobject]@{ TaskName = 'Delete Aged Discovery Data'; Enabled = $true },
            [pscustomobject]@{ TaskName = 'Backup Site Server'; Enabled = $true }
        )
        @(Test-HygMaintenanceTasks -Data $data).Count | Should -Be 0
    }
}


# ============================================================================
# Gauntlet-3 regression coverage
# ============================================================================

Describe 'BND-01 unknown GroupCount handling' {
    It 'skips boundaries whose group count the provider did not surface' {
        $data = New-HygData -Boundaries @(
            [pscustomobject]@{ DisplayName = 'Unknown count'; Value = '10.9.0.0'; BoundaryType = 0; GroupCount = -1 },
            [pscustomobject]@{ DisplayName = 'Truly orphan';  Value = '10.8.0.0'; BoundaryType = 0; GroupCount = 0 }
        )
        $f = @(Test-HygBoundaryChecks -Data $data | Where-Object { $_.CheckId -eq 'BND-01' })
        $f.Count | Should -Be 1
        $f[0].ObjectName | Should -Be 'Truly orphan'
    }
}

Describe 'DEV-02 placeholder SMBIOS handling' {
    It 'does not report machines sharing a placeholder GUID as duplicates' {
        $zeros = '00000000-0000-0000-0000-000000000000'
        $data = New-HygData -Devices @(
            (New-HygDevice -ResourceID 1 -Name 'CLONE01' -SMBIOSGUID $zeros),
            (New-HygDevice -ResourceID 2 -Name 'CLONE02' -SMBIOSGUID $zeros),
            (New-HygDevice -ResourceID 3 -Name 'CLONE03' -SMBIOSGUID 'ffffffff-ffff-ffff-ffff-ffffffffffff'),
            (New-HygDevice -ResourceID 4 -Name 'CLONE04' -SMBIOSGUID '{FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF}')
        )
        @(Test-HygDeviceDuplicates -Data $data).Count | Should -Be 0
    }

    It 'still reports a genuine cross-name SMBIOS collision' {
        $g = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $data = New-HygData -Devices @(
            (New-HygDevice -ResourceID 1 -Name 'OLDNAME2' -SMBIOSGUID $g),
            (New-HygDevice -ResourceID 2 -Name 'NEWNAME2' -SMBIOSGUID $g)
        )
        @(Test-HygDeviceDuplicates -Data $data).Count | Should -Be 1
    }
}

Describe 'Fix execution' {
    It 'treats an empty fix script as not executable' {
        Test-HygieneFixExecutable -FixScript '' | Should -BeFalse
    }

    It 'treats a comment-only fix script as not executable' {
        Test-HygieneFixExecutable -FixScript "# Console: fix it there`r`n# second line" | Should -BeFalse
    }

    It 'treats a real command as executable' {
        Test-HygieneFixExecutable -FixScript "Remove-CMApplication -Name 'X' -Force" | Should -BeTrue
    }

    It 'treats a command with a trailing comment as executable' {
        Test-HygieneFixExecutable -FixScript "Get-CMAutoDeploymentRule -Name 'r' | Remove-CMAutoDeploymentRule -Force  # or re-enable" | Should -BeTrue
    }

    It 'refuses to run a display-only finding' {
        $f = [pscustomobject]@{ CheckId = 'COL-02'; ObjectName = 'x'; FixScript = '# Review in console' }
        $r = Invoke-HygieneFix -Finding $f
        $r.Success | Should -BeFalse
        $r.ErrorMessage | Should -Match 'display-only'
    }

    It 'refuses to run outside a CMSite drive' {
        $f = [pscustomobject]@{ CheckId = 'APP-01'; ObjectName = 'x'; FixScript = "Remove-CMApplication -Name 'x' -Force" }
        $r = Invoke-HygieneFix -Finding $f
        $r.Success | Should -BeFalse
        $r.ErrorMessage | Should -Match 'site drive'
    }
}

Describe 'Rescan deltas' {
    BeforeAll {
        $script:mkFinding = {
            param($id, $name)
            [pscustomobject]@{ CheckId = $id; Severity = 'Warning'; ObjectType = 'Application'; ObjectId = $name; ObjectName = $name; Evidence = 'e' }
        }
    }

    It 'reports no baseline on the first scan' {
        $d = Get-HygieneScanDelta -Findings @(& $mkFinding 'APP-01' 'A') -Previous $null
        $d.HasBaseline | Should -BeFalse
        $d.NewKeys.Count | Should -Be 0
        @($d.Resolved).Count | Should -Be 0
    }

    It 'flags first-seen findings as new and dropped findings as resolved' {
        $prev = [pscustomobject]@{ Findings = @((& $mkFinding 'APP-01' 'A'), (& $mkFinding 'PKG-01' 'B')) }
        $curr = @((& $mkFinding 'APP-01' 'A'), (& $mkFinding 'COL-01' 'C'))
        $d = Get-HygieneScanDelta -Findings $curr -Previous $prev
        $d.HasBaseline | Should -BeTrue
        $d.NewKeys.Count | Should -Be 1
        $d.NewKeys.Contains((Get-HygieneSuppressionKey -Finding $curr[1])) | Should -BeTrue
        @($d.Resolved).Count | Should -Be 1
        @($d.Resolved)[0].ObjectName | Should -Be 'B'
    }

    It 'round-trips findings through the results file' {
        $path = Join-Path $TestDrive 'lastscan.json'
        Save-HygieneScanResult -Findings @(& $mkFinding 'APP-01' 'A') -Path $path
        $doc = Read-HygieneScanResult -Path $path
        @($doc.Findings).Count | Should -Be 1
        $doc.Findings[0].CheckId | Should -Be 'APP-01'
    }

    It 'treats a missing or malformed results file as no baseline' {
        Read-HygieneScanResult -Path (Join-Path $TestDrive 'absent.json') | Should -BeNullOrEmpty
        $bad = Join-Path $TestDrive 'bad.json'
        Set-Content -LiteralPath $bad -Value '{not json'
        Read-HygieneScanResult -Path $bad | Should -BeNullOrEmpty
    }

    It 'handles an empty current scan (everything resolved)' {
        $prev = [pscustomobject]@{ Findings = @(& $mkFinding 'APP-01' 'A') }
        $d = Get-HygieneScanDelta -Findings @() -Previous $prev
        @($d.Resolved).Count | Should -Be 1
        $d.NewKeys.Count | Should -Be 0
    }
}

Describe 'Collection evaluation deep-dive (COL-05..09)' {
    It 'COL-05 flags sub-daily full evaluation on an incremental collection with an executable fix' {
        $data = New-HygData -Collections @(
            (New-HygCollection -CollectionID 'MCM00010' -Name 'Both hourly' -RefreshType 6 -FullHourSpan 1),
            (New-HygCollection -CollectionID 'MCM00011' -Name 'Both daily backup' -RefreshType 6 -FullDaySpan 1),
            (New-HygCollection -CollectionID 'MCM00012' -Name 'Incremental only' -RefreshType 4)
        )
        $f = @(Test-HygCollectionEvaluationChecks -Data $data | Where-Object CheckId -eq 'COL-05')
        $f.Count | Should -Be 1
        $f[0].ObjectName | Should -Be 'Both hourly'
        Test-HygieneFixExecutable -FixScript $f[0].FixScript | Should -BeTrue
        $f[0].FixScript | Should -Match 'Continuous'
    }

    It 'COL-06 flags direct-rule-only scheduled collections but not when the limiting collection is incremental' {
        $data = New-HygData -Collections @(
            (New-HygCollection -CollectionID 'MCM00020' -Name 'Direct scheduled' -RefreshType 2 -DirectRuleCount 3 -FullDaySpan 1 -LimitToCollectionID 'MCM00022'),
            (New-HygCollection -CollectionID 'MCM00021' -Name 'Direct under incremental limit' -RefreshType 2 -DirectRuleCount 1 -LimitToCollectionID 'MCM00023'),
            (New-HygCollection -CollectionID 'MCM00022' -Name 'Static limit' -RefreshType 2),
            (New-HygCollection -CollectionID 'MCM00023' -Name 'Incremental limit' -RefreshType 4)
        )
        $f = @(Test-HygCollectionEvaluationChecks -Data $data | Where-Object CheckId -eq 'COL-06')
        @($f | Where-Object ObjectName -eq 'Direct scheduled').Count | Should -Be 1
        @($f | Where-Object ObjectName -eq 'Direct under incremental limit').Count | Should -Be 0
    }

    It 'COL-06 does not flag collections with query rules' {
        $data = New-HygData -Collections @(
            (New-HygCollection -CollectionID 'MCM00024' -Name 'Mixed rules' -RefreshType 2 -DirectRuleCount 1 -QueryRuleCount 1)
        )
        @(Test-HygCollectionEvaluationChecks -Data $data | Where-Object CheckId -eq 'COL-06').Count | Should -Be 0
    }

    It 'COL-07 flags include chains deeper than the threshold with the measured depth' {
        # A includes B includes C includes D includes E: depth 4 from A.
        $data = New-HygData -Collections @(
            (New-HygCollection -CollectionID 'MCM000A0' -Name 'A' -IncludeIDs @('MCM000B0')),
            (New-HygCollection -CollectionID 'MCM000B0' -Name 'B' -IncludeIDs @('MCM000C0')),
            (New-HygCollection -CollectionID 'MCM000C0' -Name 'C' -IncludeIDs @('MCM000D0')),
            (New-HygCollection -CollectionID 'MCM000D0' -Name 'D' -ExcludeIDs @('MCM000E0')),
            (New-HygCollection -CollectionID 'MCM000E0' -Name 'E')
        )
        $f = @(Test-HygCollectionEvaluationChecks -Data $data | Where-Object CheckId -eq 'COL-07')
        $f.Count | Should -Be 1
        $f[0].ObjectName | Should -Be 'A'
        $f[0].Evidence | Should -Match 'chain 4 levels'
    }

    It 'COL-08 flags include/exclude/limit reference cycles as errors' {
        $data = New-HygData -Collections @(
            (New-HygCollection -CollectionID 'MCM000F0' -Name 'Loop1' -IncludeIDs @('MCM000F1')),
            (New-HygCollection -CollectionID 'MCM000F1' -Name 'Loop2' -ExcludeIDs @('MCM000F2')),
            (New-HygCollection -CollectionID 'MCM000F2' -Name 'Loop3' -LimitToCollectionID 'MCM000F0'),
            (New-HygCollection -CollectionID 'MCM000F3' -Name 'Bystander' -IncludeIDs @('MCM000F0'))
        )
        $f = @(Test-HygCollectionEvaluationChecks -Data $data | Where-Object CheckId -eq 'COL-08')
        $f.Count | Should -Be 3
        ($f | ForEach-Object Severity | Select-Object -Unique) | Should -Be 'Error'
        @($f | Where-Object ObjectName -eq 'Bystander').Count | Should -Be 0
    }

    It 'COL-08 stays quiet on an acyclic tree and COL-07 tolerates cycles without blowing up' {
        $data = New-HygData -Collections @(
            (New-HygCollection -CollectionID 'MCM000G0' -Name 'Root'),
            (New-HygCollection -CollectionID 'MCM000G1' -Name 'Child' -LimitToCollectionID 'MCM000G0' -IncludeIDs @('MCM000G0'))
        )
        @(Test-HygCollectionEvaluationChecks -Data $data | Where-Object CheckId -eq 'COL-08').Count | Should -Be 0
    }

    It 'COL-09 flags a full-update start-hour hot spot above the threshold' {
        $many = @(1..10 | ForEach-Object { New-HygCollection -CollectionID ('MCM00H{0:00}' -f $_) -Name "Hot$_" -RefreshType 2 -FullDaySpan 1 -FullStartHour 8 })
        $few  = @(1..3  | ForEach-Object { New-HygCollection -CollectionID ('MCM00J{0:00}' -f $_) -Name "Cool$_" -RefreshType 2 -FullDaySpan 1 -FullStartHour 22 })
        $f = @(Test-HygCollectionEvaluationChecks -Data (New-HygData -Collections ($many + $few)) | Where-Object CheckId -eq 'COL-09')
        $f.Count | Should -Be 1
        $f[0].ObjectId | Should -Be '8'
    }

    It 'exempts built-in SMS collections from every evaluation check' {
        $data = New-HygData -Collections @(
            (New-HygCollection -CollectionID 'SMS00001' -Name 'All Systems' -RefreshType 6 -FullHourSpan 1 -DirectRuleCount 1)
        )
        @(Test-HygCollectionEvaluationChecks -Data $data | Where-Object { $_.CheckId -in 'COL-05','COL-06' }).Count | Should -Be 0
    }
}

Describe 'Collection reference graph source' {
    It 'prefers the SMS_CollectionDependencies dataset over embedded rules' {
        $data = New-HygData -Collections @(
            (New-HygCollection -CollectionID 'MCM000K0' -Name 'K0' -IncludeIDs @('MCM000K9'))
        ) -CollectionDependencies @(
            [pscustomobject]@{ From = 'MCM000K0'; To = 'MCM000K1'; Kind = 'include' }
        )
        $edges = @(Get-HygCollectionReferenceGraph -Data $data)
        $edges.Count | Should -Be 1
        $edges[0].To | Should -Be 'MCM000K1'
    }

    It 'falls back to embedded rules when the dependencies dataset is empty' {
        $data = New-HygData -Collections @(
            (New-HygCollection -CollectionID 'MCM000K2' -Name 'K2' -LimitToCollectionID 'SMS00001' -IncludeIDs @('MCM000K3'))
        )
        $kinds = @(Get-HygCollectionReferenceGraph -Data $data | ForEach-Object Kind | Sort-Object)
        $kinds | Should -Be @('include', 'limit')
    }

    It 'COL-08 finds a cycle reported only by the dependencies dataset' {
        # Embedded rules are blind (null lazy elements); the CIM edges see the loop.
        $data = New-HygData -Collections @(
            (New-HygCollection -CollectionID 'MCM000L0' -Name 'LoopA'),
            (New-HygCollection -CollectionID 'MCM000L1' -Name 'LoopB')
        ) -CollectionDependencies @(
            [pscustomobject]@{ From = 'MCM000L0'; To = 'MCM000L1'; Kind = 'include' },
            [pscustomobject]@{ From = 'MCM000L1'; To = 'MCM000L0'; Kind = 'limit' }
        )
        $f = @(Test-HygCollectionEvaluationChecks -Data $data | Where-Object CheckId -eq 'COL-08')
        $f.Count | Should -Be 2
    }
}

Describe 'Scan scopes' {
    It 'maps a scope to only the datasets its checks read' {
        $keys = @(Get-HygieneRequiredDataset -Scopes 'Boundaries')
        ($keys | Sort-Object) -join ',' | Should -Be 'Boundaries,BoundaryGroups'
    }

    It 'requests the per-object datasets only for the slow scopes' {
        $fast = @(Get-HygieneRequiredDataset -Scopes 'Applications','Collections','Deployments')
        $fast | Should -Not -Contain 'Relationships'
        $fast | Should -Not -Contain 'CollectionDetails'
        @(Get-HygieneRequiredDataset -Scopes 'AppRelationships') | Should -Contain 'Relationships'
        @(Get-HygieneRequiredDataset -Scopes 'CollectionSchedules') | Should -Contain 'CollectionDetails'
    }

    It 'treats no scope as every scope' {
        $all = @(Get-HygieneRequiredDataset)
        $all | Should -Contain 'Devices'
        $all | Should -Contain 'Relationships'
        $all | Should -Contain 'CollectionDetails'
    }

    It 'rejects an unknown scope' {
        { Get-HygieneRequiredDataset -Scopes 'Nope' } | Should -Throw '*Unknown scan scope*'
    }

    It 'runs only the checks of the selected scope' {
        $data = New-HygData `
            -Applications @(New-HygApp -Name 'Zombie' -IsExpired $true -IsDeployed $true) `
            -Packages @([pscustomobject]@{ PackageID = 'MCM00PKG'; Name = 'Dead Package' })
        $f = @(Invoke-HygieneScan -Data $data -Scopes 'Packages')
        @($f | Where-Object CheckId -eq 'PKG-01').Count | Should -Be 1
        @($f | Where-Object CheckId -like 'APP-*').Count | Should -Be 0
    }

    It 'never runs a check over a dataset the prefetch left out' {
        $data = New-HygData -Packages @([pscustomobject]@{ PackageID = 'MCM00PKG'; Name = 'Dead Package' })
        $data | Add-Member -NotePropertyName NotCollectedDatasets -NotePropertyValue @('Deployments')
        $f = @(Invoke-HygieneScan -Data $data -Scopes 'Packages')
        $f.Count | Should -Be 0
    }

    It 'counts an include reference from the dependency edges as a COL-01 reference' {
        $data = New-HygData `
            -Collections @((New-HygCollection -CollectionID 'MCM00A01' -Name 'Empty but included' -MemberCount 0), (New-HygCollection -CollectionID 'MCM00A02' -Name 'Parent' -MemberCount 5)) `
            -CollectionDependencies @([pscustomobject]@{ From = 'MCM00A02'; To = 'MCM00A01'; Kind = 'include' })
        @(Test-HygCollectionEmptyUnused -Data $data).Count | Should -Be 0
    }
}

Describe 'Scoped prefetch' {
    BeforeAll {
        # The ConfigurationManager module is absent on a test host; Pester
        # can only mock commands that exist.
        $stubs = 'Get-CMApplication','Get-CMPackage','Get-CMProgram','Get-CMTaskSequence','Get-CMDevice','Get-CMBoundary',
            'Get-CMBoundaryGroup','Get-CMBootImage','Get-CMOperatingSystemImage','Get-CMOperatingSystemInstaller','Get-CMDriverPackage',
            'Get-CMSoftwareUpdateGroup','Get-CMSoftwareUpdateDeploymentPackage','Get-CMAutoDeploymentRule','Get-CMSiteMaintenanceTask',
            'Get-CMCollection','Get-CMDeployment','Get-CMApplicationDeployment','Invoke-CMWmiQuery'
        foreach ($s in $stubs) { Set-Item -Path "function:global:$s" -Value { [CmdletBinding()] param($Query, $Option, $Id, [switch]$Fast) } }
    }
    AfterAll {
        foreach ($s in $stubs) { Remove-Item -Path "function:global:$s" -ErrorAction SilentlyContinue }
    }
    BeforeEach {
        # A direct WMI connection needs remote WMI rights a read-only
        # analyst lacks; every read must use the CM provider connection.
        Mock -ModuleName SiteHygieneCommon Get-CimInstance { throw 'Access is denied.' }
        Mock -ModuleName SiteHygieneCommon Invoke-CMWmiQuery { }
        Mock -ModuleName SiteHygieneCommon Invoke-CMWmiQuery {
            [pscustomobject]@{ DependentCollectionID = 'MCM00002'; SourceCollectionID = 'MCM00001'; RelationshipType = 2 }
        } -ParameterFilter { $Query -like '*SMS_CollectionDependencies*' }
        Mock -ModuleName SiteHygieneCommon Get-CMDevice { throw 'the device cmdlet reads every column' }
        Mock -ModuleName SiteHygieneCommon Invoke-CMWmiQuery { throw 'devices must not be queried' } -ParameterFilter { $Query -like '*SMS_CM_RES_COLL_SMS00001' }
        Mock -ModuleName SiteHygieneCommon Get-CMApplication { throw 'applications must not be queried' }
        Mock -ModuleName SiteHygieneCommon Get-CMCollection {
            [pscustomobject]@{ CollectionRules = @(); RefreshSchedule = @([pscustomobject]@{ DaySpan = 1; HourSpan = 0; MinuteSpan = 0; StartTime = [datetime]'2026-01-01 03:00' }) }
        }
        Mock -ModuleName SiteHygieneCommon Invoke-CMWmiQuery {
            [pscustomobject]@{ CollectionID = 'MCM00001'; Name = 'Manual';    MemberCount = 1; RefreshType = 1; LimitToCollectionID = 'SMS00001' }
            [pscustomobject]@{ CollectionID = 'MCM00002'; Name = 'Scheduled'; MemberCount = 1; RefreshType = 2; LimitToCollectionID = 'SMS00001' }
            [pscustomobject]@{ CollectionID = 'SMS00001'; Name = 'All Systems'; MemberCount = 9; RefreshType = 6; LimitToCollectionID = '' }
        } -ParameterFilter { $Query -like '*FROM SMS_Collection' }
    }

    It 'queries nothing outside the requested datasets' {
        $data = Get-HygieneData -Datasets 'Collections'
        @($data.Collections).Count | Should -Be 3
        $data.NotCollectedDatasets | Should -Contain 'Devices'
        $data.NotCollectedDatasets | Should -Contain 'Applications'
        $data.FailedDatasets.Count | Should -Be 0
        Should -Invoke -ModuleName SiteHygieneCommon Get-CMDevice -Times 0
        Should -Invoke -ModuleName SiteHygieneCommon Invoke-CMWmiQuery -Times 0 -ParameterFilter { $Query -like '*SMS_CM_RES_COLL_SMS00001' }
    }

    It 'reads collections with one non-lazy query and no per-collection read' {
        $null = Get-HygieneData -Datasets 'Collections'
        Should -Invoke -ModuleName SiteHygieneCommon Invoke-CMWmiQuery -Times 1 -Exactly -ParameterFilter { $Option -eq 'Fast' -and $Query -like '*FROM SMS_Collection' -and $Query -notlike '*`**' }
        Should -Invoke -ModuleName SiteHygieneCommon Get-CimInstance -Times 0
        Should -Invoke -ModuleName SiteHygieneCommon Get-CMCollection -Times 0
    }

    It 'takes include ids from the dependency edges' {
        $data = Get-HygieneData -Datasets 'Collections'
        @(($data.Collections | Where-Object CollectionID -eq 'MCM00002').IncludeIDs) | Should -Be @('MCM00001')
    }

    It 'reads schedule details only for custom collections with a full-update schedule' {
        $progress = [hashtable]::Synchronized(@{ Step = '' })
        $data = Get-HygieneData -Datasets 'CollectionDetails' -ProgressState $progress
        Should -Invoke -ModuleName SiteHygieneCommon Get-CMCollection -Times 1 -Exactly
        ($data.Collections | Where-Object CollectionID -eq 'MCM00002').FullStartHour | Should -Be 3
        $progress.Step | Should -BeLike '*1 of 1*'
    }

    It 'marks a throwing dataset failed instead of returning it empty' {
        $data = Get-HygieneData -Datasets 'Devices'
        Should -Invoke -ModuleName SiteHygieneCommon Get-CMDevice -Times 0
        $data.FailedDatasets | Should -Contain 'Devices'
        @($data.DatasetNotes | Where-Object { $_ -like '*devices unavailable*' }).Count | Should -Be 1
    }
}

Describe 'Content distribution checks' {
    BeforeAll {
        function New-HygContentRow {
            param(
                [string]$ObjectID = 'MCM00C01', [string]$PackageID = 'MCM00C01', [string]$Name = 'Content',
                [int]$ObjectType = 0, [int]$Targeted = 10, [int]$NumberSuccess = 10, [int]$NumberInProgress = 0,
                [int]$NumberErrors = 0, [long]$SourceSize = 1024, $LastUpdateDate = (Get-Date).AddDays(-30)
            )
            [pscustomobject]@{
                ObjectID = $ObjectID; PackageID = $PackageID; Name = $Name; ObjectType = $ObjectType
                Targeted = $Targeted; NumberSuccess = $NumberSuccess; NumberInProgress = $NumberInProgress
                NumberErrors = $NumberErrors; NumberUnknown = 0; SourceSize = $SourceSize; LastUpdateDate = $LastUpdateDate
            }
        }
        function New-HygContentData {
            param([object[]]$ContentStatus = @(), [object[]]$Applications = @(), [object[]]$Deployments = @())
            $data = New-HygData -Applications $Applications -Deployments $Deployments
            $data | Add-Member -NotePropertyName ContentStatus -NotePropertyValue $ContentStatus -PassThru
        }
    }

    It 'CNT-01 flags content with failed distribution points and states the counts' {
        $data = New-HygContentData -ContentStatus @(New-HygContentRow -Name 'Broken' -Targeted 300 -NumberSuccess 288 -NumberErrors 12)
        $f = @(Test-HygContentDistribution -Data $data)
        $f.Count | Should -Be 1
        $f[0].CheckId | Should -Be 'CNT-01'
        $f[0].Evidence | Should -BeLike '*12 of 300*'
    }

    It 'CNT-01 stays quiet on fully distributed content' {
        $data = New-HygContentData -ContentStatus @(New-HygContentRow)
        @(Test-HygContentDistribution -Data $data).Count | Should -Be 0
    }

    It 'CNT-02 flags only in-progress content older than the threshold' {
        $data = New-HygContentData -ContentStatus @(
            (New-HygContentRow -PackageID 'MCM00C02' -Name 'Stalled' -NumberSuccess 8 -NumberInProgress 2 -LastUpdateDate (Get-Date).AddDays(-9)),
            (New-HygContentRow -PackageID 'MCM00C03' -Name 'Just sent' -NumberSuccess 8 -NumberInProgress 2 -LastUpdateDate (Get-Date).AddHours(-3))
        )
        $f = @(Test-HygContentDistribution -Data $data)
        $f.Count | Should -Be 1
        $f[0].CheckId | Should -Be 'CNT-02'
        $f[0].ObjectName | Should -Be 'Stalled'
    }

    It 'CNT-03 flags a deployed application whose content targets no distribution point' {
        $app = New-HygApp -Name 'Deployed App' -IsDeployed $true
        $data = New-HygContentData -Applications @($app) -ContentStatus @(
            New-HygContentRow -ObjectID $app.ModelName -PackageID 'MCM00C04' -Name 'Deployed App' -ObjectType 512 -Targeted 0 -NumberSuccess 0
        )
        $f = @(Test-HygContentDistribution -Data $data)
        $f.Count | Should -Be 1
        $f[0].CheckId | Should -Be 'CNT-03'
        $f[0].Severity | Should -Be 'Error'
    }

    It 'CNT-03 ignores undistributed content that is not deployed or has no source files' {
        $idle = New-HygApp -Name 'Idle App' -ModelName 'ScopeId_X/Application_Idle' -IsDeployed $false
        $script = New-HygApp -Name 'Script App' -ModelName 'ScopeId_X/Application_Script' -IsDeployed $true
        $data = New-HygContentData -Applications @($idle, $script) -ContentStatus @(
            (New-HygContentRow -ObjectID $idle.ModelName -Name 'Idle App' -ObjectType 512 -Targeted 0 -NumberSuccess 0),
            (New-HygContentRow -ObjectID $script.ModelName -Name 'Script App' -ObjectType 512 -Targeted 0 -NumberSuccess 0 -SourceSize 0)
        )
        @(Test-HygContentDistribution -Data $data).Count | Should -Be 0
    }

    It 'CNT-03 flags a package with a program deployment and no distribution point' {
        $data = New-HygContentData -Deployments @(New-HygDeployment -PackageID 'MCM00C05' -FeatureType 2) -ContentStatus @(
            New-HygContentRow -PackageID 'MCM00C05' -Name 'Legacy Pkg' -Targeted 0 -NumberSuccess 0
        )
        @(Test-HygContentDistribution -Data $data | Where-Object CheckId -eq 'CNT-03').Count | Should -Be 1
    }

    It 'offers only display-only fix guidance' {
        $data = New-HygContentData -ContentStatus @(New-HygContentRow -NumberErrors 1)
        $f = @(Test-HygContentDistribution -Data $data)
        Test-HygieneFixExecutable -FixScript $f[0].FixScript | Should -BeFalse
    }

    It 'is skipped by the runner when the content status query failed' {
        $data = New-HygContentData -ContentStatus @()
        $data.FailedDatasets = @('ContentStatus')
        $f = @(Invoke-HygieneScan -Data $data -Scopes 'Content')
        @($f | Where-Object { $_.CheckId -like 'CNT-0*' }).Count | Should -Be 0
        @($f | Where-Object { $_.Category -eq 'Scan' }).Count | Should -Be 1
    }
}

Describe 'COL-04 collection evaluation run time' {
    BeforeAll {
        function New-HygEvalData {
            param([object[]]$Full = @(), [object[]]$Incremental = @())
            $data = New-HygData
            $data | Add-Member -NotePropertyName CollectionEvalFull -NotePropertyValue $Full
            $data | Add-Member -NotePropertyName CollectionEvalIncremental -NotePropertyValue $Incremental -PassThru
        }
        function New-HygEvalRow {
            param([string]$CollectionID, [string]$Name, [long]$LengthMs, [long]$MemberChanges = 0)
            [pscustomobject]@{ CollectionID = $CollectionID; Name = $Name; LengthMs = $LengthMs; MemberChanges = $MemberChanges }
        }
    }

    It 'flags only evaluations over the threshold, slowest first' {
        $data = New-HygEvalData -Full @(
            (New-HygEvalRow -CollectionID 'MCM00E01' -Name 'Quick' -LengthMs 900),
            (New-HygEvalRow -CollectionID 'MCM00E02' -Name 'Slow' -LengthMs 12000),
            (New-HygEvalRow -CollectionID 'MCM00E03' -Name 'Slowest' -LengthMs 95000 -MemberChanges 4)
        )
        $f = @(Test-HygCollectionEvaluationRunTime -Data $data)
        $f.Count | Should -Be 2
        $f[0].ObjectName | Should -Be 'Slowest'
        $f[0].Evidence | Should -BeLike '*95.0s*4 membership change*'
        $f[1].Evidence | Should -BeLike '*no membership change*'
    }

    It 'reports one finding when both evaluation types are slow' {
        $data = New-HygEvalData `
            -Full @(New-HygEvalRow -CollectionID 'MCM00E04' -Name 'Both' -LengthMs 8000) `
            -Incremental @(New-HygEvalRow -CollectionID 'MCM00E04' -Name 'Both' -LengthMs 6000)
        $f = @(Test-HygCollectionEvaluationRunTime -Data $data)
        $f.Count | Should -Be 1
        $f[0].Evidence | Should -BeLike '*full evaluation*incremental evaluation*'
    }

    It 'honors a custom threshold' {
        $data = New-HygEvalData -Full @(New-HygEvalRow -CollectionID 'MCM00E05' -Name 'Medium' -LengthMs 3000)
        $t = Get-HygieneDefaultThresholds; $t.ColEvalSlowMs = 2000
        @(Test-HygCollectionEvaluationRunTime -Data $data -Thresholds $t).Count | Should -Be 1
        @(Test-HygCollectionEvaluationRunTime -Data $data).Count | Should -Be 0
    }

    It 'is skipped, not run empty, when the timing classes are unavailable' {
        $data = New-HygEvalData
        $data.FailedDatasets = @('CollectionEvalFull', 'CollectionEvalIncremental')
        $f = @(Invoke-HygieneScan -Data $data -Scopes 'Collections')
        @($f | Where-Object { $_.CheckId -eq 'COL-04' -and $_.Category -eq 'Scan' }).Count | Should -Be 1
    }
}

Describe 'Deployment targeting and disabled objects' {
    It 'DPL-04 flags a required deployment to All Systems and ignores an available one' {
        $data = New-HygData -Deployments @(
            (New-HygDeployment -SoftwareName 'Agent' -CollectionID 'SMS00001' -DeploymentIntent 1),
            (New-HygDeployment -SoftwareName 'Optional tool' -CollectionID 'SMS00001' -DeploymentIntent 2),
            (New-HygDeployment -SoftwareName 'Scoped' -CollectionID 'MCM00011' -DeploymentIntent 1),
            (New-HygDeployment -SoftwareName 'Portal' -CollectionID 'SMS00004' -CollectionName 'All Users and User Groups' -DeploymentIntent 1),
            (New-HygDeployment -SoftwareName 'Lookalike' -CollectionID 'MCM00012' -CollectionName 'All Users' -DeploymentIntent 1),
            (New-HygDeployment -SoftwareName 'Bare metal' -CollectionID 'SMS000US' -CollectionName 'All Unknown Computers' -DeploymentIntent 1),
            (New-HygDeployment -SoftwareName 'Client patch' -CollectionID 'SMSDM003' -CollectionName 'All Desktop and Server Clients' -DeploymentIntent 1)
        )
        $f = @(Test-HygDeploymentBroadRequired -Data $data)
        $f.Count | Should -Be 3
        $f[2].ObjectName | Should -Be 'Client patch -> All Desktop and Server Clients'
        $f[0].ObjectName | Should -Be 'Agent -> All Systems'
        $f[1].ObjectName | Should -Be 'Portal -> All Users and User Groups'
    }

    It 'DPL-05 flags a deployed task sequence and a deployed program that are disabled' {
        $deployTs  = New-HygDeployment -SoftwareName 'Build' -PackageID 'MCM000T1' -FeatureType 7
        $deployPrg = New-HygDeployment -SoftwareName 'Legacy' -PackageID 'MCM000P1' -FeatureType 2
        $deployPrg | Add-Member -NotePropertyName ProgramName -NotePropertyValue 'Install'
        $deployOk  = New-HygDeployment -SoftwareName 'Healthy' -PackageID 'MCM000T2' -FeatureType 7
        $data = New-HygData -Deployments @($deployTs, $deployPrg, $deployOk) `
            -TaskSequences @(
                [pscustomobject]@{ PackageID = 'MCM000T1'; Name = 'Build'; ReferencedIDs = @(); BootImageID = ''; ProgramFlags = 0x1000 },
                [pscustomobject]@{ PackageID = 'MCM000T2'; Name = 'Healthy'; ReferencedIDs = @(); BootImageID = ''; ProgramFlags = 0 }) `
            -Programs @([pscustomobject]@{ PackageID = 'MCM000P1'; ProgramName = 'Install'; ProgramFlags = (0x1000 -bor 0x2000) })
        $f = @(Test-HygDeployedDisabledObject -Data $data)
        $f.Count | Should -Be 2
        ($f.Evidence -join ' ') | Should -BeLike "*task sequence 'Build'*program 'Install'*"
    }
}

Describe 'Update group size and expired package content' {
    It 'UPD-04 flags only groups over the limit' {
        $data = New-HygData -UpdateGroups @(
            [pscustomobject]@{ Name = 'Everything'; CI_ID = 1; NumberOfUpdates = 1400; NumberOfExpiredUpdates = 0; ContainsSupersededUpdates = $false },
            [pscustomobject]@{ Name = 'Monthly'; CI_ID = 2; NumberOfUpdates = 1000; NumberOfExpiredUpdates = 0; ContainsSupersededUpdates = $false })
        $f = @(Test-HygUpdateGroupSize -Data $data)
        $f.Count | Should -Be 1
        $f[0].ObjectName | Should -Be 'Everything'
    }

    It 'UPD-05 counts expired content per package' {
        $data = New-HygData -UpdatePackages @([pscustomobject]@{ PackageID = 'MCM000U1'; Name = 'Patches 2024' }, [pscustomobject]@{ PackageID = 'MCM000U2'; Name = 'Clean' })
        $data | Add-Member -NotePropertyName ExpiredUpdateIds -NotePropertyValue @(501, 502)
        $data | Add-Member -NotePropertyName UpdateContentMap -NotePropertyValue @(
            [pscustomobject]@{ CI_ID = 501; ContentID = 9001 }, [pscustomobject]@{ CI_ID = 502; ContentID = 9002 }, [pscustomobject]@{ CI_ID = 600; ContentID = 9003 })
        $data | Add-Member -NotePropertyName UpdatePackageContent -NotePropertyValue @(
            [pscustomobject]@{ PackageID = 'MCM000U1'; ContentID = 9001 }, [pscustomobject]@{ PackageID = 'MCM000U1'; ContentID = 9002 },
            [pscustomobject]@{ PackageID = 'MCM000U1'; ContentID = 9003 }, [pscustomobject]@{ PackageID = 'MCM000U2'; ContentID = 9003 })
        $f = @(Test-HygUpdatePackageExpiredContent -Data $data)
        $f.Count | Should -Be 1
        $f[0].ObjectName | Should -Be 'Patches 2024'
        $f[0].Evidence | Should -BeLike '2 of 3 content item*'
    }
}

Describe 'Distribution point, compliance, driver, security, and maintenance window checks' {
    BeforeAll {
        function Add-HygDataset { param($Data, [hashtable]$Sets) foreach ($k in $Sets.Keys) { $Data | Add-Member -NotePropertyName $k -NotePropertyValue $Sets[$k] -Force }; $Data }
    }

    It 'DPT-01 and DPT-02 flag an ungrouped distribution point and an empty group' {
        $data = Add-HygDataset (New-HygData) @{
            DistributionPoints       = @([pscustomobject]@{ NALPath = '["Display=\\dp1\"]MSWNET:["SMS_SITE=MCM"]\\dp1\'; Name = 'dp1' }, [pscustomobject]@{ NALPath = '["Display=\\dp2\"]MSWNET:["SMS_SITE=MCM"]\\dp2\'; Name = 'dp2' })
            BoundaryGroupSiteSystems = @('["Display=\\dp1\"]MSWNET:["SMS_SITE=MCM"]\\dp1\')
            DistributionPointGroups  = @([pscustomobject]@{ GroupID = 'g1'; Name = 'Empty'; MembersCount = 0; AssignedContentCount = 4 }, [pscustomobject]@{ GroupID = 'g2'; Name = 'Full'; MembersCount = 3; AssignedContentCount = 4 })
        }
        $f = @(Test-HygDistributionPointChecks -Data $data)
        ($f | Where-Object CheckId -eq 'DPT-01').ObjectName | Should -Be 'dp2'
        ($f | Where-Object CheckId -eq 'DPT-02').ObjectName | Should -Be 'Empty'
        $f.Count | Should -Be 2
    }

    It 'CFG checks skip a baseline that another baseline references' {
        $data = Add-HygDataset (New-HygData) @{
            Baselines          = @([pscustomobject]@{ CI_ID = 1; Name = 'Orphan'; IsAssigned = $false; InUse = $false; IsUserDefined = $true }, [pscustomobject]@{ CI_ID = 4; Name = 'Shipped baseline'; IsAssigned = $false; InUse = $false; IsUserDefined = $false }, [pscustomobject]@{ CI_ID = 2; Name = 'Child'; IsAssigned = $false; InUse = $true; IsUserDefined = $true }, [pscustomobject]@{ CI_ID = 3; Name = 'Live'; IsAssigned = $true; InUse = $false; IsUserDefined = $true })
            ConfigurationItems = @([pscustomobject]@{ CI_ID = 10; Name = 'Loose item'; InUse = $false; IsUserDefined = $true }, [pscustomobject]@{ CI_ID = 12; Name = 'Built-In'; InUse = $false; IsUserDefined = $false }, [pscustomobject]@{ CI_ID = 11; Name = 'Used item'; InUse = $true; IsUserDefined = $true })
            ClientSettings     = @([pscustomobject]@{ SettingsID = 5; Name = 'Unassigned'; AssignmentCount = 0 }, [pscustomobject]@{ SettingsID = 6; Name = 'Assigned'; AssignmentCount = 2 })
        }
        $f = @(Test-HygComplianceChecks -Data $data)
        ($f | Sort-Object CheckId).ObjectName -join ',' | Should -Be 'Orphan,Loose item,Unassigned'
    }

    It 'DRV-01 flags only drivers outside every package and boot image' {
        $data = Add-HygDataset (New-HygData) @{
            Drivers            = @([pscustomobject]@{ CI_ID = 70; Name = 'Packaged NIC' }, [pscustomobject]@{ CI_ID = 71; Name = 'Loose NIC' })
            DriverContainerIds = @(70)
        }
        $f = @(Test-HygDriverUnpackaged -Data $data)
        $f.Count | Should -Be 1
        $f[0].ObjectName | Should -Be 'Loose NIC'
    }

    It 'SEC-01 flags only administrative users the site marks deleted' {
        $data = Add-HygDataset (New-HygData) @{
            AdminUsers = @([pscustomobject]@{ AdminID = 1; LogonName = 'CONTOSO\gone'; IsDeleted = $true; RoleNames = @('Full Administrator') }, [pscustomobject]@{ AdminID = 2; LogonName = 'CONTOSO\here'; IsDeleted = $false; RoleNames = @() })
        }
        $f = @(Test-HygAdminDeletedAccount -Data $data)
        $f.Count | Should -Be 1
        $f[0].Evidence | Should -BeLike '*Full Administrator*'
    }

    It 'COL-10 flags an ended one-time window and ignores recurring and future windows' {
        $data = Add-HygDataset (New-HygData -Collections @(New-HygCollection -CollectionID 'MCM000W1' -Name 'Servers')) @{
            MaintenanceWindows = @(
                [pscustomobject]@{ CollectionID = 'MCM000W1'; Name = 'Migration night'; RecurrenceType = 1; StartTime = (Get-Date).AddDays(-40); Duration = 240; IsEnabled = $true },
                [pscustomobject]@{ CollectionID = 'MCM000W1'; Name = 'Weekly'; RecurrenceType = 3; StartTime = (Get-Date).AddDays(-400); Duration = 240; IsEnabled = $true },
                [pscustomobject]@{ CollectionID = 'MCM000W1'; Name = 'Next month'; RecurrenceType = 1; StartTime = (Get-Date).AddDays(20); Duration = 240; IsEnabled = $true })
        }
        $f = @(Test-HygMaintenanceWindowExpired -Data $data)
        $f.Count | Should -Be 1
        $f[0].ObjectName | Should -Be 'Migration night on Servers'
        Test-HygieneFixExecutable -FixScript $f[0].FixScript | Should -BeTrue
    }

    It 'maps the new scopes to their own datasets only' {
        (@(Get-HygieneRequiredDataset -Scopes 'Security') -join ',') | Should -Be 'AdminUsers'
        (@(Get-HygieneRequiredDataset -Scopes 'Drivers') -join ',') | Should -Be 'DriverContainerIds,Drivers'
        @(Get-HygieneRequiredDataset -Scopes 'MaintenanceWindows') | Should -Contain 'MaintenanceWindows'
    }

    It 'reads maintenance windows only for collections that have settings' {
        $stubs = 'Invoke-CMWmiQuery','Get-CMMaintenanceWindow'
        foreach ($s in $stubs) { Set-Item -Path "function:global:$s" -Value { [CmdletBinding()] param($Query, $Option, $CollectionId) } }
        try {
            Mock -ModuleName SiteHygieneCommon Invoke-CMWmiQuery { }
            Mock -ModuleName SiteHygieneCommon Invoke-CMWmiQuery { [pscustomobject]@{ CollectionID = 'MCM000W1' }; [pscustomobject]@{ CollectionID = 'MCM000W2' } } -ParameterFilter { $Query -like '*SMS_CollectionSettings' }
            Mock -ModuleName SiteHygieneCommon Get-CMMaintenanceWindow { [pscustomobject]@{ Name = 'W'; RecurrenceType = 1; StartTime = (Get-Date).AddDays(-5); Duration = 60; IsEnabled = $true } }
            $data = Get-HygieneData -Datasets 'MaintenanceWindows'
            Should -Invoke -ModuleName SiteHygieneCommon Get-CMMaintenanceWindow -Times 2 -Exactly
            @($data.MaintenanceWindows).Count | Should -Be 2
            $data.NotCollectedDatasets | Should -Contain 'Collections'
        }
        finally { foreach ($s in $stubs) { Remove-Item -Path "function:global:$s" -ErrorAction SilentlyContinue } }
    }

    It 'reads devices with one six-column query against the All Systems member class' {
        $stubs = 'Invoke-CMWmiQuery','Get-CMDevice'
        foreach ($s in $stubs) { Set-Item -Path "function:global:$s" -Value { [CmdletBinding()] param($Query, $Option, [switch]$Fast) } }
        try {
            Mock -ModuleName SiteHygieneCommon Get-CMDevice { throw 'the device cmdlet reads every column' }
            Mock -ModuleName SiteHygieneCommon Invoke-CMWmiQuery {
                [pscustomobject]@{ ResourceID = 16777219; Name = 'PC01'; IsClient = $true; ClientVersion = '5.00.9146.1009'; LastActiveTime = (Get-Date).AddDays(-2); SMBIOSGUID = 'A1' }
            } -ParameterFilter { $Query -like '*FROM SMS_CM_RES_COLL_SMS00001' }
            $data = Get-HygieneData -Datasets 'Devices'
            @($data.Devices).Count | Should -Be 1
            $data.Devices[0].ClientVersion | Should -Be '5.00.9146.1009'
            $data.Devices[0].SMBIOSGUID | Should -Be 'A1'
            Should -Invoke -ModuleName SiteHygieneCommon Invoke-CMWmiQuery -Times 1 -Exactly -ParameterFilter { $Option -eq 'Fast' -and $Query -notmatch 'SELECT\s+\*' }
        }
        finally { foreach ($s in $stubs) { Remove-Item -Path "function:global:$s" -ErrorAction SilentlyContinue } }
    }

    It 'reads task sequence references with one query and no per-sequence read' {
        $stubs = 'Invoke-CMWmiQuery','Get-CMTaskSequence'
        foreach ($s in $stubs) { Set-Item -Path "function:global:$s" -Value { [CmdletBinding()] param($Query, $Option, [switch]$Fast) } }
        try {
            Mock -ModuleName SiteHygieneCommon Invoke-CMWmiQuery {
                [pscustomobject]@{ PackageID = 'MCM00008'; ObjectID = 'MCM00004' }
                [pscustomobject]@{ PackageID = 'MCM00008'; ObjectID = 'ScopeId_X/Application_Y' }
            } -ParameterFilter { $Query -like '*SMS_TaskSequencePackageReference_All' }
            Mock -ModuleName SiteHygieneCommon Get-CMTaskSequence {
                [pscustomobject]@{ PackageID = 'MCM00008'; Name = 'Build'; BootImageID = 'MCM00006'; ProgramFlags = 0 }
                [pscustomobject]@{ PackageID = 'MCM00009'; Name = 'Empty'; BootImageID = ''; ProgramFlags = 0 }
            }
            $data = Get-HygieneData -Datasets 'TaskSequences'
            $build = $data.TaskSequences | Where-Object PackageID -eq 'MCM00008'
            ($build.ReferencedIDs -join ',') | Should -Be 'MCM00004,ScopeId_X/Application_Y'
            $build.BootImageID | Should -Be 'MCM00006'
            @(($data.TaskSequences | Where-Object PackageID -eq 'MCM00009').ReferencedIDs).Count | Should -Be 0
            Should -Invoke -ModuleName SiteHygieneCommon Get-CMTaskSequence -Times 1 -Exactly -ParameterFilter { $Fast }
        }
        finally { foreach ($s in $stubs) { Remove-Item -Path "function:global:$s" -ErrorAction SilentlyContinue } }
    }

    It 'fails the task sequence dataset when the reference query fails' {
        $stubs = 'Invoke-CMWmiQuery','Get-CMTaskSequence'
        foreach ($s in $stubs) { Set-Item -Path "function:global:$s" -Value { [CmdletBinding()] param($Query, $Option, [switch]$Fast) } }
        try {
            Mock -ModuleName SiteHygieneCommon Invoke-CMWmiQuery { throw 'Invalid class' }
            Mock -ModuleName SiteHygieneCommon Get-CMTaskSequence { [pscustomobject]@{ PackageID = 'MCM00008'; Name = 'Build'; BootImageID = ''; ProgramFlags = 0 } }
            $data = Get-HygieneData -Datasets 'TaskSequences'
            $data.FailedDatasets | Should -Contain 'TaskSequences'
            @($data.TaskSequences).Count | Should -Be 0
        }
        finally { foreach ($s in $stubs) { Remove-Item -Path "function:global:$s" -ErrorAction SilentlyContinue } }
    }
}

Describe 'APP-05 old application revisions' {
    BeforeAll {
        function New-HygRevisionData {
            param([object[]]$Applications = @(), [object[]]$AppRevisions = @())
            $data = New-HygData -Applications $Applications
            $data | Add-Member -NotePropertyName AppRevisions -NotePropertyValue $AppRevisions -PassThru
        }
    }

    It 'flags a deployed application once and lists every old revision' {
        $app = New-HygApp -CI_ID 501 -Name '7-Zip' -ModelName 'ScopeId_X/Application_7zip' -IsDeployed $true
        $data = New-HygRevisionData -Applications @($app) -AppRevisions @(
            [pscustomobject]@{ CI_ID = 480; ModelName = 'ScopeId_X/Application_7zip'; Revision = 2 },
            [pscustomobject]@{ CI_ID = 470; ModelName = 'ScopeId_X/Application_7zip'; Revision = 1 })
        $f = @(Test-HygAppOldRevisions -Data $data)
        $f.Count | Should -Be 1
        $f[0].CheckId | Should -Be 'APP-05'
        $f[0].Evidence | Should -BeLike '*2 old revision(s): 1, 2*'
        $f[0].FixScript | Should -BeLike '*Remove-CMApplicationRevisionHistory -Id 501 -Revision 1 -Force*'
        $f[0].FixScript | Should -BeLike '*Remove-CMApplicationRevisionHistory -Id 501 -Revision 2 -Force*'
        Test-HygieneFixExecutable -FixScript $f[0].FixScript | Should -BeTrue
    }

    It 'flags an application that is not deployed and ignores an application with one revision' {
        $idle = New-HygApp -CI_ID 502 -Name 'Idle' -ModelName 'ScopeId_X/Application_idle' -IsDeployed $false
        $single = New-HygApp -CI_ID 503 -Name 'Single' -ModelName 'ScopeId_X/Application_single' -IsDeployed $true
        $data = New-HygRevisionData -Applications @($idle, $single) -AppRevisions @(
            [pscustomobject]@{ CI_ID = 460; ModelName = 'ScopeId_X/Application_idle'; Revision = 3 },
            [pscustomobject]@{ CI_ID = 461; ModelName = 'ScopeId_X/Application_idle'; Revision = 4 })
        $f = @(Test-HygAppOldRevisions -Data $data)
        $f.Count | Should -Be 1
        $f[0].ObjectName | Should -Be 'Idle'
        $f[0].Evidence | Should -BeLike '*2 old revision(s): 3, 4*'
    }
    It 'is skipped by the runner when the revision query failed' {
        $app = New-HygApp -CI_ID 501 -Name '7-Zip' -ModelName 'ScopeId_X/Application_7zip' -IsDeployed $true
        $data = New-HygRevisionData -Applications @($app)
        $data.FailedDatasets = @('AppRevisions')
        $f = @(Invoke-HygieneScan -Data $data -Scopes 'Applications')
        @($f | Where-Object { $_.CheckId -eq 'APP-05' -and $_.Category -eq 'Scan' }).Count | Should -Be 1
    }

    It 'reads old revisions with one query that excludes the current revision' {
        $stubs = 'Invoke-CMWmiQuery'
        foreach ($s in $stubs) { Set-Item -Path "function:global:$s" -Value { [CmdletBinding()] param($Query, $Option) } }
        try {
            Mock -ModuleName SiteHygieneCommon Invoke-CMWmiQuery { [pscustomobject]@{ CI_ID = 470; ModelName = 'ScopeId_X/Application_7zip'; CIVersion = 1 } }
            $data = Get-HygieneData -Datasets 'AppRevisions'
            @($data.AppRevisions).Count | Should -Be 1
            $data.AppRevisions[0].Revision | Should -Be 1
            Should -Invoke -ModuleName SiteHygieneCommon Invoke-CMWmiQuery -Times 1 -Exactly -ParameterFilter { $Option -eq 'Fast' -and $Query -like '*FROM SMS_Application WHERE IsLatest = 0' }
        }
        finally { foreach ($s in $stubs) { Remove-Item -Path "function:global:$s" -ErrorAction SilentlyContinue } }
    }
}

Describe 'Task sequence application checks (TSQ-03, TSQ-04)' {
    BeforeAll {
        function New-HygTsAppData {
            param([object[]]$Applications, [object[]]$TaskSequences, [object[]]$TsAppDefinitions = @(), [object[]]$ContentStatus = @(), [object[]]$AppRevisions = @())
            $data = New-HygData -Applications $Applications -TaskSequences $TaskSequences
            $data | Add-Member -NotePropertyName TsAppDefinitions -NotePropertyValue $TsAppDefinitions
            $data | Add-Member -NotePropertyName ContentStatus -NotePropertyValue $ContentStatus
            $data | Add-Member -NotePropertyName AppRevisions -NotePropertyValue $AppRevisions -PassThru
        }
        function New-HygTs { param([string]$Name, [string[]]$Refs) [pscustomobject]@{ PackageID = 'MCM00008'; Name = $Name; ReferencedIDs = $Refs; BootImageID = ''; ProgramFlags = 0 } }
        function New-HygContent { param([string]$Model, [int]$Targeted, [long]$SourceSize = 1960) [pscustomobject]@{ ObjectID = $Model; PackageID = 'MCM00036'; Name = 'x'; ObjectType = 512; Targeted = $Targeted; NumberSuccess = 0; NumberInProgress = 0; NumberErrors = 0; NumberUnknown = 0; SourceSize = $SourceSize; LastUpdateDate = (Get-Date) } }
    }

    It 'TSQ-03 flags only a task sequence application without the install setting' {
        $a = New-HygApp -CI_ID 701 -Name '7-Zip' -ModelName 'ScopeId_X/Application_7zip'
        $b = New-HygApp -CI_ID 702 -Name 'Reader' -ModelName 'ScopeId_X/Application_reader'
        $data = New-HygTsAppData -Applications @($a, $b) -TaskSequences @(New-HygTs -Name 'Build Win11' -Refs @('ScopeId_X/Application_7zip', 'ScopeId_X/Application_reader', 'MCM00004')) `
            -TsAppDefinitions @([pscustomobject]@{ ModelName = 'ScopeId_X/Application_7zip'; AutoInstall = $false }, [pscustomobject]@{ ModelName = 'ScopeId_X/Application_reader'; AutoInstall = $true })
        $f = @(Test-HygTaskSequenceApplications -Data $data)
        $f.Count | Should -Be 1
        $f[0].CheckId | Should -Be 'TSQ-03'
        $f[0].ObjectName | Should -Be '7-Zip'
        $f[0].Evidence | Should -BeLike "*'Build Win11'*"
        $f[0].FixScript | Should -BeLike "*Set-CMApplication -AutoInstall `$true"
    }

    It 'TSQ-04 flags a task sequence application with source files and no distribution point' {
        $a = New-HygApp -CI_ID 701 -Name '7-Zip' -ModelName 'ScopeId_X/Application_7zip'
        $b = New-HygApp -CI_ID 702 -Name 'Reader' -ModelName 'ScopeId_X/Application_reader'
        $c = New-HygApp -CI_ID 703 -Name 'Not in a task sequence' -ModelName 'ScopeId_X/Application_other'
        $data = New-HygTsAppData -Applications @($a, $b, $c) -TaskSequences @(New-HygTs -Name 'Build Win11' -Refs @('ScopeId_X/Application_7zip', 'ScopeId_X/Application_reader')) `
            -ContentStatus @((New-HygContent -Model 'ScopeId_X/Application_7zip' -Targeted 0), (New-HygContent -Model 'ScopeId_X/Application_reader' -Targeted 3), (New-HygContent -Model 'ScopeId_X/Application_other' -Targeted 0))
        $f = @(Test-HygTaskSequenceApplications -Data $data | Where-Object CheckId -eq 'TSQ-04')
        $f.Count | Should -Be 1
        $f[0].ObjectName | Should -Be '7-Zip'
        $f[0].Severity | Should -Be 'Error'
    }

    It 'reads one definition per task sequence application and parses the install setting' {
        $stubs = 'Invoke-CMWmiQuery','Get-CMTaskSequence','Get-CMApplication'
        foreach ($s in $stubs) { Set-Item -Path "function:global:$s" -Value { [CmdletBinding()] param($Query, $Option, $ModelName, [switch]$Fast) } }
        try {
            $d = 'http://schemas.microsoft.com/SystemCenterConfigurationManager/2009/AppMgmtDigest'
            Mock -ModuleName SiteHygieneCommon Invoke-CMWmiQuery {
                [pscustomobject]@{ PackageID = 'MCM00008'; ObjectID = 'ScopeId_X/Application_on' }
                [pscustomobject]@{ PackageID = 'MCM00008'; ObjectID = 'ScopeId_X/Application_off' }
                [pscustomobject]@{ PackageID = 'MCM00008'; ObjectID = 'MCM00004' }
            } -ParameterFilter { $Query -like '*SMS_TaskSequencePackageReference_All' }
            Mock -ModuleName SiteHygieneCommon Get-CMTaskSequence { [pscustomobject]@{ PackageID = 'MCM00008'; Name = 'Build'; BootImageID = ''; ProgramFlags = 0 } }
            Mock -ModuleName SiteHygieneCommon Get-CMApplication { [pscustomobject]@{ SDMPackageXML = "<AppMgmtDigest xmlns='$d'><Application><AutoInstall>true</AutoInstall></Application></AppMgmtDigest>" } } -ParameterFilter { $ModelName -eq 'ScopeId_X/Application_on' }
            Mock -ModuleName SiteHygieneCommon Get-CMApplication { [pscustomobject]@{ SDMPackageXML = "<AppMgmtDigest xmlns='$d'><Application><Title>x</Title></Application></AppMgmtDigest>" } } -ParameterFilter { $ModelName -eq 'ScopeId_X/Application_off' }
            $data = Get-HygieneData -Datasets 'TsAppDefinitions'
            @($data.TsAppDefinitions).Count | Should -Be 2
            ($data.TsAppDefinitions | Where-Object ModelName -like '*_on').AutoInstall | Should -BeTrue
            ($data.TsAppDefinitions | Where-Object ModelName -like '*_off').AutoInstall | Should -BeFalse
            Should -Invoke -ModuleName SiteHygieneCommon Get-CMApplication -Times 2 -Exactly
        }
        finally { foreach ($s in $stubs) { Remove-Item -Path "function:global:$s" -ErrorAction SilentlyContinue } }
    }
}

Describe 'Finding key across application revisions' {
    It 'keeps the same key when an edit gives the application a new CI_ID' {
        $model = 'ScopeId_X/Application_7zip'
        $scan = {
            param([int]$CiId)
            $app = New-HygApp -CI_ID $CiId -Name '7-Zip' -ModelName $model -IsDeployed $true -IsExpired $true
            $data = New-HygData -Applications @($app)
            $data | Add-Member -NotePropertyName AppRevisions -NotePropertyValue @([pscustomobject]@{ CI_ID = 1; ModelName = $model; Revision = 1 })
            @(@(Test-HygAppRetiredDeployed -Data $data) + @(Test-HygAppOldRevisions -Data $data))
        }
        $first  = & $scan 16779183
        $second = & $scan 16779240
        $first.Count | Should -Be 2
        ($first | ForEach-Object { Get-HygieneSuppressionKey -Finding $_ }) | Should -Be ($second | ForEach-Object { Get-HygieneSuppressionKey -Finding $_ })
        $delta = Get-HygieneScanDelta -Findings $second -Previous ([pscustomobject]@{ Findings = $first })
        $delta.NewKeys.Count | Should -Be 0
        @($delta.Resolved).Count | Should -Be 0
        ($second | Where-Object CheckId -eq 'APP-05').FixScript | Should -BeLike '*-Id 16779240 -Revision 1*'
    }
}

Describe 'Provider pacing' {
    BeforeAll {
        $stubs = 'Invoke-CMWmiQuery','Get-CMCollection'
        foreach ($s in $stubs) { Set-Item -Path "function:global:$s" -Value { [CmdletBinding()] param($Query, $Option, $Id, [switch]$Fast) } }
    }
    AfterAll {
        foreach ($s in $stubs) { Remove-Item -Path "function:global:$s" -ErrorAction SilentlyContinue }
    }
    BeforeEach {
        Mock -ModuleName SiteHygieneCommon Start-Sleep { }
        Mock -ModuleName SiteHygieneCommon Invoke-CMWmiQuery { }
        Mock -ModuleName SiteHygieneCommon Invoke-CMWmiQuery {
            [pscustomobject]@{ CollectionID = 'MCM00002'; Name = 'Scheduled'; MemberCount = 1; RefreshType = 2; LimitToCollectionID = 'SMS00001' }
            [pscustomobject]@{ CollectionID = 'MCM00003'; Name = 'Scheduled too'; MemberCount = 1; RefreshType = 6; LimitToCollectionID = 'SMS00001' }
        } -ParameterFilter { $Query -like '*FROM SMS_Collection' }
        Mock -ModuleName SiteHygieneCommon Get-CMCollection { [pscustomobject]@{ CollectionRules = @(); RefreshSchedule = @() } }
    }

    It 'sends calls back to back by default' {
        $null = Get-HygieneData -Datasets 'CollectionDetails'
        Should -Invoke -ModuleName SiteHygieneCommon Start-Sleep -Times 0
        Should -Invoke -ModuleName SiteHygieneCommon Get-CMCollection -Times 2 -Exactly
    }

    It 'pauses before every provider call after the first when a pace is set' {
        # Three datasets plus two per-collection reads: five calls, four pauses.
        $null = Get-HygieneData -Datasets 'CollectionDetails' -PacingMs 250
        Should -Invoke -ModuleName SiteHygieneCommon Start-Sleep -Times 4 -Exactly -ParameterFilter { $Milliseconds -eq 250 }
    }
}

Describe 'Task sequence application definitions from the relationship pass' {
    BeforeAll {
        $stubs = 'Invoke-CMWmiQuery','Get-CMTaskSequence','Get-CMApplication'
        foreach ($s in $stubs) { Set-Item -Path "function:global:$s" -Value { [CmdletBinding()] param($Query, $Option, $ModelName, [switch]$Fast) } }
        $d = 'http://schemas.microsoft.com/SystemCenterConfigurationManager/2009/AppMgmtDigest'
    }
    AfterAll {
        foreach ($s in $stubs) { Remove-Item -Path "function:global:$s" -ErrorAction SilentlyContinue }
    }
    BeforeEach {
        Mock -ModuleName SiteHygieneCommon Invoke-CMWmiQuery { }
        Mock -ModuleName SiteHygieneCommon Invoke-CMWmiQuery {
            [pscustomobject]@{ PackageID = 'MCM00008'; ObjectID = 'ScopeId_X/Application_on' }
            [pscustomobject]@{ PackageID = 'MCM00008'; ObjectID = 'ScopeId_X/Application_off' }
        } -ParameterFilter { $Query -like '*SMS_TaskSequencePackageReference_All' }
        Mock -ModuleName SiteHygieneCommon Get-CMTaskSequence { [pscustomobject]@{ PackageID = 'MCM00008'; Name = 'Build'; BootImageID = ''; ProgramFlags = 0 } }
        Mock -ModuleName SiteHygieneCommon Get-CMApplication { [pscustomobject]@{ SDMPackageXML = "<AppMgmtDigest xmlns='$d'><Application><Title>x</Title></Application></AppMgmtDigest>" } }
    }

    It 'reads no application the map already answers' {
        $map = @{ 'ScopeId_X/Application_on' = $true; 'ScopeId_X/Application_off' = $false }
        $data = Get-HygieneData -Datasets 'TsAppDefinitions' -AutoInstallByModel $map
        @($data.TsAppDefinitions).Count | Should -Be 2
        ($data.TsAppDefinitions | Where-Object ModelName -like '*_on').AutoInstall | Should -BeTrue
        ($data.TsAppDefinitions | Where-Object ModelName -like '*_off').AutoInstall | Should -BeFalse
        Should -Invoke -ModuleName SiteHygieneCommon Get-CMApplication -Times 0
    }

    It 'falls back to one read per application the map does not cover' {
        $map = @{ 'ScopeId_X/Application_on' = $true }
        $data = Get-HygieneData -Datasets 'TsAppDefinitions' -AutoInstallByModel $map
        @($data.TsAppDefinitions).Count | Should -Be 2
        ($data.TsAppDefinitions | Where-Object ModelName -like '*_off').AutoInstall | Should -BeFalse
        Should -Invoke -ModuleName SiteHygieneCommon Get-CMApplication -Times 1 -Exactly -ParameterFilter { $ModelName -eq 'ScopeId_X/Application_off' }
    }

    It 'reads every application when no map is supplied' {
        $data = Get-HygieneData -Datasets 'TsAppDefinitions'
        @($data.TsAppDefinitions).Count | Should -Be 2
        Should -Invoke -ModuleName SiteHygieneCommon Get-CMApplication -Times 2 -Exactly
    }

    It 'parses the install setting out of the relationship XML' {
        $xmlOn  = "<AppMgmtDigest xmlns='$d'><Application><AutoInstall>true</AutoInstall></Application><DeploymentType><Title>I</Title></DeploymentType></AppMgmtDigest>"
        $xmlOff = "<AppMgmtDigest xmlns='$d'><Application><Title>x</Title></Application><DeploymentType><Title>I</Title></DeploymentType></AppMgmtDigest>"
        $parsed = ConvertTo-HygRelationships -Applications @(
            (New-HygRelApp -CI_ID 1 -Name 'On'  -Model 'S/ON'  -Xml $xmlOn),
            (New-HygRelApp -CI_ID 2 -Name 'Off' -Model 'S/OFF' -Xml $xmlOff),
            (New-HygRelApp -CI_ID 3 -Name 'NoXml' -Model 'S/NONE')
        )
        $parsed.AutoInstallByModel['S/ON']  | Should -BeTrue
        $parsed.AutoInstallByModel['S/OFF'] | Should -BeFalse
        $parsed.AutoInstallByModel.ContainsKey('S/NONE') | Should -BeFalse
    }
}

Describe 'Get-HygRelationshipInventory' {
    It 'lists healthy and broken rows with the status the checks assign' {
        $rel = New-HygRelData -Apps @(
            (New-HygRelApp -CI_ID 1 -Name 'New' -Model 'S/A' -IsSuperseding $true -Xml (New-HygAppXml -SupersedesModels @('S/B'))),
            (New-HygRelApp -CI_ID 2 -Name 'Mid' -Model 'S/B' -IsSuperseding $true -Xml (New-HygAppXml -SupersedesModels @('S/C', 'S/GONE'))),
            (New-HygRelApp -CI_ID 3 -Name 'Old' -Model 'S/C' -IsExpired $true),
            (New-HygRelApp -CI_ID 4 -Name 'Parent' -Model 'S/P' -Xml (New-HygAppXml -Dependencies @(
                @{ Model = 'S/A'; State = 'Required' },
                @{ Model = 'S/D'; State = 'Optional' }
            ))),
            (New-HygRelApp -CI_ID 5 -Name 'NoContent' -Model 'S/D' -HasContent $false)
        )
        $rows = @(Get-HygRelationshipInventory -RelationshipData $rel)
        $rows.Count | Should -Be 5

        $newToMid = $rows | Where-Object { $_.Kind -eq 'Supersedence' -and $_.SourceName -eq 'New' }
        $newToMid.Status | Should -Be 'Healthy'
        $newToMid.ChainDepth | Should -Be 1
        $newToMid.TargetVersion | Should -Be '1.0'

        ($rows | Where-Object { $_.SourceName -eq 'Mid' -and $_.TargetName -eq 'Old' }).Status | Should -Be 'Expired Target'
        ($rows | Where-Object { $_.SourceName -eq 'Mid' -and $_.TargetName -like 'Unknown*' }).Status | Should -Be 'Orphaned'

        $depRequired = $rows | Where-Object { $_.Kind -eq 'Dependency' -and $_.TargetName -eq 'New' }
        $depRequired.Status | Should -Be 'Healthy'
        $depRequired.DependencyState | Should -Be 'Required'
        ($rows | Where-Object { $_.Kind -eq 'Dependency' -and $_.TargetName -eq 'NoContent' }).Status | Should -Be 'Missing Content'
    }

    It 'marks both edges of a loop Circular and stops the chain depth at the loop' {
        $rel = New-HygRelData -Apps @(
            (New-HygRelApp -CI_ID 1 -Name 'A' -Model 'S/A' -IsSuperseding $true -Xml (New-HygAppXml -SupersedesModels @('S/B'))),
            (New-HygRelApp -CI_ID 2 -Name 'B' -Model 'S/B' -IsSuperseding $true -Xml (New-HygAppXml -SupersedesModels @('S/A')))
        )
        $rows = @(Get-HygRelationshipInventory -RelationshipData $rel)
        $rows.Count | Should -Be 2
        @($rows | Where-Object Status -eq 'Circular').Count | Should -Be 2
        ($rows | Where-Object SourceName -eq 'A').ChainDepth | Should -Be 1
    }

    It 'returns nothing for a site without relationships' {
        $rel = New-HygRelData -Apps @((New-HygRelApp -CI_ID 1 -Name 'Lone' -Model 'S/L'))
        @(Get-HygRelationshipInventory -RelationshipData $rel).Count | Should -Be 0
    }
}


Describe 'Import-HygieneLegacyDashboardState' {
    BeforeEach {
        $script:root = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
        $script:legacy = Join-Path $script:root 'mecm-health-dashboard'
        New-Item -ItemType Directory -Path (Join-Path $script:legacy 'History') -Force | Out-Null
        $script:prefs   = Join-Path $script:root 'site-hygiene\SiteHygiene.prefs.json'
        $script:history = Join-Path $script:root 'site-hygiene\History\metrics-history.csv'
        @{ DarkMode = $true; SiteCode = 'MCM'; SMSProvider = 'cm01'; SQLServer = 'sql01\CM'; AutoRefreshMinutes = 30; InactiveThresholdDays = 60; AlertsEnabled = $false; AlertCompliancePct = 90 } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:legacy 'MECMHealthDash.prefs.json') -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:legacy 'History\metrics-history.csv') -Value @('"Timestamp","DeploymentTotal"', '"2026-09-01T00:00:00","5"') -Encoding UTF8
    }
    AfterEach { Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'imports every Live setting and the history when the tool has neither' {
        $r = Import-HygieneLegacyDashboardState -LegacyRoot $script:legacy -PrefsPath $script:prefs -HistoryPath $script:history
        @($r.ImportedKeys) | Should -Be @('SQLServer', 'AutoRefreshMinutes', 'InactiveThresholdDays', 'AlertsEnabled', 'AlertCompliancePct')
        $r.HistoryCopied | Should -BeTrue
        $doc = Get-Content -LiteralPath $script:prefs -Raw | ConvertFrom-Json
        $doc.SQLServer | Should -Be 'sql01\CM'
        $doc.AutoRefreshMinutes | Should -Be 30
        $doc.AlertsEnabled | Should -BeFalse
        $doc.PSObject.Properties['SiteCode'] | Should -BeNullOrEmpty -Because 'the connection stays the tool''s own'
        @(Import-Csv -LiteralPath $script:history).Count | Should -Be 1
    }

    It 'keeps the tool''s own values and history and leaves the legacy files in place' {
        New-Item -ItemType Directory -Path (Split-Path $script:history -Parent) -Force | Out-Null
        @{ DarkMode = $false; SiteCode = 'XYZ'; SQLServer = 'mine' } | ConvertTo-Json | Set-Content -LiteralPath $script:prefs -Encoding UTF8
        Set-Content -LiteralPath $script:history -Value @('"Timestamp","DeploymentTotal"') -Encoding UTF8
        $r = Import-HygieneLegacyDashboardState -LegacyRoot $script:legacy -PrefsPath $script:prefs -HistoryPath $script:history
        @($r.ImportedKeys) | Should -Not -Contain 'SQLServer'
        @($r.ImportedKeys) | Should -Contain 'AutoRefreshMinutes'
        $r.HistoryCopied | Should -BeFalse
        $doc = Get-Content -LiteralPath $script:prefs -Raw | ConvertFrom-Json
        $doc.SQLServer | Should -Be 'mine'
        $doc.SiteCode | Should -Be 'XYZ'
        $doc.DarkMode | Should -BeFalse
        (Get-Content -LiteralPath $script:history).Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $script:legacy 'MECMHealthDash.prefs.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:legacy 'History\metrics-history.csv') | Should -BeTrue
    }

    It 'changes nothing on a second run' {
        $null = Import-HygieneLegacyDashboardState -LegacyRoot $script:legacy -PrefsPath $script:prefs -HistoryPath $script:history
        $before = Get-Content -LiteralPath $script:prefs -Raw
        $r = Import-HygieneLegacyDashboardState -LegacyRoot $script:legacy -PrefsPath $script:prefs -HistoryPath $script:history
        @($r.ImportedKeys).Count | Should -Be 0
        $r.HistoryCopied | Should -BeFalse
        (Get-Content -LiteralPath $script:prefs -Raw) | Should -Be $before
    }

    It 'imports nothing from a folder without dashboard files' {
        $empty = Join-Path $script:root 'nothing-here'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        $r = Import-HygieneLegacyDashboardState -LegacyRoot $empty -PrefsPath $script:prefs -HistoryPath $script:history
        @($r.ImportedKeys).Count | Should -Be 0
        Test-Path -LiteralPath $script:prefs | Should -BeFalse
    }

    It 'treats a malformed legacy preferences file as nothing to import' {
        Set-Content -LiteralPath (Join-Path $script:legacy 'MECMHealthDash.prefs.json') -Value '{not json' -Encoding UTF8
        $r = Import-HygieneLegacyDashboardState -LegacyRoot $script:legacy -PrefsPath $script:prefs -HistoryPath $script:history
        @($r.ImportedKeys).Count | Should -Be 0
        $r.HistoryCopied | Should -BeTrue
    }
}


Describe 'Get-HygRelationshipInventory loop flag' {
    It 'keeps the expired-target status on an edge that is also in a loop, and flags the loop' {
        $rel = New-HygRelData -Apps @(
            (New-HygRelApp -CI_ID 1 -Name 'A' -Model 'S/A' -IsSuperseding $true -IsExpired $true -Xml (New-HygAppXml -SupersedesModels @('S/B'))),
            (New-HygRelApp -CI_ID 2 -Name 'B' -Model 'S/B' -IsSuperseding $true -Xml (New-HygAppXml -SupersedesModels @('S/A')))
        )
        $rows = @(Get-HygRelationshipInventory -RelationshipData $rel)
        ($rows | Where-Object SourceName -eq 'B').Status | Should -Be 'Expired Target'
        ($rows | Where-Object SourceName -eq 'B').Circular | Should -BeTrue
        ($rows | Where-Object SourceName -eq 'A').Status | Should -Be 'Circular'
        @($rows | Where-Object Circular).Count | Should -Be 2
    }
}
