<#
.SYNOPSIS
    Core module for Site Hygiene.

.DESCRIPTION
    Import this module to get:
      - Structured logging and CM site connection management via the
        vendored SuiteCommon module (Lib\SuiteCommon)
      - One-pass site data prefetch (Get-HygieneData)
      - Pure hygiene checks over the prefetched data (Test-Hyg*)
      - Scan orchestration (Invoke-HygieneScan)
      - Findings export to CSV, HTML, and plain-text summary

    A scan is read-only: the prefetch uses Get-CM* cmdlets plus two CIM
    reads and never mutates the site. Every finding carries the evidence
    that produced it, a recommendation, and the PowerShell a fix would
    run - the script is displayed, never executed, by this module.

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
        [pscustomobject]@{ Id = 'PKG-01'; Category = 'Packages';     Severity = 'Warning'; Title = 'Package with no programs and no references' }
        [pscustomobject]@{ Id = 'COL-01'; Category = 'Collections';  Severity = 'Info';    Title = 'Empty collection nothing references' }
        [pscustomobject]@{ Id = 'COL-02'; Category = 'Collections';  Severity = 'Warning'; Title = 'Deployment targeting an empty collection' }
        [pscustomobject]@{ Id = 'COL-03'; Category = 'Collections';  Severity = 'Warning'; Title = 'Incremental-evaluation collection count over ceiling' }
        [pscustomobject]@{ Id = 'DPL-01'; Category = 'Deployments';  Severity = 'Info';    Title = 'Deployment past its expiration time' }
        [pscustomobject]@{ Id = 'DPL-02'; Category = 'Deployments';  Severity = 'Error';   Title = 'Required deployment past deadline with high failures' }
        [pscustomobject]@{ Id = 'DPL-03'; Category = 'Deployments';  Severity = 'Info';    Title = 'Available deployment with no takers' }
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
    }
}

function New-HygieneFinding {
    <#
    .SYNOPSIS
        Uniform finding object every check returns.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Constructs an in-memory finding object; changes no system state.')]
    param(
        [Parameter(Mandatory)][string]$CheckId,
        [Parameter(Mandatory)][ValidateSet('Error', 'Warning', 'Info')][string]$Severity,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$ObjectType,
        [AllowEmptyString()][string]$ObjectId = '',
        [Parameter(Mandatory)][string]$ObjectName,
        [Parameter(Mandatory)][string]$Evidence,
        [Parameter(Mandatory)][string]$Recommendation,
        [AllowEmptyString()][string]$FixScript = ''
    )

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
    }
}

# ---------------------------------------------------------------------------
# Data prefetch (the only CM-touching part of a scan)
# ---------------------------------------------------------------------------

function Get-HygieneData {
    <#
    .SYNOPSIS
        Pulls every dataset the checks need in one pass.

    .DESCRIPTION
        Bulk cmdlet reads plus two CIM queries; each dataset degrades to an
        empty set on failure with a note in DatasetNotes so one missing
        class or right never kills the whole scan. Requires an established
        CM connection (Connect-CMSite) because the CIM queries read the
        provider recorded by Get-CMConnectionInfo.
    #>
    param()

    $notes = New-Object System.Collections.Generic.List[string]

    $apps = @()
    try {
        $apps = @(Get-CMApplication -Fast -ErrorAction Stop | ForEach-Object {
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
            }
        })
        Write-Log "Loaded $($apps.Count) applications"
    } catch { $notes.Add("Applications unavailable: $($_.Exception.Message)"); Write-Log "Applications unavailable: $($_.Exception.Message)" -Level WARN }

    $packages = @()
    try {
        $packages = @(Get-CMPackage -Fast -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ PackageID = [string]$_.PackageID; Name = [string]$_.Name }
        })
        Write-Log "Loaded $($packages.Count) packages"
    } catch { $notes.Add("Packages unavailable: $($_.Exception.Message)"); Write-Log "Packages unavailable: $($_.Exception.Message)" -Level WARN }

    $programs = @()
    try {
        $programs = @(Get-CMProgram -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ PackageID = [string]$_.PackageID; ProgramName = [string]$_.ProgramName }
        })
        Write-Log "Loaded $($programs.Count) programs"
    } catch { $notes.Add("Programs unavailable: $($_.Exception.Message)"); Write-Log "Programs unavailable: $($_.Exception.Message)" -Level WARN }

    $taskSequences = @()
    try {
        $taskSequences = @(Get-CMTaskSequence -ErrorAction Stop | ForEach-Object {
            $refs = @()
            if ($_.References) { $refs = @($_.References | ForEach-Object { [string]$_.Package }) }
            [pscustomobject]@{ PackageID = [string]$_.PackageID; Name = [string]$_.Name; ReferencedIDs = $refs }
        })
        Write-Log "Loaded $($taskSequences.Count) task sequences"
    } catch { $notes.Add("Task sequences unavailable: $($_.Exception.Message)"); Write-Log "Task sequences unavailable: $($_.Exception.Message)" -Level WARN }

    $collections = @()
    try {
        $collections = @(Get-CMCollection -ErrorAction Stop | ForEach-Object {
            $includeIds = @()
            $excludeIds = @()
            if ($_.CollectionRules) {
                foreach ($rule in $_.CollectionRules) {
                    # Embedded rule objects frequently carry an empty
                    # SmsProviderObjectPath; the .NET type name is the
                    # reliable discriminator. Without the fallback no rule
                    # ever classifies and COL-01 flags collections that
                    # include/exclude rules still reference.
                    $typeName = $null
                    try { $typeName = [string]$rule.SmsProviderObjectPath } catch { $typeName = $null }
                    if (-not $typeName) { try { $typeName = $rule.GetType().Name } catch { continue } }
                    if ($typeName -match 'IncludeCollection') { $includeIds += [string]$rule.IncludeCollectionID }
                    elseif ($typeName -match 'ExcludeCollection') { $excludeIds += [string]$rule.ExcludeCollectionID }
                }
            }
            [pscustomobject]@{
                CollectionID        = [string]$_.CollectionID
                Name                = [string]$_.Name
                MemberCount         = [int]$_.MemberCount
                RefreshType         = [int]$_.RefreshType
                LimitToCollectionID = [string]$_.LimitToCollectionID
                IsBuiltIn           = ([string]$_.CollectionID -like 'SMS*')
                IncludeIDs          = $includeIds
                ExcludeIDs          = $excludeIds
            }
        })
        Write-Log "Loaded $($collections.Count) collections"
    } catch { $notes.Add("Collections unavailable: $($_.Exception.Message)"); Write-Log "Collections unavailable: $($_.Exception.Message)" -Level WARN }

    $deployments = @()
    try {
        $deployments = @(Get-CMDeployment -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                SoftwareName        = [string]$_.SoftwareName
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
        })
        Write-Log "Loaded $($deployments.Count) deployment summaries"
    } catch { $notes.Add("Deployment summaries unavailable: $($_.Exception.Message)"); Write-Log "Deployment summaries unavailable: $($_.Exception.Message)" -Level WARN }

    $appDeployments = @()
    try {
        $appDeployments = @(Get-CMApplicationDeployment -ErrorAction Stop | ForEach-Object {
            $expEnabled = $false
            $expTime = $null
            $p = $_.PSObject.Properties['ExpirationTimeEnabled']
            if ($p) { $expEnabled = [bool]$p.Value }
            $p = $_.PSObject.Properties['ExpirationTime']
            if ($p) { $expTime = $p.Value }
            [pscustomobject]@{
                ApplicationName       = [string]$_.ApplicationName
                CollectionName        = [string]$_.CollectionName
                TargetCollectionID    = [string]$_.TargetCollectionID
                ExpirationTimeEnabled = $expEnabled
                ExpirationTime        = $expTime
            }
        })
        Write-Log "Loaded $($appDeployments.Count) application deployments"
    } catch { $notes.Add("Application deployments unavailable: $($_.Exception.Message)"); Write-Log "Application deployments unavailable: $($_.Exception.Message)" -Level WARN }

    $conn = Get-CMConnectionInfo
    $collectionsWithSettings = @()
    $dependencyTargetCIIDs = @()

    if ($conn) {
        $ns = "root\SMS\site_$($conn.SiteCode)"

        # Collections that carry variables/settings live in
        # SMS_CollectionSettings; one query beats N per-collection cmdlet
        # round-trips.
        try {
            $collectionsWithSettings = @(
                Get-CimInstance -ComputerName $conn.SMSProvider -Namespace $ns `
                    -Query 'SELECT CollectionID FROM SMS_CollectionSettings' -ErrorAction Stop |
                ForEach-Object { [string]$_.CollectionID }
            )
            Write-Log "Loaded $($collectionsWithSettings.Count) collection-settings rows"
        } catch { $notes.Add("Collection settings unavailable (COL-01 cannot rule out variables): $($_.Exception.Message)"); Write-Log "Collection settings unavailable: $($_.Exception.Message)" -Level WARN }

        try {
            $dependencyTargetCIIDs = @(
                Get-CimInstance -ComputerName $conn.SMSProvider -Namespace $ns `
                    -Query 'SELECT ToApplicationCIID FROM SMS_AppDependenceRelation' -ErrorAction Stop |
                ForEach-Object { [int]$_.ToApplicationCIID }
            )
            Write-Log "Loaded $($dependencyTargetCIIDs.Count) dependency relations"
        } catch { $notes.Add("Dependency relations unavailable (APP-01 may over-report dependency-only applications): $($_.Exception.Message)"); Write-Log "Dependency relations unavailable: $($_.Exception.Message)" -Level WARN }
    }
    else {
        $notes.Add('No CM connection recorded; CIM datasets (collection settings, dependency relations) skipped.')
    }

    return [pscustomobject]@{
        Applications            = $apps
        Packages                = $packages
        Programs                = $programs
        TaskSequences           = $taskSequences
        Collections             = $collections
        Deployments             = $deployments
        AppDeployments          = $appDeployments
        CollectionsWithSettings = $collectionsWithSettings
        DependencyTargetCIIDs   = $dependencyTargetCIIDs
        DatasetNotes            = @($notes)
        CollectedAt             = Get-Date
    }
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
    foreach ($ts in @($Data.TaskSequences)) {
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
            -ObjectType 'Application' -ObjectId ([string]$app.CI_ID) -ObjectName $app.Name `
            -Evidence ("No deployments, no task sequence references, not part of any supersedence relationship, not a dependency target; created {0}, older than the {1}-day grace window." -f $app.DateCreated, $minAge) `
            -Recommendation 'Candidate for retirement and removal. Verify no out-of-band use (scripts, documentation) before deleting.' `
            -FixScript ("Remove-CMApplication -Name '{0}' -Force" -f ($app.Name -replace "'", "''"))
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
            -ObjectType 'Application' -ObjectId ([string]$app.CI_ID) -ObjectName $app.Name `
            -Evidence 'Application is retired (expired) but still has active deployments; clients targeted by them cannot install it.' `
            -Recommendation 'Remove the deployments, or reinstate the application if retiring it was a mistake.' `
            -FixScript ("Get-CMApplicationDeployment -Name '{0}' | Remove-CMApplicationDeployment -Force" -f ($app.Name -replace "'", "''"))
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
            -ObjectType 'Application' -ObjectId ([string]$app.CI_ID) -ObjectName $app.Name `
            -Evidence 'Application is superseded by a newer application but its own deployments are still active.' `
            -Recommendation 'Deploy the superseding application and retire these deployments so clients converge on the replacement.' `
            -FixScript ("Get-CMApplicationDeployment -Name '{0}' | Remove-CMApplicationDeployment -Force" -f ($app.Name -replace "'", "''"))
    }
}

# ---------------------------------------------------------------------------
# Checks: Packages
# ---------------------------------------------------------------------------

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
    foreach ($ts in @($Data.TaskSequences)) {
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
            -FixScript ("Remove-CMPackage -Id '{0}' -Force" -f $id)
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
            -FixScript ("Remove-CMCollection -Id '{0}' -Force" -f $id)
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
        -FixScript "# Per collection: Set-CMCollection -Id <CollectionID> -RefreshType Periodic"
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
        if (-not $d.ExpirationTimeEnabled) { continue }
        if (-not $d.ExpirationTime -or $d.ExpirationTime -ge $now) { continue }

        New-HygieneFinding -CheckId 'DPL-01' -Severity Info -Category 'Deployments' `
            -ObjectType 'Deployment' -ObjectId ([string]$d.TargetCollectionID) -ObjectName ("{0} -> {1}" -f $d.ApplicationName, $d.CollectionName) `
            -Evidence ("Deployment expired {0} and no longer offers to clients; it is clutter in every deployment view." -f $d.ExpirationTime) `
            -Recommendation 'Remove the expired deployment.' `
            -FixScript ("Get-CMApplicationDeployment -Name '{0}' -CollectionName '{1}' | Remove-CMApplicationDeployment -Force" -f ($d.ApplicationName -replace "'", "''"), ($d.CollectionName -replace "'", "''"))
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
            -FixScript ("# Triage first: deployment status for '{0}' on collection '{1}' in the console or via Get-CMDeployment" -f $d.SoftwareName, $d.CollectionName)
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

# ---------------------------------------------------------------------------
# Scan orchestration
# ---------------------------------------------------------------------------

function Invoke-HygieneScan {
    <#
    .SYNOPSIS
        Runs every implemented check over a prefetched dataset and returns
        findings sorted by severity, then check id, then object name.

    .DESCRIPTION
        Pure over its input: pass real data from Get-HygieneData or
        synthetic data of the same shape. A check that throws is recorded
        as a finding against the scan itself rather than aborting the run.
    #>
    param(
        [Parameter(Mandatory)]$Data,
        [hashtable]$Thresholds = (Get-HygieneDefaultThresholds)
    )

    # Threshold-less checks take only $d; the runner still passes both
    # arguments and the extra lands in $args, keeping one invocation shape.
    $checks = @(
        @{ Id = 'APP-01'; Run = { param($d, $t) Test-HygAppNoReferences -Data $d -Thresholds $t } }
        @{ Id = 'APP-02'; Run = { param($d) Test-HygAppRetiredDeployed -Data $d } }
        @{ Id = 'APP-03'; Run = { param($d) Test-HygAppSupersededDeployed -Data $d } }
        @{ Id = 'PKG-01'; Run = { param($d) Test-HygPackageUnused -Data $d } }
        @{ Id = 'COL-01'; Run = { param($d) Test-HygCollectionEmptyUnused -Data $d } }
        @{ Id = 'COL-02'; Run = { param($d) Test-HygDeploymentEmptyCollection -Data $d } }
        @{ Id = 'COL-03'; Run = { param($d, $t) Test-HygIncrementalCeiling -Data $d -Thresholds $t } }
        @{ Id = 'DPL-01'; Run = { param($d) Test-HygDeploymentExpired -Data $d } }
        @{ Id = 'DPL-02'; Run = { param($d, $t) Test-HygDeploymentPastDeadlineFailures -Data $d -Thresholds $t } }
        @{ Id = 'DPL-03'; Run = { param($d, $t) Test-HygDeploymentAvailableUnused -Data $d -Thresholds $t } }
    )

    $findings = New-Object System.Collections.Generic.List[object]
    foreach ($check in $checks) {
        try {
            foreach ($f in @(& $check.Run $Data $Thresholds)) {
                if ($f) { $findings.Add($f) }
            }
        }
        catch {
            Write-Log ("Check {0} failed: {1}" -f $check.Id, $_.Exception.Message) -Level WARN
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
