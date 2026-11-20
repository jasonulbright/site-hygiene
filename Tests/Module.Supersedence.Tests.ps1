#Requires -Modules Pester
# Repair of check SUP-01: the plan, the backup, the removal, the re-check and the restore. The site is replaced by
# stubs and mocks, so these tests run without a ConfigMgr site. The lab run with real applications is a separate proof.

BeforeAll {
    . "$PSScriptRoot\TestHelpers.ps1"
    Import-AppModule
    $script:Stubs = New-CmStub -Name 'Get-CMApplication', 'Get-CMApplicationRevisionHistory', 'Remove-CMApplicationRevisionHistory'

    $script:NsD = 'http://schemas.microsoft.com/SystemCenterConfigurationManager/2009/AppMgmtDigest'
    $script:NsR = 'http://schemas.microsoft.com/SystemsCenterConfigurationManager/2009/06/14/Rules'

    # One deployment type with the named supersedence rules. A rule is @{ Id = ...; Models = @('Scope/Application_x', ...) }.
    function New-SupXml {
        param([object[]]$Rules = @(), [string]$DtLogical = 'DeploymentType_N', [string]$DtTitle = 'Install N')
        $body = foreach ($rule in $Rules) {
            $intents = foreach ($m in $rule.Models) {
                $scope, $logical = $m -split '/', 2
                "<DeploymentTypeIntentExpression DesiredState='Prohibited'><DeploymentTypeApplicationReference AuthoringScopeId='$scope' LogicalName='$logical'/><DeploymentTypeReference AuthoringScopeId='$scope' LogicalName='DeploymentType_Old' Changeable='false'/></DeploymentTypeIntentExpression>"
            }
            "<DeploymentTypeRule xmlns='$($script:NsR)' id='$($rule.Id)' Severity='None'><DeploymentTypeExpression><Operator>Or</Operator><Operands>$($intents -join '')</Operands></DeploymentTypeExpression></DeploymentTypeRule>"
        }
        $sup = if (@($Rules).Count -gt 0) { "<Supersedes>$($body -join '')</Supersedes>" } else { '' }
        "<AppMgmtDigest xmlns='$($script:NsD)'><Application><AutoInstall>false</AutoInstall></Application><DeploymentType AuthoringScopeId='ScopeId_T' LogicalName='$DtLogical'><Title>$DtTitle</Title>$sup<DeploymentTechnology>GLOBAL/ScriptDeploymentTechnology</DeploymentTechnology></DeploymentType></AppMgmtDigest>"
    }

    function New-SupApp {
        param([string]$Model, [string]$Name, [string]$Xml = '', [int]$CI = 1)
        $o = [pscustomobject]@{
            CI_ID = $CI; CIVersion = 3; ModelName = $Model; LocalizedDisplayName = $Name; SoftwareVersion = '1.0'; Manufacturer = 'Vendor'
            IsEnabled = $true; IsExpired = $false; IsSuperseded = $false; IsSuperseding = $true; HasContent = $true
            NumberOfDeploymentTypes = 1; SDMPackageXML = $Xml
        }
        $o | Add-Member -MemberType ScriptMethod -Name Put -Value { $script:putCount++ } -Force
        $o
    }

    function New-SupTarget {
        param([string]$Key, [string]$App, [string]$Rule, [string]$Ref, [string]$Dt = 'DeploymentType_N')
        [pscustomobject]@{ FindingKey = $Key; FixData = [pscustomobject]@{
            ApplicationModelName = $App; DeploymentTypeLogicalName = $Dt; RuleId = $Rule; ReferencedApplicationModel = $Ref; Kind = 'SupersedenceToDeletedApplication' } }
    }
}

AfterAll { Remove-CmStub -Name $script:Stubs }

Describe 'Find-HygBrokenSupersedenceRule' {
    It 'returns the rule whose referenced application is gone, with the ids that the repair needs' {
        $xml = New-SupXml -Rules @(@{ Id = 'DTRule_gone'; Models = @('S/Application_gone') }, @{ Id = 'DTRule_here'; Models = @('S/Application_here') })
        $rows = @(Find-HygBrokenSupersedenceRule -SdmPackageXml $xml -Exists { param($m) $m -eq 'S/Application_here' })
        $rows.Count | Should -Be 1
        $rows[0].RuleId | Should -Be 'DTRule_gone'
        $rows[0].DeploymentTypeLogicalName | Should -Be 'DeploymentType_N'
        $rows[0].DeploymentTypeName | Should -Be 'Install N'
        $rows[0].ReferencedApplicationModel | Should -Be 'S/Application_gone'
        $rows[0].ReferencedDeploymentTypeLogicalName | Should -Be 'DeploymentType_Old'
        $rows[0].Removable | Should -BeTrue
    }

    It 'returns nothing when every referenced application exists, and for an empty document' {
        $xml = New-SupXml -Rules @(@{ Id = 'DTRule_a'; Models = @('S/Application_here') })
        @(Find-HygBrokenSupersedenceRule -SdmPackageXml $xml -Exists { $true }).Count | Should -Be 0
        @(Find-HygBrokenSupersedenceRule -SdmPackageXml '' -Exists { $false }).Count | Should -Be 0
        @(Find-HygBrokenSupersedenceRule -SdmPackageXml (New-SupXml) -Exists { $false }).Count | Should -Be 0
    }

    It 'marks a rule that also points at an existing application as not removable' {
        $xml = New-SupXml -Rules @(@{ Id = 'DTRule_mixed'; Models = @('S/Application_gone', 'S/Application_here') })
        $rows = @(Find-HygBrokenSupersedenceRule -SdmPackageXml $xml -Exists { param($m) $m -eq 'S/Application_here' })
        $rows.Count | Should -Be 1
        $rows[0].Removable | Should -BeFalse
    }
}

Describe 'The relationship data and the SUP-01 finding' {
    It 'carries the deployment type, the rule and the target deployment type of each supersedence edge' {
        $xml = New-SupXml -Rules @(@{ Id = 'DTRule_gone'; Models = @('S/Application_gone') })
        $app = [pscustomobject]@{ CI_ID = 5; ModelName = 'S/Application_new'; Name = 'New'; SoftwareVersion = '1'; IsSuperseding = $false; NumberOfDeploymentTypes = 1; SDMPackageXML = $xml }
        $rel = @((ConvertTo-HygRelationships -Applications @($app)).Relationships)
        $rel.Count | Should -Be 1
        $rel[0].FromDTLogicalName | Should -Be 'DeploymentType_N'
        $rel[0].RuleId | Should -Be 'DTRule_gone'
        $rel[0].ToDTLogicalName | Should -Be 'DeploymentType_Old'
    }

    It 'gives SUP-01 the data of its fix and a fix text that no script runs' {
        $xml = New-SupXml -Rules @(@{ Id = 'DTRule_gone'; Models = @('S/Application_gone') })
        $app = [pscustomobject]@{ CI_ID = 5; ModelName = 'S/Application_new'; Name = 'New'; SoftwareVersion = '1'; Manufacturer = 'V'; IsEnabled = $true; IsExpired = $false; IsSuperseded = $false; IsSuperseding = $false; HasContent = $true; NumberOfDeploymentTypes = 1; SDMPackageXML = $xml }
        $parsed = ConvertTo-HygRelationships -Applications @($app)
        $data = [pscustomobject]@{ Apps = @{ 5 = $app }; Relationships = $parsed.Relationships }
        $f = @(Test-HygRelationshipChecks -RelationshipData $data | Where-Object CheckId -eq 'SUP-01')
        $f.Count | Should -Be 1
        $f[0].FixData.ApplicationModelName | Should -Be 'S/Application_new'
        $f[0].FixData.RuleId | Should -Be 'DTRule_gone'
        $f[0].FixData.ReferencedApplicationModel | Should -Be 'S/Application_gone'
        $f[0].FixData.DeploymentTypeLogicalName | Should -Be 'DeploymentType_N'
        Test-HygieneFixExecutable -FixScript $f[0].FixScript | Should -BeFalse
    }
}

Describe 'Get-HygSupersedencePlan' {
    BeforeEach {
        $script:present = @{}
        Mock Get-CMApplication {
            if ($ModelName -and $script:present.ContainsKey($ModelName)) { $script:present[$ModelName] }
        } -ModuleName SiteHygieneCommon
    }

    It 'lists each broken reference with its application and deployment type, and changes nothing' {
        $xml = New-SupXml -Rules @(@{ Id = 'DTRule_gone'; Models = @('S/Application_gone') }, @{ Id = 'DTRule_here'; Models = @('S/Application_here') })
        $script:present['S/Application_new'] = New-SupApp -Model 'S/Application_new' -Name 'New App' -Xml $xml
        $script:present['S/Application_here'] = New-SupApp -Model 'S/Application_here' -Name 'Here'
        $plan = Get-HygSupersedencePlan -Target @(New-SupTarget -Key 'k1' -App 'S/Application_new' -Rule 'DTRule_gone' -Ref 'S/Application_gone')
        @($plan.Rows).Count | Should -Be 1
        $plan.Rows[0].ApplicationName | Should -Be 'New App'
        $plan.Rows[0].DeploymentTypeName | Should -Be 'Install N'
        $plan.Rows[0].ReferencedApplicationModel | Should -Be 'S/Application_gone'
        $plan.Rows[0].FindingKey | Should -Be 'k1'
        @($plan.Skipped).Count | Should -Be 0
        @($plan.Applications).Count | Should -Be 1
    }

    It 'skips a finding whose reference is no longer broken, and a finding whose application is gone' {
        $xml = New-SupXml -Rules @(@{ Id = 'DTRule_gone'; Models = @('S/Application_gone') })
        $script:present['S/Application_new'] = New-SupApp -Model 'S/Application_new' -Name 'New App' -Xml $xml
        $script:present['S/Application_gone'] = New-SupApp -Model 'S/Application_gone' -Name 'Came back'
        $plan = Get-HygSupersedencePlan -Target @(
            (New-SupTarget -Key 'k1' -App 'S/Application_new' -Rule 'DTRule_gone' -Ref 'S/Application_gone'),
            (New-SupTarget -Key 'k2' -App 'S/Application_missing' -Rule 'DTRule_x' -Ref 'S/Application_gone'))
        @($plan.Rows).Count | Should -Be 0
        @($plan.Skipped).Count | Should -Be 2
        ($plan.Skipped | Where-Object FindingKey -eq 'k1').Reason | Should -Match 'no longer broken'
        ($plan.Skipped | Where-Object FindingKey -eq 'k2').Reason | Should -Match 'no longer in the site'
    }

    It 'does not plan a rule that the finding does not name' {
        $xml = New-SupXml -Rules @(@{ Id = 'DTRule_one'; Models = @('S/Application_g1') }, @{ Id = 'DTRule_two'; Models = @('S/Application_g2') })
        $script:present['S/Application_new'] = New-SupApp -Model 'S/Application_new' -Name 'New App' -Xml $xml
        $plan = Get-HygSupersedencePlan -Target @(New-SupTarget -Key 'k1' -App 'S/Application_new' -Rule 'DTRule_one' -Ref 'S/Application_g1')
        @($plan.Rows).Count | Should -Be 1
        $plan.Rows[0].RuleId | Should -Be 'DTRule_one'
    }

    It 'does not plan a rule with an existing reference in it' {
        $xml = New-SupXml -Rules @(@{ Id = 'DTRule_mixed'; Models = @('S/Application_gone', 'S/Application_here') })
        $script:present['S/Application_new'] = New-SupApp -Model 'S/Application_new' -Name 'New App' -Xml $xml
        $script:present['S/Application_here'] = New-SupApp -Model 'S/Application_here' -Name 'Here'
        $plan = Get-HygSupersedencePlan -Target @(New-SupTarget -Key 'k1' -App 'S/Application_new' -Rule 'DTRule_mixed' -Ref 'S/Application_gone')
        @($plan.Rows).Count | Should -Be 0
        $plan.Skipped[0].Reason | Should -Match 'still exists'
    }
}

Describe 'Get-HygDocumentDifference' {
    It 'is empty when the second document is the first one without the named rules, whatever the formatting and the Version attribute' {
        $before = New-SupXml -Rules @(@{ Id = 'DTRule_gone'; Models = @('S/Application_gone') }, @{ Id = 'DTRule_here'; Models = @('S/Application_here') })
        $after = (New-SupXml -Rules @(@{ Id = 'DTRule_here'; Models = @('S/Application_here') })).Replace('><', ">`r`n  <").Replace("LogicalName='DeploymentType_N'", "LogicalName='DeploymentType_N' Version='9'")
        @(Get-HygDocumentDifference -Before $before -After $after -RemovedRuleId @('DTRule_gone')).Count | Should -Be 0
    }

    It 'does not count the empty Supersedes container that the serializer leaves out when the last rule is removed' {
        $before = New-SupXml -Rules @(@{ Id = 'DTRule_gone'; Models = @('S/Application_gone') })
        $after = (New-SupXml -Rules @(@{ Id = 'DTRule_gone'; Models = @('S/Application_gone') })).Replace('<Supersedes>', '<X>').Replace('</Supersedes>', '</X>')
        $none = New-SupXml -Rules @()
        @(Get-HygDocumentDifference -Before $before -After $none -RemovedRuleId @('DTRule_gone')).Count | Should -Be 0
        $after | Out-Null
    }

    It 'reports a rule that was removed but not named' {
        $before = New-SupXml -Rules @(@{ Id = 'DTRule_gone'; Models = @('S/Application_gone') }, @{ Id = 'DTRule_here'; Models = @('S/Application_here') })
        $after = New-SupXml -Rules @()
        $d = @(Get-HygDocumentDifference -Before $before -After $after -RemovedRuleId @('DTRule_gone'))
        $d.Count | Should -BeGreaterThan 0
        ($d -join ' ') | Should -Match 'missing'
    }

    It 'reports a changed deployment type, a changed content id and an added element' {
        $before = New-SupXml -Rules @(@{ Id = 'DTRule_gone'; Models = @('S/Application_gone') })
        $after = (New-SupXml -Rules @()).Replace('<Title>Install N</Title>', '<Title>Install M</Title><Contents><Content ContentId="Content_1"/></Contents>')
        $d = @(Get-HygDocumentDifference -Before $before -After $after -RemovedRuleId @('DTRule_gone'))
        ($d -join ' ') | Should -Match 'added'
        ($d -join ' ') | Should -Match 'Install M'
    }

    It 'reports a different title and an extra rule' {
        $before = New-SupXml -Rules @(@{ Id = 'DTRule_gone'; Models = @('S/Application_gone') })
        $after = New-SupXml -Rules @(@{ Id = 'DTRule_new'; Models = @('S/Application_other') })
        @(Get-HygDocumentDifference -Before $before -After $after -RemovedRuleId @('DTRule_gone')).Count | Should -BeGreaterThan 0
    }
}

Describe 'Test-HygSerializerInfo' {
    It 'accepts the serializer of the console: same folder, same major and minor version' {
        Test-HygSerializerInfo -Info ([pscustomobject]@{ Loaded = $true; AssemblyFolder = 'C:\Console\bin'; AssemblyVersion = '5.2603.1044.1000'; ConsoleFolder = 'C:\Console\bin'; ConsoleVersion = '5.2603.1035.1000' }) | Should -BeNullOrEmpty
    }
    It 'refuses a serializer from another folder, of another version, or not loaded' {
        Test-HygSerializerInfo -Info ([pscustomobject]@{ Loaded = $true; AssemblyFolder = 'C:\Other'; AssemblyVersion = '5.2603.1.0'; ConsoleFolder = 'C:\Console\bin'; ConsoleVersion = '5.2603.1.0' }) | Should -Match 'another folder'
        Test-HygSerializerInfo -Info ([pscustomobject]@{ Loaded = $true; AssemblyFolder = 'C:\Console\bin'; AssemblyVersion = '5.2509.1.0'; ConsoleFolder = 'C:\Console\bin'; ConsoleVersion = '5.2603.1.0' }) | Should -Match 'differs'
        Test-HygSerializerInfo -Info ([pscustomobject]@{ Loaded = $false; AssemblyFolder = ''; AssemblyVersion = ''; ConsoleFolder = 'C:\Console\bin'; ConsoleVersion = '5.2603.1.0' }) | Should -Match 'not loaded'
        Test-HygSerializerInfo -Info ([pscustomobject]@{ Loaded = $true; AssemblyFolder = 'C:\Console\bin'; AssemblyVersion = '5.2603.1.0'; ConsoleFolder = ''; ConsoleVersion = '' }) | Should -Match 'module'
    }
}

Describe 'Remove-HygBrokenSupersedence' {
    BeforeEach {
        $script:putCount = 0
        $script:revisionCalls = [System.Collections.ArrayList]::new()
        $script:keepRevision = $null
        $script:rules = @(@{ Id = 'DTRule_gone'; Models = @('S/Application_gone') }, @{ Id = 'DTRule_here'; Models = @('S/Application_here') })
        $script:fail = $false
        $script:extra = $false
        $script:serializerOk = $true
        $script:apps = @{ 'S/Application_here' = (New-SupApp -Model 'S/Application_here' -Name 'Here') }
        $script:logged = [System.Collections.ArrayList]::new()
        Mock Write-Log { [void]$script:logged.Add([string]$Message) } -ModuleName SiteHygieneCommon
        Mock Get-HygSerializerInfo { [pscustomobject]@{ Loaded = $true; AssemblyFolder = 'C:\C'; AssemblyVersion = '5.2603.1.0'; ConsoleFolder = $(if ($script:serializerOk) { 'C:\C' } else { 'D:\X' }); ConsoleVersion = '5.2603.9.0' } } -ModuleName SiteHygieneCommon
        Mock Get-CMApplication {
            if ($ModelName -eq 'S/Application_new') { $a = New-SupApp -Model 'S/Application_new' -Name 'New App' -Xml (New-SupXml -Rules $script:rules) -CI 5; $a.CIVersion = 2 + $script:putCount; $a }
            elseif ($ModelName -and $script:apps.ContainsKey($ModelName)) { $script:apps[$ModelName] }
        } -ModuleName SiteHygieneCommon
        Mock Get-CMApplicationRevisionHistory { foreach ($v in 1, 2, 3) { [pscustomobject]@{ CIVersion = $v } } } -ModuleName SiteHygieneCommon
        Mock Remove-CMApplicationRevisionHistory {
            [void]$script:revisionCalls.Add($Revision)
            if ($script:keepRevision -eq $Revision) { throw 'Configuration Manager cannot delete this revision.' }
        } -ModuleName SiteHygieneCommon
        Mock Read-HygApplicationDocument {
            $ruleList = New-Object System.Collections.Generic.List[object]
            foreach ($r in $script:rules) { $ruleList.Add([pscustomobject]@{ RuleId = $r.Id }) }
            [pscustomobject]@{ DeploymentTypes = @([pscustomobject]@{ Supersedes = $ruleList }) }
        } -ModuleName SiteHygieneCommon
        Mock ConvertTo-HygApplicationDocument {
            if ($script:fail) { throw 'The write was refused.' }
            $script:rules = @($script:rules | Where-Object { $_.Id -in @($Application.DeploymentTypes[0].Supersedes | ForEach-Object RuleId) })
            if ($script:extra) { (New-SupXml -Rules $script:rules).Replace('<Title>Install N</Title>', '<Title>Install M</Title>') } else { New-SupXml -Rules $script:rules }
        } -ModuleName SiteHygieneCommon
        $script:plan = [pscustomobject]@{
            Rows = @([pscustomobject]@{ FindingKey = 'k1'; ApplicationName = 'New App'; ApplicationModelName = 'S/Application_new'; ApplicationCIId = 5; DeploymentTypeName = 'Install N'; DeploymentTypeLogicalName = 'DeploymentType_N'
                    RuleId = 'DTRule_gone'; ReferencedApplicationModel = 'S/Application_gone'; ReferencedDeploymentTypeLogicalName = 'DeploymentType_Old' })
            Applications = @([pscustomobject]@{ ModelName = 'S/Application_new'; Name = 'New App'; CIId = 5; CIVersion = 1 })
        }
    }

    It 'removes only the broken rule, reads the application back and writes no file' {
        $before = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'supersedence-backup*' -ErrorAction SilentlyContinue).Count
        $r = Remove-HygBrokenSupersedence -Plan $script:plan
        $r.Success | Should -BeTrue -Because ($r.Message + ' / ' + (@($r.Results | ForEach-Object { $_.Result + ': ' + $_.Message + ' ' + $_.Detail }) -join '; '))
        $r.Removed | Should -Be 1
        $r.Failed | Should -Be 0
        $script:putCount | Should -Be 1
        @($script:rules | ForEach-Object { $_.Id }) | Should -Be @('DTRule_here')
        $r.Results[0].Result | Should -Be 'Removed'
        @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'supersedence-backup*' -ErrorAction SilentlyContinue).Count | Should -Be $before
        Get-Command -Name Export-HygSupersedenceBackup, Restore-HygSupersedence -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'does not touch the old revisions without -DeleteOldRevisions' {
        $null = Remove-HygBrokenSupersedence -Plan $script:plan
        $script:revisionCalls.Count | Should -Be 0
    }

    It 'with -DeleteOldRevisions deletes only the revisions older than the new one, of the changed application' {
        $r = Remove-HygBrokenSupersedence -Plan $script:plan -DeleteOldRevisions
        @($script:revisionCalls) | Should -Be @(1, 2)
        $r.Results[0].RevisionsDeleted | Should -Be 2
        $r.Results[0].RevisionNote | Should -Match '2 old revision'
        $r.Success | Should -BeTrue
    }

    It 'keeps a revision that the site refuses to delete, says so and does not fail the run' {
        $script:keepRevision = 2
        $r = Remove-HygBrokenSupersedence -Plan $script:plan -DeleteOldRevisions
        $r.Success | Should -BeTrue
        $r.Results[0].Result | Should -Be 'Removed'
        $r.Results[0].RevisionsDeleted | Should -Be 1
        $r.Results[0].RevisionNote | Should -Match 'revision 2'
        $r.Results[0].RevisionNote | Should -Match 'another object'
    }

    It 'does not delete revisions of an application that it did not change' {
        $script:apps['S/Application_gone'] = New-SupApp -Model 'S/Application_gone' -Name 'Back'
        $r = Remove-HygBrokenSupersedence -Plan $script:plan -DeleteOldRevisions
        $r.Skipped | Should -Be 1
        $script:revisionCalls.Count | Should -Be 0
    }

    It 'refuses to write when the edited document differs in more than the broken rule' {
        $script:extra = $true
        $r = Remove-HygBrokenSupersedence -Plan $script:plan -DeleteOldRevisions
        $r.Success | Should -BeFalse
        $r.Results[0].Result | Should -Be 'Failed'
        $r.Results[0].Message | Should -Match 'more than the broken rules'
        $script:putCount | Should -Be 0
        $script:revisionCalls.Count | Should -Be 0
    }

    It 'refuses everything when the serializer is not the one of the console' {
        $script:serializerOk = $false
        $r = Remove-HygBrokenSupersedence -Plan $script:plan -DeleteOldRevisions
        $r.Success | Should -BeFalse
        $r.Results[0].Result | Should -Be 'Skipped'
        $r.Message | Should -Match 'another folder'
        $script:putCount | Should -Be 0
    }

    It 'reports a failed write as Failed' {
        $script:fail = $true
        $r = Remove-HygBrokenSupersedence -Plan $script:plan
        $r.Success | Should -BeFalse
        $r.Failed | Should -Be 1
        $script:putCount | Should -Be 0
    }

    It 'writes one log line for each change with the names of the application and the deployment type only' {
        $null = Remove-HygBrokenSupersedence -Plan $script:plan
        $line = @($script:logged | Where-Object { $_ -match 'removed the broken reference' })
        $line.Count | Should -Be 1
        $line[0] | Should -Match 'New App'
        $line[0] | Should -Match 'Install N'
        ($script:logged -join ' ') | Should -Not -Match 'Application_gone|ScopeId|S/'
    }

    It 'writes nothing with -WhatIf' {
        $r = Remove-HygBrokenSupersedence -Plan $script:plan -DeleteOldRevisions -WhatIf
        $r.Removed | Should -Be 0
        $script:putCount | Should -Be 0
        $script:revisionCalls.Count | Should -Be 0
    }

    It 'stops before the next application when a stop is requested' {
        $state = [hashtable]::Synchronized(@{ StopRequested = $true })
        $r = Remove-HygBrokenSupersedence -Plan $script:plan -State $state
        $r.Removed | Should -Be 0
        $r.Skipped | Should -Be 1
    }

    It 'has nothing to do for an empty plan' {
        $r = Remove-HygBrokenSupersedence -Plan ([pscustomobject]@{ Rows = @(); Applications = @() })
        $r.Success | Should -BeTrue
        $r.Removed | Should -Be 0
    }
}

Describe 'Test-HygSupersedenceRecheck' {
    It 'runs SUP-01 again on fresh data and counts what is left, with the old revisions' {
        $script:rules = @(@{ Id = 'DTRule_gone'; Models = @('S/Application_gone') })
        Mock Get-CMApplication {
            if ($ModelName -eq 'S/Application_new') { $a = New-SupApp -Model 'S/Application_new' -Name 'New App' -Xml (New-SupXml -Rules $script:rules) -CI 7; $a.CIVersion = 3; $a }
        } -ModuleName SiteHygieneCommon
        Mock Get-CMApplicationRevisionHistory { foreach ($v in 1, 2, 3) { [pscustomobject]@{ CIVersion = $v } } } -ModuleName SiteHygieneCommon
        $before = Test-HygSupersedenceRecheck -ApplicationModelName 'S/Application_new'
        $before.Remaining | Should -Be 1
        $before.OldRevisions | Should -Be 2
        $script:rules = @()
        $after = Test-HygSupersedenceRecheck -ApplicationModelName 'S/Application_new'
        $after.Remaining | Should -Be 0
    }
}
