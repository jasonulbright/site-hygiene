#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.1.0' }
# Window test for the chrome and the buttons of the main window and of every dialog, in both themes.
# The app has two kinds of dialog window, and the test measures both:
#   - the Options dialog, built from the XAML here-string of the start script and themed by Set-DialogTheme
#   - the confirmation dialog of SuiteCommon (Show-ConfirmDialog, the Run Fix confirmation), which the test opens through
#     the real function; a dispatcher timer measures the open dialog and closes it
# The start script also calls [System.Windows.MessageBox]::Show and a SaveFileDialog. The operating system draws those,
# so the app cannot theme them and the test cannot measure them. The 'finds every dialog' test counts them.
# Rules:
#   - the dialog title bar brush (active and inactive) is the title bar brush of the main window
#   - the title bar text of the dialog is readable (4.5:1) on that brush
#   - every button has bold text (SemiBold or heavier, 600; a normal weight is a defect)
#   - no button has a border thicker than 1 px, and no button border has the text color of the theme

BeforeDiscovery {
    . "$PSScriptRoot\WindowHarness.ps1"
    $script:WindowGuard = Test-WindowTestsAllowed
    if (-not $script:WindowGuard.Allowed -and -not $env:SUITE_WINDOW_GUARD_REPORTED) { Write-Host ('Window tests skipped: {0}.' -f $script:WindowGuard.Reason) }
    $script:ThemeCases = @(@{ Dark = $true; Theme = 'dark' }, @{ Dark = $false; Theme = 'light' })
}

BeforeAll {
    . "$PSScriptRoot\WindowHarness.ps1"
    $script:WindowGuard = Test-WindowTestsAllowed
    if (-not $script:WindowGuard.Allowed) { return }
    . "$PSScriptRoot\WindowConfig.ps1"
    $script:RepoDir = Split-Path -Parent $PSScriptRoot
    $script:ShellText = [System.IO.File]::ReadAllText((Join-Path $script:RepoDir $script:AppConfig.Shell))
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoDir $script:AppConfig.Shell), [ref]$null, [ref]$null)
    # Dialogs built from XAML text in the start script.
    $script:ShellDialogXaml = @($ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -match '^\s*<Controls:MetroWindow'
            }, $true) | ForEach-Object { $_.Value })
    # Dialog functions of SuiteCommon that the start script calls: a function that builds a MetroWindow.
    $suiteAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoDir 'Lib\SuiteCommon\SuiteCommon.psm1'), [ref]$null, [ref]$null)
    $suiteDialog = @($suiteAst.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -like 'Show-*' -and $n.Extent.Text -match '<Controls:MetroWindow'
            }, $true) | ForEach-Object { $_.Name })
    $calledName = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Sort-Object -Unique)
    $script:SuiteDialogCalled = @($suiteDialog | Where-Object { $calledName -contains $_ })
    $script:NativeDialogCount = @([regex]::Matches($script:ShellText, 'MessageBox\]::Show\(')).Count + @([regex]::Matches($script:ShellText, 'New-Object\s+(System\.Windows\.Forms\.)?SaveFileDialog')).Count

    $script:Measured = @{}
    foreach ($dark in $true, $false) {
        $key = if ($dark) { 'dark' } else { 'light' }
        $script:Measured[$key] = Invoke-WpfSta -Arguments @{ Dark = $dark; Config = $script:AppConfig; Dialogs = $script:ShellDialogXaml; SuiteDialogs = $script:SuiteDialogCalled } -Script {
            $cfg = $Arguments.Config
            $main = Open-TestWindow -XamlPath (Join-Path $Root $cfg.Xaml) -Dark $Arguments.Dark
            Initialize-ShellTheme -Window $main -Dark $Arguments.Dark -Views $cfg.Views -WorkflowButtonName $cfg.WorkflowButtons `
                -OptionsButtonName $cfg.OptionsButton -LogLabelName $cfg.LogLabel -ActiveView $cfg.Views[0].Name
            $mainChrome = Get-SuiteWindowChrome -Window $main -Label 'main'
            $out = [pscustomobject]@{
                ThemeText = $mainChrome.ThemeText
                MainTitle = $mainChrome.Active; MainTitleInactive = $mainChrome.Inactive
                Main = @($mainChrome.Buttons); Dialogs = @()
            }
            $i = 0
            foreach ($xaml in $Arguments.Dialogs) {
                $i++
                [xml]$x = $xaml
                $d = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
                $d.WindowStartupLocation = 'Manual'
                $d.Left = $(if ($env:SUITE_VISIBLE_WINDOWS -eq '1') { 120 } else { -32000 }); $d.Top = $(if ($env:SUITE_VISIBLE_WINDOWS -eq '1') { 120 } else { -32000 })
                $d.ShowInTaskbar = $false
                Set-DialogTheme -Dialog $d -IsDark $Arguments.Dark
                $d.Show(); Wait-Layout $d
                $c = Get-SuiteWindowChrome -Window $d -Label ([string]$d.Title)
                $out.Dialogs += [pscustomobject]@{ Title = $c.Title; Source = 'XAML'; Index = $i; Active = $c.Active; Inactive = $c.Inactive; TitleRatio = $c.TitleRatio; Buttons = @($c.Buttons) }
                $d.Close()
            }
            # The SuiteCommon dialogs run through their real function. ShowDialog blocks, so a timer measures the owned
            # dialog and closes it. The timer ticks until the dialog is there.
            foreach ($fn in $Arguments.SuiteDialogs) {
                if ($fn -ne 'Show-ConfirmDialog') { throw ('The test cannot open the dialog function {0}. Add it to Chrome.Window.Tests.ps1.' -f $fn) }
                $global:ChromeProbe = @{ Main = $main; Result = $null; Ticks = 0 }
                $timer = New-Object System.Windows.Threading.DispatcherTimer
                $timer.Interval = [TimeSpan]::FromMilliseconds(300)
                $timer.Add_Tick({
                        $p = $global:ChromeProbe
                        $p.Ticks++
                        # The owner also owns its glow windows, so take the owned MetroWindow only.
                        $d = @($p.Main.OwnedWindows | Where-Object { $_ -is [MahApps.Metro.Controls.MetroWindow] })[0]
                        if (-not $d -and $p.Ticks -lt 40) { return }
                        $global:ChromeTimer.Stop()
                        if ($d) {
                            Wait-Layout $d
                            $c = Get-SuiteWindowChrome -Window $d -Label ([string]$d.Title)
                            $p.Result = [pscustomobject]@{ Title = $c.Title; Source = $global:ChromeFunction; Index = 0; Active = $c.Active; Inactive = $c.Inactive; TitleRatio = $c.TitleRatio; Buttons = @($c.Buttons) }
                            $d.Close()
                        }
                        else { [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() }
                    })
                $global:ChromeTimer = $timer
                $global:ChromeFunction = $fn
                $timer.Start()
                [void](Show-ConfirmDialog -Title 'Run Fix for APP-01?' -Message ("This runs the following against site ABC:`r`n`r`n[APP-01] Remove-CMApplication -Name 'Sample'") -Owner $main)
                $timer.Stop()
                if ($global:ChromeProbe.Result) { $out.Dialogs += $global:ChromeProbe.Result }
            }
            $main.Close()
            $out
        }
    }
}

AfterAll {
    if ($script:WindowGuard.Allowed) { Close-WpfSession }
}

Describe 'Chrome <Theme>' -ForEach $script:ThemeCases -Skip:(-not $script:WindowGuard.Allowed) {
    BeforeAll { $script:M = $script:Measured[$Theme] }

    It 'finds every dialog of the app' {
        # Every dialog window comes from a XAML string of the start script or from a SuiteCommon dialog function that the script calls.
        $expected = @($script:ShellDialogXaml).Count + @($script:SuiteDialogCalled).Count
        $expected | Should -BeGreaterThan 1
        @($script:M.Dialogs).Count | Should -Be $expected -Because 'every dialog window of the app must be opened and measured'
        $loads = @([regex]::Matches($script:ShellText, 'XamlReader\]::Load')).Count
        $loads | Should -Be (1 + @($script:ShellDialogXaml).Count) -Because 'one XAML load for the main window and one per dialog'
        $script:NativeDialogCount | Should -BeGreaterThan 0 -Because 'the operating system draws the message boxes and the save dialog, which the test cannot measure'
    }

    It 'gives every dialog the title bar brush of the main window' {
        $bad = @($script:M.Dialogs | Where-Object { $_.Active -ne $script:M.MainTitle -or $_.Inactive -ne $script:M.MainTitleInactive } |
                ForEach-Object { '{0}: active {1} inactive {2}, main {3} {4}' -f $_.Title, $_.Active, $_.Inactive, $script:M.MainTitle, $script:M.MainTitleInactive })
        $bad | Should -BeNullOrEmpty
    }

    It 'keeps the title text of every dialog readable at 4.5:1' {
        $bad = @($script:M.Dialogs | Where-Object { $_.TitleRatio -lt 4.5 } | ForEach-Object { '{0}: {1}' -f $_.Title, $_.TitleRatio })
        $bad | Should -BeNullOrEmpty
    }

    It 'shows bold text on every button of the main window and of every dialog' {
        $all = @($script:M.Main) + @($script:M.Dialogs | ForEach-Object { $_.Buttons })
        $all.Count | Should -BeGreaterThan 5
        $bad = @($all | Where-Object { $_.Weight -lt 600 } | ForEach-Object { '{0} "{1}" weight {2}' -f $_.Window, $_.Text, $_.Weight })
        $bad | Should -BeNullOrEmpty
    }

    It 'gives no button a border thicker than 1 px or in the text color of the theme' {
        $all = @($script:M.Main) + @($script:M.Dialogs | ForEach-Object { $_.Buttons })
        $bad = @($all | Where-Object { $_.BorderThickness -gt 1 -or ($_.BorderThickness -gt 0 -and $_.BorderColor -eq $script:M.ThemeText) } |
                ForEach-Object { '{0} "{1}" border {2}px {3}' -f $_.Window, $_.Text, $_.BorderThickness, $_.BorderColor })
        $bad | Should -BeNullOrEmpty
    }
}
