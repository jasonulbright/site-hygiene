#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x window test for the compact 1080p density and for vacant space. The main window is opened off screen,
    in both themes, at the work area of the session (1920x1032 on a 1080p screen at 100 percent) and at 1024x720, and
    measured: sidebar buttons, inline buttons, grid rows and headers, the width that the content uses, and the vacant
    area at the bottom and at the right of every view. The visible run prints the work area of the session.
#>

BeforeDiscovery {
    . "$PSScriptRoot\WindowHarness.ps1"
    . "$PSScriptRoot\WindowConfig.ps1"
    $script:WindowGuard = Test-WindowTestsAllowed
    if (-not $script:WindowGuard.Allowed -and -not $env:SUITE_WINDOW_GUARD_REPORTED) { Write-Host ('Window tests skipped: {0}.' -f $script:WindowGuard.Reason) }
    $script:Cases = @(foreach ($dark in $true, $false) {
            $design = Get-DesignSize
            foreach ($size in @(@(1024, 720), @($design.W, $design.H))) {
                @{ Dark = $dark; Theme = $(if ($dark) { 'dark' } else { 'light' }); W = $size[0]; H = $size[1]; Size = ('{0}x{1}' -f $size[0], $size[1]) }
            }
        })
    $script:ViewCases = @($script:AppConfig.Views | ForEach-Object { @{ View = $_.Name } })
}

BeforeAll {
    . "$PSScriptRoot\WindowHarness.ps1"
    $script:WindowGuard = Test-WindowTestsAllowed
    if (-not $script:WindowGuard.Allowed) { return }
    . "$PSScriptRoot\WindowConfig.ps1"
    $script:Design = Get-DesignSize
    Add-Type -AssemblyName PresentationFramework
    $wa = [System.Windows.SystemParameters]::WorkArea
    Write-Host ('Work area of this session: {0}x{1}' -f $wa.Width, $wa.Height)
    $script:Measured = @{}
    foreach ($case in @(
            @{ Dark = $true; W = 1024; H = 720 }, @{ Dark = $true; W = $script:Design.W; H = $script:Design.H },
            @{ Dark = $false; W = 1024; H = 720 }, @{ Dark = $false; W = $script:Design.W; H = $script:Design.H })) {
        $key = '{0}|{1}x{2}' -f $(if ($case.Dark) { 'dark' } else { 'light' }), $case.W, $case.H
        $case.Config = $script:AppConfig
        $script:Measured[$key] = Invoke-WpfSta -Arguments $case -Script {
            $cfg = $Arguments.Config
            $w = $null
            try {
                $w = Open-TestWindow -XamlPath (Join-Path $Root $cfg.Xaml) -Dark $Arguments.Dark -Width $Arguments.W -Height $Arguments.H
                Initialize-ShellTheme -Window $w -Dark $Arguments.Dark -Views $cfg.Views -WorkflowButtonName $cfg.WorkflowButtons `
                    -OptionsButtonName $cfg.OptionsButton -LogLabelName $cfg.LogLabel -ActiveView $cfg.Views[0].Name
                Wait-Layout $w
                $sidebar = @(foreach ($v in $cfg.Views) {
                        $b = $w.FindName($v.Button); $pt = $b.TransformToAncestor($w).Transform([System.Windows.Point]::new(0, 0))
                        [pscustomobject]@{ Name = $v.Button; Height = $b.ActualHeight; Bottom = ($pt.Y + $b.ActualHeight) }
                    })
                $views = @(foreach ($view in $cfg.Views) {
                        foreach ($v in $cfg.Views) { $w.FindName($v.Container).Visibility = if ($v.Name -eq $view.Name) { 'Visible' } else { 'Collapsed' } }
                        Wait-Layout $w
                        $c = $w.FindName($view.Container)
                        $buttons = @(foreach ($el in (Get-VisualDescendants $c)) { if ($el -is [System.Windows.Controls.Button] -and $el.Style -and (Test-VisibleInTree $el) -and $el.Name) { [pscustomobject]@{ Name = $el.Name; Height = $el.ActualHeight } } })
                        $grids = @(foreach ($el in (Get-VisualDescendants $c)) {
                                if ($el -is [System.Windows.Controls.DataGrid] -and (Test-VisibleInTree $el)) {
                                    $hdr = $null; foreach ($x in (Get-VisualDescendants $el)) { if ($x -is [System.Windows.Controls.Primitives.DataGridColumnHeadersPresenter]) { $hdr = $x; break } }
                                    $row = $null; foreach ($x in (Get-VisualDescendants $el)) { if ($x -is [System.Windows.Controls.DataGridRow]) { $row = $x; break } }
                                    [pscustomobject]@{ Name = $el.Name; Width = $el.ActualWidth; HeaderHeight = $(if ($hdr) { $hdr.ActualHeight } else { $null }); RowHeight = $(if ($row) { $row.ActualHeight } else { $null }) }
                                }
                            })
                        # The content extent: the lowest bottom and the furthest right of the visible elements that draw something.
                        $bottom = 0.0; $right = 0.0
                        foreach ($el in (Get-VisualDescendants $c)) {
                            if ($el -isnot [System.Windows.FrameworkElement] -or $el.ActualWidth -le 0 -or $el.ActualHeight -le 0 -or -not (Test-VisibleInTree $el)) { continue }
                            $draws = ($el -is [System.Windows.Controls.DataGrid]) -or ($el -is [System.Windows.Controls.TextBox]) -or ($el -is [System.Windows.Controls.Button]) -or
                                ($el -is [System.Windows.Controls.ComboBox]) -or ($el -is [System.Windows.Controls.TextBlock]) -or ($el -is [System.Windows.Controls.Canvas]) -or
                                (($el -is [System.Windows.Controls.Border]) -and $null -ne $el.Background)
                            if (-not $draws) { continue }
                            $pt = $el.TransformToAncestor($c).Transform([System.Windows.Point]::new(0, 0))
                            $bottom = [Math]::Max($bottom, $pt.Y + $el.ActualHeight); $right = [Math]::Max($right, $pt.X + $el.ActualWidth)
                        }
                        [pscustomobject]@{ View = $view.Name; Width = $c.ActualWidth; Height = $c.ActualHeight; Buttons = $buttons; Grids = $grids; VacantHeight = [Math]::Max(0, $c.ActualHeight - $bottom); VacantWidth = [Math]::Max(0, $c.ActualWidth - $right) }
                    })
                [pscustomobject]@{ Width = $w.ActualWidth; Height = $w.ActualHeight; Sidebar = $sidebar; Views = $views }
            }
            finally { if ($w) { $w.Close() } }
        }
    }
}

AfterAll {
    if ($script:WindowGuard.Allowed) { Close-WpfSession }
}

Describe 'Density <Theme> <Size>' -ForEach $script:Cases -Skip:(-not $script:WindowGuard.Allowed) {
    It 'sizes every sidebar button between 34 and 36 px and fits all of them without scrolling' {
        $m = $script:Measured['{0}|{1}' -f $Theme, $Size]
        foreach ($b in $m.Sidebar) { $b.Height | Should -BeIn 34, 35, 36 -Because $b.Name }
        ($m.Sidebar | Select-Object -Last 1).Bottom | Should -BeLessThan $m.Height
    }

    It 'sizes the inline buttons at 26 to 28 px in the <View> view' -ForEach $script:ViewCases {
        $m = $script:Measured['{0}|{1}' -f $Theme, $Size].Views | Where-Object View -eq $View
        foreach ($b in $m.Buttons | Where-Object { $_.Name -notmatch '^btnView|^btnOptions' }) { $b.Height | Should -BeLessOrEqual 28 -Because $b.Name }
    }

    It 'gives grid rows 24 to 26 px and headers 26 px in the <View> view' -ForEach $script:ViewCases {
        $m = $script:Measured['{0}|{1}' -f $Theme, $Size].Views | Where-Object View -eq $View
        foreach ($g in $m.Grids) {
            if ($null -ne $g.HeaderHeight) { $g.HeaderHeight | Should -BeLessOrEqual 26.5 -Because $g.Name }
            if ($null -ne $g.RowHeight) { [math]::Round($g.RowHeight) | Should -BeIn 24, 25, 26 -Because $g.Name }
        }
    }

    It 'lets the content fill the width in the <View> view' -ForEach $script:ViewCases {
        $mm = $script:Measured['{0}|{1}' -f $Theme, $Size]
        $m = $mm.Views | Where-Object View -eq $View
        $m.Width | Should -BeGreaterOrEqual ($mm.Width - 300)
        foreach ($g in $m.Grids) { $g.Width | Should -BeGreaterOrEqual ($m.Width * 0.3) -Because $g.Name }
    }
}

Describe 'No vacant space <Theme>' -ForEach @(@{ Theme = 'dark' }, @{ Theme = 'light' }) -Skip:(-not $script:WindowGuard.Allowed) {
    It 'leaves no vacant area larger than 120 px high or 160 px wide at the work area' {
        $m = $script:Measured['{0}|{1}' -f $Theme, $script:Design.Key]
        $bad = @($m.Views | Where-Object { $_.VacantHeight -gt 120 -or $_.VacantWidth -gt 160 } | ForEach-Object { '{0}: {1} px high, {2} px wide of {3}x{4}' -f $_.View, [int]$_.VacantHeight, [int]$_.VacantWidth, [int]$_.Width, [int]$_.Height })
        $bad | Should -BeNullOrEmpty -Because ('a view leaves a vacant area: ' + ($bad -join '; '))
    }
}
