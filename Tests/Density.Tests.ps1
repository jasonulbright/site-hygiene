#Requires -Modules Pester

<#
.SYNOPSIS
    Pester 5.x test for the compact 1080p density of the main window (XAML only, no window is opened).
    The shared style values are asserted in one place. The window test Density.Window.Tests.ps1 measures them on screen.
#>

BeforeAll {
    $script:Xaml = [xml](Get-Content -LiteralPath (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'MainWindow.xaml') -Raw)
    $script:Ns = New-Object System.Xml.XmlNamespaceManager($script:Xaml.NameTable)
    $script:Ns.AddNamespace('w', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
    $script:Ns.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
    function Get-StyleValue {
        param([string]$Key, [string]$Property)
        $style = $script:Xaml.SelectSingleNode("//w:Style[@x:Key='$Key']", $script:Ns)
        $style | Should -Not -BeNullOrEmpty -Because $Key
        $setter = $style.SelectSingleNode("w:Setter[@Property='$Property']", $script:Ns)
        if ($setter) { $setter.GetAttribute('Value') } else { $null }
    }
}

Describe 'Compact density at 1080p' {
    It 'opens at the design size of a maximized 1080p work area and keeps the minimum size of the app' {
        $w = $script:Xaml.DocumentElement
        [int]$w.GetAttribute('Width') | Should -Be 1920
        [int]$w.GetAttribute('Height') | Should -Be 1032
        [int]$w.GetAttribute('MinWidth') | Should -BeLessOrEqual 1024
        [int]$w.GetAttribute('MinHeight') | Should -BeLessOrEqual 680
    }

    It 'sizes the sidebar view buttons between 34 and 36 px' {
        [double](Get-StyleValue 'ViewButtonStyle' 'Height') | Should -BeIn 34, 35, 36
    }

    It 'sizes the inline buttons between 26 and 28 px' {
        [double](Get-StyleValue 'SquareInlineButtonStyle' 'Height') | Should -BeGreaterOrEqual 26
        [double](Get-StyleValue 'SquareInlineButtonStyle' 'Height') | Should -BeLessOrEqual 28
    }

    It 'gives every grid rows of 24 to 26 px and a 26 px column header from the one shared style' {
        [double](Get-StyleValue 'ViewDataGrid' 'RowHeight') | Should -BeGreaterOrEqual 24
        [double](Get-StyleValue 'ViewDataGrid' 'RowHeight') | Should -BeLessOrEqual 26
        [double](Get-StyleValue 'ViewDataGrid' 'ColumnHeaderHeight') | Should -Be 26
        foreach ($g in @($script:Xaml.SelectNodes('//w:DataGrid', $script:Ns))) {
            $g.GetAttribute('RowHeight') | Should -BeNullOrEmpty -Because 'the row height has one place: ViewDataGrid'
            $g.GetAttribute('Style') | Should -Match 'ViewDataGrid' -Because $g.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
        }
    }

    It 'gives no list, grid or detail pane of a view a fixed row height, so that the panes share the free height' {
        # The shell row of the log output may keep a fixed height: the content row above it takes all the free space.
        foreach ($view in @($script:Xaml.SelectNodes("//w:Grid[starts-with(@x:Name,'view')]", $script:Ns))) {
            foreach ($row in @($view.SelectNodes('w:Grid.RowDefinitions/w:RowDefinition', $script:Ns))) {
                $h = $row.GetAttribute('Height')
                if ($h -match '^\d+(\.\d+)?$') { [double]$h | Should -BeLessOrEqual 10 -Because ('{0} has a fixed row of {1} px' -f $view.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml'), $h) }
            }
        }
    }
}
