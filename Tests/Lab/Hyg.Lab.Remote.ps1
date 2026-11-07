# Runs ON the lab site server (Windows PowerShell 5.1). Started by Invoke-HygLab.ps1.
#
# Creates one ZZTEST- device collection, one ZZTEST- package and three ZZTEST- applications, scans the
# site for them, and runs their fix scripts with Invoke-HygieneFix: the success path, -WhatIf, a missing
# object, a script whose first line fails, a name with a wildcard character and a name with a curly
# apostrophe. It also runs the MNT-01 fix on one real maintenance task: the task settings are site wide, so
# the script records every task before the first change, changes only the Enabled flag of the one task, and
# puts that flag back in the cleanup, also when a step fails. Removes everything it created, also when a step fails. It compares every other collection,
# package and application with a snapshot taken before the first change. Only objects named
# ZZTEST-SH-<tag>-* change.
param(
    [Parameter(Mandatory)][string]$ModuleRoot,
    [Parameter(Mandatory)][string]$SiteCode,
    [Parameter(Mandatory)][string]$Provider
)

$ErrorActionPreference = 'Stop'
$results = [System.Collections.Generic.List[object]]::new()
function Add-Result {
    param([string]$Step, [bool]$Ok, [string]$Detail = '')
    $results.Add([PSCustomObject]@{ Step = $Step; Ok = $Ok; Detail = $Detail })
    Add-Content -LiteralPath (Join-Path $ModuleRoot 'progress.txt') -Value ('{0} | {1} | {2}' -f $Ok, $Step, $Detail)
}

$tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
$prefix = "ZZTEST-SH-$tag-"
$collName = "${prefix}coll"
$pkgName = "${prefix}pkg"
$appWild = "${prefix}app [1]"          # as a pattern, [1] matches the decoy below
$appDecoy = "${prefix}app 1"
$appCurly = "${prefix}it$([char]0x2019)s app"   # a right single quotation mark
$ns = "root\SMS\site_$SiteCode"
$snapshot = $null
$mntName = $null
$mntOriginal = $null
$mntBefore = $null
$mntRecommended = @('Delete Aged Inventory History', 'Delete Aged Discovery Data', 'Delete Obsolete Client Discovery Data', 'Delete Aged Client Operations', 'Delete Aged Log Data')

function Get-Snapshot {
    $c = @(Get-CimInstance -Namespace $ns -ClassName SMS_Collection -Filter 'CollectionType = 2' | Where-Object { $_.Name -notlike 'ZZTEST-*' } | ForEach-Object { '{0}|{1}' -f $_.CollectionID, $_.Name } | Sort-Object)
    $p = @(Get-CMPackage -Fast | Where-Object { $_.Name -notlike 'ZZTEST-*' } | ForEach-Object { '{0}|{1}' -f $_.PackageID, $_.Name } | Sort-Object)
    $a = @(Get-CMApplication -Fast | Where-Object { $_.LocalizedDisplayName -notlike 'ZZTEST-*' } | ForEach-Object { '{0}|{1}' -f $_.CI_ID, $_.LocalizedDisplayName } | Sort-Object)
    [PSCustomObject]@{ Collections = $c; Packages = $p; Applications = $a }
}
function Get-MaintenanceSnapshot {
    @(Get-CMSiteMaintenanceTask | Sort-Object TaskName | ForEach-Object { '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $_.TaskName, $_.Enabled, ($_.DaysOfWeek), ($_.BeginTime), ($_.LatestBeginTime), ($_.DeleteOlderThanDays), ($_.DeviceName) })
}
function Test-AppExists { param([string]$Name) [bool](@(Get-CMApplication -Fast | Where-Object { $_.LocalizedDisplayName -ceq $Name }).Count) }
function Get-FixFinding { param($Findings, [string]$Check, [string]$Name) @($Findings | Where-Object { $_.CheckId -eq $Check -and $_.ObjectName -ceq $Name })[0] }

try {
    Import-Module (Join-Path $ModuleRoot 'Module\SiteHygieneCommon.psd1') -Force -DisableNameChecking
    Initialize-Logging -LogPath (Join-Path $ModuleRoot 'lab.log')

    Add-Result 'connect' ([bool](Connect-CMSite -SiteCode $SiteCode -SMSProvider $Provider)) 'Connect-CMSite'
    Set-Location ('{0}:' -f $SiteCode)
    $others = @(Get-CimInstance -Namespace $ns -ClassName SMS_Collection -Filter "Name LIKE 'ZZTEST-%'")
    $othersP = @(Get-CMPackage -Fast | Where-Object { $_.Name -like 'ZZTEST-*' })
    $othersA = @(Get-CMApplication -Fast | Where-Object { $_.LocalizedDisplayName -like 'ZZTEST-*' })
    if ($others.Count + $othersP.Count + $othersA.Count -gt 0) { throw 'ZZTEST- objects already exist. Another test may be running.' }
    $snapshot = Get-Snapshot

    # --- create the test objects -----------------------------------------------------------------------
    $coll = New-CMDeviceCollection -Name $collName -LimitingCollectionName 'All Systems' -RefreshType Manual
    $pkg = New-CMPackage -Name $pkgName -Version '1'
    foreach ($n in $appWild, $appDecoy, $appCurly) { $null = New-CMApplication -Name $n }
    Add-Result 'create collection, package and three applications' ([bool]($coll.CollectionID -and $pkg.PackageID -and (Test-AppExists $appWild) -and (Test-AppExists $appDecoy) -and (Test-AppExists $appCurly))) "$($coll.CollectionID) $($pkg.PackageID)"

    # --- scan: the checks name the test objects -----------------------------------------------------------
    $scopes = 'Applications', 'Packages', 'Collections'
    $datasets = @(Get-HygieneRequiredDataset -Scopes $scopes | Where-Object { $_ -ne 'Relationships' })
    $data = Get-HygieneData -Datasets $datasets
    Add-Result 'the scan reads every dataset' ($data.FailedDatasets.Count -eq 0) ($data.DatasetNotes -join ' | ')
    $th = Get-HygieneDefaultThresholds
    $th['AppUnusedMinAgeDays'] = 0
    $findings = @(Invoke-HygieneScan -Data $data -Scopes $scopes -Thresholds $th)
    $fPkg = Get-FixFinding $findings 'PKG-01' $pkgName
    $fColl = Get-FixFinding $findings 'COL-01' $collName
    $fWild = Get-FixFinding $findings 'APP-01' $appWild
    $fDecoy = Get-FixFinding $findings 'APP-01' $appDecoy
    $fCurly = Get-FixFinding $findings 'APP-01' $appCurly
    Add-Result 'findings exist for the package, the collection and the three applications' ([bool]($fPkg -and $fColl -and $fWild -and $fDecoy -and $fCurly)) (($findings | Where-Object { $_.ObjectName -like "$prefix*" } | ForEach-Object { "$($_.CheckId) $($_.ObjectName)" }) -join '; ')
    foreach ($f in @($fPkg, $fColl, $fWild, $fCurly)) { if (-not $f) { throw 'A finding for a test object is missing.' } }
    Add-Result 'the fix scripts of the test objects parse' ((@($fPkg, $fColl, $fWild, $fCurly) | Where-Object { $e = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($_.FixScript, [ref]$null, [ref]$e); @($e).Count -gt 0 }).Count -eq 0) $fCurly.FixScript

    # --- Run Fix --------------------------------------------------------------------------------------
    $wi = Invoke-HygieneFix -Finding $fPkg -WhatIf
    Add-Result '-WhatIf runs nothing' ((-not $wi.Success) -and [bool](Get-CMPackage -Id $pkg.PackageID -Fast)) $wi.ErrorMessage

    $r = Invoke-HygieneFix -Finding $fPkg -Confirm:$false
    Add-Result 'fix PKG-01 removes the package' ($r.Success -and -not (Get-CMPackage -Id $pkg.PackageID -Fast)) $r.ErrorMessage
    $r = Invoke-HygieneFix -Finding $fColl -Confirm:$false
    Add-Result 'fix COL-01 removes the collection' ($r.Success -and -not (Get-CMDeviceCollection -Id $coll.CollectionID)) $r.ErrorMessage
    $r = Invoke-HygieneFix -Finding $fWild -Confirm:$false
    Add-Result 'fix APP-01 removes the application with [1] in its name and not the one that the pattern matches' ($r.Success -and -not (Test-AppExists $appWild) -and (Test-AppExists $appDecoy)) $r.ErrorMessage
    $r = Invoke-HygieneFix -Finding $fCurly -Confirm:$false
    Add-Result 'fix APP-01 removes the application with a curly apostrophe in its name' ($r.Success -and -not (Test-AppExists $appCurly)) $r.ErrorMessage

    $missing = [pscustomobject]@{ CheckId = 'APP-01'; ObjectName = "${prefix}none"; FixScript = "Remove-CMApplication -Name '${prefix}none' -DisableWildcardHandling -Force" }
    $r = Invoke-HygieneFix -Finding $missing -Confirm:$false
    Add-Result 'a fix for an object that does not exist reports a failure' (-not $r.Success) "success=$($r.Success) error=[$($r.ErrorMessage)]"

    $partial = [pscustomobject]@{ CheckId = 'APP-01'; ObjectName = 'two lines'; FixScript = "Remove-CMApplication -Name '${prefix}none' -DisableWildcardHandling -Force`r`nRemove-CMApplication -Name '$appDecoy' -DisableWildcardHandling -Force" }
    $r = Invoke-HygieneFix -Finding $partial -Confirm:$false
    Add-Result 'a script whose first line fails reports a failure and its second line does not run' ((-not $r.Success) -and (Test-AppExists $appDecoy)) "success=$($r.Success) error=[$($r.ErrorMessage)]"

    # --- MNT-01 on a real maintenance task --------------------------------------------------------------
    $mntBefore = Get-MaintenanceSnapshot
    $task = @(Get-CMSiteMaintenanceTask | Where-Object { $_.TaskName -in $mntRecommended } | Sort-Object TaskName)[0]
    if (-not $task) { throw 'No recommended maintenance task exists on this site.' }
    $mntName = $task.TaskName
    $mntOriginal = [bool]$task.Enabled
    Add-Result 'look before acting: the maintenance task and its state' $true ("$mntName enabled=$mntOriginal; $(@($mntBefore).Count) tasks recorded")
    if ($mntOriginal) { Set-CMSiteMaintenanceTask -Name $mntName -Enabled $false -DisableWildcardHandling }
    Add-Result 'the task is disabled for the test' (-not [bool](Get-CMSiteMaintenanceTask -Name $mntName).Enabled) $mntName
    $mdata = Get-HygieneData -Datasets 'MaintenanceTasks'
    $mf = @(Test-HygMaintenanceTasks -Data $mdata | Where-Object { $_.CheckId -eq 'MNT-01' -and $_.ObjectName -ceq $mntName })[0]
    Add-Result 'MNT-01 names the task and its fix is runnable' ([bool]$mf -and (Test-HygieneFixExecutable -FixScript $mf.FixScript)) $mf.FixScript
    $wi = Invoke-HygieneFix -Finding $mf -WhatIf
    Add-Result 'MNT-01 under -WhatIf changes nothing' ((-not $wi.Success) -and -not [bool](Get-CMSiteMaintenanceTask -Name $mntName).Enabled) ''
    $r = Invoke-HygieneFix -Finding $mf -Confirm:$false
    Add-Result 'fix MNT-01 enables the task' ($r.Success -and [bool](Get-CMSiteMaintenanceTask -Name $mntName).Enabled) $r.ErrorMessage
    $mb = @(Test-HygMaintenanceTasks -Data (Get-HygieneData -Datasets 'MaintenanceTasks') | Where-Object { $_.CheckId -eq 'MNT-02' })
    Add-Result 'MNT-02 stays guidance only' (@($mb | Where-Object { Test-HygieneFixExecutable -FixScript $_.FixScript }).Count -eq 0) ''

    $okTwo = [pscustomobject]@{ CheckId = 'APP-01'; ObjectName = 'decoy'; FixScript = $fDecoy.FixScript }
    $r = Invoke-HygieneFix -Finding $okTwo -Confirm:$false
    Add-Result 'fix APP-01 removes the decoy' ($r.Success -and -not (Test-AppExists $appDecoy)) $r.ErrorMessage
}
catch {
    Add-Result 'run' $false $_.Exception.Message
}
finally {
    try {
        Set-Location $env:SystemRoot
        if (-not (Test-CMConnection)) { [void](Connect-CMSite -SiteCode $SiteCode -SMSProvider $Provider) }
        Set-Location ('{0}:' -f $SiteCode)
        foreach ($a in @(Get-CMApplication -Fast | Where-Object { $_.LocalizedDisplayName -like "$prefix*" })) {
            try { Remove-CMApplication -InputObject $a -Force -ErrorAction Stop } catch { Add-Result "cleanup application $($a.LocalizedDisplayName)" $false $_.Exception.Message }
        }
        foreach ($p in @(Get-CMPackage -Fast | Where-Object { $_.Name -like "$prefix*" })) {
            try { Remove-CMPackage -Id $p.PackageID -Force -ErrorAction Stop } catch { Add-Result "cleanup package $($p.Name)" $false $_.Exception.Message }
        }
        if ($mntName -and $null -ne $mntOriginal) {
            try { Set-CMSiteMaintenanceTask -Name $mntName -Enabled $mntOriginal -DisableWildcardHandling -ErrorAction Stop } catch { Add-Result "restore maintenance task $mntName" $false $_.Exception.Message }
        }
        for ($pass = 1; $pass -le 3; $pass++) {
            foreach ($c in @(Get-CMDeviceCollection -Name "$prefix*" -ErrorAction SilentlyContinue)) {
                if ($c.Name -notlike "$prefix*") { continue }
                try { Remove-CMDeviceCollection -CollectionId $c.CollectionID -Force -ErrorAction Stop } catch { if ($pass -eq 3) { Add-Result "cleanup collection $($c.Name)" $false $_.Exception.Message } }
            }
        }
    } catch { Add-Result 'cleanup' $false $_.Exception.Message }
    try {
        $leftC = @(Get-CimInstance -Namespace $ns -ClassName SMS_Collection -Filter "Name LIKE '$prefix%'")
        $leftP = @(Get-CMPackage -Fast | Where-Object { $_.Name -like "$prefix*" })
        $leftA = @(Get-CMApplication -Fast | Where-Object { $_.LocalizedDisplayName -like "$prefix*" })
        Add-Result 'no ZZTEST- object of this run remains' ($leftC.Count -eq 0 -and $leftP.Count -eq 0 -and $leftA.Count -eq 0) ''
        if ($snapshot) {
            $after = Get-Snapshot
            $same = ((@($snapshot.Collections) -join "`n") -ceq (@($after.Collections) -join "`n")) -and ((@($snapshot.Packages) -join "`n") -ceq (@($after.Packages) -join "`n")) -and ((@($snapshot.Applications) -join "`n") -ceq (@($after.Applications) -join "`n"))
            Add-Result 'other collections, packages and applications are unchanged' $same ''
        }
        if ($mntBefore) {
            Add-Result 'maintenance tasks are restored exactly' ((@($mntBefore) -join "`n") -ceq (@(Get-MaintenanceSnapshot) -join "`n")) "$mntName enabled=$mntOriginal"
        }
    } catch { Add-Result 'verify cleanup' $false $_.Exception.Message }
}

$results.ToArray() | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $ModuleRoot 'results.json') -Encoding UTF8
