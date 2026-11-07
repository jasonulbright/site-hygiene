#Requires -Modules Pester
# Fix execution and fix script text. Run Fix executes the text of a finding's FixScript against the site,
# so this file checks both halves: how Invoke-HygieneFix runs a script (success, failure, partial failure,
# -WhatIf, display-only), and what the checks write into the script (names that carry quotes, wildcards or
# line breaks, and placeholders that no site can run).

BeforeAll {
    . "$PSScriptRoot\TestHelpers.ps1"
    Import-AppModule
    $script:Stubs = New-CmStub -Name 'Remove-CMApplication', 'Remove-CMPackage', 'Remove-CMCollection', 'Get-CMApplicationDeployment', 'Remove-CMApplicationDeployment', 'Get-CMAutoDeploymentRule', 'Remove-CMAutoDeploymentRule', 'Invoke-CMSoftwareUpdateAutoDeploymentRule', 'Remove-CMMaintenanceWindow'

    # The quote characters that PowerShell reads as a single quote inside a single-quoted string.
    $script:QuoteChars = @([string][char]0x27, [string][char]0x2018, [string][char]0x2019, [string][char]0x201A, [string][char]0x201B)

    # Parses fix text. Returns the number of parse errors, the number of statements and the string
    # constants that stand as command arguments.
    function Get-FixParse {
        param([Parameter(Mandatory)][string]$Text)
        $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$errs)
        $strings = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.StringConstantType -eq 'SingleQuoted' }, $true) | ForEach-Object { $_.Value })
        [PSCustomObject]@{ Errors = @($errs).Count; Statements = @($ast.EndBlock.Statements).Count; Strings = $strings }
    }

    function New-FixApp {
        param([string]$Name, [bool]$Deployed = $false, [bool]$Expired = $false, [bool]$Superseded = $false)
        [PSCustomObject]@{
            CI_ID = 1; ModelName = 'ScopeId_A/Application_1'; Name = $Name; IsDeployed = $Deployed; IsExpired = $Expired
            IsSuperseded = $Superseded; IsSuperseding = $false; PackageID = ''; DateCreated = (Get-Date).AddDays(-400)
        }
    }

    # One finding from each check that writes a name into an executable fix script. Each row names the name
    # slots (Names) that the finding holds, so a test can look for each one in the parsed script.
    function Get-NameFinding {
        param([Parameter(Mandatory)][string]$Name, [string]$Second = 'Collection')
        $data = [PSCustomObject]@{
            Applications          = @(New-FixApp -Name $Name)
            TaskSequences         = @()
            DependencyTargetCIIDs = @()
        }
        $retired = [PSCustomObject]@{ Applications = @(New-FixApp -Name $Name -Deployed $true -Expired $true) }
        $superseded = [PSCustomObject]@{ Applications = @(New-FixApp -Name $Name -Deployed $true -Superseded $true) }
        $expired = [PSCustomObject]@{ AppDeployments = @([PSCustomObject]@{ ApplicationName = $Name; CollectionName = $Second; TargetCollectionID = 'XYZ00001'; ExpirationTime = (Get-Date).AddDays(-3) }) }
        $adrs = [PSCustomObject]@{ AutoDeploymentRules = @(
                [PSCustomObject]@{ Name = $Name; AutoDeploymentEnabled = $true; LastRunTime = $null; LastErrorCode = 5 }
                [PSCustomObject]@{ Name = $Name; AutoDeploymentEnabled = $false; LastRunTime = $null; LastErrorCode = 0 }
                [PSCustomObject]@{ Name = $Name; AutoDeploymentEnabled = $true; LastRunTime = (Get-Date).AddDays(-400); LastErrorCode = 0 }) }
        $windows = [PSCustomObject]@{
            Collections        = @([PSCustomObject]@{ CollectionID = 'XYZ00001'; Name = $Second })
            MaintenanceWindows = @([PSCustomObject]@{ CollectionID = 'XYZ00001'; Name = $Name; RecurrenceType = 1; StartTime = (Get-Date).AddDays(-30); Duration = 60; IsEnabled = $true })
        }
        @{ Check = 'APP-01'; Finding = @(Test-HygAppNoReferences -Data $data); Names = @($Name) }
        @{ Check = 'APP-02'; Finding = @(Test-HygAppRetiredDeployed -Data $retired); Names = @($Name) }
        @{ Check = 'APP-03'; Finding = @(Test-HygAppSupersededDeployed -Data $superseded); Names = @($Name) }
        @{ Check = 'DPL-01'; Finding = @(Test-HygDeploymentExpired -Data $expired); Names = @($Name, $Second) }
        @{ Check = 'UPD-03 error'; Finding = @(Test-HygAdrChecks -Data $adrs | Select-Object -Skip 0 -First 1); Names = @($Name) }
        @{ Check = 'UPD-03 disabled'; Finding = @(Test-HygAdrChecks -Data $adrs | Select-Object -Skip 1 -First 1); Names = @($Name) }
        @{ Check = 'UPD-03 stale'; Finding = @(Test-HygAdrChecks -Data $adrs | Select-Object -Skip 2 -First 1); Names = @($Name) }
        @{ Check = 'COL-10'; Finding = @(Test-HygMaintenanceWindowExpired -Data $windows); Names = @($Name) }
    }
    $script:NameFinding = @{}
}

AfterAll { Remove-CmStub -Name $script:Stubs }

Describe 'Invoke-HygieneFix' {
    BeforeEach {
        $script:logged = [System.Collections.ArrayList]::new()
        Mock Write-Log { [void]$script:logged.Add(@{ Message = $Message; Level = $Level }) } -ModuleName SiteHygieneCommon
        Mock Get-Location { [PSCustomObject]@{ Provider = [PSCustomObject]@{ Name = 'CMSite' } } } -ModuleName SiteHygieneCommon
        Mock Remove-CMApplication { 'removed' } -ModuleName SiteHygieneCommon
        Mock Remove-CMPackage { 'package removed' } -ModuleName SiteHygieneCommon
    }

    It 'runs the script, returns its output and logs the script and the outcome' {
        $f = [PSCustomObject]@{ CheckId = 'APP-01'; ObjectName = 'App One'; FixScript = "Remove-CMApplication -Name 'App One' -Force" }
        $r = Invoke-HygieneFix -Finding $f
        $r.Success | Should -BeTrue
        $r.Output | Should -Be 'removed'
        $r.ErrorMessage | Should -Be ''
        Should -Invoke Remove-CMApplication -ModuleName SiteHygieneCommon -Times 1 -Exactly -ParameterFilter { $Name -eq 'App One' -and $Force }
        @($script:logged | Where-Object { $_.Message -ceq "Fix executing [APP-01] App One: Remove-CMApplication -Name 'App One' -Force" }).Count | Should -Be 1
        @($script:logged | Where-Object { $_.Message -ceq 'Fix succeeded [APP-01] App One' }).Count | Should -Be 1
    }

    It 'returns a failure and runs no later line when a cmdlet throws' {
        Mock Remove-CMApplication { throw 'The application is in use.' } -ModuleName SiteHygieneCommon
        $f = [PSCustomObject]@{ CheckId = 'APP-01'; ObjectName = 'App One'; FixScript = "Remove-CMApplication -Name 'App One' -Force`r`nRemove-CMPackage -Id 'P0000001' -Force" }
        $r = Invoke-HygieneFix -Finding $f
        $r.Success | Should -BeFalse
        $r.ErrorMessage | Should -Be 'The application is in use.'
        Should -Invoke Remove-CMPackage -ModuleName SiteHygieneCommon -Times 0 -Exactly
        @($script:logged | Where-Object { $_.Level -eq 'ERROR' -and $_.Message -like 'Fix FAILED*' }).Count | Should -Be 1
        @($script:logged | Where-Object { $_.Message -like 'Fix succeeded*' }).Count | Should -Be 0
    }

    It 'reports a failure and stops when a cmdlet writes a non-terminating error' {
        Mock Remove-CMApplication { Write-Error 'Cannot find the application.' } -ModuleName SiteHygieneCommon
        $f = [PSCustomObject]@{ CheckId = 'APP-01'; ObjectName = 'App One'; FixScript = "Remove-CMApplication -Name 'App One' -Force`r`nRemove-CMPackage -Id 'P0000001' -Force" }
        $r = Invoke-HygieneFix -Finding $f
        $r.Success | Should -BeFalse
        $r.ErrorMessage | Should -Be 'Cannot find the application.'

        @($script:logged | Where-Object { $_.Message -like 'Fix succeeded*' }).Count | Should -Be 0
    }

    It 'does not run anything with -WhatIf and says so' {
        $f = [PSCustomObject]@{ CheckId = 'APP-01'; ObjectName = 'App One'; FixScript = "Remove-CMApplication -Name 'App One' -Force" }
        $r = Invoke-HygieneFix -Finding $f -WhatIf
        $r.Success | Should -BeFalse
        $r.ErrorMessage | Should -BeLike '*WhatIf*'
        Should -Invoke Remove-CMApplication -ModuleName SiteHygieneCommon -Times 0 -Exactly
    }

    It 'runs without a prompt when the caller passes -Confirm:$false' {
        $f = [PSCustomObject]@{ CheckId = 'APP-01'; ObjectName = 'App One'; FixScript = "Remove-CMApplication -Name 'App One' -Force" }
        $r = Invoke-HygieneFix -Finding $f -Confirm:$false
        $r.Success | Should -BeTrue
        Should -Invoke Remove-CMApplication -ModuleName SiteHygieneCommon -Times 1 -Exactly
    }

    It 'refuses a finding with <Case> as the fix script' -ForEach @(
        @{ Case = 'no text'; Script = $null }
        @{ Case = 'an empty string'; Script = '' }
        @{ Case = 'only white space'; Script = "   `r`n  " }
        @{ Case = 'only a comment'; Script = '# Console: do it there' }
    ) {
        $f = [PSCustomObject]@{ CheckId = 'X-01'; ObjectName = 'x'; FixScript = $Script }
        $r = Invoke-HygieneFix -Finding $f
        $r.Success | Should -BeFalse
        $r.ErrorMessage | Should -BeLike '*display-only*'
        Should -Invoke Remove-CMApplication -ModuleName SiteHygieneCommon -Times 0 -Exactly
    }

    It 'refuses to run when the current location is not the site drive' {
        Mock Get-Location { [PSCustomObject]@{ Provider = [PSCustomObject]@{ Name = 'FileSystem' } } } -ModuleName SiteHygieneCommon
        $f = [PSCustomObject]@{ CheckId = 'APP-01'; ObjectName = 'x'; FixScript = "Remove-CMApplication -Name 'x' -Force" }
        $r = Invoke-HygieneFix -Finding $f
        $r.Success | Should -BeFalse
        $r.ErrorMessage | Should -BeLike '*site drive*'
        Should -Invoke Remove-CMApplication -ModuleName SiteHygieneCommon -Times 0 -Exactly
    }

    It 'reports a script that does not parse as a failure' {
        $f = [PSCustomObject]@{ CheckId = 'APP-01'; ObjectName = 'x'; FixScript = "Remove-CMApplication -Name 'unterminated" }
        $r = Invoke-HygieneFix -Finding $f
        $r.Success | Should -BeFalse
        $r.ErrorMessage | Should -Not -BeNullOrEmpty
    }
}

Describe 'Test-HygieneFixExecutable' {
    It 'answers <Expected> for <Case>' -ForEach @(
        @{ Case = 'a null script'; Text = $null; Expected = $false }
        @{ Case = 'a script of blank lines'; Text = "`r`n   `r`n"; Expected = $false }
        @{ Case = 'comment lines with leading space'; Text = "   # one`r`n`t# two"; Expected = $false }
        @{ Case = 'a command after a comment line'; Text = "# note`r`nRemove-CMPackage -Id 'P1' -Force"; Expected = $true }
        @{ Case = 'LF line ends'; Text = "# note`nRemove-CMPackage -Id 'P1'"; Expected = $true }
    ) {
        Test-HygieneFixExecutable -FixScript $Text | Should -Be $Expected
    }
}

Describe 'Fix scripts with names that carry quotes' {
    It 'keeps the name with quote <Label> inside one literal for <Check>' -ForEach @(
        foreach ($q in 0..4) {
            foreach ($check in 'APP-01', 'APP-02', 'APP-03', 'DPL-01', 'UPD-03 error', 'UPD-03 disabled', 'UPD-03 stale', 'COL-10') {
                @{ Quote = $q; Label = @('U+0027', 'U+2018', 'U+2019', 'U+201A', 'U+201B')[$q]; Check = $check; Runnable = ($check -ne 'UPD-03 error') }
            }
        }
    ) {
        $mark = $script:QuoteChars[$Quote]
        $name = 'Bob{0}s App' -f $mark
        $second = 'Team{0}s Devices' -f $mark
        $row = @(Get-NameFinding -Name $name -Second $second | Where-Object { $_.Check -eq $Check })[0]
        $row.Finding.Count | Should -Be 1
        $text = [string]$row.Finding[0].FixScript
        Test-HygieneFixExecutable -FixScript $text | Should -Be $Runnable
        $p = Get-FixParse -Text $text
        $p.Errors | Should -Be 0 -Because "the script must parse: $text"
        $p.Statements | Should -Be $(if ($Runnable) { 1 } else { 0 })
        if ($Runnable) {
            foreach ($n in $row.Names) {
                @($p.Strings) | Should -Contain $n -Because "the name must arrive as one literal in: $text"
            }
        }
    }

    It 'does not let a name run a second command' {
        $evil = ('x{0}; Remove-CMCollection -Id {0}SMS00001{0} -Force; {0}' -f [string][char]0x2019)
        $row = @(Get-NameFinding -Name $evil | Where-Object { $_.Check -eq 'APP-01' })[0]
        $p = Get-FixParse -Text ([string]$row.Finding[0].FixScript)
        $p.Errors | Should -Be 0
        $p.Statements | Should -Be 1
        [string]$row.Finding[0].FixScript | Should -Not -Match 'Remove-CMCollection.*-Force.*Remove-CMApplication'
    }

    It 'has no quote doubling left outside the shared helper' {
        $src = [System.IO.File]::ReadAllText((Join-Path $script:AppRoot 'Module\SiteHygieneCommon.psm1'))
        ([regex]::Matches($src, '-replace\s+"''",\s*"''''"')).Count | Should -Be 0
    }
}

Describe 'Fix scripts with names that carry wildcard characters' {
    It 'selects <Check> by exact name' -ForEach @(
        @{ Check = 'APP-01'; Cmdlet = 'Remove-CMApplication' }
        @{ Check = 'APP-02'; Cmdlet = 'Get-CMApplicationDeployment' }
        @{ Check = 'APP-03'; Cmdlet = 'Get-CMApplicationDeployment' }
        @{ Check = 'DPL-01'; Cmdlet = 'Get-CMApplicationDeployment' }
        @{ Check = 'UPD-03 disabled'; Cmdlet = 'Get-CMAutoDeploymentRule' }
    ) {
        $row = @(Get-NameFinding -Name 'Tools [x64] *' | Where-Object { $_.Check -eq $Check })[0]
        $text = [string]$row.Finding[0].FixScript
        $text | Should -Match ('{0} .*-DisableWildcardHandling' -f $Cmdlet) -Because 'a [ ], * or ? in a name is a pattern for the cmdlet unless wildcard handling is off'
    }
}

Describe 'Fix guidance and placeholders' {
    It 'keeps a name with a line break from turning guidance into a runnable script' {
        $evil = "x`r`nRemove-CMCollection -Id 'SMS00001' -Force"
        $data = [PSCustomObject]@{
            Collections = @([PSCustomObject]@{ CollectionID = 'XYZ00001'; MemberCount = 0 })
            Deployments = @([PSCustomObject]@{ CollectionID = 'XYZ00001'; SoftwareName = $evil; CollectionName = $evil })
        }
        $f = @(Test-HygDeploymentEmptyCollection -Data $data)
        $f.Count | Should -Be 1
        Test-HygieneFixExecutable -FixScript $f[0].FixScript | Should -BeFalse
    }

    It 'collapses the line separators <Name> in guidance' -ForEach @(
        @{ Name = 'CR LF'; Sep = "`r`n" }
        @{ Name = 'LF'; Sep = "`n" }
        @{ Name = 'NEL'; Sep = [string][char]0x85 }
        @{ Name = 'LINE SEPARATOR'; Sep = [string][char]0x2028 }
        @{ Name = 'PARAGRAPH SEPARATOR'; Sep = [string][char]0x2029 }
    ) {
        $f = New-HygieneFinding -CheckId 'X-01' -Severity Info -Category 'C' -ObjectType 'T' -ObjectId 'i' -ObjectName 'n' -Evidence 'e' -Recommendation 'r' -FixScript ("# Review 'a{0}Remove-CMCollection -Id b'" -f $Sep)
        Test-HygieneFixExecutable -FixScript $f.FixScript | Should -BeFalse
        $f.FixScript | Should -BeLike "# Review 'a*Remove-CMCollection -Id b'"
    }

    It 'builds a finding for an object with an empty name' {
        $f = New-HygieneFinding -CheckId 'X-01' -Severity Info -Category 'C' -ObjectType 'T' -ObjectId 'i' -ObjectName '' -Evidence 'e' -Recommendation 'r'
        $f.ObjectName | Should -Be ''
    }

    It 'keeps the lines of a runnable multi-line script' {
        $f = New-HygieneFinding -CheckId 'X-01' -Severity Info -Category 'C' -ObjectType 'T' -ObjectId 'i' -ObjectName 'n' -Evidence 'e' -Recommendation 'r' -FixScript "Remove-CMPackage -Id 'P1' -Force`r`nRemove-CMPackage -Id 'P2' -Force"
        @($f.FixScript -split "`r`n").Count | Should -Be 2
    }

    It 'holds no placeholder in a script that Run Fix would execute' {
        $texts = @(Get-FixScriptText -Path (Join-Path $script:AppRoot 'Module\SiteHygieneCommon.psm1'))
        $texts.Count | Should -BeGreaterThan 50
        $bad = @($texts | Where-Object { (Test-HygieneFixExecutable -FixScript $_.Text) -and $_.Text -match "'<[^>']+>'" } | ForEach-Object { 'line {0}: {1}' -f $_.Line, $_.Text })
        $bad | Should -BeNullOrEmpty -Because 'Run Fix would send the placeholder text to the site'
    }

    It 'names the real parameter of Set-CMCollection in the incremental evaluation guidance' {
        $collections = 1..201 | ForEach-Object { [PSCustomObject]@{ CollectionID = 'XYZ{0:D5}' -f $_; Name = 'C{0}' -f $_; RefreshType = 4 } }
        $f = @(Test-HygIncrementalCeiling -Data ([PSCustomObject]@{ Collections = $collections }))
        $f.Count | Should -Be 1
        $f[0].FixScript | Should -Not -Match 'Set-CMCollection -Id\b'
        $f[0].FixScript | Should -Match 'Set-CMCollection -CollectionId'
    }
}

Describe 'Fixes for maintenance tasks and manufacturers' {
    BeforeAll {
        $script:Tasks = [PSCustomObject]@{ MaintenanceTasks = @(
                [PSCustomObject]@{ TaskName = 'Delete Aged Discovery Data'; Enabled = $false }
                [PSCustomObject]@{ TaskName = 'Backup Site Server'; Enabled = $false }) }
        $script:Found = @(Test-HygMaintenanceTasks -Data $script:Tasks)
    }

    It 'enables a cleanup task with the native cmdlet, by exact name, on the connected site' {
        $f = $script:Found | Where-Object CheckId -eq 'MNT-01'
        Test-HygieneFixExecutable -FixScript $f.FixScript | Should -BeTrue
        $f.FixScript | Should -Be 'Set-CMSiteMaintenanceTask -Name ''Delete Aged Discovery Data'' -Enabled $true -DisableWildcardHandling'
        $p = Get-FixParse -Text $f.FixScript
        $p.Errors | Should -Be 0
        $p.Statements | Should -Be 1
        $f.FixScript | Should -Not -Match '<'
    }

    It 'gives only guidance for the backup task and says a backup destination is needed' {
        $f = $script:Found | Where-Object CheckId -eq 'MNT-02'
        Test-HygieneFixExecutable -FixScript $f.FixScript | Should -BeFalse
        $f.FixScript | Should -Match '-SiteBackupPath'
        $f.Recommendation | Should -Match 'backup destination'
        $f.Recommendation | Should -Match 'Run Fix is not offered'
    }

    It 'gives only guidance for a missing manufacturer and says only a person knows the name' {
        $dt = "<AppMgmtDigest xmlns='http://schemas.microsoft.com/SystemCenterConfigurationManager/2009/AppMgmtDigest'><DeploymentType AuthoringScopeId='ScopeId_T' LogicalName='DeploymentType_X'><Title>Install</Title><Installer><Contents/></Installer><Supersedes/><Dependencies><DeploymentTypeRule xmlns='http://schemas.microsoft.com/SystemsCenterConfigurationManager/2009/06/14/Rules'><DeploymentTypeIntentExpression DesiredState='Required'><DeploymentTypeApplicationReference AuthoringScopeId='S' LogicalName='B'/></DeploymentTypeIntentExpression></DeploymentTypeRule></Dependencies></DeploymentType></AppMgmtDigest>"
        $apps = @(
            [PSCustomObject]@{ CI_ID = 1; ModelName = 'S/A'; Name = 'NoVendor'; SoftwareVersion = '1'; Manufacturer = ''; IsEnabled = $true; IsExpired = $false; IsSuperseded = $false; IsSuperseding = $false; HasContent = $true; NumberOfDeploymentTypes = 1; SDMPackageXML = $dt }
            [PSCustomObject]@{ CI_ID = 2; ModelName = 'S/B'; Name = 'HasVendor'; SoftwareVersion = '1'; Manufacturer = 'Contoso'; IsEnabled = $true; IsExpired = $false; IsSuperseded = $false; IsSuperseding = $false; HasContent = $true; NumberOfDeploymentTypes = 0; SDMPackageXML = '' })
        $parsed = ConvertTo-HygRelationships -Applications $apps
        $lookup = @{}
        foreach ($a in $apps) { $lookup[[int]$a.CI_ID] = $a }
        $rel = [PSCustomObject]@{ Apps = $lookup; Relationships = $parsed.Relationships; ContentLocations = $parsed.ContentLocations; DatasetNotes = $parsed.ParseNotes }
        $f = @(Test-HygRelationshipChecks -RelationshipData $rel | Where-Object CheckId -eq 'REL-01')
        $f.Count | Should -Be 1
        Test-HygieneFixExecutable -FixScript $f[0].FixScript | Should -BeFalse
        $f[0].Recommendation | Should -Match 'Run Fix is not offered'
        $f[0].Recommendation | Should -Match 'only a person knows'
    }
}