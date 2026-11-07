#Requires -Modules Pester
# The site data prefetch (Get-HygieneData) and the relationship pass (Get-HygieneRelationshipData) with every
# ConfigMgr read mocked: what each dataset holds, what a missing property becomes, that one failing dataset does
# not stop the others, that only the requested datasets are read, and the pacing and progress behaviour.

BeforeDiscovery {
    # Cmdlet name, dataset key and the text of the note for each cmdlet-backed dataset.
    $script:CmdletDatasets = @(
        @{ Cmdlet = 'Get-CMApplication'; Key = 'Applications'; Label = 'applications' }
        @{ Cmdlet = 'Get-CMPackage'; Key = 'Packages'; Label = 'packages' }
        @{ Cmdlet = 'Get-CMProgram'; Key = 'Programs'; Label = 'programs' }
        @{ Cmdlet = 'Get-CMBoundary'; Key = 'Boundaries'; Label = 'boundaries' }
        @{ Cmdlet = 'Get-CMBoundaryGroup'; Key = 'BoundaryGroups'; Label = 'boundary groups' }
        @{ Cmdlet = 'Get-CMBootImage'; Key = 'BootImages'; Label = 'boot images' }
        @{ Cmdlet = 'Get-CMOperatingSystemImage'; Key = 'OSImages'; Label = 'OS images' }
        @{ Cmdlet = 'Get-CMOperatingSystemInstaller'; Key = 'OSUpgradePackages'; Label = 'OS upgrade packages' }
        @{ Cmdlet = 'Get-CMDriverPackage'; Key = 'DriverPackages'; Label = 'driver packages' }
        @{ Cmdlet = 'Get-CMSoftwareUpdateGroup'; Key = 'UpdateGroups'; Label = 'software update groups' }
        @{ Cmdlet = 'Get-CMSoftwareUpdateDeploymentPackage'; Key = 'UpdatePackages'; Label = 'update deployment packages' }
        @{ Cmdlet = 'Get-CMAutoDeploymentRule'; Key = 'AutoDeploymentRules'; Label = 'automatic deployment rules' }
        @{ Cmdlet = 'Get-CMSiteMaintenanceTask'; Key = 'MaintenanceTasks'; Label = 'site maintenance tasks' }
        @{ Cmdlet = 'Get-CMDeployment'; Key = 'Deployments'; Label = 'deployment summaries' }
        @{ Cmdlet = 'Get-CMConfigurationItem'; Key = 'ConfigurationItems'; Label = 'configuration items' }
    )
    # Class name, dataset key and label for each dataset that reads a WMI class.
    $script:WmiDatasets = @(
        @{ Class = 'SMS_Application'; Key = 'AppRevisions' }, @{ Class = 'SMS_CM_RES_COLL_SMS00001'; Key = 'Devices' },
        @{ Class = 'SMS_CollectionSettings'; Key = 'CollectionsWithSettings' }, @{ Class = 'SMS_AppDependenceRelation'; Key = 'DependencyTargetCIIDs' },
        @{ Class = 'SMS_CollectionDependencies'; Key = 'CollectionDependencies' }, @{ Class = 'SMS_Collection'; Key = 'Collections' },
        @{ Class = 'SMS_CollectionEvaluationFull'; Key = 'CollectionEvalFull' }, @{ Class = 'SMS_CollectionEvaluationIncremental'; Key = 'CollectionEvalIncremental' },
        @{ Class = 'SMS_ObjectContentInfo'; Key = 'ContentStatus' }, @{ Class = 'SMS_DistributionPointInfo'; Key = 'DistributionPoints' },
        @{ Class = 'SMS_BoundaryGroupSiteSystems'; Key = 'BoundaryGroupSiteSystems' }, @{ Class = 'SMS_DPGroupInfo'; Key = 'DistributionPointGroups' },
        @{ Class = 'SMS_ConfigurationBaselineInfo'; Key = 'Baselines' }, @{ Class = 'SMS_ClientSettings'; Key = 'ClientSettings' },
        @{ Class = 'SMS_Driver'; Key = 'Drivers' }, @{ Class = 'SMS_DriverContainer'; Key = 'DriverContainerIds' },
        @{ Class = 'SMS_Admin'; Key = 'AdminUsers' }, @{ Class = 'SMS_SoftwareUpdate'; Key = 'ExpiredUpdateIds' },
        @{ Class = 'SMS_CIToContent'; Key = 'UpdateContentMap' }, @{ Class = 'SMS_PackageToContent'; Key = 'UpdatePackageContent' },
        @{ Class = 'SMS_ApplicationAssignment'; Key = 'AppDeployments' }
    )
}

BeforeAll {
    . "$PSScriptRoot\TestHelpers.ps1"
    Import-AppModule
    $script:Mod = 'SiteHygieneCommon'
    $script:Stubs = New-CmStub -Name ($script:CmReadStubNames + 'Get-CMMaintenanceWindow')

    # Rows for every WMI class, keyed by class name. The mock picks the rows by the class after FROM.
    $script:WmiRows = @{
        SMS_Application                      = @([PSCustomObject]@{ CI_ID = 7; ModelName = 'ScopeId_A/Application_1'; CIVersion = 2 })
        SMS_TaskSequencePackageReference_All = @(
            [PSCustomObject]@{ PackageID = 'TS000001'; ObjectID = 'PKG00001' }
            [PSCustomObject]@{ PackageID = 'TS000001'; ObjectID = 'ScopeId_A/Application_1' }
            [PSCustomObject]@{ PackageID = 'TS000002'; ObjectID = 'ScopeId_A/Application_2' })
        SMS_CM_RES_COLL_SMS00001             = @(
            [PSCustomObject]@{ ResourceID = 1; Name = 'PC1'; IsClient = 1; ClientVersion = '5.0'; LastActiveTime = [datetime]'2026-10-01'; SMBIOSGUID = 'G1' }
            [PSCustomObject]@{ ResourceID = 2; Name = 'PC2'; IsClient = 0; ClientVersion = $null })
        SMS_CollectionSettings               = @([PSCustomObject]@{ CollectionID = 'XYZ00002' })
        SMS_AppDependenceRelation            = @([PSCustomObject]@{ ToApplicationCIID = 7 })
        SMS_CollectionDependencies           = @(
            [PSCustomObject]@{ DependentCollectionID = 'XYZ00002'; SourceCollectionID = 'XYZ00001'; RelationshipType = 2 }
            [PSCustomObject]@{ DependentCollectionID = 'XYZ00002'; SourceCollectionID = 'XYZ00003'; RelationshipType = 3 }
            [PSCustomObject]@{ DependentCollectionID = 'XYZ00002'; SourceCollectionID = 'SMS00001'; RelationshipType = 1 }
            [PSCustomObject]@{ DependentCollectionID = 'XYZ00002'; SourceCollectionID = 'XYZ00004'; RelationshipType = 9 })
        SMS_Collection                       = @(
            [PSCustomObject]@{ CollectionID = 'SMS00001'; Name = 'All Systems'; MemberCount = 9; RefreshType = 6; LimitToCollectionID = '' }
            [PSCustomObject]@{ CollectionID = 'XYZ00001'; Name = 'Manual'; MemberCount = 0; RefreshType = 1; LimitToCollectionID = 'SMS00001' }
            [PSCustomObject]@{ CollectionID = 'XYZ00002'; Name = 'Scheduled'; MemberCount = 3; RefreshType = 2; LimitToCollectionID = 'SMS00001' })
        SMS_CollectionEvaluationFull         = @([PSCustomObject]@{ CollectionID = 'XYZ00002'; CollectionName = 'Scheduled'; Length = 1200; MemberChanges = 5 })
        SMS_CollectionEvaluationIncremental  = @([PSCustomObject]@{ CollectionID = 'XYZ00002'; CollectionName = 'Scheduled'; Length = 90; MemberChanges = 1 })
        SMS_ObjectContentInfo                = @([PSCustomObject]@{ ObjectID = 'O1'; PackageID = 'PKG00001'; SoftwareName = 'Pkg'; ObjectType = 2; Targeted = 4; NumberSuccess = 3; NumberInProgress = 1; NumberErrors = 0; NumberUnknown = 0; SourceSize = 1024 })
        SMS_DistributionPointInfo            = @([PSCustomObject]@{ NALPath = '["Display=\\DP01\"]'; Name = '\\DP01.contoso.com' })
        SMS_BoundaryGroupSiteSystems         = @([PSCustomObject]@{ ServerNALPath = '["Display=\\DP01\"]' })
        SMS_DPGroupInfo                      = @([PSCustomObject]@{ GroupID = 'G1'; Name = 'All DPs'; MembersCount = 2; AssignedContentCount = 10 })
        SMS_ConfigurationBaselineInfo        = @([PSCustomObject]@{ CI_ID = 31; ModelName = 'ScopeId_A/Baseline_1'; LocalizedDisplayName = 'Base'; IsAssigned = $false; InUse = $false; IsUserDefined = $true })
        SMS_ClientSettings                   = @([PSCustomObject]@{ SettingsID = 4; Name = 'Custom'; AssignmentCount = 0 })
        SMS_Driver                           = @([PSCustomObject]@{ CI_ID = 51; LocalizedDisplayName = 'Driver' })
        SMS_DriverContainer                  = @([PSCustomObject]@{ CI_ID = 51 })
        SMS_Admin                            = @([PSCustomObject]@{ AdminID = 1; LogonName = 'CONTOSO\gone'; IsDeleted = $true; RoleNames = @('Full Administrator', $null) })
        SMS_SoftwareUpdate                   = @([PSCustomObject]@{ CI_ID = 61 })
        SMS_CIToContent                      = @([PSCustomObject]@{ CI_ID = 61; ContentID = 600 })
        SMS_PackageToContent                 = @([PSCustomObject]@{ PackageID = 'UPD00001'; ContentID = 600 })
        SMS_ApplicationAssignment            = @(
            [PSCustomObject]@{ ApplicationName = 'App'; CollectionName = 'Col'; TargetCollectionID = 'XYZ00002'; ExpirationTime = [datetime]'2026-01-01' }
            [PSCustomObject]@{ ApplicationName = 'App2'; CollectionName = 'Col'; TargetCollectionID = 'XYZ00002' })
    }
    $global:HygWmiRows = $script:WmiRows
}

AfterAll {
    Remove-CmStub -Name $script:Stubs
    Remove-Variable -Name HygWmiRows, HygFx, HygFail -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Get-HygieneData' {
    BeforeEach {
        $global:HygFail = @()
        Mock Write-Log { } -ModuleName $script:Mod
        Mock Start-Sleep { } -ModuleName $script:Mod
        Mock Invoke-CMWmiQuery {
            if ($Query -notmatch 'FROM (\w+)') { throw "unexpected query $Query" }
            $class = $Matches[1]
            if ($global:HygFail -contains $class) { throw "class $class is not available" }
            $global:HygWmiRows[$class]
        } -ModuleName $script:Mod
        $xml = "<AppMgmtDigest xmlns='http://schemas.microsoft.com/SystemCenterConfigurationManager/2009/AppMgmtDigest'><Application><AutoInstall>true</AutoInstall></Application></AppMgmtDigest>"
        $global:HygFx = $xml
        Mock Get-CMApplication {
            [PSCustomObject]@{ CI_ID = 7; ModelName = 'ScopeId_A/Application_1'; LocalizedDisplayName = 'App One'; IsDeployed = 1; IsExpired = 0; IsSuperseded = 0; IsSuperseding = 0; PackageID = 'PKG00001'; DateCreated = [datetime]'2026-01-01'; SDMPackageXML = $global:HygFx }
        } -ModuleName $script:Mod
        Mock Get-CMPackage { [PSCustomObject]@{ PackageID = 'PKG00001'; Name = 'Pkg' } } -ModuleName $script:Mod
        Mock Get-CMProgram { [PSCustomObject]@{ PackageID = 'PKG00001'; ProgramName = 'Install'; ProgramFlags = 16 } } -ModuleName $script:Mod
        Mock Get-CMTaskSequence { [PSCustomObject]@{ PackageID = 'TS000001'; Name = 'TS One'; BootImageID = 'BOOT0001'; ProgramFlags = 4 }; [PSCustomObject]@{ PackageID = 'TS000002'; Name = 'TS Two' } } -ModuleName $script:Mod
        Mock Get-CMBoundary { [PSCustomObject]@{ DisplayName = 'B1'; Value = '10.0.0.0/24'; BoundaryType = 3; GroupCount = 2 }; [PSCustomObject]@{ DisplayName = 'B2'; Value = 'x'; BoundaryType = 0 } } -ModuleName $script:Mod
        Mock Get-CMBoundaryGroup { [PSCustomObject]@{ GroupID = 1; Name = 'BG'; SiteSystemCount = 3 }; [PSCustomObject]@{ GroupID = 2; Name = 'BG2' } } -ModuleName $script:Mod
        Mock Get-CMBootImage { [PSCustomObject]@{ PackageID = 'BOOT0001'; Name = 'Boot' } } -ModuleName $script:Mod
        Mock Get-CMOperatingSystemImage { [PSCustomObject]@{ PackageID = 'IMG00001'; Name = 'Image' } } -ModuleName $script:Mod
        Mock Get-CMOperatingSystemInstaller { [PSCustomObject]@{ PackageID = 'UPG00001'; Name = 'Upgrade' } } -ModuleName $script:Mod
        Mock Get-CMDriverPackage { [PSCustomObject]@{ PackageID = 'DRV00001'; Name = 'Drivers' } } -ModuleName $script:Mod
        Mock Get-CMSoftwareUpdateGroup { [PSCustomObject]@{ LocalizedDisplayName = 'SUG'; CI_ID = 9; NumberOfUpdates = 12; NumberOfExpiredUpdates = 2; ContainsSupersededUpdates = $true }; [PSCustomObject]@{ LocalizedDisplayName = 'Bare'; CI_ID = 10 } } -ModuleName $script:Mod
        Mock Get-CMSoftwareUpdateDeploymentPackage { [PSCustomObject]@{ PackageID = 'UPD00001'; Name = 'Updates' } } -ModuleName $script:Mod
        Mock Get-CMAutoDeploymentRule { [PSCustomObject]@{ Name = 'ADR'; AutoDeploymentEnabled = $false; LastRunTime = [datetime]'2026-02-01'; LastErrorCode = 3 }; [PSCustomObject]@{ Name = 'Bare ADR' } } -ModuleName $script:Mod
        Mock Get-CMSiteMaintenanceTask { [PSCustomObject]@{ TaskName = 'Backup Site Server'; Enabled = 0 } } -ModuleName $script:Mod
        Mock Get-CMCollection {
            [PSCustomObject]@{
                CollectionRules = @([PSCustomObject]@{ SmsProviderObjectPath = 'SMS_CollectionRuleDirect' }, [PSCustomObject]@{ SmsProviderObjectPath = 'SMS_CollectionRuleQuery' }, [PSCustomObject]@{ SmsProviderObjectPath = '' }, $null)
                RefreshSchedule = @([PSCustomObject]@{ DaySpan = 1; HourSpan = 2; MinuteSpan = 3; StartTime = [datetime]'2026-01-01 03:30' })
            }
        } -ModuleName $script:Mod
        Mock Get-CMDeployment { [PSCustomObject]@{ SoftwareName = 'App'; ProgramName = '*'; PackageID = 'PKG00001'; CollectionID = 'XYZ00002'; CollectionName = 'Scheduled'; DeploymentIntent = 1; FeatureType = 1; NumberTargeted = 5; NumberSuccess = 4; NumberInProgress = 0; NumberErrors = 1 } } -ModuleName $script:Mod
        Mock Get-CMConfigurationItem { [PSCustomObject]@{ CI_ID = 41; ModelName = 'ScopeId_A/CI_1'; LocalizedDisplayName = 'CI'; InUse = $false; IsUserDefined = $true } } -ModuleName $script:Mod
        Mock Get-CMMaintenanceWindow { [PSCustomObject]@{ Name = 'MW'; RecurrenceType = 1; StartTime = [datetime]'2026-03-01'; Duration = 60; IsEnabled = $true } } -ModuleName $script:Mod
    }

    It 'reads every dataset when none is named and keeps the shape of each row' {
        $d = Get-HygieneData
        $d.FailedDatasets.Count | Should -Be 0
        $d.NotCollectedDatasets.Count | Should -Be 0
        $d.DatasetNotes.Count | Should -Be 0
        $d.Applications[0].Name | Should -Be 'App One'
        $d.Applications[0].CI_ID | Should -Be 7
        $d.Applications[0].IsDeployed | Should -BeTrue
        $d.AppRevisions[0].Revision | Should -Be 2
        $d.Packages[0].PackageID | Should -Be 'PKG00001'
        $d.Programs[0].ProgramFlags | Should -Be 16
        $d.BootImages[0].Name | Should -Be 'Boot'
        $d.OSImages[0].Name | Should -Be 'Image'
        $d.OSUpgradePackages[0].Name | Should -Be 'Upgrade'
        $d.DriverPackages[0].Name | Should -Be 'Drivers'
        $d.UpdatePackages[0].Name | Should -Be 'Updates'
        $d.MaintenanceTasks[0].TaskName | Should -Be 'Backup Site Server'
        $d.MaintenanceTasks[0].Enabled | Should -BeFalse
        $d.CollectionsWithSettings | Should -Be @('XYZ00002')
        $d.DependencyTargetCIIDs | Should -Be @(7)
        $d.CollectionEvalFull[0].LengthMs | Should -Be 1200
        $d.CollectionEvalIncremental[0].MemberChanges | Should -Be 1
        $d.ContentStatus[0].NumberInProgress | Should -Be 1
        $d.ContentStatus[0].SourceSize | Should -Be 1024
        $d.DistributionPoints[0].Name | Should -Be 'DP01.contoso.com'
        $d.BoundaryGroupSiteSystems | Should -Be @('["Display=\\DP01\"]')
        $d.DistributionPointGroups[0].AssignedContentCount | Should -Be 10
        $d.Baselines[0].IsUserDefined | Should -BeTrue
        $d.ClientSettings[0].AssignmentCount | Should -Be 0
        $d.Drivers[0].Name | Should -Be 'Driver'
        $d.DriverContainerIds | Should -Be @(51)
        $d.ExpiredUpdateIds | Should -Be @(61)
        $d.UpdateContentMap[0].ContentID | Should -Be 600
        $d.UpdatePackageContent[0].PackageID | Should -Be 'UPD00001'
        $d.ConfigurationItems[0].Name | Should -Be 'CI'
        $d.Deployments[0].NumberErrors | Should -Be 1
        $d.MaintenanceWindows[0].CollectionID | Should -Be 'XYZ00002'
        $d.MaintenanceWindows[0].Duration | Should -Be 60
        $d.CollectedAt | Should -Not -BeNullOrEmpty
    }

    It 'turns a missing optional property into a safe default' {
        $d = Get-HygieneData
        $pc2 = $d.Devices | Where-Object Name -eq 'PC2'
        $pc2.SMBIOSGUID | Should -Be ''
        $pc2.LastActiveTime | Should -BeNullOrEmpty
        $pc2.IsClient | Should -BeFalse
        ($d.Boundaries | Where-Object DisplayName -eq 'B2').GroupCount | Should -Be -1
        ($d.Boundaries | Where-Object DisplayName -eq 'B1').GroupCount | Should -Be 2
        ($d.BoundaryGroups | Where-Object Name -eq 'BG2').SiteSystemCount | Should -Be -1
        $bare = $d.UpdateGroups | Where-Object Name -eq 'Bare'
        $bare.NumberOfUpdates | Should -Be 0
        $bare.ContainsSupersededUpdates | Should -BeFalse
        $adr = $d.AutoDeploymentRules | Where-Object Name -eq 'Bare ADR'
        $adr.AutoDeploymentEnabled | Should -BeTrue
        $adr.LastErrorCode | Should -Be 0
        $adr.LastRunTime | Should -BeNullOrEmpty
        ($d.TaskSequences | Where-Object PackageID -eq 'TS000002').BootImageID | Should -Be ''
        ($d.TaskSequences | Where-Object PackageID -eq 'TS000002').ProgramFlags | Should -Be 0
        ($d.AppDeployments | Where-Object ApplicationName -eq 'App2').ExpirationTime | Should -BeNullOrEmpty
    }

    It 'joins the task sequence references from the one reference query' {
        $d = Get-HygieneData
        ($d.TaskSequences | Where-Object PackageID -eq 'TS000001').ReferencedIDs | Should -Be @('PKG00001', 'ScopeId_A/Application_1')
        ($d.TaskSequences | Where-Object PackageID -eq 'TS000002').ReferencedIDs | Should -Be @('ScopeId_A/Application_2')
    }

    It 'names the collection edges and marks built-in collections' {
        $d = Get-HygieneData
        $c2 = $d.Collections | Where-Object CollectionID -eq 'XYZ00002'
        $c2.IncludeIDs | Should -Be @('XYZ00001')
        $c2.ExcludeIDs | Should -Be @('XYZ00003')
        ($d.CollectionDependencies | Where-Object To -eq 'XYZ00004').Kind | Should -Be 'type9'
        ($d.CollectionDependencies | Where-Object To -eq 'SMS00001').Kind | Should -Be 'limit'
        ($d.Collections | Where-Object CollectionID -eq 'SMS00001').IsBuiltIn | Should -BeTrue
        $c2.IsBuiltIn | Should -BeFalse
    }

    It 'counts rule types and reads the schedule of a scheduled custom collection only' {
        $d = Get-HygieneData
        $c2 = $d.Collections | Where-Object CollectionID -eq 'XYZ00002'
        $c2.DirectRuleCount | Should -Be 1
        $c2.QueryRuleCount | Should -Be 1
        $c2.FullDaySpan | Should -Be 1
        $c2.FullHourSpan | Should -Be 2
        $c2.FullMinuteSpan | Should -Be 3
        $c2.FullStartHour | Should -Be 3
        ($d.Collections | Where-Object CollectionID -eq 'XYZ00001').FullStartHour | Should -Be -1
        Should -Invoke Get-CMCollection -ModuleName $script:Mod -Times 1 -Exactly
    }

    It 'skips a collection that no longer exists when it reads the schedules' {
        Mock Get-CMCollection { } -ModuleName $script:Mod
        $d = Get-HygieneData -Datasets 'CollectionDetails'
        $d.FailedDatasets.Count | Should -Be 0
        ($d.Collections | Where-Object CollectionID -eq 'XYZ00002').FullStartHour | Should -Be -1
    }

    It 'reads the install setting from the relationship map first and from the site for a model outside the map' {
        $d = Get-HygieneData -Datasets 'TsAppDefinitions' -AutoInstallByModel @{ 'ScopeId_A/Application_1' = $true }
        Should -Invoke Get-CMApplication -ModuleName $script:Mod -Times 1 -Exactly -ParameterFilter { $ModelName -eq 'ScopeId_A/Application_2' }
        Should -Invoke Get-CMApplication -ModuleName $script:Mod -Times 0 -Exactly -ParameterFilter { $ModelName -eq 'ScopeId_A/Application_1' }
        ($d.TsAppDefinitions | Where-Object ModelName -eq 'ScopeId_A/Application_1').AutoInstall | Should -BeTrue
        ($d.TsAppDefinitions | Where-Object ModelName -eq 'ScopeId_A/Application_2').AutoInstall | Should -BeTrue
    }

    It 'reads every referenced application from the site when no map is given, and reads false for a missing setting' {
        $global:HygFx = "<AppMgmtDigest xmlns='http://schemas.microsoft.com/SystemCenterConfigurationManager/2009/AppMgmtDigest'><Application/></AppMgmtDigest>"
        $d = Get-HygieneData -Datasets 'TsAppDefinitions'
        Should -Invoke Get-CMApplication -ModuleName $script:Mod -Times 2 -Exactly
        @($d.TsAppDefinitions | Where-Object AutoInstall).Count | Should -Be 0
    }

    It 'skips a referenced application that the site no longer has' {
        Mock Get-CMApplication { } -ModuleName $script:Mod
        $d = Get-HygieneData -Datasets 'TsAppDefinitions'
        @($d.TsAppDefinitions).Count | Should -Be 0
        $d.FailedDatasets.Count | Should -Be 0
    }

    It 'reads only the requested datasets and the datasets they depend on' {
        $d = Get-HygieneData -Datasets 'MaintenanceWindows'
        $d.NotCollectedDatasets | Should -Contain 'Applications'
        $d.NotCollectedDatasets | Should -Not -Contain 'CollectionsWithSettings'
        $d.MaintenanceWindows[0].Name | Should -Be 'MW'
        Should -Invoke Get-CMApplication -ModuleName $script:Mod -Times 0 -Exactly
        Should -Invoke Get-CMMaintenanceWindow -ModuleName $script:Mod -Times 1 -Exactly -ParameterFilter { $CollectionId -eq 'XYZ00002' }
    }

    It 'ignores a dataset name that does not exist and an empty name' {
        $d = Get-HygieneData -Datasets 'Packages', 'NoSuchDataset', ''
        $d.Packages.Count | Should -Be 1
        $d.FailedDatasets.Count | Should -Be 0
        $d.NotCollectedDatasets | Should -Not -Contain 'Packages'
    }

    It 'matches a dataset name without regard to case' {
        $d = Get-HygieneData -Datasets 'packages'
        $d.Packages.Count | Should -Be 1
    }

    It 'marks the cmdlet dataset <Key> failed and still reads <Other>' -ForEach @(
        foreach ($c in $script:CmdletDatasets | Where-Object { $_.Key -ne 'Packages' }) { @{ Cmdlet = $c.Cmdlet; Key = $c.Key; Label = $c.Label; Other = 'Packages' } }
        foreach ($c in $script:CmdletDatasets | Where-Object { $_.Key -eq 'Packages' }) { @{ Cmdlet = $c.Cmdlet; Key = $c.Key; Label = $c.Label; Other = 'Boundaries' } }
    ) {
        Mock $Cmdlet { throw 'access denied' } -ModuleName $script:Mod
        $d = Get-HygieneData -Datasets $Key, $Other
        $d.FailedDatasets | Should -Be @($Key)
        @($d.$Key).Count | Should -Be 0
        @($d.$Other).Count | Should -BeGreaterThan 0
        @($d.DatasetNotes | Where-Object { $_ -like "$Label unavailable*access denied*" }).Count | Should -Be 1
    }

    It 'marks the WMI dataset <Key> failed and still reads packages' -ForEach @(
        $script:WmiDatasets | Where-Object { $_.Key -notin 'Collections', 'CollectionDependencies' } | ForEach-Object { @{ Class = $_.Class; Key = $_.Key } }
    ) {
        $global:HygFail = @($Class)
        $d = Get-HygieneData -Datasets $Key, 'Packages'
        $d.FailedDatasets | Should -Be @($Key)
        @($d.$Key).Count | Should -Be 0
        $d.Packages.Count | Should -Be 1
        @($d.DatasetNotes | Where-Object { $_ -like '*unavailable*is not available*' }).Count | Should -Be 1
    }

    It 'reads collections without edges when only the edge query fails' {
        $global:HygFail = @('SMS_CollectionDependencies')
        $d = Get-HygieneData -Datasets 'Collections'
        $d.FailedDatasets | Should -Be @('CollectionDependencies')
        $d.Collections.Count | Should -Be 3
        @(($d.Collections | Where-Object CollectionID -eq 'XYZ00002').IncludeIDs).Count | Should -Be 0
    }

    It 'adds the failure hint of the dataset to the note' {
        $global:HygFail = @('SMS_Application')
        $d = Get-HygieneData -Datasets 'AppRevisions'
        $d.DatasetNotes[0] | Should -BeLike 'old application revisions unavailable (APP-05 is skipped): *'
    }

    It 'fails the task sequence dataset when the reference query fails, not only the references' {
        $global:HygFail = @('SMS_TaskSequencePackageReference_All')
        $d = Get-HygieneData -Datasets 'TaskSequences'
        $d.FailedDatasets | Should -Be @('TaskSequences')
        @($d.TaskSequences).Count | Should -Be 0
    }

    It 'pauses between provider calls but not before the first one' {
        $null = Get-HygieneData -Datasets 'Packages', 'Programs', 'BootImages' -PacingMs 25
        Should -Invoke Start-Sleep -ModuleName $script:Mod -Times 2 -Exactly -ParameterFilter { $Milliseconds -eq 25 }
    }

    It 'does not pause when the pacing is zero' {
        $null = Get-HygieneData -Datasets 'Packages', 'Programs'
        Should -Invoke Start-Sleep -ModuleName $script:Mod -Times 0 -Exactly
    }

    It 'rejects a pacing value outside 0 to 60000' -ForEach @(@{ Value = -1 }, @{ Value = 60001 }) {
        { Get-HygieneData -Datasets 'Packages' -PacingMs $Value } | Should -Throw
    }

    It 'reports the dataset and the position in the progress state' {
        $state = [hashtable]::Synchronized(@{ Step = '' })
        $null = Get-HygieneData -Datasets 'Packages', 'Programs' -ProgressState $state
        $state.Step | Should -BeLike 'Collecting programs (2 of 2)...'
    }

    It 'logs each loaded dataset and each failure' {
        $global:HygFail = @('SMS_Driver')
        $null = Get-HygieneData -Datasets 'Packages', 'Drivers'
        Should -Invoke Write-Log -ModuleName $script:Mod -Times 1 -Exactly -ParameterFilter { $Message -like 'Loaded 1 packages in *' }
        Should -Invoke Write-Log -ModuleName $script:Mod -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Message -like 'drivers unavailable*' }
    }
}

Describe 'Get-HygieneRelationshipData' {
    BeforeEach {
        Mock Write-Log { } -ModuleName $script:Mod
        $dt = "<AppMgmtDigest xmlns='http://schemas.microsoft.com/SystemCenterConfigurationManager/2009/AppMgmtDigest'><DeploymentType AuthoringScopeId='ScopeId_T' LogicalName='DeploymentType_X'><Title>Install</Title><Installer><Contents><Content><Location>\\srv\share\a</Location></Content></Contents></Installer><Supersedes/><Dependencies/></DeploymentType></AppMgmtDigest>"
        $global:HygFx = $dt
        Mock Get-CMApplication {
            foreach ($i in 1..3) {
                [PSCustomObject]@{ CI_ID = $i; ModelName = "ScopeId_A/Application_$i"; LocalizedDisplayName = "App $i"; SoftwareVersion = '1.0'; Manufacturer = $(if ($i -eq 2) { '' } else { 'Vendor' }); IsEnabled = 1; IsExpired = 0; IsSuperseded = 0; IsSuperseding = 0; HasContent = 1; NumberOfDeploymentTypes = 1; SDMPackageXML = $global:HygFx }
            }
        } -ModuleName $script:Mod
    }

    It 'returns the lookup without the XML, the relationships and the content locations' {
        $r = Get-HygieneRelationshipData
        $r.Apps.Count | Should -Be 3
        $r.Apps[2].Name | Should -Be 'App 2'
        $r.Apps[2].PSObject.Properties['SDMPackageXML'] | Should -BeNullOrEmpty
        @($r.ContentLocations).Count | Should -BeGreaterThan 0
        $r.PSObject.Properties['AutoInstallByModel'] | Should -Not -BeNullOrEmpty
    }

    It 'reports the application count in the progress state, with and without an expected count' {
        $state = [hashtable]::Synchronized(@{ Step = '' })
        $null = Get-HygieneRelationshipData -ProgressState $state -ExpectedCount 3
        $state.Step | Should -Be 'Reading application definitions (3 of 3)...'
        $null = Get-HygieneRelationshipData -ProgressState $state
        $state.Step | Should -Be 'Reading application definitions (3)...'
    }

    It 'returns null and logs a warning when the site cannot be read' {
        Mock Get-CMApplication { throw 'provider down' } -ModuleName $script:Mod
        Get-HygieneRelationshipData | Should -BeNullOrEmpty
        Should -Invoke Write-Log -ModuleName $script:Mod -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARN' -and $Message -like '*provider down*' }
    }

    It 'returns an empty result for a site with no applications' {
        Mock Get-CMApplication { } -ModuleName $script:Mod
        $r = Get-HygieneRelationshipData
        $r.Apps.Count | Should -Be 0
        @($r.Relationships).Count | Should -Be 0
    }
}
