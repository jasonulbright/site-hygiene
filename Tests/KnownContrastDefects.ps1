# Contrast violations that exist today and are not fixed yet. Each entry is
# "<control>:<metric>" or "text:<visible text>". The window test fails when a
# violation is not listed (a new defect) and when a listed one no longer happens
# (remove it here). Run Show-ContrastViolations.ps1 to print the current list.
#
# Text must reach 4.5:1 and a control border 3:1, enabled and disabled, in both
# themes. The causes are shared by every suite tool: the SuiteCommon palette
# (sidebar button border #555555 on #1E1E1E is 2.06:1), the MahApps disabled
# style, the light text box border and the unselected tab header. The fix
# belongs in app-packager-suite, then a sync of the vendored copy, not here.

function Get-KnownContrastDefect {
    param(
        [Parameter(Mandatory)][ValidateSet('dark', 'light')][string]$Theme,
        [ValidateSet('Main', 'Dialog')][string]$Scope = 'Main'
    )
    $key = '{0}|{1}' -f $Scope, $Theme
    switch ($key) {
        'Main|dark' {
            @(
                'btnExportCsv:DisabledText', 'btnExportHtml:DisabledText', 'btnOptions:DisabledBorder',
                'btnOptions:EnabledBorder', 'btnRunFix:DisabledText', 'btnScan:DisabledText',
                'btnSuppress:DisabledText', 'btnUnsuppress:DisabledText', 'btnViewClients:DisabledBorder',
                'btnViewClients:DisabledText', 'btnViewClients:EnabledBorder', 'btnViewContent:DisabledBorder',
                'btnViewContent:DisabledText', 'btnViewContent:EnabledBorder', 'btnViewDeployments:DisabledBorder',
                'btnViewDeployments:DisabledText', 'btnViewDeployments:EnabledBorder', 'btnViewDPs:DisabledBorder',
                'btnViewDPs:DisabledText', 'btnViewDPs:EnabledBorder', 'btnViewFindings:DisabledBorder',
                'btnViewFindings:DisabledText', 'btnViewFindings:EnabledBorder', 'btnViewInactive:DisabledBorder',
                'btnViewInactive:DisabledText', 'btnViewInactive:EnabledBorder', 'btnViewRelationships:DisabledBorder',
                'btnViewRelationships:DisabledText', 'btnViewRelationships:EnabledBorder', 'btnViewSite:DisabledBorder',
                'btnViewSite:DisabledText', 'btnViewSite:EnabledBorder', 'btnViewSummary:DisabledBorder',
                'btnViewSummary:DisabledText', 'btnViewSummary:EnabledBorder', 'btnViewTrends:DisabledBorder',
                'btnViewTrends:DisabledText', 'btnViewTrends:EnabledBorder', 'chkShowSuppressed:DisabledText',
                'text:Inventory', 'text:Run Fix', 'text:Tree',
                'titlebar:inactive'
            )
        }
        'Main|light' {
            @(
                'btnExportCsv:DisabledText', 'btnExportHtml:DisabledText', 'btnOptions:DisabledText',
                'btnRunFix:DisabledText', 'btnScan:DisabledText', 'btnSuppress:DisabledText',
                'btnUnsuppress:DisabledText', 'btnViewClients:DisabledText', 'btnViewContent:DisabledText',
                'btnViewDeployments:DisabledText', 'btnViewDPs:DisabledText', 'btnViewFindings:DisabledText',
                'btnViewInactive:DisabledText', 'btnViewRelationships:DisabledText', 'btnViewSite:DisabledText',
                'btnViewSummary:DisabledText', 'btnViewTrends:DisabledText', 'cboCategory:DisabledBorder',
                'cboCategory:DisabledText', 'cboCategory:EnabledBorder', 'cboCategory:EnabledText',
                'cboSeverity:DisabledBorder', 'cboSeverity:DisabledText', 'cboSeverity:EnabledBorder',
                'cboSeverity:EnabledText', 'cboTrendMetric:DisabledBorder', 'cboTrendMetric:DisabledText',
                'cboTrendMetric:EnabledBorder', 'cboTrendMetric:EnabledText', 'cboTrendRange:DisabledBorder',
                'cboTrendRange:DisabledText', 'cboTrendRange:EnabledBorder', 'cboTrendRange:EnabledText',
                'chkShowSuppressed:DisabledText', 'text:Inventory', 'text:Run Fix',
                'text:Tree', 'titlebar:inactive', 'txtFilter:DisabledBorder',
                'txtFilter:EnabledBorder'
            )
        }
        'Dialog|dark' {
            @(
                'btnCancel:DisabledText', 'btnCatAbout:DisabledText', 'btnCatAlerts:DisabledText',
                'btnCatConnection:DisabledText', 'btnCatLive:DisabledText', 'btnCatScope:DisabledText',
                'btnOk:DisabledText', 'chkAlertsEnabled:DisabledText', 'chkSqlTrustCert:DisabledText',
                'titlebar:inactive'
            )
        }
        'Dialog|light' {
            @(
                'btnCancel:DisabledText', 'btnCatAbout:DisabledText', 'btnCatAlerts:DisabledText',
                'btnCatConnection:DisabledText', 'btnCatLive:DisabledText', 'btnCatScope:DisabledText',
                'btnOk:DisabledText', 'btnOk:EnabledText', 'cboAlertCompliance:DisabledBorder',
                'cboAlertCompliance:DisabledText', 'cboAlertCompliance:EnabledBorder', 'cboAlertCompliance:EnabledText',
                'cboInactiveDays:DisabledBorder', 'cboInactiveDays:DisabledText', 'cboInactiveDays:EnabledBorder',
                'cboInactiveDays:EnabledText', 'cboRefreshInterval:DisabledBorder', 'cboRefreshInterval:DisabledText',
                'cboRefreshInterval:EnabledBorder', 'cboRefreshInterval:EnabledText', 'chkAlertsEnabled:DisabledText',
                'chkSqlTrustCert:DisabledText', 'text:OK', 'titlebar:inactive',
                'txtPacing:DisabledBorder', 'txtPacing:EnabledBorder', 'txtSiteCode:DisabledBorder',
                'txtSiteCode:EnabledBorder', 'txtSmsProvider:DisabledBorder', 'txtSmsProvider:EnabledBorder',
                'txtSqlServer:DisabledBorder', 'txtSqlServer:EnabledBorder'
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
            foreach ($metric in 'EnabledText', 'DisabledText', 'EnabledBorder', 'DisabledBorder') {
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
