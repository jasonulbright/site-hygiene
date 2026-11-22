#Requires -Modules Pester
# Per-site data (Q-112f). An old-layout tool folder is seeded in a temp folder. The path and prefs logic of the tool
# runs for site AB1, then site CD2, then AB1 again, and with no site. The tests check that the old files stay as they
# are, that AB1 data is copied once, that CD2 shows nothing of AB1 and writes only below sites\CD2.
# The site codes are fictional (AB1, CD2). The hosts use example.com.

BeforeAll {
    . "$PSScriptRoot\TestHelpers.ps1"
    Import-AppModule

    $script:envNames = 'APP_PACKAGER_DATA_ROOT', 'APP_PACKAGER_SITE', 'SUITE_CM_SITECODE', 'SUITE_CM_PROVIDER'
    $script:envSaved = @{}
    foreach ($n in $script:envNames) { $script:envSaved[$n] = [Environment]::GetEnvironmentVariable($n) }

    function Set-TestEnv {
        param([string]$Site, [string]$DataRoot)
        foreach ($n in $script:envNames) { [Environment]::SetEnvironmentVariable($n, $null) }
        [Environment]::SetEnvironmentVariable('APP_PACKAGER_DATA_ROOT', $DataRoot)
        if ($Site) { [Environment]::SetEnvironmentVariable('APP_PACKAGER_SITE', $Site) }
    }

    # The old single-site layout of the tool: files beside the script, site AB1.
    function New-OldLayout {
        param([Parameter(Mandatory)][string]$Base)
        $suite = Join-Path $Base 'suite'
        $tool = Join-Path $suite 'site-hygiene'
        New-Item -ItemType Directory -Path (Join-Path $tool 'History'), (Join-Path $tool 'Reports') -Force | Out-Null
        $prefs = [ordered]@{ DarkMode = $false; SiteCode = 'AB1'; SMSProvider = 'ab1-sms.example.com'; SQLServer = 'ab1-sql.example.com'; ProviderPacingMs = 25 }
        $prefs | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $tool 'SiteHygiene.prefs.json') -Encoding UTF8
        @{ Keys = @('APP-01|ab1-object') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $tool 'SiteHygiene.suppressions.json') -Encoding UTF8
        @{ SchemaVersion = 1; ScanTime = '2026-01-01T00:00:00.0000000+00:00'; Findings = @(@{ CheckId = 'APP-01'; ObjectName = 'ab1-object' }) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $tool 'SiteHygiene.lastscan.json') -Encoding UTF8
        ("Timestamp,CompliancePct`r`n{0},91" -f (Get-Date).AddDays(-1).ToString('o')) | Set-Content -LiteralPath (Join-Path $tool 'History\metrics-history.csv') -Encoding UTF8
        "Name`r`nab1-report" | Set-Content -LiteralPath (Join-Path $tool 'Reports\SiteHygiene-Findings-20260101-000000.csv') -Encoding UTF8
        return [pscustomobject]@{ Suite = $suite; Tool = $tool; Local = (Join-Path $Base 'local') }
    }

    function Get-SuppressionKeyCount {
        param([Parameter(Mandatory)][string]$Path)
        $s = Read-SuiteSettings -Path $Path -Defaults @{ Keys = @() }
        return @($s['Keys'] | Where-Object { $_ }).Count
    }

    function Get-OldFileHash {
        param([Parameter(Mandatory)][string]$Tool)
        $h = @{}
        foreach ($f in Get-ChildItem -LiteralPath $Tool -Recurse -File) { $h[$f.FullName] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash }
        return $h
    }

    function Start-ToolForSite {
        param([Parameter(Mandatory)]$Layout, [string]$Site, [Parameter(Mandatory)][string]$DataRoot)
        Set-TestEnv -Site $Site -DataRoot $DataRoot
        $prefsPath = Join-Path $Layout.Tool 'SiteHygiene.prefs.json'
        $siteInfo = Resolve-SuiteToolSite -Tool 'site-hygiene' -ToolRoot $Layout.Tool -LegacyPrefsPath $prefsPath -LocalRoot $Layout.Local
        $paths = Get-HygieneSitePath -Site $siteInfo -ToolRoot $Layout.Tool -Create
        $prefs = Read-HygienePreference -Path $paths.PrefsPath -Site $siteInfo
        return [pscustomobject]@{ Site = $siteInfo; Paths = $paths; Prefs = $prefs }
    }
}

AfterAll {
    foreach ($n in $script:envNames) { [Environment]::SetEnvironmentVariable($n, $script:envSaved[$n]) }
}

Describe 'Site Hygiene keeps its data per site' {
    BeforeAll {
        $script:base = Join-Path $TestDrive 'iso'
        $script:layout = New-OldLayout -Base $script:base
        $script:data = Join-Path $script:base 'data'
        $script:before = Get-OldFileHash -Tool $script:layout.Tool
        $script:ab1 = Start-ToolForSite -Layout $script:layout -Site 'AB1' -DataRoot $script:data
        $script:afterAb1 = Get-OldFileHash -Tool $script:layout.Tool
    }

    It 'uses the site AB1 and a site folder below the data root' {
        $script:ab1.Site.Active | Should -BeTrue
        $script:ab1.Site.SiteFolder | Should -Be 'AB1'
        $script:ab1.Site.ToolFolder | Should -BeLike (Join-Path $script:data '*\sites\AB1\tools\site-hygiene')
    }

    It 'leaves every old file as it was after the copy (SHA-256)' {
        $script:afterAb1.Count | Should -Be $script:before.Count
        foreach ($k in $script:before.Keys) { $script:afterAb1[$k] | Should -Be $script:before[$k] }
    }

    It 'copies the AB1 stores into the site folder once' {
        $tf = $script:ab1.Site.ToolFolder
        foreach ($name in 'lastscan.json', 'suppressions.json', 'history\metrics-history.csv', 'reports\SiteHygiene-Findings-20260101-000000.csv') {
            Test-Path -LiteralPath (Join-Path $tf $name) | Should -BeTrue -Because $name
        }
        (Get-FileHash -LiteralPath (Join-Path $tf 'lastscan.json')).Hash | Should -Be (Get-FileHash -LiteralPath (Join-Path $script:layout.Tool 'SiteHygiene.lastscan.json')).Hash
        $marker = Join-Path $tf 'migrated.json'
        $stamp = (Get-Item -LiteralPath $marker).LastWriteTimeUtc
        $again = Start-ToolForSite -Layout $script:layout -Site 'AB1' -DataRoot $script:data
        $again.Site.Migration | Should -Be 'done earlier'
        (Get-Item -LiteralPath $marker).LastWriteTimeUtc | Should -Be $stamp
    }

    It 'points every store path at the site folder' {
        $tf = $script:ab1.Site.ToolFolder
        $script:ab1.Paths.LastScanPath | Should -Be (Join-Path $tf 'lastscan.json')
        $script:ab1.Paths.SuppressPath | Should -Be (Join-Path $tf 'suppressions.json')
        $script:ab1.Paths.HistoryPath | Should -Be (Join-Path $tf 'history\metrics-history.csv')
        $script:ab1.Paths.ReportsDir | Should -Be (Join-Path $tf 'reports')
        $script:ab1.Paths.PrefsPath | Should -Be (Join-Path $script:layout.Tool 'SiteHygiene.prefs.json')
    }

    It 'reads the AB1 values and keeps the global key from the old prefs file' {
        $script:ab1.Prefs.SiteCode | Should -Be 'AB1'
        $script:ab1.Prefs.SMSProvider | Should -Be 'ab1-sms.example.com'
        $script:ab1.Prefs.SQLServer | Should -Be 'ab1-sql.example.com'
        $script:ab1.Prefs.DarkMode | Should -BeFalse
    }

    Context 'site CD2' {
        BeforeAll {
            $script:cd2 = Start-ToolForSite -Layout $script:layout -Site 'CD2' -DataRoot $script:data
        }

        It 'shows none of the AB1 values' {
            $script:cd2.Site.SiteFolder | Should -Be 'CD2'
            $script:cd2.Prefs.SiteCode | Should -Be 'CD2'
            $script:cd2.Prefs.SQLServer | Should -BeNullOrEmpty
            $script:cd2.Prefs.SMSProvider | Should -Not -Match 'ab1'
        }

        It 'gets no copy of the AB1 stores' {
            $tf = $script:cd2.Site.ToolFolder
            foreach ($name in 'lastscan.json', 'suppressions.json', 'history\metrics-history.csv', 'reports\SiteHygiene-Findings-20260101-000000.csv') {
                Test-Path -LiteralPath (Join-Path $tf $name) | Should -BeFalse -Because $name
            }
            (Get-SuppressionKeyCount -Path $script:cd2.Paths.SuppressPath) | Should -Be 0
            Read-HygieneScanResult -Path $script:cd2.Paths.LastScanPath | Should -BeNullOrEmpty
            @(Get-MetricsHistory -HistoryPath $script:cd2.Paths.HistoryPath).Count | Should -Be 0
        }

        It 'writes only below sites\CD2' {
            $ab1Files = Get-OldFileHash -Tool $script:ab1.Site.ToolFolder
            $oldFolderBefore = Get-OldFileHash -Tool $script:layout.Tool
            $cd2Prefs = @{} + $script:cd2.Prefs
            $cd2Prefs.SMSProvider = 'cd2-sms.example.com'
            $cd2Prefs.SQLServer = 'cd2-sql.example.com'
            Save-HygienePreference -Path $script:cd2.Paths.PrefsPath -Prefs $cd2Prefs -Site $script:cd2.Site | Should -BeTrue
            Save-HygieneScanResult -Findings @([pscustomobject]@{ CheckId = 'APP-01'; Severity = 'Low'; ObjectType = 'Application'; ObjectId = '1'; ObjectName = 'cd2-object'; Evidence = 'x' }) -Path $script:cd2.Paths.LastScanPath
            Add-MetricsHistoryEntry -HistoryPath $script:cd2.Paths.HistoryPath -DeploymentCounts ([pscustomobject]@{ TotalDeployments = 3; FailedDeployments = 0; OverallCompliance = 50 })
            Save-SuiteSettings -Path $script:cd2.Paths.SuppressPath -Settings @{ Keys = @('APP-01|cd2-object') } | Should -BeTrue
            $null = New-Item -ItemType Directory -Path $script:cd2.Paths.ReportsDir -Force
            Set-Content -LiteralPath (Join-Path $script:cd2.Paths.ReportsDir 'SiteHygiene-Findings-cd2.csv') -Value 'Name'
            $cd2Folder = $script:cd2.Site.ToolFolder
            foreach ($p in $script:cd2.Paths.LastScanPath, $script:cd2.Paths.SuppressPath, $script:cd2.Paths.HistoryPath, (Join-Path $script:cd2.Paths.ReportsDir 'SiteHygiene-Findings-cd2.csv'), (Join-Path $cd2Folder 'prefs.json')) {
                $p | Should -BeLike (Join-Path $script:data '*\sites\CD2\tools\site-hygiene\*')
                Test-Path -LiteralPath $p | Should -BeTrue -Because $p
            }
            $now = Get-OldFileHash -Tool $script:ab1.Site.ToolFolder
            foreach ($k in $ab1Files.Keys) { $now[$k] | Should -Be $ab1Files[$k] -Because $k }
            $now.Count | Should -Be $ab1Files.Count
            foreach ($k in $script:before.Keys | Where-Object { $_ -notlike '*SiteHygiene.prefs.json' }) { (Get-FileHash -LiteralPath $k).Hash | Should -Be $script:before[$k] -Because $k }
            # Nothing new appears beside the script. Only the old prefs file may change (its global keys).
            $oldFolderAfter = Get-OldFileHash -Tool $script:layout.Tool
            @($oldFolderAfter.Keys | Where-Object { -not $oldFolderBefore.ContainsKey($_) }) | Should -BeNullOrEmpty
            foreach ($k in $oldFolderBefore.Keys | Where-Object { $_ -notlike '*SiteHygiene.prefs.json' }) { $oldFolderAfter[$k] | Should -Be $oldFolderBefore[$k] -Because $k }
            $oldPrefs = Get-Content -LiteralPath (Join-Path $script:layout.Tool 'SiteHygiene.prefs.json') -Raw | ConvertFrom-Json
            $oldPrefs.SiteCode | Should -Be 'AB1'
            $oldPrefs.SMSProvider | Should -Be 'ab1-sms.example.com'
            $oldPrefs.SQLServer | Should -Be 'ab1-sql.example.com'
        }
    }

    Context 'back to site AB1' {
        It 'shows the AB1 values and stores again' {
            $back = Start-ToolForSite -Layout $script:layout -Site 'AB1' -DataRoot $script:data
            $back.Prefs.SiteCode | Should -Be 'AB1'
            $back.Prefs.SMSProvider | Should -Be 'ab1-sms.example.com'
            $back.Prefs.SQLServer | Should -Be 'ab1-sql.example.com'
            (Get-SuppressionKeyCount -Path $back.Paths.SuppressPath) | Should -Be 1
            @((Read-HygieneScanResult -Path $back.Paths.LastScanPath).Findings).ObjectName | Should -Be @('ab1-object')
            @(Get-MetricsHistory -HistoryPath $back.Paths.HistoryPath).Count | Should -Be 1
        }
    }
}

Describe 'Site Hygiene with no site chosen' {
    BeforeAll {
        $script:base2 = Join-Path $TestDrive 'nosite'
        $script:layout2 = New-OldLayout -Base $script:base2
        # An old prefs file with no site code names no site.
        @{ DarkMode = $true; SiteCode = ''; SMSProvider = 'old-sms.example.com' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:layout2.Tool 'SiteHygiene.prefs.json') -Encoding UTF8
        $script:none = Start-ToolForSite -Layout $script:layout2 -Site '' -DataRoot (Join-Path $script:base2 'data')
    }

    It 'is not active and keeps the old paths beside the script' {
        $script:none.Site.Active | Should -BeFalse
        $t = $script:layout2.Tool
        $script:none.Paths.LastScanPath | Should -Be (Join-Path $t 'SiteHygiene.lastscan.json')
        $script:none.Paths.SuppressPath | Should -Be (Join-Path $t 'SiteHygiene.suppressions.json')
        $script:none.Paths.HistoryPath | Should -Be (Join-Path $t 'History\metrics-history.csv')
        $script:none.Paths.ReportsDir | Should -Be (Join-Path $t 'Reports')
    }

    It 'creates no site folder' {
        Test-Path -LiteralPath (Join-Path $script:base2 'data') | Should -BeFalse
    }

    It 'reads the old prefs file' {
        $script:none.Prefs.SMSProvider | Should -Be 'old-sms.example.com'
        $script:none.Prefs.SiteCode | Should -BeNullOrEmpty
    }

    It 'fills an empty provider from the launcher provider variable only when no site is active' {
        Set-TestEnv -Site '' -DataRoot (Join-Path $script:base2 'data')
        @{ DarkMode = $true } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:layout2.Tool 'SiteHygiene.prefs.json') -Encoding UTF8
        [Environment]::SetEnvironmentVariable('SUITE_CM_PROVIDER', 'launcher-sms.example.com')
        $noSite = [pscustomobject]@{ Active = $false }
        (Read-HygienePreference -Path (Join-Path $script:layout2.Tool 'SiteHygiene.prefs.json') -Site $noSite).SMSProvider | Should -Be 'launcher-sms.example.com'
    }

    It 'saves to the old prefs file' {
        $noSite = [pscustomobject]@{ Active = $false }
        $p = Get-HygienePreferenceDefault
        $p.SiteCode = 'EF3'
        $p.SMSProvider = 'ef3-sms.example.com'
        Save-HygienePreference -Path $script:none.Paths.PrefsPath -Prefs $p -Site $noSite | Should -BeTrue
        (Get-Content -LiteralPath $script:none.Paths.PrefsPath -Raw | ConvertFrom-Json).SiteCode | Should -Be 'EF3'
    }
}

Describe 'Site Hygiene source builds no site store from the script folder' {
    BeforeAll {
        $script:scriptText = Get-Content -LiteralPath (Join-Path $script:AppRoot 'start-sitehygiene.ps1') -Raw
    }

    It 'builds no store path from the script folder in the window script' {
        [regex]::IsMatch($script:scriptText, 'Join-Path \$PSScriptRoot ''(Reports|History)[\'']') | Should -BeFalse
        [regex]::IsMatch($script:scriptText, 'Join-Path \$PSScriptRoot ''SiteHygiene\.(lastscan|suppressions)\.json''') | Should -BeFalse
    }

    It 'sets the Site Code field read-only with the launcher tooltip when a site is active' {
        $script:scriptText.Contains('$txtSiteCode.IsReadOnly = $true') | Should -BeTrue
        $script:scriptText.Contains('The site is chosen in the AppPackager Suite launcher. Restart this tool after you change it.') | Should -BeTrue
        $script:scriptText.Contains('Start-SuiteSiteWatch -Window $window -Site $script:Site') | Should -BeTrue
        $script:scriptText.IndexOf('Initialize-SuiteFooter') | Should -BeLessThan $script:scriptText.IndexOf('Start-SuiteSiteWatch')
        $script:scriptText.Contains('$newSite     = $(if ($script:Site.Active) { [string]$global:Prefs.SiteCode }') | Should -BeTrue
    }
}
