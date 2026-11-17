#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Parse-only tests of the capture tool: the lab lock. Nothing runs and no window opens.

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:CapturePath = Join-Path $script:Root 'tools\guide-capture\Invoke-GuideCapture.ps1'
    $script:Text = Get-Content -LiteralPath $script:CapturePath -Raw
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:CapturePath, [ref]$null, [ref]$null)
    $script:Code = [regex]::Replace($script:Text, '(?s)<#.*?#>', '')
    $script:Try = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $false) | Select-Object -First 1
}

Describe 'The capture tool takes the lab lock' {
    It 'parses without an error' {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:CapturePath, [ref]$null, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
    }

    It 'has a LockWaitMinutes parameter that defaults to 90' {
        $p = $script:Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'LockWaitMinutes' }
        $p | Should -Not -BeNullOrEmpty
        $p.DefaultValue.Extent.Text | Should -Be '90'
    }

    It 'takes C:\guide\capture.lock with New-Item and an IOException catch' {
        $script:Code | Should -Match '\$lockPath = ''C:\\guide\\capture\.lock'''
        $script:Code | Should -Match 'New-Item -ItemType File -Path \$path -Value \$text -ErrorAction Stop'
        $script:Code | Should -Match 'catch \[System\.IO\.IOException\]'
    }

    It 'writes the text owner|pid|start' {
        $script:Code | Should -Match "\`$lockText = '\{0\}\|\{1\}\|\{2\}' -f \`$app, \`$PID"
    }

    It 'takes the lock before it registers the first scheduled task' {
        $lock = $script:Try.Body.Extent.Text.IndexOf('New-Item -ItemType File -Path $path')
        $register = $script:Try.Body.Extent.Text.IndexOf('Register-ScheduledTask')
        $lock | Should -BeGreaterThan -1
        $register | Should -BeGreaterThan $lock
    }

    It 'treats a lock as stale only after 30 minutes with no running owner, and sleeps in every retry' {
        $script:Code | Should -Match '\[int\]\$age -gt 30 -and \$aliveLab -ne ''True'' -and -not \(Get-Process -Id \$ownerPid'
        $script:Code | Should -Match 'The stale lab lock .* was removed'
        $script:Code | Should -Match '''unknown: '' \+ \$held'
        $loop = $script:Ast.Find({ param($n) $n -is [System.Management.Automation.Language.WhileStatementAst] }, $true)
        $loop.Extent.Text | Should -Match 'Start-Sleep -Seconds 15'
    }

    It 'refreshes the lock in the poll loop' {
        $script:Code | Should -Match '\.LastWriteTime = Get-Date'
    }

    It 'releases the lock in the finally, only when this capture took it' {
        $finally = $script:Try.Finally.Extent.Text
        $finally | Should -Match 'if \(\$haveLock\)'
        $finally | Should -Match '-eq \$text'
    }

    It 'never deletes the C:\guide folder' {
        $script:Code | Should -Not -Match 'Remove-Item\s+[''"]?C:\\guide[''"]?(\s|$)'
    }
}
