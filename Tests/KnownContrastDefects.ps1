# Contrast violations that exist today and are not fixed yet. Each entry is
# "<control>:<metric>" or "text:<visible text>". The window test fails when a
# violation is not listed (a new defect) and when a listed one no longer happens
# (remove it here). Run Show-ContrastViolations.ps1 to print the current list.
#
# Text must reach 4.5:1 and a control border 3:1 while the control is enabled, in both
# themes. A disabled control is exempt (WCAG 1.4.3 exempts inactive components), so the
# probe counts no DisabledText and no DisabledBorder. The window test requires instead that a
# disabled control looks clearly dimmed. The causes of the listed defects are shared by every
# suite tool: the light text box border and the unselected tab header. The fix belongs in
# app-packager-suite, then a sync of the vendored copy, not here.

function Get-KnownContrastDefect {
    param(
        [Parameter(Mandatory)][ValidateSet('dark', 'light')][string]$Theme,
        [ValidateSet('Main', 'Dialog')][string]$Scope = 'Main'
    )
    $key = '{0}|{1}' -f $Scope, $Theme
    switch ($key) {
        'Main|dark' {
            @()
        }
        'Main|light' {
            @(
                'cboRelKind:EnabledText', 'cboRelStatus:EnabledText', 'cboStatus:EnabledText',
                'cboCategory:EnabledText', 'cboSeverity:EnabledText',
                'cboTrendMetric:EnabledText', 'cboTrendRange:EnabledText', 'text:Run Fix', 'text:Fix Supersedence'
            )
        }
        'Dialog|dark' {
            @()
        }
        'Dialog|light' {
            @(
                'cboAlertCompliance:EnabledText', 'cboInactiveDays:EnabledText',
                'cboRefreshInterval:EnabledText'
            )
        }
    }
}

function Test-LargeText {
    # WCAG large text: 24 px, or 18.66 px and bold. It needs 3:1; other text needs 4.5:1.
    param([Parameter(Mandatory)]$Row)
    return ($Row.Size -ge 24 -or ($Row.Bold -and $Row.Size -ge 18.66))
}

function Get-ContrastViolationKey {
    # The one place that decides what a contrast violation is and how it is named. The window
    # test and Show-ContrastViolations.ps1 both call it, so the printed list always matches
    # what the test expects. $Views are measured views (Text, Interactive and TitleBar).
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Views)
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($v in $Views) {
        foreach ($r in $v.Text) {
            $min = if (Test-LargeText $r) { 3.0 } else { 4.5 }
            if ($r.Ratio -lt $min) { [void]$keys.Add(('text:{0}' -f $r.Text)) }
        }
        foreach ($c in $v.Interactive) {
            # A disabled control is exempt from the text and border rules (WCAG 1.4.3 exempts inactive components).
            foreach ($metric in 'EnabledText', 'EnabledBorder') {
                $value = $c.$metric
                if ($null -eq $value) { continue }
                $min = if ($metric -like '*Text') { 4.5 } else { 3.0 }
                if ($value -lt $min) { [void]$keys.Add(('{0}:{1}' -f $c.Name, $metric)) }
            }
        }
    }
    $inactive = @($Views)[0].TitleBar.Inactive
    if ($null -ne $inactive -and $inactive -lt 4.5) { [void]$keys.Add('titlebar:inactive') }
    return @($keys | Sort-Object -Unique)
}

function Get-NotDimmedControl {
    # A disabled control is exempt from the 4.5:1 rule (WCAG 1.4.3 exempts inactive components), but it must look
    # clearly dimmed: the enabled text contrast divided by the disabled text contrast is at least 1.25, and the
    # disabled text stays readable (1.5:1 at least), or the label vanishes. Returns one line per offender.
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Views)
    foreach ($v in $Views) {
        foreach ($c in $v.Interactive) {
            if ($null -eq $c.EnabledText -or $null -eq $c.DisabledText) { continue }
            $dim = if ($c.DisabledText -gt 0) { $c.EnabledText / $c.DisabledText } else { [double]::PositiveInfinity }
            if ($dim -lt 1.25) { '{0}: enabled {1}, disabled {2}, not dimmed (needs a ratio of 1.25)' -f $c.Name, $c.EnabledText, $c.DisabledText }
            elseif ($c.DisabledText -lt 1.5) { '{0}: enabled {1}, disabled {2}, unreadable (needs 1.5)' -f $c.Name, $c.EnabledText, $c.DisabledText }
        }
    }
}
