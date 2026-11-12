#Requires -Modules Pester
# Window tests. The main window and the Options dialog (built from XAML text in the start script)
# are opened off screen on an STA thread, in both themes and at 1024x720 and 1440x900, and measured.
# The app-specific names live in WindowConfig.ps1.

BeforeDiscovery {
    . "$PSScriptRoot\WindowHarness.ps1"
    . "$PSScriptRoot\WindowConfig.ps1"
    # No window opens unless this guard allows it (the opt-in must be set). The skipped tests report the reason.
    $script:WindowGuard = Test-WindowTestsAllowed
    if (-not $script:WindowGuard.Allowed) { Write-Host ('Window tests skipped: {0}' -f $script:WindowGuard.Reason) }
    $script:Matrix = foreach ($dark in $true, $false) {
        foreach ($size in @(@(1024, 720), @(1440, 900))) {
            @{ Dark = $dark; Theme = $(if ($dark) { 'dark' } else { 'light' }); W = $size[0]; H = $size[1]; Size = ('{0}x{1}' -f $size[0], $size[1]) }
        }
    }
    $script:ViewCases = @($script:AppConfig.Views | ForEach-Object { @{ View = $_.Name } })
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $PSScriptRoot) $script:AppConfig.Shell), [ref]$null, [ref]$null)
    $script:NameCases = @($ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq 'FindName' -and
                $n.Expression.Extent.Text -eq '$window' -and $n.Arguments.Count -eq 1
            }, $true) | ForEach-Object { $_.Arguments[0].Value } | Sort-Object -Unique | ForEach-Object { @{ Name = $_ } })
    $script:DialogCases = @(for ($i = 0; $i -lt @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -match '^\s*<Controls:MetroWindow' }, $true)).Count; $i++) { @{ Index = $i } })
    $script:PaneCases = @('paneConnection', 'paneScope', 'paneLive', 'paneAlerts', 'paneAbout' | ForEach-Object { @{ Pane = $_ } })
}

BeforeAll {
    . "$PSScriptRoot\TestHelpers.ps1"
    . "$PSScriptRoot\WindowHarness.ps1"
    . "$PSScriptRoot\KnownContrastDefects.ps1"
    . "$PSScriptRoot\WindowConfig.ps1"
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:ShellPath = Join-Path $script:Root $script:AppConfig.Shell
    $script:XamlPath = Join-Path $script:Root $script:AppConfig.Xaml
    $script:XamlText = [System.IO.File]::ReadAllText($script:XamlPath)
    Import-AppModule
    $script:ScopeTitles = @(Get-HygieneScanScope | ForEach-Object { if ($_.Slow) { '{0} (slow)' -f $_.Title } else { $_.Title } })

    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ShellPath, [ref]$null, [ref]$null)
    $script:WindowNames = @($ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq 'FindName' -and
                $n.Expression.Extent.Text -eq '$window' -and $n.Arguments.Count -eq 1
            }, $true) | ForEach-Object { $_.Arguments[0].Value } | Sort-Object -Unique)
    $script:DialogXaml = @($ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -match '^\s*<Controls:MetroWindow'
            }, $true) | ForEach-Object { $_.Value })
    $script:ShellText = [System.IO.File]::ReadAllText($script:ShellPath)

    $script:Measured = @{}
    $script:DialogMeasured = @{}
    $script:WindowGuard = Test-WindowTestsAllowed
    if ($script:WindowGuard.Allowed) {
    foreach ($case in @(
            @{ Dark = $true; W = 1024; H = 720 }, @{ Dark = $true; W = 1440; H = 900 },
            @{ Dark = $false; W = 1024; H = 720 }, @{ Dark = $false; W = 1440; H = 900 })) {
        $key = '{0}|{1}x{2}' -f $(if ($case.Dark) { 'dark' } else { 'light' }), $case.W, $case.H
        $case.Config = $script:AppConfig
        $case.Findings = $script:SampleFindings
        $script:Measured[$key] = Invoke-WpfSta -Arguments $case -Script $script:MainMeasureScript
    }

    # The Options dialog: every pane, in both themes, at the declared size and at the minimum size.
    foreach ($dark in $true, $false) {
        $theme = if ($dark) { 'dark' } else { 'light' }
        $script:DialogMeasured[$theme] = Invoke-WpfSta -Arguments @{ Xaml = $script:DialogXaml[0]; Dark = $dark; Scopes = $script:ScopeTitles } -Script $script:DialogMeasureScript
    }
    }
}

AfterAll { Close-WpfSession }

Describe 'Main window XAML' -Skip:(-not $script:WindowGuard.Allowed) {
    It 'loads as a MetroWindow with the app title and a minimum size that fits 1024x720' {
        $r = Invoke-WpfSta -Arguments @{ Xaml = $script:AppConfig.Xaml } -Script {
            $w = Open-TestWindow -XamlPath (Join-Path $Root $Arguments.Xaml)
            $o = [PSCustomObject]@{ Type = $w.GetType().FullName; Title = $w.Title; MinW = $w.MinWidth; MinH = $w.MinHeight }
            $w.Close(); $o
        }
        $r.Type | Should -Be 'MahApps.Metro.Controls.MetroWindow'
        $r.Title | Should -Be $script:AppConfig.Title
        $r.MinW | Should -BeLessOrEqual 1024
        $r.MinH | Should -BeLessOrEqual 720
    }

    It 'shows the first view and keeps the others hidden' {
        $r = Invoke-WpfSta -Arguments @{ Config = $script:AppConfig } -Script {
            $w = Open-TestWindow -XamlPath (Join-Path $Root $Arguments.Config.Xaml)
            $o = foreach ($v in $Arguments.Config.Views) { [PSCustomObject]@{ Name = $v.Name; Vis = [string]$w.FindName($v.Container).Visibility } }
            $w.Close(); , @($o)
        }
        $first = $script:AppConfig.Views[0].Name
        ($r | Where-Object Name -eq $first).Vis | Should -Be 'Visible'
        @($r | Where-Object { $_.Name -ne $first -and $_.Vis -ne 'Collapsed' }) | Should -BeNullOrEmpty
    }

    It 'declares a minimum size that fits the requested size <Size>' -ForEach $script:Matrix {
        # The real window size depends on the screen of the machine (a CI runner screen is about 1044 pixels wide),
        # so the test reads the declared minimum size, which does not.
        $r = Invoke-WpfSta -Arguments @{ Xaml = $script:AppConfig.Xaml } -Script {
            $w = Open-TestWindow -XamlPath (Join-Path $Root $Arguments.Xaml)
            $o = [PSCustomObject]@{ MinW = $w.MinWidth; MinH = $w.MinHeight }
            $w.Close(); $o
        }
        $r.MinW | Should -BeLessOrEqual $W
        $r.MinH | Should -BeLessOrEqual $H
    }
}
Describe 'Window XAML text' {
    It 'declares each x:Name once' {
        $names = [regex]::Matches($script:XamlText, 'x:Name="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
        ($names | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name) | Should -BeNullOrEmpty
    }


    It 'finds the script look-ups of the window' {
        $script:WindowNames.Count | Should -BeGreaterThan 50
    }


    It 'has the control <Name> that the script looks up' -ForEach $script:NameCases {
        $script:XamlText | Should -Match ('x:Name="{0}"' -f [regex]::Escape($Name))
    }


    It 'has the container and the sidebar button of view <View>' -ForEach @($script:AppConfig.Views | ForEach-Object { @{ View = $_.Name; Container = $_.Container; Button = $_.Button } }) {
        $script:XamlText | Should -Match ('x:Name="{0}"' -f $Container)
        $script:XamlText | Should -Match ('x:Name="{0}"' -f $Button)
    }


    It 'lists in the configuration every view that the script switches to' {
        $m = [regex]::Match($script:ShellText, "function Set-ActiveView[\s\S]*?ValidateSet\(([^)]*)\)")
        $m.Success | Should -BeTrue
        $views = @([regex]::Matches($m.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
        $configured = @($script:AppConfig.Views | ForEach-Object { $_.Name })
        @($views | Where-Object { $configured -notcontains $_ }) | Should -BeNullOrEmpty
        @($configured | Where-Object { $views -notcontains $_ }) | Should -BeNullOrEmpty
    }
}

Describe 'Dialog windows' -Skip:(-not $script:WindowGuard.Allowed) {
    It 'parses dialog <Index> as a MetroWindow with named controls' -ForEach $script:DialogCases {
        $r = Invoke-WpfSta -Arguments @{ Xaml = $script:DialogXaml[$Index] } -Script {
            [xml]$x = $Arguments.Xaml
            $w = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
            # A name inside a ControlTemplate belongs to the template, not to the window, so FindName cannot find it.
            $names = @($x.SelectNodes("//*[@*[local-name()='Name']][not(ancestor::*[local-name()='ControlTemplate'])]") | ForEach-Object { $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml') })
            [PSCustomObject]@{ Type = $w.GetType().Name; Missing = @($names | Where-Object { -not $w.FindName($_) }); Count = @($names).Count }
        }
        $r.Type | Should -Be 'MetroWindow'
        $r.Missing | Should -BeNullOrEmpty
        $r.Count | Should -BeGreaterThan 0
    }

    It 'shows pane <Pane> of the Options dialog without clipped text or off-screen controls at its declared and minimum size in the <Theme> theme' -ForEach @(
        foreach ($c in $script:PaneCases) { foreach ($t in 'dark', 'light') { @{ Pane = $c.Pane; Theme = $t } } }
    ) {
        $rows = @($script:DialogMeasured[$Theme] | Where-Object Pane -eq $Pane)
        $rows.Count | Should -BeGreaterOrEqual 1
        foreach ($m in $rows) {
            $m.Clipped | ForEach-Object { '{0}: {1}: needs {2}px, has {3}px' -f $m.Size, $_.Text, $_.Needed, $_.Actual } | Should -BeNullOrEmpty
            $m.Offscreen | ForEach-Object { '{0}: {1} at {2},{3} size {4}x{5}' -f $m.Size, $_.Name, $_.X, $_.Y, $_.W, $_.H } | Should -BeNullOrEmpty
        }
    }

    It 'shows every text of the Options dialog at 4.5:1 (3:1 for large text) in the <Theme> theme, except the listed known defects' -ForEach @(@{ Theme = 'dark' }, @{ Theme = 'light' }) {
        $known = @(Get-KnownContrastDefect -Theme $Theme -Scope Dialog)
        $found = @(Get-ContrastViolationKey -Views @($script:DialogMeasured[$Theme] | Where-Object { $_.Size -eq ($script:DialogMeasured[$Theme] | Select-Object -First 1).Size }))
        $new = @($found | Where-Object { $known -notcontains $_ })
        $fixed = @($known | Where-Object { $found -notcontains $_ })
        $new | Should -BeNullOrEmpty -Because 'a new contrast violation appeared in the Options dialog'
        $fixed | Should -BeNullOrEmpty -Because 'a known defect is fixed: remove it from Get-KnownContrastDefect'
    }
}

Describe 'Dialog text' {
    It 'finds the dialog XAML in the script' {
        $script:DialogXaml.Count | Should -Be 1
    }


    It 'has every control that the Options dialog code looks up' {
        $lookups = @([regex]::Matches($script:ShellText, "\`$dlg\.FindName\('([^']+)'\)") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $lookups.Count | Should -BeGreaterThan 15
        foreach ($n in $lookups) { $script:DialogXaml[0] | Should -Match ('x:Name="{0}"' -f [regex]::Escape($n)) }
    }


    It 'gives every dialog and message a title that differs from the main window title' {
        # A toast is not a dialog: its title line names the app on purpose, so the toast call is left out.
        $titles = @([regex]::Matches($script:ShellText, "(?m)^(?!.*Send-ShToast).*?-Title\s+'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
        $titles += @([regex]::Matches($script:ShellText, "-Title\s+\`$title") | ForEach-Object { 'dynamic' })
        $titles += @([regex]::Matches($script:ShellText, "MessageBox\]::Show\([^,]+,[^,]+,\s*'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
        $titles += @($script:DialogXaml | ForEach-Object { if ($_ -match '\sTitle="([^"]*)"') { $Matches[1] } } | Where-Object { $_ })
        $titles.Count | Should -BeGreaterThan 3
        $titles | Should -Not -Contain $script:AppConfig.Title
        foreach ($t in $titles) { $t.Trim() | Should -Not -BeNullOrEmpty }
    }


    It 'builds the Run Fix confirmation title from the check id, not from the app title' {
        $script:ShellText | Should -Match "Run Fix for \{0\}\?"
        $script:ShellText | Should -Match "Run \{0\} Fixes\?"
    }


    It 'gives the dialogs in XAML different titles' {
        $titles = @($script:DialogXaml | ForEach-Object { if ($_ -match '\sTitle="([^"]*)"') { $Matches[1] } } | Where-Object { $_ })
        ($titles | Select-Object -Unique).Count | Should -Be $titles.Count
    }
}

Describe 'Layout <Theme> <Size>' -ForEach $script:Matrix -Skip:(-not $script:WindowGuard.Allowed) {
    It 'has no clipped text in the <View> view' -ForEach $script:ViewCases {
        $m = ($script:Measured['{0}|{1}' -f $Theme, $Size] | Where-Object View -eq $View)
        $m.Clipped | ForEach-Object { '{0}: needs {1}px, has {2}px' -f $_.Text, $_.Needed, $_.Actual } | Should -BeNullOrEmpty
    }

    It 'keeps every button, box and list inside the window in the <View> view' -ForEach $script:ViewCases {
        $m = ($script:Measured['{0}|{1}' -f $Theme, $Size] | Where-Object View -eq $View)
        $m.Offscreen | ForEach-Object { '{0} at {1},{2} size {3}x{4}' -f $_.Name, $_.X, $_.Y, $_.W, $_.H } | Should -BeNullOrEmpty
    }
}

Describe 'Contrast <Theme>' -ForEach @(@{ Theme = 'dark' }, @{ Theme = 'light' }) -Skip:(-not $script:WindowGuard.Allowed) {
    It 'shows every text at 4.5:1 (3:1 for large text) in the <View> view, except the listed known defects' -ForEach $script:ViewCases {
        $m = ($script:Measured['{0}|1440x900' -f $Theme] | Where-Object View -eq $View)
        $m.Text.Count | Should -BeGreaterThan 3
        $known = @(Get-KnownContrastDefect -Theme $Theme)
        $bad = $m.Text | Where-Object { $min = if (Test-LargeText $_) { 3.0 } else { 4.5 }; $_.Ratio -lt $min -and ($known -notcontains ('text:{0}' -f $_.Text)) }
        $bad | ForEach-Object { '{0} "{1}" {2} on {3} = {4}' -f $_.Name, $_.Text, $_.Foreground, $_.Backdrop, $_.Ratio } | Should -BeNullOrEmpty
    }
    It 'keeps the title text readable on the active title bar' {
        $tb = ($script:Measured['{0}|1440x900' -f $Theme] | Select-Object -First 1).TitleBar
        $tb.Active | Should -BeGreaterOrEqual 4.5
    }

    It 'meets the standard on every control, except the listed known defects' {
        $known = Get-KnownContrastDefect -Theme $Theme
        $found = @(Get-ContrastViolationKey -Views @($script:Measured['{0}|1440x900' -f $Theme]))
        $new = @($found | Where-Object { $known -notcontains $_ })
        $fixed = @($known | Where-Object { $found -notcontains $_ })
        $new | Should -BeNullOrEmpty -Because 'a new contrast violation appeared'
        $fixed | Should -BeNullOrEmpty -Because 'a known defect is fixed: remove it from Get-KnownContrastDefect'
    }
}
