#Requires -Modules Pester
# The guard that keeps window tests from opening a window on the dev PC. This file opens no window. It checks
# the guard function with injected values, and checks that every test file that can open a window uses the guard.

BeforeAll {
    . "$PSScriptRoot\WindowHarness.ps1"
    $script:OtherName = 'CM01'
}

Describe 'Test-WindowTestsAllowed' {
    It 'refuses the dev PC <Name> even with the opt-in' -ForEach @(
        @{ Name = 'removed' }, @{ Name = 'removed' }, @{ Name = 'removed' }
    ) {
        $g = Test-WindowTestsAllowed -ComputerName $Name -OptIn '1'
        $g.Allowed | Should -BeFalse
        $g.Reason | Should -BeLike '*removed*'
    }

    It 'allows another computer with the opt-in 1' {
        $g = Test-WindowTestsAllowed -ComputerName $script:OtherName -OptIn '1'
        $g.Allowed | Should -BeTrue
        $g.Reason | Should -Be ''
    }

    It 'refuses another computer when the opt-in is <Case>' -ForEach @(
        @{ Case = 'empty'; OptIn = '' }, @{ Case = 'null'; OptIn = $null }, @{ Case = '0'; OptIn = '0' }, @{ Case = 'true'; OptIn = 'true' }, @{ Case = '11'; OptIn = '11' }
    ) {
        $g = Test-WindowTestsAllowed -ComputerName $script:OtherName -OptIn $OptIn
        $g.Allowed | Should -BeFalse
        $g.Reason | Should -Be 'SUITE_ALLOW_WINDOW_TESTS is not 1'
    }

    It 'gives a reason whenever it refuses' -ForEach @(
        @{ Name = 'removed'; OptIn = '1' }, @{ Name = 'removed'; OptIn = '' }, @{ Name = 'CLIENT01'; OptIn = '' }
    ) {
        (Test-WindowTestsAllowed -ComputerName $Name -OptIn $OptIn).Reason | Should -Not -BeNullOrEmpty
    }

    It 'reads the computer name and the opt-in from the environment by default' {
        $g = Test-WindowTestsAllowed
        $expected = ($env:COMPUTERNAME -ine 'removed') -and ($env:SUITE_ALLOW_WINDOW_TESTS -eq '1')
        $g.Allowed | Should -Be $expected
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
