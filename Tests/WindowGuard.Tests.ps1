#Requires -Modules Pester
# The guard that keeps window tests from opening a window unless the opt-in is set. This file opens no window.
# It checks the guard function with injected values, and checks that every test file that can open a window uses the guard.

BeforeDiscovery {
    # Every script of the test folder except the harness and this file: each one is checked for windows that stay open.
    $script:CleanupFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File -Recurse |
            Where-Object { $_.Name -notin 'WindowHarness.ps1', 'WindowGuard.Tests.ps1' } |
            ForEach-Object { @{ Name = $_.FullName.Substring($PSScriptRoot.Length + 1); Path = $_.FullName } })
}

BeforeAll {
    . "$PSScriptRoot\WindowHarness.ps1"

    # Returns the lines of the places that open a window (.Show(), .ShowDialog(), Open-TestWindow) outside the Body of a
    # try statement that has a finally block. Only the Body counts: a window opened in the finally itself is not covered.
    function Get-UnguardedWindowOpen {
        param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)
        $isOpen = {
            param($n)
            ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Member.Value -in 'Show', 'ShowDialog') -or
            ($n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Open-TestWindow')
        }
        $tries = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] -and $null -ne $n.Finally }, $true))
        foreach ($open in @($Ast.FindAll($isOpen, $true))) {
            $covered = @($tries | Where-Object { $open.Extent.StartOffset -ge $_.Body.Extent.StartOffset -and $open.Extent.EndOffset -le $_.Body.Extent.EndOffset })
            if ($covered.Count -eq 0) { $open.Extent.StartLineNumber }
        }
    }
}

Describe 'Test-WindowTestsAllowed' {
    It 'allows the window tests with the opt-in 1' {
        $g = Test-WindowTestsAllowed -OptIn '1'
        $g.Allowed | Should -BeTrue
        $g.Reason | Should -Be ''
    }

    It 'refuses the window tests when the opt-in is <Case>' -ForEach @(
        @{ Case = 'empty'; OptIn = '' }, @{ Case = 'null'; OptIn = $null }, @{ Case = '0'; OptIn = '0' }, @{ Case = 'true'; OptIn = 'true' }, @{ Case = '11'; OptIn = '11' }
    ) {
        $g = Test-WindowTestsAllowed -OptIn $OptIn
        $g.Allowed | Should -BeFalse
        $g.Reason | Should -Be 'SUITE_ALLOW_WINDOW_TESTS is not 1'
    }

    It 'reads the opt-in from the environment by default' {
        $g = Test-WindowTestsAllowed
        $g.Allowed | Should -Be ($env:SUITE_ALLOW_WINDOW_TESTS -eq '1')
    }
}

Describe 'Test-WindowTestsAllowed signature' {
    It 'has no ComputerName parameter' {
        (Get-Command Test-WindowTestsAllowed).Parameters.ContainsKey('ComputerName') | Should -BeFalse
    }

    It 'has only the OptIn parameter of its own' {
        $own = @((Get-Command Test-WindowTestsAllowed).Parameters.Keys | Where-Object { $_ -notin [System.Management.Automation.PSCmdlet]::CommonParameters })
        $own | Should -Be @('OptIn')
    }

    It 'decides on the opt-in only' {
        (Test-WindowTestsAllowed -OptIn '1').Allowed | Should -BeTrue
        (Test-WindowTestsAllowed -OptIn '0').Allowed | Should -BeFalse
    }
}

Describe 'Window test files' {
    It 'uses the guard in <Name>, which can open a window' -ForEach @(
        Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' -File |
            Where-Object { $_.Name -ne 'WindowGuard.Tests.ps1' -and (Select-String -LiteralPath $_.FullName -Pattern 'Invoke-WpfSta|New-WpfWindow|ShowDialog|\.Show\(\)' -Quiet) } |
            ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
    ) {
        [System.IO.File]::ReadAllText($Path) | Should -Match 'Test-WindowTestsAllowed'
        [System.IO.File]::ReadAllText($Path) | Should -Match '-Skip:\(-not \$script:WindowGuard\.Allowed\)'
    }

    It 'finds at least one test file that can open a window' {
        @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' -File | Where-Object { (Select-String -LiteralPath $_.FullName -Pattern 'Invoke-WpfSta' -Quiet) }).Count | Should -BeGreaterThan 0
    }

    It 'creates windows only inside an if statement that tests the guard' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Window.Tests.ps1'), [ref]$null, [ref]$null)
        $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-WpfSta' }, $true))
        $calls.Count | Should -BeGreaterThan 0
        foreach ($c in $calls) {
            # An It block runs only when its Describe is not skipped, so a call inside a skipped Describe is guarded too.
            $guarded = $false
            for ($p = $c.Parent; $p; $p = $p.Parent) {
                if ($p -is [System.Management.Automation.Language.IfStatementAst] -and ($p.Clauses | Where-Object { $_.Item1.Extent.Text -match 'WindowGuard\.Allowed' })) { $guarded = $true; break }
                if ($p -is [System.Management.Automation.Language.CommandAst] -and $p.GetCommandName() -eq 'Describe' -and $p.Extent.Text -match '-Skip:\(-not \$script:WindowGuard\.Allowed\)') { $guarded = $true; break }
            }
            $guarded | Should -BeTrue -Because ('line {0} opens a window outside the guard' -f $c.Extent.StartLineNumber)
        }
    }
    It 'closes a session that was never opened without an error' {
        { Close-WpfSession } | Should -Not -Throw
    }
}

Describe 'Window cleanup: no window stays open after a test' {
    It 'closes the windows that a call leaves open inside the finally block of Invoke-WpfSta' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'WindowHarness.ps1'), [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-WpfSta' }, $true)
        $fn | Should -Not -BeNullOrEmpty
        $tries = @($fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] -and $null -ne $n.Finally }, $true))
        @($tries | Where-Object { $_.Finally.Extent.Text -match 'Close-SuiteOpenWindow' }).Count | Should -BeGreaterThan 0
    }

    It 'finds an unguarded window open in text, and accepts one inside a try with a finally' {
        $bad = [System.Management.Automation.Language.Parser]::ParseInput('$w = Open-TestWindow -XamlPath x; $w.Show(); $w.Close()', [ref]$null, [ref]$null)
        @(Get-UnguardedWindowOpen -Ast $bad).Count | Should -Be 2
        $noFinally = [System.Management.Automation.Language.Parser]::ParseInput('try { $w = Open-TestWindow -XamlPath x } catch { $null = $_ }', [ref]$null, [ref]$null)
        @(Get-UnguardedWindowOpen -Ast $noFinally).Count | Should -Be 1
        $inFinally = [System.Management.Automation.Language.Parser]::ParseInput('try { 1 } finally { $d.ShowDialog() }', [ref]$null, [ref]$null)
        @(Get-UnguardedWindowOpen -Ast $inFinally).Count | Should -Be 1
        $good = [System.Management.Automation.Language.Parser]::ParseInput('try { $w = Open-TestWindow -XamlPath x; $w.Show() } finally { if ($w) { $w.Close() } }', [ref]$null, [ref]$null)
        @(Get-UnguardedWindowOpen -Ast $good).Count | Should -Be 0
    }

    It 'opens a window in <Name> only inside a try with a finally' -ForEach $script:CleanupFiles {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $lines = @(Get-UnguardedWindowOpen -Ast $ast)
        $lines | Should -BeNullOrEmpty -Because ('line {0}: a window is opened outside a try with a finally, so a failure leaves it on the desktop' -f ($lines -join ', '))
    }
}
