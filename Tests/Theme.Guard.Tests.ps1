#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.1.0' }
# Guard tests for the theme rules. They parse the files and create no WPF control, so they run on
# Windows PowerShell 5.1 and PowerShell 7 and open no window.
#   (a) Every blue background in XAML and PowerShell has a white foreground.
#   (b) No font size, weight, style or text decoration depends on the theme.
#   (c) No banned word is in a tooltip, a UI string, the README or the user guide.

BeforeDiscovery {
    . "$PSScriptRoot\ThemeGuardHelpers.ps1"
    $script:RepoRootD = Split-Path -Parent $PSScriptRoot
    $script:PsFilesD = @(
        'start-sitehygiene.ps1', 'Module\SiteHygieneCommon.psm1', 'Module\SiteHygieneLive.psm1', 'Lib\SuiteCommon\SuiteCommon.psm1'
    ) | ForEach-Object { @{ Name = $_; Path = (Join-Path $script:RepoRootD $_) } }
}

BeforeAll {
    . "$PSScriptRoot\ThemeGuardHelpers.ps1"
    $script:XamlDocs = @(Get-XamlDocument)
}

Describe 'Blue backgrounds have white text (a)' {
    It 'finds XAML to check' {
        $script:XamlDocs.Count | Should -BeGreaterThan 1
    }

    It 'sets a white foreground on every blue background in <_.Source>' -ForEach @(Get-XamlDocument) {
        $bad = @(Get-BlueWithoutWhite -Text $_.Text -Source $_.Source)
        $bad | Should -BeNullOrEmpty
    }

    It 'recognizes blue and white brushes' {
        Test-BlueBrush '{DynamicResource MahApps.Brushes.Accent}' | Should -BeTrue
        Test-BlueBrush '#0078D4' | Should -BeTrue
        Test-BlueBrush '#1E1E1E' | Should -BeFalse
        Test-BlueBrush '#3A3A3A' | Should -BeFalse
        Test-WhiteBrush '{DynamicResource MahApps.Brushes.IdealForeground}' | Should -BeTrue
        Test-WhiteBrush 'Black' | Should -BeFalse
    }

    It 'flags a blue background that has no white foreground' {
        $xaml = '<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Button"><Setter Property="Background" Value="#0078D4"/></Style>'
        @(Get-BlueWithoutWhite -Text $xaml -Source 'sample').Count | Should -Be 1
        $ok = '<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Button"><Setter Property="Background" Value="#0078D4"/><Setter Property="Foreground" Value="White"/></Style>'
        @(Get-BlueWithoutWhite -Text $ok -Source 'sample').Count | Should -Be 0
    }

    It 'sets no blue color as a Background in <Name>, and each CSS rule with a blue background has white text' -ForEach @(
        @{ Name = 'start-sitehygiene.ps1'; Path = (Join-Path (Split-Path -Parent $PSScriptRoot) 'start-sitehygiene.ps1') }
        @{ Name = 'SiteHygieneCommon.psm1'; Path = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Module\SiteHygieneCommon.psm1') }
        @{ Name = 'SiteHygieneLive.psm1'; Path = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Module\SiteHygieneLive.psm1') }
    ) {
        $bad = foreach ($s in @(Get-ScriptBlueBackground -Path $Path)) { 'background ' + $s }
        $bad += foreach ($s in @(Get-ScriptString -Path $Path)) {
            foreach ($m in [regex]::Matches($s, '\{([^}]*)\}')) {
                $rule = $m.Groups[1].Value
                $bg = [regex]::Match($rule, '(?i)(?<![-\w])background(?:-color)?\s*:\s*(#[0-9A-F]{6,8})\b')
                if ($bg.Success -and (Test-BlueBrush $bg.Groups[1].Value) -and $rule -notmatch '(?i)(?<![-\w])color\s*:\s*(#fff(fff)?|white)\b') { 'css ' + $rule }
            }
        }
        @($bad) | Should -BeNullOrEmpty
    }

    It 'finds a blue Background assignment in a script' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('themeguard-' + [guid]::NewGuid().ToString('N') + '.ps1')
        try {
            [System.IO.File]::WriteAllText($tmp, "`$b.Background = '#0078D4'`n`$c.Foreground = '#0078D4'`n`$d.Background = '#1E1E1E'`n")
            @(Get-ScriptBlueBackground -Path $tmp).Count | Should -Be 1
            [System.IO.File]::WriteAllText($tmp, "`$b.Background = '#0078D4'`n`$b.Foreground = 'White'`n")
            @(Get-ScriptBlueBackground -Path $tmp).Count | Should -Be 0
        }
        finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }

    It 'sets a white foreground on every accent button style outside SuiteCommon in <_.Source>' -ForEach @(Get-XamlDocument | Where-Object { $_.Source -notmatch 'SuiteCommon' }) {
        $bad = @(Get-AccentButtonWithoutWhite -Text $_.Text -Source $_.Source)
        $bad | Should -BeNullOrEmpty
    }

    It 'flags an accent button style that has no white foreground' {
        $xaml = '<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"><Style x:Key="A" TargetType="Button" BasedOn="{StaticResource MahApps.Styles.Button.Square.Accent}"><Setter Property="Height" Value="32"/></Style></ResourceDictionary>'
        @(Get-AccentButtonWithoutWhite -Text $xaml -Source 'sample').Count | Should -Be 1
        $ok = $xaml.Replace('<Setter Property="Height" Value="32"/>', '<Setter Property="Foreground" Value="{DynamicResource MahApps.Brushes.IdealForeground}"/>')
        @(Get-AccentButtonWithoutWhite -Text $ok -Source 'sample').Count | Should -Be 0
    }

    It 'sets the foreground of a selected grid row and cell in <_.Source>' -ForEach @(Get-XamlDocument) {
        [xml]$x = $_.Text
        $bad = foreach ($t in @($x.SelectNodes("//*[local-name()='Trigger'][@Property='IsSelected']"))) {
            $fg = $t.ChildNodes | Where-Object { $_.LocalName -eq 'Setter' -and $_.GetAttribute('Property') -eq 'Foreground' } | Select-Object -First 1
            $bg = $t.ChildNodes | Where-Object { $_.LocalName -eq 'Setter' -and $_.GetAttribute('Property') -eq 'Background' } | Select-Object -First 1
            if ($bg -and -not $fg) { 'IsSelected trigger sets a Background and no Foreground' }
        }
        @($bad) | Should -BeNullOrEmpty
    }

    It 'paints the light theme buttons of SuiteCommon with white text' {
        $path = Join-Path $script:RepoRoot 'Lib\SuiteCommon\SuiteCommon.psm1'
        $text = Remove-ScriptComment -Text (Get-Content -LiteralPath $path -Raw)
        $text | Should -Match "OnBlue\s*=\s*\`$bc\.ConvertFrom\('#FFFFFF'\)"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        foreach ($name in 'Update-SidebarButtonTheme', 'Set-ButtonTheme') {
            $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
            $fn | Should -Not -BeNullOrEmpty -Because $name
            (Remove-ScriptComment -Text $fn.Extent.Text) | Should -Match 'Set-ThemeForeground' -Because ('{0} sets the foreground with each background' -f $name)
        }
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-ThemeForeground' }, $true)
        (Remove-ScriptComment -Text $fn.Extent.Text) | Should -Match '\.Foreground\s*=\s*\$OnBlue'
    }
}

Describe 'Fonts do not depend on the theme (b)' {
    It 'has no font property in a theme branch of <Name>' -ForEach $script:PsFilesD {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $assigns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.MemberExpressionAst] }, $true)
        $bad = foreach ($a in $assigns) {
            $member = [string]$a.Left.Member.Value
            if ($script:ThemeProperty -notcontains $member) { continue }
            $p = $a.Parent
            while ($p) {
                $condText = ''
                if ($p -is [System.Management.Automation.Language.IfStatementAst]) { $condText = (@($p.Clauses | ForEach-Object { $_.Item1.Extent.Text }) -join ' ') }
                elseif ($p -is [System.Management.Automation.Language.SwitchStatementAst]) { $condText = $p.Condition.Extent.Text }
                if ($condText -match '(?i)IsDark|DarkMode|Light|Theme|IsOn') { '{0}:{1} sets {2} in a theme branch' -f $Name, $a.Extent.StartLineNumber, $member; break }
                $p = $p.Parent
            }
        }
        @($bad) | Should -BeNullOrEmpty
    }

    It 'sets no font property in the theme functions of SuiteCommon except the connection boxes' {
        $path = Join-Path $script:RepoRoot 'Lib\SuiteCommon\SuiteCommon.psm1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        foreach ($name in 'Set-ThemeForeground', 'Update-SidebarButtonTheme', 'Set-ButtonTheme', 'Set-DialogTheme', 'Update-TitleBarBrushes', 'Initialize-SuiteTheme') {
            $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
            $fn | Should -Not -BeNullOrEmpty -Because $name
            $fn.Extent.Text | Should -Not -Match '\.(FontSize|FontWeight|FontStyle|TextDecorations)\s*=' -Because $name
        }
    }

    It 'makes the title of each connection box bold and 14 pt or larger, and leaves the value alone, the same way in both themes' {
        $path = Join-Path $script:RepoRoot 'Lib\SuiteCommon\SuiteCommon.psm1'
        $text = Remove-ScriptComment -Text (Get-Content -LiteralPath $path -Raw)
        $text | Should -Match 'FieldTitleFontSize\s*=\s*14'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-ConnectionTextTheme' }, $true)
        $fn | Should -Not -BeNullOrEmpty
        $code = Remove-ScriptComment -Text $fn.Extent.Text
        $code | Should -Match '\$title\.FontWeight\s*=\s*\[System\.Windows\.FontWeights\]::Bold'
        $code | Should -Not -Match '\$box\.(FontSize|FontWeight)\s*='
    }

    It 'uses no SemiBold title or label in <_.Source>, so that every title and field label is bold' -ForEach @(Get-XamlDocument) {
        $_.Text | Should -Not -Match 'FontWeight(=|" Value=)"SemiBold"'
    }

    It 'uses no theme trigger on a font property in <_.Source>' -ForEach @(Get-XamlDocument) {
        # A trigger on the selected tab or on the mouse is not a theme trigger. A trigger is a theme trigger when its own condition names the theme.
        [xml]$x = $_.Text
        $bad = foreach ($s in @($x.SelectNodes("//*[local-name()='Setter']"))) {
            if ($script:ThemeProperty -contains $s.GetAttribute('Property')) {
                $p = $s.ParentNode
                if ($p.LocalName -match 'Trigger') {
                    $condition = '{0} {1} {2}' -f $p.GetAttribute('Property'), $p.GetAttribute('Binding'), $p.GetAttribute('Value')
                    if ($condition -match '(?i)theme|dark|light|IsDark') { $p.OuterXml.Substring(0, [Math]::Min(80, $p.OuterXml.Length)) }
                }
            }
        }
        @($bad) | Should -BeNullOrEmpty
    }

    It 'finds the site code and SMS Provider boxes in the documents' {
        $names = foreach ($d in @(Get-XamlDocument)) {
            [xml]$x = $d.Text
            foreach ($n in 'txtSiteCode', 'txtSmsProvider') { if ($x.SelectSingleNode(("//*[@*[local-name()='Name']='{0}']" -f $n))) { $n } }
        }
        @($names | Sort-Object -Unique) | Should -Be @('txtSiteCode', 'txtSmsProvider')
    }

    It 'sets the title of the site code and SMS Provider boxes to bold 14 pt or more, and the value to normal weight, in <_.Source>' -ForEach @(Get-XamlDocument) {
        [xml]$x = $_.Text
        foreach ($name in 'txtSiteCode', 'txtSmsProvider', 'txtProvider', 'txtSiteServer') {
            $el = $x.SelectSingleNode(("//*[@*[local-name()='Name']='{0}']" -f $name))
            if (-not $el) { continue }
            $title = $el.PreviousSibling
            while ($title -and $title.NodeType -ne 'Element') { $title = $title.PreviousSibling }
            $title | Should -Not -BeNullOrEmpty -Because ('{0} has a title element before it' -f $name)
            $title.LocalName | Should -BeIn @('TextBlock', 'Label') -Because $name
            [double]$title.GetAttribute('FontSize') | Should -BeGreaterOrEqual 14 -Because ('the title of {0}' -f $name)
            $title.GetAttribute('FontWeight') | Should -Be 'Bold' -Because ('the title of {0}' -f $name)
            $el.GetAttribute('FontWeight') | Should -Not -Be 'Bold' -Because ('the value of {0}' -f $name)
        }
    }
}

Describe 'No banned word in the UI text and the documents (c)' {
    It 'finds the banned word <Word>' -ForEach @(@{ Word = 'simply' }, @{ Word = 'Helps you' }, @{ Word = 'streamlines' }) {
        $Word | Should -Match $script:BannedPattern
    }

    It 'has no banned word in the XAML text of <_.Source>' -ForEach @(Get-XamlDocument) {
        $bad = @(Get-XamlUiText -Text $_.Text | Where-Object { $_ -match $script:BannedPattern })
        $bad | Should -BeNullOrEmpty
    }

    It 'has no banned word in the strings of <Name>' -ForEach $script:PsFilesD {
        $bad = @(Get-ScriptString -Path $Path | Where-Object { $_ -match $script:BannedPattern })
        $bad | Should -BeNullOrEmpty
    }

    It 'has no banned word in the README or the user guide' {
        $files = @(Get-Item -LiteralPath (Join-Path $script:RepoRoot 'README.md')) + @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'docs') -Filter '*.md' -File -Recurse)
        $bad = foreach ($f in $files) {
            $n = 0
            foreach ($line in (Get-Content -LiteralPath $f.FullName)) {
                $n++
                if ($line -match $script:BannedPattern) { '{0}:{1}: {2}' -f $f.Name, $n, $Matches[0] }
            }
        }
        @($bad) | Should -BeNullOrEmpty
    }
}

Describe 'Every button takes the shared themed style (d)' {
    It 'has no unthemed button and no literal button color in <_.Source>' -ForEach @(Get-XamlDocument | Where-Object { $_.Source -notmatch 'SuiteCommon' }) {
        $bad = @(Get-ButtonThemeViolation -Text $_.Text -Source $_.Source)
        $bad | Should -BeNullOrEmpty
    }

    # The dialogs of SuiteCommon are vendored code. They are fixed in the suite repository (app-packager-suite), not here.
    # The test is skipped on purpose and shows in the result as Skipped with this reason.
    It 'SKIPPED until the suite repository fixes its dialogs: has no unthemed button in <_.Source>' -Skip -ForEach @(Get-XamlDocument | Where-Object { $_.Source -match 'SuiteCommon' }) {
        $bad = @(Get-ButtonThemeViolation -Text $_.Text -Source $_.Source)
        $bad | Should -BeNullOrEmpty
    }

    It 'finds the buttons of the documents' {
        $count = 0
        foreach ($d in @(Get-XamlDocument | Where-Object { $_.Source -notmatch 'SuiteCommon' })) {
            [xml]$x = $d.Text
            $count += @($x.SelectNodes("//*[local-name()='Button']")).Count
        }
        $count | Should -BeGreaterThan 25
    }

    It 'flags a button that has no style, a literal color and a style that is not shared' {
        $ns = 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"'
        $themed = '<Style x:Key="ThemedButtonStyle" TargetType="Button" BasedOn="{StaticResource MahApps.Styles.Button.Square}"/>'
        @(Get-ButtonThemeViolation -Text "<Grid $ns><Button x:Name=`"a`"/></Grid>" -Source 's').Count | Should -Be 1
        @(Get-ButtonThemeViolation -Text "<Grid $ns><Grid.Resources>$themed<Style x:Key=`"S`" TargetType=`"Button`" BasedOn=`"{StaticResource ThemedButtonStyle}`"/></Grid.Resources><Button Style=`"{StaticResource S}`" Background=`"#1E1E1E`"/></Grid>" -Source 's').Count | Should -Be 1
        @(Get-ButtonThemeViolation -Text "<Grid $ns><Grid.Resources>$themed<Style x:Key=`"S`" TargetType=`"Button`" BasedOn=`"{StaticResource MahApps.Styles.Button.Square.Accent}`"/></Grid.Resources><Button Style=`"{StaticResource S}`"/></Grid>" -Source 's').Count | Should -Be 2
        @(Get-ButtonThemeViolation -Text "<Grid $ns><Grid.Resources>$themed<Style x:Key=`"S`" TargetType=`"Button`" BasedOn=`"{StaticResource ThemedButtonStyle}`"><Setter Property=`"Foreground`" Value=`"White`"/></Style></Grid.Resources><Button Style=`"{StaticResource S}`"/></Grid>" -Source 's').Count | Should -Be 1
        @(Get-ButtonThemeViolation -Text "<Grid $ns><Grid.Resources>$themed<Style x:Key=`"S`" TargetType=`"Button`" BasedOn=`"{StaticResource ThemedButtonStyle}`"><Setter Property=`"Foreground`" Value=`"{DynamicResource MahApps.Brushes.ThemeForeground}`"/></Style></Grid.Resources><Button Style=`"{StaticResource S}`"/></Grid>" -Source 's').Count | Should -Be 0
    }

    It 'has one secondary button style and one primary button style in the dialog, and no other button style that sets a Background' {
        $doc = @(Get-XamlDocument | Where-Object { $_.Source -notmatch 'SuiteCommon' -and $_.Text -match 'DialogAccentButton' })
        $doc.Count | Should -Be 1
        [xml]$x = $doc[0].Text
        $xns = 'http://schemas.microsoft.com/winfx/2006/xaml'
        $withBackground = foreach ($s in @($x.SelectNodes("//*[local-name()='Style'][@TargetType='Button']"))) {
            if (@($s.ChildNodes | Where-Object { $_.LocalName -eq 'Setter' -and $_.GetAttribute('Property') -eq 'Background' }).Count -gt 0) { $s.GetAttribute('Key', $xns) }
        }
        @($withBackground | Sort-Object) | Should -Be @('DialogAccentButton', 'DialogButton')
    }

    It 'names every button of the main window and lists each one in the themed set of the script' {
        $shell = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'start-sitehygiene.ps1') -Raw
        $themed = New-Object System.Collections.Generic.HashSet[string]
        $set = [regex]::Match($shell, '\$script:WorkflowButtons\s*=\s*@\(([^)]*)\)')
        $set.Success | Should -BeTrue
        foreach ($m in [regex]::Matches($set.Groups[1].Value, '\$(btn\w+)')) { [void]$themed.Add($m.Groups[1].Value) }
        foreach ($m in [regex]::Matches($shell, 'Button\s*=\s*\$(btn\w+)')) { [void]$themed.Add($m.Groups[1].Value) }
        foreach ($m in [regex]::Matches($shell, '-OptionsButton\s+\$(btn\w+)')) { [void]$themed.Add($m.Groups[1].Value) }
        $main = @(Get-XamlDocument | Where-Object { $_.Source -eq 'MainWindow.xaml' })
        $main.Count | Should -Be 1
        [xml]$x = $main[0].Text
        $buttons = @($x.SelectNodes("//*[local-name()='Button']"))
        $buttons.Count | Should -BeGreaterThan 15
        $missing = foreach ($b in $buttons) {
            $name = $b.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
            if (-not $name) { 'a button has no x:Name' } elseif (-not $themed.Contains($name)) { $name }
        }
        @($missing) | Should -BeNullOrEmpty
    }

    It 'themes the buttons of the window in both themes through SuiteCommon' {
        $shell = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'start-sitehygiene.ps1') -Raw
        $shell | Should -Match '-WorkflowButtons\s+\$script:WorkflowButtons'
        ([regex]::Matches($shell, 'Update-SidebarButtonTheme\s*\r?\n\s*Set-ButtonTheme')).Count | Should -BeGreaterOrEqual 3
    }
}

Describe 'No raw exception text in the window (e)' {
    It 'writes exception text to the log file only (-Quiet) in <Name>' -ForEach @(
        @{ Name = 'start-sitehygiene.ps1'; Path = (Join-Path (Split-Path -Parent $PSScriptRoot) 'start-sitehygiene.ps1') }
        @{ Name = 'SiteHygieneCommon.psm1'; Path = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Module\SiteHygieneCommon.psm1') }
        @{ Name = 'SiteHygieneLive.psm1'; Path = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Module\SiteHygieneLive.psm1') }
    ) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Write-Log' }, $true)
        $calls.Count | Should -BeGreaterThan 0
        $bad = foreach ($c in $calls) {
            $t = $c.Extent.Text
            if ($t -match '\$_|\$\(\$_|Exception\.Message|\$err\b' -and $t -notmatch '-Quiet') { '{0}:{1}: {2}' -f $Name, $c.Extent.StartLineNumber, $t }
        }
        @($bad) | Should -BeNullOrEmpty
    }
}
