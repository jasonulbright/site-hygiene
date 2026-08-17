#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for the SiteHygieneCommon check engine.

.DESCRIPTION
    Every check is pure over a prefetched data object, so the whole engine
    is covered with synthetic data. No MECM, CIM, or elevation required.

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
            [string[]]$ExcludeIDs = @()
        )
        [pscustomobject]@{
            CollectionID = $CollectionID; Name = $Name; MemberCount = $MemberCount
            RefreshType = $RefreshType; LimitToCollectionID = $LimitToCollectionID
            IsBuiltIn = ($CollectionID -like 'SMS*')
            IncludeIDs = $IncludeIDs; ExcludeIDs = $ExcludeIDs
        }
    }

    function New-HygDeployment {
        param(
            [string]$SoftwareName = 'App',
            [string]$PackageID = '',
            [string]$CollectionID = 'MCM00001',
            [string]$CollectionName = 'Collection',
            [int]$DeploymentIntent = 1,
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
            DeploymentIntent = $DeploymentIntent; FeatureType = 1
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
        @(Get-HygieneCheckCatalog).Count | Should -Be 33
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
