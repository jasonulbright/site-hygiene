#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.1.0' }
# Guard tests for the tooltips. They parse the XAML of the window and of the dialogs. They create no
# WPF control, open no window and need no ConfigMgr, so they run on Windows PowerShell 5.1 and on PowerShell 7.
#
# Rules:
#   1. Every control in the audited list has a ToolTip.
#   2. A ToolTip is ASCII and ends in a period. The ToolTip of an audited control has at most 159 characters.
#   3. The progress bar of the Fix Supersedence window starts hidden.
#
# To audit a new control: add its x:Name to the list in BeforeDiscovery. A control that is not in the list
# needs no ToolTip (read-only output, dialog buttons whose label says it all, grid columns, hidden bars).

BeforeDiscovery {
    # x:Name of every control that must explain itself. The file is MainWindow.xaml or the script.
    $script:Audited = @(
        'txtFilter', 'cboTrendMetric', 'cboTrendRange',
        'btnCatConnection', 'btnCatScope', 'btnCatLive', 'btnCatAlerts', 'btnCatAbout',
        'txtSiteCode', 'txtSmsProvider', 'txtSqlServer', 'chkSqlTrustCert',
        'txtPacing', 'txtDeploymentOldDays', 'cboRefreshInterval', 'cboInactiveDays',
        'chkAlertsEnabled', 'cboAlertCompliance', 'btnApply'
    )
    # A TabItem has no name. These are the header texts of the tabs that must have a ToolTip.
    $script:AuditedTab = @('Inventory', 'Tree')
    $script:Cases = @($script:Audited | ForEach-Object { @{ Name = $_ } })
    $script:TabCases = @($script:AuditedTab | ForEach-Object { @{ Header = $_ } })
}

BeforeAll {
    $script:Root = Split-Path -Path $PSScriptRoot -Parent
    $script:XamlNs = 'http://schemas.microsoft.com/winfx/2006/xaml'
    $script:MaxLength = 159

    # Every XAML document of the app: MainWindow.xaml and each XAML here-string of the script.
    function Get-XamlDocument {
        $docs = New-Object System.Collections.Generic.List[object]
        $chunks = New-Object System.Collections.Generic.List[object]
        $chunks.Add(@{ Label = 'MainWindow.xaml'; Text = [IO.File]::ReadAllText((Join-Path $script:Root 'MainWindow.xaml')) })
        $source = [IO.File]::ReadAllText((Join-Path $script:Root 'start-sitehygiene.ps1'))
        $i = 0
        foreach ($m in [regex]::Matches($source, "(?ms)@(?:'|`")[ \t]*\r?\n(\s*<.*?)\r?\n(?:'|`")@")) {
            $i++
            $chunks.Add(@{ Label = ('start-sitehygiene.ps1 xaml {0}' -f $i); Text = $m.Groups[1].Value })
        }
        foreach ($c in $chunks) {
            $x = New-Object System.Xml.XmlDocument
            $x.LoadXml($c.Text)
            $docs.Add([pscustomobject]@{ Label = $c.Label; Xml = $x })
        }
        , $docs.ToArray()
    }

    function Get-XName {
        param($Node)
        $Node.GetAttribute('Name', $script:XamlNs)
    }

    function Get-NamedElement {
        param([string]$Name)
        $found = New-Object System.Collections.Generic.List[object]
        foreach ($d in $script:Documents) {
            foreach ($el in @($d.Xml.SelectNodes('//*[@*[local-name()="Name"]]'))) {
                if ((Get-XName $el) -eq $Name) { $found.Add([pscustomobject]@{ Label = $d.Label; Element = $el }) }
            }
        }
        $found.ToArray()
    }

    $script:Documents = Get-XamlDocument
}

Describe 'Tooltips of the audited controls' {
    It 'has a ToolTip on <Name>' -ForEach $script:Cases {
        $hits = @(Get-NamedElement -Name $Name)
        $hits.Count | Should -BeGreaterThan 0 -Because ('{0} is not in any XAML document' -f $Name)
        foreach ($h in $hits) {
            $tip = $h.Element.GetAttribute('ToolTip')
            $tip | Should -Not -BeNullOrEmpty -Because ('{0} in {1} needs a ToolTip' -f $Name, $h.Label)
            $tip.Length | Should -BeLessOrEqual $script:MaxLength -Because ('the ToolTip of {0} has {1} characters' -f $Name, $tip.Length)
        }
    }

    It 'has a ToolTip on the <Header> tab' -ForEach $script:TabCases {
        $tab = @($script:Documents[0].Xml.SelectNodes('//*[local-name()="TabItem"]') |
                Where-Object { @($_.SelectNodes('.//*[local-name()="TextBlock"][@Text="' + $Header + '"]')).Count -gt 0 })
        $tab.Count | Should -Be 1 -Because ('the tab {0} is in MainWindow.xaml' -f $Header)
        $tab[0].GetAttribute('ToolTip') | Should -Not -BeNullOrEmpty
        $tab[0].GetAttribute('ToolTip').Length | Should -BeLessOrEqual $script:MaxLength
    }

    It 'writes every ToolTip in the app as ASCII text that ends in a period' {
        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($d in $script:Documents) {
            foreach ($el in @($d.Xml.SelectNodes('//*[@ToolTip]'))) {
                $tip = $el.GetAttribute('ToolTip')
                $what = '{0}: {1} {2}' -f $d.Label, $el.LocalName, (Get-XName $el)
                if ([string]::IsNullOrWhiteSpace($tip)) { $bad.Add(('{0} has an empty ToolTip' -f $what)); continue }
                if ($tip -match '[^\x20-\x7E]') { $bad.Add(('{0} has a non-ASCII character' -f $what)) }
                if ($tip -notmatch '\.$') { $bad.Add(('{0} does not end in a period' -f $what)) }
            }
        }
        $bad | Should -BeNullOrEmpty -Because ($bad -join '; ')
    }

    It 'keeps the progress bar of a work window hidden and indeterminate at start' {
        $bars = @(Get-NamedElement -Name 'barRunning')
        $bars.Count | Should -BeGreaterThan 0
        foreach ($b in $bars) {
            $b.Element.GetAttribute('Visibility') | Should -Be 'Collapsed' -Because $b.Label
            $b.Element.GetAttribute('IsIndeterminate') | Should -Be 'True' -Because $b.Label
        }
    }
}
