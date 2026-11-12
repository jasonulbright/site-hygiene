# Helpers of Theme.Guard.Tests.ps1. Dot-source from BeforeDiscovery and from BeforeAll.

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:ThemeProperty = @('FontSize', 'FontWeight', 'FontStyle', 'TextDecorations', 'FontFamily', 'FontStretch')
$script:BannedPattern = '(?i)\b(easily|simply|seamless(ly)?|powerful|robust|streamline[sd]?|streamlining|quickly|just|effortless(ly)?|intuitive(ly)?|handy|helps you|allows you to)\b'

# True when a brush value names an accent or a blue color.
function Test-BlueBrush {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value -match 'MahApps\.Brushes\.(Accent\d*|AccentBase|Highlight|Button\.Flat\.Background\.Pressed)\b') { return $true }
    if ($Value -match '(?i)^\s*(blue|dodgerblue|royalblue|steelblue|navy|mediumblue|darkblue|cornflowerblue)\s*$') { return $true }
    if ($Value -match '^\s*#(?:[0-9A-Fa-f]{2})?([0-9A-Fa-f]{2})([0-9A-Fa-f]{2})([0-9A-Fa-f]{2})\s*$') {
        $r = [Convert]::ToInt32($Matches[1], 16) / 255.0
        $g = [Convert]::ToInt32($Matches[2], 16) / 255.0
        $b = [Convert]::ToInt32($Matches[3], 16) / 255.0
        $max = [Math]::Max($r, [Math]::Max($g, $b)); $min = [Math]::Min($r, [Math]::Min($g, $b))
        $d = $max - $min
        if ($d -lt 0.2 -or $max -eq 0) { return $false }
        if ($max -ne $b) { return $false }
        $hue = 60.0 * ((4.0 + (($r - $g) / $d)))
        return ($hue -ge 190 -and $hue -le 260)
    }
    return $false
}

function Test-WhiteBrush {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return ($Value -match '(?i)^\s*(white|#FFFFFF|#FFFFFFFF)\s*$' -or $Value -match 'MahApps\.Brushes\.(Ideal|ThemeIdeal)Foreground')
}

# The value of a Setter: the Value attribute, or the Color of a nested brush.
function Get-SetterValue {
    param($Setter)
    if ($Setter.HasAttribute('Value')) { return $Setter.GetAttribute('Value') }
    $node = $Setter.SelectSingleNode('.//*[@Color]')
    if ($node) { return $node.GetAttribute('Color') }
    return ''
}

# Every XAML document of the repository: the XAML files and the XAML here-strings of the scripts.
function Get-XamlDocument {
    $docs = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $script:RepoRoot -Filter '*.xaml' -File -Recurse | Where-Object { $_.FullName -notmatch '\\(\.claude|\.git)\\' })) {
        $docs += [PSCustomObject]@{ Source = $f.Name; Text = (Get-Content -LiteralPath $f.FullName -Raw) }
    }
    foreach ($f in @(Get-ChildItem -LiteralPath $script:RepoRoot -File -Recurse | Where-Object { $_.Extension -in '.ps1', '.psm1' -and $_.FullName -notmatch '\\(\.claude|\.git|Tests|tools)\\' })) {
        $raw = Get-Content -LiteralPath $f.FullName -Raw
        $i = 0
        foreach ($m in [regex]::Matches($raw, "(?s)@'\r?\n(\s*<[^\r\n]*Window.*?)\r?\n'@")) {
            $i++
            $docs += [PSCustomObject]@{ Source = ('{0} here-string {1}' -f $f.Name, $i); Text = $m.Groups[1].Value }
        }
    }
    return $docs
}

# Returns one text per blue-background rule that has no white foreground.
function Get-BlueWithoutWhite {
    param([string]$Text, [string]$Source)
    [xml]$x = $Text
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($el in @($x.SelectNodes('//*'))) {
        if ($el.LocalName -eq 'Setter' -and $el.GetAttribute('Property') -eq 'Background') {
            if (Test-BlueBrush (Get-SetterValue $el)) {
                $fg = $el.ParentNode.ChildNodes | Where-Object { $_.LocalName -eq 'Setter' -and $_.GetAttribute('Property') -eq 'Foreground' } | Select-Object -First 1
                if (-not $fg -or -not (Test-WhiteBrush (Get-SetterValue $fg))) {
                    [void]$found.Add(('{0}: Setter Background {1} in <{2}> has no white Foreground' -f $Source, (Get-SetterValue $el), $el.ParentNode.LocalName))
                }
            }
        }
        elseif ($el.HasAttribute('Background') -and $el.LocalName -ne 'Setter') {
            if (Test-BlueBrush $el.GetAttribute('Background')) {
                if (-not (Test-WhiteBrush $el.GetAttribute('Foreground'))) {
                    [void]$found.Add(('{0}: <{1}> Background {2} has no white Foreground' -f $Source, $el.LocalName, $el.GetAttribute('Background')))
                }
            }
        }
    }
    return $found.ToArray()
}

# Every string of a script: the constant strings and the text parts of expandable strings.
function Get-ScriptString {
    param([string]$Path)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $nodes = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)
    foreach ($n in $nodes) { [string]$n.Value }
}

# The text a user can read in a XAML document: tooltips and text attributes.
function Get-XamlUiText {
    param([string]$Text)
    [xml]$x = $Text
    foreach ($el in @($x.SelectNodes('//*'))) {
        foreach ($a in @($el.Attributes)) {
            if ($a.LocalName -match '^(ToolTip|Text|Content|Header|Title|Watermark|OnContent|OffContent|ToolTipService.*)$' -or $a.Name -match 'Watermark$') {
                if ($a.Value -notmatch '^\{') { $a.Value }
            }
        }
    }
}

# Returns one text per assignment of a blue string literal to a Background property in a script.
function Get-ScriptBlueBackground {
    param([string]$Path)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $assigns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.MemberExpressionAst] }, $true)
    foreach ($a in $assigns) {
        if ([string]$a.Left.Member.Value -ne 'Background') { continue }
        # A white or ideal foreground set on the same control in the same block makes the blue background safe.
        $target = $a.Left.Expression.Extent.Text
        $siblings = @()
        if ($a.Parent.PSObject.Properties['Statements']) { $siblings = @($a.Parent.Statements | Where-Object { $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left -is [System.Management.Automation.Language.MemberExpressionAst] }) }
        $white = @($siblings | Where-Object { [string]$_.Left.Member.Value -eq 'Foreground' -and $_.Left.Expression.Extent.Text -eq $target -and $_.Right.Extent.Text -match '(?i)IdealForeground|White|#FFFFFF' })
        if ($white.Count -gt 0) { continue }
        $strings = $a.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)
        foreach ($s in $strings) {
            if (Test-BlueBrush ([string]$s.Value)) { '{0}:{1}: Background {2}' -f (Split-Path -Leaf $Path), $a.Extent.StartLineNumber, $s.Value }
        }
    }
}

# Returns one text per style that is based on a MahApps accent button and has no white foreground.
function Get-AccentButtonWithoutWhite {
    param([string]$Text, [string]$Source)
    [xml]$x = $Text
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($st in @($x.SelectNodes("//*[local-name()='Style']"))) {
        if ($st.GetAttribute('BasedOn') -notmatch 'Button\.(Square\.|Flat\.)?Accent') { continue }
        $fg = $st.ChildNodes | Where-Object { $_.LocalName -eq 'Setter' -and $_.GetAttribute('Property') -eq 'Foreground' } | Select-Object -First 1
        if (-not $fg -or -not (Test-WhiteBrush (Get-SetterValue $fg))) {
            [void]$found.Add(('{0}: accent button style {1} has no white Foreground' -f $Source, $st.GetAttribute('Key', 'http://schemas.microsoft.com/winfx/2006/xaml')))
        }
    }
    return $found.ToArray()
}

# Returns one text per button problem in a XAML document: a Button with no Style, a Button style or template
# that is not based on a MahApps style or another style of the document, and a literal color in a button.
function Get-ButtonThemeViolation {
    param([string]$Text, [string]$Source)
    [xml]$x = $Text
    $found = New-Object System.Collections.Generic.List[string]
    $colorProperty = '^(Background|Foreground|BorderBrush|Fill|Stroke|Color|Value)$'
    $isLiteralColor = { param($v) ($v -match '^\s*#[0-9A-Fa-f]{3,8}\s*$') -or ($v -match '^\s*(White|Black|Red|Green|Blue|Gray|Grey|Transparent|Navy|Steel\w*|\w*Blue|Dark\w+|Light\w+)\s*$') }
    $keys = @($x.SelectNodes("//*[local-name()='Style']") | ForEach-Object { $_.GetAttribute('Key', 'http://schemas.microsoft.com/winfx/2006/xaml') })
    foreach ($b in @($x.SelectNodes("//*[local-name()='Button']"))) {
        $name = $b.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
        if (-not $b.HasAttribute('Style') -or $b.GetAttribute('Style') -notmatch '^\{(Static|Dynamic)Resource ') {
            [void]$found.Add(('{0}: Button {1} has no shared Style' -f $Source, $name))
        }
        foreach ($a in @($b.Attributes)) {
            if ($a.LocalName -match '^(Background|Foreground|BorderBrush)$' -and (& $isLiteralColor $a.Value)) { [void]$found.Add(('{0}: Button {1} sets {2} to the literal {3}' -f $Source, $name, $a.LocalName, $a.Value)) }
        }
    }
    $scopes = @($x.SelectNodes("//*[local-name()='Style'][@TargetType='Button']")) + @($x.SelectNodes("//*[local-name()='ControlTemplate'][@TargetType='Button']"))
    foreach ($s in $scopes) {
        $key = $s.GetAttribute('Key', 'http://schemas.microsoft.com/winfx/2006/xaml')
        if ($s.LocalName -eq 'Style') {
            $based = $s.GetAttribute('BasedOn')
            $ok = ($based -match 'MahApps\.Styles\.Button') -or ($based -match '\{StaticResource ([^}\s]+)\}' -and $keys -contains $Matches[1])
            if (-not $ok) { [void]$found.Add(('{0}: Button style {1} is not based on a MahApps style or a shared style' -f $Source, $key)) }
        }
        foreach ($n in @($s.SelectNodes('descendant-or-self::*'))) {
            foreach ($a in @($n.Attributes)) {
                if ($a.LocalName -notmatch $colorProperty) { continue }
                if ($a.LocalName -eq 'Value' -and $n.GetAttribute('Property') -notmatch '^(Background|Foreground|BorderBrush)$') { continue }
                if (& $isLiteralColor $a.Value) { [void]$found.Add(('{0}: {1} {2} uses the literal color {3}' -f $Source, $s.LocalName, $key, $a.Value)) }
            }
        }
    }
    return $found.ToArray()
}
