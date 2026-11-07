#Requires -Modules Pester
# Every ConfigMgr cmdlet call in the modules, and every ConfigMgr cmdlet that a fix script or fix guidance
# names, uses only parameters that the real cmdlet has. Mocks accept any parameter name the test stub
# declares, so a wrong parameter name passes a mocked test and fails on a site. This test checks against
# the real cmdlet signature, and is skipped on a machine without the ConfigMgr console. It reads the
# parameters written as -Name, and the keys of a splatted hashtable (@params) that the function builds
# with a literal or with $params['Key'].
#
# A fix script is text inside a string, so the calls are read from the text of each -FixScript argument
# of New-HygieneFinding: {0} placeholders become a dummy value, the text is parsed, and the cmdlet calls
# are read from the syntax tree. A comment line is guidance for the operator: the cmdlets it names are
# read with a pattern, because the operator copies them into a console.

BeforeDiscovery {
    . "$PSScriptRoot\TestHelpers.ps1"
    $script:CmAvailable = $false
    $candidates = @('C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1',
        'C:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1')
    if (Get-Command Get-CMApplication -ErrorAction SilentlyContinue) { $script:CmAvailable = $true }
    else {
        foreach ($c in $candidates) {
            if (Test-Path -LiteralPath $c) {
                try { Import-Module $c -DisableNameChecking -ErrorAction Stop -WarningAction SilentlyContinue; $script:CmAvailable = [bool](Get-Command Get-CMApplication -ErrorAction SilentlyContinue); break } catch { $null = $_ }
            }
        }
    }
    $script:Calls = @(foreach ($m in 'SiteHygieneCommon.psm1', 'SiteHygieneLive.psm1') { Get-CmCmdletCall -Path (Join-Path $script:AppRoot "Module\$m") })

    $script:FixTexts = @(Get-FixScriptText -Path (Join-Path $script:AppRoot 'Module\SiteHygieneCommon.psm1')) + @(Get-GeneratedFixText)
}

BeforeAll {
    . "$PSScriptRoot\TestHelpers.ps1"
    $script:Found = @(foreach ($m in 'SiteHygieneCommon.psm1', 'SiteHygieneLive.psm1') { Get-CmCmdletCall -Path (Join-Path $script:AppRoot "Module\$m") })

    $script:FixTexts = @(Get-FixScriptText -Path (Join-Path $script:AppRoot 'Module\SiteHygieneCommon.psm1')) + @(Get-GeneratedFixText)
    $script:FixCalls = @()
    foreach ($f in @($script:FixTexts)) { foreach ($c in (Get-FixTextCall -Text $f.Text)) { $c.Line = $f.Line; $script:FixCalls += $c } }
}

Describe 'ConfigMgr cmdlet calls' {
    It 'finds the ConfigMgr cmdlet calls of the modules' {
        $script:Found.Count | Should -BeGreaterThan 8
    }

    It 'reads the keys of a splatted hashtable and the named parameters' {
        $f = Join-Path $TestDrive 'sample.ps1'
        Set-Content -LiteralPath $f -Value @(
            'function Demo {'
            '    $p = @{ A = 1; ErrorAction = ''Stop'' }'
            '    $p[''B''] = 2'
            '    $p.C = 3'
            '    New-CMThing @p -D 4'
            '    Copy-CMOther -E 5'
            '}')
        $calls = @(Get-CmCmdletCall -Path $f)
        $calls.Count | Should -Be 2
        ($calls | Where-Object Command -eq 'New-CMThing').Parameters | Should -Be @('A', 'ErrorAction', 'B', 'C', 'D')
        ($calls | Where-Object Command -eq 'Copy-CMOther').Parameters | Should -Be @('E')
    }

    It '<Command> at line <Line> uses only real parameters (<Parameters>)' -ForEach $script:Calls -Skip:(-not $script:CmAvailable) {
        $cmd = Get-Command $Command -ErrorAction Stop
        foreach ($p in $Parameters) {
            $exact = @($cmd.Parameters.Values | Where-Object { $_.Name -eq $p -or $_.Aliases -contains $p })
            if ($exact.Count -eq 0) {
                # PowerShell binds a prefix that names exactly one parameter.
                $exact = @($cmd.Parameters.Keys | Where-Object { $_ -like "$p*" })
                $exact.Count | Should -Be 1 -Because "-$p must name exactly one parameter of $Command (found $($exact.Count))"
            }
        }
    }
}

Describe 'ConfigMgr cmdlets in fix scripts and fix guidance' {
    It 'finds the fix texts and the cmdlets they name' {
        @($script:FixTexts).Count | Should -BeGreaterThan 50
        @($script:FixCalls).Count | Should -BeGreaterThan 30
    }

    It 'reads both cmdlets of a piped call, including Resume, with the named parameters' {
        $calls = @(Get-FixTextCall -Text "Get-CMApplication -Name 'x' -DisableWildcardHandling | Resume-CMApplication")
        $calls.Count | Should -Be 2
        ($calls | Where-Object Command -eq 'Resume-CMApplication').Count | Should -Be 1
        ($calls | Where-Object Command -eq 'Get-CMApplication').Parameters | Should -Be @('Name', 'DisableWildcardHandling')
    }

    It 'includes the generated APP-05 script in the fix texts' {
        @($script:FixTexts | Where-Object { $_.Text -like '*Remove-CMApplicationRevisionHistory*' }).Count | Should -BeGreaterThan 0
    }

    It 'reads a cmdlet named in a comment and ignores quoted text, placeholders and the text after a second comment mark' {
        $calls = @(Get-FixTextCall -Text "# Per device: Remove-CMDevice -Name '<name> -Force' -Force  # verify first")
        $calls.Count | Should -Be 1
        $calls[0].Command | Should -Be 'Remove-CMDevice'
        $calls[0].Parameters | Should -Be @('Name', 'Force')
    }

    It 'names the fix cmdlet <Command> from fix text line <Line> with real parameters (<Parameters>)' -ForEach @($script:FixTexts | ForEach-Object { $line = $_.Line; foreach ($c in @(Get-FixTextCall -Text $_.Text)) { @{ Command = $c.Command; Parameters = $c.Parameters; Line = $line } } }) -Skip:(-not $script:CmAvailable) {
        $cmd = Get-Command $Command -ErrorAction Stop
        foreach ($p in $Parameters) {
            $exact = @($cmd.Parameters.Values | Where-Object { $_.Name -eq $p -or $_.Aliases -contains $p })
            if ($exact.Count -eq 0) {
                $exact = @($cmd.Parameters.Keys | Where-Object { $_ -like "$p*" })
                $exact.Count | Should -Be 1 -Because "-$p must name exactly one parameter of $Command (found $($exact.Count))"
            }
        }
    }
}
