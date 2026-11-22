<#
.SYNOPSIS
    Core module for Site Hygiene.

.DESCRIPTION
    Import this module to get:
      - Structured logging and ConfigMgr site connection management by using the
        vendored SuiteCommon module (Lib\SuiteCommon)
      - Scan scopes (Get-HygieneScanScope, Get-HygieneRequiredDataset)
      - Site data prefetch limited to the datasets a scope needs
        (Get-HygieneData)
      - Pure hygiene checks over the prefetched data (Test-Hyg*)
      - Scan orchestration (Invoke-HygieneScan)
      - Findings export to CSV, HTML, and plain-text summary

    A scan is read-only: the prefetch uses Get-CM* cmdlets plus WQL
    queries over the same provider connection and never mutates the
    site. Every finding carries the evidence that produced it, a
    recommendation, and the PowerShell a fix would run. Only
    Invoke-HygieneFix executes a fix script, and it refuses a
    comment-only script.

.EXAMPLE
    Import-Module "$PSScriptRoot\Module\SiteHygieneCommon.psd1" -Force
    Initialize-Logging -LogPath "C:\temp\hygiene.log"
    Connect-CMSite -SiteCode 'MCM' -SMSProvider 'cm01.contoso.com'
    $data     = Get-HygieneData
    $findings = Invoke-HygieneScan -Data $data
#>

# ---------------------------------------------------------------------------
# Shared core (vendored SuiteCommon)
# ---------------------------------------------------------------------------
if (-not (Get-Module SuiteCommon)) {
    Import-Module (Join-Path $PSScriptRoot '..\Lib\SuiteCommon\SuiteCommon.psd1') -Global -DisableNameChecking
}

# Timed-out content probes are stopped asynchronously so the scan thread
# never blocks on a dead SMB endpoint. Keep them rooted until a later probe
# observes the terminal state and disposes them.
$script:AppContentProbeGraveyard = @()

function ConvertTo-HygQuotedLiteral {
    <#
    .SYNOPSIS
        Escapes text for the inside of a single-quoted PowerShell string.

    .DESCRIPTION
        PowerShell reads four more characters as a single quote besides the
        apostrophe: the left, right, low and reversed single quotation marks
        (U+2018, U+2019, U+201A, U+201B). Each one ends the string unless it
        is doubled. A name from the site (an application, a rule, a window)
        goes into a fix script only through this function.
    #>
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return [regex]::Replace($Text, "['\u2018\u2019\u201A\u201B]", '$0$0')
}
# ---------------------------------------------------------------------------
# Check catalog
# ---------------------------------------------------------------------------

function Get-HygieneCheckCatalog {
    <#
    .SYNOPSIS
        Returns the implemented check catalog: Id, Category, Severity,
        Title. Stable IDs come from the project register.
    #>
    return @(
        [pscustomobject]@{ Id = 'APP-01'; Category = 'Applications'; Severity = 'Warning'; Title = 'Application with no deployments or references' }
        [pscustomobject]@{ Id = 'APP-02'; Category = 'Applications'; Severity = 'Error';   Title = 'Retired application still deployed' }
        [pscustomobject]@{ Id = 'APP-03'; Category = 'Applications'; Severity = 'Warning'; Title = 'Superseded application still deployed' }
        [pscustomobject]@{ Id = 'APP-04'; Category = 'Applications'; Severity = 'Warning'; Title = 'Deployment type content source missing or unreachable' }
        [pscustomobject]@{ Id = 'APP-05'; Category = 'Applications'; Severity = 'Info';    Title = 'Application with old revisions' }
        [pscustomobject]@{ Id = 'APP-07'; Category = 'Applications'; Severity = 'Warning'; Title = 'Retired application that still supersedes or depends on an application' }
        [pscustomobject]@{ Id = 'APP-08'; Category = 'Applications'; Severity = 'Info';    Title = 'Superseded application that qualifies for deletion' }
        [pscustomobject]@{ Id = 'PKG-01'; Category = 'Packages';     Severity = 'Warning'; Title = 'Package with no programs and no references' }
        [pscustomobject]@{ Id = 'CNT-01'; Category = 'Content';      Severity = 'Warning'; Title = 'Content failed on one or more distribution points' }
        [pscustomobject]@{ Id = 'CNT-02'; Category = 'Content';      Severity = 'Info';    Title = 'Content distribution in progress beyond threshold' }
        [pscustomobject]@{ Id = 'CNT-03'; Category = 'Content';      Severity = 'Error';   Title = 'Deployed content on no distribution point' }
        [pscustomobject]@{ Id = 'SUP-01'; Category = 'Relationships'; Severity = 'Error';   Title = 'Supersedence referencing a deleted application' }
        [pscustomobject]@{ Id = 'SUP-02'; Category = 'Relationships'; Severity = 'Error';   Title = 'Circular supersedence chain' }
        [pscustomobject]@{ Id = 'SUP-03'; Category = 'Relationships'; Severity = 'Warning'; Title = 'Superseding application disabled' }
        [pscustomobject]@{ Id = 'SUP-04'; Category = 'Relationships'; Severity = 'Warning'; Title = 'Supersedence target retired or expired' }
        [pscustomobject]@{ Id = 'DEP-01'; Category = 'Relationships'; Severity = 'Error';   Title = 'Dependency referencing a deleted application' }
        [pscustomobject]@{ Id = 'DEP-02'; Category = 'Relationships'; Severity = 'Error';   Title = 'Circular dependency' }
        [pscustomobject]@{ Id = 'DEP-03'; Category = 'Relationships'; Severity = 'Warning'; Title = 'Dependency target disabled' }
        [pscustomobject]@{ Id = 'DEP-04'; Category = 'Relationships'; Severity = 'Warning'; Title = 'Dependency target retired or expired' }
        [pscustomobject]@{ Id = 'DEP-05'; Category = 'Relationships'; Severity = 'Info';    Title = 'Dependency target reports no packaged content' }
        [pscustomobject]@{ Id = 'REL-01'; Category = 'Relationships'; Severity = 'Info';    Title = 'Application relationships without manufacturer metadata' }
        [pscustomobject]@{ Id = 'DEV-01'; Category = 'Devices';      Severity = 'Warning'; Title = 'Inactive devices beyond threshold' }
        [pscustomobject]@{ Id = 'DEV-02'; Category = 'Devices';      Severity = 'Warning'; Title = 'Duplicate device records' }
        [pscustomobject]@{ Id = 'DEV-03'; Category = 'Devices';      Severity = 'Info';    Title = 'Clients below the newest client version' }
        [pscustomobject]@{ Id = 'BND-01'; Category = 'Boundaries';   Severity = 'Warning'; Title = 'Boundary in no boundary group' }
        [pscustomobject]@{ Id = 'BND-02'; Category = 'Boundaries';   Severity = 'Warning'; Title = 'Boundary group with no site systems' }
        [pscustomobject]@{ Id = 'BND-03'; Category = 'Boundaries';   Severity = 'Info';    Title = 'Overlapping IP-range boundaries' }
        [pscustomobject]@{ Id = 'TSQ-01'; Category = 'Task Sequences'; Severity = 'Error';   Title = 'Task sequence referencing deleted content' }
        [pscustomobject]@{ Id = 'TSQ-02'; Category = 'Task Sequences'; Severity = 'Warning'; Title = 'Boot image or driver package referenced by nothing' }
        [pscustomobject]@{ Id = 'TSQ-03'; Category = 'Task Sequences'; Severity = 'Warning'; Title = 'Application in a task sequence without the task sequence install setting' }
        [pscustomobject]@{ Id = 'TSQ-04'; Category = 'Task Sequences'; Severity = 'Error';   Title = 'Application in a task sequence with content on no distribution point' }
        [pscustomobject]@{ Id = 'TSQ-05'; Category = 'Task Sequences'; Severity = 'Warning'; Title = 'Task sequence installs a retired or superseded application' }
        [pscustomobject]@{ Id = 'TSQ-06'; Category = 'Task Sequences'; Severity = 'Warning'; Title = 'Stale reference rows of a task sequence that the site does not return' }
        [pscustomobject]@{ Id = 'UPD-01'; Category = 'Updates';      Severity = 'Warning'; Title = 'Software update group with a high expired-update ratio' }
        [pscustomobject]@{ Id = 'UPD-03'; Category = 'Updates';      Severity = 'Warning'; Title = 'Automatic deployment rule disabled, stale, or erroring' }
        [pscustomobject]@{ Id = 'MNT-01'; Category = 'Site';         Severity = 'Info';    Title = 'Recommended maintenance tasks disabled' }
        [pscustomobject]@{ Id = 'MNT-02'; Category = 'Site';         Severity = 'Warning'; Title = 'Site backup task disabled' }
        [pscustomobject]@{ Id = 'COL-01'; Category = 'Collections';  Severity = 'Info';    Title = 'Empty collection nothing references' }
        [pscustomobject]@{ Id = 'COL-02'; Category = 'Collections';  Severity = 'Warning'; Title = 'Deployment targeting an empty collection' }
        [pscustomobject]@{ Id = 'COL-03'; Category = 'Collections';  Severity = 'Warning'; Title = 'Incremental-evaluation collection count over ceiling' }
        [pscustomobject]@{ Id = 'COL-04'; Category = 'Collections';  Severity = 'Warning'; Title = 'Collection evaluation run time over threshold' }
        [pscustomobject]@{ Id = 'COL-05'; Category = 'Collections';  Severity = 'Warning'; Title = 'Sub-daily full evaluation on an incremental collection' }
        [pscustomobject]@{ Id = 'COL-06'; Category = 'Collections';  Severity = 'Info';    Title = 'Scheduled evaluation on a direct-rule-only collection' }
        [pscustomobject]@{ Id = 'COL-07'; Category = 'Collections';  Severity = 'Warning'; Title = 'Include/exclude reference chain over depth threshold' }
        [pscustomobject]@{ Id = 'COL-08'; Category = 'Collections';  Severity = 'Error';   Title = 'Circular collection reference' }
        [pscustomobject]@{ Id = 'COL-09'; Category = 'Collections';  Severity = 'Info';    Title = 'Full-update start-time hot spot' }
        [pscustomobject]@{ Id = 'DPL-01'; Category = 'Deployments';  Severity = 'Info';    Title = 'Deployment past its expiration time' }
        [pscustomobject]@{ Id = 'DPL-02'; Category = 'Deployments';  Severity = 'Error';   Title = 'Required deployment past deadline with high failures' }
        [pscustomobject]@{ Id = 'COL-10'; Category = 'Collections';  Severity = 'Info';    Title = 'Expired one-time maintenance window' }
        [pscustomobject]@{ Id = 'DPL-03'; Category = 'Deployments';  Severity = 'Info';    Title = 'Available deployment with no takers' }
        [pscustomobject]@{ Id = 'DPL-04'; Category = 'Deployments';  Severity = 'Warning'; Title = 'Required deployment to a built-in all-resources collection' }
        [pscustomobject]@{ Id = 'DPL-05'; Category = 'Deployments';  Severity = 'Warning'; Title = 'Deployment of a disabled task sequence or program' }
        [pscustomobject]@{ Id = 'DPL-06'; Category = 'Deployments';  Severity = 'Info';    Title = 'Deployment created more than the age threshold ago' }
        [pscustomobject]@{ Id = 'UPD-04'; Category = 'Updates';      Severity = 'Warning'; Title = 'Software update group over the per-deployment update limit' }
        [pscustomobject]@{ Id = 'UPD-05'; Category = 'Updates';      Severity = 'Info';    Title = 'Deployment package holding expired update content' }
        [pscustomobject]@{ Id = 'DPT-01'; Category = 'Distribution Points'; Severity = 'Warning'; Title = 'Distribution point in no boundary group' }
        [pscustomobject]@{ Id = 'DPT-02'; Category = 'Distribution Points'; Severity = 'Info';    Title = 'Distribution point group with no members' }
        [pscustomobject]@{ Id = 'CFG-01'; Category = 'Compliance';   Severity = 'Info';    Title = 'Configuration baseline deployed nowhere' }
        [pscustomobject]@{ Id = 'CFG-02'; Category = 'Compliance';   Severity = 'Info';    Title = 'Configuration item in no baseline' }
        [pscustomobject]@{ Id = 'CFG-03'; Category = 'Compliance';   Severity = 'Info';    Title = 'Custom client settings deployed to no collection' }
        [pscustomobject]@{ Id = 'DRV-01'; Category = 'Drivers';      Severity = 'Info';    Title = 'Driver in no driver package or boot image' }
        [pscustomobject]@{ Id = 'SEC-01'; Category = 'Security';     Severity = 'Warning'; Title = 'Administrative user with a deleted directory account' }
    )
}

function Get-HygieneDefaultThresholds {
    <#
    .SYNOPSIS
        Default tunables for the checks that take one.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns the full thresholds hashtable by design.')]
    param()
    return @{
        AppUnusedMinAgeDays       = 30
        IncrementalCeiling        = 200
        DeadlineGraceDays         = 7
        FailurePctThreshold       = 20
        AvailableUnusedMinAgeDays = 30
        DeploymentOldDays         = 365
        InactiveDeviceDays        = 90
        SugExpiredPctThreshold    = 30
        AdrStaleDays              = 45
        ColRefDepthMax            = 3
        ColFullEvalHotSpotCount   = 10
        ContentStuckDays          = 2
        ColEvalSlowMs             = 5000
        SugMaxUpdates             = 1000
    }
}

function New-HygieneFinding {
    <#
    .SYNOPSIS
        Uniform finding object every check returns.

    .DESCRIPTION
        A FixScript that starts with a comment is guidance for the operator, never a script to run. Its line
        breaks are replaced with spaces, so a name from the site cannot add a line that Run Fix would execute.
        A script that Run Fix may execute starts with its command. Put a comment after the command, not before.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Constructs an in-memory finding object; changes no system state.')]
    param(
        [Parameter(Mandatory)][string]$CheckId,
        [Parameter(Mandatory)][ValidateSet('Error', 'Warning', 'Info')][string]$Severity,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$ObjectType,
        [AllowEmptyString()][string]$ObjectId = '',
        [Parameter(Mandatory)][AllowEmptyString()][string]$ObjectName,
        [Parameter(Mandatory)][string]$Evidence,
        [Parameter(Mandatory)][string]$Recommendation,
        [AllowEmptyString()][string]$FixScript = '',
        # The exact identifiers of a fix that has its own window, not a script. Null for every other finding.
        [AllowNull()]$FixData = $null
    )

    # A fix script that starts with a comment is guidance for the operator. A name from the site that holds a line
    # break would otherwise start a new line, and the script would run that line. Guidance stays on one line.
    if ($FixScript.TrimStart().StartsWith('#')) { $FixScript = [regex]::Replace($FixScript, '[\r\n\u0085\u2028\u2029]+', ' ') }

    return [pscustomobject]@{
        CheckId        = $CheckId
        Severity       = $Severity
        Category       = $Category
        ObjectType     = $ObjectType
        ObjectId       = $ObjectId
        ObjectName     = $ObjectName
        Evidence       = $Evidence
        Recommendation = $Recommendation
        FixScript      = $FixScript
        FixData        = $FixData
    }
}

# ---------------------------------------------------------------------------
# Scan scopes and data prefetch (the only CM-touching part of a scan)
# ---------------------------------------------------------------------------

function Get-HygieneScanScope {
    <#
    .SYNOPSIS
        Returns the selectable scan scopes: Id, Title, Slow. A scope marked
        Slow costs one provider round-trip per object instead of one query
        per dataset.
    #>
    return @(
        [pscustomobject]@{ Id = 'Applications';        Title = 'Applications';                                Slow = $false }
        [pscustomobject]@{ Id = 'AppRelationships';    Title = 'Application relationships and content paths'; Slow = $true }
        [pscustomobject]@{ Id = 'Content';             Title = 'Content distribution';                        Slow = $false }
        [pscustomobject]@{ Id = 'Packages';            Title = 'Packages';                                    Slow = $false }
        [pscustomobject]@{ Id = 'Collections';         Title = 'Collections';                                 Slow = $false }
        [pscustomobject]@{ Id = 'CollectionSchedules'; Title = 'Collection evaluation schedules';             Slow = $true }
        [pscustomobject]@{ Id = 'Deployments';         Title = 'Deployments';                                 Slow = $false }
        [pscustomobject]@{ Id = 'Devices';             Title = 'Devices';                                     Slow = $false }
        [pscustomobject]@{ Id = 'Boundaries';          Title = 'Boundaries';                                  Slow = $false }
        [pscustomobject]@{ Id = 'TaskSequences';       Title = 'Task sequences';                              Slow = $false }
        [pscustomobject]@{ Id = 'Updates';             Title = 'Software updates';                            Slow = $false }
        [pscustomobject]@{ Id = 'UpdateContent';       Title = 'Software update package content';             Slow = $false }
        [pscustomobject]@{ Id = 'DistributionPoints';  Title = 'Distribution points';                         Slow = $false }
        [pscustomobject]@{ Id = 'Compliance';          Title = 'Compliance and client settings';              Slow = $false }
        [pscustomobject]@{ Id = 'Drivers';             Title = 'Drivers';                                     Slow = $false }
        [pscustomobject]@{ Id = 'Security';            Title = 'Administrative users';                        Slow = $false }
        [pscustomobject]@{ Id = 'MaintenanceWindows';  Title = 'Maintenance windows';                         Slow = $true }
        [pscustomobject]@{ Id = 'Site';                Title = 'Site maintenance';                            Slow = $false }
    )
}

function Get-HygScanPlan {
    <#
    .SYNOPSIS
        The check table: Id, Scopes that select the check, Requires (the
        datasets the check reads as evidence), and the runner.

    .DESCRIPTION
        Threshold-less checks take only $d; the runner still passes every
        argument and the extras land in $args, keeping one invocation
        shape. A check whose Requires includes a failed or uncollected
        dataset never runs: over an empty array it would turn a query
        failure into "nothing references this object" plus a deletion
        script.
    #>
    return @(
        @{ Id = 'APP-01'; Scopes = @('Applications'); Requires = @('Applications','Deployments','TaskSequences','DependencyTargetCIIDs'); Run = { param($d, $t) Test-HygAppNoReferences -Data $d -Thresholds $t } }
        @{ Id = 'APP-02'; Scopes = @('Applications'); Requires = @('Applications'); Run = { param($d) Test-HygAppRetiredDeployed -Data $d } }
        @{ Id = 'APP-03'; Scopes = @('Applications'); Requires = @('Applications'); Run = { param($d) Test-HygAppSupersededDeployed -Data $d } }
        @{ Id = 'APP-05'; Scopes = @('Applications'); Requires = @('Applications','AppRevisions'); Run = { param($d) Test-HygAppOldRevisions -Data $d } }
        @{ Id = 'CNT';    Scopes = @('Content'); Requires = @('ContentStatus','Applications','Deployments'); Run = { param($d, $t) Test-HygContentDistribution -Data $d -Thresholds $t } }
        @{ Id = 'PKG-01'; Scopes = @('Packages'); Requires = @('Packages','Programs','Deployments','TaskSequences'); Run = { param($d) Test-HygPackageUnused -Data $d } }
        @{ Id = 'COL-01'; Scopes = @('Collections'); Requires = @('Collections','Deployments','CollectionsWithSettings','CollectionDependencies'); Run = { param($d) Test-HygCollectionEmptyUnused -Data $d } }
        @{ Id = 'COL-02'; Scopes = @('Collections'); Requires = @('Collections','Deployments'); Run = { param($d) Test-HygDeploymentEmptyCollection -Data $d } }
        @{ Id = 'COL-03'; Scopes = @('Collections'); Requires = @('Collections'); Run = { param($d, $t) Test-HygIncrementalCeiling -Data $d -Thresholds $t } }
        @{ Id = 'COL-04'; Scopes = @('Collections'); Requires = @('CollectionEvalFull','CollectionEvalIncremental'); Run = { param($d, $t) Test-HygCollectionEvaluationRunTime -Data $d -Thresholds $t } }
        @{ Id = 'COL-EVAL'; Scopes = @('Collections','CollectionSchedules'); Requires = @('Collections','CollectionDependencies'); Run = { param($d, $t) Test-HygCollectionEvaluationChecks -Data $d -Thresholds $t } }
        @{ Id = 'DPL-01'; Scopes = @('Deployments'); Requires = @('AppDeployments'); Run = { param($d) Test-HygDeploymentExpired -Data $d } }
        @{ Id = 'DPL-02'; Scopes = @('Deployments'); Requires = @('Deployments'); Run = { param($d, $t) Test-HygDeploymentPastDeadlineFailures -Data $d -Thresholds $t } }
        @{ Id = 'DPL-03'; Scopes = @('Deployments'); Requires = @('Deployments'); Run = { param($d, $t) Test-HygDeploymentAvailableUnused -Data $d -Thresholds $t } }
        @{ Id = 'DEV-01'; Scopes = @('Devices'); Requires = @('Devices','MaintenanceTasks'); Run = { param($d, $t) Test-HygDeviceInactive -Data $d -Thresholds $t } }
        @{ Id = 'DEV-02'; Scopes = @('Devices'); Requires = @('Devices'); Run = { param($d) Test-HygDeviceDuplicates -Data $d } }
        @{ Id = 'DEV-03'; Scopes = @('Devices'); Requires = @('Devices'); Run = { param($d) Test-HygClientVersions -Data $d } }
        @{ Id = 'BND';    Scopes = @('Boundaries'); Requires = @('Boundaries','BoundaryGroups'); Run = { param($d) Test-HygBoundaryChecks -Data $d } }
        @{ Id = 'TSQ-APP'; Scopes = @('TaskSequences'); Requires = @('TaskSequences','Applications','TsAppDefinitions','ContentStatus'); Run = { param($d) Test-HygTaskSequenceApplications -Data $d } }
        @{ Id = 'TSQ';    Scopes = @('TaskSequences'); Requires = @('TaskSequences','Packages','BootImages','DriverPackages','UpdatePackages','OSImages','OSUpgradePackages','Applications'); Run = { param($d) Test-HygTaskSequenceRefs -Data $d } }
        @{ Id = 'UPD-01'; Scopes = @('Updates'); Requires = @('UpdateGroups'); Run = { param($d, $t) Test-HygUpdateGroupChecks -Data $d -Thresholds $t } }
        @{ Id = 'UPD-03'; Scopes = @('Updates'); Requires = @('AutoDeploymentRules'); Run = { param($d, $t) Test-HygAdrChecks -Data $d -Thresholds $t } }
        @{ Id = 'DPL-04'; Scopes = @('Deployments'); Requires = @('Deployments'); Run = { param($d) Test-HygDeploymentBroadRequired -Data $d } }
        @{ Id = 'DPL-06'; Scopes = @('Deployments'); Requires = @('Deployments'); Run = { param($d, $t) Test-HygDeploymentOld -Data $d -Thresholds $t } }
        @{ Id = 'DPL-05'; Scopes = @('Deployments'); Requires = @('Deployments','Programs','TaskSequences'); Run = { param($d) Test-HygDeployedDisabledObject -Data $d } }
        @{ Id = 'UPD-04'; Scopes = @('Updates'); Requires = @('UpdateGroups'); Run = { param($d, $t) Test-HygUpdateGroupSize -Data $d -Thresholds $t } }
        @{ Id = 'UPD-05'; Scopes = @('UpdateContent'); Requires = @('ExpiredUpdateIds','UpdateContentMap','UpdatePackageContent','UpdatePackages'); Run = { param($d) Test-HygUpdatePackageExpiredContent -Data $d } }
        @{ Id = 'DPT';    Scopes = @('DistributionPoints'); Requires = @('DistributionPoints','BoundaryGroupSiteSystems','DistributionPointGroups'); Run = { param($d) Test-HygDistributionPointChecks -Data $d } }
        @{ Id = 'CFG';    Scopes = @('Compliance'); Requires = @('Baselines','ConfigurationItems','ClientSettings'); Run = { param($d) Test-HygComplianceChecks -Data $d } }
        @{ Id = 'DRV-01'; Scopes = @('Drivers'); Requires = @('Drivers','DriverContainerIds'); Run = { param($d) Test-HygDriverUnpackaged -Data $d } }
        @{ Id = 'SEC-01'; Scopes = @('Security'); Requires = @('AdminUsers'); Run = { param($d) Test-HygAdminDeletedAccount -Data $d } }
        @{ Id = 'COL-10'; Scopes = @('MaintenanceWindows'); Requires = @('MaintenanceWindows','CollectionsWithSettings','Collections'); Run = { param($d) Test-HygMaintenanceWindowExpired -Data $d } }
        @{ Id = 'MNT';    Scopes = @('Site'); Requires = @('MaintenanceTasks'); Run = { param($d) Test-HygMaintenanceTasks -Data $d } }
        # $args-based: these only consume the third runner argument.
        @{ Id = 'SUP/DEP/REL'; Scopes = @('AppRelationships'); Requires = @(); NeedsRelationships = $true; Run = { Test-HygRelationshipChecks -RelationshipData $args[2] } }
        @{ Id = 'APP-04';      Scopes = @('AppRelationships'); Requires = @(); NeedsRelationships = $true; Run = { Test-HygAppContentPath -RelationshipData $args[2] } }
        @{ Id = 'APP-07/08 TSQ-05/06'; Scopes = @('AppRelationships'); Requires = @('Applications','Deployments','TaskSequences'); NeedsRelationships = $true; Run = { Test-HygRetiredSupersededChecks -Data $args[0] -RelationshipData $args[2] } }
    )
}

function Resolve-HygScanScope {
    param([string[]]$Scopes)
    $all = @(Get-HygieneScanScope | ForEach-Object { $_.Id })
    $picked = @($Scopes | Where-Object { $_ })
    if ($picked.Count -eq 0) { return $all }
    $unknown = @($picked | Where-Object { $_ -notin $all })
    if ($unknown.Count -gt 0) { throw ("Unknown scan scope(s): {0}. Valid: {1}" -f ($unknown -join ', '), ($all -join ', ')) }
    return $picked
}

function Get-HygieneRequiredDataset {
    <#
    .SYNOPSIS
        Maps scan scopes to the dataset keys Get-HygieneData must collect.
        'Relationships' in the result means Get-HygieneRelationshipData is
        needed; it is not a Get-HygieneData key.
    #>
    param([string[]]$Scopes)

    $picked = @(Resolve-HygScanScope -Scopes $Scopes)
    $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($check in (Get-HygScanPlan)) {
        if (-not @($check.Scopes | Where-Object { $_ -in $picked })) { continue }
        foreach ($k in @($check.Requires)) { [void]$keys.Add($k) }
        if ($check.NeedsRelationships) { [void]$keys.Add('Relationships') }
    }
    if ('CollectionSchedules' -in $picked) { [void]$keys.Add('CollectionDetails') }
    return @($keys | Sort-Object)
}

function Get-HygieneData {
    <#
    .SYNOPSIS
        Queries the datasets the selected checks need, one query per dataset.

    .DESCRIPTION
        Each dataset degrades to an empty set on failure with a note in
        DatasetNotes so one missing class or right never kills the whole
        scan. Requires an established CM connection (Connect-CMSite).
        Every read goes through that connection, so the account needs a
        Configuration Manager role only: a direct WMI connection to the
        provider also needs remote WMI rights on the server, which a
        read-only analyst typically lacks.

        Collections and application deployments are read with
        column-restricted WQL and the Fast option: the matching Get-CM*
        cmdlets issue one extra provider round-trip per object to fill
        lazy properties, which scales with object count. Every read runs
        one after the other on the calling thread; nothing here runs in
        parallel. The per-object reads left are CollectionDetails (only
        collections with a full-update schedule), MaintenanceWindows (only
        collections that have settings), and TsAppDefinitions when no
        AutoInstallByModel map covers a referenced application.

    .PARAMETER Datasets
        Dataset keys to collect (see Get-HygieneRequiredDataset). Omitted
        or empty collects everything. Keys not collected are listed in
        NotCollectedDatasets so the scan runner never reads their empty
        arrays as evidence.

    .PARAMETER ProgressState
        Optional synchronized hashtable; Step receives the current dataset.

    .PARAMETER PacingMs
        Pause, in milliseconds, before every provider call after the
        first: between datasets and between the objects of a per-object
        dataset. Zero sends calls back to back.

    .PARAMETER AutoInstallByModel
        ModelName to AutoInstall map from Get-HygieneRelationshipData.
        A referenced application present in the map costs no provider
        read; one absent from it, or every one when the map is not
        supplied, is read individually.
    #>
    param(
        [string[]]$Datasets,
        [hashtable]$ProgressState,
        [ValidateRange(0, 60000)][int]$PacingMs = 0,
        [hashtable]$AutoInstallByModel
    )

    $notes = New-Object System.Collections.Generic.List[string]
    # Dataset keys whose collection query failed; the scan runner skips
    # checks whose inputs are on this list instead of treating an empty
    # array as evidence.
    $failed = New-Object System.Collections.Generic.List[string]
    $notCollected = New-Object System.Collections.Generic.List[string]

    $result = [ordered]@{}
    # Set once a provider call has been made; the pause runs before every
    # later call, never before the first.
    $paceState = @{ Called = $false }
    $pace = {
        if ($paceState.Called -and $PacingMs -gt 0) { Start-Sleep -Milliseconds $PacingMs }
        $paceState.Called = $true
    }

    # Ordered: Collections reads CollectionDependencies for include/exclude
    # ids, and CollectionDetails mutates the rows Collections produced.
    $collectors = [ordered]@{
        Applications = @{ Label = 'applications'; Run = {
            Get-CMApplication -Fast -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{
                    CI_ID         = [int]$_.CI_ID
                    ModelName     = [string]$_.ModelName
                    Name          = [string]$_.LocalizedDisplayName
                    IsDeployed    = [bool]$_.IsDeployed
                    IsExpired     = [bool]$_.IsExpired
                    IsSuperseded  = [bool]$_.IsSuperseded
                    IsSuperseding = [bool]$_.IsSuperseding
                    PackageID     = [string]$_.PackageID
                    DateCreated   = $_.DateCreated
                    # The number of task sequences that name the application. The reference rows leave out a retired application,
                    # so this count is the only sign in this read that a task sequence still installs one.
                    NumberOfDependentTS = $(if ($_.PSObject.Properties['NumberOfDependentTS']) { [int]$_.NumberOfDependentTS } else { 0 })
                }
            }
        } }
        # SMS_Application holds every revision; SMS_ApplicationLatest and
        # Get-CMApplication return the current one only.
        AppRevisions = @{ Label = 'old application revisions'; FailureHint = 'APP-05 is skipped'; Run = {
            Invoke-CMWmiQuery -Query 'SELECT CI_ID, ModelName, CIVersion FROM SMS_Application WHERE IsLatest = 0' -Option Fast -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ CI_ID = [int]$_.CI_ID; ModelName = [string]$_.ModelName; Revision = [int]$_.CIVersion }
            }
        } }
        Packages = @{ Label = 'packages'; Run = {
            Get-CMPackage -Fast -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ PackageID = [string]$_.PackageID; Name = [string]$_.Name }
            }
        } }
        Programs = @{ Label = 'programs'; Run = {
            Get-CMProgram -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ PackageID = [string]$_.PackageID; ProgramName = [string]$_.ProgramName; ProgramFlags = [long]$_.ProgramFlags }
            }
        } }
        TaskSequences = @{ Label = 'task sequences'; Run = {
            # References is a lazy property: one provider read per task
            # sequence. This class returns every reference in one query.
            # ObjectID holds the package id, or the model name for an
            # application, the same values References.Package holds.
            # RefPackageID is not used: for an application it is the
            # content package id, which no other dataset carries, and
            # TSQ-01 would report it as deleted content. A failure here
            # fails the whole dataset, because a task sequence with an
            # empty reference list makes packages read as unreferenced.
            $refsByTs = @{}
            Invoke-CMWmiQuery -Query 'SELECT PackageID, ObjectID FROM SMS_TaskSequencePackageReference_All' -Option Fast -ErrorAction Stop | ForEach-Object {
                $tsId = [string]$_.PackageID
                $refsByTs[$tsId] = @($refsByTs[$tsId]) + [string]$_.ObjectID
            }
            $returned = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            $built = New-Object System.Collections.Generic.List[object]
            Get-CMTaskSequence -Fast -ErrorAction Stop | ForEach-Object {
                [void]$returned.Add([string]$_.PackageID)
                $refs = @($refsByTs[[string]$_.PackageID] | Where-Object { $_ })
                $bootImage = ''
                $p = $_.PSObject.Properties['BootImageID']
                if ($p) { $bootImage = [string]$p.Value }
                $flags = 0
                $p = $_.PSObject.Properties['ProgramFlags']
                if ($p -and $null -ne $p.Value) { $flags = [long]$p.Value }
                $built.Add([pscustomobject]@{ PackageID = [string]$_.PackageID; Name = [string]$_.Name; ReferencedIDs = $refs; BootImageID = $bootImage; ProgramFlags = $flags; IsStale = $false })
            }
            # The reference rows leave out a retired application. When a retired or superseded application has a task sequence
            # that names it (NumberOfDependentTS above zero) and no row shows it, the References property of each task
            # sequence is read once (one provider read per task sequence) to name the task sequences. Without such an
            # application, no read is added.
            $missing = @($result['Applications'] | Where-Object { ($_.IsExpired -or $_.IsSuperseded) -and [int]$_.NumberOfDependentTS -gt 0 })
            $rowModels = @($built | ForEach-Object { $_.ReferencedIDs })
            if (@($missing | Where-Object { $rowModels -notcontains [string]$_.ModelName }).Count -gt 0) {
                $i = 0
                foreach ($tsEntry in $built) {
                    $i++
                    if ($ProgressState) { $ProgressState.Step = "Reading task sequence steps ($i of $($built.Count))..." }
                    & $pace
                    $full = Get-CMTaskSequence -TaskSequencePackageId $tsEntry.PackageID -ErrorAction SilentlyContinue | Select-Object -First 1
                    if (-not $full) { continue }
                    $extra = @($full.References | ForEach-Object { [string]$_.Package } | Where-Object { $_ -and ($tsEntry.ReferencedIDs -notcontains $_) })
                    if ($extra.Count -gt 0) { $tsEntry.ReferencedIDs = @($tsEntry.ReferencedIDs) + $extra }
                }
            }
            $built
            # A task sequence that has reference rows in the same query and is not returned by Get-CMTaskSequence: a stale
            # reference row (the task sequence was deleted) or a task sequence outside the scope of the account. The rows come
            # from the one query above; no query is added. The checks that read references leave these entries out.
            foreach ($tsId in @($refsByTs.Keys | Where-Object { -not $returned.Contains([string]$_) } | Sort-Object)) {
                [pscustomobject]@{ PackageID = [string]$tsId; Name = ''; ReferencedIDs = @($refsByTs[$tsId] | Where-Object { $_ }); BootImageID = ''; ProgramFlags = 0; IsStale = $true }
            }
        } }
        # The task sequence install setting exists only in the application
        # definition XML, a lazy property. The relationship pass already
        # holds every application's XML when its scope is selected, so its
        # map answers first; a model outside the map costs one provider
        # read.
        TsAppDefinitions = @{ Label = 'task sequence application definitions'; FailureHint = 'TSQ-03 and TSQ-04 are skipped'; Run = {
            $models = @($result['TaskSequences'] | ForEach-Object { $_.ReferencedIDs } | Where-Object { $_ -like '*/Application_*' } | Sort-Object -Unique)
            $i = 0
            $fromMap = 0
            foreach ($model in $models) {
                $i++
                if ($AutoInstallByModel -and $AutoInstallByModel.ContainsKey([string]$model)) {
                    $fromMap++
                    [pscustomobject]@{ ModelName = [string]$model; AutoInstall = [bool]$AutoInstallByModel[[string]$model] }
                    continue
                }
                if ($ProgressState) { $ProgressState.Step = "Reading task sequence applications ($i of $($models.Count))..." }
                & $pace
                $app = Get-CMApplication -ModelName $model -ErrorAction Stop | Select-Object -First 1
                if (-not $app) { continue }
                $auto = $false
                [xml]$xml = [string]$app.SDMPackageXML
                $nsm = [System.Xml.XmlNamespaceManager]::new($xml.NameTable)
                $nsm.AddNamespace('d', 'http://schemas.microsoft.com/SystemCenterConfigurationManager/2009/AppMgmtDigest')
                $node = $xml.SelectSingleNode('/d:AppMgmtDigest/d:Application/d:AutoInstall', $nsm)
                if ($node) { $auto = ([string]$node.InnerText).Trim() -eq 'true' }
                [pscustomobject]@{ ModelName = [string]$model; AutoInstall = $auto }
            }
            if ($fromMap -gt 0) { Write-Log ("Task sequence application definitions: {0} of {1} answered from the relationship pass" -f $fromMap, $models.Count) }
        } }
        Devices = @{ Label = 'devices'; Run = {
            # The All Systems member class is what Get-CMDevice reads, so the
            # rows and the role-based scoping are the same. The class has
            # over 100 columns; the checks read six.
            Invoke-CMWmiQuery -Query 'SELECT ResourceID, Name, IsClient, ClientVersion, LastActiveTime, SMBIOSGUID FROM SMS_CM_RES_COLL_SMS00001' -Option Fast -ErrorAction Stop | ForEach-Object {
                $smbios = ''
                $p = $_.PSObject.Properties['SMBIOSGUID']
                if ($p) { $smbios = [string]$p.Value }
                $lastActive = $null
                $p = $_.PSObject.Properties['LastActiveTime']
                if ($p) { $lastActive = $p.Value }
                [pscustomobject]@{
                    ResourceID     = [int]$_.ResourceID
                    Name           = [string]$_.Name
                    IsClient       = [bool]$_.IsClient
                    ClientVersion  = [string]$_.ClientVersion
                    LastActiveTime = $lastActive
                    SMBIOSGUID     = $smbios
                }
            }
        } }
        Boundaries = @{ Label = 'boundaries'; Run = {
            Get-CMBoundary -ErrorAction Stop | ForEach-Object {
                # -1 sentinel: GroupCount is a provider-computed count that may
                # be absent; [int]$null would read as 0 and BND-01 would flag
                # every boundary in the site.
                $groupCount = -1
                $p = $_.PSObject.Properties['GroupCount']
                if ($p -and $null -ne $p.Value) { $groupCount = [int]$p.Value }
                [pscustomobject]@{
                    DisplayName  = [string]$_.DisplayName
                    Value        = [string]$_.Value
                    BoundaryType = [int]$_.BoundaryType
                    GroupCount   = $groupCount
                }
            }
        } }
        BoundaryGroups = @{ Label = 'boundary groups'; Run = {
            Get-CMBoundaryGroup -ErrorAction Stop | ForEach-Object {
                $ssCount = -1
                $p = $_.PSObject.Properties['SiteSystemCount']
                if ($p) { $ssCount = [int]$p.Value }
                [pscustomobject]@{ GroupID = [int]$_.GroupID; Name = [string]$_.Name; SiteSystemCount = $ssCount }
            }
        } }
        BootImages = @{ Label = 'boot images'; Run = {
            Get-CMBootImage -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ PackageID = [string]$_.PackageID; Name = [string]$_.Name }
            }
        } }
        OSImages = @{ Label = 'OS images'; Run = {
            Get-CMOperatingSystemImage -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ PackageID = [string]$_.PackageID; Name = [string]$_.Name }
            }
        } }
        OSUpgradePackages = @{ Label = 'OS upgrade packages'; Run = {
            Get-CMOperatingSystemInstaller -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ PackageID = [string]$_.PackageID; Name = [string]$_.Name }
            }
        } }
        DriverPackages = @{ Label = 'driver packages'; Run = {
            Get-CMDriverPackage -Fast -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ PackageID = [string]$_.PackageID; Name = [string]$_.Name }
            }
        } }
        UpdateGroups = @{ Label = 'software update groups'; Run = {
            Get-CMSoftwareUpdateGroup -ErrorAction Stop | ForEach-Object {
                $n = 0; $e = 0; $sup = $false
                $p = $_.PSObject.Properties['NumberOfUpdates'];           if ($p) { $n = [int]$p.Value }
                $p = $_.PSObject.Properties['NumberOfExpiredUpdates'];    if ($p) { $e = [int]$p.Value }
                $sup = [bool]$_.ContainsSupersededUpdates
                [pscustomobject]@{ Name = [string]$_.LocalizedDisplayName; CI_ID = [int]$_.CI_ID; NumberOfUpdates = $n; NumberOfExpiredUpdates = $e; ContainsSupersededUpdates = $sup }
            }
        } }
        UpdatePackages = @{ Label = 'update deployment packages'; Run = {
            Get-CMSoftwareUpdateDeploymentPackage -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ PackageID = [string]$_.PackageID; Name = [string]$_.Name }
            }
        } }
        AutoDeploymentRules = @{ Label = 'automatic deployment rules'; Run = {
            Get-CMAutoDeploymentRule -Fast -ErrorAction Stop | ForEach-Object {
                $lastRun = $null; $lastError = 0; $enabled = $true
                $p = $_.PSObject.Properties['LastRunTime'];           if ($p) { $lastRun = $p.Value }
                $p = $_.PSObject.Properties['LastErrorCode'];         if ($p) { $lastError = [int]$p.Value }
                $p = $_.PSObject.Properties['AutoDeploymentEnabled']; if ($p) { $enabled = [bool]$p.Value }
                [pscustomobject]@{ Name = [string]$_.Name; AutoDeploymentEnabled = $enabled; LastRunTime = $lastRun; LastErrorCode = $lastError }
            }
        } }
        MaintenanceTasks = @{ Label = 'site maintenance tasks'; Run = {
            Get-CMSiteMaintenanceTask -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ TaskName = [string]$_.TaskName; Enabled = [bool]$_.Enabled }
            }
        } }
        # Collections that carry variables/settings live in
        # SMS_CollectionSettings; one query beats N per-collection cmdlet
        # round-trips.
        CollectionsWithSettings = @{ Label = 'collection-settings rows'; FailureHint = 'COL-01 cannot rule out variables'; Run = {
            Invoke-CMWmiQuery -Query 'SELECT CollectionID FROM SMS_CollectionSettings' -Option Fast -ErrorAction Stop |
            ForEach-Object { [string]$_.CollectionID }
        } }
        DependencyTargetCIIDs = @{ Label = 'dependency relations'; FailureHint = 'APP-01 may over-report dependency-only applications'; Run = {
            Invoke-CMWmiQuery -Query 'SELECT ToApplicationCIID FROM SMS_AppDependenceRelation' -Option Fast -ErrorAction Stop |
            ForEach-Object { [int]$_.ToApplicationCIID }
        } }
        # SMS_CollectionDependencies is authoritative for every reference
        # edge. RelationshipType: 1 = limiting, 2 = include, 3 = exclude;
        # Dependent references Source.
        CollectionDependencies = @{ Label = 'collection reference edges'; FailureHint = 'COL-01 and COL-05..COL-09 are skipped'; Run = {
            Invoke-CMWmiQuery -Query 'SELECT DependentCollectionID, SourceCollectionID, RelationshipType FROM SMS_CollectionDependencies' -Option Fast -ErrorAction Stop |
            ForEach-Object {
                # Inside the switch, $_ is the switch value, so the type is read into a variable first.
                $relType = [int]$_.RelationshipType
                [pscustomobject]@{
                    From = [string]$_.DependentCollectionID
                    To   = [string]$_.SourceCollectionID
                    Kind = switch ($relType) { 1 { 'limit' } 2 { 'include' } 3 { 'exclude' } default { "type$relType" } }
                }
            }
        } }
        Collections = @{ Label = 'collections'; Run = {
            $includes = @{}; $excludes = @{}
            foreach ($e in @($result['CollectionDependencies'])) {
                if ($e.Kind -eq 'include')     { $includes[$e.From] = @($includes[$e.From]) + $e.To }
                elseif ($e.Kind -eq 'exclude') { $excludes[$e.From] = @($excludes[$e.From]) + $e.To }
            }
            # CollectionRules and RefreshSchedule are lazy; selecting only
            # the plain columns keeps this to one provider query.
            Invoke-CMWmiQuery -Query 'SELECT CollectionID, Name, MemberCount, RefreshType, LimitToCollectionID FROM SMS_Collection' -Option Fast -ErrorAction Stop | ForEach-Object {
                $id = [string]$_.CollectionID
                [pscustomobject]@{
                    CollectionID        = $id
                    Name                = [string]$_.Name
                    MemberCount         = [int]$_.MemberCount
                    RefreshType         = [int]$_.RefreshType
                    LimitToCollectionID = [string]$_.LimitToCollectionID
                    IsBuiltIn           = ($id -like 'SMS*')
                    IncludeIDs          = @($includes[$id] | Where-Object { $_ })
                    ExcludeIDs          = @($excludes[$id] | Where-Object { $_ })
                    DirectRuleCount     = 0
                    QueryRuleCount      = 0
                    FullDaySpan         = 0
                    FullHourSpan        = 0
                    FullMinuteSpan      = 0
                    FullStartHour       = -1
                }
            }
        } }
        # Rule counts and the full-update schedule are lazy properties: one
        # provider read per collection. Limited to collections that have a
        # full-update schedule, the only ones COL-05/06/09 can flag.
        CollectionDetails = @{ Label = 'collection schedule details'; FailureHint = 'COL-05, COL-06, and COL-09 report nothing this scan'; Run = {
            $targets = @($result['Collections'] | Where-Object { -not $_.IsBuiltIn -and $_.RefreshType -in 2, 6 })
            $i = 0
            $skipped = 0
            $firstSkip = ''
            foreach ($c in $targets) {
                $i++
                if ($ProgressState) { $ProgressState.Step = "Reading collection schedules ($i of $($targets.Count))..." }
                & $pace
                # One collection that cannot be read (after the retry of transient faults) skips only itself.
                $collectionId = $c.CollectionID
                $full = $null
                try { $full = Invoke-SuiteCMRead -Description "Collection $collectionId" -ScriptBlock { Get-CMCollection -Id $collectionId -ErrorAction Stop } }
                catch {
                    $skipped++
                    if (-not $firstSkip) { $firstSkip = '{0}: {1}' -f $collectionId, $_.Exception.Message }
                    continue
                }
                if (-not $full) { continue }
                foreach ($rule in @($full.CollectionRules)) {
                    if (-not $rule) { continue }
                    # Embedded rule objects frequently carry an empty
                    # SmsProviderObjectPath; the .NET type name is the
                    # reliable discriminator.
                    $typeName = $null
                    try { $typeName = [string]$rule.SmsProviderObjectPath } catch { $typeName = $null }
                    if (-not $typeName) { try { $typeName = $rule.GetType().Name } catch { continue } }
                    if ($typeName -match 'Direct') { $c.DirectRuleCount++ }
                    elseif ($typeName -match 'Query') { $c.QueryRuleCount++ }
                }
                # RefreshSchedule is an embedded SMS_ST_RecurInterval; spans of
                # zero with no start time mean "no full schedule recorded".
                try {
                    $sched = @($full.RefreshSchedule)[0]
                    if ($sched) {
                        if ($sched.PSObject.Properties['DaySpan'])    { $c.FullDaySpan    = [int]$sched.DaySpan }
                        if ($sched.PSObject.Properties['HourSpan'])   { $c.FullHourSpan   = [int]$sched.HourSpan }
                        if ($sched.PSObject.Properties['MinuteSpan']) { $c.FullMinuteSpan = [int]$sched.MinuteSpan }
                        if ($sched.PSObject.Properties['StartTime'] -and $sched.StartTime) { $c.FullStartHour = ([datetime]$sched.StartTime).Hour }
                    }
                } catch { $null = $_ }
                $c.CollectionID
            }
            if ($skipped -gt 0) { $notes.Add("collection schedule details: $skipped of $($targets.Count) collections could not be read and were skipped (first: $firstSkip)") }
        } }
        Deployments = @{ Label = 'deployment summaries'; Run = {
            Get-CMDeployment -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{
                    SoftwareName        = [string]$_.SoftwareName
                    ProgramName         = [string]$_.ProgramName
                    PackageID           = [string]$_.PackageID
                    CollectionID        = [string]$_.CollectionID
                    CollectionName      = [string]$_.CollectionName
                    DeploymentIntent    = [int]$_.DeploymentIntent
                    FeatureType         = [int]$_.FeatureType
                    NumberTargeted      = [int]$_.NumberTargeted
                    NumberSuccess       = [int]$_.NumberSuccess
                    NumberInProgress    = [int]$_.NumberInProgress
                    NumberErrors        = [int]$_.NumberErrors
                    EnforcementDeadline = $_.EnforcementDeadline
                    CreationTime        = $_.CreationTime
                }
            }
        } }
        # Last-run evaluation timings, present on site version 2010 and
        # later. Kept out of the Collections query so an older site loses
        # only COL-04, not every collection check.
        CollectionEvalFull = @{ Label = 'full evaluation timings'; FailureHint = 'COL-04 is skipped; the class needs site version 2010 or later'; Run = {
            Invoke-CMWmiQuery -Query 'SELECT CollectionID, CollectionName, Length, MemberChanges FROM SMS_CollectionEvaluationFull' -Option Fast -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ CollectionID = [string]$_.CollectionID; Name = [string]$_.CollectionName; LengthMs = [long]$_.Length; MemberChanges = [long]$_.MemberChanges }
            }
        } }
        CollectionEvalIncremental = @{ Label = 'incremental evaluation timings'; FailureHint = 'COL-04 is skipped; the class needs site version 2010 or later'; Run = {
            Invoke-CMWmiQuery -Query 'SELECT CollectionID, CollectionName, Length, MemberChanges FROM SMS_CollectionEvaluationIncremental' -Option Fast -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ CollectionID = [string]$_.CollectionID; Name = [string]$_.CollectionName; LengthMs = [long]$_.Length; MemberChanges = [long]$_.MemberChanges }
            }
        } }
        # One row per content object with per-state distribution point
        # counts; the per-package-per-DP status classes grow as content
        # times distribution points.
        ContentStatus = @{ Label = 'content status rows'; Run = {
            Invoke-CMWmiQuery -Query 'SELECT ObjectID, PackageID, SoftwareName, ObjectType, Targeted, NumberSuccess, NumberInProgress, NumberErrors, NumberUnknown, SourceSize, LastUpdateDate FROM SMS_ObjectContentInfo' -Option Fast -ErrorAction Stop | ForEach-Object {
                $updated = $null
                $p = $_.PSObject.Properties['LastUpdateDate']
                if ($p) { $updated = $p.Value }
                [pscustomobject]@{
                    ObjectID         = [string]$_.ObjectID
                    PackageID        = [string]$_.PackageID
                    Name             = [string]$_.SoftwareName
                    ObjectType       = [int]$_.ObjectType
                    Targeted         = [int]$_.Targeted
                    NumberSuccess    = [int]$_.NumberSuccess
                    NumberInProgress = [int]$_.NumberInProgress
                    NumberErrors     = [int]$_.NumberErrors
                    NumberUnknown    = [int]$_.NumberUnknown
                    SourceSize       = [long]$_.SourceSize
                    LastUpdateDate   = $updated
                }
            }
        } }
        DistributionPoints = @{ Label = 'distribution points'; Run = {
            Invoke-CMWmiQuery -Query 'SELECT NALPath, Name FROM SMS_DistributionPointInfo' -Option Fast -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ NALPath = [string]$_.NALPath; Name = ([string]$_.Name).TrimStart('\') }
            }
        } }
        BoundaryGroupSiteSystems = @{ Label = 'boundary group site systems'; Run = {
            Invoke-CMWmiQuery -Query 'SELECT ServerNALPath FROM SMS_BoundaryGroupSiteSystems' -Option Fast -ErrorAction Stop |
            ForEach-Object { [string]$_.ServerNALPath }
        } }
        DistributionPointGroups = @{ Label = 'distribution point groups'; Run = {
            Invoke-CMWmiQuery -Query 'SELECT GroupID, Name, MembersCount, AssignedContentCount FROM SMS_DPGroupInfo' -Option Fast -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ GroupID = [string]$_.GroupID; Name = [string]$_.Name; MembersCount = [int]$_.MembersCount; AssignedContentCount = [int]$_.AssignedContentCount }
            }
        } }
        Baselines = @{ Label = 'configuration baselines'; Run = {
            Invoke-CMWmiQuery -Query 'SELECT CI_ID, ModelName, LocalizedDisplayName, IsAssigned, InUse, IsUserDefined FROM SMS_ConfigurationBaselineInfo' -Option Fast -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ CI_ID = [int]$_.CI_ID; ModelName = [string]$_.ModelName; Name = [string]$_.LocalizedDisplayName; IsAssigned = [bool]$_.IsAssigned; InUse = [bool]$_.InUse; IsUserDefined = [bool]$_.IsUserDefined }
            }
        } }
        ConfigurationItems = @{ Label = 'configuration items'; Run = {
            Get-CMConfigurationItem -Fast -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ CI_ID = [int]$_.CI_ID; ModelName = [string]$_.ModelName; Name = [string]$_.LocalizedDisplayName; InUse = [bool]$_.InUse; IsUserDefined = [bool]$_.IsUserDefined }
            }
        } }
        ClientSettings = @{ Label = 'custom client settings'; Run = {
            Invoke-CMWmiQuery -Query 'SELECT SettingsID, Name, AssignmentCount FROM SMS_ClientSettings' -Option Fast -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ SettingsID = [int]$_.SettingsID; Name = [string]$_.Name; AssignmentCount = [int]$_.AssignmentCount }
            }
        } }
        Drivers = @{ Label = 'drivers'; Run = {
            Invoke-CMWmiQuery -Query 'SELECT CI_ID, LocalizedDisplayName FROM SMS_Driver' -Option Fast -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ CI_ID = [int]$_.CI_ID; Name = [string]$_.LocalizedDisplayName }
            }
        } }
        DriverContainerIds = @{ Label = 'driver package memberships'; Run = {
            Invoke-CMWmiQuery -Query 'SELECT CI_ID FROM SMS_DriverContainer' -Option Fast -ErrorAction Stop |
            ForEach-Object { [int]$_.CI_ID }
        } }
        AdminUsers = @{ Label = 'administrative users'; Run = {
            Invoke-CMWmiQuery -Query 'SELECT AdminID, LogonName, IsDeleted, RoleNames FROM SMS_Admin' -Option Fast -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ AdminID = [int]$_.AdminID; LogonName = [string]$_.LogonName; IsDeleted = [bool]$_.IsDeleted; RoleNames = @($_.RoleNames | Where-Object { $_ } | ForEach-Object { [string]$_ }) }
            }
        } }
        ExpiredUpdateIds = @{ Label = 'expired updates'; Run = {
            Invoke-CMWmiQuery -Query 'SELECT CI_ID FROM SMS_SoftwareUpdate WHERE IsExpired = 1' -Option Fast -ErrorAction Stop |
            ForEach-Object { [int]$_.CI_ID }
        } }
        # ContentDownloaded limits the map to content that is in a package;
        # the unfiltered class has a row for every content item of every
        # synchronized update.
        UpdateContentMap = @{ Label = 'downloaded update content rows'; Run = {
            Invoke-CMWmiQuery -Query 'SELECT CI_ID, ContentID FROM SMS_CIToContent WHERE ContentDownloaded = 1' -Option Fast -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ CI_ID = [int]$_.CI_ID; ContentID = [int]$_.ContentID }
            }
        } }
        UpdatePackageContent = @{ Label = 'update package content rows'; Run = {
            Invoke-CMWmiQuery -Query 'SELECT PackageID, ContentID FROM SMS_PackageToContent WHERE PackageType = 5' -Option Fast -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ PackageID = [string]$_.PackageID; ContentID = [int]$_.ContentID }
            }
        } }
        # Maintenance windows are a lazy array on the collection settings:
        # one provider read per collection that has settings.
        MaintenanceWindows = @{ Label = 'maintenance windows'; FailureHint = 'COL-10 is skipped'; Run = {
            $targets = @($result['CollectionsWithSettings'])
            $i = 0
            $skipped = 0
            $firstSkip = ''
            foreach ($id in $targets) {
                $i++
                if ($ProgressState) { $ProgressState.Step = "Reading maintenance windows ($i of $($targets.Count))..." }
                & $pace
                # One collection that cannot be read (after the retry of transient faults) skips only itself.
                $windowRows = @()
                try { $windowRows = @(Invoke-SuiteCMRead -Description "Maintenance windows of $id" -ScriptBlock { Get-CMMaintenanceWindow -CollectionId $id -ErrorAction Stop }) }
                catch {
                    $skipped++
                    if (-not $firstSkip) { $firstSkip = '{0}: {1}' -f $id, $_.Exception.Message }
                    continue
                }
                $windowRows | ForEach-Object {
                    [pscustomobject]@{
                        CollectionID   = [string]$id
                        Name           = [string]$_.Name
                        RecurrenceType = [int]$_.RecurrenceType
                        StartTime      = $_.StartTime
                        Duration       = [int]$_.Duration
                        IsEnabled      = [bool]$_.IsEnabled
                    }
                }
            }
            if ($skipped -gt 0) { $notes.Add("maintenance windows: $skipped of $($targets.Count) collections could not be read and were skipped (first: $firstSkip); COL-10 may miss expired windows") }
        } }
        AppDeployments = @{ Label = 'application deployments'; Run = {
            Invoke-CMWmiQuery -Query 'SELECT ApplicationName, CollectionName, TargetCollectionID, ExpirationTime FROM SMS_ApplicationAssignment' -Option Fast -ErrorAction Stop | ForEach-Object {
                # A deployment without an expiration reads null.
                $expTime = $null
                $p = $_.PSObject.Properties['ExpirationTime']
                if ($p) { $expTime = $p.Value }
                [pscustomobject]@{
                    ApplicationName    = [string]$_.ApplicationName
                    CollectionName     = [string]$_.CollectionName
                    TargetCollectionID = [string]$_.TargetCollectionID
                    ExpirationTime     = $expTime
                }
            }
        } }
    }

    $wanted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($k in @($Datasets | Where-Object { $_ })) { [void]$wanted.Add($k) }
    if ($wanted.Count -eq 0) { foreach ($k in $collectors.Keys) { [void]$wanted.Add($k) } }
    if ($wanted.Contains('MaintenanceWindows')) { [void]$wanted.Add('CollectionsWithSettings') }
    if ($wanted.Contains('TsAppDefinitions')) { [void]$wanted.Add('TaskSequences') }
    if ($wanted.Contains('CollectionDetails')) { [void]$wanted.Add('Collections') }
    if ($wanted.Contains('Collections')) { [void]$wanted.Add('CollectionDependencies') }

    $total = @($collectors.Keys | Where-Object { $wanted.Contains($_) }).Count
    $index = 0
    foreach ($key in @($collectors.Keys)) {
        $result[$key] = @()
        if (-not $wanted.Contains($key)) { $notCollected.Add($key); continue }
        $collector = $collectors[$key]
        $index++
        if ($ProgressState) { $ProgressState.Step = "Collecting $($collector.Label) ($index of $total)..." }
        $hint = $(if ($collector.FailureHint) { " ($($collector.FailureHint))" } else { '' })
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            & $pace
            $result[$key] = @(& $collector.Run)
            Write-Log ("Loaded {0} {1} in {2:n1}s" -f @($result[$key]).Count, $collector.Label, $sw.Elapsed.TotalSeconds)
        }
        catch {
            $result[$key] = @()
            $failed.Add($key)
            $notes.Add("$($collector.Label) unavailable${hint}: $($_.Exception.Message)")
            Write-Log "$($collector.Label) unavailable after $([int]$sw.Elapsed.TotalSeconds)s: $($_.Exception.Message)" -Level WARN -Quiet
            Write-Log "$($collector.Label) is unavailable. The log file has the details." -Level WARN
        }
    }

    $result['DatasetNotes']         = $notes.ToArray()
    $result['FailedDatasets']       = $failed.ToArray()
    $result['NotCollectedDatasets'] = $notCollected.ToArray()
    $result['CollectedAt']          = Get-Date
    return [pscustomobject]$result
}

# ---------------------------------------------------------------------------
# Checks: Applications
# ---------------------------------------------------------------------------

function Test-HygAppNoReferences {
    <#
    .SYNOPSIS
        APP-01: applications with no deployments, no task sequence
        references, no supersedence role, and no dependency targeting.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Named for the reference-absence condition it tests.')]
    param(
        [Parameter(Mandatory)]$Data,
        [hashtable]$Thresholds = (Get-HygieneDefaultThresholds)
    )

    $tsRefs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($ts in @(Get-HygLiveTaskSequence -Data $Data)) {
        foreach ($r in @($ts.ReferencedIDs)) { [void]$tsRefs.Add([string]$r) }
    }
    $depTargets = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($id in @($Data.DependencyTargetCIIDs)) { [void]$depTargets.Add([int]$id) }

    $minAge = [int]$Thresholds.AppUnusedMinAgeDays
    $cutoff = (Get-Date).AddDays(-$minAge)

    foreach ($app in @($Data.Applications)) {
        if ($app.IsDeployed -or $app.IsSuperseding -or $app.IsSuperseded) { continue }
        if ($depTargets.Contains([int]$app.CI_ID)) { continue }
        if ($app.PackageID -and $tsRefs.Contains([string]$app.PackageID)) { continue }
        if ($app.ModelName -and $tsRefs.Contains([string]$app.ModelName)) { continue }
        if ($app.DateCreated -and $app.DateCreated -gt $cutoff) { continue }

        New-HygieneFinding -CheckId 'APP-01' -Severity Warning -Category 'Applications' `
            -ObjectType 'Application' -ObjectId ([string]$app.ModelName) -ObjectName $app.Name `
            -Evidence ("No deployments, no task sequence references, not part of any supersedence relationship, not a dependency target; created {0}, older than the {1}-day grace window." -f $app.DateCreated, $minAge) `
            -Recommendation 'Candidate for retirement and removal. Verify no out-of-band use (scripts, documentation) before deleting.' `
            -FixScript ("Remove-CMApplication -Name '{0}' -DisableWildcardHandling -Force" -f (ConvertTo-HygQuotedLiteral $app.Name))
    }
}

function Test-HygAppRetiredDeployed {
    <#
    .SYNOPSIS
        APP-02: retired (expired) applications that still have deployments.
    #>
    param([Parameter(Mandatory)]$Data)

    foreach ($app in @($Data.Applications)) {
        if (-not ($app.IsExpired -and $app.IsDeployed)) { continue }

        New-HygieneFinding -CheckId 'APP-02' -Severity Error -Category 'Applications' `
            -ObjectType 'Application' -ObjectId ([string]$app.ModelName) -ObjectName $app.Name `
            -Evidence 'Application is retired (expired) but still has active deployments; clients targeted by them cannot install it.' `
            -Recommendation 'Remove the deployments, or reinstate the application if retiring it was a mistake.' `
            -FixScript ("Get-CMApplicationDeployment -Name '{0}' -DisableWildcardHandling | Remove-CMApplicationDeployment -Force" -f (ConvertTo-HygQuotedLiteral $app.Name))
    }
}

function Test-HygAppSupersededDeployed {
    <#
    .SYNOPSIS
        APP-03: superseded applications still deployed.
    #>
    param([Parameter(Mandatory)]$Data)

    foreach ($app in @($Data.Applications)) {
        if (-not ($app.IsSuperseded -and $app.IsDeployed)) { continue }
        if ($app.IsExpired) { continue }  # APP-02 already carries the louder finding

        New-HygieneFinding -CheckId 'APP-03' -Severity Warning -Category 'Applications' `
            -ObjectType 'Application' -ObjectId ([string]$app.ModelName) -ObjectName $app.Name `
            -Evidence 'Application is superseded by a newer application but its own deployments are still active.' `
            -Recommendation 'Deploy the superseding application and retire these deployments so clients converge on the replacement.' `
            -FixScript ("Get-CMApplicationDeployment -Name '{0}' -DisableWildcardHandling | Remove-CMApplicationDeployment -Force" -f (ConvertTo-HygQuotedLiteral $app.Name))
    }
}

# ---------------------------------------------------------------------------
# Checks: Packages
# ---------------------------------------------------------------------------

function Test-HygAppOldRevisions {
    <#
    .SYNOPSIS
        APP-05: applications that hold revisions other than the current
        one. One finding per application, so the suppression key does not
        change when the revision list grows.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Reports the full old-revision set of an application by design.')]
    param([Parameter(Mandatory)]$Data)

    $oldByModel = @{}
    foreach ($r in @($Data.AppRevisions)) {
        if (-not $r -or -not $r.ModelName) { continue }
        $oldByModel[[string]$r.ModelName] = @($oldByModel[[string]$r.ModelName]) + [int]$r.Revision
    }

    foreach ($app in @($Data.Applications)) {
        if (-not $app.ModelName) { continue }
        $old = @($oldByModel[[string]$app.ModelName] | Where-Object { $_ } | Sort-Object -Unique)
        if ($old.Count -eq 0) { continue }
        # The site refuses to delete a revision that another object still
        # references; Run Fix then reports that line as the failure.
        $lines = foreach ($rev in $old) { "Remove-CMApplicationRevisionHistory -Id {0} -Revision {1} -Force" -f $app.CI_ID, $rev }
        New-HygieneFinding -CheckId 'APP-05' -Severity Info -Category 'Applications' `
            -ObjectType 'Application' -ObjectId ([string]$app.ModelName) -ObjectName $app.Name `
            -Evidence ("The application holds {0} old revision(s): {1}. Clients use the current revision only. The site keeps the definition of each old revision." -f $old.Count, ($old -join ', ')) `
            -Recommendation 'Delete the old revisions. Keep one only if you plan to restore it.' `
            -FixScript ($lines -join "`r`n")
    }
}

function Test-HygPackageUnused {
    <#
    .SYNOPSIS
        PKG-01: legacy packages with no programs, no deployments, and no
        task sequence references.
    #>
    param([Parameter(Mandatory)]$Data)

    $withPrograms = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in @($Data.Programs)) { [void]$withPrograms.Add([string]$p.PackageID) }

    $deployed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($d in @($Data.Deployments)) { if ($d.PackageID) { [void]$deployed.Add([string]$d.PackageID) } }

    $tsRefs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($ts in @(Get-HygLiveTaskSequence -Data $Data)) {
        foreach ($r in @($ts.ReferencedIDs)) { [void]$tsRefs.Add([string]$r) }
    }

    foreach ($pkg in @($Data.Packages)) {
        # Default client packages ship without programs and would always
        # flag; they are site plumbing, not clutter.
        if ($pkg.Name -match '^Configuration Manager Client') { continue }
        $id = [string]$pkg.PackageID
        if ($withPrograms.Contains($id)) { continue }
        if ($deployed.Contains($id)) { continue }
        if ($tsRefs.Contains($id)) { continue }

        New-HygieneFinding -CheckId 'PKG-01' -Severity Warning -Category 'Packages' `
            -ObjectType 'Package' -ObjectId $id -ObjectName $pkg.Name `
            -Evidence 'Package has no programs, no deployments, and no task sequence references.' `
            -Recommendation 'Candidate for deletion; its content still occupies distribution points and the content library.' `
            -FixScript ("Remove-CMPackage -Id '{0}' -Force" -f (ConvertTo-HygQuotedLiteral $id))
    }
}

# ---------------------------------------------------------------------------
# Checks: Collections
# ---------------------------------------------------------------------------

function Test-HygCollectionEmptyUnused {
    <#
    .SYNOPSIS
        COL-01: empty collections that nothing references - no deployments,
        no include/exclude rule from another collection, not anyone's
        limiting collection, no collection variables/settings.
    #>
    param([Parameter(Mandatory)]$Data)

    $deploymentTargets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($d in @($Data.Deployments)) { if ($d.CollectionID) { [void]$deploymentTargets.Add([string]$d.CollectionID) } }

    $referenced = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($c in @($Data.Collections)) {
        foreach ($id in @($c.IncludeIDs)) { [void]$referenced.Add([string]$id) }
        foreach ($id in @($c.ExcludeIDs)) { [void]$referenced.Add([string]$id) }
        if ($c.LimitToCollectionID) { [void]$referenced.Add([string]$c.LimitToCollectionID) }
    }
    if ($Data.PSObject.Properties['CollectionDependencies']) {
        foreach ($e in @($Data.CollectionDependencies)) { if ($e.To) { [void]$referenced.Add([string]$e.To) } }
    }

    $withSettings = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @($Data.CollectionsWithSettings)) { [void]$withSettings.Add([string]$id) }

    foreach ($c in @($Data.Collections)) {
        if ($c.IsBuiltIn) { continue }
        if ($c.MemberCount -ne 0) { continue }
        $id = [string]$c.CollectionID
        if ($deploymentTargets.Contains($id)) { continue }
        if ($referenced.Contains($id)) { continue }
        if ($withSettings.Contains($id)) { continue }

        New-HygieneFinding -CheckId 'COL-01' -Severity Info -Category 'Collections' `
            -ObjectType 'Collection' -ObjectId $id -ObjectName $c.Name `
            -Evidence 'Empty collection with no deployments, no include/exclude references from other collections, not used as a limiting collection, and no collection variables.' `
            -Recommendation 'Delete unless it is a staging container someone still fills by hand.' `
            -FixScript ("Remove-CMCollection -Id '{0}' -Force" -f (ConvertTo-HygQuotedLiteral $id))
    }
}

function Test-HygDeploymentEmptyCollection {
    <#
    .SYNOPSIS
        COL-02: deployments whose target collection has zero members.
    #>
    param([Parameter(Mandatory)]$Data)

    $emptyCollections = @{}
    foreach ($c in @($Data.Collections)) {
        if ($c.MemberCount -eq 0) { $emptyCollections[[string]$c.CollectionID] = $c }
    }

    foreach ($d in @($Data.Deployments)) {
        $cid = [string]$d.CollectionID
        if (-not $cid -or -not $emptyCollections.ContainsKey($cid)) { continue }

        New-HygieneFinding -CheckId 'COL-02' -Severity Warning -Category 'Collections' `
            -ObjectType 'Deployment' -ObjectId $cid -ObjectName ("{0} -> {1}" -f $d.SoftwareName, $d.CollectionName) `
            -Evidence ("Deployment targets collection '{0}' ({1}), which currently has zero members - it can never apply." -f $d.CollectionName, $cid) `
            -Recommendation 'Remove the deployment, or fix the collection membership if it emptied by accident.' `
            -FixScript ("# Review in console: deployment of '{0}' to collection '{1}'" -f $d.SoftwareName, $d.CollectionName)
    }
}

function Test-HygIncrementalCeiling {
    <#
    .SYNOPSIS
        COL-03: count of incremental-evaluation collections against the
        recommended ceiling. RefreshType 4 (Continuous) and 6 (Both)
        enroll a collection in incremental evaluation.
    #>
    param(
        [Parameter(Mandatory)]$Data,
        [hashtable]$Thresholds = (Get-HygieneDefaultThresholds)
    )

    $ceiling = [int]$Thresholds.IncrementalCeiling
    $incremental = @($Data.Collections | Where-Object { $_.RefreshType -in 4, 6 })
    if ($incremental.Count -le $ceiling) { return }

    $sample = @($incremental | Sort-Object Name | Select-Object -First 15 | ForEach-Object { $_.Name }) -join ', '

    New-HygieneFinding -CheckId 'COL-03' -Severity Warning -Category 'Collections' `
        -ObjectType 'Site' -ObjectId '' -ObjectName 'Incremental evaluation load' `
        -Evidence ("{0} collections use incremental evaluation; above the recommended ceiling of {1}, evaluation latency degrades site-wide. First 15 by name: {2}" -f $incremental.Count, $ceiling, $sample) `
        -Recommendation 'Switch rarely-changing collections to scheduled-only refresh until the count sits under the ceiling.' `
        -FixScript "# Per collection: Set-CMCollection -CollectionId <CollectionID> -RefreshType Periodic"
}

# ---------------------------------------------------------------------------
# Checks: Deployments
# ---------------------------------------------------------------------------

function Test-HygDeploymentExpired {
    <#
    .SYNOPSIS
        DPL-01: application deployments whose expiration time has passed.
    #>
    param([Parameter(Mandatory)]$Data)

    $now = Get-Date
    foreach ($d in @($Data.AppDeployments)) {
        # SMS_ApplicationAssignment exposes ExpirationTime only (no enable
        # flag); a deployment with no expiration reads null and is skipped.
        if (-not $d.ExpirationTime -or $d.ExpirationTime -ge $now) { continue }

        New-HygieneFinding -CheckId 'DPL-01' -Severity Info -Category 'Deployments' `
            -ObjectType 'Deployment' -ObjectId ([string]$d.TargetCollectionID) -ObjectName ("{0} -> {1}" -f $d.ApplicationName, $d.CollectionName) `
            -Evidence ("Deployment expired {0} and no longer offers to clients; it is clutter in every deployment view." -f $d.ExpirationTime) `
            -Recommendation 'Remove the expired deployment.' `
            -FixScript ("Get-CMApplicationDeployment -Name '{0}' -CollectionName '{1}' -DisableWildcardHandling | Remove-CMApplicationDeployment -Force" -f (ConvertTo-HygQuotedLiteral $d.ApplicationName), (ConvertTo-HygQuotedLiteral $d.CollectionName))
    }
}

function Test-HygDeploymentPastDeadlineFailures {
    <#
    .SYNOPSIS
        DPL-02: required deployments past their enforcement deadline with a
        failure rate over the threshold.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Named for the failure condition it tests.')]
    param(
        [Parameter(Mandatory)]$Data,
        [hashtable]$Thresholds = (Get-HygieneDefaultThresholds)
    )

    $grace = [int]$Thresholds.DeadlineGraceDays
    $pctThreshold = [int]$Thresholds.FailurePctThreshold
    $cutoff = (Get-Date).AddDays(-$grace)

    foreach ($d in @($Data.Deployments)) {
        if ($d.DeploymentIntent -ne 1) { continue }
        if (-not $d.EnforcementDeadline -or $d.EnforcementDeadline -gt $cutoff) { continue }
        if ($d.NumberTargeted -le 0 -or $d.NumberErrors -le 0) { continue }
        $pct = [math]::Round(($d.NumberErrors / $d.NumberTargeted) * 100, 1)
        if ($pct -lt $pctThreshold) { continue }

        New-HygieneFinding -CheckId 'DPL-02' -Severity Error -Category 'Deployments' `
            -ObjectType 'Deployment' -ObjectId ([string]$d.CollectionID) -ObjectName ("{0} -> {1}" -f $d.SoftwareName, $d.CollectionName) `
            -Evidence ("Required deployment passed its deadline {0} (over {1} days ago) with {2} of {3} targeted clients in error ({4}%)." -f $d.EnforcementDeadline, $grace, $d.NumberErrors, $d.NumberTargeted, $pct) `
            -Recommendation 'Investigate the client errors; a deployment stuck past deadline at this failure rate needs a fix or retirement, not more time.' `
            -FixScript ("# Triage first: deployment status for '{0}' on collection '{1}' in the console or by using Get-CMDeployment" -f $d.SoftwareName, $d.CollectionName)
    }
}

function Test-HygDeploymentAvailableUnused {
    <#
    .SYNOPSIS
        DPL-03: available deployments old enough to judge with zero
        successes and nothing in progress.
    #>
    param(
        [Parameter(Mandatory)]$Data,
        [hashtable]$Thresholds = (Get-HygieneDefaultThresholds)
    )

    $minAge = [int]$Thresholds.AvailableUnusedMinAgeDays
    $cutoff = (Get-Date).AddDays(-$minAge)

    foreach ($d in @($Data.Deployments)) {
        if ($d.DeploymentIntent -ne 2) { continue }
        if (-not $d.CreationTime -or $d.CreationTime -gt $cutoff) { continue }
        if ($d.NumberTargeted -le 0) { continue }
        if (($d.NumberSuccess + $d.NumberInProgress) -gt 0) { continue }

        New-HygieneFinding -CheckId 'DPL-03' -Severity Info -Category 'Deployments' `
            -ObjectType 'Deployment' -ObjectId ([string]$d.CollectionID) -ObjectName ("{0} -> {1}" -f $d.SoftwareName, $d.CollectionName) `
            -Evidence ("Available deployment created {0} (over {1} days ago) targets {2} clients with zero installs and nothing in progress." -f $d.CreationTime, $minAge, $d.NumberTargeted) `
            -Recommendation 'Nobody is opting in; remove the deployment or rethink how it is offered.' `
            -FixScript ("# Review: deployment of '{0}' to '{1}'" -f $d.SoftwareName, $d.CollectionName)
    }
}

function Test-HygDeploymentOld {
    <#
    .SYNOPSIS
        DPL-06: a deployment created more than the age threshold ago (default 365 days). The recommendation is to review whether
        it is still needed; nothing is deleted. A deployment that DPL-03 already reports (available, old enough, with no
        takers) is left to DPL-03, so one situation is one finding.
    #>
    param(
        [Parameter(Mandatory)]$Data,
        [hashtable]$Thresholds = (Get-HygieneDefaultThresholds)
    )

    $days = [int]$Thresholds.DeploymentOldDays
    if ($days -le 0) { return }
    $cutoff = (Get-Date).AddDays(-$days)
    $unusedAge = [int]$Thresholds.AvailableUnusedMinAgeDays
    $unusedCutoff = (Get-Date).AddDays(-$unusedAge)

    foreach ($d in @($Data.Deployments)) {
        if (-not $d.CreationTime -or $d.CreationTime -gt $cutoff) { continue }
        # DPL-03 reports it: available, older than its own age, targets clients, nobody installed it.
        if ($d.DeploymentIntent -eq 2 -and $d.CreationTime -le $unusedCutoff -and $d.NumberTargeted -gt 0 -and ($d.NumberSuccess + $d.NumberInProgress) -le 0) { continue }
        New-HygieneFinding -CheckId 'DPL-06' -Severity Info -Category 'Deployments' `
            -ObjectType 'Deployment' -ObjectId ([string]$d.CollectionID) -ObjectName ("{0} -> {1}" -f $d.SoftwareName, $d.CollectionName) `
            -Evidence ("The deployment was created {0}, more than {1} days ago. It targets {2} clients: {3} installed, {4} in progress, {5} with errors." -f $d.CreationTime, $days, $d.NumberTargeted, $d.NumberSuccess, $d.NumberInProgress, $d.NumberErrors) `
            -Recommendation 'Review whether the deployment is still needed. Nothing is deleted from here.' `
            -FixScript ("# Review: deployment of '{0}' to '{1}'" -f $d.SoftwareName, $d.CollectionName)
    }
}

# ---------------------------------------------------------------------------
# Checks: Devices
# ---------------------------------------------------------------------------

function Test-HygDeviceInactive {
    <#
    .SYNOPSIS
        DEV-01: one aggregated finding for clients inactive beyond the
        threshold. Severity depends on whether the discovery cleanup tasks
        are enabled to eventually purge them.
    #>
    param(
        [Parameter(Mandatory)]$Data,
        [hashtable]$Thresholds = (Get-HygieneDefaultThresholds)
    )

    $days = [int]$Thresholds.InactiveDeviceDays
    $cutoff = (Get-Date).AddDays(-$days)
    $inactive = @($Data.Devices | Where-Object {
        $_.IsClient -and $_.LastActiveTime -and $_.LastActiveTime -lt $cutoff
    })
    if ($inactive.Count -eq 0) { return }

    $cleanupTasks = @('Delete Inactive Client Discovery Data', 'Delete Aged Discovery Data')
    $cleanupEnabled = @($Data.MaintenanceTasks | Where-Object { $_.TaskName -in $cleanupTasks -and $_.Enabled }).Count -gt 0
    $sample = @($inactive | Sort-Object Name | Select-Object -First 15 | ForEach-Object { $_.Name }) -join ', '

    $severity = if ($cleanupEnabled) { 'Info' } else { 'Warning' }
    $cleanupNote = if ($cleanupEnabled) { 'discovery cleanup tasks are enabled and will eventually purge them' } else { 'no discovery cleanup task is enabled, so they accumulate forever' }

    New-HygieneFinding -CheckId 'DEV-01' -Severity $severity -Category 'Devices' `
        -ObjectType 'Site' -ObjectId '' -ObjectName 'Inactive clients' `
        -Evidence ("{0} clients have been inactive for over {1} days; {2}. First 15 by name: {3}" -f $inactive.Count, $days, $cleanupNote, $sample) `
        -Recommendation 'Verify that the devices no longer exist, then let the cleanup tasks purge them or delete the records.' `
        -FixScript "# Per device: Remove-CMDevice -Name '<name>' -Force  # verify first"
}

function Test-HygDeviceDuplicates {
    <#
    .SYNOPSIS
        DEV-02: device records sharing a name (and, when present, SMBIOS
        GUID collisions across different names).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Named for the duplicate condition it tests.')]
    param([Parameter(Mandatory)]$Data)

    foreach ($group in ($Data.Devices | Group-Object { ([string]$_.Name).ToLowerInvariant() } | Where-Object { $_.Count -gt 1 })) {
        $ids = @($group.Group | ForEach-Object { $_.ResourceID }) -join ', '
        New-HygieneFinding -CheckId 'DEV-02' -Severity Warning -Category 'Devices' `
            -ObjectType 'Device' -ObjectId $ids -ObjectName $group.Group[0].Name `
            -Evidence ("{0} device records share the name '{1}' (ResourceIDs {2}); deployments and reports split across them." -f $group.Count, $group.Group[0].Name, $ids) `
            -Recommendation 'Keep the active record and delete the stale duplicates.' `
            -FixScript ("# Review each: Get-CMDevice -Name '{0}' | Select-Object ResourceID, LastActiveTime, ClientVersion" -f (ConvertTo-HygQuotedLiteral $group.Group[0].Name))
    }

    # Placeholder GUIDs (unset firmware identifiers on cloned VMs and some
    # OEM batches) are shared by distinct machines - grouping them would
    # report machines-with-no-identifier as duplicates.
    $placeholderGuids = @(
        '00000000-0000-0000-0000-000000000000',
        'FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF'
    )
    $withGuid = @($Data.Devices | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.SMBIOSGUID) -and
        ([string]$_.SMBIOSGUID).Trim('{}') -notin $placeholderGuids
    })
    foreach ($group in ($withGuid | Group-Object SMBIOSGUID | Where-Object { $_.Count -gt 1 })) {
        $names = @($group.Group | ForEach-Object { $_.Name } | Select-Object -Unique)
        if ($names.Count -lt 2) { continue }  # same-name duplicates already covered
        New-HygieneFinding -CheckId 'DEV-02' -Severity Warning -Category 'Devices' `
            -ObjectType 'Device' -ObjectId ([string]$group.Name) -ObjectName ($names -join ' / ') `
            -Evidence ("{0} device records with different names share SMBIOS GUID {1}: {2}. Usually a renamed or re-imaged machine leaving a stale record." -f $group.Count, $group.Name, ($names -join ', ')) `
            -Recommendation 'Delete the record for the name the machine no longer uses.' `
            -FixScript "# Review each record's LastActiveTime before deleting"
    }
}

function Test-HygClientVersions {
    <#
    .SYNOPSIS
        DEV-03: one aggregated finding for clients below the newest client
        version observed in the site data.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Named for the version census it tests.')]
    param([Parameter(Mandatory)]$Data)

    $clients = @($Data.Devices | Where-Object { $_.IsClient -and $_.ClientVersion })
    if ($clients.Count -eq 0) { return }

    $versions = @($clients | ForEach-Object { try { [version]$_.ClientVersion } catch { $null } } | Where-Object { $_ })
    if ($versions.Count -eq 0) { return }
    $newest = ($versions | Sort-Object -Descending)[0]

    $behind = @($clients | Where-Object { try { [version]$_.ClientVersion -lt $newest } catch { $false } })
    if ($behind.Count -eq 0) { return }

    $sample = @($behind | Sort-Object Name | Select-Object -First 15 | ForEach-Object { "{0} ({1})" -f $_.Name, $_.ClientVersion }) -join ', '
    New-HygieneFinding -CheckId 'DEV-03' -Severity Info -Category 'Devices' `
        -ObjectType 'Site' -ObjectId '' -ObjectName 'Client version drift' `
        -Evidence ("{0} of {1} clients run a client version below the newest seen ({2}). First 15: {3}" -f $behind.Count, $clients.Count, $newest, $sample) `
        -Recommendation 'Check automatic client upgrade settings; long-tail old clients usually mean the upgrade never reaches them.' `
        -FixScript '# Console: Administration > Site Configuration > Sites > Hierarchy Settings > Client Upgrade'
}

# ---------------------------------------------------------------------------
# Checks: Boundaries
# ---------------------------------------------------------------------------

function Test-HygBoundaryChecks {
    <#
    .SYNOPSIS
        BND-01 boundaries in no group, BND-02 groups with no site systems,
        BND-03 overlapping IP-range boundaries.

    .DESCRIPTION
        Overlap detection covers IP-range boundaries only (BoundaryType 3,
        value 'start-end'); subnet and AD-site overlap is not computable
        from the value strings alone.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Runs the full boundary check family by design.')]
    param([Parameter(Mandatory)]$Data)

    # GroupCount -1 means the provider did not surface the count; unknown
    # is not zero, so those boundaries are skipped rather than flagged.
    foreach ($b in @($Data.Boundaries | Where-Object { $_.GroupCount -eq 0 })) {
        New-HygieneFinding -CheckId 'BND-01' -Severity Warning -Category 'Boundaries' `
            -ObjectType 'Boundary' -ObjectId ([string]$b.Value) -ObjectName ($(if ($b.DisplayName) { $b.DisplayName } else { $b.Value })) `
            -Evidence ("Boundary '{0}' belongs to no boundary group; clients inside it get no content location or site assignment from it." -f $b.Value) `
            -Recommendation 'Add the boundary to the appropriate boundary group or delete it.' `
            -FixScript '# Console: Administration > Hierarchy Configuration > Boundary Groups - add the boundary'
    }

    foreach ($g in @($Data.BoundaryGroups | Where-Object { $_.SiteSystemCount -eq 0 })) {
        New-HygieneFinding -CheckId 'BND-02' -Severity Warning -Category 'Boundaries' `
            -ObjectType 'BoundaryGroup' -ObjectId ([string]$g.GroupID) -ObjectName $g.Name `
            -Evidence ("Boundary group '{0}' references no site systems; clients in it fall back to other groups for content, adding latency, unless it exists for site assignment only." -f $g.Name) `
            -Recommendation 'Add the serving DP/MP site systems, or leave as-is if the group is assignment-only by design.' `
            -FixScript ("# Console: Boundary Group '{0}' Properties > References - add site systems" -f $g.Name)
    }

    $ranges = @()
    foreach ($b in @($Data.Boundaries | Where-Object { $_.BoundaryType -eq 3 })) {
        $parts = ([string]$b.Value) -split '-'
        if ($parts.Count -ne 2) { continue }
        try {
            $start = [System.Net.IPAddress]::Parse($parts[0].Trim())
            $end   = [System.Net.IPAddress]::Parse($parts[1].Trim())
            $ranges += [pscustomobject]@{
                Boundary = $b
                Start    = [uint32]([System.BitConverter]::ToUInt32(([byte[]]$start.GetAddressBytes())[3..0], 0))
                End      = [uint32]([System.BitConverter]::ToUInt32(([byte[]]$end.GetAddressBytes())[3..0], 0))
            }
        } catch { continue }
    }
    for ($i = 0; $i -lt $ranges.Count; $i++) {
        for ($j = $i + 1; $j -lt $ranges.Count; $j++) {
            $a = $ranges[$i]; $b2 = $ranges[$j]
            if ($a.Start -le $b2.End -and $b2.Start -le $a.End) {
                New-HygieneFinding -CheckId 'BND-03' -Severity Info -Category 'Boundaries' `
                    -ObjectType 'Boundary' -ObjectId ([string]$a.Boundary.Value) -ObjectName ("{0} overlaps {1}" -f $a.Boundary.Value, $b2.Boundary.Value) `
                    -Evidence ("IP ranges '{0}' and '{1}' overlap. Fine for content location, a problem for automatic site assignment if the overlapping groups assign different sites." -f $a.Boundary.Value, $b2.Boundary.Value) `
                    -Recommendation 'Verify the overlap is intentional and both ranges route to compatible boundary groups.' `
                    -FixScript '# Console: Administration > Hierarchy Configuration > Boundaries'
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Checks: Task sequences
# ---------------------------------------------------------------------------

function Test-HygTaskSequenceRefs {
    <#
    .SYNOPSIS
        TSQ-01 task sequences referencing deleted content; TSQ-02 boot
        images and driver packages nothing references.

    .DESCRIPTION
        The known-content universe is packages, boot images, driver
        packages, update deployment packages, and applications (by content
        PackageID or ModelName). Default boot images ship with the site
        and are excluded from TSQ-02.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Runs the full task sequence reference family by design.')]
    param([Parameter(Mandatory)]$Data)

    $known = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($x in @($Data.Packages))          { [void]$known.Add([string]$x.PackageID) }
    foreach ($x in @($Data.BootImages))        { [void]$known.Add([string]$x.PackageID) }
    foreach ($x in @($Data.DriverPackages))    { [void]$known.Add([string]$x.PackageID) }
    foreach ($x in @($Data.UpdatePackages))    { [void]$known.Add([string]$x.PackageID) }
    foreach ($x in @(Get-HygLiveTaskSequence -Data $Data))     { [void]$known.Add([string]$x.PackageID) }
    # OS images and OS upgrade packages are legitimate task-sequence
    # references (ImagePackageID / InstallPackageID); without them every
    # Apply/Upgrade Operating System step reads as deleted content.
    foreach ($x in @($Data.OSImages))          { [void]$known.Add([string]$x.PackageID) }
    foreach ($x in @($Data.OSUpgradePackages)) { [void]$known.Add([string]$x.PackageID) }
    foreach ($x in @($Data.Applications)) {
        if ($x.PackageID) { [void]$known.Add([string]$x.PackageID) }
        if ($x.ModelName) { [void]$known.Add([string]$x.ModelName) }
    }

    foreach ($ts in @(Get-HygLiveTaskSequence -Data $Data)) {
        # BootImageID is stored separately from References on the task
        # sequence object, so include it explicitly in the broken-reference
        # check as well as in TSQ-02's usage accounting below.
        $candidateIds = @($ts.ReferencedIDs)
        if ($ts.BootImageID) { $candidateIds += [string]$ts.BootImageID }
        $missing = @($candidateIds | Where-Object { $_ -and -not $known.Contains([string]$_) } | Select-Object -Unique)
        if ($missing.Count -eq 0) { continue }
        New-HygieneFinding -CheckId 'TSQ-01' -Severity Error -Category 'Task Sequences' `
            -ObjectType 'TaskSequence' -ObjectId ([string]$ts.PackageID) -ObjectName $ts.Name `
            -Evidence ("Task sequence references {0} content id(s) that no longer exist: {1}. Runs fail at those steps." -f $missing.Count, ($missing -join ', ')) `
            -Recommendation 'Open the task sequence editor and fix or remove the steps referencing deleted content.' `
            -FixScript ("# Console: edit task sequence '{0}' and repair the broken references" -f $ts.Name)
    }

    $referenced = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($ts in @(Get-HygLiveTaskSequence -Data $Data)) {
        foreach ($r in @($ts.ReferencedIDs)) { [void]$referenced.Add([string]$r) }
        if ($ts.BootImageID) { [void]$referenced.Add([string]$ts.BootImageID) }
    }

    # Default boot images ship with the site and stay unreferenced until
    # OSD is in use; flagging them is noise.
    foreach ($bi in @($Data.BootImages | Where-Object { $_.Name -notmatch '^Boot image \((x64|x86|arm64)\)$' })) {
        if ($referenced.Contains([string]$bi.PackageID)) { continue }
        New-HygieneFinding -CheckId 'TSQ-02' -Severity Warning -Category 'Task Sequences' `
            -ObjectType 'BootImage' -ObjectId ([string]$bi.PackageID) -ObjectName $bi.Name `
            -Evidence 'Custom boot image is referenced by no task sequence.' `
            -Recommendation 'Delete it if the task sequences that used it are gone; its content still occupies DPs.' `
            -FixScript ("Remove-CMBootImage -Id '{0}' -Force" -f (ConvertTo-HygQuotedLiteral $bi.PackageID))
    }
    foreach ($dp in @($Data.DriverPackages)) {
        if ($referenced.Contains([string]$dp.PackageID)) { continue }
        New-HygieneFinding -CheckId 'TSQ-02' -Severity Warning -Category 'Task Sequences' `
            -ObjectType 'DriverPackage' -ObjectId ([string]$dp.PackageID) -ObjectName $dp.Name `
            -Evidence 'Driver package is referenced by no task sequence.' `
            -Recommendation 'Delete it if the hardware model is retired; driver packages are among the largest content on DPs.' `
            -FixScript ("Remove-CMDriverPackage -Id '{0}' -Force" -f (ConvertTo-HygQuotedLiteral $dp.PackageID))
    }
}

# ---------------------------------------------------------------------------
# Checks: Updates
# ---------------------------------------------------------------------------

function Test-HygTaskSequenceApplications {
    <#
    .SYNOPSIS
        TSQ-03: an application in a task sequence that does not have the
        task sequence install setting. TSQ-04: an application in a task
        sequence whose content is on no distribution point. One finding
        per application; the evidence names the task sequences.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Runs the task sequence application check family by design.')]
    param([Parameter(Mandatory)]$Data)

    $appByModel = @{}
    foreach ($a in @($Data.Applications)) { if ($a.ModelName) { $appByModel[[string]$a.ModelName] = $a } }
    $tsByModel = @{}
    foreach ($ts in @(Get-HygLiveTaskSequence -Data $Data)) {
        foreach ($ref in @($ts.ReferencedIDs)) {
            if ($appByModel.ContainsKey([string]$ref)) { $tsByModel[[string]$ref] = @($tsByModel[[string]$ref]) + $ts.Name }
        }
    }
    if ($tsByModel.Count -eq 0) { return }

    foreach ($def in @($Data.TsAppDefinitions)) {
        if (-not $def -or $def.AutoInstall -or -not $tsByModel.ContainsKey([string]$def.ModelName)) { continue }
        $app = $appByModel[[string]$def.ModelName]
        $tsNames = @($tsByModel[[string]$def.ModelName] | Sort-Object -Unique) -join "', '"
        New-HygieneFinding -CheckId 'TSQ-03' -Severity Warning -Category 'Task Sequences' `
            -ObjectType 'Application' -ObjectId ([string]$app.ModelName) -ObjectName $app.Name `
            -Evidence ("Task sequence '{0}' installs this application. The application does not have the setting 'Allow this application to be installed from the Install Application task sequence action without being deployed'." -f $tsNames) `
            -Recommendation 'Set the option on the General tab of the application properties. The change makes a new application revision.' `
            -FixScript ("Get-CMApplication -ModelName '{0}' | Set-CMApplication -AutoInstall `$true" -f (ConvertTo-HygQuotedLiteral $def.ModelName))
    }

    # SourceSize 0 covers an application with no content files.
    foreach ($row in @($Data.ContentStatus)) {
        if (-not $row -or $row.ObjectType -ne 512 -or $row.Targeted -ne 0 -or $row.SourceSize -le 0) { continue }
        $model = [string]$row.ObjectID
        if (-not $tsByModel.ContainsKey($model)) { continue }
        $app = $appByModel[$model]
        $tsNames = @($tsByModel[$model] | Sort-Object -Unique) -join "', '"
        New-HygieneFinding -CheckId 'TSQ-04' -Severity Error -Category 'Task Sequences' `
            -ObjectType 'Application' -ObjectId ([string]$app.ModelName) -ObjectName $app.Name `
            -Evidence ("Task sequence '{0}' installs this application. The application has source files, and its content is on no distribution point. The task sequence cannot find the content." -f $tsNames) `
            -Recommendation 'Distribute the content to the distribution point groups that serve the task sequence clients.' `
            -FixScript ("# Console: Software Library > '{0}' > Distribute Content - select the distribution point groups" -f $app.Name)
    }
}

function Test-HygUpdateGroupChecks {
    <#
    .SYNOPSIS
        UPD-01: software update groups with a high expired-update ratio.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Runs the update-group check family by design.')]
    param(
        [Parameter(Mandatory)]$Data,
        [hashtable]$Thresholds = (Get-HygieneDefaultThresholds)
    )

    # Expired count is the only documented number on SMS_AuthorizationList;
    # superseded presence is a boolean (ContainsSupersededUpdates), so it
    # colors the evidence but never enters the percentage.
    $pctThreshold = [int]$Thresholds.SugExpiredPctThreshold
    foreach ($sug in @($Data.UpdateGroups)) {
        if ($sug.NumberOfUpdates -le 0) { continue }
        $pct = [math]::Round(($sug.NumberOfExpiredUpdates / $sug.NumberOfUpdates) * 100, 1)
        if ($pct -lt $pctThreshold) { continue }
        $supersededNote = if ($sug.ContainsSupersededUpdates) { ' The group also contains superseded updates.' } else { '' }
        New-HygieneFinding -CheckId 'UPD-01' -Severity Warning -Category 'Updates' `
            -ObjectType 'UpdateGroup' -ObjectId ([string]$sug.CI_ID) -ObjectName $sug.Name `
            -Evidence ("{0} of {1} updates in the group are expired ({2}%); compliance numbers computed from it are misleading.{3}" -f $sug.NumberOfExpiredUpdates, $sug.NumberOfUpdates, $pct, $supersededNote) `
            -Recommendation 'Clean the expired/superseded updates out of the group or rebuild it from a current search.' `
            -FixScript ("# Console: Software Library > Software Update Groups > '{0}' - remove expired/superseded members" -f $sug.Name)
    }
}

function Test-HygAdrChecks {
    <#
    .SYNOPSIS
        UPD-03: ADRs erroring, disabled, or enabled but stale.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Runs the ADR check family by design.')]
    param(
        [Parameter(Mandatory)]$Data,
        [hashtable]$Thresholds = (Get-HygieneDefaultThresholds)
    )

    $staleDays = [int]$Thresholds.AdrStaleDays
    $staleCutoff = (Get-Date).AddDays(-$staleDays)
    foreach ($adr in @($Data.AutoDeploymentRules)) {
        if ($adr.LastErrorCode -ne 0) {
            New-HygieneFinding -CheckId 'UPD-03' -Severity Error -Category 'Updates' `
                -ObjectType 'ADR' -ObjectId '' -ObjectName $adr.Name `
                -Evidence ("Automatic deployment rule's last run ended with error code {0}; new updates are not being deployed by it." -f $adr.LastErrorCode) `
                -Recommendation 'Open the ADR run history (the ruleengine.log file on the site server) and fix the failure.' `
                -FixScript ("# Rerun after fixing: Invoke-CMSoftwareUpdateAutoDeploymentRule -Name '{0}'" -f (ConvertTo-HygQuotedLiteral $adr.Name))
        }
        elseif (-not $adr.AutoDeploymentEnabled) {
            New-HygieneFinding -CheckId 'UPD-03' -Severity Info -Category 'Updates' `
                -ObjectType 'ADR' -ObjectId '' -ObjectName $adr.Name `
                -Evidence 'Automatic deployment rule is disabled.' `
                -Recommendation 'Delete it if retired, or re-enable it if it should still run.' `
                -FixScript ("Get-CMAutoDeploymentRule -Name '{0}' -DisableWildcardHandling -Fast | Remove-CMAutoDeploymentRule -Force  # or re-enable in console" -f (ConvertTo-HygQuotedLiteral $adr.Name))
        }
        elseif ($adr.LastRunTime -and $adr.LastRunTime -lt $staleCutoff) {
            New-HygieneFinding -CheckId 'UPD-03' -Severity Warning -Category 'Updates' `
                -ObjectType 'ADR' -ObjectId '' -ObjectName $adr.Name `
                -Evidence ("Automatic deployment rule is enabled but last ran {0} (over {1} days ago); its schedule may be broken." -f $adr.LastRunTime, $staleDays) `
                -Recommendation 'Check the ADR schedule and the last evaluation in ruleengine.log.' `
                -FixScript ("Invoke-CMSoftwareUpdateAutoDeploymentRule -Name '{0}' -DisableWildcardHandling" -f (ConvertTo-HygQuotedLiteral $adr.Name))
        }
    }
}

# ---------------------------------------------------------------------------
# Checks: Site maintenance
# ---------------------------------------------------------------------------

function Test-HygMaintenanceTasks {
    <#
    .SYNOPSIS
        MNT-01 recommended cleanup tasks that exist but are disabled;
        MNT-02 the site backup task disabled.

    .DESCRIPTION
        The recommended set is conservative cleanup-only tasks; index
        rebuild is deliberately excluded because sites with external SQL
        maintenance disable it on purpose.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Runs the full maintenance-task family by design.')]
    param([Parameter(Mandatory)]$Data)

    $recommended = @(
        'Delete Aged Inventory History',
        'Delete Aged Discovery Data',
        'Delete Obsolete Client Discovery Data',
        'Delete Aged Client Operations',
        'Delete Aged Log Data'
    )
    foreach ($t in @($Data.MaintenanceTasks | Where-Object { $_.TaskName -in $recommended -and -not $_.Enabled })) {
        New-HygieneFinding -CheckId 'MNT-01' -Severity Info -Category 'Site' `
            -ObjectType 'MaintenanceTask' -ObjectId '' -ObjectName $t.TaskName `
            -Evidence ("Cleanup task '{0}' is disabled; the data it would prune accumulates in the site database." -f $t.TaskName) `
            -Recommendation 'Enable it unless a deliberate retention policy keeps it off. Run Fix enables the task on the connected site; a site with its own task of that name needs the same step there.' `
            -FixScript ("Set-CMSiteMaintenanceTask -Name '{0}' -Enabled `$true -DisableWildcardHandling" -f (ConvertTo-HygQuotedLiteral $t.TaskName))
    }

    $backup = @($Data.MaintenanceTasks | Where-Object { $_.TaskName -eq 'Backup Site Server' }) | Select-Object -First 1
    if ($backup -and -not $backup.Enabled) {
        New-HygieneFinding -CheckId 'MNT-02' -Severity Warning -Category 'Site' `
            -ObjectType 'MaintenanceTask' -ObjectId '' -ObjectName 'Backup Site Server' `
            -Evidence 'The Backup Site Server maintenance task is disabled.' `
            -Recommendation 'Enable it, or confirm an SQL-level backup of the site database (plus CD.Latest) covers recovery instead. Run Fix is not offered: enabling the task needs a backup destination that only you know. Set the destination, then enable the task.' `
            -FixScript "# Set the backup destination and enable the task: Set-CMSiteMaintenanceTask -Name 'Backup Site Server' -SiteBackupPath <backup path> -Enabled `$true"
    }
}

# ---------------------------------------------------------------------------
# Application relationships (absorbed from the supersedence-auditor tool)
# ---------------------------------------------------------------------------

function ConvertTo-HygRelationships {
    <#
    .SYNOPSIS
        Parses SDMPackageXML into supersedence/dependency relationship
        records and deployment-type content locations. Pure over its input.

    .DESCRIPTION
        One in-memory XPath pass replaces per-app cmdlet round-trips. The
        XML shape: /AppMgmtDigest/DeploymentType (digest namespace) with
        Supersedes and Dependencies rule blocks in the Rules namespace;
        each DeploymentTypeIntentExpression carries the referenced
        application's AuthoringScopeId/LogicalName (its ModelName) and,
        for dependencies, a DesiredState of Required or Optional.

    .PARAMETER Applications
        Objects with CI_ID, ModelName, Name, SoftwareVersion, IsSuperseding,
        NumberOfDeploymentTypes, SDMPackageXML.

    .OUTPUTS
        [pscustomobject] Relationships (FromAppCIID/FromAppName/FromDTName/
        ToAppCIID/ToAppName/ToModelName/ToAppExists/Kind/DependencyState),
        ContentLocations (AppCIID/AppName/DTName/Location),
        AutoInstallByModel (ModelName to the task sequence install
        setting), ParseNotes.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Converts to the full relationship set by design.')]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Applications
    )

    $modelToApp = @{}
    foreach ($app in $Applications) {
        if ($app.ModelName) { $modelToApp[[string]$app.ModelName] = $app }
    }

    $relationships = New-Object System.Collections.Generic.List[object]
    $contentLocations = New-Object System.Collections.Generic.List[object]
    $autoInstall = @{}
    $notes = New-Object System.Collections.Generic.List[string]

    $nsDigest = 'http://schemas.microsoft.com/SystemCenterConfigurationManager/2009/AppMgmtDigest'
    $nsRules  = 'http://schemas.microsoft.com/SystemsCenterConfigurationManager/2009/06/14/Rules'

    $withXml = @($Applications | Where-Object { $_.NumberOfDeploymentTypes -gt 0 -and $_.SDMPackageXML })

    foreach ($app in $withXml) {
        try {
            [xml]$xml = $app.SDMPackageXML
        }
        catch {
            $notes.Add(("SDMPackageXML for '{0}' did not parse: {1}" -f $app.Name, $_.Exception.Message))
            continue
        }

        $nsm = [System.Xml.XmlNamespaceManager]::new($xml.NameTable)
        $nsm.AddNamespace('d', $nsDigest)
        $nsm.AddNamespace('r', $nsRules)

        if ($app.ModelName) {
            $autoNode = $xml.SelectSingleNode('/d:AppMgmtDigest/d:Application/d:AutoInstall', $nsm)
            $autoInstall[[string]$app.ModelName] = [bool]($autoNode -and ([string]$autoNode.InnerText).Trim() -eq 'true')
        }

        $dtNodes = $xml.SelectNodes('/d:AppMgmtDigest/d:DeploymentType', $nsm)
        foreach ($dtNode in $dtNodes) {
            $dtTitle = ''
            $titleNode = $dtNode.SelectSingleNode('d:Title', $nsm)
            if ($titleNode) { $dtTitle = $titleNode.InnerText }

            foreach ($loc in $dtNode.SelectNodes('d:Installer/d:Contents/d:Content/d:Location', $nsm)) {
                $path = [string]$loc.InnerText
                if (-not [string]::IsNullOrWhiteSpace($path)) {
                    $contentLocations.Add([pscustomobject]@{
                        AppCIID = [int]$app.CI_ID
                        AppName = [string]$app.Name
                        DTName  = $dtTitle
                        Location = $path.Trim()
                    })
                }
            }

            # The XML is read for every application. IsSuperseding is not a
            # gate: the site clears it when the superseded application is
            # deleted, which is the broken reference SUP-01 reports.
            foreach ($rule in $dtNode.SelectNodes('d:Supersedes/r:DeploymentTypeRule', $nsm)) {
                foreach ($intent in $rule.SelectNodes('.//r:DeploymentTypeIntentExpression', $nsm)) {
                    $appRef = $intent.SelectSingleNode('r:DeploymentTypeApplicationReference', $nsm)
                    if (-not $appRef) { continue }
                    $refModel = '{0}/{1}' -f $appRef.GetAttribute('AuthoringScopeId'), $appRef.GetAttribute('LogicalName')
                    $toApp = $null
                    if ($modelToApp.ContainsKey($refModel)) { $toApp = $modelToApp[$refModel] }
                    $dtRef = $intent.SelectSingleNode('r:DeploymentTypeReference', $nsm)

                    $relationships.Add([pscustomobject]@{
                        FromAppCIID     = [int]$app.CI_ID
                        FromAppName     = [string]$app.Name
                        FromDTName      = $dtTitle
                        ToAppCIID       = if ($toApp) { [int]$toApp.CI_ID } else { 0 }
                        ToAppName       = if ($toApp) { [string]$toApp.Name } else { "Unknown ($refModel)" }
                        ToModelName     = $refModel
                        ToAppExists     = ($null -ne $toApp)
                        Kind            = 'Supersedence'
                        DependencyState = ''
                        # The fix of SUP-01 names the exact rule: the deployment type of the source application, the rule
                        # and the deployment type that the rule points at.
                        FromDTLogicalName = [string]$dtNode.GetAttribute('LogicalName')
                        RuleId            = [string]$rule.GetAttribute('id')
                        ToDTLogicalName   = $(if ($dtRef) { [string]$dtRef.GetAttribute('LogicalName') } else { '' })
                    })
                }
            }

            foreach ($rule in $dtNode.SelectNodes('d:Dependencies/r:DeploymentTypeRule', $nsm)) {
                foreach ($intent in $rule.SelectNodes('.//r:DeploymentTypeIntentExpression', $nsm)) {
                    $appRef = $intent.SelectSingleNode('r:DeploymentTypeApplicationReference', $nsm)
                    if (-not $appRef) { continue }
                    $refModel = '{0}/{1}' -f $appRef.GetAttribute('AuthoringScopeId'), $appRef.GetAttribute('LogicalName')
                    $toApp = $null
                    if ($modelToApp.ContainsKey($refModel)) { $toApp = $modelToApp[$refModel] }

                    $desired = [string]$intent.GetAttribute('DesiredState')
                    $depState = switch ($desired) {
                        'Required' { 'Required' }
                        'Optional' { 'Optional' }
                        default    { 'AppDependence' }
                    }

                    $relationships.Add([pscustomobject]@{
                        FromAppCIID     = [int]$app.CI_ID
                        FromAppName     = [string]$app.Name
                        FromDTName      = $dtTitle
                        ToAppCIID       = if ($toApp) { [int]$toApp.CI_ID } else { 0 }
                        ToAppName       = if ($toApp) { [string]$toApp.Name } else { "Unknown ($refModel)" }
                        ToModelName     = $refModel
                        ToAppExists     = ($null -ne $toApp)
                        Kind            = 'Dependency'
                        DependencyState = $depState
                        FromDTLogicalName = [string]$dtNode.GetAttribute('LogicalName')
                        RuleId            = [string]$rule.GetAttribute('id')
                        ToDTLogicalName   = ''
                    })
                }
            }
        }
    }

    # .ToArray(), not @(...): wrapping a generic List of PSCustomObjects in
    # an array subexpression throws "Argument types do not match" on some
    # PowerShell 7 builds.
    return [pscustomobject]@{
        Relationships      = $relationships.ToArray()
        ContentLocations   = $contentLocations.ToArray()
        AutoInstallByModel = $autoInstall
        ParseNotes         = $notes.ToArray()
    }
}

function Get-HygieneRelationshipData {
    <#
    .SYNOPSIS
        Bulk-loads applications WITH SDMPackageXML and resolves every
        supersedence/dependency relationship in one pass.

    .DESCRIPTION
        One Get-CMApplication call (no -Fast: the XML is the point)
        followed by the pure parser. SDMPackageXML is a lazy property, so
        the provider fills it one instance at a time behind that call.
        Requires an established CM connection. Returns $null on total
        failure with the reason logged.
    #>
    param(
        [hashtable]$ProgressState,
        [int]$ExpectedCount = 0
    )

    try {
        Write-Log 'Loading applications with SDMPackageXML for relationship analysis (one provider read per application)...'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $read = 0
        $apps = @(Get-CMApplication -ErrorAction Stop | ForEach-Object {
            $read++
            if ($ProgressState) {
                $ProgressState.Step = $(if ($ExpectedCount -gt 0) { "Reading application definitions ($read of $ExpectedCount)..." } else { "Reading application definitions ($read)..." })
            }
            if ($read % 100 -eq 0) { Write-Log ("Read {0} application definitions in {1:n0}s" -f $read, $sw.Elapsed.TotalSeconds) }
            [pscustomobject]@{
                CI_ID                   = [int]$_.CI_ID
                ModelName               = [string]$_.ModelName
                Name                    = [string]$_.LocalizedDisplayName
                SoftwareVersion         = [string]$_.SoftwareVersion
                Manufacturer            = [string]$_.Manufacturer
                IsEnabled               = [bool]$_.IsEnabled
                IsExpired               = [bool]$_.IsExpired
                IsSuperseded            = [bool]$_.IsSuperseded
                IsSuperseding           = [bool]$_.IsSuperseding
                HasContent              = [bool]$_.HasContent
                NumberOfDeploymentTypes = [int]$_.NumberOfDeploymentTypes
                SDMPackageXML           = [string]$_.SDMPackageXML
            }
        })

        $parsed = ConvertTo-HygRelationships -Applications $apps

        # The lookup drops SDMPackageXML: consumers need flags and names
        # only, and the XML blobs would otherwise ride along through the
        # background-runspace state transfer.
        $lookup = @{}
        foreach ($a in $apps) {
            $lookup[[int]$a.CI_ID] = [pscustomobject]@{
                CI_ID                   = $a.CI_ID
                ModelName               = $a.ModelName
                Name                    = $a.Name
                SoftwareVersion         = $a.SoftwareVersion
                Manufacturer            = $a.Manufacturer
                IsEnabled               = $a.IsEnabled
                IsExpired               = $a.IsExpired
                IsSuperseded            = $a.IsSuperseded
                IsSuperseding           = $a.IsSuperseding
                HasContent              = $a.HasContent
                NumberOfDeploymentTypes = $a.NumberOfDeploymentTypes
            }
        }

        Write-Log ("Resolved {0} relationships and {1} content locations from {2} applications" -f @($parsed.Relationships).Count, @($parsed.ContentLocations).Count, $apps.Count)

        return [pscustomobject]@{
            Apps               = $lookup
            Relationships      = $parsed.Relationships
            ContentLocations   = $parsed.ContentLocations
            AutoInstallByModel = $parsed.AutoInstallByModel
            DatasetNotes       = $parsed.ParseNotes
        }
    }
    catch {
        Write-Log ("Relationship data unavailable: {0}" -f $_.Exception.Message) -Level WARN -Quiet
        Write-Log 'Relationship data is unavailable. The log file has the details.' -Level WARN
        return $null
    }
}

function Find-HygCircularEdges {
    <#
    .SYNOPSIS
        Returns the set of edges that participate in a cycle: an edge
        (From -> To) is circular when From is reachable from To.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns the circular edge set by design.')]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Edges
    )

    $adj = @{}
    foreach ($e in $Edges) {
        $k = [int]$e.FromAppCIID
        if (-not $adj.ContainsKey($k)) { $adj[$k] = New-Object System.Collections.Generic.List[int] }
        $adj[$k].Add([int]$e.ToAppCIID)
    }

    $reachCache = @{}
    $reach = {
        param([int]$From, [int]$Target)
        $key = "$From>$Target"
        if ($reachCache.ContainsKey($key)) { return $reachCache[$key] }
        $seen = New-Object 'System.Collections.Generic.HashSet[int]'
        $stack = New-Object System.Collections.Generic.Stack[int]
        $stack.Push($From)
        $found = $false
        while ($stack.Count -gt 0) {
            $n = $stack.Pop()
            if ($n -eq $Target) { $found = $true; break }
            if (-not $seen.Add($n)) { continue }
            if ($adj.ContainsKey($n)) { foreach ($m in $adj[$n]) { $stack.Push($m) } }
        }
        $reachCache[$key] = $found
        return $found
    }

    $circular = @()
    foreach ($e in $Edges) {
        if ([int]$e.ToAppCIID -eq 0) { continue }
        if (& $reach ([int]$e.ToAppCIID) ([int]$e.FromAppCIID)) { $circular += ,$e }
    }
    # Emit unrolled: callers rebuild with @(...).
    return $circular
}

function Test-HygRelationshipChecks {
    <#
    .SYNOPSIS
        SUP-01..04, DEP-01..05, REL-01 over parsed relationship data.

    .DESCRIPTION
        Status semantics match the absorbed auditor: orphaned reference and
        circular chains are errors, expired targets and disabled
        source/target are warnings, a dependency target without content is
        an error, relationships without manufacturer metadata are
        informational. Supersedence and dependency rules have no removal
        cmdlet, so the fix scripts are console guidance.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Runs the full relationship check family by design.')]
    param(
        [Parameter(Mandatory)]$RelationshipData
    )

    $apps = $RelationshipData.Apps
    # A CI_ID changes with each application revision; the model name does
    # not, so it keeps the finding key stable across edits.
    $modelOf = { param($ciid) $a = $apps[[int]$ciid]; if ($a -and $a.ModelName) { [string]$a.ModelName } else { [string]$ciid } }
    $rels = @($RelationshipData.Relationships)
    $sup  = @($rels | Where-Object { $_.Kind -eq 'Supersedence' })
    $dep  = @($rels | Where-Object { $_.Kind -eq 'Dependency' })

    foreach ($r in $sup) {
        $pair = "'{0}' -> '{1}'" -f $r.FromAppName, $r.ToAppName
        if (-not $r.ToAppExists) {
            New-HygieneFinding -CheckId 'SUP-01' -Severity Error -Category 'Relationships' `
                -ObjectType 'Supersedence' -ObjectId (& $modelOf $r.FromAppCIID) -ObjectName $pair `
                -Evidence ("Supersedence on deployment type '{0}' references {1}, which no longer exists in the site." -f $r.FromDTName, $r.ToModelName) `
                -Recommendation 'Remove the broken supersedence reference. A broken reference makes the evaluation of other deployments fail on clients. Fix Supersedence shows what it removes and then removes the reference.' `
                -FixScript ("# Fix Supersedence removes the reference of '{0}' to the deleted application. No script runs from here." -f $r.FromAppName) `
                -FixData ([pscustomobject]@{
                    Kind                       = 'SupersedenceToDeletedApplication'
                    ApplicationModelName       = [string](& $modelOf $r.FromAppCIID)
                    ApplicationName            = [string]$r.FromAppName
                    DeploymentTypeLogicalName  = [string]$r.FromDTLogicalName
                    DeploymentTypeName         = [string]$r.FromDTName
                    RuleId                     = [string]$r.RuleId
                    ReferencedApplicationModel = [string]$r.ToModelName
                    ReferencedDeploymentTypeLogicalName = [string]$r.ToDTLogicalName
                })
            continue
        }
        $fromApp = $apps[[int]$r.FromAppCIID]
        $toApp   = $apps[[int]$r.ToAppCIID]
        if ($toApp -and $toApp.IsExpired) {
            New-HygieneFinding -CheckId 'SUP-04' -Severity Warning -Category 'Relationships' `
                -ObjectType 'Supersedence' -ObjectId (& $modelOf $r.FromAppCIID) -ObjectName $pair `
                -Evidence ("Superseded application '{0}' is retired; the rule still exists but its target is inactive." -f $r.ToAppName) `
                -Recommendation 'Remove the supersedence relationship. No active application may supersede a retired one. Run Fix removes the rule with Set-CMApplicationSupersedence and then deletes the old revisions that the change makes.' `
                -FixScript (Get-HygSupersedenceRemovalScript -FromModel ([string](& $modelOf $r.FromAppCIID)) -FromDeploymentType ([string]$r.FromDTLogicalName) -ToModel ([string]$r.ToModelName) -ToDeploymentType ([string]$r.ToDTLogicalName))
        }
        elseif ($fromApp -and -not $fromApp.IsEnabled) {
            New-HygieneFinding -CheckId 'SUP-03' -Severity Warning -Category 'Relationships' `
                -ObjectType 'Supersedence' -ObjectId (& $modelOf $r.FromAppCIID) -ObjectName $pair `
                -Evidence ("Superseding application '{0}' is disabled; the replacement cannot deploy while the rule stands." -f $r.FromAppName) `
                -Recommendation 'Enable the superseding application or remove the supersedence relationship.' `
                -FixScript ("Get-CMApplication -Name '{0}' -DisableWildcardHandling | Resume-CMApplication" -f (ConvertTo-HygQuotedLiteral $r.FromAppName))
        }
    }

    foreach ($e in (Find-HygCircularEdges -Edges $sup)) {
        New-HygieneFinding -CheckId 'SUP-02' -Severity Error -Category 'Relationships' `
            -ObjectType 'Supersedence' -ObjectId (& $modelOf $e.FromAppCIID) -ObjectName ("'{0}' -> '{1}'" -f $e.FromAppName, $e.ToAppName) `
            -Evidence 'This supersedence edge is part of a loop: following the chain from the superseded application eventually returns to the superseding one.' `
            -Recommendation 'Break the loop by removing the relationship that closes it.' `
            -FixScript ("# Console: review the supersedence chain starting at '{0}' and remove the looping reference" -f $e.FromAppName)
    }

    foreach ($r in $dep) {
        $pair = "'{0}' -> '{1}'" -f $r.FromAppName, $r.ToAppName
        if (-not $r.ToAppExists) {
            New-HygieneFinding -CheckId 'DEP-01' -Severity Error -Category 'Relationships' `
                -ObjectType 'Dependency' -ObjectId (& $modelOf $r.FromAppCIID) -ObjectName $pair `
                -Evidence ("Dependency on deployment type '{0}' references {1}, which no longer exists in the site." -f $r.FromDTName, $r.ToModelName) `
                -Recommendation 'Remove the broken dependency; installs of the parent fail while it references a deleted application.' `
                -FixScript ("# Console: '{0}' > Deployment Types > '{1}' > Dependencies - remove the broken reference" -f $r.FromAppName, $r.FromDTName)
            continue
        }
        $toApp = $apps[[int]$r.ToAppCIID]
        if ($toApp -and $toApp.IsExpired) {
            New-HygieneFinding -CheckId 'DEP-04' -Severity Warning -Category 'Relationships' `
                -ObjectType 'Dependency' -ObjectId (& $modelOf $r.FromAppCIID) -ObjectName $pair `
                -Evidence ("Dependency target '{0}' is retired; {1} installs relying on it will fail." -f $r.ToAppName, $r.DependencyState) `
                -Recommendation 'Remove the dependency, or point it at the current application. No active application may depend on a retired one. Run Fix removes the dependency with Remove-CMDeploymentTypeDependency and then deletes the old revisions that the change makes.' `
                -FixScript (Get-HygDependencyRemovalScript -FromModel ([string](& $modelOf $r.FromAppCIID)) -FromDeploymentType ([string]$r.FromDTLogicalName) -ToModel ([string]$r.ToModelName))
        }
        elseif ($toApp -and -not $toApp.IsEnabled) {
            New-HygieneFinding -CheckId 'DEP-03' -Severity Warning -Category 'Relationships' `
                -ObjectType 'Dependency' -ObjectId (& $modelOf $r.FromAppCIID) -ObjectName $pair `
                -Evidence ("Dependency target '{0}' is disabled; automatic dependency installs will fail." -f $r.ToAppName) `
                -Recommendation 'Enable the dependency target or remove the dependency.' `
                -FixScript ("Get-CMApplication -Name '{0}' -DisableWildcardHandling | Resume-CMApplication" -f (ConvertTo-HygQuotedLiteral $r.ToAppName))
        }
        elseif ($toApp -and -not $toApp.HasContent) {
            # ContentLocation is optional for script deployment types. This
            # is therefore an inventory signal, not proof that dependency
            # installation will fail or that DP distribution is missing.
            New-HygieneFinding -CheckId 'DEP-05' -Severity Info -Category 'Relationships' `
                -ObjectType 'Dependency' -ObjectId (& $modelOf $r.FromAppCIID) -ObjectName $pair `
                -Evidence ("Dependency target '{0}' reports HasContent=false. Contentless script deployment types can be valid, so this is not evidence of an installation or distribution failure." -f $r.ToAppName) `
                -Recommendation 'Verify the target has an enabled deployment type and that its install command does not require packaged source content.' `
                -FixScript ("# Review deployment types for '{0}'; no automatic remediation is safe for HasContent=false" -f (ConvertTo-HygQuotedLiteral $r.ToAppName))
        }
    }

    foreach ($e in (Find-HygCircularEdges -Edges $dep)) {
        New-HygieneFinding -CheckId 'DEP-02' -Severity Error -Category 'Relationships' `
            -ObjectType 'Dependency' -ObjectId (& $modelOf $e.FromAppCIID) -ObjectName ("'{0}' -> '{1}'" -f $e.FromAppName, $e.ToAppName) `
            -Evidence 'This dependency edge is part of a loop: the target eventually depends back on the source, which deadlocks automatic installs.' `
            -Recommendation 'Break the loop by removing one dependency in the cycle.' `
            -FixScript ("# Console: review the dependency chain starting at '{0}' and remove the looping reference" -f $e.FromAppName)
    }

    # REL-01: apps carrying relationships but no manufacturer metadata.
    $participants = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($r in $rels) {
        [void]$participants.Add([int]$r.FromAppCIID)
        if ([int]$r.ToAppCIID -ne 0) { [void]$participants.Add([int]$r.ToAppCIID) }
    }
    foreach ($ciid in $participants) {
        $app = $apps[[int]$ciid]
        if ($app -and [string]::IsNullOrWhiteSpace([string]$app.Manufacturer)) {
            New-HygieneFinding -CheckId 'REL-01' -Severity Info -Category 'Relationships' `
                -ObjectType 'Application' -ObjectId ([string]$app.ModelName) -ObjectName $app.Name `
                -Evidence 'Application participates in supersedence/dependency relationships but has no Manufacturer set, which makes relationship views hard to audit.' `
                -Recommendation 'Fill in the Manufacturer field. Run Fix is not offered: the site data does not hold the manufacturer name, and only a person knows it.' `
                -FixScript ("# Set the manufacturer in the console, or run: Set-CMApplication -Name '{0}' -DisableWildcardHandling -Publisher <manufacturer>" -f (ConvertTo-HygQuotedLiteral $app.Name))
        }
    }
}

function Build-HygRelationshipTree {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '', Justification='Build is approved from PowerShell 6; Windows PowerShell 5.1 does not list it. The name is part of the module interface.')]
    <#
    .SYNOPSIS
        Builds a nested node tree for one relationship kind, rooted at
        applications nothing of that kind points to. Pure over its input.

    .DESCRIPTION
        Node shape: Label, Glyph, AppCIID, Children[]. Glyphs: check for
        healthy, warn for disabled or content-less, x for missing or
        retired. A path-local visited set stops circular chains; MaxDepth
        bounds pathological graphs.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Named for the tree it builds.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'MaxDepth', Justification='Consumed inside the nested New-Node function through dynamic scope.')]
    param(
        [Parameter(Mandatory)]$RelationshipData,
        [Parameter(Mandatory)][ValidateSet('Supersedence', 'Dependency')][string]$Kind,
        [int]$MaxDepth = 12
    )

    $apps  = $RelationshipData.Apps
    $edges = @($RelationshipData.Relationships | Where-Object { $_.Kind -eq $Kind })

    $adj = @{}
    $targets = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($e in $edges) {
        $k = [int]$e.FromAppCIID
        if (-not $adj.ContainsKey($k)) { $adj[$k] = New-Object System.Collections.Generic.List[object] }
        $adj[$k].Add($e)
        if ([int]$e.ToAppCIID -ne 0) { [void]$targets.Add([int]$e.ToAppCIID) }
    }

    function Get-NodeGlyph {
        param($App, [bool]$Exists)
        if (-not $Exists -or -not $App) { return [char]0x2717 }
        if ($App.IsExpired) { return [char]0x2717 }
        if (-not $App.IsEnabled) { return [char]0x26A0 }
        if (-not $App.HasContent) { return [char]0x26A0 }
        return [char]0x2713
    }

    function New-Node {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Constructs an in-memory tree node; changes no system state.')]
        param([int]$CIID, [string]$FallbackLabel, [bool]$Exists, [int]$Depth, $Path)
        $app = if ($Exists) { $apps[[int]$CIID] } else { $null }
        $label = if ($app) {
            if ($app.SoftwareVersion) { '{0} ({1})' -f $app.Name, $app.SoftwareVersion } else { [string]$app.Name }
        } else { $FallbackLabel }

        $children = @()
        if ($Exists -and $Depth -lt $MaxDepth -and $adj.ContainsKey($CIID) -and -not $Path.Contains($CIID)) {
            [void]$Path.Add($CIID)
            foreach ($e in $adj[$CIID]) {
                if ([int]$e.ToAppCIID -ne 0 -and $Path.Contains([int]$e.ToAppCIID)) {
                    $children += [pscustomobject]@{
                        Label = ('{0} (circular reference)' -f $e.ToAppName)
                        Glyph = [char]0x2717
                        AppCIID = [int]$e.ToAppCIID
                        Children = @()
                    }
                    continue
                }
                $children += New-Node -CIID ([int]$e.ToAppCIID) -FallbackLabel ([string]$e.ToAppName) -Exists $e.ToAppExists -Depth ($Depth + 1) -Path $Path
            }
            [void]$Path.Remove($CIID)
        }

        return [pscustomobject]@{
            Label    = $label
            Glyph    = Get-NodeGlyph -App $app -Exists $Exists
            AppCIID  = [int]$CIID
            Children = @($children)
        }
    }

    $roots = @($adj.Keys | Where-Object { -not $targets.Contains([int]$_) } | Sort-Object { $apps[[int]$_].Name })
    # In a pure cycle every node is also a target; fall back to every edge
    # source so the loop still renders.
    if ($roots.Count -eq 0 -and $adj.Keys.Count -gt 0) { $roots = @($adj.Keys) }

    $nodes = foreach ($r in $roots) {
        New-Node -CIID ([int]$r) -FallbackLabel 'Unknown' -Exists $true -Depth 0 -Path (New-Object System.Collections.Generic.List[int])
    }
    return @($nodes)
}

function Get-HygRelationshipInventory {
    <#
    .SYNOPSIS
        One row per supersedence or dependency relationship, healthy rows
        included, with the status the SUP/DEP checks would assign. Pure
        over its input.

    .DESCRIPTION
        Status values: Healthy, Orphaned (target deleted), Expired Target,
        Disabled Source (supersedence), Disabled Target (dependency),
        Missing Content (dependency), with the same precedence as the
        SUP/DEP checks. Circular is a separate flag, because SUP-02 and
        DEP-02 report a loop in addition to whatever else the edge has;
        a row in a loop with nothing else wrong reads Status Circular.
        ChainDepth on a supersedence row is the number of further
        supersedence hops below the target; a loop below the target
        stops the count.

    .OUTPUTS
        [pscustomobject] Kind, Status, Circular, SourceName, SourceVersion,
        SourceDeploymentType, TargetName, TargetVersion, DependencyState,
        ChainDepth, SourceCIID, TargetCIID, TargetModelName.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns the full inventory by design.')]
    param([Parameter(Mandatory)]$RelationshipData)

    $apps = $RelationshipData.Apps
    $rels = @($RelationshipData.Relationships)
    $sup  = @($rels | Where-Object { $_.Kind -eq 'Supersedence' })
    $dep  = @($rels | Where-Object { $_.Kind -eq 'Dependency' })

    $circular = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($kindEdges in @($sup, $dep)) {
        foreach ($e in @(Find-HygCircularEdges -Edges $kindEdges)) {
            [void]$circular.Add(('{0}|{1}|{2}' -f $e.Kind, $e.FromAppCIID, $e.ToAppCIID))
        }
    }

    $supAdj = @{}
    foreach ($e in $sup) {
        $k = [int]$e.FromAppCIID
        if (-not $supAdj.ContainsKey($k)) { $supAdj[$k] = New-Object System.Collections.Generic.List[int] }
        if ([int]$e.ToAppCIID -ne 0) { $supAdj[$k].Add([int]$e.ToAppCIID) }
    }
    $depthCache = @{}
    $depthOf = $null
    $depthOf = {
        param([int]$Id, [hashtable]$OnPath)
        if ($depthCache.ContainsKey($Id)) { return $depthCache[$Id] }
        if ($OnPath.ContainsKey($Id)) { return 0 }
        $OnPath[$Id] = $true
        $max = 0
        if ($supAdj.ContainsKey($Id)) {
            foreach ($next in $supAdj[$Id]) {
                $d = 1 + (& $depthOf $next $OnPath)
                if ($d -gt $max) { $max = $d }
            }
        }
        [void]$OnPath.Remove($Id)
        $depthCache[$Id] = $max
        return $max
    }

    $versionOf = { param($ciid) $a = $apps[[int]$ciid]; if ($a) { [string]$a.SoftwareVersion } else { '' } }

    $rows = foreach ($r in $rels) {
        $toApp = $(if ($r.ToAppExists) { $apps[[int]$r.ToAppCIID] } else { $null })
        $fromApp = $apps[[int]$r.FromAppCIID]
        $isCircular = $circular.Contains(('{0}|{1}|{2}' -f $r.Kind, $r.FromAppCIID, $r.ToAppCIID))
        $status = 'Healthy'
        if (-not $r.ToAppExists) { $status = 'Orphaned' }
        elseif ($toApp -and $toApp.IsExpired) { $status = 'Expired Target' }
        elseif ($r.Kind -eq 'Supersedence' -and $fromApp -and -not $fromApp.IsEnabled) { $status = 'Disabled Source' }
        elseif ($r.Kind -eq 'Dependency' -and $toApp -and -not $toApp.IsEnabled) { $status = 'Disabled Target' }
        elseif ($r.Kind -eq 'Dependency' -and $toApp -and -not $toApp.HasContent) { $status = 'Missing Content' }
        if ($isCircular -and $status -eq 'Healthy') { $status = 'Circular' }

        $depth = 0
        if ($r.Kind -eq 'Supersedence' -and $r.ToAppExists) { $depth = & $depthOf ([int]$r.ToAppCIID) @{ ([int]$r.FromAppCIID) = $true } }

        [pscustomobject]@{
            Kind                 = [string]$r.Kind
            Status               = $status
            Circular             = [bool]$isCircular
            SourceName           = [string]$r.FromAppName
            SourceVersion        = (& $versionOf $r.FromAppCIID)
            SourceDeploymentType = [string]$r.FromDTName
            TargetName           = [string]$r.ToAppName
            TargetVersion        = (& $versionOf $r.ToAppCIID)
            DependencyState      = [string]$r.DependencyState
            ChainDepth           = [int]$depth
            SourceCIID           = [int]$r.FromAppCIID
            TargetCIID           = [int]$r.ToAppCIID
            TargetModelName      = [string]$r.ToModelName
        }
    }
    return @($rows | Sort-Object Kind, SourceName, TargetName)
}

function Test-HygAppContentPath {
    <#
    .SYNOPSIS
        APP-04: deployment-type content source folders that are missing or
        unreachable from this computer.

    .DESCRIPTION
        Probes each unique content location once with a bounded Test-Path.
        Unreachable can mean deleted source or no rights from here - the
        evidence says which app/DT so the operator can judge.
    #>
    param(
        [Parameter(Mandatory)]$RelationshipData,
        [int]$ProbeTimeoutMs = 3000
    )

    # Reap probes that finished stopping after an earlier timeout.
    $script:AppContentProbeGraveyard = @(Stop-SuiteBgWork -PowerShell $null -Timer $null -Graveyard $script:AppContentProbeGraveyard)
    $checked = @{}
    # The model name keeps the finding key stable; a CI_ID changes with
    # each application revision.
    $appLookup = $RelationshipData.PSObject.Properties['Apps']
    $appIdOf = { param($ciid) $a = $(if ($appLookup -and $appLookup.Value) { $appLookup.Value[[int]$ciid] }); if ($a -and $a.ModelName) { [string]$a.ModelName } else { [string]$ciid } }
    foreach ($loc in @($RelationshipData.ContentLocations)) {
        $path = [string]$loc.Location
        if (-not $checked.ContainsKey($path)) {
            # Probe on a worker pipeline with a real timeout: Test-Path
            # against a stalled SMB endpoint blocks for the TCP timeout and
            # would hang the scan. Timed out means Unknown, never missing.
            $state = 'Missing'
            $probe = [powershell]::Create()
            [void]$probe.AddScript({ param($p) try { Test-Path -LiteralPath $p -ErrorAction Stop } catch { $false } }).AddArgument($path)
            $handle = $probe.BeginInvoke()
            if ($handle.AsyncWaitHandle.WaitOne($ProbeTimeoutMs)) {
                $ok = [bool]($probe.EndInvoke($handle) | Select-Object -First 1)
                if ($ok) { $state = 'Ok' }
                $probe.Dispose()
            }
            else {
                # BeginStop remains non-blocking even when Test-Path is stuck
                # in an SMB call. Retain and reap the pipeline later rather
                # than abandoning an undisposed PowerShell/runspace object.
                $script:AppContentProbeGraveyard = @(Stop-SuiteBgWork -PowerShell $probe -Timer $null -Graveyard $script:AppContentProbeGraveyard)
                $state = 'Unknown'
            }
            $checked[$path] = $state
        }
        if ($checked[$path] -eq 'Ok') { continue }

        if ($checked[$path] -eq 'Unknown') {
            New-HygieneFinding -CheckId 'APP-04' -Severity Info -Category 'Applications' `
                -ObjectType 'DeploymentType' -ObjectId (& $appIdOf $loc.AppCIID) -ObjectName ("{0} / {1}" -f $loc.AppName, $loc.DTName) `
                -Evidence ("Content source '{0}' did not answer within {1}s from this computer; its state is unknown, not missing." -f $path, [int]($ProbeTimeoutMs / 1000)) `
                -Recommendation 'Probe the path from the site server, where rights and routes may differ.' `
                -FixScript ("# From the site server: Test-Path -LiteralPath '{0}'" -f (ConvertTo-HygQuotedLiteral $path))
        }
        else {
            New-HygieneFinding -CheckId 'APP-04' -Severity Warning -Category 'Applications' `
                -ObjectType 'DeploymentType' -ObjectId (& $appIdOf $loc.AppCIID) -ObjectName ("{0} / {1}" -f $loc.AppName, $loc.DTName) `
                -Evidence ("Content source '{0}' is missing or unreachable from this computer; the site server may still reach it, but content updates run from a session that cannot will fail." -f $path) `
                -Recommendation 'Verify from the site server; restore the source folder, correct the deployment type content location, or fix share permissions.' `
                -FixScript ("# Console: '{0}' > Deployment Types > '{1}' > Content - correct the content location" -f $loc.AppName, $loc.DTName)
        }
    }
}

# ---------------------------------------------------------------------------
# Collection evaluation run time (COL-04)
# ---------------------------------------------------------------------------

function Test-HygCollectionEvaluationRunTime {
    <#
    .SYNOPSIS
        COL-04: collections whose last full or incremental evaluation ran
        longer than the threshold, slowest first. One finding per
        collection so the suppression key stays stable when both
        evaluation types are slow.
    #>
    param(
        [Parameter(Mandatory)]$Data,
        [hashtable]$Thresholds = (Get-HygieneDefaultThresholds)
    )

    $limit = [long]$Thresholds.ColEvalSlowMs
    $slow = @{}
    foreach ($pair in @(@{ Kind = 'full'; Rows = $Data.CollectionEvalFull }, @{ Kind = 'incremental'; Rows = $Data.CollectionEvalIncremental })) {
        foreach ($row in @($pair.Rows)) {
            if (-not $row -or $row.LengthMs -le $limit) { continue }
            $id = [string]$row.CollectionID
            if (-not $slow.ContainsKey($id)) { $slow[$id] = [pscustomobject]@{ CollectionID = $id; Name = $row.Name; WorstMs = 0; Parts = @() } }
            $entry = $slow[$id]
            if ($row.LengthMs -gt $entry.WorstMs) { $entry.WorstMs = $row.LengthMs }
            $changeText = $(if ($row.MemberChanges -eq 0) { 'no membership change' } else { "$($row.MemberChanges) membership change(s)" })
            $entry.Parts += ("last {0} evaluation ran {1:n1}s with {2}" -f $pair.Kind, ($row.LengthMs / 1000), $changeText)
        }
    }

    foreach ($entry in ($slow.Values | Sort-Object WorstMs -Descending)) {
        New-HygieneFinding -CheckId 'COL-04' -Severity Warning -Category 'Collections' `
            -ObjectType 'Collection' -ObjectId $entry.CollectionID -ObjectName $entry.Name `
            -Evidence ("{0} (threshold {1:n1}s). Evaluations run one at a time per queue, so a slow collection delays every collection queued behind it." -f (($entry.Parts -join '; ') -replace '^l', 'L'), ($limit / 1000)) `
            -Recommendation 'Review the membership query: avoid LIKE wildcards and nested subselects on large classes, limit to the smallest suitable collection, and drop incremental updates where membership rarely changes.' `
            -FixScript ("# Review: (Get-CMCollection -Id '{0}').CollectionRules | Select-Object RuleName, QueryExpression" -f $entry.CollectionID)
    }
}

# ---------------------------------------------------------------------------
# Content distribution (CNT-01..CNT-03)
# ---------------------------------------------------------------------------

function Test-HygContentDistribution {
    <#
    .SYNOPSIS
        CNT-01..CNT-03: content failed on distribution points, content in
        progress beyond the threshold, and deployed content targeted to no
        distribution point.

    .DESCRIPTION
        Reads the per-content summary counts only. Fix scripts are
        display-only: redistribution needs a distribution point choice
        this data does not carry.
    #>
    param(
        [Parameter(Mandatory)]$Data,
        [hashtable]$Thresholds = (Get-HygieneDefaultThresholds)
    )

    $typeNames = @{ 0 = 'Package'; 3 = 'DriverPackage'; 4 = 'TaskSequence'; 5 = 'UpdatePackage'; 257 = 'OSImage'; 258 = 'BootImage'; 259 = 'OSUpgradePackage'; 512 = 'Application' }
    $typeOf = { param($row) if ($typeNames.ContainsKey([int]$row.ObjectType)) { $typeNames[[int]$row.ObjectType] } else { 'Content' } }
    $rows = @($Data.ContentStatus)
    $stuckDays = [int]$Thresholds.ContentStuckDays
    $cutoff = (Get-Date).AddDays(-$stuckDays)

    foreach ($row in $rows) {
        if ($row.NumberErrors -gt 0) {
            New-HygieneFinding -CheckId 'CNT-01' -Severity Warning -Category 'Content' `
                -ObjectType (& $typeOf $row) -ObjectId $row.PackageID -ObjectName $row.Name `
                -Evidence ("Distribution failed on {0} of {1} targeted distribution point(s) ({2} succeeded, {3} in progress). Clients in the boundaries those distribution points serve fall back to another source or fail with content not found." -f $row.NumberErrors, $row.Targeted, $row.NumberSuccess, $row.NumberInProgress) `
                -Recommendation 'Review the failed distribution points under Monitoring > Distribution Status > Content Status, fix the cause, then redistribute.' `
                -FixScript ("# Console: Monitoring > Distribution Status > Content Status > '{0}' ({1}) > View Status > Error > Redistribute" -f $row.Name, $row.PackageID)
        }
        elseif ($row.NumberInProgress -gt 0 -and $row.LastUpdateDate -and ([datetime]$row.LastUpdateDate) -lt $cutoff) {
            New-HygieneFinding -CheckId 'CNT-02' -Severity Info -Category 'Content' `
                -ObjectType (& $typeOf $row) -ObjectId $row.PackageID -ObjectName $row.Name `
                -Evidence ("Distribution is still in progress on {0} of {1} targeted distribution point(s), and the content was last updated {2:yyyy-MM-dd}, more than {3} day(s) ago. A transfer that old is usually stalled, not slow." -f $row.NumberInProgress, $row.Targeted, ([datetime]$row.LastUpdateDate), $stuckDays) `
                -Recommendation 'Check the in-progress distribution points for a stalled transfer or an offline server; cancel and redistribute if nothing is moving.' `
                -FixScript ("# Console: Monitoring > Distribution Status > Content Status > '{0}' ({1}) > View Status > In Progress" -f $row.Name, $row.PackageID)
        }
    }

    # CNT-03: something is deployed, it has source content, and no
    # distribution point is targeted. SourceSize 0 covers content-less
    # script deployment types, which legitimately target nothing.
    $undistributed = @($rows | Where-Object { $_.Targeted -eq 0 -and $_.SourceSize -gt 0 })
    if ($undistributed.Count -eq 0) { return }

    $deployedModels = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($a in @($Data.Applications)) { if ($a.IsDeployed -and -not $a.IsExpired -and $a.ModelName) { [void]$deployedModels.Add([string]$a.ModelName) } }
    # FeatureType 2 = program deployment; its PackageID is the package id.
    $deployedPackages = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($d in @($Data.Deployments)) { if ($d.FeatureType -eq 2 -and $d.PackageID) { [void]$deployedPackages.Add([string]$d.PackageID) } }

    foreach ($row in $undistributed) {
        $isDeployed = ($row.ObjectType -eq 512 -and $deployedModels.Contains([string]$row.ObjectID)) -or
                      ($row.ObjectType -eq 0 -and $deployedPackages.Contains([string]$row.PackageID))
        if (-not $isDeployed) { continue }
        New-HygieneFinding -CheckId 'CNT-03' -Severity Error -Category 'Content' `
            -ObjectType (& $typeOf $row) -ObjectId $row.PackageID -ObjectName $row.Name `
            -Evidence 'This content has an active deployment and source files, but it is targeted to no distribution point. Every client that tries to install it fails to locate content.' `
            -Recommendation 'Distribute the content to the distribution point groups that serve the deployment''s collection.' `
            -FixScript ("# Console: Software Library > '{0}' > Distribute Content - choose the distribution point group(s) for the targeted clients" -f $row.Name)
    }
}

# ---------------------------------------------------------------------------
# Deployment targeting and disabled deployed objects (DPL-04, DPL-05)
# ---------------------------------------------------------------------------

function Test-HygDeploymentBroadRequired {
    <#
    .SYNOPSIS
        DPL-04: required deployments that target a built-in all-resources
        collection. DeploymentIntent 1 = required.
    #>
    param([Parameter(Mandatory)]$Data)

    # The remaining all-resources collections match by name plus the
    # built-in id prefix, so a custom collection of the same name never
    # matches. All Unknown Computers is left out: a required task sequence
    # to it is the normal bare-metal deployment.
    $broadIds = @{ 'SMS00001' = 'All Systems'; 'SMS00002' = 'All Users'; 'SMSDM003' = 'All Desktop and Server Clients' }
    $broadNames = 'All Systems', 'All Users', 'All User Groups', 'All Users and User Groups', 'All Desktop and Server Clients'
    foreach ($d in @($Data.Deployments)) {
        if ($d.DeploymentIntent -ne 1) { continue }
        $id = ([string]$d.CollectionID).ToUpperInvariant()
        $name = $null
        if ($broadIds.ContainsKey($id)) { $name = $broadIds[$id] }
        elseif ($id -like 'SMS*' -and $broadNames -contains [string]$d.CollectionName) { $name = [string]$d.CollectionName }
        if (-not $name) { continue }
        New-HygieneFinding -CheckId 'DPL-04' -Severity Warning -Category 'Deployments' `
            -ObjectType 'Deployment' -ObjectId ("{0}|{1}" -f $d.SoftwareName, $id) -ObjectName ("{0} -> {1}" -f $d.SoftwareName, $name) `
            -Evidence ("Required deployment of '{0}' targets the built-in collection '{1}' ({2}). Every current and future resource in the site receives it, with no pilot group and no way to exclude a resource." -f $d.SoftwareName, $name, $id) `
            -Recommendation 'Re-target the deployment to a custom collection limited to the intended resources, then remove this deployment.' `
            -FixScript ("# Review first: Get-CMDeployment -CollectionName '{0}' | Where-Object SoftwareName -eq '{1}'" -f $name, (ConvertTo-HygQuotedLiteral $d.SoftwareName))
    }
}

function Test-HygDeployedDisabledObject {
    <#
    .SYNOPSIS
        DPL-05: deployments whose task sequence or program is disabled.
        ProgramFlags bit 12 (0x1000) = DISABLED. FeatureType 2 = program,
        7 = task sequence; PackageID carries the package id for both.
    #>
    param([Parameter(Mandatory)]$Data)

    $disabledFlag = 0x1000
    $disabledTs = @{}
    foreach ($ts in @(Get-HygLiveTaskSequence -Data $Data)) {
        if ($ts.PSObject.Properties['ProgramFlags'] -and (([long]$ts.ProgramFlags) -band $disabledFlag)) { $disabledTs[[string]$ts.PackageID] = $ts.Name }
    }
    $disabledPrograms = @{}
    foreach ($p in @($Data.Programs)) {
        if ($p.PSObject.Properties['ProgramFlags'] -and (([long]$p.ProgramFlags) -band $disabledFlag)) { $disabledPrograms[("{0}|{1}" -f $p.PackageID, $p.ProgramName)] = $true }
    }

    foreach ($d in @($Data.Deployments)) {
        $pkg = [string]$d.PackageID
        if (-not $pkg) { continue }
        $what = $null
        if ($d.FeatureType -eq 7 -and $disabledTs.ContainsKey($pkg)) { $what = "task sequence '$($disabledTs[$pkg])'" }
        elseif ($d.FeatureType -eq 2 -and $d.PSObject.Properties['ProgramName'] -and $disabledPrograms.ContainsKey(("{0}|{1}" -f $pkg, $d.ProgramName))) { $what = "program '$($d.ProgramName)' of package $pkg" }
        if (-not $what) { continue }
        New-HygieneFinding -CheckId 'DPL-05' -Severity Warning -Category 'Deployments' `
            -ObjectType 'Deployment' -ObjectId ("{0}|{1}" -f $pkg, $d.CollectionID) -ObjectName ("{0} -> {1}" -f $d.SoftwareName, $d.CollectionName) `
            -Evidence ("The deployment to '{0}' runs the {1}, which is disabled. Clients receive the policy and never run it." -f $d.CollectionName, $what) `
            -Recommendation 'Enable the object if the deployment is still wanted; otherwise remove the deployment.' `
            -FixScript ("# Review: Get-CMDeployment -CollectionName '{0}' | Where-Object PackageID -eq '{1}'" -f (ConvertTo-HygQuotedLiteral $d.CollectionName), $pkg)
    }
}

# ---------------------------------------------------------------------------
# Software update group size and expired package content (UPD-04, UPD-05)
# ---------------------------------------------------------------------------

function Test-HygUpdateGroupSize {
    <#
    .SYNOPSIS
        UPD-04: software update groups over the documented limit of
        updates in one deployment.
    #>
    param(
        [Parameter(Mandatory)]$Data,
        [hashtable]$Thresholds = (Get-HygieneDefaultThresholds)
    )

    $max = [int]$Thresholds.SugMaxUpdates
    foreach ($sug in @($Data.UpdateGroups)) {
        if ($sug.NumberOfUpdates -le $max) { continue }
        New-HygieneFinding -CheckId 'UPD-04' -Severity Warning -Category 'Updates' `
            -ObjectType 'UpdateGroup' -ObjectId ([string]$sug.CI_ID) -ObjectName $sug.Name `
            -Evidence ("The group holds {0} updates; a software update deployment supports at most {1}. A deployment of this group fails or cannot be created." -f $sug.NumberOfUpdates, $max) `
            -Recommendation 'Split the group, for example by year or product, and remove expired and superseded members.' `
            -FixScript ("# Console: Software Library > Software Update Groups > '{0}' - split the membership" -f $sug.Name)
    }
}

function Test-HygUpdatePackageExpiredContent {
    <#
    .SYNOPSIS
        UPD-05: deployment packages that still hold content for expired
        updates. Joins expired update ids to downloaded content ids to
        package content ids in memory.
    #>
    param([Parameter(Mandatory)]$Data)

    $expired = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($id in @($Data.ExpiredUpdateIds)) { [void]$expired.Add([int]$id) }
    if ($expired.Count -eq 0) { return }

    $expiredContent = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($row in @($Data.UpdateContentMap)) { if ($row -and $expired.Contains([int]$row.CI_ID)) { [void]$expiredContent.Add([int]$row.ContentID) } }

    $perPackage = @{}
    $totals = @{}
    foreach ($row in @($Data.UpdatePackageContent)) {
        if (-not $row) { continue }
        $pkg = [string]$row.PackageID
        $totals[$pkg] = 1 + [int]$totals[$pkg]
        if ($expiredContent.Contains([int]$row.ContentID)) { $perPackage[$pkg] = 1 + [int]$perPackage[$pkg] }
    }

    $names = @{}
    foreach ($p in @($Data.UpdatePackages)) { $names[[string]$p.PackageID] = $p.Name }
    foreach ($pkg in ($perPackage.Keys | Sort-Object { $perPackage[$_] } -Descending)) {
        $name = $(if ($names.ContainsKey($pkg)) { $names[$pkg] } else { $pkg })
        New-HygieneFinding -CheckId 'UPD-05' -Severity Info -Category 'Updates' `
            -ObjectType 'UpdatePackage' -ObjectId $pkg -ObjectName $name `
            -Evidence ("{0} of {1} content item(s) in the package belong to expired updates. The files stay in the package source and on every distribution point that holds the package." -f $perPackage[$pkg], $totals[$pkg]) `
            -Recommendation 'Remove the expired updates from the package, or let the site remove them: expired updates leave packages only when no deployment references them.' `
            -FixScript ("# Console: Software Library > Deployment Packages > '{0}' > Show Members - remove expired updates, then refresh distribution points" -f $name)
    }
}

# ---------------------------------------------------------------------------
# Distribution points (DPT-01, DPT-02)
# ---------------------------------------------------------------------------

function Test-HygDistributionPointChecks {
    <#
    .SYNOPSIS
        DPT-01: distribution points in no boundary group. DPT-02:
        distribution point groups with no members.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Runs the distribution point check family by design.')]
    param([Parameter(Mandatory)]$Data)

    $inGroup = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($row in @($Data.BoundaryGroupSiteSystems)) { if ($row) { [void]$inGroup.Add([string]$row) } }

    foreach ($dp in @($Data.DistributionPoints)) {
        if (-not $dp -or $inGroup.Contains([string]$dp.NALPath)) { continue }
        New-HygieneFinding -CheckId 'DPT-01' -Severity Warning -Category 'Distribution Points' `
            -ObjectType 'DistributionPoint' -ObjectId ([string]$dp.NALPath) -ObjectName $dp.Name `
            -Evidence 'The distribution point is a site system of no boundary group. Clients select content sources through boundary groups, so no client selects this server except through the default site boundary group fallback.' `
            -Recommendation 'Add the distribution point to the boundary group(s) for the locations it serves, or remove the role if the server is retired.' `
            -FixScript ("# Set-CMBoundaryGroup -Name '<boundary group>' -AddSiteSystemServerName '{0}'" -f $dp.Name)
    }

    foreach ($g in @($Data.DistributionPointGroups)) {
        if (-not $g -or $g.MembersCount -ne 0) { continue }
        New-HygieneFinding -CheckId 'DPT-02' -Severity Info -Category 'Distribution Points' `
            -ObjectType 'DistributionPointGroup' -ObjectId ([string]$g.GroupID) -ObjectName $g.Name `
            -Evidence ("The distribution point group has no members and {0} content item(s) assigned. Content distributed to it reaches no server." -f $g.AssignedContentCount) `
            -Recommendation 'Add the intended distribution points, or delete the group.' `
            -FixScript ("# Review: Get-CMDistributionPointGroup -Name '{0}'" -f (ConvertTo-HygQuotedLiteral $g.Name))
    }
}

# ---------------------------------------------------------------------------
# Compliance settings and client settings (CFG-01..CFG-03)
# ---------------------------------------------------------------------------

function Test-HygComplianceChecks {
    <#
    .SYNOPSIS
        CFG-01: configuration baselines deployed nowhere. CFG-02:
        configuration items no baseline references. CFG-03: custom client
        settings deployed to no collection.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Runs the compliance check family by design.')]
    param([Parameter(Mandatory)]$Data)

    foreach ($b in @($Data.Baselines)) {
        # InUse: another baseline references this one, which deploys it
        # indirectly.
        if (-not $b -or -not $b.IsUserDefined -or $b.IsAssigned -or $b.InUse) { continue }
        New-HygieneFinding -CheckId 'CFG-01' -Severity Info -Category 'Compliance' `
            -ObjectType 'Baseline' -ObjectId $(if ($b.ModelName) { [string]$b.ModelName } else { [string]$b.CI_ID }) -ObjectName $b.Name `
            -Evidence 'The configuration baseline has no deployment and no other baseline references it. No client evaluates it.' `
            -Recommendation 'Deploy the baseline, or delete it if it is no longer needed.' `
            -FixScript ("# Review: Get-CMBaseline -Id {0} -Fast" -f $b.CI_ID)
    }

    foreach ($ci in @($Data.ConfigurationItems)) {
        # Items the product ships are not the administrator's to clean up.
        if (-not $ci -or -not $ci.IsUserDefined -or $ci.InUse) { continue }
        New-HygieneFinding -CheckId 'CFG-02' -Severity Info -Category 'Compliance' `
            -ObjectType 'ConfigurationItem' -ObjectId $(if ($ci.ModelName) { [string]$ci.ModelName } else { [string]$ci.CI_ID }) -ObjectName $ci.Name `
            -Evidence 'No configuration baseline references this configuration item. No client evaluates it.' `
            -Recommendation 'Add the item to a baseline, or delete it if it is no longer needed.' `
            -FixScript ("# Review: Get-CMConfigurationItem -Id {0} -Fast" -f $ci.CI_ID)
    }

    foreach ($s in @($Data.ClientSettings)) {
        if (-not $s -or $s.AssignmentCount -ne 0) { continue }
        New-HygieneFinding -CheckId 'CFG-03' -Severity Info -Category 'Compliance' `
            -ObjectType 'ClientSettings' -ObjectId ([string]$s.SettingsID) -ObjectName $s.Name `
            -Evidence 'The custom client settings object is deployed to no collection. It applies to no client.' `
            -Recommendation 'Deploy the settings to the intended collection, or delete them.' `
            -FixScript ("# Review: Get-CMClientSetting -Name '{0}'" -f (ConvertTo-HygQuotedLiteral $s.Name))
    }
}

# ---------------------------------------------------------------------------
# Drivers (DRV-01)
# ---------------------------------------------------------------------------

function Test-HygDriverUnpackaged {
    <#
    .SYNOPSIS
        DRV-01: drivers that belong to no driver package and no boot image.
    #>
    param([Parameter(Mandatory)]$Data)

    $contained = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($id in @($Data.DriverContainerIds)) { [void]$contained.Add([int]$id) }
    foreach ($drv in @($Data.Drivers)) {
        if (-not $drv -or $contained.Contains([int]$drv.CI_ID)) { continue }
        New-HygieneFinding -CheckId 'DRV-01' -Severity Info -Category 'Drivers' `
            -ObjectType 'Driver' -ObjectId ([string]$drv.CI_ID) -ObjectName $drv.Name `
            -Evidence 'The driver is in the catalog but in no driver package and no boot image. A task sequence can install a driver only from a driver package on a distribution point.' `
            -Recommendation 'Add the driver to a driver package, or delete it from the catalog.' `
            -FixScript ("# Review: Get-CMDriver -Id {0} -Fast" -f $drv.CI_ID)
    }
}

# ---------------------------------------------------------------------------
# Administrative users (SEC-01)
# ---------------------------------------------------------------------------

function Test-HygAdminDeletedAccount {
    <#
    .SYNOPSIS
        SEC-01: administrative users whose Active Directory account the
        site reports as deleted.
    #>
    param([Parameter(Mandatory)]$Data)

    foreach ($a in @($Data.AdminUsers)) {
        if (-not $a -or -not $a.IsDeleted) { continue }
        $roles = $(if (@($a.RoleNames).Count -gt 0) { @($a.RoleNames) -join ', ' } else { 'none recorded' })
        New-HygieneFinding -CheckId 'SEC-01' -Severity Warning -Category 'Security' `
            -ObjectType 'AdministrativeUser' -ObjectId ([string]$a.AdminID) -ObjectName $a.LogonName `
            -Evidence ("The site reports that the Active Directory account for this administrative user is deleted. Roles: {0}." -f $roles) `
            -Recommendation 'Remove the administrative user from the site.' `
            -FixScript ("# Review, then remove: Get-CMAdministrativeUser -Name '{0}'" -f (ConvertTo-HygQuotedLiteral $a.LogonName))
    }
}

# ---------------------------------------------------------------------------
# Maintenance windows (COL-10)
# ---------------------------------------------------------------------------

function Test-HygMaintenanceWindowExpired {
    <#
    .SYNOPSIS
        COL-10: one-time maintenance windows that ended in the past.
        RecurrenceType 1 = no recurrence. One day of grace covers windows
        whose start time is recorded in UTC.
    #>
    param([Parameter(Mandatory)]$Data)

    $names = @{}
    foreach ($c in @($Data.Collections)) { $names[[string]$c.CollectionID] = $c.Name }
    $now = Get-Date
    foreach ($w in @($Data.MaintenanceWindows)) {
        if (-not $w -or $w.RecurrenceType -ne 1 -or -not $w.StartTime) { continue }
        $end = ([datetime]$w.StartTime).AddMinutes([int]$w.Duration)
        if ($end.AddDays(1) -ge $now) { continue }
        $colName = $(if ($names.ContainsKey([string]$w.CollectionID)) { $names[[string]$w.CollectionID] } else { [string]$w.CollectionID })
        New-HygieneFinding -CheckId 'COL-10' -Severity Info -Category 'Collections' `
            -ObjectType 'MaintenanceWindow' -ObjectId ("{0}|{1}" -f $w.CollectionID, $w.Name) -ObjectName ("{0} on {1}" -f $w.Name, $colName) `
            -Evidence ("The one-time maintenance window ended {0:yyyy-MM-dd HH:mm} and never recurs. A collection with any maintenance window, including an expired one, blocks required deployments outside a window." -f $end) `
            -Recommendation 'Delete the expired window. If the collection needs no window at all, delete every window on it.' `
            -FixScript ("Remove-CMMaintenanceWindow -CollectionId '{0}' -MaintenanceWindowName '{1}' -DisableWildcardHandling -Force" -f (ConvertTo-HygQuotedLiteral $w.CollectionID), (ConvertTo-HygQuotedLiteral $w.Name))
    }
}

# ---------------------------------------------------------------------------
# Scan orchestration
# ---------------------------------------------------------------------------

function Invoke-HygieneScan {
    <#
    .SYNOPSIS
        Runs the checks the selected scopes cover over a prefetched dataset
        and returns findings sorted by severity, then check id, then object
        name.

    .DESCRIPTION
        Pure over its input: pass real data from Get-HygieneData or
        synthetic data of the same shape. A check that throws is recorded
        as a finding against the scan itself rather than aborting the run.

    .PARAMETER Scopes
        Scope ids from Get-HygieneScanScope. Omitted or empty runs every
        check.
    #>
    param(
        [Parameter(Mandatory)]$Data,
        [hashtable]$Thresholds = (Get-HygieneDefaultThresholds),
        $RelationshipData = $null,
        [string[]]$Scopes
    )

    $picked = @(Resolve-HygScanScope -Scopes $Scopes)
    $checks = @(Get-HygScanPlan | Where-Object { @($_.Scopes | Where-Object { $_ -in $picked }).Count -gt 0 })
    if (-not $RelationshipData) {
        if (@($checks | Where-Object { $_.NeedsRelationships }).Count -gt 0) {
            Write-Log 'Relationship data not collected; SUP/DEP/REL and APP-04 checks skipped this scan.' -Level WARN
        }
        $checks = @($checks | Where-Object { -not $_.NeedsRelationships })
    }

    # Synthetic fixtures may predate FailedDatasets; absent means none.
    $failedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $fp = $Data.PSObject.Properties['FailedDatasets']
    if ($fp -and $fp.Value) { foreach ($k in @($fp.Value)) { [void]$failedSet.Add([string]$k) } }
    $notCollectedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $np = $Data.PSObject.Properties['NotCollectedDatasets']
    if ($np -and $np.Value) { foreach ($k in @($np.Value)) { [void]$notCollectedSet.Add([string]$k) } }

    $findings = New-Object System.Collections.Generic.List[object]
    foreach ($check in $checks) {
        # A dataset left out of the prefetch on purpose is a scope mismatch,
        # not a site problem: no finding, but the check still must not run.
        $outOfScope = @(@($check.Requires) | Where-Object { $notCollectedSet.Contains($_) })
        if ($outOfScope.Count -gt 0) {
            Write-Log ("Check {0} skipped: dataset(s) {1} not collected for this scan scope" -f $check.Id, ($outOfScope -join ', ')) -Level WARN
            continue
        }
        $missing = @(@($check.Requires) | Where-Object { $failedSet.Contains($_) })
        if ($missing.Count -gt 0) {
            Write-Log ("Check {0} skipped: dataset(s) {1} unavailable" -f $check.Id, ($missing -join ', ')) -Level WARN
            $findings.Add((New-HygieneFinding -CheckId $check.Id -Severity Info -Category 'Scan' `
                -ObjectType 'Check' -ObjectName ("Check {0} skipped" -f $check.Id) `
                -Evidence ("Dataset(s) {0} could not be collected this scan; running the check over incomplete input would fabricate evidence." -f ($missing -join ', ')) `
                -Recommendation 'Fix the dataset error (see the scan log for the query failure) and rescan.'))
            continue
        }
        try {
            foreach ($f in @(& $check.Run $Data $Thresholds $RelationshipData)) {
                if ($f) { $findings.Add($f) }
            }
        }
        catch {
            Write-Log ("Check {0} failed: {1}" -f $check.Id, $_.Exception.Message) -Level WARN -Quiet
            Write-Log ('Check {0} failed. The log file has the details.' -f $check.Id) -Level WARN
            $findings.Add((New-HygieneFinding -CheckId $check.Id -Severity Warning -Category 'Scan' `
                -ObjectType 'Check' -ObjectName ("Check {0} did not run" -f $check.Id) `
                -Evidence ("The check itself failed: {0}" -f $_.Exception.Message) `
                -Recommendation 'Findings from this check are missing from the results; the failure is a defect worth reporting.'))
        }
    }

    $severityRank = @{ 'Error' = 0; 'Warning' = 1; 'Info' = 2 }
    $sorted = @($findings | Sort-Object -Property @{ Expression = { $severityRank[$_.Severity] } }, CheckId, ObjectName)
    Write-Log ("Hygiene scan produced {0} finding(s)" -f $sorted.Count)
    # Emit unrolled: callers rebuild with @(...) and a wrapped return would
    # hand them a single array element instead of N findings.
    return $sorted
}

function Get-HygieneScanSummary {
    <#
    .SYNOPSIS
        Aggregates findings into per-check rows for the Summary view.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings
    )

    $byCheck = @{}
    foreach ($f in $Findings) {
        if (-not $byCheck.ContainsKey($f.CheckId)) { $byCheck[$f.CheckId] = 0 }
        $byCheck[$f.CheckId]++
    }

    $rows = foreach ($check in (Get-HygieneCheckCatalog)) {
        $count = 0
        if ($byCheck.ContainsKey($check.Id)) { $count = $byCheck[$check.Id] }
        [pscustomobject]@{
            CheckId  = $check.Id
            Severity = $check.Severity
            Category = $check.Category
            Title    = $check.Title
            Findings = $count
        }
    }
    return @($rows)
}

function Get-HygieneSuppressionKey {
    <#
    .SYNOPSIS
        Stable identity for a finding, used by the suppression list and
        rescan comparisons.
    #>
    param(
        [Parameter(Mandatory)]$Finding
    )
    return '{0}|{1}|{2}|{3}' -f $Finding.CheckId, $Finding.ObjectType, $Finding.ObjectId, $Finding.ObjectName
}

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------

function Export-HygieneCsv {
    <#
    .SYNOPSIS
        Exports findings to CSV.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings,
        [Parameter(Mandatory)][string]$OutputPath
    )

    $parentDir = Split-Path -Path $OutputPath -Parent
    if ($parentDir -and -not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    $Findings |
        Select-Object CheckId, Severity, Category, ObjectType, ObjectId, ObjectName, Evidence, Recommendation, FixScript |
        Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Log "Exported CSV to $OutputPath"
}

function Export-HygieneHtml {
    <#
    .SYNOPSIS
        Exports findings to a self-contained HTML report with
        severity-coded rows.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings,
        [Parameter(Mandatory)][string]$OutputPath,
        [string]$ReportTitle = 'Site Hygiene Report'
    )

    $parentDir = Split-Path -Path $OutputPath -Parent
    if ($parentDir -and -not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    $css = @(
        '<style>',
        'body { font-family: "Segoe UI", Arial, sans-serif; margin: 20px; background: #fafafa; }',
        'h1 { color: #0078D4; margin-bottom: 4px; }',
        '.summary { color: #555; margin-bottom: 16px; }',
        'table { border-collapse: collapse; width: 100%; margin-top: 12px; }',
        'th { background: #0078D4; color: #fff; padding: 8px 12px; text-align: left; }',
        'td { padding: 6px 12px; border-bottom: 1px solid #e0e0e0; vertical-align: top; }',
        'tr:nth-child(even) { background: #f5f5f5; }',
        '.sev-Error { color: #c00; font-weight: bold; }',
        '.sev-Warning { color: #b87800; font-weight: bold; }',
        '.sev-Info { color: #228b22; }',
        'code { font-family: Consolas, monospace; font-size: 0.9em; }',
        '</style>'
    ) -join "`r`n"

    $encode = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }

    $bodyRows = foreach ($f in $Findings) {
        $cells = @(
            ('<td class="sev-{0}">{0}</td>' -f (& $encode $f.Severity)),
            ('<td>{0}</td>' -f (& $encode $f.CheckId)),
            ('<td>{0}</td>' -f (& $encode $f.Category)),
            ('<td>{0}</td>' -f (& $encode $f.ObjectName)),
            ('<td>{0}</td>' -f (& $encode $f.Evidence)),
            ('<td>{0}</td>' -f (& $encode $f.Recommendation)),
            ('<td><code>{0}</code></td>' -f (& $encode $f.FixScript))
        )
        "<tr>$($cells -join '')</tr>"
    }

    $counts = @($Findings | Group-Object Severity | ForEach-Object { "{0} {1}" -f $_.Count, $_.Name }) -join ', '
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $html = @(
        '<!DOCTYPE html>',
        '<html><head><meta charset="utf-8"><title>' + (& $encode $ReportTitle) + '</title>',
        $css,
        '</head><body>',
        ('<h1>{0}</h1>' -f (& $encode $ReportTitle)),
        ('<div class="summary">Generated: {0} | Findings: {1}{2}</div>' -f $timestamp, @($Findings).Count, $(if ($counts) { " ($counts)" } else { '' })),
        '<table><thead><tr><th>Severity</th><th>Check</th><th>Category</th><th>Object</th><th>Evidence</th><th>Recommendation</th><th>Fix script</th></tr></thead>',
        "<tbody>$($bodyRows -join "`r`n")</tbody></table>",
        '</body></html>'
    ) -join "`r`n"

    Set-Content -LiteralPath $OutputPath -Value $html -Encoding UTF8
    Write-Log "Exported HTML to $OutputPath"
}

function New-HygieneSummaryText {
    <#
    .SYNOPSIS
        Plain-text scan summary for clipboard or log.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Builds a string; changes no system state.')]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings,
        [string[]]$DatasetNotes = @()
    )

    $lines = @()
    $lines += '=== Site Hygiene Summary ==='
    $lines += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += ''
    $lines += "Total findings: $(@($Findings).Count)"
    foreach ($group in ($Findings | Group-Object Severity | Sort-Object Name)) {
        $lines += ("  {0}: {1}" -f $group.Name, $group.Count)
    }
    $lines += ''
    foreach ($group in ($Findings | Group-Object CheckId | Sort-Object Name)) {
        $lines += ("  {0}: {1} finding(s)" -f $group.Name, $group.Count)
    }
    if ($DatasetNotes.Count -gt 0) {
        $lines += ''
        $lines += '--- Dataset notes ---'
        foreach ($n in $DatasetNotes) { $lines += "  $n" }
    }
    return ($lines -join "`r`n")
}

# ---------------------------------------------------------------------------
# Fix execution
# ---------------------------------------------------------------------------

function Test-HygieneFixExecutable {
    <#
    .SYNOPSIS
        True when a finding's fix script contains something to run.

    .DESCRIPTION
        Comment-only fix scripts point the operator at the console or at
        another tool; they are display-only and must not enable the Run
        Fix action.
    #>
    param([AllowEmptyString()][string]$FixScript = '')

    foreach ($line in ($FixScript -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed -and -not $trimmed.StartsWith('#')) { return $true }
    }
    return $false
}

function Invoke-HygieneFix {
    <#
    .SYNOPSIS
        Executes one finding's fix script against the connected site.

    .DESCRIPTION
        Must be called from the ConfigMgr site drive. The exact script is logged
        before execution and the outcome after, so the log carries a
        complete record of every mutation this tool performs. The script
        runs with ErrorAction Stop, for terminating and non-terminating
        errors alike, so a partial failure surfaces instead of reporting
        success: the first error ends the script, and no later line runs.

        The caller confirms with the operator first (the GUI shows the
        script). With -WhatIf the script is not run.

    .OUTPUTS
        [pscustomobject] Success, Output, ErrorMessage.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][pscustomobject]$Finding)

    $fixScript = [string]$Finding.FixScript
    if (-not (Test-HygieneFixExecutable -FixScript $fixScript)) {
        return [pscustomobject]@{ Success = $false; Output = ''; ErrorMessage = 'This finding has a display-only fix script; nothing to execute.' }
    }
    if ((Get-Location).Provider.Name -ne 'CMSite') {
        return [pscustomobject]@{ Success = $false; Output = ''; ErrorMessage = 'Fix execution requires the ConfigMgr site drive as the current location.' }
    }
    if (-not $PSCmdlet.ShouldProcess(("[{0}] {1}" -f $Finding.CheckId, $Finding.ObjectName), $fixScript)) {
        return [pscustomobject]@{ Success = $false; Output = ''; ErrorMessage = 'Not run: the fix was skipped by -WhatIf or declined at the confirmation.' }
    }

    Write-Log ("Fix executing [{0}] {1}: {2}" -f $Finding.CheckId, $Finding.ObjectName, $fixScript)
    try {
        # Invoke-Command -ErrorAction Stop does not reach into the script block: a cmdlet that writes a
        # non-terminating error would pass as a success. The preference variable in this scope stops the
        # script at the first error of a ConfigMgr cmdlet. The error variable also catches an error that
        # a command writes without stopping, so no error passes as a success.
        $ErrorActionPreference = 'Stop'
        # The script runs one top-level statement at a time. After each statement the error list is checked, so
        # the first error ends the run even when a command carries -ErrorAction Continue or writes an error
        # without stopping. No later statement runs.
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($fixScript, [ref]$null, [ref]$parseErrors)
        if (@($parseErrors).Count -gt 0) { throw ('The fix script does not parse: {0}' -f @($parseErrors)[0].Message) }
        $output = @()
        foreach ($statement in @($ast.EndBlock.Statements)) {
            $fixErrors = $null
            $output += @(Invoke-Command -ScriptBlock ([scriptblock]::Create($statement.Extent.Text)) -ErrorVariable fixErrors)
            if (@($fixErrors).Count -gt 0) { throw @($fixErrors)[0] }
        }
        $text = (@($output) | Out-String).Trim()
        Write-Log ("Fix succeeded [{0}] {1}" -f $Finding.CheckId, $Finding.ObjectName)
        return [pscustomobject]@{ Success = $true; Output = $text; ErrorMessage = '' }
    }
    catch {
        Write-Log ("Fix FAILED [{0}] {1}: {2}" -f $Finding.CheckId, $Finding.ObjectName, $_.Exception.Message) -Level ERROR -Quiet
        return [pscustomobject]@{ Success = $false; Output = ''; ErrorMessage = $_.Exception.Message }
    }
}

# ---------------------------------------------------------------------------
# Supersedence repair (SUP-01)
# ---------------------------------------------------------------------------
# A supersedence reference to an application that was deleted breaks the evaluation of other deployments on clients.
# The supported cmdlet, Set-CMApplicationSupersedence with -RemoveSupersedence (it replaces the deprecated
# Remove-CMDeploymentTypeSupersedence since version 2111), needs both the superseded application and its deployment
# type as parameters. The deleted application has neither, so on this site version the cmdlet answers "No object
# corresponds to the specified parameters". The repair therefore edits the application document of the superseding
# application, with the serializer of the console assemblies that the ConfigMgr cmdlets use, and writes it back with
# Put. It removes only the rules that point at an application that no longer exists, refuses to write when the edited
# document differs from the original in anything else, and writes no file of the removed data.

function Find-HygBrokenSupersedenceRule {
    <#
    .SYNOPSIS
        The supersedence rules of one application document whose referenced application no longer exists.

    .DESCRIPTION
        Pure over the XML and the existence test. A rule with more than one reference, where only some of the
        referenced applications are gone, is returned with Removable set to false: the repair never edits it.

    .PARAMETER SdmPackageXml
        The SDMPackageXML of the superseding application.

    .PARAMETER Exists
        A script block that takes a model name (ScopeId/Application_guid) and returns true when the application is in the site.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$SdmPackageXml,
        [Parameter(Mandatory)][scriptblock]$Exists
    )

    $rows = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($SdmPackageXml)) { return @() }
    [xml]$xml = $SdmPackageXml
    $nsm = [System.Xml.XmlNamespaceManager]::new($xml.NameTable)
    $nsm.AddNamespace('d', 'http://schemas.microsoft.com/SystemCenterConfigurationManager/2009/AppMgmtDigest')
    $nsm.AddNamespace('r', 'http://schemas.microsoft.com/SystemsCenterConfigurationManager/2009/06/14/Rules')

    foreach ($dtNode in $xml.SelectNodes('/d:AppMgmtDigest/d:DeploymentType', $nsm)) {
        $titleNode = $dtNode.SelectSingleNode('d:Title', $nsm)
        $dtTitle = $(if ($titleNode) { [string]$titleNode.InnerText } else { '' })
        foreach ($rule in $dtNode.SelectNodes('d:Supersedes/r:DeploymentTypeRule', $nsm)) {
            $refs = @($rule.SelectNodes('.//r:DeploymentTypeIntentExpression', $nsm) | ForEach-Object {
                $appRef = $_.SelectSingleNode('r:DeploymentTypeApplicationReference', $nsm)
                $dtRef = $_.SelectSingleNode('r:DeploymentTypeReference', $nsm)
                if ($appRef) {
                    [pscustomobject]@{
                        Model   = ('{0}/{1}' -f $appRef.GetAttribute('AuthoringScopeId'), $appRef.GetAttribute('LogicalName'))
                        DtLogicalName = $(if ($dtRef) { [string]$dtRef.GetAttribute('LogicalName') } else { '' })
                    }
                }
            })
            if ($refs.Count -eq 0) { continue }
            $missing = @($refs | Where-Object { -not [bool](& $Exists ([string]$_.Model)) })
            if ($missing.Count -eq 0) { continue }
            $rows.Add([pscustomobject]@{
                DeploymentTypeName                  = $dtTitle
                DeploymentTypeLogicalName           = [string]$dtNode.GetAttribute('LogicalName')
                RuleId                              = [string]$rule.GetAttribute('id')
                ReferencedApplicationModel          = [string]$missing[0].Model
                ReferencedDeploymentTypeLogicalName = [string]$missing[0].DtLogicalName
                Removable                           = ($missing.Count -eq $refs.Count)
            })
        }
    }
    return $rows.ToArray()
}

function Get-HygSupersedencePlan {
    <#
    .SYNOPSIS
        The plan of the SUP-01 repair: each application and deployment type with a broken supersedence reference, and
        the reference that the repair removes. Changes nothing.

    .DESCRIPTION
        Reads each application fresh from the connected site. A finding whose reference no longer holds (the rule is
        gone, or the referenced application exists again) is listed under Skipped with the reason, not in the plan.

    .PARAMETER Target
        Objects with FindingKey and FixData (the FixData of a SUP-01 finding).

    .OUTPUTS
        [pscustomobject] Rows, Skipped, Applications (ModelName, Name, CIId, CIVersion, Xml).
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Target)

    $rows = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $apps = New-Object System.Collections.Generic.List[object]
    $existsCache = @{}
    $exists = {
        param([string]$Model)
        if (-not $existsCache.ContainsKey($Model)) {
            $existsCache[$Model] = [bool](Get-CMApplication -ModelName $Model -Fast -ErrorAction SilentlyContinue)
        }
        $existsCache[$Model]
    }

    foreach ($group in @($Target | Group-Object { [string]$_.FixData.ApplicationModelName })) {
        $model = [string]$group.Name
        $app = $null
        try { $app = Get-CMApplication -ModelName $model -ErrorAction Stop } catch { $app = $null }
        if (-not $app) {
            foreach ($t in $group.Group) { $skipped.Add([pscustomobject]@{ FindingKey = [string]$t.FindingKey; Reason = 'The application is no longer in the site.' }) }
            continue
        }
        $xml = [string]$app.SDMPackageXML
        $apps.Add([pscustomobject]@{ ModelName = $model; Name = [string]$app.LocalizedDisplayName; CIId = [int]$app.CI_ID; CIVersion = [int]$app.CIVersion })
        $broken = @(Find-HygBrokenSupersedenceRule -SdmPackageXml $xml -Exists $exists)
        foreach ($t in $group.Group) {
            $d = $t.FixData
            $hit = @($broken | Where-Object {
                $_.RuleId -eq [string]$d.RuleId -and $_.DeploymentTypeLogicalName -eq [string]$d.DeploymentTypeLogicalName -and $_.ReferencedApplicationModel -eq [string]$d.ReferencedApplicationModel
            }) | Select-Object -First 1
            if (-not $hit) {
                $skipped.Add([pscustomobject]@{ FindingKey = [string]$t.FindingKey; Reason = 'The reference is no longer broken: the rule is gone from the application, or the referenced application exists again.' })
                continue
            }
            if (-not $hit.Removable) {
                $skipped.Add([pscustomobject]@{ FindingKey = [string]$t.FindingKey; Reason = 'The rule also points at an application that still exists, so it is not edited here. Use the console.' })
                continue
            }
            $rows.Add([pscustomobject]@{
                FindingKey                          = [string]$t.FindingKey
                ApplicationName                     = [string]$app.LocalizedDisplayName
                ApplicationModelName                = $model
                ApplicationCIId                     = [int]$app.CI_ID
                DeploymentTypeName                  = $hit.DeploymentTypeName
                DeploymentTypeLogicalName           = $hit.DeploymentTypeLogicalName
                RuleId                              = $hit.RuleId
                ReferencedApplicationModel          = $hit.ReferencedApplicationModel
                ReferencedDeploymentTypeLogicalName = $hit.ReferencedDeploymentTypeLogicalName
            })
        }
    }
    return [pscustomobject]@{ Rows = $rows.ToArray(); Skipped = $skipped.ToArray(); Applications = $apps.ToArray() }
}

function Read-HygApplicationDocument {
    <#
    .SYNOPSIS
        The application object of an application document, read with the serializer of the console assemblies.
    #>
    param([Parameter(Mandatory)][string]$Xml)
    $serializer = 'Microsoft.ConfigurationManagement.ApplicationManagement.Serialization.SccmSerializer' -as [type]
    if (-not $serializer) { throw 'The console assemblies for application documents are not loaded. Import the ConfigurationManager module first.' }
    return $serializer::DeserializeFromString($Xml, $true)
}

function ConvertTo-HygApplicationDocument {
    <#
    .SYNOPSIS
        The application document (XML text) of an application object.
    #>
    param([Parameter(Mandatory)]$Application)
    $serializer = 'Microsoft.ConfigurationManagement.ApplicationManagement.Serialization.SccmSerializer' -as [type]
    if (-not $serializer) { throw 'The console assemblies for application documents are not loaded. Import the ConfigurationManager module first.' }
    return [string]$serializer::SerializeToString($Application, $true)
}

function Get-HygSerializerInfo {
    <#
    .SYNOPSIS
        Where the serializer of application documents was loaded from, and where the ConfigurationManager module (the console) is.
    #>
    $serializer = 'Microsoft.ConfigurationManagement.ApplicationManagement.Serialization.SccmSerializer' -as [type]
    $module = Get-Module -Name ConfigurationManager | Select-Object -First 1
    $info = [ordered]@{ Loaded = [bool]$serializer; AssemblyFolder = ''; AssemblyVersion = ''; ConsoleFolder = ''; ConsoleVersion = '' }
    if ($serializer) {
        $path = [string]$serializer.Assembly.Location
        $info.AssemblyFolder = $(if ($path) { Split-Path -Path $path -Parent } else { '' })
        $info.AssemblyVersion = $(if ($path) { [string](Get-Item -LiteralPath $path).VersionInfo.FileVersion } else { '' })
    }
    if ($module) { $info.ConsoleFolder = [string]$module.ModuleBase; $info.ConsoleVersion = [string]$module.Version }
    return [pscustomobject]$info
}

function Test-HygSerializerInfo {
    <#
    .SYNOPSIS
        Null when the serializer is the one of the console, else the reason it is not. The fix refuses to edit a document with another serializer.

    .DESCRIPTION
        The serializer must be loaded from the folder of the ConfigurationManager module and must have the same major and
        minor version (for example 5.2603). A build number may differ: the console assemblies carry their own build numbers.
    #>
    param([Parameter(Mandatory)]$Info)
    if (-not $Info.Loaded) { return 'The serializer of the console is not loaded.' }
    if (-not $Info.ConsoleFolder) { return 'The ConfigurationManager module of the console is not loaded.' }
    if ([string]$Info.AssemblyFolder -ne [string]$Info.ConsoleFolder) { return 'The serializer is not the one of the console: it was loaded from another folder.' }
    $a = [string]$Info.AssemblyVersion -split '\.'
    $c = [string]$Info.ConsoleVersion -split '\.'
    if ($a.Count -lt 2 -or $c.Count -lt 2 -or $a[0] -ne $c[0] -or $a[1] -ne $c[1]) { return ('The serializer version {0} differs from the console version {1}.' -f $Info.AssemblyVersion, $Info.ConsoleVersion) }
    return $null
}

function ConvertTo-HygDocumentLine {
    <#
    .SYNOPSIS
        An application document as a sorted list of one line for each element: path, attributes (the Version attribute left out,
        because each write raises it) and the text of a leaf. Formatting, namespace declarations, the order of siblings and an empty Supersedes container do not count.
    #>
    param([Parameter(Mandatory)][string]$Xml, [string[]]$WithoutRuleId = @())
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($Xml)
    foreach ($id in $WithoutRuleId) {
        foreach ($rule in @($doc.SelectNodes("//*[local-name()='DeploymentTypeRule'][@id='$($id -replace "'", '')']"))) { [void]$rule.ParentNode.RemoveChild($rule) }
    }
    $lines = New-Object System.Collections.Generic.List[string]
    $walk = $null
    $walk = {
        param($node, [string]$path)
        foreach ($child in $node.ChildNodes) {
            if ($child.NodeType -ne 'Element') { continue }
            $attrs = (@($child.Attributes | Where-Object { $_.Name -ne 'Version' -and $_.Name -notlike 'xmlns*' } | ForEach-Object { '{0}={1}' -f $_.Name, $_.Value } | Sort-Object) -join ',')
            $hasChild = $false
            foreach ($g in $child.ChildNodes) { if ($g.NodeType -eq 'Element') { $hasChild = $true } }
            # The serializer leaves out the container of a deployment type that has no supersedence rule left: an empty
            # container and no container are the same document.
            if ($child.LocalName -eq 'Supersedes' -and -not $hasChild) { continue }
            $lines.Add(('{0}/{1}[{2}]={3}' -f $path, $child.LocalName, $attrs, $(if ($hasChild) { '' } else { $child.InnerText.Trim() })))
            & $walk $child ('{0}/{1}' -f $path, $child.LocalName)
        }
    }
    & $walk $doc.DocumentElement ''
    return @($lines | Sort-Object)
}

function Get-HygDocumentDifference {
    <#
    .SYNOPSIS
        What differs between two application documents once the named supersedence rules are taken out of the first one.
        An empty result means the second document is the first one without those rules and nothing else.
    #>
    param([Parameter(Mandatory)][string]$Before, [Parameter(Mandatory)][string]$After, [string[]]$RemovedRuleId = @())
    $expected = @(ConvertTo-HygDocumentLine -Xml $Before -WithoutRuleId $RemovedRuleId)
    $actual = @(ConvertTo-HygDocumentLine -Xml $After)
    $diff = New-Object System.Collections.Generic.List[string]
    $left = New-Object 'System.Collections.Generic.Dictionary[string,int]'
    foreach ($l in $expected) { if ($left.ContainsKey($l)) { $left[$l]++ } else { $left[$l] = 1 } }
    foreach ($l in $actual) {
        if ($left.ContainsKey($l) -and $left[$l] -gt 0) { $left[$l]-- } else { $diff.Add('added: ' + $l) }
    }
    foreach ($k in $left.Keys) { for ($i = 0; $i -lt $left[$k]; $i++) { $diff.Add('missing: ' + $k) } }
    return $diff.ToArray()
}

function Remove-HygBrokenSupersedence {
    <#
    .SYNOPSIS
        Removes the supersedence references of a plan that point at deleted applications, and then the old revisions that the change made.

    .DESCRIPTION
        Set-CMApplicationSupersedence -RemoveSupersedence and the deprecated Remove-CMDeploymentTypeSupersedence need the superseded
        application and its deployment type as parameters. A deleted application has neither, so the cmdlets cannot remove this reference.
        The fix edits the application document of the superseding application with the serializer of the console and writes it back.

        For each application it reads the application again, checks that each reference is still broken, and removes only those rules.
        It refuses when the serializer is not the one of the console, and when the edited document differs from the original in anything
        but the removed rules. After the write it reads the application again and checks the same. An application that fails does not
        stop the others. No file of the removed data is written.

        With -DeleteOldRevisions it then deletes the old revisions of exactly the applications that it changed. The site refuses to delete
        a revision that another object still uses: that revision is kept, the result says so, and the run does not fail.
        Set $State.StopRequested to stop after the application in work.

    .OUTPUTS
        [pscustomobject] Success, Message, Results (one row for each planned reference with Result Removed, Failed or Skipped, a Message,
        and for a changed application RevisionsDeleted, RevisionsKept and RevisionNote), Removed, Failed, Skipped.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Plan,
        [switch]$DeleteOldRevisions,
        [hashtable]$State
    )

    $results = New-Object System.Collections.Generic.List[object]
    $rows = @($Plan.Rows)
    $finish = {
        param([bool]$Ok, [string]$Message)
        [pscustomobject]@{
            Success = $Ok
            Message = $Message
            Results = $results.ToArray()
            Removed = @($results | Where-Object { $_.Result -eq 'Removed' }).Count
            Failed  = @($results | Where-Object { $_.Result -eq 'Failed' }).Count
            Skipped = @($results | Where-Object { $_.Result -eq 'Skipped' }).Count
        }
    }
    if ($rows.Count -eq 0) { return (& $finish $true 'The plan has no reference to remove.') }
    if (-not $PSCmdlet.ShouldProcess(('{0} reference(s) on the connected site' -f $rows.Count), 'Remove the broken supersedence references')) {
        foreach ($r in $rows) { $results.Add([pscustomobject]@{ Row = $r; Result = 'Skipped'; Message = 'Not run: skipped by -WhatIf or declined.' }) }
        return (& $finish $true 'Not run: skipped by -WhatIf or declined.')
    }

    $refusal = Test-HygSerializerInfo -Info (Get-HygSerializerInfo)
    if ($refusal) {
        Write-Log 'Supersedence repair refused: the serializer is not the one of the console. Nothing was changed.' -Level ERROR
        foreach ($r in $rows) { $results.Add([pscustomobject]@{ Row = $r; Result = 'Skipped'; Message = $refusal + ' Nothing was changed.' }) }
        return (& $finish $false ($refusal + ' Nothing was changed.'))
    }

    $existsCache = @{}
    $exists = {
        param([string]$Model)
        if (-not $existsCache.ContainsKey($Model)) { $existsCache[$Model] = [bool](Get-CMApplication -ModelName $Model -Fast -ErrorAction SilentlyContinue) }
        $existsCache[$Model]
    }

    foreach ($group in @($rows | Group-Object ApplicationModelName)) {
        $groupRows = @($group.Group)
        $label = [string]$groupRows[0].ApplicationName
        if ($State -and $State.StopRequested) {
            foreach ($r in $groupRows) { $results.Add([pscustomobject]@{ Row = $r; Result = 'Skipped'; Message = 'Stopped before this application.' }) }
            continue
        }
        try {
            $app = Get-CMApplication -ModelName $group.Name -ErrorAction Stop
            if (-not $app) { throw 'The application is no longer in the site.' }
            $original = [string]$app.SDMPackageXML
            $live = @(Find-HygBrokenSupersedenceRule -SdmPackageXml $original -Exists $exists)
            $todo = New-Object System.Collections.Generic.List[object]
            foreach ($r in $groupRows) {
                $stillBroken = @($live | Where-Object { $_.RuleId -eq $r.RuleId -and $_.Removable -and $_.ReferencedApplicationModel -eq $r.ReferencedApplicationModel })
                if ($stillBroken.Count -gt 0) { $todo.Add($r) }
                else { $results.Add([pscustomobject]@{ Row = $r; Result = 'Skipped'; Message = 'The reference is no longer broken, so it was left as it is.' }) }
            }
            if ($todo.Count -eq 0) { continue }

            $ids = @($todo | ForEach-Object { [string]$_.RuleId })
            $object = Read-HygApplicationDocument -Xml $original
            $removedIds = New-Object System.Collections.Generic.List[string]
            # The rules are copied first, because the collection changes while a rule is removed. The copy is made with
            # foreach: an array subexpression over a generic collection of objects can throw "Argument types do not match".
            foreach ($dt in $object.DeploymentTypes) {
                $copy = New-Object System.Collections.ArrayList
                foreach ($rule in $dt.Supersedes) { [void]$copy.Add($rule) }
                foreach ($rule in $copy) {
                    if ($ids -contains [string]$rule.RuleId) {
                        [void]$dt.Supersedes.Remove($rule)
                        $removedIds.Add([string]$rule.RuleId)
                    }
                }
            }
            if ($removedIds.Count -eq 0) { throw 'The rule was not found in the application document.' }
            $edited = ConvertTo-HygApplicationDocument -Application $object

            # Nothing but the removed rules may differ. Otherwise the document is not written.
            $before = @(Get-HygDocumentDifference -Before $original -After $edited -RemovedRuleId $removedIds.ToArray())
            if ($before.Count -gt 0) {
                Write-Log ('Supersedence repair refused [{0}]: the edited document differs from the original in more than the broken rules. Nothing was changed.' -f $label) -Level ERROR
                foreach ($r in $todo) { $results.Add([pscustomobject]@{ Row = $r; Result = 'Failed'; Message = 'The edited document differs from the original in more than the broken rules, so nothing was changed.'; Detail = ($before | Select-Object -First 5) -join ' | ' }) }
                continue
            }

            $app.SDMPackageXML = $edited
            [void]$app.Put()

            # Read the application again: it must read back, and it must be the original without the removed rules.
            $after = Get-CMApplication -ModelName $group.Name -ErrorAction Stop
            $readBack = @()
            try { [void](Read-HygApplicationDocument -Xml ([string]$after.SDMPackageXML)); $readBack = @(Get-HygDocumentDifference -Before $original -After ([string]$after.SDMPackageXML) -RemovedRuleId $removedIds.ToArray()) }
            catch { $readBack = @('the document did not read back') }
            if ($readBack.Count -gt 0) {
                Write-Log ('Supersedence repair FAILED [{0}]: the application did not read back as the original without the broken rules.' -f $label) -Level ERROR
                foreach ($r in $todo) { $results.Add([pscustomobject]@{ Row = $r; Result = 'Failed'; Message = 'The application did not read back as the original without the broken rules. Check it in the console.'; Detail = ($readBack | Select-Object -First 5) -join ' | ' }) }
                continue
            }

            $deleted = 0; $kept = New-Object System.Collections.Generic.List[string]
            if ($DeleteOldRevisions) {
                $newest = [int]$after.CIVersion
                foreach ($rev in @(Get-CMApplicationRevisionHistory -Id ([int]$after.CI_ID) -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.CIVersion } | Sort-Object -Unique)) {
                    if ($rev -ge $newest) { continue }
                    try { Remove-CMApplicationRevisionHistory -Id ([int]$after.CI_ID) -Revision $rev -Force -ErrorAction Stop; $deleted++ }
                    catch { $kept.Add(('revision {0}: the site did not delete it because another object still uses it' -f $rev)) }
                }
            }
            $note = $(if (-not $DeleteOldRevisions) { '' } elseif ($kept.Count -eq 0) { ('{0} old revision(s) deleted.' -f $deleted) } else { ('{0} old revision(s) deleted; kept: {1}.' -f $deleted, ($kept -join '; ')) })
            foreach ($r in $todo) {
                $results.Add([pscustomobject]@{ Row = $r; Result = 'Removed'; Message = 'Removed.'; RevisionsDeleted = $deleted; RevisionsKept = $kept.ToArray(); RevisionNote = $note })
                Write-Log ('Supersedence repair [{0}] deployment type {1}: removed the broken reference' -f $r.ApplicationName, $r.DeploymentTypeName)
            }
            if ($note) { Write-Log ('Supersedence repair [{0}]: {1}' -f $label, $note) }
        }
        catch {
            Write-Log ('Supersedence repair FAILED [{0}]' -f $label) -Level ERROR
            foreach ($r in $groupRows) {
                if (-not ($results | Where-Object { $_.Row.RuleId -eq $r.RuleId -and $_.Row.ApplicationModelName -eq $r.ApplicationModelName })) {
                    $results.Add([pscustomobject]@{ Row = $r; Result = 'Failed'; Message = 'The change failed. The log file has the details.'; Detail = [string]$_.Exception.Message })
                }
            }
        }
    }
    $summary = '{0} removed, {1} failed, {2} skipped.' -f @($results | Where-Object Result -eq 'Removed').Count, @($results | Where-Object Result -eq 'Failed').Count, @($results | Where-Object Result -eq 'Skipped').Count
    Write-Log ('Supersedence repair finished: {0}' -f $summary)
    return (& $finish (@($results | Where-Object Result -eq 'Failed').Count -eq 0) $summary)
}

function Test-HygSupersedenceRecheck {
    <#
    .SYNOPSIS
        Runs check SUP-01 again on the named applications, on fresh data from the site, and counts their old revisions (check APP-05).

    .OUTPUTS
        [pscustomobject] Remaining (the number of SUP-01 findings left on these applications), OldRevisions (the old revisions of these
        applications), Findings.
    #>
    param([Parameter(Mandatory)][string[]]$ApplicationModelName)

    $apps = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $toApp = {
        param($A, [bool]$WithXml)
        [pscustomobject]@{
            CI_ID = [int]$A.CI_ID; ModelName = [string]$A.ModelName; Name = [string]$A.LocalizedDisplayName; SoftwareVersion = [string]$A.SoftwareVersion
            Manufacturer = [string]$A.Manufacturer; IsEnabled = [bool]$A.IsEnabled; IsExpired = [bool]$A.IsExpired; IsSuperseded = [bool]$A.IsSuperseded
            IsSuperseding = [bool]$A.IsSuperseding; HasContent = [bool]$A.HasContent
            NumberOfDeploymentTypes = $(if ($WithXml) { [int]$A.NumberOfDeploymentTypes } else { 0 })
            SDMPackageXML = $(if ($WithXml) { [string]$A.SDMPackageXML } else { '' })
            CIVersion = [int]$A.CIVersion
        }
    }
    foreach ($model in $ApplicationModelName) {
        $a = Get-CMApplication -ModelName $model -ErrorAction SilentlyContinue
        if ($a) { $apps.Add((& $toApp $a $true)); $seen[$model] = $true }
    }
    # The referenced applications that exist join the data, so the check tells a deleted one from a present one.
    foreach ($rel in @((ConvertTo-HygRelationships -Applications $apps.ToArray()).Relationships)) {
        $m = [string]$rel.ToModelName
        if ($seen.ContainsKey($m)) { continue }
        $seen[$m] = $true
        $r = Get-CMApplication -ModelName $m -ErrorAction SilentlyContinue
        if ($r) { $apps.Add((& $toApp $r $false)) }
    }
    $all = $apps.ToArray()
    $parsed = ConvertTo-HygRelationships -Applications $all
    $lookup = @{}
    foreach ($a in $all) { $lookup[[int]$a.CI_ID] = $a }
    $data = [pscustomobject]@{ Apps = $lookup; Relationships = $parsed.Relationships }
    $findings = @(Test-HygRelationshipChecks -RelationshipData $data | Where-Object { $_.CheckId -eq 'SUP-01' -and $ApplicationModelName -contains [string]$_.ObjectId })
    $old = 0
    foreach ($a in @($all | Where-Object { $ApplicationModelName -contains $_.ModelName })) {
        $old += @(Get-CMApplicationRevisionHistory -Id ([int]$a.CI_ID) -ErrorAction SilentlyContinue | Where-Object { [int]$_.CIVersion -lt [int]$a.CIVersion }).Count
    }
    return [pscustomobject]@{ Remaining = $findings.Count; OldRevisions = $old; Findings = $findings }
}

# ---------------------------------------------------------------------------
# Retired and superseded applications (Q-89)
# ---------------------------------------------------------------------------
# Rule: no active application depends on or supersedes a retired application, and no task sequence installs a retired
# or superseded one. The fixes use the supported cmdlets: Set-CMApplicationSupersedence -RemoveSupersedence and
# Remove-CMDeploymentTypeDependency work when both applications exist. Each fix script is one statement (Run Fix runs the
# statements one at a time, and a variable does not live from one statement to the next), followed by a statement that
# deletes the old revisions of the changed application. The site refuses to delete a revision that another object uses:
# that revision stays and the fix does not fail.

function Get-HygSupersedenceRemovalScript {
    <#
    .SYNOPSIS
        The fix script that removes one supersedence rule between two applications that both exist, then the old revisions
        that the change makes. Both statements resolve the applications by model name when they run.
    #>
    param(
        [Parameter(Mandatory)][string]$FromModel, [Parameter(Mandatory)][string]$FromDeploymentType,
        [Parameter(Mandatory)][string]$ToModel, [Parameter(Mandatory)][string]$ToDeploymentType,
        [switch]$RetiredSource
    )
    $f = ConvertTo-HygQuotedLiteral $FromModel; $t = ConvertTo-HygQuotedLiteral $ToModel
    $fd = ConvertTo-HygQuotedLiteral ('*/' + $FromDeploymentType); $td = ConvertTo-HygQuotedLiteral ('*/' + $ToDeploymentType)
    $remove = "& { `$f = Get-CMApplication -ModelName '$f'; `$t = Get-CMApplication -ModelName '$t'; `$fd = Get-CMDeploymentType -InputObject `$f | Where-Object { `$_.ModelName -like '$fd' }; `$td = Get-CMDeploymentType -InputObject `$t | Where-Object { `$_.ModelName -like '$td' }; Set-CMApplicationSupersedence -Id `$f.CI_ID -CurrentDeploymentTypeId `$fd.CI_ID -SupersededApplicationId `$t.CI_ID -OldDeploymentTypeId `$td.CI_ID -RemoveSupersedence -Force }"
    if ($RetiredSource) { $remove = Get-HygRetiredSourceScript -Model $FromModel -Change $remove }
    return ($remove + "`r`n" + (Get-HygRevisionCleanupScript -Model $FromModel))
}

function Get-HygDependencyRemovalScript {
    <#
    .SYNOPSIS
        The fix script that removes the dependency of one deployment type on one application, then the old revisions that the
        change makes. A dependency group that has no dependency left is removed by the cmdlet.
    #>
    param([Parameter(Mandatory)][string]$FromModel, [Parameter(Mandatory)][string]$FromDeploymentType, [Parameter(Mandatory)][string]$ToModel, [switch]$RetiredSource)
    $f = ConvertTo-HygQuotedLiteral $FromModel; $t = ConvertTo-HygQuotedLiteral $ToModel
    $fd = ConvertTo-HygQuotedLiteral ('*/' + $FromDeploymentType)
    $remove = "& { `$f = Get-CMApplication -ModelName '$f'; `$dt = Get-CMDeploymentType -InputObject `$f | Where-Object { `$_.ModelName -like '$fd' }; foreach (`$g in @(Get-CMDeploymentTypeDependencyGroup -InputObject `$dt)) { foreach (`$d in @(Get-CMDeploymentTypeDependency -InputObject `$g)) { if (`$d.AppModelName -eq '$t') { Remove-CMDeploymentTypeDependency -InputObject `$g -DeploymentTypeDependency `$d -Force } } } }"
    if ($RetiredSource) { $remove = Get-HygRetiredSourceScript -Model $FromModel -Change $remove }
    return ($remove + "`r`n" + (Get-HygRevisionCleanupScript -Model $FromModel))
}

function Get-HygRetiredSourceScript {
    <#
    .SYNOPSIS
        Wraps one change of a RETIRED application in one statement: refuse when the application has a deployment, reinstate the
        application, make the change, and retire the application again, also when the change fails.

    .DESCRIPTION
        The site ignores Set-CMApplicationSupersedence -RemoveSupersedence and Remove-CMDeploymentTypeDependency for a retired
        application: the cmdlets return no error and change nothing (measured on a lab site). The change, the retire and the guard are
        one statement, because Run Fix stops at the first error and runs no later statement, and the application must be retired again
        whatever happens. A retired application with a deployment is refused, because it would deploy while it is reinstated.
    #>
    param([Parameter(Mandatory)][string]$Model, [Parameter(Mandatory)][string]$Change)
    $m = ConvertTo-HygQuotedLiteral $Model
    return "& { `$r = Get-CMApplication -ModelName '$m'; if (@(Get-CMApplicationDeployment -InputObject `$r).Count -gt 0) { throw 'The retired application has a deployment. The fix reinstates the application for a moment, so delete the deployment first (check APP-02).' }; Resume-CMApplication -InputObject `$r; try { $Change } finally { Suspend-CMApplication -InputObject (Get-CMApplication -ModelName '$m') } }"
}

function Get-HygRevisionCleanupScript {
    <#
    .SYNOPSIS
        The fix statement that deletes the old revisions of one application (the ones older than the current revision). A revision
        that another object still uses stays, and the statement says so; it does not fail.
    #>
    param([Parameter(Mandatory)][string]$Model)
    $m = ConvertTo-HygQuotedLiteral $Model
    return "& { `$a = Get-CMApplication -ModelName '$m'; foreach (`$rev in @(Get-CMApplicationRevisionHistory -Id `$a.CI_ID | ForEach-Object { [int]`$_.CIVersion } | Sort-Object)) { if (`$rev -lt [int]`$a.CIVersion) { try { Remove-CMApplicationRevisionHistory -Id `$a.CI_ID -Revision `$rev -Force -ErrorAction Stop } catch { Write-Output ('Revision {0} stays: another object uses it.' -f `$rev) } } } }"
}

function Get-HygApplicationBlocker {
    <#
    .SYNOPSIS
        Every object that refers to an application and so blocks its delete, from the datasets that a scan already holds.

    .DESCRIPTION
        Kinds: Deployment, Task sequence (also a task sequence that holds the task sequence that installs the application),
        Stale reference (a reference row of a task sequence that Get-CMTaskSequence does not return), Dependency (another
        application depends on it) and Supersedence (another application supersedes it). A task sequence or a collection that
        the account may not see is not in the data; the dialog says so.

    .OUTPUTS
        Objects with Kind, Name and Detail.
    #>
    param(
        [Parameter(Mandatory)]$Data,
        [Parameter(Mandatory)]$RelationshipData,
        [Parameter(Mandatory)][string]$ModelName
    )
    $out = New-Object System.Collections.Generic.List[object]
    $app = @($Data.Applications | Where-Object { [string]$_.ModelName -eq $ModelName }) | Select-Object -First 1
    if ($app) {
        foreach ($d in @($Data.Deployments | Where-Object { [int]$_.FeatureType -eq 1 -and [string]$_.SoftwareName -eq [string]$app.Name })) {
            $out.Add([pscustomobject]@{ Kind = 'Deployment'; Name = [string]$d.CollectionName; Detail = ('Collection {0} ({1})' -f $d.CollectionName, $d.CollectionID) })
        }
    }
    $live = @(Get-HygLiveTaskSequence -Data $Data)
    foreach ($ts in $live) {
        $refs = @($ts.ReferencedIDs)
        if ($refs -contains $ModelName -or ($app -and $app.PackageID -and $refs -contains [string]$app.PackageID)) {
            $out.Add([pscustomobject]@{ Kind = 'Task sequence'; Name = [string]$ts.Name; Detail = ('Package {0}' -f $ts.PackageID) })
            foreach ($outer in @($live | Where-Object { @($_.ReferencedIDs) -contains [string]$ts.PackageID })) {
                $out.Add([pscustomobject]@{ Kind = 'Task sequence (nested)'; Name = [string]$outer.Name; Detail = ('Package {0}; it holds the task sequence {1}, which installs the application' -f $outer.PackageID, $ts.Name) })
            }
        }
    }
    foreach ($ts in @($Data.TaskSequences | Where-Object { $_.PSObject.Properties['IsStale'] -and $_.IsStale })) {
        if (@($ts.ReferencedIDs) -contains $ModelName -or ($app -and $app.PackageID -and @($ts.ReferencedIDs) -contains [string]$app.PackageID)) {
            $out.Add([pscustomobject]@{ Kind = 'Stale reference'; Name = [string]$ts.PackageID; Detail = 'A reference row of a task sequence that the site does not return. It still blocks the delete.' })
        }
    }
    foreach ($e in @($RelationshipData.Relationships | Where-Object { $_.ToModelName -eq $ModelName })) {
        if ($e.Kind -eq 'Dependency') { $out.Add([pscustomobject]@{ Kind = 'Dependency'; Name = [string]$e.FromAppName; Detail = ('Deployment type {0} depends on it' -f $e.FromDTName) }) }
        elseif ($e.Kind -eq 'Supersedence') { $out.Add([pscustomobject]@{ Kind = 'Supersedence'; Name = [string]$e.FromAppName; Detail = ('Deployment type {0} supersedes it' -f $e.FromDTName) }) }
    }
    return $out.ToArray()
}

function Get-HygLiveTaskSequence {
    <#
    .SYNOPSIS
        The task sequences that Get-CMTaskSequence returned. The dataset also holds an entry for each task sequence whose
        reference rows the site returns and whose task sequence it does not (IsStale); the checks that read references leave those out.
    #>
    param([Parameter(Mandatory)]$Data)
    return @(@($Data.TaskSequences) | Where-Object { -not $_.PSObject.Properties['IsStale'] -or -not $_.IsStale })
}

function Test-HygRetiredSupersededChecks {
    <#
    .SYNOPSIS
        APP-07 (a retired application that still holds supersedence or dependency rules), APP-08 (a superseded application that
        qualifies for deletion), TSQ-05 (a task sequence installs a retired or superseded application) and TSQ-06 (a stale
        reference row). The incoming references to a retired application are SUP-04 and DEP-04, so one situation is one finding.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Runs the retired and superseded check family by design.')]
    param([Parameter(Mandatory)]$Data, [Parameter(Mandatory)]$RelationshipData)

    $apps = $RelationshipData.Apps
    $edges = @($RelationshipData.Relationships)
    $byModel = @{}
    foreach ($a in @($Data.Applications)) { if ($a.ModelName) { $byModel[[string]$a.ModelName] = $a } }
    $modelOfCi = { param($ci) $a = $apps[[int]$ci]; if ($a -and $a.ModelName) { [string]$a.ModelName } else { '' } }
    $live = @(Get-HygLiveTaskSequence -Data $Data)

    # APP-07: a retired application that holds rules of its own toward an application that exists and is not retired
    # (a retired target is SUP-04 or DEP-04, a deleted one SUP-01 or DEP-01).
    foreach ($app in @($apps.Values | Where-Object { $_.IsExpired -and $_.ModelName })) {
        $own = @($edges | Where-Object { [int]$_.FromAppCIID -eq [int]$app.CI_ID -and $_.ToAppExists -and -not ($apps[[int]$_.ToAppCIID] -and $apps[[int]$_.ToAppCIID].IsExpired) })
        if ($own.Count -eq 0) { continue }
        $incoming = @($edges | Where-Object { $_.ToModelName -eq [string]$app.ModelName }).Count
        $scripts = New-Object System.Collections.Generic.List[string]
        $text = foreach ($e in $own) {
            $to = [string]$e.ToAppName
            if ($e.Kind -eq 'Supersedence') {
                $scripts.Add((Get-HygSupersedenceRemovalScript -FromModel ([string]$app.ModelName) -FromDeploymentType ([string]$e.FromDTLogicalName) -ToModel ([string]$e.ToModelName) -ToDeploymentType ([string]$e.ToDTLogicalName) -RetiredSource))
                "supersedes '{0}' (deployment type '{1}')" -f $to, $e.FromDTName
            }
            else {
                $scripts.Add((Get-HygDependencyRemovalScript -FromModel ([string]$app.ModelName) -FromDeploymentType ([string]$e.FromDTLogicalName) -ToModel ([string]$e.ToModelName) -RetiredSource))
                "depends on '{0}' (deployment type '{1}')" -f $to, $e.FromDTName
            }
        }
        New-HygieneFinding -CheckId 'APP-07' -Severity Warning -Category 'Applications' `
            -ObjectType 'Application' -ObjectId ([string]$app.ModelName) -ObjectName ([string]$app.Name) `
            -Evidence ("The application is retired and still {0}.{1}" -f ($text -join '; and '), $(if ($incoming -gt 0) { (' {0} other rule(s) point at it: see SUP-04 and DEP-04.' -f $incoming) } else { '' })) `
            -Recommendation 'A retired application must not supersede or depend on an active one. Remove the rules. The site ignores a change of a retired application, so each removal reinstates the application, makes the change and retires it again (not for an application that has a deployment). Each removal makes a new revision of the retired application; the fix deletes the old revisions it creates.' `
            -FixScript ($scripts -join "`r`n")
    }

    # APP-08: a superseded application that nothing but the supersedence of its replacement refers to.
    # A retired superseded application is SUP-04 (remove the rule); once the rule is gone, APP-01 reports the unused application.
    foreach ($app in @($Data.Applications | Where-Object { $_.IsSuperseded -and -not $_.IsExpired -and $_.ModelName })) {
        $model = [string]$app.ModelName
        if ($app.IsDeployed) { continue }
        $blockers = @(Get-HygApplicationBlocker -Data $Data -RelationshipData $RelationshipData -ModelName $model | Where-Object { $_.Kind -ne 'Supersedence' })
        if ($blockers.Count -gt 0) { continue }
        $rules = @($edges | Where-Object { $_.Kind -eq 'Supersedence' -and $_.ToModelName -eq $model -and $_.ToAppExists })
        if ($rules.Count -eq 0) { continue }
        $scripts = New-Object System.Collections.Generic.List[string]
        foreach ($e in $rules) { $scripts.Add((Get-HygSupersedenceRemovalScript -FromModel (& $modelOfCi $e.FromAppCIID) -FromDeploymentType ([string]$e.FromDTLogicalName) -ToModel $model -ToDeploymentType ([string]$e.ToDTLogicalName))) }
        $scripts.Add(("Get-CMApplication -ModelName '{0}' | Remove-CMApplication -Force" -f (ConvertTo-HygQuotedLiteral $model)))
        $by = (@($rules | ForEach-Object { "'{0}'" -f $_.FromAppName } | Sort-Object -Unique) -join ', ')
        New-HygieneFinding -CheckId 'APP-08' -Severity Info -Category 'Applications' `
            -ObjectType 'Application' -ObjectId $model -ObjectName ([string]$app.Name) `
            -Evidence ("The application is superseded by {0}. It has no deployment, no dependency on it and no task sequence that refers to it (also no stale reference row). Blocked by: nothing." -f $by) `
            -Recommendation 'The application qualifies for deletion. Run Fix removes the supersedence rule of the replacement, deletes the application and deletes the old revisions that the rule change makes. The site refuses a delete that something still blocks; the result says what.' `
            -FixScript ($scripts -join "`r`n")
    }

    # TSQ-05: a task sequence installs a retired or superseded application.
    foreach ($ts in $live) {
        foreach ($ref in @($ts.ReferencedIDs | Where-Object { $_ -like '*/Application_*' } | Sort-Object -Unique)) {
            $app = $byModel[[string]$ref]
            if (-not $app) { continue }
            $state = $(if ($app.IsExpired) { 'retired' } elseif ($app.IsSuperseded) { 'superseded' } else { '' })
            if (-not $state) { continue }
            $by = @($edges | Where-Object { $_.Kind -eq 'Supersedence' -and $_.ToModelName -eq [string]$ref } | ForEach-Object { $_.FromAppName } | Sort-Object -Unique)
            New-HygieneFinding -CheckId 'TSQ-05' -Severity Warning -Category 'Task Sequences' `
                -ObjectType 'TaskSequence' -ObjectId ([string]$ts.PackageID) -ObjectName ("{0} ({1}) -> {2}" -f $ts.Name, $ts.PackageID, $app.Name) `
                -Evidence ("Task sequence '{0}' (package {1}) has a step that installs the {2} application '{3}'.{4}" -f $ts.Name, $ts.PackageID, $state, $app.Name, $(if ($by.Count -gt 0) { (' It is superseded by {0}.' -f (($by | ForEach-Object { "'$_'" }) -join ', ')) } else { '' })) `
                -Recommendation 'Edit the task sequence in the console and point the Install Application step at the active application. No fix runs from here: a task sequence is never edited without you.' `
                -FixScript ("# Console: Task Sequences > '{0}' > Edit - replace the application '{1}' in the Install Application step" -f $ts.Name, $app.Name)
        }
    }

    # TSQ-06: reference rows of a task sequence that the site does not return.
    foreach ($ts in @($Data.TaskSequences | Where-Object { $_.PSObject.Properties['IsStale'] -and $_.IsStale })) {
        $names = @($ts.ReferencedIDs | ForEach-Object { $a = $byModel[[string]$_]; if ($a) { [string]$a.Name } else { [string]$_ } } | Select-Object -First 8)
        New-HygieneFinding -CheckId 'TSQ-06' -Severity Warning -Category 'Task Sequences' `
            -ObjectType 'TaskSequence' -ObjectId ([string]$ts.PackageID) -ObjectName ([string]$ts.PackageID) `
            -Evidence ("Stale reference: the site returns {0} reference row(s) of task sequence {1}, but the task sequence itself is not returned (deleted, or outside your security scope). The rows still block the delete of what they name: {2}." -f @($ts.ReferencedIDs).Count, $ts.PackageID, ($names -join ', ')) `
            -Recommendation 'Check the task sequence in the console with an account that sees all objects. When it is gone, the rows are stale: the site removes them with its own cleanup, or a site repair is needed. No fix runs from here.' `
            -FixScript ("# No supported cmdlet removes a reference row of task sequence {0}." -f $ts.PackageID)
    }
}

# ---------------------------------------------------------------------------
# Rescan deltas
# ---------------------------------------------------------------------------

function Save-HygieneScanResult {
    <#
    .SYNOPSIS
        Persists a scan's findings for the next scan's delta comparison.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Writes the tool-local results file; no site state.')]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings,
        [Parameter(Mandatory)][string]$Path
    )
    $doc = [pscustomobject]@{
        SchemaVersion = 1
        ScanTime      = (Get-Date).ToString('o')
        Findings      = @($Findings | ForEach-Object {
            [pscustomobject]@{
                CheckId    = $_.CheckId
                Severity   = $_.Severity
                ObjectType = $_.ObjectType
                ObjectId   = $_.ObjectId
                ObjectName = $_.ObjectName
                Evidence   = $_.Evidence
            }
        })
    }
    $doc | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-HygieneScanResult {
    <#
    .SYNOPSIS
        Reads the previous scan's findings; $null when absent or unreadable.

    .DESCRIPTION
        A malformed file degrades to "no previous scan" (every finding
        reports as new) rather than failing the scan that produced good
        data.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $doc = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
        if (-not $doc.PSObject.Properties['Findings']) { return $null }
        return $doc
    }
    catch {
        Write-Log "Previous scan results unreadable ($Path): $($_.Exception.Message)" -Level WARN -Quiet
        Write-Log 'The previous scan results are unreadable. The log file has the details.' -Level WARN
        return $null
    }
}

function Get-HygieneScanDelta {
    <#
    .SYNOPSIS
        Diffs a scan against the previous results by finding identity.

    .OUTPUTS
        [pscustomobject] NewKeys (HashSet of suppression keys first seen
        this scan), Resolved (previous findings no longer present),
        HasBaseline (false when no previous scan existed).
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings,
        $Previous
    )

    $newKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if (-not $Previous) {
        return [pscustomobject]@{ NewKeys = $newKeys; Resolved = @(); HasBaseline = $false }
    }

    $prevKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in @($Previous.Findings)) { [void]$prevKeys.Add((Get-HygieneSuppressionKey -Finding $f)) }

    $currentKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in @($Findings)) {
        $key = Get-HygieneSuppressionKey -Finding $f
        [void]$currentKeys.Add($key)
        if (-not $prevKeys.Contains($key)) { [void]$newKeys.Add($key) }
    }

    $resolved = @(@($Previous.Findings) | Where-Object { -not $currentKeys.Contains((Get-HygieneSuppressionKey -Finding $_)) })
    return [pscustomobject]@{ NewKeys = $newKeys; Resolved = $resolved; HasBaseline = $true }
}

# ---------------------------------------------------------------------------
# Collection evaluation deep-dive (COL-05..COL-09)
# ---------------------------------------------------------------------------

function Get-HygCollectionReferenceGraph {
    <#
    .SYNOPSIS
        Builds the collection reference edge list from the collection
        dataset: limiting, include, and exclude references.

    .DESCRIPTION
        Every referenced collection joins the evaluation graph when the
        referencing collection evaluates, so these edges are the unit of
        both the depth and the cycle analysis. No provider round-trips:
        the dataset already carries the ids.
    #>
    param([Parameter(Mandatory)]$Data)

    # SMS_CollectionDependencies is the authoritative source; the embedded
    # CollectionRules fallback under-reports because the provider returns
    # include/exclude rules as null lazy elements.
    if ($Data.PSObject.Properties['CollectionDependencies'] -and @($Data.CollectionDependencies).Count -gt 0) {
        return @($Data.CollectionDependencies)
    }

    $edges = @()
    foreach ($c in @($Data.Collections)) {
        if ($c.LimitToCollectionID) { $edges += [pscustomobject]@{ From = [string]$c.CollectionID; To = [string]$c.LimitToCollectionID; Kind = 'limit' } }
        foreach ($id in @($c.IncludeIDs)) { if ($id) { $edges += [pscustomobject]@{ From = [string]$c.CollectionID; To = [string]$id; Kind = 'include' } } }
        foreach ($id in @($c.ExcludeIDs)) { if ($id) { $edges += [pscustomobject]@{ From = [string]$c.CollectionID; To = [string]$id; Kind = 'exclude' } } }
    }
    return $edges
}

function Test-HygCollectionEvaluationChecks {
    <#
    .SYNOPSIS
        COL-05..COL-09: collection evaluation configuration checks.

    .DESCRIPTION
        Rules per the Learn collection best-practices and evaluation
        docs: full updates are only a backup on incremental collections;
        direct-rule-only collections with a non-incremental limiting
        collection need no schedule; deep include/exclude chains add
        every referenced collection into the evaluation graph; reference
        cycles are never valid; clustered full-update start times create
        evaluation hot spots. Built-in (SMS*) collections are exempt -
        the site owns their configuration and Set-CMCollection refuses
        them.
    #>
    param(
        [Parameter(Mandatory)]$Data,
        [hashtable]$Thresholds = (Get-HygieneDefaultThresholds)
    )

    $cols = @($Data.Collections | Where-Object { -not $_.IsBuiltIn })
    $byId = @{}
    foreach ($c in @($Data.Collections)) { $byId[[string]$c.CollectionID] = $c }
    $nameOf = { param($id) if ($byId.ContainsKey($id)) { $byId[$id].Name } else { $id } }

    # COL-05 / COL-06: refresh configuration. RefreshType: 1 = manual,
    # 2 = periodic full, 4 = incremental, 6 = both.
    foreach ($c in $cols) {
        $freqText = if ($c.FullMinuteSpan -gt 0) { "every $($c.FullMinuteSpan) minute(s)" }
                    elseif ($c.FullHourSpan -gt 0) { "every $($c.FullHourSpan) hour(s)" }
                    elseif ($c.FullDaySpan -gt 0) { "every $($c.FullDaySpan) day(s)" }
                    else { 'on an unrecognized schedule' }

        if ($c.RefreshType -eq 6 -and ($c.FullMinuteSpan -gt 0 -or $c.FullHourSpan -gt 0)) {
            New-HygieneFinding -CheckId 'COL-05' -Severity Warning -Category 'Collections' `
                -ObjectType 'Collection' -ObjectId $c.CollectionID -ObjectName $c.Name `
                -Evidence ("Incremental updates are enabled AND a full evaluation runs {0}. A full update on an incremental collection is only a backup evaluation; running it sub-daily duplicates work the incremental cycle already does, and each full evaluation also evaluates every dependent collection." -f $freqText) `
                -Recommendation 'Keep incremental updates and drop the full schedule back to a rare backup, or remove it.' `
                -FixScript ("Set-CMCollection -CollectionId '{0}' -RefreshType Continuous" -f (ConvertTo-HygQuotedLiteral $c.CollectionID))
        }

        if ($c.RefreshType -in 2, 6 -and $c.DirectRuleCount -gt 0 -and $c.QueryRuleCount -eq 0 -and @($c.IncludeIDs).Count -eq 0 -and @($c.ExcludeIDs).Count -eq 0) {
            $limiting = $(if ($byId.ContainsKey([string]$c.LimitToCollectionID)) { $byId[[string]$c.LimitToCollectionID] } else { $null })
            if (-not $limiting -or $limiting.RefreshType -notin 4, 6) {
                New-HygieneFinding -CheckId 'COL-06' -Severity Info -Category 'Collections' `
                    -ObjectType 'Collection' -ObjectId $c.CollectionID -ObjectName $c.Name `
                    -Evidence ("Membership is {0} direct rule(s) only and the limiting collection '{1}' is not incrementally updated. Direct membership never changes on its own, so the scheduled evaluation re-computes an identical result every cycle." -f $c.DirectRuleCount, (& $nameOf ([string]$c.LimitToCollectionID))) `
                    -Recommendation 'Disable the update schedule; direct-rule collections update when the rule changes.' `
                    -FixScript ("Set-CMCollection -CollectionId '{0}' -RefreshType Manual" -f (ConvertTo-HygQuotedLiteral $c.CollectionID))
            }
        }
    }

    # Reference graph: depth and cycles.
    $edges = @(Get-HygCollectionReferenceGraph -Data $Data)
    $refAdj = @{}
    foreach ($e in ($edges | Where-Object { $_.Kind -ne 'limit' })) {
        if (-not $refAdj.ContainsKey($e.From)) { $refAdj[$e.From] = @() }
        $refAdj[$e.From] += $e.To
    }

    # COL-07: longest include/exclude chain per collection (memoized DFS,
    # cycle-guarded; cycles report through COL-08, not a bogus depth).
    $depthCache = @{}
    $getRefDepth = $null
    $getRefDepth = {
        param([string]$Id, [hashtable]$OnPath)
        if ($depthCache.ContainsKey($Id)) { return $depthCache[$Id] }
        if ($OnPath.ContainsKey($Id)) { return 0 }
        $OnPath[$Id] = $true
        $max = 0
        if ($refAdj.ContainsKey($Id)) {
            foreach ($next in $refAdj[$Id]) {
                $d = 1 + (& $getRefDepth $next $OnPath)
                if ($d -gt $max) { $max = $d }
            }
        }
        [void]$OnPath.Remove($Id)
        $depthCache[$Id] = $max
        return $max
    }
    $maxDepth = [int]$Thresholds.ColRefDepthMax
    foreach ($c in $cols) {
        $d = & $getRefDepth ([string]$c.CollectionID) @{}
        if ($d -gt $maxDepth) {
            New-HygieneFinding -CheckId 'COL-07' -Severity Warning -Category 'Collections' `
                -ObjectType 'Collection' -ObjectId $c.CollectionID -ObjectName $c.Name `
                -Evidence ("Include/exclude references chain {0} levels deep (threshold {1}). Every referenced collection is evaluated to build this membership, and a change anywhere in the chain re-evaluates the whole branch." -f $d, $maxDepth) `
                -Recommendation 'Flatten the chain: replace nested include/exclude rules with a WQL query rule using a ResourceId subselect against the target collection.' `
                -FixScript ("# Replace include/exclude rules on '{0}' with a query rule, for example: select * from SMS_R_System where SMS_R_System.ResourceId in (select ResourceID from SMS_CM_RES_COLL_<CollectionID>)" -f $c.Name)
        }
    }

    # COL-08: reference cycles across limit + include + exclude edges.
    $fullAdj = @{}
    foreach ($e in $edges) {
        if (-not $fullAdj.ContainsKey($e.From)) { $fullAdj[$e.From] = @() }
        $fullAdj[$e.From] += $e.To
    }
    $flagged = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $edges) {
        if ($flagged.Contains($e.From)) { continue }
        if ($e.From -like 'SMS*') { continue }
        # From is in a cycle when From is reachable from To.
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $stack = New-Object 'System.Collections.Generic.Stack[string]'
        $stack.Push($e.To)
        $inCycle = $false
        while ($stack.Count -gt 0) {
            $n = $stack.Pop()
            if ($n -eq $e.From) { $inCycle = $true; break }
            if (-not $seen.Add($n)) { continue }
            if ($fullAdj.ContainsKey($n)) { foreach ($m in $fullAdj[$n]) { $stack.Push($m) } }
        }
        if ($inCycle) {
            [void]$flagged.Add($e.From)
            New-HygieneFinding -CheckId 'COL-08' -Severity Error -Category 'Collections' `
                -ObjectType 'Collection' -ObjectId $e.From -ObjectName (& $nameOf $e.From) `
                -Evidence ("The {0} reference from '{1}' to '{2}' is part of a loop: following limiting/include/exclude references from '{2}' leads back to '{1}'. Every evaluation of any collection in the loop re-enters the loop, which hammers collection evaluation and the site database." -f $e.Kind, (& $nameOf $e.From), (& $nameOf $e.To)) `
                -Recommendation 'Break the loop by removing or re-pointing one of the references in the cycle.' `
                -FixScript ("# Console: review the {0} rule on '{1}' that references '{2}' and break the cycle" -f $e.Kind, (& $nameOf $e.From), (& $nameOf $e.To))
        }
    }

    # COL-09: full-update start-time hot spots.
    $hotThreshold = [int]$Thresholds.ColFullEvalHotSpotCount
    $scheduled = @($cols | Where-Object { $_.RefreshType -in 2, 6 -and $_.FullStartHour -ge 0 })
    foreach ($group in ($scheduled | Group-Object FullStartHour | Where-Object { $_.Count -ge $hotThreshold })) {
        $names = @($group.Group | Select-Object -First 5 | ForEach-Object { "'$($_.Name)'" }) -join ', '
        New-HygieneFinding -CheckId 'COL-09' -Severity Info -Category 'Collections' `
            -ObjectType 'Schedule' -ObjectId ([string]$group.Name) -ObjectName ("{0} full updates starting at {1:00}:00" -f $group.Count, [int]$group.Name) `
            -Evidence ("{0} collections schedule their full evaluation in the same start hour ({1:00}:00), including {2}. Clustered full updates create an evaluation hot spot; spreading them out and preferring off-peak hours reduces contention." -f $group.Count, [int]$group.Name, $names) `
            -Recommendation 'Stagger the full-update start times across off-peak hours.' `
            -FixScript '# Per collection: Set-CMCollection -CollectionId <ID> -RefreshSchedule (New-CMSchedule -Start <off-peak time> -RecurInterval Days -RecurCount 1)'
    }
}

# ---------------------------------------------------------------------------
# Site data paths and prefs (Q-112f). The window script calls these once at
# start. A test calls them without a window.
# ---------------------------------------------------------------------------

function Get-HygieneSiteKey {
    <#
    .SYNOPSIS
        The prefs keys that belong to a site.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification='Returns the full key list by design.')]
    [OutputType([string[]])]
    param()
    return @('SiteCode', 'SMSProvider', 'SQLServer')
}

function Get-HygienePreferenceDefault {
    <#
    .SYNOPSIS
        The default prefs of the tool.
    #>
    [OutputType([hashtable])]
    param()
    return @{
        DarkMode                  = $true
        SiteCode                  = ''
        SMSProvider               = ''
        SQLServer                 = ''
        SqlTrustServerCertificate = $true
        SqlQueryTimeoutSeconds    = 300
        ScanScopes                = @()
        ProviderPacingMs          = 0
        AutoRefreshMinutes        = 15
        InactiveThresholdDays     = 14
        DeploymentOldDays         = 365
        AlertsEnabled             = $true
        AlertCompliancePct        = 80
    }
}

function Get-HygieneSitePath {
    <#
    .SYNOPSIS
        Returns the paths of the site stores of Site Hygiene.
    .DESCRIPTION
        With an active site, the last scan, the suppressions, the history and the reports are below
        sites\<SITE>\tools\site-hygiene. With no site they are the old paths beside the script. The prefs file
        stays beside the script (it holds the global keys). Returns PrefsPath, LastScanPath, SuppressPath,
        HistoryPath and ReportsDir. -Create makes the folders that the site paths need.
    .PARAMETER Site
        The result of Resolve-SuiteToolSite.
    .PARAMETER ToolRoot
        The tool folder (the script folder).
    #>
    [OutputType([pscustomobject])]
    param(
        $Site,
        [Parameter(Mandatory)][string]$ToolRoot,
        [switch]$Create
    )
    $root = $ToolRoot.TrimEnd('\', '/')
    if (-not $Site) { $Site = [pscustomobject]@{ Active = $false } }
    return [pscustomobject]@{
        PrefsPath    = Join-Path $root 'SiteHygiene.prefs.json'
        LastScanPath = Resolve-SuiteToolPath -Site $Site -Name 'lastscan.json' -LegacyPath (Join-Path $root 'SiteHygiene.lastscan.json') -File -Create:$Create
        SuppressPath = Resolve-SuiteToolPath -Site $Site -Name 'suppressions.json' -LegacyPath (Join-Path $root 'SiteHygiene.suppressions.json') -File -Create:$Create
        HistoryPath  = Resolve-SuiteToolPath -Site $Site -Name 'history\metrics-history.csv' -LegacyPath (Join-Path $root 'History\metrics-history.csv') -File -Create:$Create
        ReportsDir   = Resolve-SuiteToolPath -Site $Site -Name 'reports' -LegacyPath (Join-Path $root 'Reports') -Create:$Create
    }
}

function Read-HygienePreference {
    <#
    .SYNOPSIS
        Reads the prefs: the site keys from the site, the other keys from the prefs file beside the script.
    .DESCRIPTION
        With no active site, the launcher values (SUITE_CM_SITECODE, SUITE_CM_PROVIDER) fill an empty site code and
        an empty provider. With a site, the site code is the site's code and the launcher environment is not read.
    #>
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path, $Site)
    if (-not $Site) { $Site = [pscustomobject]@{ Active = $false } }
    $prefs = Read-SuiteToolPrefs -Path $Path -Defaults (Get-HygienePreferenceDefault) -Site $Site -SiteKeys (Get-HygieneSiteKey)
    if (-not $Site -or -not $Site.Active) {
        if (-not $prefs.SiteCode -and $env:SUITE_CM_SITECODE) { $prefs.SiteCode = [string]$env:SUITE_CM_SITECODE }
        if (-not $prefs.SMSProvider -and $env:SUITE_CM_PROVIDER) { $prefs.SMSProvider = [string]$env:SUITE_CM_PROVIDER }
    }
    return $prefs
}

function Save-HygienePreference {
    <#
    .SYNOPSIS
        Saves the prefs: the site keys to the site, the other keys to the prefs file beside the script.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Writes the tool prefs files.')]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$Prefs, $Site)
    if (-not $Site) { $Site = [pscustomobject]@{ Active = $false } }
    return (Save-SuiteToolPrefs -Path $Path -Settings $Prefs -Site $Site -SiteKeys (Get-HygieneSiteKey))
}
