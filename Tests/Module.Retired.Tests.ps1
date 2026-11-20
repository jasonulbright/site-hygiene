#Requires -Modules Pester
# Retired and superseded applications (Q-89): the fixes of SUP-04 and DEP-04, the retired application that holds rules (APP-07),
# the superseded application that qualifies for deletion (APP-08), the task sequence that installs a retired or superseded
# application (TSQ-05), the stale reference rows (TSQ-06) and the list of what blocks the delete of an application.

BeforeAll {
    . "$PSScriptRoot\TestHelpers.ps1"
    Import-AppModule

    function New-RetApp {
        param([int]$CI, [string]$Name, [bool]$Expired = $false, [bool]$Superseded = $false, [bool]$Deployed = $false, [string]$Model = '')
        [pscustomobject]@{
            CI_ID = $CI; ModelName = $(if ($Model) { $Model } else { "S/Application_$Name" }); Name = $Name; SoftwareVersion = '1'; Manufacturer = 'V'
            IsEnabled = $true; IsExpired = $Expired; IsSuperseded = $Superseded; IsSuperseding = $false; IsDeployed = $Deployed; HasContent = $true
            NumberOfDeploymentTypes = 1; PackageID = ''; DateCreated = [datetime]'2020-01-01'
        }
    }
    function New-RetEdge {
        param([string]$Kind, $From, $To, [string]$FromDt = 'DeploymentType_F', [string]$ToDt = 'DeploymentType_T')
        [pscustomobject]@{
            Kind = $Kind; FromAppCIID = $From.CI_ID; FromAppName = $From.Name; FromDTName = ($From.Name + ' DT'); FromDTLogicalName = $FromDt
            ToAppCIID = $To.CI_ID; ToAppName = $To.Name; ToModelName = $To.ModelName; ToAppExists = $true; ToDTLogicalName = $ToDt; RuleId = 'DTRule_1'; DependencyState = ''
        }
    }
    function New-RetData {
        param($Apps, $Edges, $TaskSequences = @(), $Deployments = @())
        $lookup = @{}; foreach ($a in $Apps) { $lookup[[int]$a.CI_ID] = $a }
        $data = [pscustomobject]@{ Applications = @($Apps); TaskSequences = @($TaskSequences); Deployments = @($Deployments); TsAppDefinitions = @(); ContentStatus = @() }
        $rel = [pscustomobject]@{ Apps = $lookup; Relationships = @($Edges) }
        @{ Data = $data; Rel = $rel }
    }
    function New-RetTs { param([string]$Id, [string]$Name, [string[]]$Refs, [bool]$Stale = $false) [pscustomobject]@{ PackageID = $Id; Name = $Name; ReferencedIDs = $Refs; BootImageID = ''; ProgramFlags = 0; IsStale = $Stale } }
    function Get-StatementCount { param([string]$Text) $e = $null; $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$e); if (@($e).Count -gt 0) { throw ('does not parse: ' + @($e)[0].Message) }; @($ast.EndBlock.Statements).Count }
}

Describe 'The fix scripts' {
    It 'removes a supersedence rule with the supported cmdlet and then the old revisions, as two statements that parse' {
        $s = Get-HygSupersedenceRemovalScript -FromModel 'S/Application_N' -FromDeploymentType 'DeploymentType_N1' -ToModel 'S/Application_O' -ToDeploymentType 'DeploymentType_O1'
        Get-StatementCount $s | Should -Be 2
        $s | Should -Match 'Set-CMApplicationSupersedence -Id \$f\.CI_ID .* -RemoveSupersedence -Force'
        $s | Should -Match "Get-CMApplication -ModelName 'S/Application_N'"
        $s | Should -Match "-like '\*/DeploymentType_O1'"
        $s | Should -Match 'Remove-CMApplicationRevisionHistory'
        $s | Should -Not -Match 'Remove-CMDeploymentTypeSupersedence'
        Test-HygieneFixExecutable -FixScript $s | Should -BeTrue
    }
    It 'removes a dependency with the supported cmdlet and then the old revisions' {
        $s = Get-HygDependencyRemovalScript -FromModel 'S/Application_N' -FromDeploymentType 'DeploymentType_N1' -ToModel 'S/Application_R'
        Get-StatementCount $s | Should -Be 2
        $s | Should -Match 'Remove-CMDeploymentTypeDependency -InputObject \$g -DeploymentTypeDependency \$d -Force'
        $s | Should -Match "AppModelName -eq 'S/Application_R'"
    }
    It 'keeps a model name with a quote inside the quotes of the script' {
        $s = Get-HygDependencyRemovalScript -FromModel "S/Application_N'x" -FromDeploymentType 'D' -ToModel 'S/Application_R'
        Get-StatementCount $s | Should -Be 2
    }
}

Describe 'SUP-04 and DEP-04 have a fix' {
    It 'gives SUP-04 the removal of the rule and DEP-04 the removal of the dependency' {
        $new = New-RetApp -CI 1 -Name 'New'; $old = New-RetApp -CI 2 -Name 'Old' -Expired $true
        $x = New-RetData -Apps @($new, $old) -Edges @((New-RetEdge Supersedence $new $old), (New-RetEdge Dependency $new $old))
        $f = @(Test-HygRelationshipChecks -RelationshipData $x.Rel)
        $sup = @($f | Where-Object CheckId -eq 'SUP-04')[0]
        $dep = @($f | Where-Object CheckId -eq 'DEP-04')[0]
        Test-HygieneFixExecutable -FixScript $sup.FixScript | Should -BeTrue
        $sup.FixScript | Should -Match 'Set-CMApplicationSupersedence'
        Test-HygieneFixExecutable -FixScript $dep.FixScript | Should -BeTrue
        $dep.FixScript | Should -Match 'Remove-CMDeploymentTypeDependency'
    }
}

Describe 'Test-HygRetiredSupersededChecks' {
    It 'APP-07: a retired application that supersedes or depends on an active one is one finding with both removals' {
        $ret = New-RetApp -CI 1 -Name 'Retired' -Expired $true; $act = New-RetApp -CI 2 -Name 'Active'; $act2 = New-RetApp -CI 3 -Name 'Active2'
        $x = New-RetData -Apps @($ret, $act, $act2) -Edges @((New-RetEdge Supersedence $ret $act), (New-RetEdge Dependency $ret $act2))
        $f = @(Test-HygRetiredSupersededChecks -Data $x.Data -RelationshipData $x.Rel | Where-Object CheckId -eq 'APP-07')
        $f.Count | Should -Be 1
        $f[0].ObjectName | Should -Be 'Retired'
        $f[0].Evidence | Should -Match "supersedes 'Active'"
        $f[0].Evidence | Should -Match "depends on 'Active2'"
        $f[0].FixScript | Should -Match 'Set-CMApplicationSupersedence'
        $f[0].FixScript | Should -Match 'Remove-CMDeploymentTypeDependency'
        Test-HygieneFixExecutable -FixScript $f[0].FixScript | Should -BeTrue
    }
    It 'APP-07 leaves out an edge to a retired target (SUP-04 and DEP-04 report it) and to a deleted one (SUP-01 and DEP-01)' {
        $ret = New-RetApp -CI 1 -Name 'Retired' -Expired $true; $ret2 = New-RetApp -CI 2 -Name 'Retired2' -Expired $true
        $gone = New-RetEdge Supersedence $ret $ret2; $gone2 = New-RetEdge Supersedence $ret $ret2; $gone2.ToAppExists = $false
        $x = New-RetData -Apps @($ret, $ret2) -Edges @($gone, $gone2)
        @(Test-HygRetiredSupersededChecks -Data $x.Data -RelationshipData $x.Rel | Where-Object CheckId -eq 'APP-07').Count | Should -Be 0
    }
    It 'APP-08: a superseded application that nothing refers to qualifies, and the fix removes the rule, deletes the application and its revisions' {
        $new = New-RetApp -CI 1 -Name 'New'; $old = New-RetApp -CI 2 -Name 'Old' -Superseded $true
        $x = New-RetData -Apps @($new, $old) -Edges @((New-RetEdge Supersedence $new $old))
        $f = @(Test-HygRetiredSupersededChecks -Data $x.Data -RelationshipData $x.Rel | Where-Object CheckId -eq 'APP-08')
        $f.Count | Should -Be 1
        $f[0].ObjectName | Should -Be 'Old'
        $f[0].Evidence | Should -Match "superseded by 'New'"
        $f[0].Evidence | Should -Match 'Blocked by: nothing'
        $f[0].FixScript | Should -Match 'Set-CMApplicationSupersedence'
        $f[0].FixScript | Should -Match 'Remove-CMApplication -Force'
        ($f[0].FixScript -split "`r?`n" | Select-Object -Last 1) | Should -Match 'Remove-CMApplication'
    }
    It 'APP-08 leaves a retired superseded application to SUP-04 (one situation, one finding)' {
        $new = New-RetApp -CI 1 -Name 'New'; $old = New-RetApp -CI 2 -Name 'Old' -Superseded $true -Expired $true
        $x = New-RetData -Apps @($new, $old) -Edges @((New-RetEdge Supersedence $new $old))
        @(Test-HygRetiredSupersededChecks -Data $x.Data -RelationshipData $x.Rel | Where-Object CheckId -eq 'APP-08').Count | Should -Be 0
    }
    It 'APP-08 is not reported when a deployment, a dependency, a task sequence or a stale reference row refers to the application' {
        $new = New-RetApp -CI 1 -Name 'New'; $old = New-RetApp -CI 2 -Name 'Old' -Superseded $true; $dep = New-RetApp -CI 3 -Name 'Dependent'
        $sup = New-RetEdge Supersedence $new $old
        $cases = @(
            @{ Why = 'deployed'; Apps = @($new, (New-RetApp -CI 2 -Name 'Old' -Superseded $true -Deployed $true)); Edges = @($sup); Ts = @() },
            @{ Why = 'dependency'; Apps = @($new, $old, $dep); Edges = @($sup, (New-RetEdge Dependency $dep $old)); Ts = @() },
            @{ Why = 'task sequence'; Apps = @($new, $old); Edges = @($sup); Ts = @((New-RetTs 'TS1' 'Build' @($old.ModelName))) },
            @{ Why = 'stale reference'; Apps = @($new, $old); Edges = @($sup); Ts = @((New-RetTs 'TSX' '' @($old.ModelName) $true)) }
        )
        foreach ($c in $cases) {
            $x = New-RetData -Apps $c.Apps -Edges $c.Edges -TaskSequences $c.Ts
            @(Test-HygRetiredSupersededChecks -Data $x.Data -RelationshipData $x.Rel | Where-Object CheckId -eq 'APP-08').Count | Should -Be 0 -Because $c.Why
        }
    }
    It 'TSQ-05: a task sequence that installs a retired or superseded application is a finding with the name and the package id, and has no fix' {
        $ret = New-RetApp -CI 1 -Name 'Retired' -Expired $true; $old = New-RetApp -CI 2 -Name 'Old' -Superseded $true; $act = New-RetApp -CI 3 -Name 'Active'
        $x = New-RetData -Apps @($ret, $old, $act) -Edges @((New-RetEdge Supersedence $act $old)) -TaskSequences @(
            (New-RetTs 'MCM00010' 'Build PC' @($ret.ModelName, $old.ModelName, $act.ModelName, 'MCM00004')))
        $f = @(Test-HygRetiredSupersededChecks -Data $x.Data -RelationshipData $x.Rel | Where-Object CheckId -eq 'TSQ-05')
        $f.Count | Should -Be 2
        $r = $f | Where-Object ObjectName -like '*Retired'
        $r.Evidence | Should -Match "Task sequence 'Build PC' \(package MCM00010\)"
        $r.Evidence | Should -Match 'retired application'
        ($f | Where-Object ObjectName -like '*Old').Evidence | Should -Match "superseded by 'Active'"
        Test-HygieneFixExecutable -FixScript $r.FixScript | Should -BeFalse
    }
    It 'TSQ-06: reference rows of a task sequence that the site does not return are a stale reference finding' {
        $act = New-RetApp -CI 3 -Name 'Active'
        $x = New-RetData -Apps @($act) -Edges @() -TaskSequences @((New-RetTs 'MCM000AA' '' @($act.ModelName) $true), (New-RetTs 'MCM00010' 'Live' @($act.ModelName)))
        $f = @(Test-HygRetiredSupersededChecks -Data $x.Data -RelationshipData $x.Rel | Where-Object CheckId -eq 'TSQ-06')
        $f.Count | Should -Be 1
        $f[0].ObjectName | Should -Be 'MCM000AA'
        $f[0].Evidence | Should -Match '^Stale reference'
        $f[0].Evidence | Should -Match 'Active'
        Test-HygieneFixExecutable -FixScript $f[0].FixScript | Should -BeFalse
    }
}

Describe 'Get-HygApplicationBlocker' {
    It 'lists every referencing object by kind and name, the nested task sequence and the stale row' {
        $new = New-RetApp -CI 1 -Name 'New'; $old = New-RetApp -CI 2 -Name 'Old' -Superseded $true -Deployed $true; $dep = New-RetApp -CI 3 -Name 'Dependent'
        $x = New-RetData -Apps @($new, $old, $dep) -Edges @((New-RetEdge Supersedence $new $old), (New-RetEdge Dependency $dep $old)) -TaskSequences @(
            (New-RetTs 'TS000001' 'Inner' @($old.ModelName)), (New-RetTs 'TS000002' 'Outer' @('TS000001')), (New-RetTs 'TSSTALE1' '' @($old.ModelName) $true)) -Deployments @(
            [pscustomobject]@{ SoftwareName = 'Old'; FeatureType = 1; CollectionName = 'All Desktops'; CollectionID = 'MCM00099' },
            [pscustomobject]@{ SoftwareName = 'Other'; FeatureType = 1; CollectionName = 'Nope'; CollectionID = 'MCM00098' })
        $b = @(Get-HygApplicationBlocker -Data $x.Data -RelationshipData $x.Rel -ModelName $old.ModelName)
        ($b | ForEach-Object Kind | Sort-Object) | Should -Be @('Dependency', 'Deployment', 'Stale reference', 'Supersedence', 'Task sequence', 'Task sequence (nested)')
        ($b | Where-Object Kind -eq 'Deployment').Name | Should -Be 'All Desktops'
        ($b | Where-Object Kind -eq 'Task sequence').Name | Should -Be 'Inner'
        ($b | Where-Object Kind -eq 'Task sequence (nested)').Name | Should -Be 'Outer'
        ($b | Where-Object Kind -eq 'Stale reference').Name | Should -Be 'TSSTALE1'
        ($b | Where-Object Kind -eq 'Dependency').Name | Should -Be 'Dependent'
        ($b | Where-Object Kind -eq 'Supersedence').Name | Should -Be 'New'
    }
}

Describe 'The task sequence dataset keeps the stale reference rows from the one query' {
    It 'adds an entry for reference rows whose task sequence is not returned, and the checks that read references leave it out' {
        $stubs = 'Invoke-CMWmiQuery', 'Get-CMTaskSequence'
        foreach ($s in $stubs) { Set-Item -Path "function:global:$s" -Value { [CmdletBinding()] param($Query, $Option, [switch]$Fast) } }
        try {
            Mock -ModuleName SiteHygieneCommon Invoke-CMWmiQuery {
                [pscustomobject]@{ PackageID = 'MCM00008'; ObjectID = 'ScopeId_X/Application_Y' }
                [pscustomobject]@{ PackageID = 'MCM0DEAD'; ObjectID = 'ScopeId_X/Application_Z' }
            } -ParameterFilter { $Query -like '*SMS_TaskSequencePackageReference_All' }
            Mock -ModuleName SiteHygieneCommon Get-CMTaskSequence { [pscustomobject]@{ PackageID = 'MCM00008'; Name = 'Build'; BootImageID = ''; ProgramFlags = 0 } }
            $data = Get-HygieneData -Datasets 'TaskSequences'
            $stale = @($data.TaskSequences | Where-Object IsStale)
            $stale.Count | Should -Be 1
            $stale[0].PackageID | Should -Be 'MCM0DEAD'
            ($stale[0].ReferencedIDs -join ',') | Should -Be 'ScopeId_X/Application_Z'
            @($data.TaskSequences | Where-Object { -not $_.IsStale }).Count | Should -Be 1
            @(Get-HygLiveTaskSequence -Data $data).Count | Should -Be 1
            Should -Invoke -ModuleName SiteHygieneCommon Invoke-CMWmiQuery -Times 1 -Exactly
        }
        finally { foreach ($s in $stubs) { Remove-Item -Path "function:global:$s" -ErrorAction SilentlyContinue } }
    }
}

Describe 'Test-HygDeploymentOld' {
    BeforeAll {
        function New-OldDep { param([int]$AgeDays, [int]$Intent = 1, [int]$Success = 5, [int]$Targeted = 10, [string]$Name = 'App') [pscustomobject]@{ SoftwareName = $Name; CollectionID = 'MCM00001'; CollectionName = 'All'; DeploymentIntent = $Intent; NumberTargeted = $Targeted; NumberSuccess = $Success; NumberInProgress = 0; NumberErrors = 0; CreationTime = (Get-Date).AddDays(-$AgeDays) } }
    }
    It 'reports a deployment older than 365 days by default, with the review text and no fix' {
        $data = [pscustomobject]@{ Deployments = @((New-OldDep -AgeDays 400), (New-OldDep -AgeDays 100 -Name 'Young')) }
        $f = @(Test-HygDeploymentOld -Data $data)
        $f.Count | Should -Be 1
        $f[0].CheckId | Should -Be 'DPL-06'
        $f[0].ObjectName | Should -Be 'App -> All'
        $f[0].Recommendation | Should -Match 'Review whether the deployment is still needed'
        Test-HygieneFixExecutable -FixScript $f[0].FixScript | Should -BeFalse
    }
    It 'uses the threshold setting' {
        $data = [pscustomobject]@{ Deployments = @((New-OldDep -AgeDays 200)) }
        $t = Get-HygieneDefaultThresholds; $t.DeploymentOldDays | Should -Be 365
        @(Test-HygDeploymentOld -Data $data -Thresholds $t).Count | Should -Be 0
        $t.DeploymentOldDays = 180
        @(Test-HygDeploymentOld -Data $data -Thresholds $t).Count | Should -Be 1
    }
    It 'leaves a deployment to DPL-03 when DPL-03 already reports it (one situation, one finding)' {
        $data = [pscustomobject]@{ Deployments = @((New-OldDep -AgeDays 400 -Intent 2 -Success 0)) }
        @(Test-HygDeploymentOld -Data $data).Count | Should -Be 0
        @(Test-HygDeploymentAvailableUnused -Data $data).Count | Should -Be 1
    }
    It 'is in the catalog and in the scan plan' {
        (Get-HygieneCheckCatalog | Where-Object Id -eq 'DPL-06').Category | Should -Be 'Deployments'
        @(& (Get-Module SiteHygieneCommon) { Get-HygScanPlan } | Where-Object Id -eq 'DPL-06').Count | Should -Be 1
    }
}
