#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x tests for the main window layout (XAML only, no window is opened).
#>

BeforeAll {
    $script:strXamlPath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'MainWindow.xaml'
    $script:xmlWindow = [xml](Get-Content -LiteralPath $script:strXamlPath -Raw)
    $script:nsWpf = New-Object System.Xml.XmlNamespaceManager($script:xmlWindow.NameTable)
    $script:nsWpf.AddNamespace('w', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
}

Describe 'Main window tabs' {
    It 'gives every tab header an explicit theme foreground so unselected tabs keep AA contrast' {
        $arrTab = @($script:xmlWindow.SelectNodes('//w:TabItem', $script:nsWpf))
        $arrTab.Count | Should -BeGreaterThan 0
        foreach ($nodeTab in $arrTab) {
            $nodeText = $nodeTab.SelectSingleNode('w:TabItem.Header/w:TextBlock', $script:nsWpf)
            $nodeText | Should -Not -BeNullOrEmpty -Because 'a plain Header string takes the dim MahApps tab color'
            $nodeText.GetAttribute('Foreground') | Should -Match 'ThemeForeground'
        }
    }
}
